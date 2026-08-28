// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LivenessBase.t.sol";

/**
 * @notice Active-position block-cadence bailout behavior and composition.
 *
 * @dev The arithmetic boundaries of `impliedMillisecondsPerBlock` are pinned exhaustively on the
 *      opening path (OpeningExecution) and across chain profiles in BlockCadenceModels. These tests
 *      cover what the active branch does with the result and how it composes with the other
 *      liveness modes. Block/time pairs are hand-chosen from the inequality — no test calls or
 *      reimplements the predicate.
 *
 *      At millisecondsPerBlock = 2_000, over dt seconds:
 *          elapsed  = dt * 1000 ms,   expected = db * 2_000 ms,   accepted when |diff| <= 2_000.
 *      `_advanceValid` uses db = floor(dt/2), so expected ~= elapsed and it is always inside.
 *      `_tooManyBlocks(dt)` returns 2*dt + 100 blocks, i.e. expected = 4_000*dt + 200_000 ms
 *      against an elapsed of 1_000*dt ms — far above the ceiling for every dt used here.
 */
contract ActiveBlockCadenceTest is LivenessBase {
    function setUp() public {
        _setUpLiveness();
    }

    // ══════════════════════════════════════════════════════════════════
    //  1. Valid cadence follows the ordinary path
    // ══════════════════════════════════════════════════════════════════

    function test_validCadenceClosesNormally() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maturityWindow = MATURITY_INSTANT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            "no cadence bailout"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "closed normally");
    }

    function test_validCadenceLiquidatesNormally() public {
        LiveCfg memory c = _defaultLiveCfg();

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);

        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            "no cadence bailout"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "liquidated normally");
    }

    function test_validCadencePreMaturityWithoutIntentFailsLiquidationNormally() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maturityWindow = MATURITY_LONG;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            "no cadence bailout"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "ordinary failed liquidation");
    }

    // ══════════════════════════════════════════════════════════════════
    //  2 & 5. Invalid cadence bails out, completely
    // ══════════════════════════════════════════════════════════════════

    /// @dev A cadence bailout consumes the close request along with the failed report attempt.
    function test_aBailoutClearsTheIntentAndDeadline() public {
        LiveCfg memory c = _defaultLiveCfg();

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(
            swapId,
            _defaultCloseDutch(),
            active,
            false,
            _emptyPermit2(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper()
        );

        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);
        (, uint48 deadlineBefore, bool intentBefore) = _closeState(swapId);
        assertTrue(deadlineBefore != 0, "precondition: report deadline stored");
        assertTrue(intentBefore, "precondition: intent applies to this report");

        uint256 dt = _secondsForBlocks(c.settlementTime) + 2;
        _advanceInvalidCadence(dt, _tooManyBlocks(dt));
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            "cadence bailout reached"
        );
        assertTrue(punt.swaps(swapId) != bytes32(0), "position survives");

        (, uint48 deadlineAfter, bool intentAfter) = _closeState(swapId);
        assertEq(deadlineAfter, 0, "failed report deadline cleared");
        assertFalse(intentAfter, "failed report consumes the close intent");
    }

    function test_invalidCadenceBailsOutAndLeavesThePositionReusable() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maturityWindow = MATURITY_INSTANT; // would otherwise close, so the bailout is decisive

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        uint256 dt = _secondsForBlocks(c.settlementTime) + 2;
        _advanceInvalidCadence(dt, _tooManyBlocks(dt));

        Book memory before = _book();
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            "cadence bailout emitted"
        );
        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId),
            "latency disabled, so no latency diagnostic"
        );
        assertEq(
            _countLogs(logs, OpenPuntStorage.PositionReportBailedOut.selector, swapId),
            1,
            "exactly one PositionReportBailedOut"
        );
        _assertNoEconomicOutcome(logs, swapId);

        OpenPuntStorage.MatchedSwap memory reusable = _readBailedOut(logs, swapId, mt.reportId, mt.swap);
        _assertBailoutIsEconomicallyComplete(before, mt.reportId, LIVE_COMP, A1, A2_HEALTHY, "cadence bailout");

        // reusable: the decoded state drives a real follow-up report
        Matched memory second = _reportLive(swapId, _noDutch(), reusable, p.preimage, reporter, 0, A2_HEALTHY);
        assertTrue(second.reportId != mt.reportId, "a genuinely new report");
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. BPS takes precedence over a certain liquidation
    // ══════════════════════════════════════════════════════════════════

    function test_invalidCadencePreventsAnOtherwiseCertainLiquidation() public {
        LiveCfg memory c = _defaultLiveCfg();

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);

        uint256 dt = _secondsForBlocks(c.settlementTime) + 2;
        _advanceInvalidCadence(dt, _tooManyBlocks(dt));

        Book memory before = _book();
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            "cadence bailout emitted"
        );
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "liquidation prevented");

        _readBailedOut(logs, swapId, mt.reportId, mt.swap);
        assertEq(
            _spendable(matcher, address(collat)), before.matcherCollat, "the matcher received no margin pool at all"
        );
        _assertBailoutIsEconomicallyComplete(before, mt.reportId, LIVE_COMP, A1, A2_LIQUIDATES, "BPS over liquidation");

        // and the same price liquidates once the cadence is sane again
        OpenPuntStorage.MatchedSwap memory reusable = mt.swap;
        Matched memory second = _reportLive(swapId, _noDutch(), reusable, p.preimage, reporter, 0, A2_LIQUIDATES);
        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs2 = _executeNow(swapId, second, closeExecutor);
        assertTrue(_hasLog(logs2, OpenPuntStorage.PositionLiquidated.selector, swapId), "liquidates on a valid retry");
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. Both diagnostics, one transition
    // ══════════════════════════════════════════════════════════════════

    function test_bothCadenceAndLatencyFailButOnlyOneTransitionOccurs() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        c.maturityWindow = MATURITY_INSTANT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        // Past the latency deadline with a wrong block count.
        uint256 dt = _secondsForBlocks(c.settlementTime) + c.maxExecutionLatency + 1;
        _advanceInvalidCadence(dt, _tooManyBlocks(dt));

        Book memory before = _book();
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            "cadence diagnostic"
        );
        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId), "latency diagnostic"
        );
        assertEq(
            _countLogs(logs, OpenPuntStorage.PositionReportBailedOut.selector, swapId),
            1,
            "two reasons, but exactly one state transition"
        );
        _assertNoEconomicOutcome(logs, swapId);

        _readBailedOut(logs, swapId, mt.reportId, mt.swap);
        // exactly one compensation payment, despite two diagnostics
        _assertBailoutIsEconomicallyComplete(
            before, mt.reportId, LIVE_COMP, A1, A2_HEALTHY, "combined cadence and latency bailout"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. Auxiliary state preserved across the bailout
    // ══════════════════════════════════════════════════════════════════

    /// @dev A cadence bailout clears the request that applied to the report and its heartbeat.
    ///      The report already consumed the auction, so no auction state can reappear.
    function test_bailoutClearsAppliedIntentAndHeartbeatAfterAuctionConsumption() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.hbMin = HB_MIN;
        c.hbMax = HB_MAX;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        _startDefaultAuction(swapId, active);

        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);
        assertEq(_storedDutchState(swapId), bytes32(0), "auction consumed by this report");

        _heartbeat(swapId, mt.swap, outsider);
        (uint128 hbReport,) = punt.liquidationHeartbeats(swapId);
        assertEq(hbReport, uint128(mt.reportId), "heartbeat bound to the live report");

        uint256 coreCollatBefore = _spendable(address(punt), address(collat));
        uint256 dt = _secondsForBlocks(c.settlementTime) + 2;
        _advanceInvalidCadence(dt, _tooManyBlocks(dt));

        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);
        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId), "cadence bailout"
        );
        _readBailedOut(logs, swapId, mt.reportId, mt.swap);

        // The request applied to this report and is cleared by its reusable bailout.
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertFalse(intent, "failed report consumes close intent");
        assertEq(pending, 0, "pending compensation already migrated, and stays migrated");
        assertEq(_storedDutchState(swapId), bytes32(0), "consumed auction stays absent");
        assertEq(_spendable(address(punt), address(collat)), coreCollatBefore, "margin pool remains on the core");

        // cleared
        (uint128 hbReportAfter, uint48 hbTimeAfter) = punt.liquidationHeartbeats(swapId);
        assertEq(hbReportAfter, 0, "heartbeat cleared by the bailout");
        assertEq(hbTimeAfter, 0, "heartbeat cleared by the bailout");
    }
}
