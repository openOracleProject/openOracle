// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";
import {NoReturnERC20} from "../openPunt/util/NoReturnERC20.sol";
import {MintableERC20} from "./util/MintableERC20.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

/**
 * @title DisputeHelperBase
 * @notice Fixture placing the AUTHENTIC Uniswap Universal Router, V2 factory/pairs, V3
 *         factory/pools and V4 PoolManager alongside the real OpenOracle and the real
 *         OracleDisputeHelper. No routing venue, router command, or oracle transition is mocked.
 *
 * @dev WHY `vm.deployCode` RATHER THAN `new`.
 *      A Solidity file and its entire import closure must resolve to one solc version. The
 *      Universal Router's V4Router pins `=0.8.26`, Uniswap V2 pins `=0.5.16`, Uniswap V3 pins
 *      `=0.7.6`, and every OpenPunt/OpenOracle source pins exactly `0.8.28`. No test file can
 *      therefore import both OracleDisputeHelper and the router. `uniswap-venues/` is a SEPARATE Foundry
 *      project whose shims exist only to force those artifacts to be COMPILED at their own pinned
 *      versions; this fixture then places the resulting REAL creation bytecode and drives it through
 *      hand-written minimal interfaces. Keeping it a separate project is what lets the main build
 *      keep `solc = "0.8.28"` as an explicit hard pin. The runtime code exercised by every test in
 *      this folder is genuine Uniswap code, not a reimplementation.
 *
 *      This is the same technique the Permit2 tranche uses, and it is explicitly NOT the
 *      forbidden kind of state fabrication: nothing here writes a storage slot, mocks a call, or
 *      synthesizes a hash. Pools are created by real factories and funded by real mint calls;
 *      oracle games are created by real `report()` calls.
 *
 *      PRICING. Every venue is seeded at a 1:1 ratio between the two ROUTE tokens with deep
 *      liquidity, so a route's output is the input less venue fees and price impact. Tests assert
 *      on the helper's accounting (what it required, what it kept, what it refunded), never on a
 *      venue's exact quote, so the AMM math is never re-derived here.
 */
