// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LivenessBase.t.sol";

/**
 * @notice Preservation of the liquidation-notice clock across unauthorized liquidation bailouts.
 *
 * @dev A premature liquidating report must not destroy the heartbeat and restart its notice clock.
 *      Otherwise an actor could repeat unauthorized liquidation attempts to keep the position
 *      unliquidatable.
 *
 *      The unauthorized-liquidation branch writes back
 *
 *          LiquidationHeartbeat({reportId: 0, timestamp: heartbeatState.timestamp})
 *
 *      rather than leaving it deleted: the original timestamp survives, unbound. `report()` rebinds
 *      an unbound heartbeat that is still inside `liquidationHeartbeatMax`, so notice keeps
 *      accruing across as many premature reports as an attacker cares to pay for.
 *
 *      The fixture uses a 30-second minimum notice against a four-second oracle settlement window,
 *      the production-shaped relationship: the window is far shorter than the notice, so a report
 *      started immediately after a heartbeat can never satisfy it.
 *
 *      In block mode a four-second window is two blocks at the fixture's 2,000 ms/block, and
 *      OpenPunt's derived eligibility instant is
 *      `lastReportOppoTime + floor(settlementTime * millisecondsPerBlock / 1000)`.
 */
contract HeartbeatPreservationTest is LivenessBase {
    /// @dev 2 blocks == 4 wall-clock seconds at the fixture cadence.
    uint48 internal constant SETTLE_2_BLOCKS = 2;
    uint256 internal constant SETTLE_SECONDS = 4;

    function setUp() public {
        _setUpLiveness();
    }

    function _cfg() internal pure returns (LiveCfg memory c) {
        c = _defaultLiveCfg();
        c.hbMin = HB_MIN; // 30 s
        c.hbMax = HB_MAX; // 300 s
        c.settlementTime = SETTLE_2_BLOCKS;
        c.maturityWindow = MATURITY_LONG; // never mature: only a liquidation can resolve it
    }

    function _hb(uint256 swapId) internal view returns (uint128 reportId, uint48 timestamp) {
        return punt.liquidationHeartbeats(swapId);
    }

    function _assertHb(uint256 swapId, uint128 wantId, uint48 wantTs, string memory what) internal view {
        (uint128 id, uint48 ts) = _hb(swapId);
        assertEq(id, wantId, string.concat(what, ": heartbeat reportId"));
        assertEq(ts, wantTs, string.concat(what, ": heartbeat timestamp"));
    }

    struct Pos {
        uint256 swapId;
        OpenPuntStorage.MatchedSwap active;
        Proposal p;
    }

    function _open() internal returns (Pos memory q) {
        LiveCfg memory c = _cfg();
        (q.swapId, q.active, q.p,) = _openLive(c);
    }

    /// @dev A premature liquidating report: started now, so its eligibility is only four seconds
    ///      out and cannot possibly satisfy a thirty-second notice.
    function _prematureLiquidatingReport(Pos memory q, OpenPuntStorage.MatchedSwap memory state)
        internal
        returns (Matched memory mt)
    {
        mt = _reportLive(q.swapId, _noDutch(), state, q.p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
    }

    // ══════════════════════════════════════════════════════════════════
    //  1. Premature-report grief sequence
    // ══════════════════════════════════════════════════════════════════

    function test_prematureReportCannotDestroyTheNoticeClock() public {
        Pos memory q = _open();

        _heartbeat(q.swapId, q.active, outsider);
        (uint128 idAtRest, uint48 H) = _hb(q.swapId);
        assertEq(idAtRest, 0, "recorded unbound on an idle position");
        assertEq(H, uint48(vm.getBlockTimestamp()), "H is the moment of the beat");

        // An unrelated actor starts a liquidating report before notice accrues.
        Matched memory mt = _prematureLiquidatingReport(q, q.active);
        _assertHb(q.swapId, uint128(mt.reportId), H, "the premature report bound the heartbeat");
        assertEq(
            uint256(mt.game.lastReportOppoTime) + _secondsForBlocks(SETTLE_2_BLOCKS),
            uint256(H) + SETTLE_SECONDS,
            "eligibility is only four seconds out"
        );
        assertLt(uint256(H) + SETTLE_SECONDS, uint256(H) + HB_MIN, "far short of the thirty-second notice");

        // execute after the real oracle settlement window
        _advanceValid(SETTLE_SECONDS);
        Vm.Log[] memory logs = _executeNow(q.swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, q.swapId), "refused");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, q.swapId), "not liquidated");

        // the position is reusable
        OpenPuntStorage.MatchedSwap memory reusable = _readBailedOut(logs, q.swapId, mt.reportId);
        assertEq(punt.swapIdToReportId(q.swapId), 0, "report slot released");
        assertEq(punt.swaps(q.swapId), keccak256(abi.encode(reusable)), "position reusable");

        // and the notice clock survived, unbound and unrestamped
        _assertHb(q.swapId, 0, H, "preserved after the unauthorized liquidation");
    }

    // ══════════════════════════════════════════════════════════════════
    //  2. Repeating the grief cannot restart the clock
    // ══════════════════════════════════════════════════════════════════

    function test_repeatedPrematureReportsCannotRestartTheClock() public {
        Pos memory q = _open();
        _heartbeat(q.swapId, q.active, outsider);
        (, uint48 H) = _hb(q.swapId);

        // ── first premature report ───────────────────────────────────────
        Matched memory first = _prematureLiquidatingReport(q, q.active);
        _advanceValid(SETTLE_SECONDS);
        Vm.Log[] memory logs1 = _executeNow(q.swapId, first, closeExecutor);
        OpenPuntStorage.MatchedSwap memory afterFirst = _readBailedOut(logs1, q.swapId, first.reportId);
        _assertHb(q.swapId, 0, H, "preserved after the first refusal");

        // ── second premature report, still before H + 30 ─────────────────
        Matched memory second = _prematureLiquidatingReport(q, afterFirst);
        assertTrue(second.reportId != first.reportId, "a genuinely new oracle game");
        _assertHb(q.swapId, uint128(second.reportId), H, "the preserved beat REBOUND to the new report");

        _advanceValid(SETTLE_SECONDS);
        assertLt(vm.getBlockTimestamp(), uint256(H) + HB_MIN, "still inside the notice period");

        Vm.Log[] memory logs2 = _executeNow(q.swapId, second, closeExecutor);
        assertTrue(_hasLog(logs2, OpenPuntStorage.LiquidationHeartbeatBailout.selector, q.swapId), "refused again");
        assertFalse(_hasLog(logs2, OpenPuntStorage.PositionLiquidated.selector, q.swapId), "still not liquidated");

        // the decisive property: the timestamp never moved and the binding was released
        _assertHb(q.swapId, 0, H, "timestamp is still exactly H after two refusals");
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. The exact authorization boundary using the preserved heartbeat
    // ══════════════════════════════════════════════════════════════════

    function test_preservedHeartbeatAuthorisesAtExactlyTheMinimumNotice() public {
        Pos memory q = _open();
        _heartbeat(q.swapId, q.active, outsider);
        (, uint48 H) = _hb(q.swapId);

        // burn the beat's binding with a premature report, exactly as an attacker would
        Matched memory premature = _prematureLiquidatingReport(q, q.active);
        _advanceValid(SETTLE_SECONDS);
        OpenPuntStorage.MatchedSwap memory reusable =
            _readBailedOut(_executeNow(q.swapId, premature, closeExecutor), q.swapId, premature.reportId);
        _assertHb(q.swapId, 0, H, "preserved");

        // report at H + 26 so that eligibility lands exactly on H + 30
        _advanceValid(uint256(H) + 26 - vm.getBlockTimestamp());
        assertEq(vm.getBlockTimestamp(), uint256(H) + 26, "reporting at H + 26");

        Matched memory mt =
            _reportLive(q.swapId, _noDutch(), reusable, q.p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        _assertHb(q.swapId, uint128(mt.reportId), H, "rebound, still carrying the original timestamp");
        assertEq(
            uint256(mt.game.lastReportOppoTime) + _secondsForBlocks(SETTLE_2_BLOCKS),
            uint256(H) + HB_MIN,
            "eligibility is exactly H + liquidationHeartbeatMin"
        );

        uint256 matcherBefore = _spendable(matcher, address(collat));
        _advanceValid(SETTLE_SECONDS);
        Vm.Log[] memory logs = _executeNow(q.swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, q.swapId), "liquidation authorised");
        assertFalse(
            _hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, q.swapId), "no heartbeat bailout"
        );
        assertEq(punt.swaps(q.swapId), bytes32(0), "position terminal");
        _assertHb(q.swapId, 0, 0, "heartbeat finally deleted on the terminal outcome");
        assertEq(
            _spendable(matcher, address(collat)) - matcherBefore,
            uint256(MARGIN_S) + MARGIN_M,
            "matcher receives exactly the pooled margins"
        );
    }

    /// @dev The one-second-short contrast uses the same preserved timestamp, so the only
    ///      difference from the passing case is when the second report was started.
    function test_preservedHeartbeatOneSecondShortStaysUnauthorised() public {
        Pos memory q = _open();
        _heartbeat(q.swapId, q.active, outsider);
        (, uint48 H) = _hb(q.swapId);

        Matched memory premature = _prematureLiquidatingReport(q, q.active);
        _advanceValid(SETTLE_SECONDS);
        OpenPuntStorage.MatchedSwap memory reusable =
            _readBailedOut(_executeNow(q.swapId, premature, closeExecutor), q.swapId, premature.reportId);

        // report at H + 25, so eligibility is H + 29
        _advanceValid(uint256(H) + 25 - vm.getBlockTimestamp());
        Matched memory mt =
            _reportLive(q.swapId, _noDutch(), reusable, q.p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        assertEq(
            uint256(mt.game.lastReportOppoTime) + _secondsForBlocks(SETTLE_2_BLOCKS),
            uint256(H) + HB_MIN - 1,
            "eligibility is one second short"
        );

        _advanceValid(SETTLE_SECONDS);
        Vm.Log[] memory logs = _executeNow(q.swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, q.swapId), "refused");
        _assertHb(q.swapId, 0, H, "and the clock is preserved for the next attempt");
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. Live-report heartbeat recovery
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice A report cannot invalidate a heartbeat transaction built from the active position.
     *
     * @dev The active MatchedSwap hash remains stable when the report starts, so the original
     *      preimage still records a heartbeat and binds it to the report that won the race.
     *      With a four-second
     *      window against a thirty-second notice it is necessarily too late to authorise. It still
     *      matters: the bailout preserves its timestamp unbound, and the next report binds
     *      it, so the notice it started accruing is not lost.
     */
    function test_aHeartbeatRacedByAReportStillUsesTheStableActivePreimage() public {
        Pos memory q = _open();
        _assertHb(q.swapId, 0, 0, "fixture: no heartbeat yet");

        // the report wins the race
        Matched memory first = _prematureLiquidatingReport(q, q.active);
        assertEq(punt.swaps(q.swapId), keccak256(abi.encode(q.active)), "the active position hash stayed stable");

        // The transaction built before the report remains valid and binds to the live sidecar id.
        _heartbeat(q.swapId, q.active, outsider);
        (uint128 boundId, uint48 H) = _hb(q.swapId);
        assertEq(boundId, uint128(first.reportId), "bound directly to the report that won the race");
        assertEq(H, uint48(vm.getBlockTimestamp()), "recorded at the current timestamp");

        // it is too late to authorise this report: eligibility is four seconds out, notice is thirty
        _advanceValid(SETTLE_SECONDS);
        Vm.Log[] memory logs = _executeNow(q.swapId, first, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, q.swapId), "refused");

        // but its clock survives, unbound
        _assertHb(q.swapId, 0, H, "preserved unbound after the refusal");

        // and the next report binds it, so the notice it accrued is not wasted
        OpenPuntStorage.MatchedSwap memory reusable = _readBailedOut(logs, q.swapId, first.reportId);
        Matched memory second = _prematureLiquidatingReport(q, reusable);
        _assertHb(q.swapId, uint128(second.reportId), H, "rebound to the next report, timestamp intact");
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. An expired preserved heartbeat can be replaced
    // ══════════════════════════════════════════════════════════════════

    function test_expiredPreservedHeartbeatCanBeReplacedAndRebound() public {
        Pos memory q = _open();
        _heartbeat(q.swapId, q.active, outsider);
        (, uint48 H) = _hb(q.swapId);

        Matched memory premature = _prematureLiquidatingReport(q, q.active);
        _advanceValid(SETTLE_SECONDS);
        OpenPuntStorage.MatchedSwap memory reusable =
            _readBailedOut(_executeNow(q.swapId, premature, closeExecutor), q.swapId, premature.reportId);
        _assertHb(q.swapId, 0, H, "preserved immediately after the bailout");

        // While still inside hbMax, the preserved heartbeat prevents replacement.
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.LiquidationHeartbeatLive.selector);
        punt.liquidationHeartbeat(q.swapId, reusable);

        // past hbMax it is stale, and a replacement is permitted
        _advanceValid(uint256(H) + HB_MAX + 2 - vm.getBlockTimestamp());
        assertGt(vm.getBlockTimestamp(), uint256(H) + HB_MAX, "the preserved beat has expired");

        _heartbeat(q.swapId, reusable, outsider);
        (uint128 newId, uint48 newTs) = _hb(q.swapId);
        assertEq(newId, 0, "replacement is unbound");
        assertEq(newTs, uint48(vm.getBlockTimestamp()), "replacement carries the CURRENT timestamp");
        assertTrue(newTs != H, "and is genuinely not the old one");

        // and the replacement binds a subsequent report normally
        Matched memory mt = _reportLive(q.swapId, _noDutch(), reusable, q.p.preimage, reporter, LIVE_COMP, A2_HEALTHY);
        _assertHb(q.swapId, uint128(mt.reportId), newTs, "the fresh beat bound the new report");
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. No heartbeat at all
    // ══════════════════════════════════════════════════════════════════

    /// @dev The restore writes `{0, heartbeatState.timestamp}`, which for a position that never had
    ///      a heartbeat is `{0, 0}` — indistinguishable from deleted. Proven not to create an
    ///      observable heartbeat, and not to block a fresh one.
    function test_noHeartbeatBailoutLeavesNothingObservable() public {
        Pos memory q = _open();
        _assertHb(q.swapId, 0, 0, "fixture: no heartbeat");

        Matched memory mt = _prematureLiquidatingReport(q, q.active);
        _assertHb(q.swapId, 0, 0, "report binds nothing when there is no beat");

        _advanceValid(SETTLE_SECONDS);
        Vm.Log[] memory logs = _executeNow(q.swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, q.swapId), "refused");
        _assertHb(q.swapId, 0, 0, "still nothing observable");

        // a fresh heartbeat is recordable, which it would not be if a live beat had been created
        OpenPuntStorage.MatchedSwap memory reusable = _readBailedOut(logs, q.swapId, mt.reportId);
        _heartbeat(q.swapId, reusable, outsider);
        (uint128 id, uint48 ts) = _hb(q.swapId);
        assertEq(id, 0, "fresh beat unbound");
        assertEq(ts, uint48(vm.getBlockTimestamp()), "fresh beat at the current timestamp");
    }

    // ══════════════════════════════════════════════════════════════════
    //  7. Every other outcome deletes the heartbeat
    // ══════════════════════════════════════════════════════════════════

    /// @dev Only the unauthorized-liquidation branch restores. The unconditional delete at the top
    ///      of the active branch is final for every other resolution.
    function test_healthyReusableOutcomeStillDeletesTheHeartbeat() public {
        Pos memory q = _open();
        _heartbeat(q.swapId, q.active, outsider);
        (, uint48 H) = _hb(q.swapId);

        Matched memory mt = _reportLive(q.swapId, _noDutch(), q.active, q.p.preimage, reporter, LIVE_COMP, A2_HEALTHY);
        _advanceValid(SETTLE_SECONDS);
        Vm.Log[] memory logs = _executeNow(q.swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, q.swapId), "ordinary failed liquidation");
        _assertHb(q.swapId, 0, 0, "deleted on a healthy reusable outcome");
        assertTrue(H != 0, "the heartbeat genuinely existed beforehand");
    }

    function test_cadenceBailoutStillDeletesTheHeartbeat() public {
        Pos memory q = _open();
        _heartbeat(q.swapId, q.active, outsider);

        Matched memory mt = _prematureLiquidatingReport(q, q.active);
        uint256 dt = SETTLE_SECONDS;
        _advanceInvalidCadence(dt, _tooManyBlocks(dt));

        Vm.Log[] memory logs = _executeNow(q.swapId, mt, closeExecutor);
        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, q.swapId),
            "cadence bailout"
        );
        assertFalse(
            _hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, q.swapId),
            "the cadence branch short-circuits before the liquidation branch"
        );
        _assertHb(q.swapId, 0, 0, "deleted on a cadence bailout");
    }

    function test_latencyBailoutStillDeletesTheHeartbeat() public {
        LiveCfg memory c = _cfg();
        c.maxExecutionLatency = LATENCY_MIN;
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        _heartbeat(swapId, active, outsider);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);

        _advanceValid(SETTLE_SECONDS + LATENCY_MIN + 2); // past the deadline
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId), "latency bailout");
        _assertHb(swapId, 0, 0, "deleted on a latency bailout");
    }
}
