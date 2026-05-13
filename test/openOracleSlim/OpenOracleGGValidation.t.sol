// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {OpenOracleErrors} from "../../src/OpenOracleErrors.sol";

// Compact negative-validation matrix for report / dispute / settle.
// Each test sets up the smallest possible state and asserts the expected
// revert. Coverage is for protocol-rule input validation, not preimage hash
// mismatch (covered in EdgeCases).
contract OpenOracleGGValidationTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
    }

    // -------------------------------------------------------------------------
    // report() input validation
    // -------------------------------------------------------------------------

    function testReport_RevertsAmount1Zero() public {
        Slim.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.InvalidAmount1.selector);
        oracle.report{value: p.settlerReward}(p, 0, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsAmount2Zero() public {
        Slim.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.InvalidAmount2.selector);
        oracle.report{value: p.settlerReward}(p, 1e18, 0, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsSameToken() public {
        Slim.CreateReportParams memory p = _defaultParams();
        p.token2Address = p.token1Address;
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.TokensCannotBeSame.selector);
        oracle.report{value: p.settlerReward}(p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsFeeSumTooHigh() public {
        Slim.CreateReportParams memory p = _defaultParams();
        // feePercentage + protocolFee > 1e7 (PERCENTAGE_PRECISION).
        p.feePercentage = uint24(5_000_000);
        p.protocolFee = uint24(5_000_001);
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.FeesTooHigh.selector);
        oracle.report{value: p.settlerReward}(p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsMultiplierTooLow() public {
        Slim.CreateReportParams memory p = _defaultParams();
        p.multiplier = uint16(99); // < MULTIPLIER_PRECISION (100)
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.MultiplierTooLow.selector);
        oracle.report{value: p.settlerReward}(p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsSettlementTimeBelowDisputeDelay() public {
        Slim.CreateReportParams memory p = _defaultParams();
        p.settlementTime = 5;
        p.disputeDelay = 10; // > settlementTime
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.SettleVsDisputeDelayTiming.selector);
        oracle.report{value: p.settlerReward}(p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsZeroReporter() public {
        Slim.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.AddressCannotBeZero.selector);
        oracle.report{value: p.settlerReward}(p, 1e18, 2000e18, address(0), false, false, _emptyTiming());
    }

    function testReport_RevertsMsgValueTooLow() public {
        Slim.CreateReportParams memory p = _defaultParams();
        // settlerReward = 0.001 ether but we send 0.
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.MsgValueTooLow.selector);
        oracle.report{value: 0}(p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsNeitherTokenIsETH_WithExtraMsgValue() public {
        // ERC20 pair, but sending more than settlerReward.
        Slim.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.NeitherTokenIsETH.selector);
        oracle.report{value: uint256(p.settlerReward) + 1}(
            p, 1e18, 2000e18, alice, false, false, _emptyTiming()
        );
    }

    // -------------------------------------------------------------------------
    // dispute() input validation
    // -------------------------------------------------------------------------

    // Helper: alice reports 1e18 / 2000e18 with default params.
    function _aliceReports() internal returns (ReportContext memory ctx) {
        vm.prank(alice);
        ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);
    }

    function testDispute_RevertsInvalidTokenToSwap() public {
        ReportContext memory ctx = _aliceReports();
        vm.warp(block.timestamp + 6);

        address randomToken = address(0xDEADBEEF);
        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.InvalidTokenToSwap.selector);
        oracle.dispute(
            ctx.reportId, randomToken, 1.1e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testDispute_RevertsZeroAmount2() public {
        ReportContext memory ctx = _aliceReports();
        vm.warp(block.timestamp + 6);

        // newAmount1 will pass escalation check (1e18 * 110/100 = 1.1e18).
        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.AmountsCannotBeZero.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 0, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testDispute_RevertsTooLate() public {
        ReportContext memory ctx = _aliceReports();
        // settlementTime is 300; warp past it.
        vm.warp(block.timestamp + 301);

        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.DisputeTooLate.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testDispute_RevertsTooEarly() public {
        ReportContext memory ctx = _aliceReports();
        // disputeDelay is 5; we haven't warped at all.

        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.DisputeTooEarly.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testDispute_RevertsAlreadySettled() public {
        ReportContext memory ctx = _aliceReports();
        vm.warp(block.timestamp + 301);

        vm.prank(charlie);
        ctx = _settle(ctx);

        // Try to dispute the now-settled report. Stored hash advanced too,
        // so InvalidStateHash kicks in first if we use ctx.game (post-settle).
        // To exercise AlreadySettled, we'd need a preimage that hashes to the
        // settled state — which is exactly ctx.game now.
        // Roll back time and try again.
        vm.warp(block.timestamp - 250);
        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.AlreadySettled.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testDispute_RevertsZeroDisputer() public {
        ReportContext memory ctx = _aliceReports();
        vm.warp(block.timestamp + 6);

        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.AddressCannotBeZero.selector);
        oracle.dispute(
            ctx.reportId,
            address(token1),
            1.1e18,
            2100e18,
            address(0),
            false,
            false,
            ctx.game,
            ctx.helper,
            _emptyTiming()
        );
    }


    function testDispute_RevertsEscalationHalted() public {
        // Set escalationHalt low so we can reach it quickly.
        Slim.CreateReportParams memory p = _defaultParams();
        p.escalationHalt = 1e18; // == amount1 -> already at halt
        p.multiplier = 110;

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 6);

        // At halt, expectedAmount1 = oldAmount1 + 1. Submitting a different value reverts.
        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.EscalationHalted.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.5e18, 2900e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testDispute_RevertsInvalidAmount1_BelowEscalation() public {
        ReportContext memory ctx = _aliceReports();
        vm.warp(block.timestamp + 6);

        // newAmount1 should equal oldAmount1 * multiplier / MULTIPLIER_PRECISION = 1e18 * 110 / 100 = 1.1e18.
        // Submit something else.
        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.InvalidAmount1.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.05e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    // -------------------------------------------------------------------------
    // settle() input validation
    // -------------------------------------------------------------------------

    function testSettle_RevertsTooEarly() public {
        ReportContext memory ctx = _aliceReports();
        // settlementTime is 300; we haven't warped enough.

        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.SettleTooEarly.selector);
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);
    }

    function testSettle_RevertsAlreadySettled() public {
        ReportContext memory ctx = _aliceReports();
        vm.warp(block.timestamp + 301);

        vm.prank(charlie);
        ctx = _settle(ctx);

        // Try to settle again — the post-settle game/helper still hashes to the
        // current stored hash, but settlementTimestamp != 0 triggers AlreadySettled.
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.AlreadySettled.selector);
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);
    }
}
