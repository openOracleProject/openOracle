// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenPuntBase} from "../openPunt/OpenPuntBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";
import {MintableERC20} from "../openPunt/util/MintableERC20.sol";

/**
 * @title OpenPuntHelperBase
 * @notice Fixture for OpenPuntHelper: the real OpenPunt system from `OpenPuntBase`, plus the
 *         authentic Uniswap Universal Router and V2/V3/V4 venues from the isolated
 *         `uniswap-venues/` project.
 *
 * @dev This extends `OpenPuntBase`, so every
 *      position still reaches its state through the same real `propose` -> `matchSwap` -> settle ->
 *      `execute` -> `report` -> `execute` calls the rest of the OpenPunt suite uses. The only
 *      additions here are routing venues, the helper itself, and the extra actors the helper's
 *      funder/designated-party split requires.
 *
 *      Venue placement is duplicated from `DisputeHelperBase` because the venues are compiled at
 *      0.5.16 / 0.7.6 / 0.8.26 and placed with `vm.deployCode`. Keeping the setup separate avoids
 *      coupling the fixtures while identical artifact paths let one venue rebuild serve both.
 *
 *      PERMIT2. `OpenPuntBase._deploySystem` etches `RecordingPermit2` at the canonical address
 *      because OpenPunt's own `propose`/`close` paths need it. The router's Permit2 immutable
 *      points at that same address. The `payerIsUser` route test confirms that such a plan cannot
 *      fund the helper because the helper never approves Permit2.
 *
 *      Up to three obligations are aggregated by token into `FundingState.assets`; the summed
 *      requirement for each is deposited into the helper's own OpenOracle ledger, OpenPunt is
 *      granted an internal allowance over it, and only then is `matchSwap` / `report` called.
 *      `suppliedAmount3` is matcher collateral on a match and native execution compensation on a
 *      report.
 */
