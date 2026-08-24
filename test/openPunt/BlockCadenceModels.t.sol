// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice The block-cadence predicate across the three configured chain profiles, driven through
 *         the real propose -> match -> execute lifecycle.
 *
 * @dev Reference model, derived here without reading production state:
 *
 *          elapsedMilliseconds  = (block.timestamp - reportTimestamp) * 1000
 *          expectedMilliseconds = (block.number - reportBlockNumber) * millisecondsPerBlock
 *          accepted  <=>  |expectedMilliseconds - elapsedMilliseconds| <= 2000
 *
 *      The tolerance is two seconds of time, not two blocks: how many blocks fit inside it
 *      depends entirely on the chain's block interval, which is exactly what these profiles show.
 *
 *      OpenPunt creates its games with `flags: 0`, so the oracle clock counts blocks: settlement
 *      eligibility is `blockNumber >= reportBlock +
 *      settlementTime(blocks)` and carries no wall-clock requirement at all. A position can
 *      therefore become executable within a single timestamp, and the zero-elapsed boundary is
 *      exercised directly below rather than approximated at one second.
 */
contract BlockCadenceModelsTest is OpenPuntBase {
    uint16 internal constant MS_BASE = 2_000; // Base: one block / 2 s
    uint16 internal constant MS_ROBINHOOD = 100; // Robinhood Chain: ten blocks / s
    uint16 internal constant MS_ETHEREUM = 12_000; // Ethereum: one block / 12 s

    function setUp() public {
        _setUpAll();
        collat.mint(swapper, type(uint96).max);
    }

    // ── driver ──────────────────────────────────────────────────────────

    /// @dev Setup only, stopping just before `execute()`, so a test can wrap the execution alone
    ///      in `vm.expectRevert` without the earlier lifecycle calls absorbing it.
    function _prepareCadence(uint16 msPerBlock, uint48 settlementTime, uint256 dt, uint256 blocks)
        internal
        returns (Proposal memory p, Matched memory mt)
    {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();
        s.millisecondsPerBlock = msPerBlock;
        s.maxGameTime = 604800;
        m.settlementTime = settlementTime;
        m.disputeDelay = 0;

        p = _proposeWith(s, m, swapper);
        mt = _matchSwapWith(p, AMOUNT2, matcher);
        _advanceTimeAndBlocks(dt, blocks);
    }

    function _executeCadence(Proposal memory p, Matched memory mt) internal {
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, false);
    }

    function _runCadence(uint16 msPerBlock, uint48 settlementTime, uint256 dt, uint256 blocks)
        internal
        returns (uint256 swapId, Vm.Log[] memory logs)
    {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();
        s.millisecondsPerBlock = msPerBlock;
        s.maxGameTime = 604800; // the 7-day cap: never the binding constraint here
        m.settlementTime = settlementTime;
        m.disputeDelay = 0;

        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, AMOUNT2, matcher);

        _advanceTimeAndBlocks(dt, blocks);

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, false);
        logs = vm.getRecordedLogs();
        swapId = p.swapId;
    }

    /// @dev Settlement eligibility is purely block-based, so `blocks` must be at least
    ///      `settlementTime` for `execute()` to be reachable at all. Every case below respects
    ///      that, which is why the cadence bands are chosen to sit above the settlement window.
    function _assertAccepted(uint16 msPerBlock, uint48 settlementTime, uint256 dt, uint256 blocks, string memory what)
        internal
    {
        (uint256 swapId, Vm.Log[] memory logs) = _runCadence(msPerBlock, settlementTime, dt, blocks);
        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            string.concat(what, ": no cadence bailout")
        );
        _findLog(logs, address(punt), OpenPuntStorage.PositionOpened.selector, swapId); // reverts if absent
        assertTrue(punt.swaps(swapId) != bytes32(0), string.concat(what, ": position live"));
    }

    function _assertRejected(uint16 msPerBlock, uint48 settlementTime, uint256 dt, uint256 blocks, string memory what)
        internal
    {
        (uint256 swapId, Vm.Log[] memory logs) = _runCadence(msPerBlock, settlementTime, dt, blocks);
        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            string.concat(what, ": cadence bailout emitted")
        );
        _findLog(logs, address(punt), OpenPuntStorage.PositionOpeningFailed.selector, swapId); // reverts if absent
        assertEq(punt.swaps(swapId), bytes32(0), string.concat(what, ": position deleted"));
    }

    // ══════════════════════════════════════════════════════════════════
    //  Base — 2,000 ms/block, dt = 300 s, elapsed = 300,000 ms
    // ══════════════════════════════════════════════════════════════════
    //   149 blocks -> 298,000 ms, 2,000 below : accepted (inclusive edge)
    //   150 blocks -> 300,000 ms, exact       : accepted
    //   151 blocks -> 302,000 ms, 2,000 above : accepted (inclusive edge)
    //   148 blocks -> 296,000 ms, 4,000 below : rejected
    //   152 blocks -> 304,000 ms, 4,000 above : rejected

    function test_base_exactCadenceAccepted() public {
        _assertAccepted(MS_BASE, 100, 300, 150, "base exact");
    }

    function test_base_lowerEdgeAccepted() public {
        _assertAccepted(MS_BASE, 100, 300, 149, "base lower edge");
    }

    function test_base_upperEdgeAccepted() public {
        _assertAccepted(MS_BASE, 100, 300, 151, "base upper edge");
    }

    function test_base_belowLowerEdgeRejected() public {
        _assertRejected(MS_BASE, 100, 300, 148, "base below lower edge");
    }

    function test_base_aboveUpperEdgeRejected() public {
        _assertRejected(MS_BASE, 100, 300, 152, "base above upper edge");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Robinhood — 100 ms/block
    // ══════════════════════════════════════════════════════════════════
    //  dt = 10 s, elapsed = 10,000 ms:
    //    80 blocks  ->  8,000 ms, 2,000 below : accepted (inclusive edge)
    //   100 blocks  -> 10,000 ms, exact       : accepted
    //   120 blocks  -> 12,000 ms, 2,000 above : accepted (inclusive edge)
    //    79 blocks  ->  7,900 ms, 2,100 below : rejected
    //   121 blocks  -> 12,100 ms, 2,100 above : rejected

    function test_robinhood_exactCadenceAccepted() public {
        _assertAccepted(MS_ROBINHOOD, 50, 10, 100, "robinhood exact");
    }

    function test_robinhood_lowerEdgeAccepted() public {
        _assertAccepted(MS_ROBINHOOD, 50, 10, 80, "robinhood lower edge");
    }

    function test_robinhood_upperEdgeAccepted() public {
        _assertAccepted(MS_ROBINHOOD, 50, 10, 120, "robinhood upper edge");
    }

    function test_robinhood_oneBlockBelowLowerEdgeRejected() public {
        _assertRejected(MS_ROBINHOOD, 50, 10, 79, "robinhood below lower edge");
    }

    function test_robinhood_oneBlockAboveUpperEdgeRejected() public {
        _assertRejected(MS_ROBINHOOD, 50, 10, 121, "robinhood above upper edge");
    }

    /**
     * @notice Many blocks sharing one integer second are handled correctly.
     *
     * @dev dt = 1 s, elapsed = 1,000 ms. 30 blocks is 3,000 ms expected, exactly 2,000 ms above
     *      elapsed, so it is the inclusive edge; 31 blocks is 3,100 ms and fails. Thirty blocks
     *      inside a single second being accepted is the clearest statement that the allowance is
     *      two seconds of time rather than a block count.
     */
    function test_robinhood_manyBlocksInsideOneSecondAccepted() public {
        _assertAccepted(MS_ROBINHOOD, 20, 1, 30, "robinhood 30 blocks in 1s");
    }

    function test_robinhood_oneBlockTooManyInsideOneSecondRejected() public {
        _assertRejected(MS_ROBINHOOD, 20, 1, 31, "robinhood 31 blocks in 1s");
    }

    // ── zero elapsed wall-clock time ────────────────────────────────────
    //  dt = 0 s, elapsed = 0 ms, at 100 ms/block:
    //    20 blocks -> 2,000 ms expected, exactly the allowance : accepted
    //    21 blocks -> 2,100 ms expected                        : rejected

    /**
     * @notice Twenty blocks inside a single timestamp are accepted; twenty-one are not.
     *
     * @dev This is the boundary that was unreachable while the oracle clock ran on timestamps.
     *      The settlement window is 20 blocks and exactly 20 blocks are produced, so the position
     *      becomes eligible and executes without the wall clock advancing at all.
     */
    function test_zeroElapsedSecondsAtTheExactAllowanceAccepted() public {
        _assertAccepted(MS_ROBINHOOD, 20, 0, 20, "20 blocks in zero seconds");
    }

    function test_zeroElapsedSecondsOneBlockBeyondTheAllowanceRejected() public {
        _assertRejected(MS_ROBINHOOD, 20, 0, 21, "21 blocks in zero seconds");
    }

    /// @dev The same-timestamp property is not specific to Robinhood: at 2,000 ms/block a single
    ///      block inside one timestamp is exactly the allowance, and two blocks is 4,000 ms.
    function test_sameTimestampDifferentBlockAtBaseCadence() public {
        _assertAccepted(MS_BASE, 1, 0, 1, "1 block in zero seconds at 2000 ms/block");
        _assertRejected(MS_BASE, 1, 0, 2, "2 blocks in zero seconds at 2000 ms/block");
    }

    // ── exact settlement eligibility ────────────────────────────────────

    /**
     * @notice Eligibility is `blockNumber >= reportBlock + settlementTime`, counted in blocks and
     *         independent of the wall clock.
     *
     * @dev Exactly `settlementTime` blocks is eligible; one block fewer reverts
     *      `OracleSettlementNotEligible` even if a great deal of wall-clock time has passed.
     */
    function test_exactBlockSettlementEligibility() public {
        _assertAccepted(MS_ROBINHOOD, 20, 2, 20, "exactly settlementTime blocks");
    }

    function test_oneBlockShortOfEligibilityReverts() public {
        (Proposal memory p, Matched memory mt) = _prepareCadence(MS_ROBINHOOD, 20, 2, 19);
        vm.expectRevert(PuntErrors.OracleSettlementNotEligible.selector);
        _executeCadence(p, mt);
    }

    /// @dev And abundant wall-clock time does not substitute for the missing block.
    function test_wallClockTimeDoesNotSubstituteForBlocks() public {
        (Proposal memory p, Matched memory mt) = _prepareCadence(MS_ROBINHOOD, 20, 10_000, 19);
        vm.expectRevert(PuntErrors.OracleSettlementNotEligible.selector);
        _executeCadence(p, mt);
    }

    /// @dev The allowance is two seconds, not two blocks: at 100 ms/block it spans 41 distinct
    ///      block counts, at 2,000 ms/block only 3, and at 12,000 ms/block only 1.
    function test_theAllowanceIsTimeNotBlocks() public pure {
        assertEq(_acceptedBandWidth(MS_ROBINHOOD, 10), 41, "robinhood: 80..120 inclusive");
        assertEq(_acceptedBandWidth(MS_BASE, 300), 3, "base: 149..151 inclusive");
        assertEq(_acceptedBandWidth(MS_ETHEREUM, 1200), 1, "ethereum: only the exact block count");
    }

    /// @dev Counts how many block deltas satisfy |db*msPerBlock - dt*1000| <= 2000, by direct
    ///      enumeration of the derived inequality rather than by calling production code.
    function _acceptedBandWidth(uint256 msPerBlock, uint256 dt) internal pure returns (uint256 n) {
        uint256 elapsed = dt * 1000;
        uint256 centre = elapsed / msPerBlock;
        for (uint256 db = centre > 60 ? centre - 60 : 0; db <= centre + 60; db++) {
            uint256 expected = db * msPerBlock;
            uint256 diff = expected > elapsed ? expected - elapsed : elapsed - expected;
            if (diff <= 2000) n++;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  Ethereum — 12,000 ms/block
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice A long perfect-cadence interval that the legacy blocks-per-second representation cannot express.
     *
     * @dev 100 blocks over 1,200 s is exactly 12 s per block. Under the milliseconds-per-block model
     *      expected = 100 * 12,000 = 1,200,000 ms and elapsed = 1,200,000 ms, so the difference is
     *      zero and it passes with the full tolerance to spare; no drift accumulates however long
     *      the window.
     */
    function test_ethereum_longPerfectCadenceAccepted() public {
        _assertAccepted(MS_ETHEREUM, 50, 1200, 100, "ethereum 100 blocks / 1200s");
    }

    function test_ethereum_evenLongerPerfectCadenceAccepted() public {
        _assertAccepted(MS_ETHEREUM, 50, 3600, 300, "ethereum 300 blocks / 3600s");
    }

    /// @dev With 12 s blocks the two-second tolerance is narrower than a single block, so only the
    ///      exact count is accepted — one block either way is 12,000 ms out.
    function test_ethereum_oneBlockEitherSideRejected() public {
        _assertRejected(MS_ETHEREUM, 50, 1200, 99, "ethereum one block short");
    }

    function test_ethereum_oneBlockOverRejected() public {
        _assertRejected(MS_ETHEREUM, 50, 1200, 101, "ethereum one block over");
    }

    /**
     * @notice The legacy thousandths-of-a-block-per-second representation rejects that
     *         same perfect interval purely from rounding.
     *
     * @dev Twelve-second blocks are 1000/12 = 83.33... thousandths of a block per second, which is
     *      not representable. Both candidate roundings are evaluated here using the legacy formula —
     *      reproduced locally for the comparison, and never used as the reference model for any
     *      acceptance assertion above.
     */
    function test_ethereum_oldRepresentationWouldHaveFailedThisInterval() public pure {
        uint256 dt = 1200;
        uint256 db = 100;

        // Legacy representation: accepted <=> |1000*db - dt*bps| <= 2*bps
        (bool ok83, uint256 diff83, uint256 slack83) = _oldModel(dt, db, 83);
        (bool ok84, uint256 diff84, uint256 slack84) = _oldModel(dt, db, 84);

        assertFalse(ok83, "old model with bps = 83 rejects a perfect 12s cadence");
        assertFalse(ok84, "old model with bps = 84 rejects a perfect 12s cadence");
        assertEq(diff83, 400, "bps 83 drifts 400 thousandths-of-a-block over the window");
        assertEq(slack83, 166, "against a slack of only 166");
        assertEq(diff84, 800, "bps 84 drifts 800 the other way");
        assertEq(slack84, 168, "against a slack of only 168");

        // The milliseconds-per-block model is exact for the same interval.
        uint256 elapsedMs = dt * 1000;
        uint256 expectedMs = db * uint256(MS_ETHEREUM);
        assertEq(expectedMs, elapsedMs, "the new representation has zero error");
    }

    function _oldModel(uint256 dt, uint256 db, uint256 bps)
        internal
        pure
        returns (bool ok, uint256 diff, uint256 slack)
    {
        uint256 expected = dt * bps;
        uint256 actual = 1000 * db;
        diff = actual > expected ? actual - expected : expected - actual;
        slack = 2 * bps;
        ok = diff <= slack;
    }

    // ══════════════════════════════════════════════════════════════════
    //  _getBlockNumber() routing
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice The cadence predicate reads the chain height through OpenPunt's centralized
     *         accessor, from inside the delegatecalled lifecycle module.
     *
     * @dev No harness and no fabricated oracle state: the routing is exercised by the ordinary
     *      lifecycle above. Two runs that differ only in `vm.roll` produce opposite cadence
     *      verdicts, proving that the delegatecalled module reads the core's chain-height accessor.
     */
    function test_theModuleReadsChainHeightThroughTheCentralizedAccessor() public {
        uint256 snap = vm.snapshotState();
        (uint256 idA, Vm.Log[] memory logsA) = _runCadence(MS_BASE, 100, 300, 150);
        bool bailedA = _hasBailoutLog(logsA, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, idA);
        vm.revertToState(snap);

        (uint256 idB, Vm.Log[] memory logsB) = _runCadence(MS_BASE, 100, 300, 400);
        bool bailedB = _hasBailoutLog(logsB, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, idB);

        assertFalse(bailedA, "150 blocks: accepted");
        assertTrue(bailedB, "400 blocks over the same 300s: rejected");
        assertTrue(bailedA != bailedB, "the verdict depends on the height the module actually read");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Validation
    // ══════════════════════════════════════════════════════════════════

    /// @dev A zero interval is still rejected through the ordinary proposal path, and 1 is still
    ///      accepted, so the boundary did not move with the representation.
    function test_zeroMillisecondsPerBlockIsRejectedAndOneIsAccepted() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        uint256 idBefore = punt.nextSwapId();

        s.millisecondsPerBlock = 0;
        _proposeBad(s, _defaultMatcherPreimage(), PuntErrors.InvalidOracleParams.selector, "millisecondsPerBlock 0");
        assertEq(punt.nextSwapId(), idBefore, "no swapId consumed by the rejected proposal");

        s.millisecondsPerBlock = 1;
        _proposeOk(s, _defaultMatcherPreimage(), "millisecondsPerBlock 1");
    }

    /**
     * @notice The extreme interval is accepted, but only alongside a settlement window and a game
     *         timeout that satisfy the two coupled bounds.
     *
     * @dev `propose()` requires settlementTime * millisecondsPerBlock <= 4 hours and
     *      maxGameTime * 1000 >= that product * 20. At 65_535 ms/block those bind hard: 30 blocks
     *      is 1_966_050 ms of settlement, which forces maxGameTime >= 39_321 s. This is the real
     *      shape of the parameter space, and it is why a large millisecondsPerBlock cannot be
     *      combined with a large block-denominated settlement window.
     */
    function test_extremeMillisecondsPerBlockRequiresACompatibleWindow() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();
        s.millisecondsPerBlock = type(uint16).max;

        // the fixture window is far too long for this interval
        _proposeBad(s, m, PuntErrors.InvalidOracleParams.selector, "max interval, default window");

        // 30 blocks * 65_535 ms = 1_966_050 ms of settlement. The rule is
        //     maxGameTime * 1000 >= settlementDurationMilliseconds * 20
        // so maxGameTime must be at least 1_966_050 * 20 / 1000 = 39_321 seconds.
        m.settlementTime = 30;
        m.disputeDelay = 5;
        s.maxGameTime = 39_320;
        _proposeBad(s, m, PuntErrors.InvalidOracleParams.selector, "one second short of the ratio");

        s.maxGameTime = 39_321;
        _proposeOk(s, m, "exactly the minimum compatible window");
    }
}
