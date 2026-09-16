// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {OpenPuntBase} from "../../test/openPunt/OpenPuntBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";

/**
 * @notice Pinned Base-fork coverage for the caller-selected-router boundary shared by
 *         OpenPuntHelper and OracleDisputeHelper.
 *
 * @dev Set BASE_RPC_URL to run this file. The fork supplies only deployed routers, tokens, and
 *      pool liquidity; the current Oracle, OpenPunt, lifecycle, and both helpers are deployed
 *      locally. User balances are test-funded, but every route crosses a real Base pool.
 *
 *      Uniswap uses the deployed Universal Router and its WETH/USDC 0.05% pool. Aerodrome uses
 *      its deployed Universal Router and the high-volume NVDAc/USDC 0.115% factory-3 pool. The
 *      factory-3 selector is deliberately encoded in the path, so this catches both a stale
 *      router deployment and an incorrect Slipstream-factory choice.
 *
 *      Base executes B20 token accounts natively even though eth_getCode returns only 0xef.
 *      Foundry's local EVM cannot execute that chain-native hook. The setup therefore installs
 *      ordinary ERC20 transfer semantics at the NVDAc address and seeds the pool with its exact
 *      NVDAc balance at BASE_FORK_BLOCK. The Aerodrome router, factory selection, pool bytecode,
 *      concentrated-liquidity state, price, ticks, USDC inventory, and swap callback are all the
 *      pinned live Base state; only the B20 token-account execution shim is local.
 */