abstract contract DisputeHelperBase is Test {
    // ── real Uniswap venues, placed from compiled artifacts ─────────────
    address internal v2Factory;
    address internal v3Factory;
    address internal poolManager;
    address internal router;
    address internal v4Liquidity;

    // ── protocol under test ─────────────────────────────────────────────
    OpenOracle internal oracle;
    /// @dev The same deployment seen through IOpenOracle2, whose struct types are the ones the
    ///      helper's ABI uses. OpenOracle declares its own layout-identical copies, and Solidity
    ///      will not implicitly convert between them.
    IOpenOracle2 internal oracleI;
    OracleDisputeHelper internal helper;

    // ── tokens ──────────────────────────────────────────────────────────
    MintableERC20 internal tokenA; // oracle token1 in the ERC20/ERC20 games
    MintableERC20 internal tokenB; // oracle token2 in the ERC20/ERC20 games
    MintableERC20 internal tokenC; // third-asset ERC20 route input
    NoReturnERC20 internal usdtLike; // USDT-style: transfer/transferFrom return no data
    MockWETH9 internal weth;

    // ── actors ──────────────────────────────────────────────────────────
    address internal reporter = address(0xA11CE);
    address internal disputer = address(0xB0B);
    address payable internal protocolFeeRecipient = payable(address(0xFEE));

    address internal constant ETH = address(0);
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ── oracle flags ────────────────────────────────────────────────────
    uint8 internal constant FLAG_TIME_TYPE = 1 << 0;
    uint8 internal constant FLAG_FEES_ONLY_AT_HALT = 1 << 5;

    // ── router command bytes (mirror of Uniswap's Commands library) ─────
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
    uint8 internal constant FLAG_ALLOW_REVERT = 0x80;

    // ── V4 action bytes (mirror of v4-periphery's Actions library) ──────
    uint8 internal constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant ACTION_SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant ACTION_SETTLE = 0x0b;
    uint8 internal constant ACTION_SETTLE_ALL = 0x0c;
    uint8 internal constant ACTION_TAKE = 0x0e;
    uint8 internal constant ACTION_TAKE_ALL = 0x0f;

    // ── venue parameters ────────────────────────────────────────────────
    uint24 internal constant V3_FEE = 3000;
    int24 internal constant V3_TICK_SPACING = 60;
    uint24 internal constant V4_FEE = 3000;
    int24 internal constant V4_TICK_SPACING = 60;
    /// @dev 2**96 — the sqrt price for a 1:1 pool.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    /// @dev Widest range aligned to tick spacing 60.
    int24 internal constant MIN_TICK = -887220;
    int24 internal constant MAX_TICK = 887220;

    // ── oracle game parameters, fixed so every expectation is hand-derivable ──
    uint128 internal constant OLD_AMOUNT_1 = 1e18;
    uint128 internal constant OLD_AMOUNT_2 = 1000e18;
    uint24 internal constant FEE_PERCENTAGE = 3000; // 3000 / 1e7 = 0.03%
    uint24 internal constant PROTOCOL_FEE = 1000; // 1000 / 1e7 = 0.01%
    uint16 internal constant MULTIPLIER = 110; // newAmount1 must be 1.1x oldAmount1
    uint16 internal constant MULTIPLIER_FLAT = 100; // newAmount1 must equal oldAmount1
    uint128 internal constant ESCALATION_HALT = 1e30;
    uint48 internal constant SETTLEMENT_TIME = 300;
    uint24 internal constant DISPUTE_DELAY = 0;
    uint96 internal constant SETTLER_REWARD = 0.001 ether;

    struct Game {
        uint256 reportId;
        IOpenOracle2.OracleGame game;
        IOpenOracle2.PreimageHelper helper;
    }

    function setUp() public virtual {
        // Permit2 is an immutable dependency of the authentic Universal Router. Deploying it here
        // keeps every caller-supplied plan on the same runtime surface as production.
        new DeployPermit2().deployPermit2();

        oracle = new OpenOracle();
        oracleI = IOpenOracle2(address(oracle));
        weth = new MockWETH9();

        tokenA = new MintableERC20("Token A", "TKA");
        tokenB = new MintableERC20("Token B", "TKB");
        tokenC = new MintableERC20("Token C", "TKC");
        usdtLike = new NoReturnERC20("Tether-like", "USDT");

        _deployVenues();
        _seedVenues();

        helper = new OracleDisputeHelper(address(oracle));

        vm.deal(reporter, 1_000 ether);
        vm.deal(disputer, 1_000 ether);
        _fund(reporter);
        _fund(disputer);
    }

    // ────────────────────────────────────────────────────────────────────
    //  venue construction
    // ────────────────────────────────────────────────────────────────────

    function _deployVenues() internal {
        _requireVenueArtifacts();

        // Artifacts are addressed by their on-disk path rather than the usual `File.sol:Name`
        // shorthand: that shorthand only resolves contracts inside the current compilation unit's
        // source set, and these venues are a separate Foundry project compiled at other solc
        // versions entirely.
        v2Factory =
            deployCode("uniswap-venues/out/UniswapV2Factory.sol/UniswapV2Factory.json", abi.encode(address(this)));
        v3Factory = deployCode("uniswap-venues/out/UniswapV3Factory.sol/UniswapV3Factory.json");
        poolManager = deployCode("uniswap-venues/out/PoolManager.sol/PoolManager.json", abi.encode(address(this)));
        v4Liquidity = deployCode("uniswap-venues/out/V4Support.sol/V4LiquidityHelper.json", abi.encode(poolManager));

        // Init-code hashes are taken from the very artifacts the factories deploy, so the router's
        // CREATE2 pool address derivation necessarily agrees with the factories'.
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

    /// @dev The venues are a separate Foundry project, so the root `forge test` cannot rebuild them
    ///      and cannot notice on its own that they are out of date. That is the one hazard this
    ///      layout introduces, and it is silent by nature: a stale `uniswap-venues/out/` makes the
    ///      whole suite exercise the PREVIOUS bytecode while reporting green.
    ///
    ///      The check is CONTENT-based, not timestamp-based. Solidity records a keccak256 of every
    ///      source it compiled in the artifact's own metadata, so comparing that against a fresh
    ///      hash of the file on disk answers exactly the right question -- "was this artifact built
    ///      from the bytes that are here now?" -- with no baseline file to maintain.
    ///
    ///      Timestamps were tried first and are wrong for this: `touch` on an unchanged file makes
    ///      the artifact look stale, but Foundry correctly skips recompiling it, so the suite would
    ///      brick permanently on a file nobody actually edited.
    ///
    ///      EVERY recorded source is checked, not a sample. An earlier version compared a hand-picked
    ///      key per tree, which left a real hole: editing `Dispatcher.sol`, `Payments.sol`,
    ///      `V2SwapRouter.sol` or any imported math library changes the deployed bytecode but touches
    ///      none of the chosen keys, so the check would have passed on stale artifacts. Walking the
    ///      whole `metadata.sources` map is the only version of this that is actually sound.
    ///
    ///      The five artifacts below are chosen so their closures collectively cover everything used
    ///      to build the deployed venues (~222 sources: 116 router, 45 PoolManager, 33 V3, 17 V4
    ///      support, 11 V2). The remaining artifacts are deployed but their sources are subsets of
    ///      these closures, so they only need an existence check.
    function _requireVenueArtifacts() internal view {
        // Cheap existence check for everything actually deployed.
        string[7] memory deployed = [
            "uniswap-venues/out/UniversalRouter.sol/UniversalRouter.json",
            "uniswap-venues/out/UniswapV2Factory.sol/UniswapV2Factory.json",
            "uniswap-venues/out/UniswapV2Pair.sol/UniswapV2Pair.json",
            "uniswap-venues/out/UniswapV3Factory.sol/UniswapV3Factory.json",
            "uniswap-venues/out/UniswapV3Pool.sol/UniswapV3Pool.json",
            "uniswap-venues/out/PoolManager.sol/PoolManager.json",
            "uniswap-venues/out/V4Support.sol/V4LiquidityHelper.json"
        ];
        for (uint256 i; i < deployed.length; ++i) {
            if (!vm.exists(deployed[i])) {
                _venueBuildRequired(string.concat("Uniswap venue artifact is missing: ", deployed[i]));
            }
        }

        string[5] memory closures = [
            "uniswap-venues/out/UniversalRouterBuild.sol/UniversalRouterBuild.json",
            "uniswap-venues/out/UniswapV2Factory.sol/UniswapV2Factory.json",
            "uniswap-venues/out/UniswapV3Factory.sol/UniswapV3Factory.json",
            "uniswap-venues/out/V4Support.sol/V4LiquidityHelper.json",
            "uniswap-venues/out/PoolManager.sol/PoolManager.json"
        ];
        for (uint256 i; i < closures.length; ++i) {
            _requireCurrentClosure(closures[i]);
        }
    }

    /// @dev Hashes every source solc recorded for this artifact against the file on disk.
    function _requireCurrentClosure(string memory artifact) internal view {
        if (!vm.exists(artifact)) {
            _venueBuildRequired(string.concat("Uniswap venue artifact is missing: ", artifact));
        }

        string memory json = vm.readFile(artifact);
        string[] memory sources = vm.parseJsonKeys(json, ".metadata.sources");

        for (uint256 i; i < sources.length; ++i) {
            _assertRecordedHash(json, sources[i]);
        }
    }

    /// @param json A venue artifact's full JSON.
    /// @param sourceKey Path as solc recorded it, i.e. relative to the venue project root.
    function _assertRecordedHash(string memory json, string memory sourceKey) internal view {
        bytes32 built = vm.parseJsonBytes32(json, string.concat(".metadata.sources.[\"", sourceKey, "\"].keccak256"));
        bytes32 onDisk = keccak256(bytes(vm.readFile(string.concat("uniswap-venues/", sourceKey))));

        if (built != onDisk) {
            _venueBuildRequired(
                string.concat("Uniswap venue artifacts are STALE -- changed since the build: ", sourceKey)
            );
        }
    }

    function _venueBuildRequired(string memory reason) internal pure {
        revert(
            string.concat(
                reason,
                ". The venues are a SEPARATE Foundry project so they cannot disturb this one's pinned"
                " 0.8.28 build, which also means the root `forge test` cannot rebuild them."
                " Run: cd uniswap-venues && forge build"
            )
        );
    }

    /// @dev Mirrors universal-router's RouterParameters. Kept local because that type lives in the
    ///      0.8.26 unit; the ABI encoding of a fully-static struct is identical either way.
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

    uint256 internal constant POOL_LIQUIDITY = 500_000e18;

    function _seedVenues() internal {
        // Route pairs that any test may need. Every pool is 1:1 with deep liquidity.
        _seedV2(address(tokenC), address(tokenA));
        _seedV2(address(tokenC), address(tokenB));
        _seedV2(address(tokenA), address(tokenB));
        _seedV2(address(weth), address(tokenA));
        _seedV2(address(weth), address(tokenB));
        _seedV2(address(usdtLike), address(tokenA));

        _seedV3(address(tokenC), address(tokenA));
        _seedV3(address(tokenC), address(tokenB));
        _seedV3(address(weth), address(tokenA));

        _seedV4(address(tokenC), address(tokenA));
        _seedV4(address(tokenC), address(tokenB));
        _seedV4(ETH, address(tokenA));
    }

    function _seedV2(address a, address b) internal {
        address pair = IV2Factory(v2Factory).createPair(a, b);
        _mintTo(a, pair, POOL_LIQUIDITY);
        _mintTo(b, pair, POOL_LIQUIDITY);
        IV2Pair(pair).mint(address(this));
    }

    function _seedV3(address a, address b) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        address pool = IV3Factory(v3Factory).createPool(c0, c1, V3_FEE);
        IV3Pool(pool).initialize(SQRT_PRICE_1_1);
        _mintTo(c0, address(this), POOL_LIQUIDITY);
        _mintTo(c1, address(this), POOL_LIQUIDITY);
        IV3Pool(pool).mint(address(this), MIN_TICK, MAX_TICK, 1e21, abi.encode(c0, c1));
    }

    function _seedV4(address a, address b) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        IV4Liquidity(v4Liquidity).initializePool(c0, c1, V4_FEE, V4_TICK_SPACING, address(0), SQRT_PRICE_1_1);
        if (c0 != ETH) _mintTo(c0, v4Liquidity, POOL_LIQUIDITY);
        if (c1 != ETH) _mintTo(c1, v4Liquidity, POOL_LIQUIDITY);
        uint256 ethNeeded = c0 == ETH ? POOL_LIQUIDITY : 0;
        if (ethNeeded > 0) vm.deal(v4Liquidity, v4Liquidity.balance + ethNeeded);
        IV4Liquidity(v4Liquidity).addLiquidity(c0, c1, V4_FEE, V4_TICK_SPACING, address(0), MIN_TICK, MAX_TICK, 1e21);
    }

    /// @dev V3 pools call this back to collect the tokens owed for a mint.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        (address c0, address c1) = abi.decode(data, (address, address));
        if (amount0Owed > 0) _transferFrom(c0, msg.sender, amount0Owed);
        if (amount1Owed > 0) _transferFrom(c1, msg.sender, amount1Owed);
    }

    // ────────────────────────────────────────────────────────────────────
    //  token helpers — every balance comes from a real mint/transfer
    // ────────────────────────────────────────────────────────────────────

    function _mintTo(address token, address to, uint256 amount) internal {
        if (token == address(weth)) {
            vm.deal(address(this), address(this).balance + amount);
            weth.deposit{value: amount}();
            weth.transfer(to, amount);
        } else if (token == address(usdtLike)) {
            usdtLike.mint(to, amount);
        } else {
            MintableERC20(token).mint(to, amount);
        }
    }

    function _transferFrom(address token, address to, uint256 amount) internal {
        if (token == address(usdtLike)) {
            usdtLike.transfer(to, amount);
        } else {
            require(IERC20Like(token).transfer(to, amount), "transfer failed");
        }
    }

    function _fund(address who) internal {
        tokenA.mint(who, 1_000_000e18);
        tokenB.mint(who, 10_000_000e18);
        tokenC.mint(who, 1_000_000e18);
        usdtLike.mint(who, 1_000_000e18);

        vm.startPrank(who);
        tokenA.approve(address(oracle), type(uint256).max);
        tokenB.approve(address(oracle), type(uint256).max);
        tokenA.approve(address(helper), type(uint256).max);
        tokenB.approve(address(helper), type(uint256).max);
        tokenC.approve(address(helper), type(uint256).max);
        usdtLike.approve(address(helper), type(uint256).max);
        usdtLike.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    function _balance(address token, address who) internal view returns (uint256) {
        return token == ETH ? who.balance : IERC20Like(token).balanceOf(who);
    }

    // ────────────────────────────────────────────────────────────────────
    //  oracle games — created only through real report() calls
    // ────────────────────────────────────────────────────────────────────

    function _emptyTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory) {
        return IOpenOracle2.TimingBoundaries({
            blockNumber: 0,
            blockNumberBound: 0,
            blockTimestamp: 0,
            blockTimestampBound: 0
        });
    }

    function _newGame(address token1, address token2) internal returns (Game memory) {
        return _newGame(token1, token2, MULTIPLIER, OLD_AMOUNT_1, OLD_AMOUNT_2);
    }

    function _newGame(address token1, address token2, uint16 multiplier, uint128 amount1, uint128 amount2)
        internal
        returns (Game memory ctx)
    {
        return _newGameConfigured(token1, token2, multiplier, amount1, amount2, FLAG_TIME_TYPE, ESCALATION_HALT);
    }

    function _newGameConfigured(
        address token1,
        address token2,
        uint16 multiplier,
        uint128 amount1,
        uint128 amount2,
        uint8 flags,
        uint128 escalationHalt
    ) internal returns (Game memory ctx) {
        IOpenOracle2.OracleGame memory input;
        input.token1 = token1;
        input.token2 = token2;
        input.feePercentage = FEE_PERCENTAGE;
        input.protocolFee = PROTOCOL_FEE;
        input.multiplier = multiplier;
        input.settlementTime = SETTLEMENT_TIME;
        input.disputeDelay = DISPUTE_DELAY;
        input.escalationHalt = escalationHalt;
        input.settlerReward = SETTLER_REWARD;
        input.protocolFeeRecipient = protocolFeeRecipient;
        input.flags = flags;
        input.currentAmount1 = amount1;
        input.currentAmount2 = amount2;
        input.currentReporter = reporter;

        uint256 value = SETTLER_REWARD;
        if (token1 == ETH) value += amount1;
        if (token2 == ETH) value += amount2;

        uint256 createTs = block.timestamp;
        uint256 createBn = block.number;

        vm.prank(reporter);
        ctx.reportId = oracleI.report{value: value}(input, false, false, _emptyTiming());

        ctx.game = input;
        ctx.game.reportTimestamp = uint48(block.timestamp);
        ctx.game.lastReportOppoTime = uint48(block.number);
        ctx.helper = IOpenOracle2.PreimageHelper({
            reportId: ctx.reportId,
            creator: reporter,
            blockTimestamp: createTs,
            blockNumber: createBn
        });
    }

    /// @dev The next legal token1 amount for a dispute: oldAmount1 * multiplier / 100.
    function _nextAmount1(Game memory ctx) internal pure returns (uint128) {
        return uint128(uint256(ctx.game.currentAmount1) * ctx.game.multiplier / 100);
    }

    function _dd(Game memory ctx, uint128 newAmount1, uint128 newAmount2)
        internal
        pure
        returns (OracleDisputeHelper.DisputeData memory)
    {
        return OracleDisputeHelper.DisputeData({reportId: ctx.reportId, newAmount1: newAmount1, newAmount2: newAmount2});
    }

    /// @notice Drives the helper as `disputer` with `tryInternalBalances = false`.
    /// @dev The default is the purely-external funding path. Every suite outside
    ///      `InternalBalanceFunding.t.sol` uses it, which is what pins that adding the internal
    ///      option changed nothing about the original behaviour.
    function _callDispute(
        Game memory ctx,
        uint128 newAmount1,
        uint128 newAmount2,
        uint256 supplied1,
        uint256 supplied2,
        address routeInputToken,
        uint256 maxSwapInput,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 ethValue
    ) internal {
        _callDisputeWith(
            ctx,
            newAmount1,
            newAmount2,
            supplied1,
            supplied2,
            false,
            routeInputToken,
            maxSwapInput,
            commands,
            inputs,
            ethValue
        );
    }

    /// @notice Single entry point for driving the helper, always as `disputer`.
    /// @dev Every argument is passed straight through; nothing is defaulted silently.
    function _callDisputeWith(
        Game memory ctx,
        uint128 newAmount1,
        uint128 newAmount2,
        uint256 supplied1,
        uint256 supplied2,
        bool tryInternalBalances,
        address routeInputToken,
        uint256 maxSwapInput,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 ethValue
    ) internal {
        _callDisputeWithRouter(
            ctx,
            newAmount1,
            newAmount2,
            supplied1,
            supplied2,
            tryInternalBalances,
            routeInputToken,
            maxSwapInput,
            commands,
            inputs,
            ethValue,
            router
        );
    }

    /// @notice Variant used to exercise the caller-selected router API.
    function _callDisputeWithRouter(
        Game memory ctx,
        uint128 newAmount1,
        uint128 newAmount2,
        uint256 supplied1,
        uint256 supplied2,
        bool tryInternalBalances,
        address routeInputToken,
        uint256 maxSwapInput,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 ethValue,
        address routerChoice
    ) internal {
        vm.prank(disputer);
        helper.disputeWithRoute{value: ethValue}(
            _dd(ctx, newAmount1, newAmount2),
            ctx.game,
            ctx.helper,
            _emptyTiming(),
            supplied1,
            supplied2,
            tryInternalBalances,
            routeInputToken,
            maxSwapInput,
            commands,
            inputs,
            block.timestamp + 1,
            routerChoice
        );
    }

    // ────────────────────────────────────────────────────────────────────
    //  OpenOracle internal balances — created only through real deposits
    // ────────────────────────────────────────────────────────────────────

    /// @dev A real `deposit()`. The oracle credits `amount + 1` on a first deposit, seeding the
    ///      1-unit sentinel, so the SPENDABLE amount afterwards is exactly `amount`.
    function _depositInternal(address who, address token, uint256 amount) internal {
        vm.startPrank(who);
        if (token == ETH) {
            oracle.deposit{value: amount}(ETH, uint128(amount), who);
        } else {
            IERC20Like(token).approve(address(oracle), type(uint256).max);
            oracle.deposit(token, uint128(amount), who);
        }
        vm.stopPrank();
    }

    /// @dev A real `approveInternal()`. The oracle refuses a non-zero -> non-zero change, so this
    ///      always zeroes first.
    function _approveInternal(address who, address token, uint256 amount) internal {
        vm.startPrank(who);
        oracle.approveInternal(address(helper), token, 0);
        if (amount != 0) oracle.approveInternal(address(helper), token, amount);
        vm.stopPrank();
    }

    /// @dev Internal balance minus the 1-unit sentinel, i.e. what the helper may actually draw.
    function _spendable(address who, address token) internal view returns (uint256) {
        uint256 balance = oracle.tokenHolder(who, token);
        return balance > 1 ? balance - 1 : 0;
    }

    /// @notice Asserts the helper is stateless after a call: it must hold none of the tokens it
    ///         touched. This is what makes a correct `_requiredFunding` derivation observable.
    function _assertHelperHoldsNothing(address[] memory tokens) internal view {
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(_balance(tokens[i], address(helper)), 0, "helper retained a balance");
        }
        assertEq(address(helper).balance, 0, "helper retained ETH");
    }

    function _tokens(address a, address b) internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = a;
        t[1] = b;
    }

    function _tokens(address a, address b, address c) internal pure returns (address[] memory t) {
        t = new address[](3);
        t[0] = a;
        t[1] = b;
        t[2] = c;
    }

    // ────────────────────────────────────────────────────────────────────
    //  route encoding — real Universal Router calldata
    // ────────────────────────────────────────────────────────────────────

    /// @dev V2 exact-out. `payerIsUser=false` makes the router pay from its OWN balance, which is
    ///      the only funding shape the helper supports.
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

    function _v3ExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 amountInMax)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        // A V3 exact-output path is encoded in REVERSE: tokenOut, fee, tokenIn.
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

    /// @dev This router revision takes a per-hop minimum-price array as the sixth field of every
    ///      V2/V3 swap input. An empty array disables the check, which is what every route here
    ///      wants: slippage is already bounded by the helper's own funding assertion.
    function _noHopPrices() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    /// @dev SWEEP returns the unspent input token from the router to the helper.
    function _sweep(address token, address recipient, uint256 minAmount) internal pure returns (bytes memory) {
        return abi.encode(token, recipient, minAmount);
    }

    struct PoolKeyLite {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function _poolKey(address a, address b, address hooks) internal pure returns (PoolKeyLite memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKeyLite({currency0: c0, currency1: c1, fee: V4_FEE, tickSpacing: V4_TICK_SPACING, hooks: hooks});
    }

    struct ExactInSingle {
        PoolKeyLite poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @dev Builds a real V4_SWAP command: SWAP_EXACT_IN_SINGLE, SETTLE, TAKE. `payerIsUser=false`
    ///      on SETTLE makes the PoolManager pull from the router's own balance.
    function _v4ExactInSingle(address tokenIn, address tokenOut, uint128 amountIn, uint128 minOut, address hooks)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        PoolKeyLite memory key = _poolKey(tokenIn, tokenOut, hooks);
        bool zeroForOne = tokenIn == key.currency0;

        bytes memory actions = abi.encodePacked(ACTION_SWAP_EXACT_IN_SINGLE, ACTION_SETTLE, ACTION_TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInSingle({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(tokenIn, uint256(amountIn), false);
        // TAKE_ALL, not TAKE: an exact-amount TAKE leaves the surplus credit unsettled and the
        // PoolManager reverts with CurrencyNotSettled. TAKE_ALL credits the router's caller,
        // which is the helper.
        params[2] = abi.encode(tokenOut, uint256(minOut));

        commands = abi.encodePacked(CMD_V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _cat(bytes memory a, bytes memory b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, b);
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

    function _noRoute() internal pure returns (bytes memory commands, bytes[] memory inputs) {
        commands = "";
        inputs = new bytes[](0);
    }

    receive() external payable {}
}

// ── minimal interfaces onto the real, version-pinned deployments ────────

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

interface IV2Factory {
    function createPair(address, address) external returns (address);
    function getPair(address, address) external view returns (address);
}

interface IV2Pair {
    function mint(address) external returns (uint256);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IV3Factory {
    function createPool(address, address, uint24) external returns (address);
    function getPool(address, address, uint24) external view returns (address);
}

interface IV3Pool {
    function initialize(uint160) external;
    function mint(address, int24, int24, uint128, bytes calldata) external returns (uint256, uint256);
}

interface IV4Liquidity {
    function initializePool(address, address, uint24, int24, address, uint160) external;
    function addLiquidity(address, address, uint24, int24, address, int24, int24, int256) external payable;
}

interface IUniversalRouterLike {
    function execute(bytes calldata, bytes[] calldata, uint256) external payable;
}

/// @notice Canonical WETH9 behaviour (deposit/withdraw/transfer), used as the router's WETH9
///         immutable so WRAP_ETH and UNWRAP_WETH exercise real code paths.
contract MockWETH9 {
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
