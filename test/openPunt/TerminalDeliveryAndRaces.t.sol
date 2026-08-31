// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";

/**
 * @notice Terminal payout routing under all four position funding modes, plus the ordering
 *         races between reporting, cancelling and executing.
 *
 * @dev The payout route is chosen by the position's own `useInternalBalances`, independently
 *      of how any Dutch reward was funded. The matcher is always paid into its oracle ledger;
 *      only the swapper's leg switches route.
 */
contract TerminalDeliveryAndRacesTest is CloseBase {
    uint128 internal constant REPORTER_COMP = 0.0005 ether;

    function setUp() public {
        _setUpClose();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Terminal collateral delivery
    // ══════════════════════════════════════════════════════════════════

    struct Ledger {
        uint256 swapperExt;
        uint256 swapperInt;
        uint256 swapperEth;
        uint256 swapperEthInt;
        uint256 matcherInt;
        uint256 matcherEthInt;
    }

    function _ledger() internal view returns (Ledger memory l) {
        l.swapperExt = collat.balanceOf(swapper);
        l.swapperInt = _spendable(swapper, address(collat));
        l.swapperEth = swapper.balance;
        l.swapperEthInt = _spendable(swapper, address(0));
        l.matcherInt = _spendable(matcher, address(collat));
        l.matcherEthInt = _spendable(matcher, address(0));
    }

    /// @dev Opens, sets intent via a live report, closes, and returns the realised payouts.
    function _runTerminal(bool ethCollat, bool internalPos)
        internal
        returns (Ledger memory before, uint256 owedS, uint256 owedM, uint256 marginSum)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _positionCfg(ethCollat, internalPos);
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        marginSum = uint256(active.initialMarginSwapper) + active.initialMarginMatcher;

        // Intent through the live-report branch, before its fixed cutoff, so no Dutch reward is involved.
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        vm.prank(swapper);
        punt.close{value: 0}(
            swapId, _dutchInput(), mt.swap, true, _emptyPermit2(), 0, _emptyOracleGame(), _emptyOracleHelper(), 0
        );

        before = _ledger();
        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        (owedS, owedM) = _readPositionClosed(logs, swapId);

        // universal terminal post-conditions
        assertEq(owedS + owedM, marginSum, "payouts conserve the pool");
        assertEq(punt.swaps(swapId), bytes32(0), "position hash cleared");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "close state cleared");
        assertFalse(intent, "close intent cleared");
        assertEq(punt.executionGasComp(mt.reportId), 0, "execution compensation cleared");
        assertEq(_spendable(address(punt), active.collatToken), 0, "core holds no position collateral");
    }

    function test_erc20ExternalPositionPaysTheSwapperExternally() public {
        (Ledger memory b, uint256 owedS, uint256 owedM,) = _runTerminal(false, false);

        assertEq(collat.balanceOf(swapper) - b.swapperExt, owedS, "swapper paid externally");
        assertEq(_spendable(swapper, address(collat)), b.swapperInt, "swapper ledger untouched");
        assertEq(_spendable(matcher, address(collat)) - b.matcherInt, owedM, "matcher paid into its ledger");
    }

    function test_erc20InternalPositionPaysTheSwapperIntoTheLedger() public {
        (Ledger memory b, uint256 owedS, uint256 owedM,) = _runTerminal(false, true);

        assertEq(_spendable(swapper, address(collat)) - b.swapperInt, owedS, "swapper paid into the ledger");
        assertEq(collat.balanceOf(swapper), b.swapperExt, "external balance untouched");
        assertEq(_spendable(matcher, address(collat)) - b.matcherInt, owedM, "matcher paid into its ledger");
    }

    function test_ethExternalPositionPaysTheSwapperAsRawEth() public {
        (Ledger memory b, uint256 owedS, uint256 owedM,) = _runTerminal(true, false);

        assertEq(swapper.balance - b.swapperEth, owedS, "swapper paid as raw ETH");
        assertEq(_spendable(swapper, address(0)), b.swapperEthInt, "swapper ETH ledger untouched");
        assertEq(_spendable(matcher, address(0)) - b.matcherEthInt, owedM, "matcher paid into its ETH ledger");
    }

    function test_ethInternalPositionPaysTheSwapperIntoTheEthLedger() public {
        (Ledger memory b, uint256 owedS, uint256 owedM,) = _runTerminal(true, true);

        assertEq(_spendable(swapper, address(0)) - b.swapperEthInt, owedS, "swapper paid into the ETH ledger");
        assertEq(swapper.balance, b.swapperEth, "raw ETH untouched");
        assertEq(_spendable(matcher, address(0)) - b.matcherEthInt, owedM, "matcher paid into its ETH ledger");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Ordering: cancel first, then report
    // ══════════════════════════════════════════════════════════════════

    function test_cancelThenReport() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);

        uint256 swapperExt0 = collat.balanceOf(swapper);
        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapId, active);
        assertEq(collat.balanceOf(swapper) - swapperExt0, DUTCH_MAX, "reward returned before any report");

        // the auction no longer exists, so the reporter cannot claim anything
        uint256 reporterCollat0 = _spendable(reporter, address(collat));
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);

        assertEq(_spendable(reporter, address(collat)), reporterCollat0, "nothing left to claim");
        assertEq(punt.executionGasComp(mt.reportId), REPORTER_COMP, "only the reporter's own compensation");

        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        assertTrue(
            _hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "cancelled intent does not survive"
        );
        assertTrue(punt.swaps(swapId) != bytes32(0), "position remains active");
    }

    /// @dev Supplying the now-deleted preimage after cancellation is rejected outright.
    function test_cancelThenReportWithTheStalePreimageRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);

        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapId, active);

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.report(swapId, _expectedDutchHash(d), active, p.preimage, _noTiming(), reporter, A1, A2_OPEN, 0);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Ordering: report consumes first, then cancellation is unavailable
    // ══════════════════════════════════════════════════════════════════

    function test_reportConsumesAuctionAndThenBlocksCancellation() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        _startDefaultAuction(swapId, active);

        uint256 reporterCollat0 = _spendable(reporter, address(collat));
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        uint256 owed = uint256(CLOSE_COMP) + REPORTER_COMP;
        assertEq(punt.executionGasComp(mt.reportId), owed, "compensation migrated");
        assertEq(_spendable(reporter, address(collat)) - reporterCollat0, DUTCH_START, "auction claimed");
        assertEq(_storedDutchState(swapId), bytes32(0), "auction consumed");

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.OracleGameInProgress.selector);
        puntLifecycle.cancelCloseAuction(swapId, active);

        assertEq(punt.executionGasComp(mt.reportId), owed, "compensation stays with the report");

        _executeReport(swapId, mt, closeExecutor);
        assertEq(_spendable(closeExecutor, address(0)), owed, "executor still paid in full");
    }

    /// @dev Once a report holds the report id, a second reporter cannot consume or re-skip it.
    function test_secondReporterCannotConsumeTheAuctionAgain() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);

        Matched memory first = _reportWithDutch(swapId, d, active, p.preimage, reporter, REPORTER_COMP);
        assertEq(_storedDutchState(swapId), bytes32(0), "auction consumed by the first reporter");

        uint256 outsiderCollat0 = _spendable(outsider, address(collat));

        // the report sidecar is live, so no second report can start at all
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.OracleGameInProgress.selector);
        puntLifecycle.report(
            swapId, _expectedDutchHash(d), first.swap, p.preimage, _noTiming(), outsider, A1, A2_OPEN, 0
        );

        // The active preimage is stable, but the live report sidecar still blocks another report.
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.OracleGameInProgress.selector);
        puntLifecycle.report(swapId, _expectedDutchHash(d), active, p.preimage, _noTiming(), outsider, A1, A2_OPEN, 0);

        assertEq(_spendable(outsider, address(collat)), outsiderCollat0, "no second reward");
        assertEq(punt.executionGasComp(first.reportId), uint256(CLOSE_COMP) + REPORTER_COMP, "compensation intact");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Terminal state cannot be replayed
    // ══════════════════════════════════════════════════════════════════

    function test_staleCallsAfterTerminalExecutionCannotDuplicatePayouts() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);

        Matched memory mt = _reportWithDutch(swapId, d, active, p.preimage, reporter, REPORTER_COMP);
        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);
        assertTrue(owedS + owedM > 0, "position closed");

        uint256 swapperExt = collat.balanceOf(swapper);
        uint256 matcherInt = _spendable(matcher, address(collat));
        uint256 execEth = _spendable(closeExecutor, address(0));

        // stale report
        vm.prank(reporter);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.report(swapId, bytes32(0), mt.swap, p.preimage, _noTiming(), reporter, A1, A2_OPEN, 0);

        // stale close
        vm.prank(swapper);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.close{value: 0}(
            swapId, _dutchInput(), mt.swap, false, _emptyPermit2(), 0, _emptyOracleGame(), _emptyOracleHelper(), 0
        );

        // stale execute
        vm.prank(executor);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);

        // Stale cancellation: the auction was claimed, so its hash is gone.
        vm.prank(swapper);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.cancelCloseAuction(swapId, active);

        assertEq(collat.balanceOf(swapper), swapperExt, "swapper payout not duplicated");
        assertEq(_spendable(matcher, address(collat)), matcherInt, "matcher payout not duplicated");
        assertEq(_spendable(closeExecutor, address(0)), execEth, "executor compensation not duplicated");
        assertEq(_spendable(address(punt), address(collat)), 0, "core still holds nothing");
    }

    function test_claimAnyLeavesNoAuctionEscrowAfterTerminalExecution() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        _startDefaultAuction(swapId, active);

        uint256 swapperExt0 = collat.balanceOf(swapper);
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        assertEq(collat.balanceOf(swapper) - swapperExt0, DUTCH_MAX - DUTCH_START, "remainder returned at report");
        assertEq(_storedDutchState(swapId), bytes32(0), "auction consumed at report");
        _executeReport(swapId, mt, closeExecutor);
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        uint256 swapperAfterTerminal = collat.balanceOf(swapper);

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.cancelCloseAuction(swapId, active);

        assertEq(collat.balanceOf(swapper), swapperAfterTerminal, "nothing paid twice");
        assertEq(_spendable(address(punt), address(collat)), 0, "core fully drained");
    }
}
