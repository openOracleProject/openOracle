// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice bailOutOpen() reached naturally, plus the ordering races between bailing out and
 *         executing the opening.
 */
contract OpeningBailoutsTest is OpenPuntBase {
    function setUp() public {
        _setUpAll();
        collat.mint(swapper, 1_000_000e18);
        vm.deal(swapper, 100 ether);
        _mintAndDeposit(collat, matcher, 1_000_000e18);
        _mintAndDeposit(tokenA, matcher, 1_000e18);
        _mintAndDeposit(tokenB, matcher, 1_000_000e18);
    }

    /// @dev Moves to exactly `start + maxGameTime`, the last instant bailout is refused.
    function _warpToTimeoutBoundary(OpenPuntStorage.MatchedSwap memory s) internal {
        uint256 target = uint256(s.start) + uint256(s.maxGameTime);
        uint256 delta = target - vm.getBlockTimestamp();
        _advanceTimeAndBlocks(delta, delta / 2);
        assertEq(vm.getBlockTimestamp(), target, "sitting on the timeout boundary");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Rejections
    // ══════════════════════════════════════════════════════════════════

    function test_bailoutBeforeMatchRejects() public {
        Proposal memory p = _propose();
        bytes32 storedBefore = punt.swaps(p.swapId);

        OpenPuntStorage.MatchedSwap memory empty;
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.bailOutOpen(p.swapId, empty);

        assertEq(punt.swaps(p.swapId), storedBefore, "proposal phase preserved");
    }

    function test_bailoutOnActivePositionRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openPosition();
        bytes32 storedBefore = punt.swaps(swapId);

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.CantBailOutYet.selector);
        punt.bailOutOpen(swapId, active);

        assertEq(punt.swaps(swapId), storedBefore, "active position preserved");
    }

    function test_bailoutBeforeTimeoutRejects() public {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);

        _advanceChain(1000); // well short of maxGameTime (6000)

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.CantBailOutYet.selector);
        punt.bailOutOpen(p.swapId, mt.swap);

        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(mt.swap)), "matched phase preserved");
    }

    /// @dev The contract uses a strict `>`, so the boundary instant itself is still refused.
    function test_bailoutAtExactTimeoutBoundaryRejects() public {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        _warpToTimeoutBoundary(mt.swap);

        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherCollat0 = _spendable(matcher, address(collat));

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.CantBailOutYet.selector);
        punt.bailOutOpen(p.swapId, mt.swap);

        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(mt.swap)), "matched phase preserved");
        assertEq(collat.balanceOf(swapper), swapperExt0, "no refund at the boundary");
        assertEq(_spendable(matcher, address(collat)), matcherCollat0, "no refund at the boundary");
        assertEq(punt.tempHolding(outsider), 0, "no compensation at the boundary");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Success
    // ══════════════════════════════════════════════════════════════════

    function test_bailoutOneSecondPastTimeoutSucceedsForAnyone() public {
        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherCollat0 = _spendable(matcher, address(collat));
        uint256 matcherA0 = _spendable(matcher, address(tokenA));
        uint256 matcherB0 = _spendable(matcher, address(tokenB));

        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        assertEq(punt.tempHolding(matcher), MATCHER_GAS_COMP, "matcher gas comp queued at match");

        _warpToTimeoutBoundary(mt.swap);
        vm.warp(vm.getBlockTimestamp() + 1);

        // an unrelated third party performs the bailout
        vm.recordLogs();
        vm.prank(outsider);
        punt.bailOutOpen(p.swapId, mt.swap);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _findLog(logs, address(punt), OpenPuntStorage.OpeningBailedOut.selector, p.swapId);
        _findLog(logs, address(punt), OpenPuntStorage.SwapRefunded.selector, p.swapId);

        assertEq(punt.swaps(p.swapId), bytes32(0), "swap hash deleted");

        // both margins returned in full, no fee taken
        assertEq(collat.balanceOf(swapper), swapperExt0, "swapper margin refunded externally");
        assertEq(_spendable(matcher, address(collat)), matcherCollat0, "matcher margin refunded internally");
        assertEq(_spendable(address(punt), address(collat)), 0, "core drained of collateral");

        // caller earns the opening execution compensation; matcher keeps its own
        assertEq(punt.tempHolding(outsider), OPEN_EXEC_COMP, "caller receives opening execution comp");
        assertEq(punt.tempHolding(matcher), MATCHER_GAS_COMP, "matcher retains matcher gas comp");

        // the oracle legs are still locked in the live game at this point
        assertEq(_spendable(matcher, address(tokenA)), matcherA0 - INITIAL_LIQUIDITY, "leg1 still in the oracle game");
        assertEq(_spendable(matcher, address(tokenB)), matcherB0 - AMOUNT2, "leg2 still in the oracle game");

        // ...and the game is untouched by the bailout: it settles independently
        assertTrue(oracle.oracleGame(mt.reportId) != bytes32(0), "oracle game still committed");
        _settleDirect(mt, settler);

        assertEq(_spendable(matcher, address(tokenA)), matcherA0, "leg1 returned by independent settlement");
        assertEq(_spendable(matcher, address(tokenB)), matcherB0, "leg2 returned by independent settlement");
        assertEq(_spendable(settler, address(0)), SETTLER_REWARD, "settler reward paid to whoever settled");
    }

    function test_bailoutCallerIsPaidRegardlessOfIdentity() public {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        _warpToTimeoutBoundary(mt.swap);
        vm.warp(vm.getBlockTimestamp() + 1);

        // the swapper themself bails out this time
        vm.prank(swapper);
        punt.bailOutOpen(p.swapId, mt.swap);

        assertEq(punt.tempHolding(swapper), OPEN_EXEC_COMP, "swapper-as-caller receives the comp");
        assertEq(punt.swaps(p.swapId), bytes32(0), "swap hash deleted");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Phase races
    // ══════════════════════════════════════════════════════════════════

    function test_bailoutFirstMakesLaterOpeningExecutionFail() public {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        _warpToTimeoutBoundary(mt.swap);
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(outsider);
        punt.bailOutOpen(p.swapId, mt.swap);
        assertEq(punt.swaps(p.swapId), bytes32(0), "terminal");

        uint256 swapperExt = collat.balanceOf(swapper);
        uint256 matcherCollat = _spendable(matcher, address(collat));

        // the opening executor arrives late with a state that no longer exists
        vm.prank(executor);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, false);

        assertEq(punt.swaps(p.swapId), bytes32(0), "terminal phase not resurrected");
        assertEq(collat.balanceOf(swapper), swapperExt, "no second refund");
        assertEq(_spendable(matcher, address(collat)), matcherCollat, "no second refund");
        assertEq(punt.tempHolding(executor), 0, "late executor earns nothing");
    }

    function test_openingExecutionFirstMakesLaterBailoutFail() public {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        _advanceToSettlementEligibility();

        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);
        bytes32 activeHash = punt.swaps(p.swapId);

        // push past the would-be timeout so only the phase check can reject
        _warpToTimeoutBoundary(mt.swap);
        vm.warp(vm.getBlockTimestamp() + 1);

        // stale pre-opening state no longer hashes
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.bailOutOpen(p.swapId, mt.swap);

        // the current state hashes, but the position is active
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.CantBailOutYet.selector);
        punt.bailOutOpen(p.swapId, active);

        assertEq(punt.swaps(p.swapId), activeHash, "active phase not overwritten");
        assertEq(punt.tempHolding(outsider), 0, "failed bailout pays nothing");
    }

    function test_repeatedBailoutCannotDoubleRefund() public {
        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherCollat0 = _spendable(matcher, address(collat));

        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        _warpToTimeoutBoundary(mt.swap);
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(outsider);
        punt.bailOutOpen(p.swapId, mt.swap);

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.bailOutOpen(p.swapId, mt.swap);

        assertEq(collat.balanceOf(swapper), swapperExt0, "swapper refunded exactly once");
        assertEq(_spendable(matcher, address(collat)), matcherCollat0, "matcher refunded exactly once");
        assertEq(punt.tempHolding(outsider), OPEN_EXEC_COMP, "caller compensated exactly once");
    }
}
