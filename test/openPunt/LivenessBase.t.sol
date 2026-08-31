// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";

/**
 * @notice Fixture for the active-position liveness modes: maximum execution latency,
 *         active block-cadence bailout, and the liquidation heartbeat.
 *
 * @dev Canonical ERC20 setup throughout — the asset/delivery matrix is already complete, and
 *      multiplying liveness across it would add no branch coverage.
 *
 *      Timing is the input under test, so settlementTime, maxExecutionLatency, the heartbeat
 *      window and the block cadence are all per-test parameters. `_advanceValid` keeps the
 *      cadence inside the tolerated band for any single duration: with db = floor(dt/2) at
 *      2,000 ms/block, the expected milliseconds are at most 2,000 below the elapsed
 *      `dt * 1000`, which is exactly the allowance. So a test that is not about cadence can
 *      never trip it accidentally.
 *
 *      Foundry's default tx.gasprice is 0, which `liquidationHeartbeat()`
 *      rejects as a forced transaction. The fixture sets a positive gas price by default so
 *      that heartbeat tests exercise the intended path; the forced-transaction case sets it
 *      back to zero explicitly.
 */
abstract contract LivenessBase is CloseBase {
    /// @dev Liquidatable closing leg: pricePnl == |dA2| == 900e18 against a 1000e18 margin
    ///      leaves equity at 100e18, below the 200e18 maintenance margin.
    uint128 internal constant A2_LIQUIDATES = A2_OPEN - 900e18;
    /// @dev Flat: equity stays at the full 1000e18 margin.
    uint128 internal constant A2_HEALTHY = A2_OPEN;

    uint16 internal constant LATENCY_MIN = 60; // smallest enabled value propose() accepts
    uint16 internal constant HB_MIN = 30;
    uint16 internal constant HB_MAX = 300;

    uint128 internal constant LIVE_COMP = 0.0009 ether;

    /// @dev Maturity one second after opening settlement eligibility, so any closing execution
    ///      is already mature. Without a bailout the report would
    ///      certainly close, so an observed bailout cannot be confused with an ordinary
    ///      pre-maturity LiquidationFailed.
    uint48 internal constant MATURITY_INSTANT = 1;

    struct LiveCfg {
        uint48 settlementTime;
        uint16 maxExecutionLatency;
        uint16 hbMin;
        uint16 hbMax;
        uint48 maturityWindow;
    }

    function _setUpLiveness() internal {
        _setUpClose();
        vm.txGasPrice(1 gwei); // heartbeats require a non-forced transaction
    }

    function _defaultLiveCfg() internal pure returns (LiveCfg memory c) {
        c.settlementTime = SETTLEMENT_BLOCKS; // 150 blocks == 300 s at 2,000 ms/block
        c.maxExecutionLatency = 0;
        c.hbMin = 0;
        c.hbMax = 0;
        c.maturityWindow = MATURITY_LONG;
    }

    function _liveCfg(LiveCfg memory c)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _cfgZeroFee(0); // zero fee, zero funding: liveness only
        s.isLong = true;
        s.maturityWindow = c.maturityWindow;
        s.maxExecutionLatency = c.maxExecutionLatency;
        s.liquidationHeartbeatMin = c.hbMin;
        s.liquidationHeartbeatMax = c.hbMax;
        m.settlementTime = c.settlementTime;
        m.disputeDelay = c.settlementTime > 5 ? uint24(5) : uint24(1); // nonzero, below settlementTime
    }

    // ── clock control ───────────────────────────────────────────────────

    /// @dev Advances `secs` with db = floor(secs / 2).
    ///
    ///      A single call produces valid cadence for that interval because the flooring
    ///      error is at most 500 scaled units against a slack of 1000. It is not a guarantee
    ///      across a sequence: the predicate measures from the report's own timestamp and block,
    ///      so several consecutive odd-duration advances can accumulate separate flooring errors
    ///      and drift outside the band.
    ///
    ///      Callers making sequential advances between a report and its execution must keep the
    ///      cumulative block change within the band measured from the report's original
    ///      timestamp/block. Prefer even increments, or derive the final block target from
    ///      `game.lastReportOppoTime` plus the total elapsed time, whenever the exact instant of
    ///      execution is what a test is pinning.
    function _advanceValid(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 2);
    }

    /// @dev Advances `secs` with a deliberately wrong number of blocks.
    function _advanceInvalidCadence(uint256 secs, uint256 blocks) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + blocks);
    }

    /// @dev Block count that is certainly outside the band for `secs` at 500 (1 block / 2s):
    ///      expected = 2_000 ms per block against an elapsed of 1_000 ms per second, so
    ///      2*secs + 100 blocks implies 4_000*secs + 200_000 ms against 1_000*secs — far above
    ///      the 2_000 ms ceiling for every duration used here.
    function _tooManyBlocks(uint256 secs) internal pure returns (uint256) {
        return 2 * secs + 100;
    }

    // ── lifecycle at configurable settlement times ──────────────────────

    function _openLive(LiveCfg memory c)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p, Matched memory mt)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _liveCfg(c);
        p = _proposeWith(s, m, swapper);
        mt = _matchSwapWith(p, A2_OPEN, matcher);
        openingReportTs = mt.game.lastReportOppoTime;

        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        active = _executeOpening(mt, executor);
        swapId = p.swapId;

        assertTrue(active.active, "fixture: position is active");
        assertEq(punt.swapIdToReportId(swapId), 0, "fixture: idle");
    }

    function _reportLive(
        uint256 swapId,
        OpenPuntStorage.CloseDutch memory d,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.MatcherPreimage memory preimage,
        address who,
        uint128 comp,
        uint128 a2Close
    ) internal returns (Matched memory mt) {
        return _reportOnPositionWithAmounts(swapId, d, active, preimage, who, comp, A1, a2Close);
    }

    /// @dev Executes at the current block; the test owns the timing entirely.
    function _executeNow(uint256 swapId, Matched memory mt, address who) internal returns (Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(who);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);
        logs = vm.getRecordedLogs();
    }

    /// @dev Applies the one field a real settlement changes, then proves the result really is
    ///      the oracle's committed state before it is used.
    function _settledStateOf(Matched memory mt, uint48 settledAt)
        internal
        view
        returns (IOpenOracle2.OracleGame memory g)
    {
        g = abi.decode(abi.encode(mt.game), (IOpenOracle2.OracleGame));
        g.settlementTimestamp = settledAt; // block mode: a BLOCK NUMBER
        assertEq(
            oracle.oracleGame(mt.reportId),
            keccak256(abi.encode(g, mt.helper)),
            "reconstructed settled state is the oracle's real commitment"
        );
    }

    // ── heartbeat helpers ───────────────────────────────────────────────

    function _heartbeat(uint256 swapId, OpenPuntStorage.MatchedSwap memory state, address who)
        internal
        returns (Vm.Log[] memory logs)
    {
        vm.recordLogs();
        vm.prank(who);
        punt.liquidationHeartbeat(swapId, state);
        logs = vm.getRecordedLogs();
    }

    function _readHeartbeatSet(Vm.Log[] memory logs, uint256 swapId)
        internal
        view
        returns (uint256 reportIdTopic, uint48 timestamp)
    {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.LiquidationHeartbeatSet.selector, swapId);
        reportIdTopic = uint256(l.topics[2]);
        timestamp = abi.decode(l.data, (uint48));
    }

    /// @dev `LiquidationHeartbeatBailout(uint256 indexed swapId, uint128 indexed reportId)`
    ///      carries no data; the report it refers to is the second topic.
    function _readHeartbeatBailoutReportId(Vm.Log[] memory logs, uint256 swapId) internal view returns (uint256) {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId);
        return uint256(l.topics[2]);
    }

    /// @dev `execute()` deletes the heartbeat before branching, so the mapping must be empty
    ///      after every active-position outcome, reusable or terminal.
    function _assertHeartbeatCleared(uint256 swapId, string memory what) internal view {
        (uint128 r, uint48 t) = punt.liquidationHeartbeats(swapId);
        assertEq(r, 0, string.concat(what, ": heartbeat report id cleared"));
        assertEq(t, 0, string.concat(what, ": heartbeat timestamp cleared"));
    }

    // ── bailout assertions ──────────────────────────────────────────────

    /// @dev Proves the bailout names the consumed report and leaves the report-start checkpoint reusable.
    function _readBailedOut(
        Vm.Log[] memory logs,
        uint256 swapId,
        uint256 expectedOldReportId,
        OpenPuntStorage.MatchedSwap memory reusable
    ) internal view returns (OpenPuntStorage.MatchedSwap memory) {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.PositionReportBailedOut.selector, swapId);
        assertEq(uint256(l.topics[2]), expectedOldReportId, "bailout event names the old report id");
        assertEq(l.data.length, 0, "bailout does not repeat the report-start checkpoint");

        assertTrue(reusable.active, "bailed-out position stays active");
        assertEq(punt.swapIdToReportId(swapId), 0, "bailed-out position is reportable again");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(reusable)), "report-start state reconstructs stored hash");
        return reusable;
    }

    /// @dev Counts PositionReportBailedOut occurrences, so "exactly one state transition" is
    ///      checkable when two diagnostic reasons fire together.
    function _countLogs(Vm.Log[] memory logs, bytes32 topic0, uint256 swapId) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(punt)) continue;
            if (logs[i].topics.length < 2 || logs[i].topics[0] != topic0) continue;
            if (uint256(logs[i].topics[1]) == swapId) n++;
        }
    }

    /// @dev No economic outcome event may accompany a bailout.
    function _assertNoEconomicOutcome(Vm.Log[] memory logs, uint256 swapId) internal view {
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "no close");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "no liquidation");
        assertFalse(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "no failed-liquidation event");
    }

    /// @dev Books every separately-reconcilable claim around a bailout.
    struct Book {
        uint256 swapperCollatExt;
        uint256 matcherCollat;
        uint256 corePoolCollat;
        uint256 reporterLeg1;
        uint256 reporterLeg2;
        uint256 executorEth;
        uint256 coreEth;
    }

    function _book() internal view returns (Book memory b) {
        b.swapperCollatExt = collat.balanceOf(swapper);
        b.matcherCollat = _spendable(matcher, address(collat));
        b.corePoolCollat = _spendable(address(punt), address(collat));
        b.reporterLeg1 = _spendable(reporter, address(tokenA));
        b.reporterLeg2 = _spendable(reporter, address(tokenB));
        b.executorEth = _spendable(closeExecutor, address(0));
        b.coreEth = _spendable(address(punt), address(0));
    }

    /// @dev A bailed-out report must be economically complete: legs settled back, compensation
    ///      paid once and cleared — while the position itself is untouched and still open.
    ///      `before` is captured after the report was submitted, so the reporter's legs are
    ///      already posted at that point and settlement must hand them back on top.
    function _assertBailoutIsEconomicallyComplete(
        Book memory before,
        uint256 reportId,
        uint128 compOwed,
        uint128 postedLeg1,
        uint128 postedLeg2,
        string memory what
    ) internal view {
        // position margin untouched
        assertEq(collat.balanceOf(swapper), before.swapperCollatExt, string.concat(what, ": swapper margin unmoved"));
        assertEq(_spendable(matcher, address(collat)), before.matcherCollat, string.concat(what, ": matcher unmoved"));
        assertEq(
            _spendable(address(punt), address(collat)),
            before.corePoolCollat,
            string.concat(what, ": margin pool still escrowed on the core")
        );

        // the oracle report settled and returned both posted legs to the reporter
        assertEq(
            _spendable(reporter, address(tokenA)) - before.reporterLeg1,
            postedLeg1,
            string.concat(what, ": leg1 settled back to the reporter")
        );
        assertEq(
            _spendable(reporter, address(tokenB)) - before.reporterLeg2,
            postedLeg2,
            string.concat(what, ": leg2 settled back to the reporter")
        );

        // compensation paid exactly once and cleared
        assertEq(
            _spendable(closeExecutor, address(0)) - before.executorEth,
            compOwed,
            string.concat(what, ": executor paid exactly the accrued compensation")
        );
        assertEq(punt.executionGasComp(reportId), 0, string.concat(what, ": compensation cleared"));
        assertEq(
            _spendable(address(punt), address(0)),
            before.coreEth - compOwed,
            string.concat(what, ": core released exactly that compensation")
        );
    }
}
