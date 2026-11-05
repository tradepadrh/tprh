// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 * PonsRouter
 * ----------
 * Router with a frontend fee for Pons tokens on Robinhood Chain (chain id 4663).
 *
 * Routes:
 *   - Pons v2 launches (buy / sell): bonding curve or the Uniswap v4 pool with the pons hook (see below).
 *   - Pons v1 launches and other WETH pairs (buyV3 / sellV3): the token's Uniswap V3 pool via SwapRouter02.
 *     Pons v1 pools pair every token with WETH at the 1% fee tier (10000).
 *
 * v2 flow:
 *   - Read the launch phase from the Pons factory (getLaunchedToken(token).phase)
 *       phase 0 (NotGraduated) -> trade directly against the bonding curve
 *       phase 2 (PoolCreated)  -> swap in the Uniswap v4 pool (pons hook, pool fee = 0)
 *       any other phase        -> revert (curve closed / graduating / rescued)
 *   - Take the frontend fee (feeBps) on the quote-asset side (ETH or the pair token):
 *       buy  : fee is taken from the input before the trade
 *       sell : fee is taken from the output after the trade
 *   - Fees are held in the contract and withdrawn by the owner via withdrawFees().
 *
 * Notes:
 *   - The Pons creator fee keeps working as normal, because the trade still happens on the Pons curve/pool.
 *   - On curve buys, recipient = the user's wallet, so the snipe tax is computed for the user's wallet
 *     (per the docs: currentSnipeTaxBps is keyed on the recipient).
 *   - NOT AUDITED. Test on a fork / testnet before using real funds.
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IPonsFactory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut);
}

// ---- Uniswap v4 (minimal) ----
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified; // negative = exact input
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

// ---- Uniswap V3 (minimal) ----
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

