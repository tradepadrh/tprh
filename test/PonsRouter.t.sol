// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/PonsRouter.sol";

// ------------------------------------------------------------------ mocks

contract MockERC20 {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) { symbol = s; }

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract MockFactory {
    mapping(address => IPonsFactory.LaunchedToken) internal launches;
    function set(IPonsFactory.LaunchedToken memory l) external { launches[l.token] = l; }
    function setPhase(address t, uint8 p) external { launches[t].phase = p; }
    function getLaunchedToken(address t) external view returns (IPonsFactory.LaunchedToken memory) { return launches[t]; }
}

/// Curve: 1 quote = 1000 tokens. Can fill partially (sellable) and refund to msg.sender.
contract MockCurve {
    MockERC20 public token;
    address public pair; // 0 = ETH
    uint256 public sellable = type(uint256).max;
    address public lastRecipient;

    constructor(MockERC20 t, address p) { token = t; pair = p; }
    receive() external payable {}

    function setSellable(uint256 s) external { sellable = s; }

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 out) {
        if (pair == address(0)) require(msg.value == quoteIn, "value");
        else MockERC20(pair).transferFrom(msg.sender, address(this), quoteIn);
        lastRecipient = recipient;
        out = quoteIn * 1000;
        uint256 spent = quoteIn;
        if (out > sellable) {
            out = sellable;
            spent = sellable / 1000;
            uint256 refund = quoteIn - spent;
            if (pair == address(0)) payable(msg.sender).transfer(refund);
            else MockERC20(pair).transfer(msg.sender, refund);
        }
        require(out * 1 >= minTokensOut * spent / quoteIn, "slippage"); // rate-based check
        token.mint(recipient, out);
    }

    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 out) {
        token.transferFrom(msg.sender, address(this), tokensIn);
        out = tokensIn / 1000;
        require(out >= minQuoteOut, "slippage");
        if (pair == address(0)) payable(recipient).transfer(out);
        else MockERC20(pair).transfer(recipient, out);
    }
}

/// Simple PoolManager: fixed rate 1 currency0 = 2 currency1. Checks that the input was actually paid.
contract MockPoolManager {
    address internal synced;
    uint256 internal syncedBal;
    uint256 public paid;

    receive() external payable {}

    function unlock(bytes calldata data) external returns (bytes memory r) {
        paid = 0;
        r = IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, SwapParams memory p, bytes calldata) external pure returns (int256) {
        uint256 amtIn = uint256(-p.amountSpecified);
        int128 a0; int128 a1;
        if (p.zeroForOne) { a0 = -int128(int256(amtIn)); a1 = int128(int256(amtIn * 2)); }
        else { a1 = -int128(int256(amtIn)); a0 = int128(int256(amtIn / 2)); }
        return (int256(a0) << 128) | int256(uint256(uint128(a1)));
    }

    function sync(address c) external { synced = c; syncedBal = MockERC20(c).balanceOf(address(this)); }

    function settle() external payable returns (uint256) {
        if (msg.value > 0) paid = msg.value;
        else paid = MockERC20(synced).balanceOf(address(this)) - syncedBal;
        return paid;
    }

    function take(address c, address to, uint256 a) external {
        if (c == address(0)) payable(to).transfer(a);
        else MockERC20(c).mint(to, a); // mock: mint the output
    }
}

// ------------------------------------------------------------------ tests

