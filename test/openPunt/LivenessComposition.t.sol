// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LivenessBase.t.sol";

/**
 * @notice How the liveness modes compose with heartbeat authorization and consumed close auctions.
 *
 * @dev Once a heartbeat has bound to a
 *      report, `liquidationHeartbeatMax` stops acting as an execution deadline. Authorization
 *      then checks only the matching report id and the minimum-notice condition. The separate
 *      execution deadline is `maxExecutionLatency`, and it takes precedence when both apply.
 */
contract LivenessCompositionTest is LivenessBase {
    function setUp() public {
        _setUpLiveness();
    }

    function _hbCfg() internal pure returns (LiveCfg memory c) {
        c = _defaultLiveCfg();
        c.hbMin = HB_MIN;
        c.hbMax = HB_MAX;
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. Maximum-window semantics once a heartbeat has bound
    // ══════════════════════════════════════════════════════════════════

    /// @dev A bound heartbeat does not expire. With latency disabled, liquidation succeeds even
    ///      though heartbeatTimestamp + heartbeatMax passed long ago.
    function test_boundHeartbeatSurvivesItsMaximumWindow() public {
        LiveCfg memory c = _hbCfg();
        c.maxExecutionLatency = 0; // no separate execution deadline

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        _heartbeat(swapId, active, outsider);
        (, uint48 hbTs) = punt.liquidationHeartbeats(swapId);

        // bind well inside the window
        _advanceValid(10);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        (uint128 bound,) = punt.liquidationHeartbeats(swapId);
        assertEq(bound, uint128(mt.reportId), "bound inside the window");

        // let the maximum window elapse entirely before executing
        _advanceValid(uint256(hbTs) + HB_MAX + 500 - vm.getBlockTimestamp());
        assertGt(vm.getBlockTimestamp(), uint256(hbTs) + HB_MAX, "the original maximum window has definitely elapsed");

        uint256 matcherBefore = _spendable(matcher, address(collat));
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(
            _hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId),
            "a bound heartbeat remains valid past its maximum window"
        );
        assertFalse(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "no heartbeat bailout");
        assertEq(_spendable(matcher, address(collat)) - matcherBefore, 2000e18, "matcher took the pool");
    }

    /// @dev The same setup with maxExecutionLatency enabled and exceeded: the latency bailout
    ///      wins, so latency is the real execution deadline, not the heartbeat maximum.
    function test_latencyTakesPrecedenceOverABoundHeartbeat() public {
        LiveCfg memory c = _hbCfg();
        c.maxExecutionLatency = LATENCY_MIN;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        _heartbeat(swapId, active, outsider);
        _advanceValid(10);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        (uint128 bound,) = punt.liquidationHeartbeats(swapId);
        assertEq(bound, uint128(mt.reportId), "bound and, by notice, authorised");

        // past the latency deadline
        uint256 deadline =
            uint256(mt.game.lastReportOppoTime) + _secondsForBlocks(c.settlementTime) + c.maxExecutionLatency;
        _advanceValid(deadline + 1 - vm.getBlockTimestamp());

        Book memory before = _book();
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId), "latency bailout wins"
        );
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "no liquidation");
        assertFalse(
            _hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId),
            "the heartbeat branch is never reached"
        );
        assertEq(_countLogs(logs, OpenPuntStorage.PositionReportBailedOut.selector, swapId), 1, "one state transition");

        _readBailedOut(logs, swapId, mt.reportId, mt.swap);
        _assertBailoutIsEconomicallyComplete(
            before, mt.reportId, LIVE_COMP, A1, A2_LIQUIDATES, "latency over heartbeat"
        );

        // the heartbeat was cleared, so a retry needs a fresh one
        (uint128 hbAfter, uint48 tsAfter) = punt.liquidationHeartbeats(swapId);
        assertEq(hbAfter, 0, "heartbeat cleared by the bailout");
        assertEq(tsAfter, 0, "heartbeat cleared by the bailout");
    }

    function test_consumedDutchCannotBeClaimedByALaterReportAfterLatencyBailout() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        c.maturityWindow = MATURITY_LONG;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);
        uint256 reporterCollat0 = _spendable(reporter, address(collat));
        Matched memory first = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);

        assertEq(_spendable(reporter, address(collat)) - reporterCollat0, DUTCH_START, "auction claimed");
        assertEq(_storedDutchState(swapId), bytes32(0), "auction consumed");
        assertEq(
            punt.executionGasComp(first.reportId),
            uint256(CLOSE_COMP) + LIVE_COMP,
            "auction and reporter compensation assigned"
        );

        uint256 deadline =
            uint256(first.game.lastReportOppoTime) + _secondsForBlocks(c.settlementTime) + c.maxExecutionLatency;
        _advanceValid(deadline + 1 - vm.getBlockTimestamp());
        Vm.Log[] memory logs = _executeNow(swapId, first, closeExecutor);
        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId), "report one bailed out"
        );
        OpenPuntStorage.MatchedSwap memory reusable = _readBailedOut(logs, swapId, first.reportId, first.swap);
        assertEq(punt.closeRequestBlock(swapId), 0, "request that applied to report one is cleared");

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.report(
            swapId, _expectedDutchHash(d), reusable, p.preimage, _noTiming(), reporter, A1, A2_HEALTHY, 0
        );

        Matched memory second = _reportLive(swapId, _noDutch(), reusable, p.preimage, reporter, 0, A2_HEALTHY);
        assertTrue(second.reportId != first.reportId, "a new report starts with no auction");
        assertEq(punt.executionGasComp(second.reportId), 0, "old compensation cannot migrate twice");
    }

    function test_consumedDutchRemainsConsumedAfterCadenceBailout() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maturityWindow = MATURITY_LONG;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        _startDefaultAuction(swapId, active);

        Matched memory first = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);
        assertEq(_storedDutchState(swapId), bytes32(0), "auction consumed by report one");

        uint256 dt = _secondsForBlocks(c.settlementTime) + 2;
        _advanceInvalidCadence(dt, _tooManyBlocks(dt));
        Vm.Log[] memory logs = _executeNow(swapId, first, closeExecutor);
        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId), "cadence bailout"
        );
        OpenPuntStorage.MatchedSwap memory reusable = _readBailedOut(logs, swapId, first.reportId, first.swap);

        Matched memory second = _reportLive(swapId, _noDutch(), reusable, p.preimage, reporter, 0, A2_HEALTHY);
        assertTrue(second.reportId != first.reportId, "a genuinely later report");
        assertEq(_storedDutchState(swapId), bytes32(0), "auction cannot reappear");
        assertEq(punt.executionGasComp(second.reportId), 0, "compensation cannot migrate twice");
    }
}
