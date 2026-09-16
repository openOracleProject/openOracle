// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenPuntHelperBase} from "./OpenPuntHelperBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";

/**
 * @notice `_addAsset`: merging up to three obligations into one funding entry per token.
 *
 * @dev When two obligations share a token, the helper deposits their summed requirement once into
 *      its own OpenOracle ledger. OpenPunt then draws the pieces separately:
 *      `internalTransferFrom(funder, matcher, token1, ...)` for
 *      the leg and `internalTransferFrom(funder, punt, collatToken, ...)` for the collateral. So an
 *      aggregation that overwrote instead of adding would not fail in the helper at all: it would
 *      under-deposit and revert later inside `matchSwap`. Every merged case therefore asserts each
 *      economic purpose separately, so a correct net balance cannot hide a reversed or
 *      omitted component.
 *
 *      `assetCount == 1` is unreachable because both entry points add two distinct
 *      oracle tokens and `TokensCannotBeSame` is checked first, so two is the floor.
 *        - 2: collateral equals an oracle token (match), or an ETH oracle leg merges with the ETH
 *             execution-compensation slot (report).
 *        - 3: all three assets distinct (match), or both oracle tokens non-ETH (report).
 *
 *      `reportWithRoute` registers ETH unconditionally, so a report with two ERC20 oracle tokens is
 *      always count 3 even when `executionComp` and `suppliedAmount3` are both zero.
 */
