// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CloseBase} from "./CloseBase.t.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice A close request applies to a report only when its recorded block precedes that report's
///         settlement eligibility. Maturity is also decided at settlement eligibility.
contract CloseRequestTimingTest is CloseBase {
    uint128 internal constant REPORTER_COMP = 0.0005 ether;

    function setUp() public {
        _setUpClose();
    }

    function test_intentWaitingBeforeAReportClosesThatReport() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        _startAuction(swapId, active);

        (, uint48 requestedAt, bool intentBefore) = _closeState(swapId);
        assertTrue(requestedAt != 0, "request recorded when the auction starts");
        assertTrue(intentBefore, "request is live before a report starts");

        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        (, uint48 requestAfter, bool intent) = _closeState(swapId);
        assertEq(requestAfter, requestedAt, "report does not rewrite the request timestamp");
        assertTrue(uint256(requestAfter) < uint256(mt.game.reportTimestamp) + p.preimage.settlementTime);
        assertTrue(intent, "request remains live");

        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "standing intent closes");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
    }

    function test_intentOneBlockBeforeTheDeadlineAppliesToTheLiveReport() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);

        uint256 eligibility = uint256(mt.game.reportTimestamp) + mt.game.settlementTime;
        _advanceChain((eligibility - vm.getBlockNumber() - 1) * 2);
        assertEq(vm.getBlockNumber() + 1, eligibility, "one block remains");

        uint256 compBefore = punt.executionGasComp(mt.reportId);
        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(
            swapId,
            _dutchInput(),
            mt.swap,
            false,
            _emptyPermit2(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );

        (, uint48 requestedAt, bool intent) = _closeState(swapId);
        assertTrue(intent, "intent applies to this report");
        assertTrue(uint256(requestedAt) < eligibility, "request predates eligibility");
        assertEq(punt.executionGasComp(mt.reportId), compBefore + CLOSE_COMP, "compensation attached to this report");

        _advanceChain(2);
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);
        assertTrue(_hasLog(vm.getRecordedLogs(), OpenPuntStorage.PositionClosed.selector, swapId), "same report closes");
    }

    function test_intentExactlyAtEligibilityAppliesOnlyToTheNextReport() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);

        uint256 eligibility = uint256(mt.game.reportTimestamp) + mt.game.settlementTime;
        _advanceChain((eligibility - vm.getBlockNumber()) * 2);
        assertEq(vm.getBlockNumber(), eligibility, "exact eligibility block");
        uint256 compBefore = punt.executionGasComp(mt.reportId);

        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(
            swapId,
            _dutchInput(),
            mt.swap,
            false,
            _emptyPermit2(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );

        (, uint48 requestedAt, bool intentAfter) = _closeState(swapId);
        assertEq(requestedAt, eligibility, "request recorded at eligibility");
        assertTrue(intentAfter, "request remains for a future report");
        assertEq(punt.executionGasComp(mt.reportId), compBefore, "future compensation does not pay old executor");
        OpenPuntStorage.StoredDutch memory auction = _storedAuction(swapId);
        assertEq(auction.maxReward, DUTCH_MAX, "future auction funded");
        assertEq(auction.executionComp, CLOSE_COMP, "future compensation remains with auction");
        bytes32 auctionHash = _storedDutchState(swapId);
        assertTrue(auctionHash != bytes32(0), "future auction stored");

        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);
        assertTrue(punt.swaps(swapId) != bytes32(0), "old healthy report is reusable");
        assertEq(punt.closeRequestBlock(swapId), requestedAt, "future request survives");
        assertEq(_storedDutchState(swapId), auctionHash, "future auction survives old report");

        Matched memory next = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        assertEq(
            punt.executionGasComp(next.reportId),
            uint256(REPORTER_COMP) + CLOSE_COMP,
            "future report inherits queued compensation"
        );
        Vm.Log[] memory logs = _executeReport(swapId, next, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "future report closes");
    }

    function test_aSettledKnownPriceCannotBeAdoptedWithLateIntent() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);

        _advanceToSettlementEligibility();
        _settleDirect(mt, settler);
        mt.game.settlementTimestamp = uint48(vm.getBlockNumber());
        assertEq(oracle.oracleGame(mt.reportId), keccak256(abi.encode(mt.game, mt.helper)), "settled preimage");

        vm.prank(swapper);
        punt.close{value: 0}(
            swapId, _dutchInput(), mt.swap, true, _emptyPermit2(), 0, _emptyOracleGame(), _emptyOracleHelper(), 0
        );

        assertTrue(_storedDutchState(swapId) != bytes32(0), "known eligible report creates a future auction");
        (, uint48 requestedAt, bool intentBeforeExecute) = _closeState(swapId);
        assertTrue(intentBeforeExecute, "late request is retained for a future report");
        assertTrue(
            uint256(requestedAt) >= uint256(mt.game.reportTimestamp) + mt.game.settlementTime,
            "known report cannot use the request"
        );

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "healthy report remains reusable");
        (, uint48 requestAfter, bool intent) = _closeState(swapId);
        assertEq(requestAfter, requestedAt, "future request survives");
        assertTrue(intent, "future request remains live");
    }

    function test_matchingEligiblePreimagesAutoExecuteBeforeOpeningTheFutureAuction() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        Matched memory oldReport = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        _advanceToSettlementEligibility();

        uint256 swapperEthLedgerBefore = _spendable(swapper, address(0));
        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(
            swapId,
            _dutchInput(),
            oldReport.swap,
            false,
            _emptyPermit2(),
            CLOSE_COMP,
            oldReport.game,
            oldReport.helper,
            0
        );

        assertEq(punt.swapIdToReportId(swapId), 0, "eligible old report auto-executed");
        assertEq(punt.executionGasComp(oldReport.reportId), 0, "old compensation consumed once");
        assertEq(
            _spendable(swapper, address(0)) - swapperEthLedgerBefore,
            REPORTER_COMP,
            "swapper performed and earned the old execution"
        );
        OpenPuntStorage.StoredDutch memory auction = _storedAuction(swapId);
        assertEq(auction.maxReward, DUTCH_MAX, "future auction created after reusable execution");
        assertEq(auction.executionComp, CLOSE_COMP, "new compensation belongs to the future report");
        assertTrue(punt.closeRequestBlock(swapId) != 0, "future request recorded");
    }

    function test_mismatchedEligiblePreimagesCreateAFutureAuctionWithoutTouchingTheOldReport() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        Matched memory oldReport = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        _advanceToSettlementEligibility();
        IOpenOracle2.PreimageHelper memory wrongHelper = oldReport.helper;
        wrongHelper.reportId += 1;

        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(
            swapId, _dutchInput(), oldReport.swap, false, _emptyPermit2(), CLOSE_COMP, oldReport.game, wrongHelper, 0
        );

        assertEq(punt.swapIdToReportId(swapId), oldReport.reportId, "old report remains live on-chain");
        assertEq(punt.executionGasComp(oldReport.reportId), REPORTER_COMP, "old executor receives no new compensation");
        OpenPuntStorage.StoredDutch memory auction = _storedAuction(swapId);
        assertEq(auction.maxReward, DUTCH_MAX, "future auction funded");
        assertEq(auction.executionComp, CLOSE_COMP, "future compensation remains queued");
    }

    function test_disputeExtendedEligibilityKeepsTheCurrentReportLiveForClose() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        uint256 originalEligibility = oracle.settlementEligibility(mt.reportId);

        uint256 hopBlocks = uint256(mt.game.disputeDelay) + 1;
        _advanceTimeAndBlocks(_secondsForBlocks(hopBlocks), hopBlocks);
        uint128 disputedAmount1 = uint128(uint256(mt.game.currentAmount1) * mt.game.multiplier / 100);
        uint128 disputedAmount2 = uint128(uint256(mt.game.currentAmount2) * mt.game.multiplier / 100);
        vm.prank(matcher);
        IOpenOracle2(address(oracle)).dispute(
            mt.reportId, disputedAmount1, disputedAmount2, matcher, true, true, mt.game, mt.helper, _noTiming()
        );

        uint256 extendedEligibility = oracle.settlementEligibility(mt.reportId);
        assertGt(extendedEligibility, originalEligibility, "dispute moved stored eligibility");
        if (vm.getBlockNumber() < originalEligibility) {
            _advanceTimeAndBlocks(
                _secondsForBlocks(originalEligibility - vm.getBlockNumber()), originalEligibility - vm.getBlockNumber()
            );
        }
        assertLt(vm.getBlockNumber(), extendedEligibility, "replacement report is still live");

        uint256 compBefore = punt.executionGasComp(mt.reportId);
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

        assertEq(_storedDutchState(swapId), bytes32(0), "live disputed report needs no future auction");
        assertEq(punt.executionGasComp(mt.reportId), compBefore + CLOSE_COMP, "current report receives compensation");
    }

    function test_terminalCloseDeletesTheWholeCloseState() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        _startAuction(swapId, active);
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        _executeReport(swapId, mt, closeExecutor);

        (uint128 pending, uint48 deadline, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "pending compensation deleted");
        assertEq(deadline, 0, "deadline deleted");
        assertFalse(intent, "intent deleted");
    }

    function test_terminalMaturityCloseRefundsTheUnusedFutureAuction() public {
        (uint256 swapId, Matched memory mt) = _reportEndingRelativeToMaturity(0);
        uint256 swapperCollatBefore = collat.balanceOf(swapper);
        uint256 swapperEthBefore = swapper.balance;

        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(
            swapId,
            _dutchInput(),
            mt.swap,
            false,
            _emptyPermit2(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );
        assertTrue(_storedDutchState(swapId) != bytes32(0), "future auction funded while old report remains");
        assertEq(swapperCollatBefore - collat.balanceOf(swapper), DUTCH_MAX, "reward escrowed");
        assertEq(swapperEthBefore - swapper.balance, CLOSE_COMP, "compensation escrowed");
        assertTrue(punt.closeRequestBlock(swapId) != 0, "request recorded");

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);
        assertTrue(_hasLog(vm.getRecordedLogs(), OpenPuntStorage.PositionClosed.selector, swapId), "maturity closes");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        assertEq(punt.closeRequestBlock(swapId), 0, "terminal state clears request");
        assertEq(_storedDutchState(swapId), bytes32(0), "terminal state deletes auction");
        assertEq(collat.balanceOf(swapper), swapperCollatBefore + MARGIN_S, "reward returned beside terminal payout");
        assertEq(swapper.balance, swapperEthBefore, "unused compensation returned");
    }

    function test_matchingEligibleMaturityReportAutoExecutesAndReturnsUnusedCallValue() public {
        (uint256 swapId, Matched memory mt) = _reportEndingRelativeToMaturity(0);
        uint256 swapperEthBefore = swapper.balance;
        uint256 swapperCollatBefore = collat.balanceOf(swapper);

        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(
            swapId, _dutchInput(), mt.swap, false, _emptyPermit2(), CLOSE_COMP, mt.game, mt.helper, 0
        );

        assertEq(punt.swaps(swapId), bytes32(0), "maturity report terminated the position");
        assertEq(punt.swapIdToReportId(swapId), 0, "terminal report cleared");
        assertEq(punt.closeRequestBlock(swapId), 0, "no future request created");
        assertEq(_storedDutchState(swapId), bytes32(0), "no future auction created");
        assertEq(swapper.balance, swapperEthBefore, "unused call value returned");
        assertEq(collat.balanceOf(swapper), swapperCollatBefore + MARGIN_S, "terminal payout delivered normally");
    }

    function test_terminalMaturityReturnsAnInternallyFundedFutureAuctionToTheLedger() public {
        (uint256 swapId, Matched memory mt) = _reportEndingRelativeToMaturity(0);
        uint256 collatLedgerBefore = _spendable(swapper, address(collat));
        uint256 ethLedgerBefore = _spendable(swapper, address(0));

        vm.prank(swapper);
        punt.close(
            swapId,
            _dutchInput(),
            mt.swap,
            true,
            _emptyPermit2(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );
        assertEq(collatLedgerBefore - _spendable(swapper, address(collat)), DUTCH_MAX, "internal reward escrowed");
        assertEq(ethLedgerBefore - _spendable(swapper, address(0)), CLOSE_COMP, "internal compensation escrowed");

        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);

        assertEq(_spendable(swapper, address(collat)), collatLedgerBefore, "reward returned to internal balance");
        assertEq(_spendable(swapper, address(0)), ethLedgerBefore, "compensation returned to internal balance");
        assertEq(_storedDutchState(swapId), bytes32(0), "terminal state deleted internal auction");
    }

    function test_eligibilityJustBeforeMaturityStaysReusableHoweverLate() public {
        (uint256 swapId, Matched memory mt) = _reportEndingRelativeToMaturity(-2);
        _advanceChain(30 days);

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "pre-maturity eligibility");
        assertTrue(punt.swaps(swapId) != bytes32(0), "position survives");
    }

    function test_eligibilityExactlyAtMaturityCloses() public {
        (uint256 swapId, Matched memory mt) = _reportEndingRelativeToMaturity(0);
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);
        assertTrue(
            _hasLog(vm.getRecordedLogs(), OpenPuntStorage.PositionClosed.selector, swapId), "inclusive at maturity"
        );
    }

    function test_eligibilityAfterMaturityCloses() public {
        (uint256 swapId, Matched memory mt) = _reportEndingRelativeToMaturity(2);
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, 0);
        assertTrue(
            _hasLog(vm.getRecordedLogs(), OpenPuntStorage.PositionClosed.selector, swapId), "past maturity closes"
        );
    }

    function _startAuction(uint256 swapId, OpenPuntStorage.MatchedSwap memory active) internal {
        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(
            swapId,
            _defaultCloseDutch(),
            active,
            false,
            _emptyPermit2(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );
    }

    function _reportEndingRelativeToMaturity(int256 offset) internal returns (uint256 swapId, Matched memory mt) {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        swapId = sid;

        uint256 window = _secondsForBlocks(SETTLEMENT_BLOCKS);
        uint256 target = uint256(active.maturity) + uint256(offset >= 0 ? uint256(offset) : 0)
            - (offset < 0 ? uint256(-offset) : 0) - window;
        uint256 hop = target - vm.getBlockTimestamp();
        _advanceChain(hop - (hop % 2));

        mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        _advanceToSettlementEligibility();
    }
}
