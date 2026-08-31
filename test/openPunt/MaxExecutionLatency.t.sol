// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LivenessBase.t.sol";

/**
 * @notice The active-position execution deadline, in wall-clock seconds:
 *
 *     lastReportOppoTime + floor(settlementTime * millisecondsPerBlock / 1000) + maxExecutionLatency
 *
 * @dev In block mode, `settlementTime` is a block count and the game's wall clock is
 *      `lastReportOppoTime`, not `reportTimestamp` (which holds the report's block number).
 *
 * @dev The implementation uses a strict `>`, so execution exactly at the deadline is still
 *      valid and one second later bails out. The same deadline protects both opening and active
 *      reports; an opening bailout refunds both margins instead of activating a stale basis.
 */
contract MaxExecutionLatencyTest is LivenessBase {
    function setUp() public {
        _setUpLiveness();
    }

    /// @dev Deadline offset from the closing report's own timestamp.
    function _deadlineOffset(LiveCfg memory c) internal pure returns (uint256) {
        return _secondsForBlocks(c.settlementTime) + c.maxExecutionLatency;
    }

    // ══════════════════════════════════════════════════════════════════
    //  1. Disabled sentinel
    // ══════════════════════════════════════════════════════════════════

    /// @dev With the sentinel, an arbitrarily late execution still resolves normally. Maturity
    ///      is short so the outcome is an unambiguous close rather than a pre-maturity
    ///      LiquidationFailed that could be mistaken for a latency effect.
    function test_disabledSentinelNeverBailsOutHoweverLate() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = 0;
        c.maturityWindow = MATURITY_SHORT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        // far beyond any deadline the minimum enabled value would have imposed
        _advanceValid(_secondsForBlocks(c.settlementTime) + 10_000);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId),
            "no latency bailout with the disabled sentinel"
        );
        assertFalse(
            _hasLog(logs, OpenPuntStorage.PositionReportBailedOut.selector, swapId), "no bailout state transition"
        );
        // Maturity is decided at settlement eligibility, not at execution time:
        //     maturityPassed = settlementEligibilityTimestamp >= s.maturity
        // This report became eligible before maturity, so however long execution is delayed it can
        // no longer be converted into a maturity close — that would let someone hold a settled
        // pre-maturity price and cash it in as a close. The report stays reusable instead, and the
        // The disabled sentinel remains unaffected.
        //
        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "resolves reusably");
        assertFalse(
            _hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "a pre-maturity report cannot close"
        );
        assertTrue(punt.swaps(swapId) != bytes32(0), "position survives");
    }

    // ══════════════════════════════════════════════════════════════════
    //  2. Exactly at the deadline
    // ══════════════════════════════════════════════════════════════════

    function test_executionExactlyAtTheDeadlineIsStillValid() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        c.maturityWindow = MATURITY_INSTANT; // mature by execution time, so a close is expected

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        uint256 deadline = uint256(mt.game.lastReportOppoTime) + _deadlineOffset(c);
        _advanceValid(deadline - vm.getBlockTimestamp());
        assertEq(vm.getBlockTimestamp(), deadline, "sitting exactly on the deadline");

        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId),
            "the boundary instant is not late"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "resolved normally");
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. One second late
    // ══════════════════════════════════════════════════════════════════

    function test_oneSecondLateBailsOutAndLeavesThePositionReusable() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        c.maturityWindow = MATURITY_INSTANT; // would otherwise close, so the bailout is decisive

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        uint256 deadline = uint256(mt.game.lastReportOppoTime) + _deadlineOffset(c);
        _advanceValid(deadline + 1 - vm.getBlockTimestamp());
        assertEq(vm.getBlockTimestamp(), deadline + 1, "one second past the deadline");

        Book memory before = _book();
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId), "latency bailout emitted"
        );
        assertEq(
            _countLogs(logs, OpenPuntStorage.PositionReportBailedOut.selector, swapId),
            1,
            "exactly one PositionReportBailedOut"
        );
        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            "cadence was valid, so no BPS diagnostic"
        );
        _assertNoEconomicOutcome(logs, swapId);

        OpenPuntStorage.MatchedSwap memory reusable = _readBailedOut(logs, swapId, mt.reportId, mt.swap);
        _assertBailoutIsEconomicallyComplete(before, mt.reportId, LIVE_COMP, A1, A2_HEALTHY, "late bailout");

        // A stale replay of the consumed live-report state cannot collect the compensation again.
        // The replay is submitted by the same account whose balance is then checked, so the
        // assertion is about the actor that would have been paid.
        uint256 execEth = _spendable(closeExecutor, address(0));
        vm.prank(closeExecutor);
        vm.expectRevert(PuntErrors.NoOracleGame.selector);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);
        assertEq(_spendable(closeExecutor, address(0)), execEth, "the replaying account is paid nothing further");

        // the decoded reusable state drives the next real report
        Matched memory second = _reportLive(swapId, _noDutch(), reusable, p.preimage, reporter, 0, A2_HEALTHY);
        assertTrue(second.reportId != mt.reportId, "a genuinely new report");
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. Close intent is consumed by the failed report attempt
    // ══════════════════════════════════════════════════════════════════

    function test_closeIntentIsClearedByALatencyBailout() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        c.maturityWindow = MATURITY_LONG; // only an intent can close this position

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        // set the intent on the live report
        vm.prank(swapper);
        punt.close{value: 0}(
            swapId, _dutchInput(), mt.swap, true, _emptyPermit2(), 0, _emptyOracleGame(), _emptyOracleHelper(), 0
        );
        (,, bool intentBefore) = _closeState(swapId);
        assertTrue(intentBefore, "intent set while the report was live");

        uint256 deadline = uint256(mt.game.lastReportOppoTime) + _deadlineOffset(c);
        _advanceValid(deadline + 1 - vm.getBlockTimestamp());
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId), "latency bailout");
        OpenPuntStorage.MatchedSwap memory reusable = _readBailedOut(logs, swapId, mt.reportId, mt.swap);

        (uint128 pending,, bool intent) = _closeState(swapId);
        assertFalse(intent, "failed report consumes the close intent");
        assertEq(pending, 0, "no pending auction compensation remains");

        // a later valid report does not inherit a stale close option
        Matched memory second = _reportLive(swapId, _noDutch(), reusable, p.preimage, reporter, 0, A2_HEALTHY);
        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory closeLogs = _executeNow(swapId, second, closeExecutor);

        assertTrue(_hasLog(closeLogs, OpenPuntStorage.LiquidationFailed.selector, swapId), "ordinary reusable report");
        assertTrue(punt.swaps(swapId) != bytes32(0), "position remains active");
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. Opening games use the same deadline
    // ══════════════════════════════════════════════════════════════════

    /// @dev Zero remains an explicit opt-out: a late but otherwise valid opening still activates.
    function test_openingLatencyDisabledStillAllowsLateExecution() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = 0;

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _liveCfg(c);
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, A2_OPEN, matcher);

        _advanceValid(_secondsForBlocks(c.settlementTime) + 500);
        assertLt(vm.getBlockTimestamp() - uint256(mt.swap.start), uint256(mt.swap.maxGameTime), "inside maxGameTime");

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, p.swapId),
            "disabled deadline emitted a bailout"
        );
        OpenPuntStorage.MatchedSwap memory opened =
            _decodeSingleSwapState(logs, OpenPuntStorage.PositionOpened.selector, p.swapId);
        assertTrue(opened.active, "position did not open with latency disabled");
    }

    /// @dev The deadline is inclusive for an opening report, exactly as it is for an active report.
    function test_openingExecutionExactlyAtTheDeadlineStillOpens() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _liveCfg(c);
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, A2_OPEN, matcher);

        uint256 deadline = uint256(mt.game.lastReportOppoTime) + _deadlineOffset(c);
        _advanceValid(deadline - vm.getBlockTimestamp());
        assertEq(vm.getBlockTimestamp(), deadline, "exact opening deadline");

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, p.swapId),
            "the inclusive deadline was treated as late"
        );
        OpenPuntStorage.MatchedSwap memory opened =
            _decodeSingleSwapState(logs, OpenPuntStorage.PositionOpened.selector, p.swapId);
        assertTrue(opened.active, "position did not open at the deadline");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(opened)), "stored hash tracks the opened state");
    }

    /// @dev One second late refunds both parties and deletes the matched position instead of
    ///      activating the stale opening price.
    function test_openingExecutionOneSecondLateRefundsBothMargins() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _liveCfg(c);
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, A2_OPEN, matcher);

        uint256 swapperBefore = collat.balanceOf(swapper);
        uint256 matcherBefore = _spendable(matcher, address(collat));
        uint256 executorCompBefore = punt.tempHolding(executor);

        uint256 deadline = uint256(mt.game.lastReportOppoTime) + _deadlineOffset(c);
        _advanceValid(deadline + 1 - vm.getBlockTimestamp());
        assertEq(vm.getBlockTimestamp(), deadline + 1, "one second past the opening deadline");

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, p.swapId),
            "opening latency bailout missing"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionOpeningFailed.selector, p.swapId), "opening failure missing");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionOpened.selector, p.swapId), "stale position opened");
        assertEq(punt.swaps(p.swapId), bytes32(0), "stale matched position survived");
        assertEq(punt.swapIdToReportId(p.swapId), 0, "opening report sidecar survived");
        assertEq(collat.balanceOf(swapper) - swapperBefore, mt.swap.initialMarginSwapper, "swapper margin refund");
        assertEq(
            _spendable(matcher, address(collat)) - matcherBefore, mt.swap.initialMarginMatcher, "matcher margin refund"
        );
        assertEq(
            punt.tempHolding(executor) - executorCompBefore,
            mt.swap.openExecutionComp,
            "executor did not receive opening compensation"
        );
    }

    /// @dev A real dispute resets both oracle settlement eligibility and the execution deadline.
    ///      Passing the original deadline remains valid while the replacement quote is still fresh.
    function test_openingDeadlineTracksTheLatestDispute() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _liveCfg(c);
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, A2_OPEN, matcher);
        uint256 originalDeadline = uint256(mt.game.lastReportOppoTime) + _deadlineOffset(c);

        uint256 disputeBlocks = uint256(mt.game.disputeDelay) + 1;
        _advanceValid(_secondsForBlocks(disputeBlocks));

        uint128 disputedAmount1 = uint128(uint256(mt.game.currentAmount1) * mt.game.multiplier / 100);
        uint128 disputedAmount2 = uint128(uint256(mt.game.currentAmount2) * mt.game.multiplier / 100);
        vm.recordLogs();
        vm.prank(reporter);
        IOpenOracle2(address(oracle)).dispute(
            mt.reportId, disputedAmount1, disputedAmount2, reporter, true, true, mt.game, mt.helper, _noTiming()
        );
        Vm.Log memory disputedLog =
            _findLog(vm.getRecordedLogs(), address(oracle), OpenOracle.ReportDisputed.selector, mt.reportId);
        mt.game = PackedDecoder.decodeOracleGame(disputedLog.data);
        mt.helper = PackedDecoder.decodeHelperTail(disputedLog.data, mt.reportId);

        uint256 resetDeadline = uint256(mt.game.lastReportOppoTime) + _deadlineOffset(c);
        assertGt(resetDeadline, originalDeadline, "dispute did not move the deadline");
        _advanceValid(originalDeadline + 1 - vm.getBlockTimestamp());
        assertLt(vm.getBlockTimestamp(), resetDeadline, "fixture passed the reset deadline");

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, p.swapId),
            "original deadline incorrectly remained authoritative"
        );
        assertTrue(
            _hasLog(logs, OpenPuntStorage.PositionOpened.selector, p.swapId), "fresh disputed quote did not open"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. Settled and unsettled oracle shapes
    // ══════════════════════════════════════════════════════════════════

    /// @dev The late report is still unsettled: execute() settles it internally, pays the
    ///      compensation, and only then takes the bailout.
    function test_lateBailoutSettlesTheReportInternally() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        c.maturityWindow = MATURITY_INSTANT; // mature by execution time, so a close is expected

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        bytes32 oracleHashBefore = oracle.oracleGame(mt.reportId);
        uint256 deadline = uint256(mt.game.lastReportOppoTime) + _deadlineOffset(c);
        _advanceValid(deadline + 1 - vm.getBlockTimestamp());

        Book memory before = _book();
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId), "latency bailout");
        assertTrue(oracle.oracleGame(mt.reportId) != oracleHashBefore, "the report was settled by execute()");
        _readBailedOut(logs, swapId, mt.reportId, mt.swap);
        _assertBailoutIsEconomicallyComplete(
            before, mt.reportId, LIVE_COMP, A1, A2_HEALTHY, "internally settled late bailout"
        );
    }

    /// @dev Pre-settling at eligibility must neither bypass nor spuriously trigger the rule.
    function test_preSettledReportStillBailsOutWhenLate() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        c.maturityWindow = MATURITY_INSTANT; // mature by execution time, so a close is expected

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        // settle independently, exactly at eligibility
        _advanceValid(_secondsForBlocks(c.settlementTime));
        uint48 settledAt = uint48(vm.getBlockNumber()); // block mode: settle() records the BLOCK NUMBER
        _settleDirect(mt, settler);
        IOpenOracle2.OracleGame memory settled = _settledStateOf(mt, settledAt);

        // then drift past the deadline
        uint256 deadline = uint256(mt.game.lastReportOppoTime) + _deadlineOffset(c);
        _advanceValid(deadline + 1 - vm.getBlockTimestamp());

        Book memory before = _book();
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, settled, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId),
            "pre-settling does not bypass the deadline"
        );
        _readBailedOut(logs, swapId, mt.reportId, mt.swap);
        // the legs were already returned by the independent settle(), before this snapshot,
        // so execution hands back nothing further
        _assertBailoutIsEconomicallyComplete(before, mt.reportId, LIVE_COMP, 0, 0, "pre-settled late bailout");
    }

    /// @dev The converse: pre-settled and inside the deadline resolves normally.
    function test_preSettledReportInsideTheDeadlineResolvesNormally() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        c.maturityWindow = MATURITY_INSTANT; // mature by execution time, so a close is expected

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        _advanceValid(_secondsForBlocks(c.settlementTime));
        uint48 settledAt = uint48(vm.getBlockNumber()); // block mode: settle() records the BLOCK NUMBER
        _settleDirect(mt, settler);
        IOpenOracle2.OracleGame memory settled = _settledStateOf(mt, settledAt);

        _advanceValid(10); // still far inside the 60-second latency window

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, settled, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId),
            "no spurious latency bailout on a pre-settled report"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "resolved normally");
    }
}
