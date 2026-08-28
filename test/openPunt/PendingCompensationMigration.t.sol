// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CloseBase} from "./CloseBase.t.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {PuntErrors} from "../../src/libraries/PuntErrors.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice Auction execution compensation either migrates into the report that consumes the
 *         auction or returns to the swapper when the request is cancelled.
 */
contract PendingCompensationMigrationTest is CloseBase {
    uint128 internal constant REPORTER_COMP = 0.0005 ether;

    function setUp() public {
        _setUpClose();
    }

    function test_auctionStoresItsCompensationAsPending() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _startDefaultAuction(swapId, active);

        (uint128 pending, uint48 requestedAt, bool intent) = _closeState(swapId);
        assertEq(pending, CLOSE_COMP, "Dutch compensation pending");
        assertTrue(requestedAt != 0, "close request timestamp stored");
        assertTrue(intent, "close request live");
    }

    function test_claimedDutchMigratesPendingCompIntoItsReport() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);

        Matched memory mt = _reportWithDutch(swapId, d, active, p.preimage, reporter, REPORTER_COMP);

        (uint128 pending, uint48 requestedAt, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "pending tranche migrated");
        assertTrue(requestedAt != 0, "request timestamp retained");
        assertTrue(intent, "request applies to its report");
        assertEq(punt.executionGasComp(mt.reportId), CLOSE_COMP + REPORTER_COMP, "both report additions assigned");
        assertEq(_storedDutchState(swapId), bytes32(0), "claimed auction consumed");
    }

    function test_zeroExpectedHashClaimsAuctionAndMigratesCompensation() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        _startDefaultAuction(swapId, active);

        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);

        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "compensation migrated");
        assertTrue(intent, "close intent applies");
        assertEq(punt.executionGasComp(mt.reportId), CLOSE_COMP + REPORTER_COMP, "report fully compensated");
        assertEq(_storedDutchState(swapId), bytes32(0), "auction consumed");
    }

    function test_cancellingIdleAuctionRefundsPendingCompAndClearsIntent() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _startDefaultAuction(swapId, active);
        uint256 ethBefore = swapper.balance;

        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapId, active);

        (uint128 pending, uint48 deadline, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "pending compensation refunded");
        assertEq(deadline, 0, "still no report");
        assertFalse(intent, "idle close request withdrawn");
        assertEq(swapper.balance, ethBefore + CLOSE_COMP, "compensation returned");
    }

    function test_liveReportBlocksCancellationAndPreservesItsIntentAndCompensation() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        _startDefaultAuction(swapId, active);
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        uint256 assignedBefore = punt.executionGasComp(mt.reportId);

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.OracleGameInProgress.selector);
        puntLifecycle.cancelCloseAuction(swapId, active);

        (uint128 pending, uint48 requestedAt, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "nothing report-specific became refundable");
        assertTrue(requestedAt != 0, "request remains live");
        assertTrue(intent, "cancellation cannot revoke the live report intent");
        assertEq(punt.executionGasComp(mt.reportId), assignedBefore, "report compensation untouched");

        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "live report still closes");
    }

    function test_reportWithoutAnAuctionHasNoPendingMigration() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);

        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "no Dutch escrow exists");
        assertFalse(intent, "ordinary report has no close request");
        assertEq(punt.executionGasComp(mt.reportId), REPORTER_COMP, "only reporter contribution assigned");
    }
}
