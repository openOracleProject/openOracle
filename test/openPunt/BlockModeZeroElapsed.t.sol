// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ActivePositionBase.t.sol";

/**
 * @notice A complete active-position lifecycle in which the wall clock never advances.
 *
 * @dev Block mode makes this reachable: settlement eligibility is `blockNumber >= reportBlock +
 *      settlementTime(blocks)` and carries no wall-clock requirement, so a position can be opened,
 *      reported on and closed inside a single timestamp. The property is carried through
 *      to a terminal outcome.
 *
 *      With millisecondsPerBlock = 100 and settlementTime = 20 blocks, the settlement
 *      window is 2,000 ms of implied time and each execution sits on the inclusive cadence edge:
 *
 *          elapsed  = 0 ms          (no timestamp advance)
 *          expected = 20 * 100 ms   = 2,000 ms
 *          |expected - elapsed| = 2,000 <= 2,000   -> accepted, exactly at the boundary
 *
 *      The funding term is `(closingReportWall + D) - start` with
 *      `start == openingReportWall + D`, so D cancels and the elapsed time is the wall-clock gap
 *      between the two reports — zero here. With a nonzero funding rate configured, funding of
 *      exactly zero is therefore evidence that the subtraction resolved to zero rather than
 *      underflowing or picking up the conversion term.
 */
contract BlockModeZeroElapsedTest is ActivePositionBase {
    uint16 internal constant MS_ROBINHOOD = 100;
    uint48 internal constant SETTLE_BLOCKS = 20;

    /// @dev A large positive rate: swapper pays matcher. 1e7 == 100% annual, so this is 50%.
    int32 internal constant LIVE_RATE = 5_000_000;

    function setUp() public {
        _setUpAccounting();
    }

    function _zeroElapsedCfg()
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _cfgZeroFee(LIVE_RATE); // zero fulfillment fee, funding fixed at LIVE_RATE
        s.isLong = true;
        s.millisecondsPerBlock = MS_ROBINHOOD;
        s.maturityWindow = MATURITY_LONG; // never mature; the close is driven by intent
        m.settlementTime = SETTLE_BLOCKS;
        m.disputeDelay = 5; // strictly below the settlement window, in blocks
    }

    /// @dev Advances blocks only. The timestamp is deliberately untouched.
    function _rollOnly(uint256 blocks) internal {
        vm.roll(vm.getBlockNumber() + blocks);
    }

    function test_fullActiveLifecycleInsideASingleTimestamp() public {
        uint256 t0 = vm.getBlockTimestamp();

        // ── open: 20 blocks, zero seconds ────────────────────────────────
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _zeroElapsedCfg();
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory opening = _matchSwapWith(p, A2_OPEN, matcher);

        assertEq(uint256(opening.game.lastReportOppoTime), t0, "opening report wall clock is t0");
        _rollOnly(SETTLE_BLOCKS);
        assertEq(vm.getBlockTimestamp(), t0, "no wall-clock time has passed");

        OpenPuntStorage.MatchedSwap memory active = _executeOpening(opening, executor);

        assertTrue(active.active, "opened inside a single timestamp");
        assertGt(active.fundingRate, 0, "the position genuinely carries a nonzero funding rate");
        // start == openingReportWall + floor(20 * 100 / 1000) == t0 + 2
        assertEq(uint256(active.start), t0 + 2, "start is the report wall clock plus the converted window");

        // ── report and close intent, still at t0 ────────────────────────
        Matched memory closing = _reportOnPositionWithAmounts(
            p.swapId, _noDutch(), active, p.preimage, reporter, REPORT_EXEC_COMP, A1, A2_OPEN
        );
        assertEq(uint256(closing.game.lastReportOppoTime), t0, "closing report wall clock is t0");

        vm.prank(swapper);
        punt.close{value: CLOSE_EXEC_COMP}(
            p.swapId,
            _noDutch(),
            closing.swap,
            false,
            _emptyPermit2(),
            CLOSE_EXEC_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );
        (, uint48 requestedAt, bool intent) = _closeState(p.swapId);
        assertTrue(intent, "close intent applies to the live report");
        assertEq(requestedAt, vm.getBlockNumber(), "request block stored");
        assertLt(requestedAt, closing.game.reportTimestamp + SETTLE_BLOCKS, "request precedes eligibility");

        // ── execute the close: 20 blocks, still zero seconds ─────────────
        // the swapper funded externally, so its payout lands in the ERC20 balance; the matcher
        // posted from the oracle ledger and is repaid there. Two different ledgers, checked apart.
        uint256 swapperBefore = collat.balanceOf(swapper);
        uint256 matcherBefore = _spendable(matcher, address(collat));

        _rollOnly(SETTLE_BLOCKS);
        assertEq(vm.getBlockTimestamp(), t0, "still no wall-clock time has passed");

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, closing.game, closing.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // ── the transition happened, and no cadence bailout occurred ─────
        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, p.swapId),
            "cadence accepted at the inclusive edge"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, p.swapId), "closed through intent");
        assertEq(punt.swaps(p.swapId), bytes32(0), "position resolved");

        // ── funding elapsed time was exactly zero ────────────────────────
        // Price is flat (A2_OPEN both sides) and the fulfillment fee is zero, so with zero funding
        // each party is owed exactly its own margin back. Any nonzero funding would move both.
        (uint256 owedToSwapper, uint256 owedToMatcher) = _readPositionClosed(logs, p.swapId);
        assertEq(owedToSwapper, MARGIN_S, "swapper owed exactly its margin: funding contributed nothing");
        assertEq(owedToMatcher, MARGIN_M, "matcher owed exactly its margin: funding contributed nothing");
        assertEq(collat.balanceOf(swapper) - swapperBefore, MARGIN_S, "and that is what it received");
        assertEq(_spendable(matcher, address(collat)) - matcherBefore, MARGIN_M, "and that is what it received");
    }

    /**
     * @notice The identical position accrues funding when wall-clock time elapses.
     *
     * @dev Without this, the zero-funding assertions above would also hold if the funding rate
     *      were silently inert. The only difference here is that the closing report is placed a
     *      day later, with a block cadence that keeps the check satisfied.
     */
    function test_controlTheSameConfigurationAccruesFundingWhenTimePasses() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _zeroElapsedCfg();
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory opening = _matchSwapWith(p, A2_OPEN, matcher);

        _rollOnly(SETTLE_BLOCKS);
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(opening, executor);

        // one day later, at the configured 100 ms/block cadence: 10 blocks per second
        uint256 gap = 1 days;
        _advanceTimeAndBlocks(gap, gap * 1000 / uint256(MS_ROBINHOOD));

        Matched memory closing = _reportOnPositionWithAmounts(
            p.swapId, _noDutch(), active, p.preimage, reporter, REPORT_EXEC_COMP, A1, A2_OPEN
        );
        vm.prank(swapper);
        punt.close{value: CLOSE_EXEC_COMP}(
            p.swapId,
            _noDutch(),
            closing.swap,
            false,
            _emptyPermit2(),
            CLOSE_EXEC_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );

        _advanceTimeAndBlocks(2, 20);
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, closing.game, closing.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, p.swapId),
            "cadence still satisfied"
        );
        (uint256 owedToSwapper, uint256 owedToMatcher) = _readPositionClosed(logs, p.swapId);
        assertLt(owedToSwapper, MARGIN_S, "the swapper paid funding once time elapsed");
        assertGt(owedToMatcher, MARGIN_M, "and the matcher received it");
    }
}
