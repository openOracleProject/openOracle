// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice Covers the report() liquidity gate:
 *
 *           if (amount1 > minAmount1 && preimage.disputeDelay != 0) revert InvalidAmount1;
 *
 *         - nonzero disputeDelay: amount1 must equal initialLiquidity exactly
 *         - zero disputeDelay:    amount1 may range up to the existing reportCeiling
 *
 * @dev Every case reaches an active position through the real sequence
 *      propose -> matchSwap -> settlement eligibility -> opening execute.
 *      `disputeDelayParam` is set before proposing, so the delay under test is the one
 *      the proposal actually hash-committed; nothing is patched in after matching.
 */
contract ReportLiquidityGateTest is OpenPuntBase {
    uint128 internal constant HIGHER_AMOUNT1 = 2 * INITIAL_LIQUIDITY;

    function setUp() public {
        _setUpAll();
    }

    // ── shared setup ────────────────────────────────────────────────────

    /// @dev Opens a real position whose committed MatcherPreimage carries `delay`,
    ///      and proves the delay genuinely survived into the committed state.
    function _openWithDisputeDelay(uint24 delay)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p)
    {
        disputeDelayParam = delay;

        Proposal memory proposal = _propose();
        assertEq(proposal.preimage.disputeDelay, delay, "proposal committed the delay under test");

        Matched memory mt = _matchSwap(proposal);
        // the delay reached the real oracle game too, straight from its packed log
        assertEq(mt.game.disputeDelay, delay, "opening oracle game carries the delay under test");
        assertEq(
            mt.swap.matcherPreimageHash,
            keccak256(abi.encode(proposal.preimage)),
            "position is bound to that exact preimage"
        );

        _advanceToSettlementEligibility();
        active = _executeOpening(mt, executor);
        assertTrue(active.active, "position is active");
        assertEq(punt.swapIdToReportId(proposal.swapId), 0, "no live report before the gate test");

        swapId = proposal.swapId;
        p = proposal;
    }

    // ── case 1: nonzero delay, exact liquidity succeeds ─────────────────

    function test_nonzeroDelay_exactLiquiditySucceeds() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openWithDisputeDelay(5);

        uint256 reporterAInt0 = _spendable(reporter, address(tokenA));
        uint256 expectedReportId = oracle.nextReportId();

        Matched memory closing = _reportOnPositionWithAmount1(
            swapId, _noDutch(), active, p.preimage, reporter, REPORT_EXEC_COMP, INITIAL_LIQUIDITY
        );

        assertEq(closing.reportId, expectedReportId, "new oracle game created");
        assertEq(closing.game.currentAmount1, INITIAL_LIQUIDITY, "oracle game holds exactly initialLiquidity");
        assertEq(closing.game.currentAmount2, AMOUNT2, "oracle game holds the quoted amount2");
        assertEq(closing.game.disputeDelay, 5, "new game inherits the nonzero delay");
        assertEq(punt.swapIdToReportId(swapId), expectedReportId, "sidecar points at the new report");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(active)), "active hash remains stable");
        assertEq(
            oracle.oracleGame(closing.reportId),
            keccak256(abi.encode(closing.game, closing.helper)),
            "reconstructed game hashes to the oracle's commitment"
        );
        assertEq(_spendable(reporter, address(tokenA)), reporterAInt0 - INITIAL_LIQUIDITY, "reporter funded leg1");
    }

    // ── case 2: nonzero delay, higher liquidity reverts ─────────────────

    function test_nonzeroDelay_higherLiquidityReverts() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openWithDisputeDelay(5);

        // pre-state
        bytes32 storedBefore = punt.swaps(swapId);
        uint256 nextReportIdBefore = oracle.nextReportId();
        uint256 reporterAInt0 = _spendable(reporter, address(tokenA));
        uint256 reporterBInt0 = _spendable(reporter, address(tokenB));
        uint256 reporterEthInt0 = _spendable(reporter, address(0));
        uint256 reporterAExt0 = tokenA.balanceOf(reporter);
        uint256 reporterBExt0 = tokenB.balanceOf(reporter);
        uint256 reporterEthExt0 = reporter.balance;

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.InvalidAmount1.selector);
        puntLifecycle.report(
            swapId, bytes32(0), active, p.preimage, _noTiming(), reporter, HIGHER_AMOUNT1, AMOUNT2, REPORT_EXEC_COMP
        );

        // position untouched
        assertEq(punt.swaps(swapId), storedBefore, "position hash unchanged");
        assertEq(punt.swapIdToReportId(swapId), 0, "sidecar still carries no report");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(active)), "stored active hash remains unchanged");

        // no oracle game was created
        assertEq(oracle.nextReportId(), nextReportIdBefore, "oracle nextReportId unchanged");
        assertEq(oracle.oracleGame(nextReportIdBefore), bytes32(0), "no game at the would-be reportId");

        // reporter paid nothing, internally or externally
        assertEq(_spendable(reporter, address(tokenA)), reporterAInt0, "reporter internal tokenA unchanged");
        assertEq(_spendable(reporter, address(tokenB)), reporterBInt0, "reporter internal tokenB unchanged");
        assertEq(_spendable(reporter, address(0)), reporterEthInt0, "reporter internal ETH unchanged");
        assertEq(tokenA.balanceOf(reporter), reporterAExt0, "reporter external tokenA unchanged");
        assertEq(tokenB.balanceOf(reporter), reporterBExt0, "reporter external tokenB unchanged");
        assertEq(reporter.balance, reporterEthExt0, "reporter external ETH unchanged");

        // no execution compensation was recorded anywhere
        assertEq(punt.executionGasComp(nextReportIdBefore), 0, "no comp on the would-be report");
        assertEq(punt.executionGasComp(0), 0, "no comp stranded on reportId zero");
        assertEq(_spendable(address(punt), address(0)), 0, "core took no ETH");
    }

    /// @dev The gate rejects any excess, not just a doubling — one wei over is still over.
    function test_nonzeroDelay_oneUnitOverReverts() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openWithDisputeDelay(5);
        bytes32 storedBefore = punt.swaps(swapId);

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.InvalidAmount1.selector);
        puntLifecycle.report(
            swapId, bytes32(0), active, p.preimage, _noTiming(), reporter, INITIAL_LIQUIDITY + 1, AMOUNT2, 0
        );

        assertEq(punt.swaps(swapId), storedBefore, "position hash unchanged");
    }

    // ── case 3: zero delay, higher in-range liquidity succeeds ──────────

    function test_zeroDelay_higherLiquiditySucceeds() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openWithDisputeDelay(0);

        uint256 reporterAInt0 = _spendable(reporter, address(tokenA));
        uint256 reporterBInt0 = _spendable(reporter, address(tokenB));
        uint256 expectedReportId = oracle.nextReportId();

        // sanity: the higher amount is inside the pre-existing ceiling, so only the new
        // disputeDelay rule could have blocked it.
        uint256 ceiling = 10 * uint256(INITIAL_LIQUIDITY) > ESCALATION_HALT ? ESCALATION_HALT : 10 * INITIAL_LIQUIDITY;
        assertLe(HIGHER_AMOUNT1, ceiling, "test amount is within reportCeiling");
        assertGt(HIGHER_AMOUNT1, INITIAL_LIQUIDITY, "test amount exceeds initialLiquidity");

        Matched memory closing = _reportOnPositionWithAmount1(
            swapId, _noDutch(), active, p.preimage, reporter, REPORT_EXEC_COMP, HIGHER_AMOUNT1
        );

        // the sidecar points at the new report while the active hash remains stable
        assertEq(closing.reportId, expectedReportId, "new oracle game created");
        assertEq(punt.swapIdToReportId(swapId), expectedReportId, "sidecar points at the new report");
        assertTrue(closing.swap.active, "position still active");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(active)), "active hash remains stable");

        // the real ReportSubmitted log carries the higher liquidity
        assertEq(closing.game.currentAmount1, HIGHER_AMOUNT1, "packed log shows the higher currentAmount1");
        assertEq(closing.game.currentAmount2, AMOUNT2, "packed log shows the quoted amount2");
        assertEq(closing.game.disputeDelay, 0, "new game carries the zero delay");
        assertEq(closing.game.currentReporter, reporter, "reporter owns the new game");

        // and it reconstructs the oracle's own commitment
        assertEq(
            oracle.oracleGame(closing.reportId),
            keccak256(abi.encode(closing.game, closing.helper)),
            "reconstructed game hashes to the oracle's commitment"
        );

        // the reporter genuinely funded the higher amount
        assertEq(
            _spendable(reporter, address(tokenA)), reporterAInt0 - HIGHER_AMOUNT1, "reporter funded the higher leg1"
        );
        assertEq(_spendable(reporter, address(tokenB)), reporterBInt0 - AMOUNT2, "reporter funded leg2");
        assertEq(
            punt.executionGasComp(closing.reportId), REPORT_EXEC_COMP, "execution comp recorded against the new report"
        );
    }

    /// @dev Zero delay still respects the pre-existing ceiling.
    function test_zeroDelay_aboveCeilingStillReverts() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openWithDisputeDelay(0);
        bytes32 storedBefore = punt.swaps(swapId);

        uint128 ceiling =
            10 * uint256(INITIAL_LIQUIDITY) > ESCALATION_HALT ? ESCALATION_HALT : uint128(10 * INITIAL_LIQUIDITY);

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.InvalidAmount1.selector);
        puntLifecycle.report(swapId, bytes32(0), active, p.preimage, _noTiming(), reporter, ceiling + 1, AMOUNT2, 0);

        assertEq(punt.swaps(swapId), storedBefore, "position hash unchanged");
        assertEq(oracle.oracleGame(oracle.nextReportId()), bytes32(0), "no game created");
    }

    /// @dev Below initialLiquidity is rejected regardless of the delay setting.
    function test_belowInitialLiquidityRevertsUnderEitherDelay() public {
        (uint256 swapIdA, OpenPuntStorage.MatchedSwap memory activeA, Proposal memory pA) = _openWithDisputeDelay(5);

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.InvalidAmount1.selector);
        puntLifecycle.report(
            swapIdA, bytes32(0), activeA, pA.preimage, _noTiming(), reporter, INITIAL_LIQUIDITY - 1, AMOUNT2, 0
        );

        (uint256 swapIdB, OpenPuntStorage.MatchedSwap memory activeB, Proposal memory pB) = _openWithDisputeDelay(0);

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.InvalidAmount1.selector);
        puntLifecycle.report(
            swapIdB, bytes32(0), activeB, pB.preimage, _noTiming(), reporter, INITIAL_LIQUIDITY - 1, AMOUNT2, 0
        );

        assertEq(punt.swaps(swapIdA), keccak256(abi.encode(activeA)), "position A unchanged");
        assertEq(punt.swaps(swapIdB), keccak256(abi.encode(activeB)), "position B unchanged");
    }
}