contract BaseRouterHelpersForkTest is OpenPuntBase {
    uint256 internal constant BASE_FORK_BLOCK = 51_339_594;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;

    address internal constant UNISWAP_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant UNISWAP_WETH_USDC_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    uint24 internal constant UNISWAP_FEE = 500;

    address internal constant AERODROME_ROUTER = 0xC5b6786D7B64767D775877b0B6A319AD946B11B5;
    address internal constant AERODROME_PERMIT2 = 0x494bbD8A3302AcA833D307D11838f18DbAdA9C25;
    address internal constant AERODROME_NVDAC_USDC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;
    uint24 internal constant AERODROME_FACTORY_3_FLAG = 0x080000;
    uint24 internal constant AERODROME_TICK_SPACING = 10;
    uint256 internal constant PINNED_NVDAC_POOL_BALANCE = 780_942_399_291;

    bytes32 internal constant CL_SWAP_TOPIC =
        keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)");

    uint128 internal constant FORK_SWAPPER_MARGIN = 10e6;
    uint128 internal constant FORK_MATCHER_MARGIN = 10e6;
    uint128 internal constant FORK_MAINTENANCE_MARGIN = 2e6;
    uint128 internal constant FORK_NOTIONAL = 100e6;

    uint128 internal constant WETH_LIQUIDITY = 0.001 ether;
    uint128 internal constant WETH_QUOTE = 2.5e6;
    uint128 internal constant NVDAC_LIQUIDITY = 10_000_000; // 0.1 NVDAc at 8 decimals
    uint128 internal constant NVDAC_QUOTE = 22e6;

    address internal routeFunder = address(0xF001);
    address internal routeMatcher = address(0xF002);
    address internal routeReporter = address(0xF003);
    address internal routeDisputer = address(0xF004);

    OpenPuntHelper internal routeHelper;
    OracleDisputeHelper internal disputeHelper;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL is not set");
            return;
        }

        vm.createSelectFork(rpc, BASE_FORK_BLOCK);
        _deploySystem();

        // See the contract-level Foundry/B20 note. Reuse the suite's standard ERC20 runtime and
        // preserve the live pool's exact raw-token inventory at the pinned block.
        vm.etch(NVDAC, address(tokenA).code);
        deal(NVDAC, AERODROME_NVDAC_USDC_POOL, PINNED_NVDAC_POOL_BALANCE, true);

        routeHelper = new OpenPuntHelper(address(punt));
        disputeHelper = new OracleDisputeHelper(address(oracle));

        vm.deal(swapper, 10 ether);
        vm.deal(routeFunder, 20 ether);
        vm.deal(routeMatcher, 2 ether);
        vm.deal(routeReporter, 20 ether);
        vm.deal(routeDisputer, 20 ether);

        deal(USDC, swapper, 10_000e6, true);
        deal(USDC, routeFunder, 100_000e6, true);
        deal(USDC, routeReporter, 100_000e6, true);
        deal(USDC, routeDisputer, 100_000e6, true);
        deal(NVDAC, routeFunder, 100e8, true);
        deal(NVDAC, routeReporter, 100e8, true);

        vm.prank(routeFunder);
        IWETHFork(WETH).deposit{value: 10 ether}();
        vm.prank(routeReporter);
        IWETHFork(WETH).deposit{value: 10 ether}();

        vm.prank(swapper);
        IERC20Fork(USDC).approve(PERMIT2, type(uint256).max);

        _approveExternal(routeFunder, USDC, address(routeHelper));
        _approveExternal(routeFunder, WETH, address(routeHelper));
        _approveExternal(routeFunder, NVDAC, address(routeHelper));

        _approveExternal(routeReporter, USDC, address(oracle));
        _approveExternal(routeReporter, WETH, address(oracle));
        _approveExternal(routeReporter, NVDAC, address(oracle));

        _approveExternal(routeDisputer, USDC, address(disputeHelper));
        _approveExternal(routeDisputer, WETH, address(disputeHelper));
        _approveExternal(routeDisputer, NVDAC, address(disputeHelper));

        _approvePuntInternal(routeMatcher, WETH);
        _approvePuntInternal(routeMatcher, USDC);
        _approvePuntInternal(routeMatcher, NVDAC);
        _approvePuntInternal(routeReporter, WETH);
        _approvePuntInternal(routeReporter, USDC);
        _approvePuntInternal(routeReporter, NVDAC);
    }

    function test_uniswapMatch_exactOutputRefundsUnusedInputAndUsesExpectedPool() public {
        Proposal memory p = _forkProposal(WETH, USDC, WETH_LIQUIDITY, WETH_QUOTE);
        uint256 maxInput = 10e6;
        (bytes memory commands, bytes[] memory inputs) =
            _uniswapExactOutput(USDC, WETH, WETH_LIQUIDITY, maxInput, address(routeHelper));

        uint256 funderBefore = IERC20Fork(USDC).balanceOf(routeFunder);
        uint256 routerBefore = IERC20Fork(USDC).balanceOf(UNISWAP_ROUTER);

        (Matched memory mt, Vm.Log[] memory logs) = _matchWithRoute(
            p,
            WETH_QUOTE,
            _funding(
                0,
                uint256(WETH_QUOTE) + maxInput,
                FORK_MATCHER_MARGIN,
                USDC,
                maxInput,
                commands,
                inputs
            ),
            UNISWAP_ROUTER
        );

        _assertPoolSwap(logs, UNISWAP_WETH_USDC_POOL);
        assertEq(mt.swap.matcher, routeMatcher, "wrong matched counterparty");
        assertEq(mt.game.currentReporter, routeMatcher, "wrong opening reporter");
        assertGt(funderBefore - IERC20Fork(USDC).balanceOf(routeFunder), WETH_QUOTE + FORK_MATCHER_MARGIN);
        assertLt(funderBefore - IERC20Fork(USDC).balanceOf(routeFunder), WETH_QUOTE + FORK_MATCHER_MARGIN + maxInput);
        assertEq(IERC20Fork(USDC).balanceOf(UNISWAP_ROUTER), routerBefore, "unused input not swept");
        _assertNoRouteApprovals(address(routeHelper), USDC, UNISWAP_ROUTER, PERMIT2);
    }

    function test_aerodromeMatch_exactInputRefundsSurplusOutputAndUsesFactory3Pool() public {
        Proposal memory p = _forkProposal(NVDAC, USDC, NVDAC_LIQUIDITY, NVDAC_QUOTE);
        uint256 routeInput = 30e6;
        (bytes memory commands, bytes[] memory inputs) =
            _aerodromeExactInput(USDC, NVDAC, routeInput, NVDAC_LIQUIDITY, address(routeHelper));

        uint256 nvdaBefore = IERC20Fork(NVDAC).balanceOf(routeFunder);
        (Matched memory mt, Vm.Log[] memory logs) = _matchWithRoute(
            p,
            NVDAC_QUOTE,
            _funding(
                0,
                uint256(NVDAC_QUOTE) + routeInput,
                FORK_MATCHER_MARGIN,
                USDC,
                routeInput,
                commands,
                inputs
            ),
            AERODROME_ROUTER
        );

        _assertPoolSwap(logs, AERODROME_NVDAC_USDC_POOL);
        assertEq(mt.swap.matcher, routeMatcher, "wrong matched counterparty");
        assertEq(mt.game.currentReporter, routeMatcher, "wrong opening reporter");
        assertGt(IERC20Fork(NVDAC).balanceOf(routeFunder), nvdaBefore, "surplus output not refunded");
        _assertNoRouteApprovals(address(routeHelper), USDC, AERODROME_ROUTER, AERODROME_PERMIT2);
    }

    function test_aerodromeMatch_exactOutputRefundsUnusedInputAndUsesFactory3Pool() public {
        Proposal memory p = _forkProposal(NVDAC, USDC, NVDAC_LIQUIDITY, NVDAC_QUOTE);
        uint256 maxInput = 30e6;
        (bytes memory commands, bytes[] memory inputs) =
            _aerodromeExactOutput(USDC, NVDAC, NVDAC_LIQUIDITY, maxInput, address(routeHelper));

        uint256 funderBefore = IERC20Fork(USDC).balanceOf(routeFunder);
        uint256 routerBefore = IERC20Fork(USDC).balanceOf(AERODROME_ROUTER);

        (Matched memory mt, Vm.Log[] memory logs) = _matchWithRoute(
            p,
            NVDAC_QUOTE,
            _funding(
                0,
                uint256(NVDAC_QUOTE) + maxInput,
                FORK_MATCHER_MARGIN,
                USDC,
                maxInput,
                commands,
                inputs
            ),
            AERODROME_ROUTER
        );

        _assertPoolSwap(logs, AERODROME_NVDAC_USDC_POOL);
        assertEq(mt.swap.matcher, routeMatcher, "wrong matched counterparty");
        assertEq(mt.game.currentReporter, routeMatcher, "wrong opening reporter");
        uint256 spent = funderBefore - IERC20Fork(USDC).balanceOf(routeFunder);
        assertGt(spent, NVDAC_QUOTE + FORK_MATCHER_MARGIN, "route consumed no input");
        assertLt(spent, NVDAC_QUOTE + FORK_MATCHER_MARGIN + maxInput, "unused input not refunded");
        assertEq(IERC20Fork(USDC).balanceOf(AERODROME_ROUTER), routerBefore, "unused input not swept");
        _assertNoRouteApprovals(address(routeHelper), USDC, AERODROME_ROUTER, AERODROME_PERMIT2);
    }

    function test_uniswapReport_routesAgainstLivePoolAndAttributesReporter() public {
        (Proposal memory p, OpenPuntStorage.MatchedSwap memory active) =
            _openDirect(WETH, USDC, WETH_LIQUIDITY, WETH_QUOTE);
        uint256 maxInput = 10e6;
        (bytes memory commands, bytes[] memory inputs) =
            _uniswapExactOutput(USDC, WETH, WETH_LIQUIDITY, maxInput, address(routeHelper));

        (Matched memory reportCtx, Vm.Log[] memory logs) = _reportWithRoute(
            p,
            active,
            WETH_LIQUIDITY,
            WETH_QUOTE,
            _funding(0, uint256(WETH_QUOTE) + maxInput, 0, USDC, maxInput, commands, inputs),
            UNISWAP_ROUTER
        );

        _assertPoolSwap(logs, UNISWAP_WETH_USDC_POOL);
        assertEq(reportCtx.game.currentReporter, routeReporter, "wrong active-report reporter");
        assertEq(punt.swapIdToReportId(p.swapId), reportCtx.reportId, "report not attached to position");
        _assertNoRouteApprovals(address(routeHelper), USDC, UNISWAP_ROUTER, PERMIT2);
    }

    function test_aerodromeReport_routesAgainstLiveFactory3PoolAndAttributesReporter() public {
        (Proposal memory p, OpenPuntStorage.MatchedSwap memory active) =
            _openDirect(NVDAC, USDC, NVDAC_LIQUIDITY, NVDAC_QUOTE);
        uint256 routeInput = 30e6;
        (bytes memory commands, bytes[] memory inputs) =
            _aerodromeExactInput(USDC, NVDAC, routeInput, NVDAC_LIQUIDITY, address(routeHelper));

        uint256 funderNvdaBefore = IERC20Fork(NVDAC).balanceOf(routeFunder);
        (Matched memory reportCtx, Vm.Log[] memory logs) = _reportWithRoute(
            p,
            active,
            NVDAC_LIQUIDITY,
            NVDAC_QUOTE,
            _funding(0, uint256(NVDAC_QUOTE) + routeInput, 0, USDC, routeInput, commands, inputs),
            AERODROME_ROUTER
        );

        _assertPoolSwap(logs, AERODROME_NVDAC_USDC_POOL);
        assertEq(reportCtx.game.currentReporter, routeReporter, "wrong active-report reporter");
        assertEq(punt.swapIdToReportId(p.swapId), reportCtx.reportId, "report not attached to position");
        assertGt(IERC20Fork(NVDAC).balanceOf(routeFunder), funderNvdaBefore, "surplus output not refunded");
        _assertNoRouteApprovals(address(routeHelper), USDC, AERODROME_ROUTER, AERODROME_PERMIT2);
    }

    function test_uniswapDispute_routesAgainstLivePoolAndFundsOracle() public {
        OracleContext memory ctx = _newOracleGame(WETH, USDC, WETH_LIQUIDITY, WETH_QUOTE);
        uint128 newAmount1 = uint128(uint256(WETH_LIQUIDITY) * 110 / 100);
        uint256 required1 = uint256(newAmount1) + WETH_LIQUIDITY + uint256(WETH_LIQUIDITY) * 4_000 / 1e7;
        uint256 maxInput = 10e6;
        (bytes memory commands, bytes[] memory inputs) =
            _uniswapExactOutput(USDC, WETH, required1, maxInput, address(disputeHelper));

        uint256 oracleWethBefore = IERC20Fork(WETH).balanceOf(address(oracle));
        vm.recordLogs();
        vm.prank(routeDisputer);
        disputeHelper.disputeWithRoute(
            OracleDisputeHelper.DisputeData(ctx.reportId, newAmount1, WETH_QUOTE),
            ctx.game,
            ctx.helper,
            _noTiming(),
            0,
            maxInput,
            false,
            USDC,
            maxInput,
            commands,
            inputs,
            block.timestamp + 1,
            UNISWAP_ROUTER
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertPoolSwap(logs, UNISWAP_WETH_USDC_POOL);
        assertEq(IERC20Fork(WETH).balanceOf(address(oracle)) - oracleWethBefore, required1, "oracle funding delta");
        _assertDisputedState(ctx, newAmount1, WETH_QUOTE);
        _assertNoRouteApprovals(address(disputeHelper), USDC, UNISWAP_ROUTER, PERMIT2);
    }

    function test_aerodromeDispute_routesAgainstLiveFactory3PoolAndFundsOracle() public {
        OracleContext memory ctx = _newOracleGame(NVDAC, USDC, NVDAC_LIQUIDITY, NVDAC_QUOTE);
        uint128 newAmount1 = uint128(uint256(NVDAC_LIQUIDITY) * 110 / 100);
        uint256 required1 = uint256(newAmount1) + NVDAC_LIQUIDITY + uint256(NVDAC_LIQUIDITY) * 4_000 / 1e7;
        uint256 routeInput = 60e6;
        (bytes memory commands, bytes[] memory inputs) =
            _aerodromeExactInput(USDC, NVDAC, routeInput, required1, address(disputeHelper));

        uint256 oracleNvdaBefore = IERC20Fork(NVDAC).balanceOf(address(oracle));
        uint256 disputerNvdaBefore = IERC20Fork(NVDAC).balanceOf(routeDisputer);
        vm.recordLogs();
        vm.prank(routeDisputer);
        disputeHelper.disputeWithRoute(
            OracleDisputeHelper.DisputeData(ctx.reportId, newAmount1, NVDAC_QUOTE),
            ctx.game,
            ctx.helper,
            _noTiming(),
            0,
            routeInput,
            false,
            USDC,
            routeInput,
            commands,
            inputs,
            block.timestamp + 1,
            AERODROME_ROUTER
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertPoolSwap(logs, AERODROME_NVDAC_USDC_POOL);
        assertEq(IERC20Fork(NVDAC).balanceOf(address(oracle)) - oracleNvdaBefore, required1, "oracle funding delta");
        assertGt(IERC20Fork(NVDAC).balanceOf(routeDisputer), disputerNvdaBefore, "surplus output not refunded");
        _assertDisputedState(ctx, newAmount1, NVDAC_QUOTE);
        _assertNoRouteApprovals(address(disputeHelper), USDC, AERODROME_ROUTER, AERODROME_PERMIT2);
    }

    function test_aerodromeUnderDelivery_revertsPoolRouterFundingAndProposalAtomically() public {
        uint128 impossibleLiquidity = 1 ether;
        Proposal memory p = _forkProposal(NVDAC, USDC, impossibleLiquidity, NVDAC_QUOTE);
        uint256 routeInput = 1e6;
        (bytes memory commands, bytes[] memory inputs) =
            _aerodromeExactInput(USDC, NVDAC, routeInput, 0, address(routeHelper));

        bytes32 proposalBefore = punt.swaps(p.swapId);
        uint256 funderUsdcBefore = IERC20Fork(USDC).balanceOf(routeFunder);
        uint256 poolUsdcBefore = IERC20Fork(USDC).balanceOf(AERODROME_NVDAC_USDC_POOL);
        uint256 poolNvdaBefore = IERC20Fork(NVDAC).balanceOf(AERODROME_NVDAC_USDC_POOL);

        vm.prank(routeFunder);
        vm.expectRevert(OpenPuntHelper.InsufficientRouterOutput.selector);
        routeHelper.matchWithRoute(
            p.swapId,
            NVDAC_QUOTE,
            p.swap,
            p.preimage,
            _noTiming(),
            routeMatcher,
            _funding(
                0,
                uint256(NVDAC_QUOTE) + routeInput,
                FORK_MATCHER_MARGIN,
                USDC,
                routeInput,
                commands,
                inputs
            ),
            AERODROME_ROUTER
        );

        assertEq(punt.swaps(p.swapId), proposalBefore, "proposal changed");
        assertEq(IERC20Fork(USDC).balanceOf(routeFunder), funderUsdcBefore, "caller input changed");
        assertEq(IERC20Fork(USDC).balanceOf(AERODROME_NVDAC_USDC_POOL), poolUsdcBefore, "pool USDC changed");
        assertEq(IERC20Fork(NVDAC).balanceOf(AERODROME_NVDAC_USDC_POOL), poolNvdaBefore, "pool NVDAc changed");
        _assertNoRouteApprovals(address(routeHelper), USDC, AERODROME_ROUTER, AERODROME_PERMIT2);
    }

    struct OracleContext {
        uint256 reportId;
        IOpenOracle2.OracleGame game;
        IOpenOracle2.PreimageHelper helper;
    }

    function _forkProposal(address token1, address token2, uint128 amount1, uint128 amount2)
        internal
        returns (Proposal memory p)
    {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.collatToken = USDC;
        s.oracleToken1 = token1;
        s.oracleToken2 = token2;
        s.initialMarginSwapper = FORK_SWAPPER_MARGIN;
        s.initialMarginMatcher = FORK_MATCHER_MARGIN;
        s.maintenanceMarginSwapper = FORK_MAINTENANCE_MARGIN;
        s.notional = FORK_NOTIONAL;
        s.priceTolerated = uint232(uint256(amount1) * 1e30 / amount2);
        s.toleranceRange = 1e6;
        s.maxDisputeCostPerToken1 = 0;

        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();
        m.initialLiquidity = amount1;
        m.escalationHalt = amount1 * 20;

        p = _proposeWith(s, m, swapper);
    }

    function _matchWithRoute(
        Proposal memory p,
        uint128 amount2,
        OpenPuntHelper.RouteFunding memory funding,
        address chosenRouter
    ) internal returns (Matched memory mt, Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(routeFunder);
        routeHelper.matchWithRoute(
            p.swapId, amount2, p.swap, p.preimage, _noTiming(), routeMatcher, funding, chosenRouter
        );
        logs = vm.getRecordedLogs();

        mt.swapId = p.swapId;
        (mt.reportId, mt.swap) = _decodeSwapMatched(logs, p.swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);
    }

    function _openDirect(address token1, address token2, uint128 amount1, uint128 amount2)
        internal
        returns (Proposal memory p, OpenPuntStorage.MatchedSwap memory active)
    {
        p = _forkProposal(token1, token2, amount1, amount2);
        (Matched memory mt,) = _matchWithRoute(
            p,
            amount2,
            _funding(amount1, amount2, FORK_MATCHER_MARGIN, USDC, 0, "", new bytes[](0)),
            address(0)
        );
        _advanceToSettlementEligibility();
        active = _executeOpening(mt, executor);
    }

    function _reportWithRoute(
        Proposal memory p,
        OpenPuntStorage.MatchedSwap memory active,
        uint128 amount1,
        uint128 amount2,
        OpenPuntHelper.RouteFunding memory funding,
        address chosenRouter
    ) internal returns (Matched memory mt, Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(routeFunder);
        routeHelper.reportWithRoute(
            p.swapId,
            bytes32(0),
            active,
            p.preimage,
            _noTiming(),
            routeReporter,
            amount1,
            amount2,
            0,
            funding,
            chosenRouter
        );
        logs = vm.getRecordedLogs();

        mt.swapId = p.swapId;
        mt.swap = _decodeSingleSwapState(logs, OpenPuntStorage.PositionReportStarted.selector, p.swapId);
        mt.reportId = punt.swapIdToReportId(p.swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);
    }

    function _newOracleGame(address token1, address token2, uint128 amount1, uint128 amount2)
        internal
        returns (OracleContext memory ctx)
    {
        IOpenOracle2.OracleGame memory game;
        game.currentAmount1 = amount1;
        game.currentAmount2 = amount2;
        game.currentReporter = routeReporter;
        game.token1 = token1;
        game.token2 = token2;
        game.settlementTime = 300;
        game.escalationHalt = amount1 * 20;
        game.disputeDelay = 0;
        game.feePercentage = 4_000;
        game.multiplier = 110;
        game.flags = ORACLE_FLAG_TIME_TYPE;

        uint256 createTimestamp = block.timestamp;
        uint256 createBlock = block.number;
        vm.prank(routeReporter);
        ctx.reportId = IOpenOracle2(address(oracle)).report(game, false, false, _noTiming());

        game.reportTimestamp = uint48(block.timestamp);
        game.lastReportOppoTime = uint48(block.number);
        ctx.game = game;
        ctx.helper = IOpenOracle2.PreimageHelper(ctx.reportId, routeReporter, createTimestamp, createBlock);
        assertEq(oracle.oracleGame(ctx.reportId), keccak256(abi.encode(ctx.game, ctx.helper)), "bad initial game fixture");
    }

    function _assertDisputedState(OracleContext memory ctx, uint128 newAmount1, uint128 newAmount2) internal view {
        IOpenOracle2.OracleGame memory expected = ctx.game;
        expected.currentAmount1 = newAmount1;
        expected.currentAmount2 = newAmount2;
        expected.currentReporter = routeDisputer;
        expected.reportTimestamp = uint48(block.timestamp);
        expected.lastReportOppoTime = uint48(block.number);
        assertEq(
            oracle.oracleGame(ctx.reportId),
            keccak256(abi.encode(expected, ctx.helper)),
            "disputer attribution or oracle state mismatch"
        );
    }

    function _funding(
        uint256 supplied1,
        uint256 supplied2,
        uint256 supplied3,
        address inputToken,
        uint256 maxInput,
        bytes memory commands,
        bytes[] memory inputs
    ) internal view returns (OpenPuntHelper.RouteFunding memory) {
        return OpenPuntHelper.RouteFunding({
            suppliedAmount1: supplied1,
            suppliedAmount2: supplied2,
            suppliedAmount3: supplied3,
            tryInternalBalances: false,
            inputToken: inputToken,
            maxSwapInput: maxInput,
            commands: commands,
            inputs: inputs,
            deadline: block.timestamp + 1
        });
    }

    function _uniswapExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMaximum,
        address recipient
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        commands = abi.encodePacked(bytes1(uint8(0x01)), bytes1(uint8(0x04)));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(
            recipient,
            amountOut,
            amountInMaximum,
            abi.encodePacked(tokenOut, UNISWAP_FEE, tokenIn),
            false
        );
        inputs[1] = abi.encode(tokenIn, recipient, uint256(0));
    }

    function _aerodromeExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        commands = abi.encodePacked(bytes1(uint8(0x00)));
        inputs = new bytes[](1);
        uint24 poolParam = AERODROME_FACTORY_3_FLAG | AERODROME_TICK_SPACING;
        inputs[0] = abi.encode(
            recipient,
            amountIn,
            amountOutMinimum,
            abi.encodePacked(tokenIn, poolParam, tokenOut),
            false,
            false
        );
    }

    function _aerodromeExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMaximum,
        address recipient
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        commands = abi.encodePacked(bytes1(uint8(0x01)), bytes1(uint8(0x04)));
        inputs = new bytes[](2);
        uint24 poolParam = AERODROME_FACTORY_3_FLAG | AERODROME_TICK_SPACING;
        inputs[0] = abi.encode(
            recipient,
            amountOut,
            amountInMaximum,
            abi.encodePacked(tokenOut, poolParam, tokenIn),
            false,
            false
        );
        inputs[1] = abi.encode(tokenIn, recipient, uint256(0));
    }

    function _approveExternal(address owner, address token, address spender) internal {
        vm.prank(owner);
        IERC20Fork(token).approve(spender, type(uint256).max);
    }

    function _approvePuntInternal(address owner, address token) internal {
        vm.prank(owner);
        oracle.approveInternal(address(punt), token, type(uint256).max);
    }

    function _assertNoRouteApprovals(address owner, address token, address chosenRouter, address routerPermit2)
        internal
        view
    {
        assertEq(IERC20Fork(token).allowance(owner, chosenRouter), 0, "router allowance granted");
        assertEq(IERC20Fork(token).allowance(owner, routerPermit2), 0, "Permit2 allowance granted");
    }

    function _assertPoolSwap(Vm.Log[] memory logs, address expectedPool) internal pure {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == expectedPool && logs[i].topics.length != 0 && logs[i].topics[0] == CL_SWAP_TOPIC) {
                return;
            }
        }
        revert("expected live pool did not emit Swap");
    }
}

interface IERC20Fork {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWETHFork is IERC20Fork {
    function deposit() external payable;
}
