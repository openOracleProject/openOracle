// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LivenessBase.t.sol";

/// @notice Recovery metadata is additive and follows the same real lifecycle transitions as events.
contract RecoveryIndexTest is LivenessBase {
    function setUp() public {
        _setUpLiveness();
    }

    function test_proposalsAreIndexedPerSwapperWithTheirExactBlocks() public {
        collat.transfer(outsider, 2 * INITIAL_MARGIN_SWAPPER);
        vm.prank(outsider);
        collat.approve(PERMIT2, type(uint256).max);

        uint48 firstBlock = uint48(vm.getBlockNumber());
        Proposal memory first = _propose();

        _advanceTimeAndBlocks(2, 1);
        uint48 outsiderBlock = uint48(vm.getBlockNumber());
        Proposal memory other = _proposeWith(_defaultProposedSwap(), _defaultMatcherPreimage(), outsider);

        _advanceTimeAndBlocks(2, 1);
        uint48 secondBlock = uint48(vm.getBlockNumber());
        Proposal memory second = _propose();

        assertEq(punt.numSwapsBySwapper(swapper), 2, "swapper count");
        assertEq(punt.numSwapsBySwapper(outsider), 1, "outsider count");

        _assertPackedProposal(swapper, 0, first.swapId, firstBlock);
        _assertPackedProposal(swapper, 1, second.swapId, secondBlock);
        _assertPackedProposal(outsider, 0, other.swapId, outsiderBlock);
    }

    function test_recoveryBlocksFollowOpeningReportAndClosingLifecycle() public {
        uint48 proposalBlock = uint48(vm.getBlockNumber());
        Proposal memory p = _propose();
        _assertPackedProposal(swapper, 0, p.swapId, proposalBlock);
        _assertRecovery(p.swapId, 0, 0, 0, "proposed");

        _advanceTimeAndBlocks(2, 1);
        uint48 openingReportBlock = uint48(vm.getBlockNumber());
        Matched memory opening = _matchSwap(p);
        _assertRecovery(p.swapId, 0, 0, openingReportBlock, "opening report live");

        _advanceToSettlementEligibility();
        uint48 openedBlock = uint48(vm.getBlockNumber());
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(opening, executor);
        _assertRecovery(p.swapId, openedBlock, 0, 0, "position opened");

        OpenPuntStorage.CloseDutch memory dutch = _startDefaultAuction(p.swapId, active);
        _advanceTimeAndBlocks(2, 1);
        uint48 closingReportBlock = uint48(vm.getBlockNumber());
        Matched memory closing = _reportWithDutch(p.swapId, dutch, active, p.preimage, reporter, REPORT_EXEC_COMP);
        _assertRecovery(p.swapId, openedBlock, 0, closingReportBlock, "closing report live");

        Vm.Log[] memory logs = _executeReport(p.swapId, closing, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, p.swapId), "position closed");
        _assertRecovery(p.swapId, openedBlock, uint48(vm.getBlockNumber()), 0, "position terminal");
    }

    function test_reusableReportClearsOnlyReportStartBlock() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        (uint48 openedBlock,,) = punt.recoveryBlocks(swapId);
        assertTrue(openedBlock != 0, "position has opening block");

        _advanceTimeAndBlocks(2, 1);
        uint48 reportBlock = uint48(vm.getBlockNumber());
        Matched memory report = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, 0);
        _assertRecovery(swapId, openedBlock, 0, reportBlock, "reusable report live");

        Vm.Log[] memory logs = _executeReport(swapId, report, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "report released");
        assertTrue(punt.swaps(swapId) != bytes32(0), "position remains live");
        _assertRecovery(swapId, openedBlock, 0, 0, "reusable report cleared");
    }

    function test_liquidationRecordsTerminalBlockAndPreservesOpenedBlock() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_LONG;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        (uint48 openedBlock,,) = punt.recoveryBlocks(swapId);

        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_OPEN - 1500e18, ELAPSED_STD);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "position liquidated");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        _assertRecovery(swapId, openedBlock, uint48(vm.getBlockNumber()), 0, "liquidation terminal");
    }

    function test_unmatchedCancellationKeepsProposalIndexButCreatesNoLifecycleBlocks() public {
        uint48 proposedBlock = uint48(vm.getBlockNumber());
        Proposal memory p = _propose();

        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(punt.swaps(p.swapId), bytes32(0), "proposal ended");
        assertEq(punt.numSwapsBySwapper(swapper), 1, "history entry retained");
        _assertPackedProposal(swapper, 0, p.swapId, proposedBlock);
        _assertRecovery(p.swapId, 0, 0, 0, "unmatched cancellation");
    }

    function test_manualOpeningTimeoutClearsReportWithoutOpeningOrTerminalBlock() public {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        _assertRecovery(p.swapId, 0, 0, uint48(vm.getBlockNumber()), "opening report live");

        _advanceChain(uint256(mt.swap.maxGameTime) + 2);
        vm.prank(outsider);
        punt.bailOutOpen(p.swapId, mt.swap);

        assertEq(punt.swaps(p.swapId), bytes32(0), "opening removed");
        assertEq(punt.swapIdToReportId(p.swapId), 0, "opening report cleared");
        _assertRecovery(p.swapId, 0, 0, 0, "manual opening timeout");
    }

    function test_executeTimeOpeningFailureClearsReportWithoutOpeningOrTerminalBlock() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.priceTolerated = 2 * PT_ACC;
        s.toleranceRange = 1;

        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, A2_OPEN, matcher);
        _assertRecovery(p.swapId, 0, 0, uint48(vm.getBlockNumber()), "doomed opening report live");

        _advanceToSettlementEligibility();
        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasBailoutLog(logs, OpenPuntStorage.SlippageBailout.selector, p.swapId), "slippage bailout");
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionOpeningFailed.selector, p.swapId), "opening failed");
        assertEq(punt.swaps(p.swapId), bytes32(0), "failed opening removed");
        _assertRecovery(p.swapId, 0, 0, 0, "execute-time opening failure");
    }

    function test_activeLatencyBailoutPreservesOpeningAndClearsOnlyReportBlock() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = LATENCY_MIN;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        (uint48 openedBlock,,) = punt.recoveryBlocks(swapId);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);
        _assertRecovery(swapId, openedBlock, 0, uint48(vm.getBlockNumber()), "latency report live");

        uint256 deadline =
            uint256(mt.game.lastReportOppoTime) + _secondsForBlocks(c.settlementTime) + c.maxExecutionLatency;
        _advanceValid(deadline + 1 - vm.getBlockTimestamp());
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasBailoutLog(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, swapId), "latency bailout");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(mt.swap)), "active position preserved");
        _assertRecovery(swapId, openedBlock, 0, 0, "active latency bailout");
    }

    function test_activeCadenceBailoutPreservesOpeningAndClearsOnlyReportBlock() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.maxExecutionLatency = 0;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        (uint48 openedBlock,,) = punt.recoveryBlocks(swapId);
        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_HEALTHY);
        _assertRecovery(swapId, openedBlock, 0, uint48(vm.getBlockNumber()), "cadence report live");

        _advanceInvalidCadence(_secondsForBlocks(c.settlementTime) + 100, c.settlementTime);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId), "cadence bailout"
        );
        assertEq(punt.swaps(swapId), keccak256(abi.encode(mt.swap)), "active position preserved");
        _assertRecovery(swapId, openedBlock, 0, 0, "active cadence bailout");
    }

    function test_heartbeatBailoutPreservesOpeningAndClearsOnlyReportBlock() public {
        LiveCfg memory c = _defaultLiveCfg();
        c.settlementTime = 2;
        c.hbMin = HB_MIN;
        c.hbMax = HB_MAX;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);
        (uint48 openedBlock,,) = punt.recoveryBlocks(swapId);
        _heartbeat(swapId, active, outsider);
        (, uint48 heartbeatTimestamp) = punt.liquidationHeartbeats(swapId);

        Matched memory mt = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, LIVE_COMP, A2_LIQUIDATES);
        _assertRecovery(swapId, openedBlock, 0, uint48(vm.getBlockNumber()), "heartbeat report live");
        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, swapId), "heartbeat bailout");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(mt.swap)), "active position preserved");
        (uint128 heartbeatReportId, uint48 preservedTimestamp) = punt.liquidationHeartbeats(swapId);
        assertEq(heartbeatReportId, 0, "heartbeat unbound for reuse");
        assertEq(preservedTimestamp, heartbeatTimestamp, "heartbeat timestamp preserved");
        _assertRecovery(swapId, openedBlock, 0, 0, "heartbeat authorization bailout");
    }

    function test_closeAuctionStartAndCancellationDoNotChangeRecoveryBlocks() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        (uint48 openedBlock,,) = punt.recoveryBlocks(swapId);

        _startDefaultAuction(swapId, active);
        assertTrue(punt.closeRequestBlock(swapId) != 0, "close request live");
        _assertRecovery(swapId, openedBlock, 0, 0, "close auction started");

        vm.prank(swapper);
        puntLifecycle.cancelCloseAuction(swapId, active);
        assertEq(punt.closeRequestBlock(swapId), 0, "close request cleared");
        _assertRecovery(swapId, openedBlock, 0, 0, "close auction cancelled");
    }

    function _assertPackedProposal(address who, uint256 index, uint256 expectedSwapId, uint48 expectedBlock)
        internal
        view
    {
        uint256 packed = punt.swapperSwapData(who, index);
        assertEq(packed >> 48, expectedSwapId, "packed swapId");
        assertEq(uint48(packed), expectedBlock, "packed proposal block");
    }

    function _assertRecovery(
        uint256 swapId,
        uint48 expectedOpened,
        uint48 expectedTerminal,
        uint48 expectedReportStart,
        string memory phase
    ) internal view {
        (uint48 opened, uint48 terminal, uint48 reportStart) = punt.recoveryBlocks(swapId);
        assertEq(opened, expectedOpened, string.concat(phase, ": opened block"));
        assertEq(terminal, expectedTerminal, string.concat(phase, ": terminal block"));
        assertEq(reportStart, expectedReportStart, string.concat(phase, ": report start block"));
    }
}