contract AssetAggregationTest is OpenPuntHelperBase {
    function setUp() public override {
        super.setUp();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));
        _approveReporterLegs(designatedReporter, address(tokenA), address(tokenB));
    }

    // ────────────────────────────────────────────────────────────────────
    //  count 3 — everything distinct
    // ────────────────────────────────────────────────────────────────────

    function test_matchWithThreeDistinctAssetsFundsEachSeparately() public {
        Proposal memory p = _propose();

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 b0 = tokenB.balanceOf(funder);
        uint256 c0 = collat.balanceOf(funder);

        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false), 0);

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY, "leg 1");
        assertEq(b0 - tokenB.balanceOf(funder), AMOUNT2, "leg 2");
        assertEq(c0 - collat.balanceOf(funder), INITIAL_MARGIN_MATCHER, "collateral");
        _assertHelperClean();
    }

    // ────────────────────────────────────────────────────────────────────
    //  count 2 — collateral equals an oracle token
    // ────────────────────────────────────────────────────────────────────

    /// @dev collatToken == oracleToken1. The merged entry must require
    ///      `initialLiquidity + initialMarginMatcher`, and the caller must be debited exactly that
    ///      sum in one token. An overwriting `_addAsset` would leave the deposit short by
    ///      whichever component lost, and `matchSwap` would revert.
    function test_collateralEqualToOracleToken1MergesAdditively() public {
        Proposal memory p = _proposeCollat(address(tokenA));

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 b0 = tokenB.balanceOf(funder);

        uint256 combined = uint256(INITIAL_LIQUIDITY) + COLLAT_MARGIN;
        Matched memory mt = _match(p, _noRouteFunding(combined, AMOUNT2, 0, false), 0);

        assertEq(a0 - tokenA.balanceOf(funder), combined, "the merged token1 debit must be the SUM");
        assertEq(b0 - tokenB.balanceOf(funder), AMOUNT2, "leg 2 must be unaffected by the merge");

        // Both purposes independently: the leg reached the oracle game, and the collateral reached
        // OpenPunt as the matcher's margin.
        assertEq(mt.game.currentAmount1, INITIAL_LIQUIDITY, "the oracle leg component was not funded");
        assertEq(mt.swap.initialMarginMatcher, COLLAT_MARGIN, "the collateral component was not recorded");
        assertEq(mt.swap.collatToken, address(tokenA), "collateral token");
        _assertHelperClean();
    }

    /// @dev The same merge declared as two supplied amounts on one token: `_addAsset` sums the
    ///      supplied side as well, so splitting the declaration across `suppliedAmount1` and
    ///      `suppliedAmount3` must be equivalent to declaring the total once.
    function test_theSuppliedSideOfAMergeIsAlsoAdditive() public {
        Proposal memory p = _proposeCollat(address(tokenA));

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 combined = uint256(INITIAL_LIQUIDITY) + COLLAT_MARGIN;

        // Declared as two halves of the same token budget.
        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, COLLAT_MARGIN, false), 0);

        assertEq(a0 - tokenA.balanceOf(funder), combined, "split declaration must equal the combined debit");
    }

    /// @dev collatToken == oracleToken2, the mirror case.
    function test_collateralEqualToOracleToken2MergesAdditively() public {
        Proposal memory p = _proposeCollat(address(tokenB));

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 b0 = tokenB.balanceOf(funder);

        uint256 combined = uint256(AMOUNT2) + COLLAT_MARGIN;
        Matched memory mt = _match(p, _noRouteFunding(INITIAL_LIQUIDITY, combined, 0, false), 0);

        assertEq(b0 - tokenB.balanceOf(funder), combined, "the merged token2 debit must be the SUM");
        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY, "leg 1 must be unaffected by the merge");
        assertEq(mt.game.currentAmount2, AMOUNT2, "the oracle leg component was not funded");
        assertEq(mt.swap.initialMarginMatcher, COLLAT_MARGIN, "the collateral component was not recorded");
        _assertHelperClean();
    }

    /// @dev A merged entry that is one wei short must fail, which is what proves the requirement
    ///      really is the sum rather than either component.
    function test_aMergedEntryOneWeiShortIsRejected() public {
        Proposal memory p = _proposeCollat(address(tokenA));
        uint256 combined = uint256(INITIAL_LIQUIDITY) + COLLAT_MARGIN;

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMaximumSwapInput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(combined - 1, AMOUNT2, 0, false),
            router
        );
    }

    /// @dev Supplying only the larger component is likewise insufficient — the classic symptom of
    ///      an overwriting merge.
    function test_supplyingOnlyTheLargerComponentIsRejected() public {
        Proposal memory p = _proposeCollat(address(tokenA));

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMaximumSwapInput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(COLLAT_MARGIN, AMOUNT2, 0, false),
            router
        );
    }

    // ────────────────────────────────────────────────────────────────────
    //  count 2 on a report — ETH oracle leg merges with the comp slot
    // ────────────────────────────────────────────────────────────────────

    /// @dev With oracleToken2 == ETH the report's unconditional ETH entry merges with the ETH
    ///      oracle leg, so one ETH budget must cover `amount2 + executionComp` and msg.value must
    ///      equal that sum. This is the reachable `assetCount == 2` shape on a report.
    ///
    ///      The legs are 1e18 / 1e18 with `priceTolerated = 1e30`, matching the affordable-ETH-leg
    ///      pattern because the default 2000e18 token2 leg is impractical to fund in native ETH.
    function test_ethOracleLegMergesWithExecutionCompensation() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openEthLegPosition();

        uint256 combined = uint256(ETH_LEG_AMOUNT2) + REPORT_EXEC_COMP;
        uint256 e0 = funder.balance;

        vm.recordLogs();
        vm.prank(funder);
        helper.reportWithRoute{value: combined}(
            sid,
            bytes32(0),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            ETH_LEG_AMOUNT1,
            ETH_LEG_AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(ETH_LEG_AMOUNT1, 0, combined, false),
            router
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        OpenPuntStorage.MatchedSwap memory rep =
            _decodeSingleSwapState(logs, OpenPuntStorage.PositionReportStarted.selector, sid);
        uint256 reportId = punt.swapIdToReportId(sid);
        (IOpenOracle2.OracleGame memory game, IOpenOracle2.PreimageHelper memory gh) =
            _decodeReportSubmitted(logs, reportId);

        // Both ETH purposes independently: the oracle leg is in the game, and the compensation is
        // escrowed against the report. A merged entry that dropped either would still net out.
        assertEq(e0 - funder.balance, combined, "the merged ETH debit must be the SUM of leg and comp");
        assertEq(game.currentAmount2, ETH_LEG_AMOUNT2, "the ETH oracle leg component was not funded");
        assertEq(punt.executionGasComp(reportId), REPORT_EXEC_COMP, "the compensation component was not escrowed");

        // Settle and execute the genuine game.
        _advanceToSettlementEligibility();
        vm.prank(closeExecutor);
        puntLifecycle.execute(sid, rep, game, gh, 0);

        assertEq(punt.executionGasComp(reportId), 0, "the compensation was not consumed");
        assertEq(address(helper).balance, 0, "helper retained ETH");
        assertLe(oracle.tokenHolder(address(helper), ETH_ASSET), 1, "only the oracle sentinel may remain");
    }

    /// @dev One wei short of the merged ETH requirement is rejected.
    function test_theMergedEthEntryRejectsAShortBudget() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openEthLegPosition();

        uint256 combined = uint256(ETH_LEG_AMOUNT2) + REPORT_EXEC_COMP;

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMaximumSwapInput.selector);
        helper.reportWithRoute{value: combined - 1}(
            sid,
            bytes32(0),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            ETH_LEG_AMOUNT1,
            ETH_LEG_AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(ETH_LEG_AMOUNT1, 0, combined - 1, false),
            router
        );
    }

    // ────────────────────────────────────────────────────────────────────
    //  the merged entry is one route budget, not two
    // ────────────────────────────────────────────────────────────────────

    /// @dev With collateral merged into token1, a route whose input is token1 draws its budget from
    ///      the combined surplus: `supplied - (leg + collateral)`. Asking for one wei more is
    ///      rejected, which pins that `_suppliedSurplus` reads the merged requirement rather than
    ///      either component alone.
    ///
    ///      The surplus must comfortably exceed the 2000e18 token2 leg it buys at 1:1, or the
    ///      exact-output swap reverts with the router's own `V2TooMuchRequested()` before the
    ///      helper's cap is ever the binding constraint.
    function test_routeBudgetOnAMergedTokenUsesTheCombinedSurplus() public {
        Proposal memory p = _proposeCollat(address(tokenA));

        uint256 combined = uint256(INITIAL_LIQUIDITY) + COLLAT_MARGIN;
        uint256 surplus = 4000e18;

        (bytes memory over, bytes[] memory overIn) = _v2ExactOut(address(tokenA), address(tokenB), AMOUNT2, surplus + 1);

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMaximumSwapInput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(combined + surplus, 0, 0, false, address(tokenA), surplus + 1, over, overIn),
            router
        );

        // Exactly the combined surplus is accepted and buys the token2 leg.
        (bytes memory ok, bytes[] memory okIn) = _v2ExactOut(address(tokenA), address(tokenB), AMOUNT2, surplus);
        (bytes memory okc, bytes[] memory okin) = _withSweep(ok, okIn, address(tokenA));

        uint256 b0 = tokenB.balanceOf(funder);

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(combined + surplus, 0, 0, false, address(tokenA), surplus, okc, okin),
            router
        );

        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the merged-surplus route should have matched");
        assertEq(tokenB.balanceOf(funder), b0, "the token2 leg must have come from the route");
        _assertHelperClean();
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    uint128 internal constant COLLAT_MARGIN = 800e18;
    /// @dev Returns affordable native oracle legs with a matching expected price.
    uint128 internal constant ETH_LEG_AMOUNT1 = 1e18;
    uint128 internal constant ETH_LEG_AMOUNT2 = 1e18;

    /// @dev A proposal whose collateral token is `token`, built through the real `propose`.
    function _proposeCollat(address token) internal returns (Proposal memory) {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.collatToken = token;
        s.initialMarginSwapper = COLLAT_MARGIN;
        s.initialMarginMatcher = COLLAT_MARGIN;
        s.maintenanceMarginSwapper = 150e18;
        s.notional = 8000e18;

        // The swapper pays its own margin in this token, so give it the balance and approval.
        MintableERC20Like(token).mint(swapper, 1_000_000e18);
        vm.prank(swapper);
        MintableERC20Like(token).approve(PERMIT2, type(uint256).max);

        return _proposeWith(s, _defaultMatcherPreimage(), swapper);
    }

    /// @dev A live position whose oracleToken2 is native ETH, so a later report merges that leg
    ///      with the execution-compensation slot.
    function _openEthLegPosition()
        internal
        returns (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre)
    {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.oracleToken2 = ETH_ASSET;
        s.priceTolerated = 1e30; // 1e18 / 1e18 legs

        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();
        m.initialLiquidity = ETH_LEG_AMOUNT1;

        Proposal memory p = _proposeWith(s, m, swapper);
        pre = p.preimage;

        // The default matcher funds this one directly; ETH legs need an ETH internal balance.
        _depositInternal(matcher, ETH_ASSET, 10 ether);
        vm.prank(matcher);
        oracle.approveInternal(address(punt), ETH_ASSET, type(uint256).max);
        _approveReporterLegs(designatedReporter, address(tokenA), ETH_ASSET);

        vm.recordLogs();
        vm.prank(matcher);
        punt.matchSwap(p.swapId, ETH_LEG_AMOUNT2, p.swap, p.preimage, _noTiming(), matcher);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Matched memory mt;
        mt.swapId = p.swapId;
        (mt.reportId, mt.swap) = _decodeSwapMatched(logs, p.swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);

        _advanceToSettlementEligibility();
        live = _executeOpening(mt, executor);
        sid = p.swapId;
    }

    function _match(Proposal memory p, OpenPuntHelper.RouteFunding memory route, uint256 value)
        internal
        returns (Matched memory mt)
    {
        vm.recordLogs();
        vm.prank(funder);
        helper.matchWithRoute{value: value}(
            p.swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), designatedMatcher, route, router
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        mt.swapId = p.swapId;
        (mt.reportId, mt.swap) = _decodeSwapMatched(logs, p.swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);
    }

    function _assertHelperClean() internal view {
        assertEq(tokenA.balanceOf(address(helper)), 0, "helper retained token1");
        assertEq(tokenB.balanceOf(address(helper)), 0, "helper retained token2");
        assertEq(collat.balanceOf(address(helper)), 0, "helper retained collateral");
        assertEq(tokenC.balanceOf(address(helper)), 0, "helper retained route input");
        assertEq(address(helper).balance, 0, "helper retained ETH");
        assertLe(oracle.tokenHolder(address(helper), address(tokenA)), 1, "helper retained internal token1");
        assertLe(oracle.tokenHolder(address(helper), address(tokenB)), 1, "helper retained internal token2");
        assertLe(oracle.tokenHolder(address(helper), address(collat)), 1, "helper retained internal collateral");
        assertLe(oracle.tokenHolder(address(helper), address(tokenC)), 1, "helper retained internal route input");
        assertLe(oracle.tokenHolder(address(helper), ETH_ASSET), 1, "helper retained internal ETH");
    }
}

interface MintableERC20Like {
    function mint(address, uint256) external;
    function approve(address, uint256) external returns (bool);
}
