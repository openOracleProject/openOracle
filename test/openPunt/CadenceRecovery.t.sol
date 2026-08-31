// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LivenessBase.t.sol";

/**
 * @notice The one-week cadence-recovery escape hatch on the active-position path.
 *
 * @dev A report whose latest report/dispute predates maturity plus one week remains subject to the
 *      ordinary cadence and latency checks. A report started or updated after that boundary waits
 *      its committed block window, then bypasses both checks derived from the obsolete block-time
 *      assumption. Liquidation heartbeat authorization remains independent.
 */
contract CadenceRecoveryTest is LivenessBase {
    function setUp() public {
        _setUpLiveness();
    }

    struct Live {
        uint256 swapId;
        OpenPuntStorage.MatchedSwap active;
        Proposal p;
        Matched mt;
    }

    /// @dev Active position with a settlement-eligible closing report and a deliberately broken
    ///      cadence. `maturityWindow` is one second so `maturity` sits just after opening.
    function _brokenCadenceAtEligibility(LiveCfg memory c, uint128 a2Close) internal returns (Live memory l) {
        c.maturityWindow = MATURITY_INSTANT;
        (l.swapId, l.active, l.p,) = _openLive(c);
        l.mt = _reportLive(l.swapId, _noDutch(), l.active, l.p.preimage, reporter, LIVE_COMP, a2Close);
        _advanceValid(_secondsForBlocks(c.settlementTime) + 2); // eligible, cadence still valid
    }

    function _freshRecoveryReport(LiveCfg memory c, uint128 a2Close) internal returns (Live memory l) {
        c.maturityWindow = MATURITY_INSTANT;
        (l.swapId, l.active, l.p,) = _openLive(c);
        _warpTo(uint256(l.active.maturity) + 1 weeks);
        l.mt = _reportLive(l.swapId, _noDutch(), l.active, l.p.preimage, reporter, LIVE_COMP, a2Close);
    }

    function _advanceSlowToEligibility(Live memory l, LiveCfg memory c) internal {
        vm.warp(vm.getBlockTimestamp() + _secondsForBlocks(c.settlementTime) + uint256(c.maxExecutionLatency) + 3);
        vm.roll(uint256(l.mt.game.reportTimestamp) + c.settlementTime);
    }

    /// @dev Advances the wall clock to an absolute instant without producing blocks, which breaks
    ///      the cadence by construction: expected milliseconds stop growing while elapsed ones do.
    function _warpTo(uint256 instant) internal {
        require(instant >= vm.getBlockTimestamp(), "target already passed");
        vm.warp(instant);
    }

    function _assertCadenceIsBroken(Live memory l) internal view {
        uint256 elapsedMs = (vm.getBlockTimestamp() - uint256(l.mt.game.lastReportOppoTime)) * 1000;
        uint256 expectedMs = (vm.getBlockNumber() - uint256(l.mt.game.reportTimestamp)) * uint256(MS_PER_BLOCK);
        uint256 diff = elapsedMs > expectedMs ? elapsedMs - expectedMs : expectedMs - elapsedMs;
        require(diff > 2000, "fixture: the cadence is NOT broken, the test would be vacuous");
    }

    // ══════════════════════════════════════════════════════════════════
    //  The boundary
    // ══════════════════════════════════════════════════════════════════

    /// @dev One second before the recovery instant, a broken cadence still bails out.
    function test_oneSecondBeforeRecoveryTheCadenceStillBailsOut() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = 0; // isolate the cadence from the latency deadline
        Live memory l = _brokenCadenceAtEligibility(c, A2_HEALTHY);

        _warpTo(uint256(l.active.maturity) + 1 weeks - 1);
        _assertCadenceIsBroken(l);

        Vm.Log[] memory logs = _executeNow(l.swapId, l.mt, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, l.swapId),
            "cadence bailout at maturity + 1 week - 1"
        );
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, l.swapId), "not closed");
        assertTrue(punt.swaps(l.swapId) != bytes32(0), "position survives and stays reusable");
    }

    /// @dev Reaching the recovery boundary does not make a report from before that boundary fresh.
    function test_anOldReportDoesNotBecomeExecutableAtRecovery() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = 0;
        Live memory l = _brokenCadenceAtEligibility(c, A2_HEALTHY);

        _warpTo(uint256(l.active.maturity) + 1 weeks);
        _assertCadenceIsBroken(l);
        assertLt(l.mt.game.lastReportOppoTime, uint256(l.active.maturity) + 1 weeks, "report predates recovery");

        Vm.Log[] memory logs = _executeNow(l.swapId, l.mt, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, l.swapId),
            "stale report still fails cadence"
        );
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, l.swapId), "stale report did not close");
        assertTrue(punt.swaps(l.swapId) != bytes32(0), "position remains reusable");
    }

    /// @dev A report started exactly at recovery resolves despite both a broken cadence and an
    ///      exceeded synthetic latency deadline.
    function test_aFreshRecoveryReportBypassesCadenceAndSyntheticLatency() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        Live memory l = _freshRecoveryReport(c, A2_HEALTHY);

        assertEq(l.mt.game.lastReportOppoTime, uint256(l.active.maturity) + 1 weeks, "report starts at recovery");
        _advanceSlowToEligibility(l, c);
        _assertCadenceIsBroken(l);
        assertGt(
            vm.getBlockTimestamp(),
            uint256(l.mt.game.lastReportOppoTime) + _secondsForBlocks(c.settlementTime) + c.maxExecutionLatency,
            "synthetic latency deadline exceeded"
        );

        Vm.Log[] memory logs = _executeNow(l.swapId, l.mt, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, l.swapId),
            "fresh recovery report bypasses cadence"
        );
        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, l.swapId),
            "fresh recovery report bypasses synthetic latency"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, l.swapId), "position closed");
        assertEq(punt.swaps(l.swapId), bytes32(0), "position resolved");
    }

    function test_recoveryAllowsAnOtherwiseStuckLiquidation() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        Live memory l = _freshRecoveryReport(c, A2_LIQUIDATES);

        _advanceSlowToEligibility(l, c);
        _assertCadenceIsBroken(l);
        uint256 matcherBefore = _spendable(matcher, address(collat));

        Vm.Log[] memory logs = _executeNow(l.swapId, l.mt, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, l.swapId),
            "no cadence bailout"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, l.swapId), "liquidated");
        assertEq(_spendable(matcher, address(collat)) - matcherBefore, 2000e18, "matcher took the pool");
    }

    /// @dev Recovery is gated on `active`, so it cannot apply while a position is opening. A
    ///      broken cadence on the opening path still refunds both margins after any delay.
    function test_recoveryDoesNotApplyToTheOpeningPath() public {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);

        // Baselines are taken after matching, so both margins are already posted and the refund
        // returns each party exactly its own margin
        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherCollat0 = _spendable(matcher, address(collat));

        // reach eligibility, then let a month of wall-clock time pass with no blocks
        _advanceValid(SETTLE_HOP_SECONDS);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, p.swapId),
            "opening still bails out on a broken cadence"
        );
        assertEq(punt.swaps(p.swapId), bytes32(0), "proposal deleted");
        assertEq(collat.balanceOf(swapper), swapperExt0 + mt.swap.initialMarginSwapper, "remaining margin refunded");
        assertEq(_spendable(matcher, address(collat)), matcherCollat0 + INITIAL_MARGIN_MATCHER, "matcher refunded");
    }

    /// @dev A report from before recovery remains stale when latency is enabled too.
    function test_anOldReportStillFailsLatencyAfterRecoveryBegins() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        Live memory l = _brokenCadenceAtEligibility(c, A2_HEALTHY);

        _warpTo(uint256(l.active.maturity) + 1 weeks);

        Vm.Log[] memory logs = _executeNow(l.swapId, l.mt, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, l.swapId),
            "stale report fails cadence"
        );
        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, l.swapId),
            "stale report also fails latency"
        );
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, l.swapId), "not closed");
        assertTrue(punt.swaps(l.swapId) != bytes32(0), "position survives and stays reusable");
    }

    /// @dev Recovery changes timing checks only; it does not authorize liquidation.
    function test_recoveryDoesNotBypassHeartbeatAuthorization() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        c.hbMin = HB_MIN;
        c.hbMax = HB_MAX;
        Live memory l = _freshRecoveryReport(c, A2_LIQUIDATES);

        (uint128 hbId, uint48 hbTs) = punt.liquidationHeartbeats(l.swapId);
        assertEq(hbId, 0, "fixture: no heartbeat was ever placed");
        assertEq(hbTs, 0, "fixture: no heartbeat was ever placed");

        _advanceSlowToEligibility(l, c);
        uint256 matcherBefore = _spendable(matcher, address(collat));

        Vm.Log[] memory logs = _executeNow(l.swapId, l.mt, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, l.swapId),
            "fresh recovery report bypasses cadence"
        );
        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, l.swapId),
            "fresh recovery report bypasses synthetic latency"
        );
        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, l.swapId),
            "but the heartbeat gate still refused to authorise the liquidation"
        );
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, l.swapId), "not liquidated");
        assertEq(_spendable(matcher, address(collat)), matcherBefore, "matcher took nothing");
        assertTrue(punt.swaps(l.swapId) != bytes32(0), "position survives and stays reusable");
    }

    /// @dev With a valid heartbeat, the same recovered execution liquidates. This pairs the
    ///      recovery path with an independently satisfied heartbeat gate.
    function test_recoveredLiquidationSucceedsWithAValidHeartbeat() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;
        c.hbMin = HB_MIN;
        c.hbMax = HB_MAX;
        c.maturityWindow = MATURITY_INSTANT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        _warpTo(uint256(active.maturity) + 1 weeks);
        _heartbeat(swapId, active, outsider);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        Live memory l = Live({swapId: swapId, active: active, p: p, mt: mt});
        _advanceSlowToEligibility(l, c);

        uint256 matcherBefore = _spendable(matcher, address(collat));
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "liquidated");
        assertEq(_spendable(matcher, address(collat)) - matcherBefore, 2000e18, "matcher took the pool");
    }
}
