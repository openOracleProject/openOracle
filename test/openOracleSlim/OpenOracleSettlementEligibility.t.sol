// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Coverage for the opt-in settlement-eligibility sidecar used by integrations that need
///         to classify a live report without possessing its full preimage.
contract OpenOracleSettlementEligibilityTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
    }

    function _trackedParams(bool timestampMode) internal view returns (CompatTypes.CreateReportParams memory p) {
        p = _defaultParams();
        p.flags = FLAG_STORE_SETTLEMENT_ELIGIBILITY;
        if (timestampMode) p.flags |= FLAG_TIME_TYPE;
    }

    function testTimestampModeStoresTheExactInitialEligibility() public {
        CompatTypes.CreateReportParams memory p = _trackedParams(true);
        uint256 expected = block.timestamp + p.settlementTime;

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);

        assertEq(oracle.settlementEligibility(ctx.reportId), expected, "timestamp deadline");
        assertEq(_hashOracle(ctx.game, ctx.helper), oracle.oracleGame(ctx.reportId), "state remains reconstructable");
    }

    function testBlockModeStoresTheExactInitialEligibility() public {
        CompatTypes.CreateReportParams memory p = _trackedParams(false);
        uint256 expected = block.number + p.settlementTime;

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);

        assertEq(oracle.settlementEligibility(ctx.reportId), expected, "block deadline");
        assertEq(_hashOracle(ctx.game, ctx.helper), oracle.oracleGame(ctx.reportId), "state remains reconstructable");
    }

    function testFlagOffLeavesTheSidecarZeroAcrossTheWholeLifecycle() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        assertEq(oracle.settlementEligibility(ctx.reportId), 0, "zero after report");

        vm.warp(block.timestamp + p.disputeDelay + 1);
        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, false, false);
        assertEq(oracle.settlementEligibility(ctx.reportId), 0, "zero after dispute");

        vm.warp(block.timestamp + p.settlementTime);
        vm.prank(charlie);
        _settle(ctx);
        assertEq(oracle.settlementEligibility(ctx.reportId), 0, "zero after settle");
    }

    function testTimestampDisputeReplacesTheDeadlineWithTheLatestRound() public {
        CompatTypes.CreateReportParams memory p = _trackedParams(true);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        uint256 original = oracle.settlementEligibility(ctx.reportId);

        vm.warp(block.timestamp + p.disputeDelay + 1);
        uint256 expected = block.timestamp + p.settlementTime;
        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, false, false);

        assertGt(expected, original, "fixture extends the deadline");
        assertEq(oracle.settlementEligibility(ctx.reportId), expected, "latest timestamp deadline");
        assertEq(_hashOracle(ctx.game, ctx.helper), oracle.oracleGame(ctx.reportId), "disputed state reconstructs");
    }

    function testBlockModeDisputeReplacesTheDeadlineWithTheLatestRound() public {
        CompatTypes.CreateReportParams memory p = _trackedParams(false);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        uint256 original = oracle.settlementEligibility(ctx.reportId);

        vm.roll(block.number + p.disputeDelay + 1);
        uint256 expected = block.number + p.settlementTime;
        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, false, false);

        assertGt(expected, original, "fixture extends the deadline");
        assertEq(oracle.settlementEligibility(ctx.reportId), expected, "latest block deadline");
        assertEq(_hashOracle(ctx.game, ctx.helper), oracle.oracleGame(ctx.reportId), "disputed state reconstructs");
    }

    function testStoredEligibilityIsTheExactSettlementBoundaryAndSurvivesSettlement() public {
        CompatTypes.CreateReportParams memory p = _trackedParams(true);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        uint256 deadline = oracle.settlementEligibility(ctx.reportId);

        vm.warp(deadline - 1);
        vm.prank(charlie);
        vm.expectRevert(Errors.SettleTooEarly.selector);
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);

        vm.warp(deadline);
        vm.prank(charlie);
        _settle(ctx);
        assertEq(oracle.settlementEligibility(ctx.reportId), deadline, "settlement does not rewrite the sidecar");
    }

    function testAllFlagsComposeAndTheSidecarDoesNotChangeTheCommittedPreimage() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags = 0x7F;

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);

        assertEq(ctx.game.flags, 0x7F, "all flags committed");
        assertEq(_hashOracle(ctx.game, ctx.helper), oracle.oracleGame(ctx.reportId), "all-flags preimage reconstructs");
        assertEq(
            oracle.settlementEligibility(ctx.reportId),
            uint256(ctx.game.reportTimestamp) + ctx.game.settlementTime,
            "sidecar composes with every existing flag"
        );
    }

    function test_reportFailureRollsBackTheSidecarAndReportId() public {
        CompatTypes.CreateReportParams memory p = _trackedParams(true);
        uint256 expectedId = oracle.nextReportId();

        vm.prank(alice);
        vm.expectRevert(Errors.MsgValueTooLow.selector);
        CompatTypes.reportRaw(oracle, 0, p, 1e18, 2000e18, alice, false, false, _emptyTiming());

        assertEq(oracle.nextReportId(), expectedId, "report id rolled back");
        assertEq(oracle.settlementEligibility(expectedId), 0, "sidecar write rolled back");
        assertEq(oracle.oracleGame(expectedId), bytes32(0), "state hash rolled back");
    }

    function test_disputeFailureRollsBackTheSidecarAndStateHash() public {
        CompatTypes.CreateReportParams memory p = _trackedParams(true);
        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);

        vm.warp(block.timestamp + p.disputeDelay + 1);
        uint256 deadlineBefore = oracle.settlementEligibility(ctx.reportId);
        bytes32 hashBefore = oracle.oracleGame(ctx.reportId);

        vm.startPrank(bob);
        token1.approve(address(oracle), 0);
        token2.approve(address(oracle), 0);
        (bool ok,) = address(oracle).call(
            abi.encodeCall(
                oracle.dispute, (ctx.reportId, 1.1e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming())
            )
        );
        vm.stopPrank();

        assertFalse(ok, "unfunded dispute must revert");
        assertEq(oracle.settlementEligibility(ctx.reportId), deadlineBefore, "deadline rolled back");
        assertEq(oracle.oracleGame(ctx.reportId), hashBefore, "state hash rolled back");
    }

    function testSeparateReportsKeepIndependentClockModesAndDeadlines() public {
        CompatTypes.CreateReportParams memory timeParams = _trackedParams(true);
        CompatTypes.CreateReportParams memory blockParams = _trackedParams(false);

        uint256 timeExpected = block.timestamp + timeParams.settlementTime;
        vm.prank(alice);
        ReportContext memory timeReport = _report(timeParams, 1e18, 2000e18, alice, false, false);

        vm.warp(block.timestamp + 17);
        vm.roll(block.number + 9);
        uint256 blockExpected = block.number + blockParams.settlementTime;
        vm.prank(bob);
        ReportContext memory blockReport = _report(blockParams, 1e18, 2000e18, bob, false, false);

        assertEq(oracle.settlementEligibility(timeReport.reportId), timeExpected, "timestamp report unchanged");
        assertEq(oracle.settlementEligibility(blockReport.reportId), blockExpected, "block report independent");
    }
}
