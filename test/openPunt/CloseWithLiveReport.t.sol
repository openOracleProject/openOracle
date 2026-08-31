// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";

contract CloseWithLiveReportTest is CloseBase {
    uint128 internal constant REPORTER_COMP = 0.0005 ether;

    function setUp() public {
        _setUpClose();
    }

    function _positionWithLiveReport()
        internal
        returns (
            uint256 swapId,
            OpenPuntStorage.MatchedSwap memory active,
            OpenPuntStorage.MatcherPreimage memory preimage,
            Matched memory mt
        )
    {
        Proposal memory p;
        (swapId, active, p) = _openIdle();
        preimage = p.preimage;
        mt = _reportWithDutch(swapId, _noDutch(), active, preimage, reporter, REPORTER_COMP);
        assertEq(punt.closeRequestBlock(swapId), 0, "no request");
        assertEq(_storedDutchState(swapId), bytes32(0), "no auction");
    }

    function test_liveReportRegistersRequestAndTopsUpThatReport() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,, Matched memory mt) = _positionWithLiveReport();
        bytes32 positionHash = punt.swaps(swapId);
        uint256 compBefore = punt.executionGasComp(mt.reportId);

        vm.recordLogs();
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

        (uint256 reportIdTopic, uint128 added) = _readCloseIntentSet(vm.getRecordedLogs(), swapId);
        assertEq(reportIdTopic, mt.reportId, "live report");
        assertEq(added, CLOSE_COMP, "compensation addition");
        assertTrue(punt.closeRequestBlock(swapId) != 0, "request recorded");
        assertEq(punt.executionGasComp(mt.reportId), compBefore + CLOSE_COMP, "report topped up");
        assertEq(_storedDutchState(swapId), bytes32(0), "no auction created");
        assertEq(punt.swaps(swapId), positionHash, "stable position hash");
    }

    function test_liveErc20ReportRequiresOnlyExecutionCompensationAsMsgValue() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,, Matched memory mt) = _positionWithLiveReport();
        uint256 compBefore = punt.executionGasComp(mt.reportId);

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.InvalidMsgValue.selector);
        punt.close{value: CLOSE_COMP - 1}(
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

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.InvalidMsgValue.selector);
        punt.close{value: CLOSE_COMP + 1}(
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

        assertEq(punt.closeRequestBlock(swapId), 0, "rejected calls set no request");
        assertEq(punt.executionGasComp(mt.reportId), compBefore, "compensation unchanged");
    }

    function test_internalFundingUsesOnlyExecutionCompensation() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,, Matched memory mt) = _positionWithLiveReport();
        uint256 ledgerBefore = _spendable(swapper, address(0));
        uint256 compBefore = punt.executionGasComp(mt.reportId);

        vm.prank(swapper);
        punt.close(
            swapId,
            _dutchInput(),
            active,
            true,
            _emptyPermit2(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );
        assertEq(_spendable(swapper, address(0)), ledgerBefore - CLOSE_COMP, "only compensation consumed");
        assertEq(punt.executionGasComp(mt.reportId), compBefore + CLOSE_COMP, "report topped up");
    }

    function test_zeroCompensationStillRegistersTheRequest() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,, Matched memory mt) = _positionWithLiveReport();
        uint256 compBefore = punt.executionGasComp(mt.reportId);

        vm.prank(swapper);
        punt.close(
            swapId, _dutchInput(), active, false, _emptyPermit2(), 0, _emptyOracleGame(), _emptyOracleHelper(), 0
        );
        assertTrue(punt.closeRequestBlock(swapId) != 0, "request recorded");
        assertEq(punt.executionGasComp(mt.reportId), compBefore, "nothing added");
    }

    function test_secondCloseRevertsWhileTheRequestIsLive() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,,) = _positionWithLiveReport();
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

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.CloseIntentLive.selector);
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
    }

    function test_liveReportIgnoresDutchFieldsAndNeverCallsPermit2() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,, Matched memory mt) = _positionWithLiveReport();
        OpenPuntStorage.CloseDutch memory nonsense;
        nonsense.swapper = outsider;
        nonsense.collatToken = address(tokenB);
        nonsense.swapId = 12345;
        nonsense.start = 777;
        uint256 permitCalls = _permit2().callCount();

        vm.prank(swapper);
        punt.close{value: CLOSE_COMP}(
            swapId, nonsense, active, false, _emptyPermit2(), CLOSE_COMP, _emptyOracleGame(), _emptyOracleHelper(), 0
        );
        assertEq(_storedDutchState(swapId), bytes32(0), "no auction stored");
        assertEq(punt.executionGasComp(mt.reportId), REPORTER_COMP + CLOSE_COMP, "only comp changed");
        assertEq(_permit2().callCount(), permitCalls, "Permit2 untouched");
    }

    function test_onlySwapperMayRegisterTheRequest() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,,) = _positionWithLiveReport();
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.NotSwapper.selector);
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
        assertEq(punt.closeRequestBlock(swapId), 0, "no request");
    }

    function test_requestBeforeEligibilityClosesAndPaysCombinedCompensationOnce() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,, Matched memory mt) = _positionWithLiveReport();
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

        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "position closed");
        assertEq(_spendable(closeExecutor, address(0)), REPORTER_COMP + CLOSE_COMP, "executor paid");
        assertEq(punt.executionGasComp(mt.reportId), 0, "compensation consumed");
    }

    function test_requestAtEligibilityDoesNotUseTheOldPriceAndSurvivesForTheNextReport() public {
        (
            uint256 swapId,
            OpenPuntStorage.MatchedSwap memory active,
            OpenPuntStorage.MatcherPreimage memory preimage,
            Matched memory first
        ) = _positionWithLiveReport();
        uint256 eligibilityBlock = uint256(first.game.reportTimestamp) + first.game.settlementTime;
        _advanceChain((eligibilityBlock - vm.getBlockNumber()) * 2);

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
        assertEq(requestedAt, first.game.reportTimestamp + first.game.settlementTime, "exact boundary");

        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, first.swap, first.game, first.helper, 0);
        assertTrue(punt.swaps(swapId) != bytes32(0), "old report did not close");
        assertEq(punt.closeRequestBlock(swapId), requestedAt, "request preserved");

        Matched memory second = _reportWithDutch(swapId, _noDutch(), active, preimage, reporter, REPORTER_COMP);
        Vm.Log[] memory logs = _executeReport(swapId, second, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "next report closes");
    }
}
