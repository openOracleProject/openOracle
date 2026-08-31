// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LivenessBase.t.sol";

/**
 * @notice `liquidationHeartbeat()` and the liquidation-authorization rule it feeds.
 *
 * @dev Minimum notice is measured against the earlier of real execution time and synthetic
 *      settlement eligibility. In block mode the game's wall clock lives in
 *      `lastReportOppoTime`, and the block-denominated settlement window is converted with the
 *      position's own `millisecondsPerBlock`:
 *
 *          min(
 *              lastReportOppoTime + floor(settlementTime * millisecondsPerBlock / 1000),
 *              block.timestamp
 *          )
 *              >= heartbeatTimestamp + liquidationHeartbeatMin
 *
 *      Therefore neither waiting longer nor blocks arriving slightly faster than the configured
 *      cadence can shorten the real notice period.
 */
contract LiquidationHeartbeatTest is LivenessBase {
    /// @dev A four-second oracle game makes settlement eligibility land at a hand-chosen
    ///      instant relative to the heartbeat, which is what the notice rule is measured against.
    /// @dev Two blocks at 2,000 ms/block is a four-second settlement window,
    ///      which is what the notice arithmetic below is built around: a heartbeat, then a report
    ///      26 seconds later, puts settlement eligibility exactly HB_MIN (30 s) after the beat.
    uint48 internal constant SHORT_SETTLE = 2;

    function setUp() public {
        _setUpLiveness();
    }

    function _hbCfg() internal pure returns (LiveCfg memory c) {
        c = _defaultLiveCfg();
        c.hbMin = HB_MIN;
        c.hbMax = HB_MAX;
    }

    function _shortSettleCfg() internal pure returns (LiveCfg memory c) {
        c = _hbCfg();
        c.settlementTime = SHORT_SETTLE;
    }

    // ══════════════════════════════════════════════════════════════════
    //  1-6. Entry-point validation and recording
    // ══════════════════════════════════════════════════════════════════

    function test_disabledModeRejects() public {
        LiveCfg memory c = _defaultLiveCfg(); // hbMin/hbMax both zero
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,,) = _openLive(c);

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidLiquidationHeartbeat.selector);
        punt.liquidationHeartbeat(swapId, active);

        (uint128 r, uint48 t) = punt.liquidationHeartbeats(swapId);
        assertEq(r, 0, "nothing recorded");
        assertEq(t, 0, "nothing recorded");
    }

    function test_matchedButNotActiveRejects() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _liveCfg(_hbCfg());
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, A2_OPEN, matcher);
        assertFalse(mt.swap.active, "genuinely inactive");

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.NotActive.selector);
        punt.liquidationHeartbeat(p.swapId, mt.swap);

        (uint128 r,) = punt.liquidationHeartbeats(p.swapId);
        assertEq(r, 0, "nothing recorded");
    }

    function test_hashGateRejectsWrongIdAndPerturbedState() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,,) = _openLive(_hbCfg());

        // wrong swap id
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.liquidationHeartbeat(swapId + 999, active);

        // perturbed state
        OpenPuntStorage.MatchedSwap memory tampered = _copy(active);
        tampered.maintenanceMarginSwapper += 1;
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.liquidationHeartbeat(swapId, tampered);

        (uint128 r, uint48 t) = punt.liquidationHeartbeats(swapId);
        assertEq(r, 0, "heartbeat mapping unchanged");
        assertEq(t, 0, "heartbeat mapping unchanged");
        (uint128 r2, uint48 t2) = punt.liquidationHeartbeats(swapId + 999);
        assertEq(r2, 0, "ghost slot untouched");
        assertEq(t2, 0, "ghost slot untouched");
    }

    /// @dev A zero gas price marks a force-included transaction, which the heartbeat refuses:
    ///      during a sequencer outage only forced transactions land, and the heartbeat must
    ///      stop so that liquidations become unauthorised.
    function test_forcedTransactionRejected() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,,) = _openLive(_hbCfg());

        vm.txGasPrice(0);
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.ForcedTransaction.selector);
        punt.liquidationHeartbeat(swapId, active);

        (uint128 r, uint48 t) = punt.liquidationHeartbeats(swapId);
        assertEq(r, 0, "nothing recorded by a forced transaction");
        assertEq(t, 0, "nothing recorded by a forced transaction");

        // and with a real gas price it works
        vm.txGasPrice(1 gwei);
        _heartbeat(swapId, active, outsider);
        (, uint48 t2) = punt.liquidationHeartbeats(swapId);
        assertEq(t2, uint48(vm.getBlockTimestamp()), "recorded once the transaction is not forced");
    }

    function test_permissionlessRecordingOnAnIdlePosition() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,,) = _openLive(_hbCfg());
        bytes32 positionHash = punt.swaps(swapId);
        uint48 now_ = uint48(vm.getBlockTimestamp());

        // an unrelated third party
        Vm.Log[] memory logs = _heartbeat(swapId, active, outsider);

        (uint128 storedReport, uint48 storedTs) = punt.liquidationHeartbeats(swapId);
        assertEq(storedReport, 0, "idle position: bound to no report");
        assertEq(storedTs, now_, "timestamp is the transaction timestamp");

        (uint256 eventReportId, uint48 eventTs) = _readHeartbeatSet(logs, swapId);
        assertEq(eventReportId, 0, "event carries a zero report id");
        assertEq(eventTs, now_, "event carries the timestamp");

        assertEq(punt.swaps(swapId), positionHash, "the position hash itself is unchanged");
    }

    // ══════════════════════════════════════════════════════════════════
    //  7. Renewal boundaries
    // ══════════════════════════════════════════════════════════════════

    function test_renewalBoundaries() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,,) = _openLive(_hbCfg());

        _heartbeat(swapId, active, outsider);
        (, uint48 first) = punt.liquidationHeartbeats(swapId);

        // before the window expires
        _advanceValid(100);
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.LiquidationHeartbeatLive.selector);
        punt.liquidationHeartbeat(swapId, active);

        // exactly at timestamp + max: the implementation uses <=, so still live
        _advanceValid(uint256(first) + HB_MAX - vm.getBlockTimestamp());
        assertEq(vm.getBlockTimestamp(), uint256(first) + HB_MAX, "exactly on the window boundary");
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.LiquidationHeartbeatLive.selector);
        punt.liquidationHeartbeat(swapId, active);

        // one second later it may be replaced
        _advanceValid(1);
        _heartbeat(swapId, active, outsider);
        (, uint48 second) = punt.liquidationHeartbeats(swapId);
        assertEq(second, uint48(vm.getBlockTimestamp()), "expired unbound heartbeat replaced");
        assertTrue(second > first, "and it really is a new one");
    }

    // ══════════════════════════════════════════════════════════════════
    //  8-9. Binding to a report
    // ══════════════════════════════════════════════════════════════════

    function test_reportAtTheExactBindingBoundaryInherits() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(_hbCfg());

        _heartbeat(swapId, active, outsider);
        (, uint48 hbTs) = punt.liquidationHeartbeats(swapId);

        _advanceValid(uint256(hbTs) + HB_MAX - vm.getBlockTimestamp());
        assertEq(vm.getBlockTimestamp(), uint256(hbTs) + HB_MAX, "exactly on the binding boundary");

        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, 0, A2_HEALTHY);
        (uint128 boundTo,) = punt.liquidationHeartbeats(swapId);
        assertEq(boundTo, uint128(mt.reportId), "the boundary instant still binds");
    }

    function test_reportOneSecondAfterTheBoundaryDoesNotInherit() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(_hbCfg());

        _heartbeat(swapId, active, outsider);
        (, uint48 hbTs) = punt.liquidationHeartbeats(swapId);

        _advanceValid(uint256(hbTs) + HB_MAX + 1 - vm.getBlockTimestamp());
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, 0, A2_HEALTHY);

        (uint128 boundTo,) = punt.liquidationHeartbeats(swapId);
        assertEq(boundTo, 0, "one second past the boundary does not bind");
        assertTrue(mt.reportId != 0, "the report itself still started");
    }

    function test_reportDuringAnOrdinaryWindowInherits() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(_hbCfg());

        _heartbeat(swapId, active, outsider);
        _advanceValid(50);

        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, 0, A2_HEALTHY);
        (uint128 boundTo,) = punt.liquidationHeartbeats(swapId);
        assertEq(boundTo, uint128(mt.reportId), "inherited during an ordinary live window");
    }

    function test_heartbeatAfterAReportExistsBindsToItDirectly() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(_hbCfg());

        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, 0, A2_HEALTHY);
        Vm.Log[] memory logs = _heartbeat(swapId, mt.swap, outsider);

        (uint128 boundTo, uint48 ts) = punt.liquidationHeartbeats(swapId);
        assertEq(boundTo, uint128(mt.reportId), "recorded against the live report directly");
        assertEq(ts, uint48(vm.getBlockTimestamp()), "with the current timestamp");

        (uint256 eventReportId,) = _readHeartbeatSet(logs, swapId);
        assertEq(eventReportId, mt.reportId, "event carries the live report id");
    }

    /// @dev The maximum window governs how long an unbound heartbeat may still attach to a
    ///      report. It does not expire a heartbeat that has already bound.
    function test_aBoundHeartbeatCannotBeReplacedEvenAfterTheWindowElapses() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(_hbCfg());

        _heartbeat(swapId, active, outsider);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, 0, A2_HEALTHY);
        (uint128 boundTo, uint48 hbTs) = punt.liquidationHeartbeats(swapId);
        assertEq(boundTo, uint128(mt.reportId), "bound");

        _advanceValid(uint256(HB_MAX) + 100); // well past the original window
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.LiquidationHeartbeatLive.selector);
        punt.liquidationHeartbeat(swapId, mt.swap);

        (uint128 stillBound, uint48 stillTs) = punt.liquidationHeartbeats(swapId);
        assertEq(stillBound, boundTo, "binding unchanged");
        assertEq(stillTs, hbTs, "timestamp unchanged");
    }

    // ══════════════════════════════════════════════════════════════════
    //  10. Independence between positions
    // ══════════════════════════════════════════════════════════════════

    function test_twoPositionsKeepIndependentHeartbeats() public {
        (uint256 idA, OpenPuntStorage.MatchedSwap memory activeA,,) = _openLive(_hbCfg());
        (uint256 idB, OpenPuntStorage.MatchedSwap memory activeB,,) = _openLive(_hbCfg());

        _heartbeat(idA, activeA, outsider);
        (uint128 rA, uint48 tA) = punt.liquidationHeartbeats(idA);
        (uint128 rB, uint48 tB) = punt.liquidationHeartbeats(idB);
        assertEq(tA, uint48(vm.getBlockTimestamp()), "A recorded");
        assertEq(tB, 0, "B untouched");
        assertEq(rA, 0, "A unbound");
        assertEq(rB, 0, "B unbound");

        _advanceValid(120);
        _heartbeat(idB, activeB, outsider);
        (, uint48 tA2) = punt.liquidationHeartbeats(idA);
        (, uint48 tB2) = punt.liquidationHeartbeats(idB);
        assertEq(tA2, tA, "A's record is untouched by B's heartbeat");
        assertEq(tB2, uint48(vm.getBlockTimestamp()), "B recorded independently");

        // and A cannot be renewed while its own window is live, independently of B
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.LiquidationHeartbeatLive.selector);
        punt.liquidationHeartbeat(idA, activeA);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Authorization timing: notice is measured at settlement eligibility
    // ══════════════════════════════════════════════════════════════════

    function test_exactlyEnoughNoticeAuthorisesLiquidation() public {
        LiveCfg memory c = _shortSettleCfg();
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        _heartbeat(swapId, active, outsider);
        (, uint48 hbTs) = punt.liquidationHeartbeats(swapId);

        // report 26s after the heartbeat: eligibility lands at hb + 26 + 4 == hb + 30
        _advanceValid(26);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        assertEq(
            uint256(mt.game.lastReportOppoTime) + _secondsForBlocks(c.settlementTime),
            uint256(hbTs) + HB_MIN,
            "settlement eligibility is exactly the minimum notice"
        );

        uint256 matcherBefore = _spendable(matcher, address(collat));
        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "liquidation authorised");
        assertFalse(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "no heartbeat bailout");
        assertEq(_spendable(matcher, address(collat)) - matcherBefore, 2000e18, "matcher took the pool");

        (uint128 hbAfter, uint48 tsAfter) = punt.liquidationHeartbeats(swapId);
        assertEq(hbAfter, 0, "heartbeat cleared");
        assertEq(tsAfter, 0, "heartbeat cleared");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "close state cleared");
        assertFalse(intent, "close state cleared");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
    }

    /// @dev Two settlement blocks arrive in only two real seconds. That is exactly the permitted
    ///      cadence deviation, but the synthetic clock is already two seconds further ahead. The
    ///      synthetic clock alone would authorise; the real-time clamp refuses one second early.
    function test_syntheticFutureTimeCannotAuthoriseOneSecondEarly() public {
        LiveCfg memory c = _shortSettleCfg();
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        _heartbeat(swapId, active, outsider);
        (, uint48 hbTs) = punt.liquidationHeartbeats(swapId);

        _advanceValid(27);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        uint256 syntheticEligibility = uint256(mt.game.lastReportOppoTime) + _secondsForBlocks(c.settlementTime);
        assertEq(syntheticEligibility, uint256(hbTs) + HB_MIN + 1, "synthetic clock would authorise");

        vm.roll(vm.getBlockNumber() + c.settlementTime);
        vm.warp(vm.getBlockTimestamp() + 2);
        assertEq(vm.getBlockTimestamp(), uint256(hbTs) + HB_MIN - 1, "real clock is one second early");

        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "refused early");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "no early liquidation");
    }

    /// @dev The same fast-block shape authorises at the exact real-time minimum. This proves the
    ///      clamp adds no extra delay beyond the configured heartbeat notice.
    function test_syntheticFutureTimeAuthorisesAtTheRealMinimum() public {
        LiveCfg memory c = _shortSettleCfg();
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        _heartbeat(swapId, active, outsider);
        (, uint48 hbTs) = punt.liquidationHeartbeats(swapId);

        _advanceValid(27);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);

        vm.roll(vm.getBlockNumber() + c.settlementTime);
        vm.warp(vm.getBlockTimestamp() + 3);
        assertEq(vm.getBlockTimestamp(), uint256(hbTs) + HB_MIN, "real clock reached the exact minimum");

        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "authorised at minimum");
        assertFalse(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "no heartbeat bailout");
    }

    /// @dev The decisive property: executing much later cannot rescue a report whose
    ///      settlement-eligibility instant fell one second short of the minimum notice.
    function test_oneSecondShortStaysUnauthorisedHoweverLateExecutionHappens() public {
        LiveCfg memory c = _shortSettleCfg();
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        _heartbeat(swapId, active, outsider);
        (, uint48 hbTs) = punt.liquidationHeartbeats(swapId);

        _advanceValid(25); // eligibility at hb + 29, one second short of 30
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        assertEq(
            uint256(mt.game.lastReportOppoTime) + _secondsForBlocks(c.settlementTime),
            uint256(hbTs) + HB_MIN - 1,
            "eligibility is one second short"
        );

        // wait far more than the minimum notice in real time before executing
        _advanceValid(200);
        assertGt(vm.getBlockTimestamp(), uint256(hbTs) + HB_MIN, "more than the notice period has really elapsed");

        Book memory before = _book();
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "still unauthorised");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "no liquidation");
        assertEq(
            _readHeartbeatBailoutReportId(logs, swapId),
            mt.reportId,
            "the bailout event names the report that was refused"
        );

        OpenPuntStorage.MatchedSwap memory reusable = _readBailedOut(logs, swapId, mt.reportId, mt.swap);
        _assertBailoutIsEconomicallyComplete(before, mt.reportId, LIVE_COMP, A1, A2_LIQUIDATES, "one second short");

        // The binding is released but the notice clock is preserved: an unauthorized liquidation
        // no longer destroys the heartbeat, so a premature report cannot restart it. Because the
        // preserved beat is still inside liquidationHeartbeatMax it owns the slot, and a
        // replacement is refused. Full coverage of this behaviour lives in
        // HeartbeatPreservationTest.
        (uint128 keptId, uint48 keptTs) = punt.liquidationHeartbeats(swapId);
        assertEq(keptId, 0, "binding released");
        assertEq(keptTs, hbTs, "original timestamp preserved, not restamped and not cleared");
        assertLt(vm.getBlockTimestamp(), uint256(hbTs) + HB_MAX, "the preserved beat is still live");

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.LiquidationHeartbeatLive.selector);
        punt.liquidationHeartbeat(swapId, reusable);
    }

    function test_noHeartbeatCannotLiquidate() public {
        LiveCfg memory c = _shortSettleCfg();
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        (uint128 bound,) = punt.liquidationHeartbeats(swapId);
        assertEq(bound, 0, "no heartbeat exists");

        Book memory before = _book();
        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "bailed out");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "no liquidation");
        OpenPuntStorage.MatchedSwap memory reusable = _readBailedOut(logs, swapId, mt.reportId, mt.swap);
        _assertBailoutIsEconomicallyComplete(before, mt.reportId, LIVE_COMP, A1, A2_LIQUIDATES, "no heartbeat");

        // the position is genuinely reusable
        Matched memory second = _reportLive(swapId, _noDutch(), reusable, p.preimage, reporter, 0, A2_HEALTHY);
        assertTrue(second.reportId != mt.reportId, "reportable again");
    }

    function test_expiredUnboundHeartbeatCannotAuthorise() public {
        LiveCfg memory c = _shortSettleCfg();
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        _heartbeat(swapId, active, outsider);
        (, uint48 hbTs) = punt.liquidationHeartbeats(swapId);

        // one second past the binding window
        _advanceValid(uint256(hbTs) + HB_MAX + 1 - vm.getBlockTimestamp());
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        (uint128 bound,) = punt.liquidationHeartbeats(swapId);
        assertEq(bound, 0, "did not bind");

        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "cannot liquidate");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "no liquidation");
    }

    // ── heartbeat placed during a live report ───────────────────────────

    /// @dev With a settlement window longer than the minimum notice, a heartbeat placed after
    ///      the report can still satisfy the notice condition by settlement eligibility.
    function test_heartbeatDuringALiveReportCanAuthorise() public {
        LiveCfg memory c = _hbCfg(); // 300s settlement, comfortably longer than the 30s notice
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);

        // heartbeat 10s into a 300s window: eligibility is 290s later, far beyond 30s notice
        _advanceValid(10);
        _heartbeat(swapId, mt.swap, outsider);
        (uint128 bound, uint48 hbTs) = punt.liquidationHeartbeats(swapId);
        assertEq(bound, uint128(mt.reportId), "bound to the live report directly");
        assertGe(
            uint256(mt.game.lastReportOppoTime) + _secondsForBlocks(c.settlementTime),
            uint256(hbTs) + HB_MIN,
            "notice satisfied by eligibility"
        );

        uint256 matcherBefore = _spendable(matcher, address(collat));
        _advanceValid(_secondsForBlocks(c.settlementTime));
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(
            _hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId),
            "authorised by the live-report heartbeat"
        );
        assertEq(_spendable(matcher, address(collat)) - matcherBefore, 2000e18, "matcher took the pool");
    }

    /// @dev The opposite: a live-report heartbeat placed too late cannot authorise.
    function test_heartbeatDuringALiveReportTooLateCannotAuthorise() public {
        LiveCfg memory c = _hbCfg();
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);

        // heartbeat 280s into the 300s window: eligibility is only 20s later, short of 30s
        _advanceValid(280);
        _heartbeat(swapId, mt.swap, outsider);
        (uint128 bound, uint48 hbTs) = punt.liquidationHeartbeats(swapId);
        assertEq(bound, uint128(mt.reportId), "bound, but too late");
        assertLt(
            uint256(mt.game.lastReportOppoTime) + _secondsForBlocks(c.settlementTime),
            uint256(hbTs) + HB_MIN,
            "notice NOT satisfied"
        );

        _advanceValid(_secondsForBlocks(c.settlementTime));
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "unauthorised");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "no liquidation");
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. Healthy outcomes are never gated by the heartbeat
    // ══════════════════════════════════════════════════════════════════

    function test_healthyCloseWithIntentIsNotGated() public {
        LiveCfg memory c = _hbCfg();
        c.maturityWindow = MATURITY_LONG;
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        // enter execution with a genuinely bound heartbeat: it must neither gate the healthy
        // close nor survive it
        _heartbeat(swapId, active, outsider);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);
        (uint128 bound,) = punt.liquidationHeartbeats(swapId);
        assertEq(bound, uint128(mt.reportId), "the report bound the heartbeat");

        vm.prank(swapper);
        punt.close{value: 0}(
            swapId, _dutchInput(), mt.swap, true, _emptyPermit2(), 0, _emptyOracleGame(), _emptyOracleHelper(), 0
        );

        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        // A bound heartbeat does not gate a healthy close.
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "healthy report closed");
        assertFalse(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "not gated");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        _assertHeartbeatCleared(swapId, "healthy terminal close");
    }

    function test_healthyPostMaturityCloseIsNotGated() public {
        LiveCfg memory c = _hbCfg();
        c.maturityWindow = MATURITY_INSTANT;
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);
        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "permissionless maturity close");
        assertFalse(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "not gated");
    }

    function test_healthyPreMaturityWithoutIntentEmitsOrdinaryLiquidationFailed() public {
        LiveCfg memory c = _hbCfg();
        c.maturityWindow = MATURITY_LONG;
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        // a genuinely bound heartbeat, so deletion on the reusable outcome is observable
        _heartbeat(swapId, active, outsider);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);
        (uint128 bound,) = punt.liquidationHeartbeats(swapId);
        assertEq(bound, uint128(mt.reportId), "the report bound the heartbeat");

        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "ordinary failed liquidation");
        assertFalse(
            _hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId),
            "healthy reports are never heartbeat-gated"
        );

        // the report-start checkpoint remains reusable, and the heartbeat was consumed with the report
        OpenPuntStorage.MatchedSwap memory reusable = mt.swap;
        assertEq(punt.swapIdToReportId(swapId), 0, "reportId cleared");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(reusable)), "report-start state reconstructs stored hash");
        _assertHeartbeatCleared(swapId, "healthy reusable failure");

        Vm.Log[] memory hbLogs = _heartbeat(swapId, reusable, outsider);
        (uint256 freshReportId,) = _readHeartbeatSet(hbLogs, swapId);
        assertEq(freshReportId, 0, "a fresh heartbeat records against the now-idle position");
    }
}