contract PonsRouterTest is Test {
    MockFactory factory;
    MockPoolManager pm;
    PonsRouter router;
    MockERC20 tok;
    MockCurve curve;
    address hook = address(0xBEEF);
    address feeTo = address(0xFEE);
    address user = address(0xA11CE);

    function setUp() public {
        factory = new MockFactory();
        pm = new MockPoolManager();
        vm.deal(address(pm), 100 ether);
        router = new PonsRouter(address(factory), address(pm), hook, feeTo, 50); // 0.5%
        tok = new MockERC20("MEME");
        curve = new MockCurve(tok, address(0));
        vm.deal(address(curve), 100 ether);
        factory.set(_launch(address(tok), address(curve), address(0), 0));
        vm.deal(user, 100 ether);
    }

    function _launch(address t, address c, address pair, uint8 phase) internal pure returns (IPonsFactory.LaunchedToken memory l) {
        l.token = t; l.curve = c; l.pairToken = pair; l.phase = phase; l.exists = true; l.tickSpacing = 200;
    }

    function test_buyCurveNative_takesFeeAndSendsTokensToUser() public {
        vm.prank(user);
        uint256 out = router.buy{value: 1 ether}(address(tok), 1 ether, 0, block.timestamp);
        assertEq(out, 0.995 ether * 1000);
        assertEq(tok.balanceOf(user), out);
        assertEq(curve.lastRecipient(), user, "snipe tax must be computed for the user wallet");
        assertEq(router.feesAccrued(address(0)), 0.005 ether);
        assertEq(address(router).balance, 0.005 ether);
    }

    function test_buyCurveNative_refundsPartialFill() public {
        curve.setSellable(100 ether); // = 0.1 ETH worth
        uint256 balBefore = user.balance;
        vm.prank(user);
        router.buy{value: 1 ether}(address(tok), 1 ether, 0, block.timestamp);
        assertEq(tok.balanceOf(user), 100 ether);
        // user pays 0.1 to the curve + 0.005 fee; the rest is refunded
        assertEq(balBefore - user.balance, 0.105 ether);
        assertEq(address(router).balance, 0.005 ether);
    }

    function test_sellCurveNative_feeOnOutput() public {
        tok.mint(user, 1000 ether);
        vm.startPrank(user);
        tok.approve(address(router), 1000 ether);
        uint256 balBefore = user.balance;
        uint256 out = router.sell(address(tok), 1000 ether, 0.99 ether, block.timestamp);
        vm.stopPrank();
        assertEq(out, 0.995 ether);
        assertEq(user.balance - balBefore, 0.995 ether);
        assertEq(router.feesAccrued(address(0)), 0.005 ether);
    }

    function test_sellCurve_revertsWhenBelowMin() public {
        tok.mint(user, 1000 ether);
        vm.startPrank(user);
        tok.approve(address(router), 1000 ether);
        vm.expectRevert(abi.encodeWithSelector(PonsRouter.InsufficientOutput.selector, 0.995 ether, 1 ether));
        router.sell(address(tok), 1000 ether, 1 ether, block.timestamp);
        vm.stopPrank();
    }

    function test_buyPoolNative_swapsOnV4() public {
        factory.setPhase(address(tok), 2);
        vm.prank(user);
        uint256 out = router.buy{value: 1 ether}(address(tok), 1 ether, 1 ether, block.timestamp);
        // ETH (currency0) -> token: 2x rate on 0.995
        assertEq(out, 1.99 ether);
        assertEq(tok.balanceOf(user), 1.99 ether);
        assertEq(pm.paid(), 0.995 ether);
        assertEq(router.feesAccrued(address(0)), 0.005 ether);
    }

    function test_buyPool_revertsBelowMin() public {
        factory.setPhase(address(tok), 2);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(PonsRouter.InsufficientOutput.selector, 1.99 ether, 2 ether));
        router.buy{value: 1 ether}(address(tok), 1 ether, 2 ether, block.timestamp);
    }

    function test_sellPoolNative() public {
        factory.setPhase(address(tok), 2);
        tok.mint(user, 2 ether);
        vm.startPrank(user);
        tok.approve(address(router), 2 ether);
        uint256 balBefore = user.balance;
        uint256 out = router.sell(address(tok), 2 ether, 0, block.timestamp);
        vm.stopPrank();
        assertEq(out, 0.995 ether); // 2 token -> 1 ETH, minus 0.5%
        assertEq(user.balance - balBefore, 0.995 ether);
        assertEq(pm.paid(), 2 ether);
    }

    function test_buyCurveErc20Pair() public {
        MockERC20 usd = new MockERC20("USD");
        MockERC20 t2 = new MockERC20("T2");
        MockCurve c2 = new MockCurve(t2, address(usd));
        usd.mint(address(c2), 1000 ether);
        factory.set(_launch(address(t2), address(c2), address(usd), 0));
        usd.mint(user, 10 ether);
        vm.startPrank(user);
        usd.approve(address(router), 10 ether);
        router.buy(address(t2), 10 ether, 0, block.timestamp);
        vm.stopPrank();
        assertEq(t2.balanceOf(user), 9.95 ether * 1000);
        assertEq(router.feesAccrued(address(usd)), 0.05 ether);
        assertEq(usd.balanceOf(address(router)), 0.05 ether);
    }

    function test_rejectsSweptPhase() public {
        factory.setPhase(address(tok), 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(PonsRouter.UnsupportedPhase.selector, uint8(1)));
        router.buy{value: 1 ether}(address(tok), 1 ether, 0, block.timestamp);
    }

    function test_rejectsWrongValueAndExpired() public {
        vm.prank(user);
        vm.expectRevert(PonsRouter.ValueMismatch.selector);
        router.buy{value: 0.5 ether}(address(tok), 1 ether, 0, block.timestamp);

        vm.warp(1000);
        vm.prank(user);
        vm.expectRevert(PonsRouter.Expired.selector);
        router.buy{value: 1 ether}(address(tok), 1 ether, 0, 999);
    }

    function test_adminFeeCapAndWithdraw() public {
        vm.expectRevert(PonsRouter.FeeTooHigh.selector);
        router.setFeeBps(101);

        vm.prank(user);
        vm.expectRevert(PonsRouter.NotOwner.selector);
        router.setFeeBps(10);

        vm.prank(user);
        router.buy{value: 1 ether}(address(tok), 1 ether, 0, block.timestamp);
        router.withdrawFees(address(0));
        assertEq(feeTo.balance, 0.005 ether);
        assertEq(router.feesAccrued(address(0)), 0);
    }

    function test_unlockCallbackOnlyPoolManager() public {
        vm.expectRevert(PonsRouter.NotPoolManager.selector);
        router.unlockCallback("");
    }
}
