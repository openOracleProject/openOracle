// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Focused coverage for flexible escalation and fee activation at the halt.
contract OpenOracleEscalationModesTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
    }

    function _reportWith(CompatTypes.CreateReportParams memory p) internal returns (ReportContext memory ctx) {
        vm.prank(alice);
        ctx = _report(p, 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + p.disputeDelay + 1);
    }

    function testExactModeStillRejectsAmountAboveRequiredEscalation() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        ReportContext memory ctx = _reportWith(p);

        vm.prank(bob);
        vm.expectRevert(Errors.InvalidAmount1.selector);
        oracle.dispute(ctx.reportId, 1.5e18, 3000e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming());
    }

    function testFlexibleEscalationAcceptsAmountBetweenMinimumAndHalt() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_FLEXIBLE_ESCALATION;
        ReportContext memory ctx = _reportWith(p);

        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 1.5e18, 3000e18, false, false);

        assertEq(ctx.game.currentAmount1, 1.5e18, "flexible amount committed");
        assertEq(_hashOracle(ctx.game, ctx.helper), oracle.oracleGame(ctx.reportId), "flexible state hash");
    }

    function testFlexibleEscalationRejectsAmountBelowMinimum() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_FLEXIBLE_ESCALATION;
        ReportContext memory ctx = _reportWith(p);

        vm.prank(bob);
        vm.expectRevert(Errors.InvalidAmount1.selector);
        oracle.dispute(ctx.reportId, 1.05e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming());
    }

    function testFlexibleEscalationRejectsAmountAboveHalt() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_FLEXIBLE_ESCALATION;
        ReportContext memory ctx = _reportWith(p);

        vm.prank(bob);
        vm.expectRevert(Errors.InvalidAmount1.selector);
        oracle.dispute(
            ctx.reportId, p.escalationHalt + 1, 20_000e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
    }

    function testFlexibleEscalationWithOneXMultiplierAcceptsAnyAmountThroughHalt() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_FLEXIBLE_ESCALATION;
        p.multiplier = 100;
        ReportContext memory ctx = _reportWith(p);

        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 7e18, 14_000e18, false, false);

        assertEq(ctx.game.currentAmount1, 7e18, "one-x flexible escalation");
    }

    function testFlexibleEscalationPreservesPostHaltPlusOneRule() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_FLEXIBLE_ESCALATION;
        p.escalationHalt = 2e18;
        ReportContext memory ctx = _reportWith(p);

        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 2e18, 4000e18, false, false);

        vm.warp(block.timestamp + p.disputeDelay + 1);
        vm.prank(charlie);
        vm.expectRevert(Errors.EscalationHalted.selector);
        oracle.dispute(ctx.reportId, 2e18 + 2, 4000e18, charlie, false, false, ctx.game, ctx.helper, _emptyTiming());

        vm.prank(charlie);
        ctx = _dispute(ctx, address(token1), 2e18 + 1, 4000e18, false, false);
        assertEq(ctx.game.currentAmount1, 2e18 + 1, "post-halt plus-one amount");
    }

    function testFeesOnlyAtHaltSuppressesToken1SideFeesBelowHalt() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_FEES_ONLY_AT_HALT;
        ReportContext memory ctx = _reportWith(p);

        uint256 aliceBefore = _heldTokens(alice, address(token1));
        uint256 recipientBefore = _heldTokens(protocolFeeRecipient, address(token1));

        vm.prank(bob);
        _dispute(ctx, address(token1), 1.1e18, 2100e18, false, false);

        assertEq(_heldTokens(alice, address(token1)), aliceBefore + 2e18, "no reporter fee below halt");
        assertEq(_heldTokens(protocolFeeRecipient, address(token1)), recipientBefore, "no protocol fee below halt");
    }

    function testFeesOnlyAtHaltSuppressesToken2SideFeesBelowHalt() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_FEES_ONLY_AT_HALT;
        ReportContext memory ctx = _reportWith(p);

        uint256 aliceBefore = _heldTokens(alice, address(token2));
        uint256 recipientBefore = _heldTokens(protocolFeeRecipient, address(token2));

        vm.prank(bob);
        _dispute(ctx, address(token2), 1.1e18, 2300e18, false, false);

        assertEq(_heldTokens(alice, address(token2)), aliceBefore + 4000e18, "no reporter fee below halt");
        assertEq(_heldTokens(protocolFeeRecipient, address(token2)), recipientBefore, "no protocol fee below halt");
    }

    function testCombinedModesFlexibleJumpToHaltIsFreeThenFeesActivate() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_FEES_ONLY_AT_HALT | FLAG_FLEXIBLE_ESCALATION;
        p.escalationHalt = 2e18;
        ReportContext memory ctx = _reportWith(p);

        uint256 recipientBeforeFirst = _heldTokens(protocolFeeRecipient, address(token1));
        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 2e18, 4000e18, false, false);
        assertEq(_heldTokens(protocolFeeRecipient, address(token1)), recipientBeforeFirst, "reaching halt remains free");

        vm.warp(block.timestamp + p.disputeDelay + 1);
        uint256 bobBefore = _heldTokens(bob, address(token1));
        uint256 recipientBeforeSecond = _heldTokens(protocolFeeRecipient, address(token1));
        uint256 oldAmount1 = ctx.game.currentAmount1;
        uint256 fee = oldAmount1 * p.feePercentage / 1e7;
        uint256 protocolFee = oldAmount1 * p.protocolFee / 1e7;

        vm.prank(charlie);
        _dispute(ctx, address(token1), 2e18 + 1, 4000e18, false, false);

        assertEq(
            _heldTokens(bob, address(token1)), bobBefore + 2 * oldAmount1 + fee, "reporter fee starts against halt"
        );
        assertEq(
            _heldTokens(protocolFeeRecipient, address(token1)),
            recipientBeforeSecond + protocolFee,
            "protocol fee starts against halt"
        );
    }

    function testFeesOnlyAtHaltSuppressesSelfDisputeProtocolFeeBelowHalt() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_FEES_ONLY_AT_HALT;

        vm.prank(bob);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, bob, false, false);
        vm.warp(block.timestamp + p.disputeDelay + 1);

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 recipientBefore = _heldTokens(protocolFeeRecipient, address(token1));

        vm.prank(bob);
        _dispute(ctx, address(token1), 1.1e18, 1900e18, false, false);

        assertEq(token1.balanceOf(bob), bobToken1Before - 0.1e18, "self-dispute pays only amount delta");
        assertEq(
            _heldTokens(protocolFeeRecipient, address(token1)), recipientBefore, "self-dispute protocol fee suppressed"
        );
    }
}
