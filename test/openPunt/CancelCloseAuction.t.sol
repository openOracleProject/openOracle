// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";

contract CancelCloseAuctionTest is CloseBase {
    uint128 internal constant REPORTER_COMP = 0.0005 ether;

    function setUp() public {
        _setUpClose();
    }

    function test_swapperCancelsTheRequestAndRecoversExternalFunding() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _startDefaultAuction(swapId, active);
        uint256 collatBefore = collat.balanceOf(swapper);
        uint256 ethBefore = swapper.balance;
        bytes32 positionHash = punt.swaps(swapId);

        vm.recordLogs();
        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapId, active);

        Vm.Log memory cancelled =
            _findLog(vm.getRecordedLogs(), address(punt), OpenPuntStorage.CloseAuctionCancelled.selector, swapId);
        assertEq(cancelled.topics.length, 2, "only event signature and swap id are indexed");
        assertEq(cancelled.data.length, 0, "cancel event carries no repeated auction data");
        assertEq(collat.balanceOf(swapper) - collatBefore, DUTCH_MAX, "reward refunded");
        assertEq(swapper.balance - ethBefore, CLOSE_COMP, "compensation refunded");
        assertEq(_storedDutchState(swapId), bytes32(0), "auction deleted");
        assertEq(punt.closeRequestBlock(swapId), 0, "request cleared");
        assertEq(punt.swaps(swapId), positionHash, "position unchanged");
    }

    function test_cancelledRequestDoesNotCloseALaterReport() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        _startDefaultAuction(swapId, active);

        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapId, active);

        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "reusable report");
        assertTrue(punt.swaps(swapId) != bytes32(0), "position remains active");
    }

    function test_outsiderCannotCancel() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _startDefaultAuction(swapId, active);
        Snap memory before = _snap(swapId, active.collatToken);

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.NotSwapper.selector);
        puntLifecycle.cancelCloseAuction(swapId, active);
        _assertUnchanged(before, swapId, active.collatToken, "outsider cancel");
    }

    function test_requestCannotBeCancelledTwice() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _startDefaultAuction(swapId, active);

        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapId, active);

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.NothingToWithdraw.selector);
        puntLifecycle.cancelCloseAuction(swapId, active);
    }

    function test_liveReportPreventsIntentRevocationAndHasAlreadyConsumedTheAuction() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);
        uint256 swapperCollatBefore = collat.balanceOf(swapper);
        uint256 reporterBefore = _spendable(reporter, address(collat));

        Matched memory mt = _reportWithDutch(swapId, d, active, p.preimage, reporter, REPORTER_COMP);
        uint256 reward = DUTCH_START;

        assertEq(_storedDutchState(swapId), bytes32(0), "report consumed auction");
        assertEq(collat.balanceOf(swapper) - swapperCollatBefore, DUTCH_MAX - reward, "leftover refunded");
        assertEq(_spendable(reporter, address(collat)) - reporterBefore, reward, "reporter rewarded");

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.OracleGameInProgress.selector);
        puntLifecycle.cancelCloseAuction(swapId, active);

        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "request remains binding");
    }

    function test_lateRequestCanBeCancelledAfterTheOldReportClears() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        _advanceToSettlementEligibility();

        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(
            swapId,
            _dutchInput(),
            active,
            false,
            _emptyPermit2(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );
        uint48 requestedAt = punt.closeRequestBlock(swapId);
        assertTrue(requestedAt >= mt.game.reportTimestamp + mt.game.settlementTime, "too late for old report");

        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);
        assertEq(punt.swapIdToReportId(swapId), 0, "old report cleared");
        assertEq(punt.closeRequestBlock(swapId), requestedAt, "future request preserved");

        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapId, active);
        assertEq(punt.closeRequestBlock(swapId), 0, "future request cancelled");
    }

    function test_internallyFundedAuctionRefundsToTheLedger() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _startAuction(swapId, active, _dutchInput(), true, CLOSE_COMP);
        uint256 collatBefore = _spendable(swapper, address(collat));
        uint256 ethBefore = _spendable(swapper, address(0));

        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapId, active);
        assertEq(_spendable(swapper, address(collat)) - collatBefore, DUTCH_MAX, "collateral ledger refund");
        assertEq(_spendable(swapper, address(0)) - ethBefore, CLOSE_COMP, "ETH ledger refund");
    }

    function test_ethCollateralRefundsRewardAndCompensationTogether() public {
        (OpenPuntStorage.ProposedSwap memory ps, OpenPuntStorage.MatcherPreimage memory pm) = _positionCfg(true, false);
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openAccounting(ps, pm);
        _startAuction(swapId, active, _dutchInput(), false, CLOSE_COMP);
        uint256 before = swapper.balance;

        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapId, active);
        assertEq(swapper.balance - before, uint256(DUTCH_MAX) + CLOSE_COMP, "combined ETH refund");
    }

    function test_cancellingOneAuctionDoesNotDisturbAnother() public {
        (uint256 swapIdA, OpenPuntStorage.MatchedSwap memory activeA,) = _openIdle();
        (uint256 swapIdB, OpenPuntStorage.MatchedSwap memory activeB,) = _openIdle();
        _startDefaultAuction(swapIdA, activeA);
        _startDefaultAuction(swapIdB, activeB);
        bytes32 auctionB = _storedDutchState(swapIdB);
        uint48 requestB = punt.closeRequestBlock(swapIdB);

        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapIdA, activeA);
        assertEq(_storedDutchState(swapIdA), bytes32(0), "A cancelled");
        assertEq(_storedDutchState(swapIdB), auctionB, "B auction unchanged");
        assertEq(punt.closeRequestBlock(swapIdB), requestB, "B request unchanged");
    }
}