abstract contract OpenPuntHelperBase is OpenPuntBase {
    // ── real Uniswap venues ─────────────────────────────────────────────
    address internal v2Factory;
    address internal v3Factory;
    address internal poolManager;
    address internal router;
    address internal v4Liquidity;

    OpenPuntHelper internal helper;

    /// @dev Third-asset route input, and a canonical WETH for WRAP_ETH / UNWRAP_WETH.
    MintableERC20 internal tokenC;
    HelperWETH9 internal weth;

    // ── actors, kept distinct from OpenPuntBase's ───────────────────────
    /// @dev Supplies all capital and is `msg.sender` to the helper.
    address internal funder = address(0x2001);
    /// @dev Recorded as the position counterparty and opening oracle reporter.
    address internal designatedMatcher = address(0x2002);
    /// @dev Recorded as the active-report oracle reporter.
    address internal designatedReporter = address(0x2003);
    /// @dev Never authorised for anything; used for negative cases.
    address internal attacker = address(0x2004);

    address internal constant ETH_ASSET = address(0);

    // ── router command bytes (Uniswap's Commands library) ───────────────
    uint8 internal constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint8 internal constant CMD_V3_SWAP_EXACT_OUT = 0x01;
    uint8 internal constant CMD_PERMIT2_TRANSFER_FROM = 0x02;
    uint8 internal constant CMD_PERMIT2_PERMIT_BATCH = 0x03;
    uint8 internal constant CMD_SWEEP = 0x04;
    uint8 internal constant CMD_TRANSFER = 0x05;
    uint8 internal constant CMD_PAY_PORTION = 0x06;
    uint8 internal constant CMD_V2_SWAP_EXACT_IN = 0x08;
    uint8 internal constant CMD_V2_SWAP_EXACT_OUT = 0x09;
    uint8 internal constant CMD_PERMIT2_PERMIT = 0x0a;
    uint8 internal constant CMD_WRAP_ETH = 0x0b;
    uint8 internal constant CMD_UNWRAP_WETH = 0x0c;
    uint8 internal constant CMD_PERMIT2_TRANSFER_FROM_BATCH = 0x0d;
    uint8 internal constant CMD_BALANCE_CHECK_ERC20 = 0x0e;
    uint8 internal constant CMD_V4_SWAP = 0x10;
    uint8 internal constant CMD_V3_POSITION_MANAGER_PERMIT = 0x11;
    uint8 internal constant CMD_V3_POSITION_MANAGER_CALL = 0x12;
    uint8 internal constant CMD_V4_INITIALIZE_POOL = 0x13;
    uint8 internal constant CMD_V4_POSITION_MANAGER_CALL = 0x14;
    uint8 internal constant CMD_EXECUTE_SUB_PLAN = 0x21;
    uint8 internal constant ROUTER_FLAG_ALLOW_REVERT = 0x80;

    // ── V4 actions (v4-periphery's Actions library) ─────────────────────
    uint8 internal constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant ACTION_SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant ACTION_SETTLE = 0x0b;
    uint8 internal constant ACTION_TAKE = 0x0e;
    uint8 internal constant ACTION_TAKE_ALL = 0x0f;

    // ── venue parameters ────────────────────────────────────────────────
    uint24 internal constant V3_FEE = 3000;
    uint24 internal constant V4_FEE = 3000;
    int24 internal constant V4_TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant MIN_TICK = -887220;
    int24 internal constant MAX_TICK = 887220;
    uint256 internal constant POOL_LIQUIDITY = 2_000_000e18;

    function setUp() public virtual {
        _deploySystem();
        _fundActors();
        _armSwapper();
        _armMatcher();

        tokenC = new MintableERC20("RouteTokenC", "RTC");
        weth = new HelperWETH9();

        _deployVenues();
        _seedVenues();

        helper = new OpenPuntHelper(address(punt));

        _armHelperActors();
    }

    // ────────────────────────────────────────────────────────────────────
    //  actors
    // ────────────────────────────────────────────────────────────────────

    /// @dev The funder holds all the capital and approves the helper. The designated parties hold
    ///      nothing by default — their only job is to grant OpenPunt the internal allowances that
    ///      `matchSwap`/`report` need in order to consume the legs pushed to them. Keeping their
    ///      wallets empty is what makes "the caller supplied the capital" observable.
    function _armHelperActors() internal {
        vm.deal(funder, 1_000 ether);
        vm.deal(designatedMatcher, 10 ether);
        vm.deal(designatedReporter, 10 ether);
        vm.deal(attacker, 10 ether);

        collat.mint(funder, 10_000_000e18);
        tokenA.mint(funder, 10_000_000e18);
        tokenB.mint(funder, 10_000_000e18);
        tokenC.mint(funder, 10_000_000e18);

        vm.startPrank(funder);
        collat.approve(address(helper), type(uint256).max);
        tokenA.approve(address(helper), type(uint256).max);
        tokenB.approve(address(helper), type(uint256).max);
        tokenC.approve(address(helper), type(uint256).max);
        collat.approve(address(oracle), type(uint256).max);
        tokenA.approve(address(oracle), type(uint256).max);
        tokenB.approve(address(oracle), type(uint256).max);
        tokenC.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The approvals a designated matcher must hold. `matchSwap` pushes both oracle legs to
    ///      the matcher and then creates the oracle game with the matcher as reporter, which is
    ///      what consumes them with OpenPunt as `msg.sender`. Collateral needs NO approval here —
    ///      it moves funder -> OpenPunt directly.
    function _approveMatcherLegs(address who, address token1, address token2) internal {
        _approveToPunt(who, token1);
        _approveToPunt(who, token2);
    }

    /// @dev `approveInternal` refuses a non-zero -> non-zero change, so zero first. This keeps the
    ///      arming helpers idempotent when a suite arms the same actor for several token sets.
    function _approveToPunt(address who, address token) internal {
        vm.startPrank(who);
        oracle.approveInternal(address(punt), token, 0);
        oracle.approveInternal(address(punt), token, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The designated reporter approves only the oracle legs. The helper funds execution
    ///      compensation directly; when an oracle leg is ETH, it is already included here.
    function _approveReporterLegs(address who, address token1, address token2) internal {
        _approveToPunt(who, token1);
        _approveToPunt(who, token2);
    }

    // ────────────────────────────────────────────────────────────────────
    //  RouteFunding builders — tryInternalBalances is explicit everywhere
    // ────────────────────────────────────────────────────────────────────

    /// @dev A fully supplied call that needs no routing at all.
    function _noRouteFunding(uint256 supplied1, uint256 supplied2, uint256 supplied3, bool tryInternal)
        internal
        view
        returns (OpenPuntHelper.RouteFunding memory)
    {
        return OpenPuntHelper.RouteFunding({
            suppliedAmount1: supplied1,
            suppliedAmount2: supplied2,
            suppliedAmount3: supplied3,
            tryInternalBalances: tryInternal,
            inputToken: address(tokenC),
            maxSwapInput: 0,
            commands: "",
            inputs: new bytes[](0),
            deadline: block.timestamp + 1
        });
    }

    function _routeFunding(
        uint256 supplied1,
        uint256 supplied2,
        uint256 supplied3,
        bool tryInternal,
        address inputToken,
        uint256 maxSwapInput,
        bytes memory commands,
        bytes[] memory inputs
    ) internal view returns (OpenPuntHelper.RouteFunding memory) {
        return OpenPuntHelper.RouteFunding({
            suppliedAmount1: supplied1,
            suppliedAmount2: supplied2,
            suppliedAmount3: supplied3,
            tryInternalBalances: tryInternal,
            inputToken: inputToken,
            maxSwapInput: maxSwapInput,
            commands: commands,
            inputs: inputs,
            deadline: block.timestamp + 1
        });
    }

    // ────────────────────────────────────────────────────────────────────
    //  internal-balance helpers — real deposits and approvals only
    // ────────────────────────────────────────────────────────────────────

    function _depositInternal(address who, address token, uint256 amount) internal {
        vm.startPrank(who);
        if (token == ETH_ASSET) {
            oracle.deposit{value: amount}(ETH_ASSET, uint128(amount), who);
        } else {
            IERC20Min(token).approve(address(oracle), type(uint256).max);
            oracle.deposit(token, uint128(amount), who);
        }
        vm.stopPrank();
    }

    /// @dev `approveInternal` refuses a non-zero -> non-zero change, so always zero first.
    function _approveInternalToHelper(address who, address token, uint256 amount) internal {
        vm.startPrank(who);
        oracle.approveInternal(address(helper), token, 0);
        if (amount != 0) oracle.approveInternal(address(helper), token, amount);
        vm.stopPrank();
    }

    // `_spendable` is inherited from OpenPuntBase, which already re-derives it independently of
    // production code.

    function _externalBalance(address token, address who) internal view returns (uint256) {
        return token == ETH_ASSET ? who.balance : IERC20Min(token).balanceOf(who);
    }

    // ────────────────────────────────────────────────────────────────────
    //  venue construction
    // ────────────────────────────────────────────────────────────────────

    function _deployVenues() internal {
        _requireVenueArtifacts();

        v2Factory =
            deployCode("uniswap-venues/out/UniswapV2Factory.sol/UniswapV2Factory.json", abi.encode(address(this)));
        v3Factory = deployCode("uniswap-venues/out/UniswapV3Factory.sol/UniswapV3Factory.json");
        poolManager = deployCode("uniswap-venues/out/PoolManager.sol/PoolManager.json", abi.encode(address(this)));
        v4Liquidity = deployCode("uniswap-venues/out/V4Support.sol/V4LiquidityHelper.json", abi.encode(poolManager));

        bytes32 pairInitCodeHash = keccak256(vm.getCode("uniswap-venues/out/UniswapV2Pair.sol/UniswapV2Pair.json"));
        bytes32 poolInitCodeHash = keccak256(vm.getCode("uniswap-venues/out/UniswapV3Pool.sol/UniswapV3Pool.json"));

        router = deployCode(
            "uniswap-venues/out/UniversalRouter.sol/UniversalRouter.json",
            abi.encode(
                RouterParameters({
                    permit2: PERMIT2,
                    weth9: address(weth),
                    v2Factory: v2Factory,
                    v3Factory: v3Factory,
                    pairInitCodeHash: pairInitCodeHash,
                    poolInitCodeHash: poolInitCodeHash,
                    v4PoolManager: poolManager,
                    permissionsAdapterFactory: address(0),
                    v3NFTPositionManager: address(0),
                    v4PositionManager: address(0),
                    spokePool: address(0)
                })
            )
        );
    }

    struct RouterParameters {
        address permit2;
        address weth9;
        address v2Factory;
        address v3Factory;
        bytes32 pairInitCodeHash;
        bytes32 poolInitCodeHash;
        address v4PoolManager;
        address permissionsAdapterFactory;
        address v3NFTPositionManager;
        address v4PositionManager;
        address spokePool;
    }

    /// @dev Pools among every asset a test might route between, all 1:1 with deep liquidity so a
    ///      route's output is the input less venue fees and impact. No test asserts an exact quote.
    function _seedVenues() internal {
        _seedV2(address(tokenC), address(tokenA));
        _seedV2(address(tokenC), address(tokenB));
        _seedV2(address(tokenC), address(collat));
        _seedV2(address(tokenA), address(tokenB));
        _seedV2(address(collat), address(tokenA));
        _seedV2(address(collat), address(tokenB));
        _seedV2(address(weth), address(tokenA));
        _seedV2(address(weth), address(collat));

        _seedV3(address(tokenC), address(tokenA));
        _seedV3(address(tokenC), address(collat));
        _seedV3(address(weth), address(tokenA));
        _seedV3(address(weth), address(collat));

        _seedV4(address(tokenC), address(tokenA));
        _seedV4(address(tokenC), address(collat));
        _seedV4(ETH_ASSET, address(tokenA));
    }

    function _seedV2(address a, address b) internal {
        address pair = IV2FactoryMin(v2Factory).createPair(a, b);
        _mintTo(a, pair, POOL_LIQUIDITY);
        _mintTo(b, pair, POOL_LIQUIDITY);
        IV2PairMin(pair).mint(address(this));
    }

    function _seedV3(address a, address b) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        address pool = IV3FactoryMin(v3Factory).createPool(c0, c1, V3_FEE);
        IV3PoolMin(pool).initialize(SQRT_PRICE_1_1);
        _mintTo(c0, address(this), POOL_LIQUIDITY);
        _mintTo(c1, address(this), POOL_LIQUIDITY);
        IV3PoolMin(pool).mint(address(this), MIN_TICK, MAX_TICK, 1e21, abi.encode(c0, c1));
    }

    function _seedV4(address a, address b) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        IV4LiquidityMin(v4Liquidity).initializePool(c0, c1, V4_FEE, V4_TICK_SPACING, address(0), SQRT_PRICE_1_1);
        if (c0 != ETH_ASSET) _mintTo(c0, v4Liquidity, POOL_LIQUIDITY);
        if (c1 != ETH_ASSET) _mintTo(c1, v4Liquidity, POOL_LIQUIDITY);
        if (c0 == ETH_ASSET) vm.deal(v4Liquidity, v4Liquidity.balance + POOL_LIQUIDITY);
        IV4LiquidityMin(v4Liquidity).addLiquidity(c0, c1, V4_FEE, V4_TICK_SPACING, address(0), MIN_TICK, MAX_TICK, 1e21);
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        (address c0, address c1) = abi.decode(data, (address, address));
        if (amount0Owed > 0) require(IERC20Min(c0).transfer(msg.sender, amount0Owed), "v3 pay0");
        if (amount1Owed > 0) require(IERC20Min(c1).transfer(msg.sender, amount1Owed), "v3 pay1");
    }

    /// @dev Every venue balance comes from a real mint or a real WETH deposit.
    function _mintTo(address token, address to, uint256 amount) internal {
        if (token == address(weth)) {
            vm.deal(address(this), address(this).balance + amount);
            weth.deposit{value: amount}();
            weth.transfer(to, amount);
        } else {
            MintableERC20(token).mint(to, amount);
        }
    }

    // ────────────────────────────────────────────────────────────────────
    //  route encoding — real Universal Router calldata
    // ────────────────────────────────────────────────────────────────────

    /// @dev This router revision takes a per-hop minimum-price array as the sixth field of every
    ///      V2/V3 swap input. Empty disables it; slippage is bounded by the helper's own funding
    ///      assertion instead.
    function _noHopPrices() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function _v2ExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 amountInMax)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        commands = abi.encodePacked(CMD_V2_SWAP_EXACT_OUT);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(address(helper), amountOut, amountInMax, path, false, _noHopPrices());
    }

    function _v2ExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        commands = abi.encodePacked(CMD_V2_SWAP_EXACT_IN);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(address(helper), amountIn, amountOutMin, path, false, _noHopPrices());
    }

    /// @dev A V3 exact-output path is encoded in REVERSE: tokenOut, fee, tokenIn.
    function _v3ExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 amountInMax)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes memory path = abi.encodePacked(tokenOut, V3_FEE, tokenIn);
        commands = abi.encodePacked(CMD_V3_SWAP_EXACT_OUT);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(address(helper), amountOut, amountInMax, path, false, _noHopPrices());
    }

    function _v3ExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes memory path = abi.encodePacked(tokenIn, V3_FEE, tokenOut);
        commands = abi.encodePacked(CMD_V3_SWAP_EXACT_IN);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(address(helper), amountIn, amountOutMin, path, false, _noHopPrices());
    }

    struct PoolKeyLite {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct ExactInSingle {
        PoolKeyLite poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    function _poolKey(address a, address b, address hooks) internal pure returns (PoolKeyLite memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKeyLite({currency0: c0, currency1: c1, fee: V4_FEE, tickSpacing: V4_TICK_SPACING, hooks: hooks});
    }

    /// @dev V4's TAKE_ALL credits the router's own caller, which in production is the helper.
    function _v4ExactInSingle(address tokenIn, address tokenOut, uint128 amountIn, uint128 minOut, address hooks)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        PoolKeyLite memory key = _poolKey(tokenIn, tokenOut, hooks);
        bytes memory actions = abi.encodePacked(ACTION_SWAP_EXACT_IN_SINGLE, ACTION_SETTLE, ACTION_TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInSingle({
                poolKey: key,
                zeroForOne: tokenIn == key.currency0,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(tokenIn, uint256(amountIn), false);
        params[2] = abi.encode(tokenOut, uint256(minOut));

        commands = abi.encodePacked(CMD_V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    struct ExactOutSingle {
        PoolKeyLite poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @dev SETTLE with OPEN_DELTA (0) pays whatever the exact-output swap ended up owing from the
    ///      router's own balance.
    function _v4ExactOutSingle(address tokenIn, address tokenOut, uint128 amountOut, uint128 amountInMax)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        PoolKeyLite memory key = _poolKey(tokenIn, tokenOut, address(0));
        bytes memory actions = abi.encodePacked(ACTION_SWAP_EXACT_OUT_SINGLE, ACTION_SETTLE, ACTION_TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactOutSingle({
                poolKey: key,
                zeroForOne: tokenIn == key.currency0,
                amountOut: amountOut,
                amountInMaximum: amountInMax,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(tokenIn, uint256(0), false);
        params[2] = abi.encode(tokenOut, uint256(amountOut));

        commands = abi.encodePacked(CMD_V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _sweepInput(address token) internal view returns (bytes memory) {
        return abi.encode(token, address(helper), uint256(0));
    }

    function _join(bytes memory c1, bytes[] memory i1, bytes memory c2, bytes[] memory i2)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = abi.encodePacked(c1, c2);
        inputs = new bytes[](i1.length + i2.length);
        for (uint256 i; i < i1.length; ++i) {
            inputs[i] = i1[i];
        }
        for (uint256 i; i < i2.length; ++i) {
            inputs[i1.length + i] = i2[i];
        }
    }

    function _withSweep(bytes memory commands, bytes[] memory inputs, address token)
        internal
        view
        returns (bytes memory, bytes[] memory)
    {
        bytes[] memory sweep = new bytes[](1);
        sweep[0] = _sweepInput(token);
        return _join(commands, inputs, abi.encodePacked(CMD_SWEEP), sweep);
    }

    // ────────────────────────────────────────────────────────────────────
    //  venue artifact freshness (same contract as the dispute-helper suite)
    // ────────────────────────────────────────────────────────────────────

    function _requireVenueArtifacts() internal view {
        string[5] memory closures = [
            "uniswap-venues/out/UniversalRouterBuild.sol/UniversalRouterBuild.json",
            "uniswap-venues/out/UniswapV2Factory.sol/UniswapV2Factory.json",
            "uniswap-venues/out/UniswapV3Factory.sol/UniswapV3Factory.json",
            "uniswap-venues/out/V4Support.sol/V4LiquidityHelper.json",
            "uniswap-venues/out/PoolManager.sol/PoolManager.json"
        ];
        for (uint256 i; i < closures.length; ++i) {
            if (!vm.exists(closures[i])) {
                revert(
                    "Uniswap venue artifacts are missing. They are a SEPARATE Foundry project."
                    " Run: cd uniswap-venues && forge build"
                );
            }
            string memory json = vm.readFile(closures[i]);
            string[] memory sources = vm.parseJsonKeys(json, ".metadata.sources");
            for (uint256 k; k < sources.length; ++k) {
                bytes32 built =
                    vm.parseJsonBytes32(json, string.concat(".metadata.sources.[\"", sources[k], "\"].keccak256"));
                bytes32 onDisk = keccak256(bytes(vm.readFile(string.concat("uniswap-venues/", sources[k]))));
                if (built != onDisk) {
                    revert(
                        string.concat(
                            "Uniswap venue artifacts are STALE -- changed since the build: ",
                            sources[k],
                            ". Run: cd uniswap-venues && forge build"
                        )
                    );
                }
            }
        }
    }

    receive() external payable {}
}

// ── minimal interfaces onto the version-pinned deployments ──────────────

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

interface IV2FactoryMin {
    function createPair(address, address) external returns (address);
    function getPair(address, address) external view returns (address);
}

interface IV2PairMin {
    function mint(address) external returns (uint256);
}

interface IV3FactoryMin {
    function createPool(address, address, uint24) external returns (address);
    function getPool(address, address, uint24) external view returns (address);
}

interface IV3PoolMin {
    function initialize(uint160) external;
    function mint(address, int24, int24, uint128, bytes calldata) external returns (uint256, uint256);
}

interface IV4LiquidityMin {
    function initializePool(address, address, uint24, int24, address, uint160) external;
    function addLiquidity(address, address, uint24, int24, address, int24, int24, int256) external payable;
}

interface IUniversalRouterMin {
    function execute(bytes calldata, bytes[] calldata, uint256) external payable;
}

/// @notice Canonical WETH9 behaviour, used as the router's WETH9 immutable.
contract HelperWETH9 {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "WETH: balance");
        balanceOf[msg.sender] -= amount;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "WETH: send");
        emit Transfer(msg.sender, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return transferFrom(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "WETH: balance");
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "WETH: allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }
}