contract PonsRouter is IUnlockCallback {
    // ---------- constants ----------
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 100; // frontend fee cap: 1%
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    address internal constant NATIVE = address(0);

    uint8 internal constant PHASE_CURVE = 0;
    uint8 internal constant PHASE_POOL = 2;
    uint8 public constant ROUTE_V3 = 100; // "phase" value in Bought/Sold events for Uniswap V3 trades

    // ---------- configuration ----------
    IPonsFactory public immutable factory;
    IPoolManager public immutable poolManager;
    address public immutable memeHook;
    ISwapRouter02 public immutable swapRouter;
    IUniswapV3Factory public immutable v3Factory;
    address public immutable weth;

    address public owner;
    address public pendingOwner;
    address public feeRecipient;
    uint16 public feeBps;

    /// fees collected per asset (address(0) = ETH)
    mapping(address => uint256) public feesAccrued;

    uint256 private _locked = 1;

    // ---------- event ----------
    event Bought(address indexed user, address indexed token, uint8 phase, uint256 quoteIn, uint256 frontendFee, uint256 tokensOut);
    event Sold(address indexed user, address indexed token, uint8 phase, uint256 tokensIn, uint256 frontendFee, uint256 quoteOut);
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address feeRecipient);
    event FeesWithdrawn(address indexed asset, address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ---------- error ----------
    error NotOwner();
    error NotPoolManager();
    error Reentrancy();
    error Expired();
    error UnknownToken();
    error UnsupportedPhase(uint8 phase);
    error FeeTooHigh();
    error ZeroAmount();
    error ValueMismatch();
    error InsufficientOutput(uint256 got, uint256 minOut);
    error TransferFailed();
    error NoPool();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(
        address _factory,
        address _poolManager,
        address _memeHook,
        address _swapRouter,
        address _v3Factory,
        address _weth,
        address _feeRecipient,
        uint16 _feeBps
    ) {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        factory = IPonsFactory(_factory);
        poolManager = IPoolManager(_poolManager);
        memeHook = _memeHook;
        swapRouter = ISwapRouter02(_swapRouter);
        v3Factory = IUniswapV3Factory(_v3Factory);
        weth = _weth;
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    receive() external payable {}

    // =====================================================================
    //                               VIEW
    // =====================================================================

    /// Routing info for the frontend: phase, curve, pair token and v4 pool key.
    function route(address token)
        external
        view
        returns (uint8 phase, address curve, address pairToken, PoolKey memory key)
    {
        IPonsFactory.LaunchedToken memory l = factory.getLaunchedToken(token);
        if (!l.exists) revert UnknownToken();
        return (l.phase, l.curve, l.pairToken, _poolKey(l));
    }

    // =====================================================================
    //                               BUY
    // =====================================================================

    /// Buy `token` with `quoteIn` of the quote asset (ETH via msg.value, or an approved ERC-20 pair token).
    /// `minTokensOut` is computed from the amount AFTER the frontend fee.
    function buy(address token, uint256 quoteIn, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (quoteIn == 0) revert ZeroAmount();
        IPonsFactory.LaunchedToken memory l = factory.getLaunchedToken(token);
        if (!l.exists) revert UnknownToken();

        address quote = l.pairToken;
        bool native = quote == NATIVE;

        // pull user funds
        if (native) {
            if (msg.value != quoteIn) revert ValueMismatch();
        } else {
            if (msg.value != 0) revert ValueMismatch();
            _pull(quote, msg.sender, quoteIn);
        }

        uint256 fee = (quoteIn * feeBps) / BPS;
        uint256 net = quoteIn - fee;
        feesAccrued[quote] += fee;

        if (l.phase == PHASE_CURVE) {
            uint256 before = _balance(quote) - feesAccrued[quote] - net; // balance other than this trade's funds
            if (native) {
                tokensOut = IPonsCurve(l.curve).buy{value: net}(net, minTokensOut, msg.sender);
            } else {
                _approve(quote, l.curve, net);
                tokensOut = IPonsCurve(l.curve).buy(net, minTokensOut, msg.sender);
                _approve(quote, l.curve, 0);
            }
            // near graduation the curve may fill partially and refund the remaining input to the router
            uint256 afterBal = _balance(quote) - feesAccrued[quote];
            if (afterBal > before) _send(quote, msg.sender, afterBal - before);
        } else if (l.phase == PHASE_POOL) {
            PoolKey memory key = _poolKey(l);
            bool zeroForOne = key.currency0 == quote; // quote -> token
            tokensOut = _swapV4(key, zeroForOne, net, msg.sender);
            if (tokensOut < minTokensOut) revert InsufficientOutput(tokensOut, minTokensOut);
        } else {
            revert UnsupportedPhase(l.phase);
        }

        emit Bought(msg.sender, token, l.phase, quoteIn, fee, tokensOut);
    }

    // =====================================================================
    //                               SELL
    // =====================================================================

    /// Sell `tokensIn` tokens (must be approved to the router). `minQuoteOut` = minimum the user receives AFTER the fee.
    function sell(address token, uint256 tokensIn, uint256 minQuoteOut, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 quoteOut)
    {
        if (tokensIn == 0) revert ZeroAmount();
        IPonsFactory.LaunchedToken memory l = factory.getLaunchedToken(token);
        if (!l.exists) revert UnknownToken();

        address quote = l.pairToken;
        _pull(token, msg.sender, tokensIn);

        uint256 gross;
        if (l.phase == PHASE_CURVE) {
            _approve(token, l.curve, tokensIn);
            // slippage is checked after the fee below, so the curve minimum is 0
            gross = IPonsCurve(l.curve).sell(tokensIn, 0, address(this));
            _approve(token, l.curve, 0);
        } else if (l.phase == PHASE_POOL) {
            PoolKey memory key = _poolKey(l);
            bool zeroForOne = key.currency0 == token; // token -> quote
            gross = _swapV4(key, zeroForOne, tokensIn, address(this));
        } else {
            revert UnsupportedPhase(l.phase);
        }

        uint256 fee = (gross * feeBps) / BPS;
        quoteOut = gross - fee;
        if (quoteOut < minQuoteOut) revert InsufficientOutput(quoteOut, minQuoteOut);

        feesAccrued[quote] += fee;
        _send(quote, msg.sender, quoteOut);

        emit Sold(msg.sender, token, l.phase, tokensIn, fee, quoteOut);
    }

    // =====================================================================
    //                    UNISWAP V3 (Pons v1 and WETH pairs)
    // =====================================================================

    /// The Uniswap V3 pool for token/WETH at a fee tier, or address(0).
    function v3Pool(address token, uint24 poolFee) public view returns (address) {
        return v3Factory.getPool(token, weth, poolFee);
    }

    /// Buy `token` with ETH through its Uniswap V3 WETH pool. Pons v1 pools use poolFee = 10000.
    /// `minTokensOut` is checked against what the buyer's balance actually gained (after any token tax).
    function buyV3(address token, uint24 poolFee, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (token == weth || v3Pool(token, poolFee) == address(0)) revert NoPool();

        uint256 fee = (msg.value * feeBps) / BPS;
        uint256 net = msg.value - fee;
        feesAccrued[NATIVE] += fee;

        IWETH9(weth).deposit{value: net}();
        _approve(weth, address(swapRouter), net);
        uint256 before = IERC20(token).balanceOf(msg.sender);
        swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth, tokenOut: token, fee: poolFee, recipient: msg.sender,
                amountIn: net, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
        _approve(weth, address(swapRouter), 0);
        tokensOut = IERC20(token).balanceOf(msg.sender) - before;
        if (tokensOut < minTokensOut) revert InsufficientOutput(tokensOut, minTokensOut);

        emit Bought(msg.sender, token, ROUTE_V3, msg.value, fee, tokensOut);
    }

    /// Sell `tokensIn` of `token` (approved to this router) for ETH through its Uniswap V3 WETH pool.
    /// `minEthOut` is the minimum ETH the seller receives after the frontend fee.
    function sellV3(address token, uint24 poolFee, uint256 tokensIn, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        if (tokensIn == 0) revert ZeroAmount();
        if (token == weth || v3Pool(token, poolFee) == address(0)) revert NoPool();

        uint256 tBefore = IERC20(token).balanceOf(address(this));
        _pull(token, msg.sender, tokensIn);
        uint256 got = IERC20(token).balanceOf(address(this)) - tBefore;   // handles transfer taxes

        _approve(token, address(swapRouter), got);
        uint256 wBefore = IERC20(weth).balanceOf(address(this));
        swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: token, tokenOut: weth, fee: poolFee, recipient: address(this),
                amountIn: got, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
        _approve(token, address(swapRouter), 0);
        uint256 gross = IERC20(weth).balanceOf(address(this)) - wBefore;
        IWETH9(weth).withdraw(gross);

        uint256 fee = (gross * feeBps) / BPS;
        ethOut = gross - fee;
        if (ethOut < minEthOut) revert InsufficientOutput(ethOut, minEthOut);
        feesAccrued[NATIVE] += fee;
        _send(NATIVE, msg.sender, ethOut);

        emit Sold(msg.sender, token, ROUTE_V3, tokensIn, fee, ethOut);
    }

    // =====================================================================
    //                          UNISWAP V4 SWAP
    // =====================================================================

    struct SwapData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address recipient;
    }

    function _swapV4(PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient)
        internal
        returns (uint256 amountOut)
    {
        bytes memory res = poolManager.unlock(abi.encode(SwapData(key, zeroForOne, amountIn, recipient)));
        amountOut = abi.decode(res, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SwapData memory s = abi.decode(data, (SwapData));

        int256 delta = poolManager.swap(
            s.key,
            SwapParams({
                zeroForOne: s.zeroForOne,
                amountSpecified: -int256(s.amountIn),
                sqrtPriceLimitX96: s.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // BalanceDelta packs two int128 values (amount0 in the high bits, amount1 in the low bits)
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 d0 = int128(delta >> 128);
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 d1 = int128(delta);

        (address inCur, address outCur, int128 dIn, int128 dOut) = s.zeroForOne
            ? (s.key.currency0, s.key.currency1, d0, d1)
            : (s.key.currency1, s.key.currency0, d1, d0);
        // exact-input swap: we owe the input (negative) and receive the output (non-negative)
        if (dIn >= 0 || dOut < 0) revert InsufficientOutput(0, 1);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-dIn));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 received = uint256(uint128(dOut));

        // pay the input to the PoolManager
        if (inCur == NATIVE) {
            poolManager.settle{value: owed}();
        } else {
            poolManager.sync(inCur);
            _send(inCur, address(poolManager), owed);
            poolManager.settle();
        }
        // take the output
        poolManager.take(outCur, s.recipient, received);

        return abi.encode(received);
    }

    // =====================================================================
    //                               ADMIN
    // =====================================================================

    function setFeeBps(uint16 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = _feeBps;
        emit FeeUpdated(_feeBps);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    /// Withdraw collected fees for one asset (address(0) = ETH) to feeRecipient.
    function withdrawFees(address asset) external onlyOwner nonReentrant {
        uint256 amount = feesAccrued[asset];
        if (amount == 0) revert ZeroAmount();
        feesAccrued[asset] = 0;
        _send(asset, feeRecipient, amount);
        emit FeesWithdrawn(asset, feeRecipient, amount);
    }

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // =====================================================================
    //                              INTERNAL
    // =====================================================================

    function _poolKey(IPonsFactory.LaunchedToken memory l) internal view returns (PoolKey memory key) {
        (address c0, address c1) = l.pairToken < l.token ? (l.pairToken, l.token) : (l.token, l.pairToken);
        key = PoolKey({currency0: c0, currency1: c1, fee: l.poolFee, tickSpacing: l.tickSpacing, hooks: memeHook});
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == NATIVE ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _pull(address token, address from, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _send(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (asset == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            (bool ok, bytes memory ret) = asset.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
            if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
        }
    }

    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
