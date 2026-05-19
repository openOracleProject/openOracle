// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

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
        CompatTypes.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidAmount1.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 0, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsAmount2Zero() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidAmount2.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 0, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsSameToken() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.token2Address = p.token1Address;
        vm.prank(alice);
        vm.expectRevert(Errors.TokensCannotBeSame.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsFeeSumTooHigh() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        // feePercentage + protocolFee > 1e7 (PERCENTAGE_PRECISION).
        p.feePercentage = uint24(5_000_000);
        p.protocolFee = uint24(5_000_001);
        vm.prank(alice);
        vm.expectRevert(Errors.FeesTooHigh.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsMultiplierTooLow() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.multiplier = uint16(99); // < MULTIPLIER_PRECISION (100)
        vm.prank(alice);
        vm.expectRevert(Errors.MultiplierTooLow.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsSettlementTimeBelowDisputeDelay() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.settlementTime = 5;
        p.disputeDelay = 10; // > settlementTime
        vm.prank(alice);
        vm.expectRevert(Errors.SettleVsDisputeDelayTiming.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    // The check changed from `<` to `<=`: equal values yield an empty dispute window
    // (DisputeTooEarly + DisputeTooLate overlap), so report must reject it at creation.
    function testReport_RevertsSettlementTimeEqualsDisputeDelay() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.settlementTime = 10;
        p.disputeDelay = 10; // equal — dispute window is empty
        vm.prank(alice);
        vm.expectRevert(Errors.SettleVsDisputeDelayTiming.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    // ─── New dirty-field / mode guards (post hash refactor) ──────────────────────
    // Caller is required to pass zero for fields the contract overrides (reportTimestamp,
    // lastReportOppoTime) or for fields that must start at zero (settlementTimestamp,
    // numReports). These dirty-field reverts protect against caller mistakes that would
    // otherwise hash a poisoned preimage. Also covers the new `flags > FLAGS_MAX` check.

    /// @dev Build the input OracleGame from defaults, with one slot poisoned to a non-zero
    ///      value so we can target each guard individually.
    function _buildDirtyOracleGame(CompatTypes.CreateReportParams memory p, uint128 amount1, uint128 amount2)
        internal
        view
        returns (Slim.OracleGame memory g)
    {
        g.token1 = p.token1Address;
        g.token2 = p.token2Address;
        g.feePercentage = p.feePercentage;
        g.multiplier = p.multiplier;
        g.settlementTime = p.settlementTime;
        g.escalationHalt = p.escalationHalt;
        g.disputeDelay = p.disputeDelay;
        g.protocolFee = p.protocolFee;
        g.settlerReward = p.settlerReward;
        g.callbackContract = p.callbackContract;
        g.callbackGasLimit = p.callbackGasLimit;
        g.protocolFeeRecipient = p.protocolFeeRecipient;
        g.flags = p.flags;
        g.currentAmount1 = amount1;
        g.currentAmount2 = amount2;
        g.currentReporter = alice;
        // All dirty-required slots default to zero.
    }

    function testReport_RevertsDirtyReportTimestamp() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        Slim.OracleGame memory g = _buildDirtyOracleGame(p, 1e18, 2000e18);
        g.reportTimestamp = uint48(1234);
        vm.prank(alice);
        vm.expectRevert(Errors.TimestampsMustBeZero.selector);
        oracle.report{value: p.settlerReward}(g, false, false, _emptyTiming());
    }

    function testReport_RevertsDirtyLastReportOppoTime() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        Slim.OracleGame memory g = _buildDirtyOracleGame(p, 1e18, 2000e18);
        g.lastReportOppoTime = uint48(5678);
        vm.prank(alice);
        vm.expectRevert(Errors.TimestampsMustBeZero.selector);
        oracle.report{value: p.settlerReward}(g, false, false, _emptyTiming());
    }

    function testReport_RevertsDirtySettlementTimestamp() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        Slim.OracleGame memory g = _buildDirtyOracleGame(p, 1e18, 2000e18);
        g.settlementTimestamp = uint48(9999);
        vm.prank(alice);
        vm.expectRevert(Errors.TimestampsMustBeZero.selector);
        oracle.report{value: p.settlerReward}(g, false, false, _emptyTiming());
    }

    function testReport_RevertsDirtyNumReports() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        Slim.OracleGame memory g = _buildDirtyOracleGame(p, 1e18, 2000e18);
        g.numReports = 1;
        vm.prank(alice);
        vm.expectRevert(Errors.NumReportsMustBeZero.selector);
        oracle.report{value: p.settlerReward}(g, false, false, _emptyTiming());
    }

    function testReport_RevertsFlagsAboveMax() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags = 0x10; // bit 4 — no flag uses it, must revert
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidMode.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_AcceptsFlagsAtMax() public {
        // All four defined flag bits combined (0x0F) should be accepted.
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags = 0x0F;
        vm.prank(alice);
        // Should not revert with InvalidMode (will pass through to the rest of report).
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsZeroReporter() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        vm.expectRevert(Errors.AddressCannotBeZero.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, address(0), false, false, _emptyTiming());
    }

    function testReport_RevertsMsgValueTooLow() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        // settlerReward = 0.001 ether but we send 0.
        vm.prank(alice);
        vm.expectRevert(Errors.MsgValueTooLow.selector);
        CompatTypes.reportRaw(oracle, 0, p, 1e18, 2000e18, alice, false, false, _emptyTiming());
    }

    function testReport_RevertsNeitherTokenIsETH_WithExtraMsgValue() public {
        // ERC20 pair, but sending more than settlerReward.
        CompatTypes.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        vm.expectRevert(Errors.NeitherTokenIsETH.selector);
        CompatTypes.reportRaw(oracle, uint256(p.settlerReward) + 1, 
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
        vm.expectRevert(Errors.InvalidTokenToSwap.selector);
        oracle.dispute(
            ctx.reportId, randomToken, 1.1e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testDispute_RevertsZeroAmount2() public {
        ReportContext memory ctx = _aliceReports();
        vm.warp(block.timestamp + 6);

        // newAmount1 will pass escalation check (1e18 * 110/100 = 1.1e18).
        vm.prank(bob);
        vm.expectRevert(Errors.AmountsCannotBeZero.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 0, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testDispute_RevertsTooLate() public {
        ReportContext memory ctx = _aliceReports();
        // settlementTime is 300; warp past it.
        vm.warp(block.timestamp + 301);

        vm.prank(bob);
        vm.expectRevert(Errors.DisputeTooLate.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testDispute_RevertsTooEarly() public {
        ReportContext memory ctx = _aliceReports();
        // disputeDelay is 5; we haven't warped at all.

        vm.prank(bob);
        vm.expectRevert(Errors.DisputeTooEarly.selector);
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
        vm.expectRevert(Errors.AlreadySettled.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testDispute_RevertsZeroDisputer() public {
        ReportContext memory ctx = _aliceReports();
        vm.warp(block.timestamp + 6);

        vm.prank(bob);
        vm.expectRevert(Errors.AddressCannotBeZero.selector);
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
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.escalationHalt = 1e18; // == amount1 -> already at halt
        p.multiplier = 110;

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 6);

        // At halt, expectedAmount1 = oldAmount1 + 1. Submitting a different value reverts.
        vm.prank(bob);
        vm.expectRevert(Errors.EscalationHalted.selector);
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
        vm.expectRevert(Errors.InvalidAmount1.selector);
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
        vm.expectRevert(Errors.SettleTooEarly.selector);
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
        vm.expectRevert(Errors.AlreadySettled.selector);
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);
    }
}
