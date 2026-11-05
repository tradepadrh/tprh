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
    function transfer(address to, uint256 a) external virtual returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external virtual returns (bool) {
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


// ---- Uniswap V3 mocks ----
contract MockWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    receive() external payable { balanceOf[msg.sender] += msg.value; }
    function deposit() external payable { balanceOf[msg.sender] += msg.value; }
    function withdraw(uint256 a) external { balanceOf[msg.sender] -= a; payable(msg.sender).transfer(a); }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// Token that burns `taxBps` of every transfer (to test balance-delta accounting).
contract TaxToken is MockERC20 {
    uint256 public taxBps;
    constructor(uint256 t) MockERC20("TAX") { taxBps = t; }
    function _cut(uint256 a) internal view returns (uint256) { return a - a * taxBps / 10000; }
    function transfer(address to, uint256 a) external override returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += _cut(a); return true; }
    function transferFrom(address f, address to, uint256 a) external override returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += _cut(a); return true;
    }
}

contract MockV3Factory {
    mapping(bytes32 => address) internal pools;
    function setPool(address a, address b, uint24 fee, address p) external { pools[keccak256(abi.encode(a, b, fee))] = p; pools[keccak256(abi.encode(b, a, fee))] = p; }
    function getPool(address a, address b, uint24 fee) external view returns (address) { return pools[keccak256(abi.encode(a, b, fee))]; }
}

/// SwapRouter02 stand-in: 1 WETH = 1000 tokens. Pulls tokenIn from the caller, pays tokenOut to recipient.
contract MockSwapRouter {
    MockWETH public weth;
    uint24 public lastFee;
    constructor(MockWETH w) { weth = w; }
    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        lastFee = p.fee;
        if (p.tokenIn == address(weth)) {
            weth.transferFrom(msg.sender, address(this), p.amountIn);
            out = p.amountIn * 1000;
            MockERC20(p.tokenOut).mint(address(this), out);
            MockERC20(p.tokenOut).transfer(p.recipient, out); // a taxed token delivers less than `out`
        } else {
            MockERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
            out = p.amountIn / 1000;
            weth.transfer(p.recipient, out);
        }
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
    MockWETH weth;
    MockV3Factory v3f;
    MockSwapRouter sr;
    MockERC20 v1tok;

    function setUp() public {
        factory = new MockFactory();
        pm = new MockPoolManager();
        vm.deal(address(pm), 100 ether);
        weth = new MockWETH();
        v3f = new MockV3Factory();
        sr = new MockSwapRouter(weth);
        vm.deal(address(this), 50 ether);
        weth.deposit{value: 50 ether}(); weth.transfer(address(sr), 50 ether);   // router liquidity for sells
        router = new PonsRouter(address(factory), address(pm), hook, address(sr), address(v3f), address(weth), feeTo, 50); // 0.5%
        v1tok = new MockERC20("V1");
        v3f.setPool(address(v1tok), address(weth), 10000, address(0xB001));
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

    // ---------------- Uniswap V3 route (Pons v1) ----------------
    function test_buyV3_takesFeeWrapsAndSwaps() public {
        vm.prank(user);
        uint256 out = router.buyV3{value: 1 ether}(address(v1tok), 10000, 990 ether, block.timestamp);
        assertEq(out, 995 ether);
        assertEq(v1tok.balanceOf(user), 995 ether);
        assertEq(sr.lastFee(), 10000);
        assertEq(router.feesAccrued(address(0)), 0.005 ether);
        assertEq(address(router).balance, 0.005 ether, "only the fee stays in the router");
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(weth.allowance(address(router), address(sr)), 0);
    }

    function test_buyV3_revertsBelowMin() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(PonsRouter.InsufficientOutput.selector, 995 ether, 996 ether));
        router.buyV3{value: 1 ether}(address(v1tok), 10000, 996 ether, block.timestamp);
    }

    function test_buyV3_revertsWithoutPool() public {
        vm.prank(user);
        vm.expectRevert(PonsRouter.NoPool.selector);
        router.buyV3{value: 1 ether}(address(v1tok), 3000, 0, block.timestamp);   // wrong fee tier
        vm.prank(user);
        vm.expectRevert(PonsRouter.NoPool.selector);
        router.buyV3{value: 1 ether}(address(weth), 10000, 0, block.timestamp);
    }

    function test_sellV3_unwrapsAndTakesFee() public {
        v1tok.mint(user, 1000 ether);
        vm.startPrank(user);
        v1tok.approve(address(router), 1000 ether);
        uint256 balBefore = user.balance;
        uint256 out = router.sellV3(address(v1tok), 10000, 1000 ether, 0.99 ether, block.timestamp);
        vm.stopPrank();
        assertEq(out, 0.995 ether);
        assertEq(user.balance - balBefore, 0.995 ether);
        assertEq(router.feesAccrued(address(0)), 0.005 ether);
        assertEq(v1tok.allowance(address(router), address(sr)), 0);
    }

    function test_sellV3_revertsBelowMin() public {
        v1tok.mint(user, 1000 ether);
        vm.startPrank(user);
        v1tok.approve(address(router), 1000 ether);
        vm.expectRevert(abi.encodeWithSelector(PonsRouter.InsufficientOutput.selector, 0.995 ether, 1 ether));
        router.sellV3(address(v1tok), 10000, 1000 ether, 1 ether, block.timestamp);
        vm.stopPrank();
    }

    function test_v3_taxTokenUsesRealBalances() public {
        TaxToken tt = new TaxToken(1000); // 10% transfer tax
        v3f.setPool(address(tt), address(weth), 10000, address(0xB002));
        // buy: the pool sends 995 but the buyer only receives 895.5 after tax -> minOut is checked on 895.5
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(PonsRouter.InsufficientOutput.selector, 895.5 ether, 900 ether));
        router.buyV3{value: 1 ether}(address(tt), 10000, 900 ether, block.timestamp);
        vm.prank(user);
        uint256 got = router.buyV3{value: 1 ether}(address(tt), 10000, 895 ether, block.timestamp);
        assertEq(got, 895.5 ether);
        assertEq(tt.balanceOf(user), 895.5 ether);
        // sell: user sends 1000, router receives 900 after tax and only swaps what it got
        tt.mint(user, 1000 ether);
        vm.startPrank(user);
        tt.approve(address(router), 1000 ether);
        uint256 out = router.sellV3(address(tt), 10000, 1000 ether, 0, block.timestamp);
        vm.stopPrank();
        assertEq(out, 0.9 ether - 0.0045 ether);   // only the 900 tokens that arrived were swapped
    }

    function test_feesFromBothRoutesWithdrawTogether() public {
        vm.startPrank(user);
        router.buy{value: 1 ether}(address(tok), 1 ether, 0, block.timestamp);
        router.buyV3{value: 1 ether}(address(v1tok), 10000, 0, block.timestamp);
        vm.stopPrank();
        router.withdrawFees(address(0));
        assertEq(feeTo.balance, 0.01 ether);
    }
}
