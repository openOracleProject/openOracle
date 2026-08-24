// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CloseBase} from "./CloseBase.t.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
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
        punt.close{value: CLOSE_COMP}(swapId, _dutchInput(), mt.swap, false, _emptyPermit2(), CLOSE_COMP);

        (, uint48 requestedAt, bool intent) = _closeState(swapId);
        assertTrue(intent, "intent applies to this report");
        assertTrue(uint256(requestedAt) < eligibility, "request predates eligibility");
        assertEq(punt.executionGasComp(mt.reportId), compBefore + CLOSE_COMP, "compensation attached to this report");

        _advanceChain(2);
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, false);
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
        punt.close{value: CLOSE_COMP}(swapId, _dutchInput(), mt.swap, false, _emptyPermit2(), CLOSE_COMP);

        (, uint48 requestedAt, bool intentAfter) = _closeState(swapId);
        assertEq(requestedAt, eligibility, "request recorded at eligibility");
        assertTrue(intentAfter, "request remains for a future report");
        assertEq(punt.executionGasComp(mt.reportId), compBefore + CLOSE_COMP, "current executor is still paid");
        assertEq(_storedDutchState(swapId), bytes32(0), "a live report needs no auction");

        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, false);
        assertTrue(punt.swaps(swapId) != bytes32(0), "old healthy report is reusable");
        assertEq(punt.closeRequestBlock(swapId), requestedAt, "future request survives");
    }

    function test_aSettledKnownPriceCannotBeAdoptedWithLateIntent() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);

        _advanceToSettlementEligibility();
        _settleDirect(mt, settler);
        mt.game.settlementTimestamp = uint48(vm.getBlockNumber());
        assertEq(oracle.oracleGame(mt.reportId), keccak256(abi.encode(mt.game, mt.helper)), "settled preimage");

        vm.prank(swapper);
        punt.close{value: 0}(swapId, _dutchInput(), mt.swap, true, _emptyPermit2(), 0);

        assertEq(_storedDutchState(swapId), bytes32(0), "live report path creates no auction");
        (, uint48 requestedAt, bool intentBeforeExecute) = _closeState(swapId);
        assertTrue(intentBeforeExecute, "late request is retained for a future report");
        assertTrue(
            uint256(requestedAt) >= uint256(mt.game.reportTimestamp) + mt.game.settlementTime,
            "known report cannot use the request"
        );

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "healthy report remains reusable");
        (, uint48 requestAfter, bool intent) = _closeState(swapId);
        assertEq(requestAfter, requestedAt, "future request survives");
        assertTrue(intent, "future request remains live");
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

    function test_terminalMaturityCloseClearsALateRequestWithoutCreatingAnAuction() public {
        (uint256 swapId, Matched memory mt) = _reportEndingRelativeToMaturity(0);

        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(swapId, _dutchInput(), mt.swap, false, _emptyPermit2(), CLOSE_COMP);
        assertEq(_storedDutchState(swapId), bytes32(0), "live report path creates no auction");
        assertTrue(punt.closeRequestBlock(swapId) != 0, "request recorded");

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, false);
        assertTrue(_hasLog(vm.getRecordedLogs(), OpenPuntStorage.PositionClosed.selector, swapId), "maturity closes");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        assertEq(punt.closeRequestBlock(swapId), 0, "terminal state clears request");
    }

    function test_eligibilityJustBeforeMaturityStaysReusableHoweverLate() public {
        (uint256 swapId, Matched memory mt) = _reportEndingRelativeToMaturity(-2);
        _advanceChain(30 days);

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "pre-maturity eligibility");
        assertTrue(punt.swaps(swapId) != bytes32(0), "position survives");
    }

    function test_eligibilityExactlyAtMaturityCloses() public {
        (uint256 swapId, Matched memory mt) = _reportEndingRelativeToMaturity(0);
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, false);
        assertTrue(
            _hasLog(vm.getRecordedLogs(), OpenPuntStorage.PositionClosed.selector, swapId), "inclusive at maturity"
        );
    }

    function test_eligibilityAfterMaturityCloses() public {
        (uint256 swapId, Matched memory mt) = _reportEndingRelativeToMaturity(2);
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, false);
        assertTrue(
            _hasLog(vm.getRecordedLogs(), OpenPuntStorage.PositionClosed.selector, swapId), "past maturity closes"
        );
    }

    function _startAuction(uint256 swapId, OpenPuntStorage.MatchedSwap memory active) internal {
        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(swapId, _defaultCloseDutch(), active, false, _emptyPermit2(), CLOSE_COMP);
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
