// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase} from "./DisputeHelperBase.t.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";

/**
 * @notice Every branch of the helper's delegated-dispute funding derivation, against the amounts
 *         the real oracle actually pulls.
 *
 * @dev WHY THE HELPER'S NUMBERS ARE OBSERVABLE. `_requiredFunding` is a pure re-derivation of the
 *      oracle's non-self-dispute funding path. If it over-derives, the helper pulls more than the
 *      oracle takes and the surplus is refunded — so the disputer's net debit reveals the error.
 *      If it under-derives, `_assertFullyFunded` passes on too little and the oracle's own pull
 *      reverts. Each test therefore pins the exact net token movement for the disputer, computed
 *      by hand below and never by calling the helper's own arithmetic.
 *
 *      SHARED CONSTANTS. token1 = tokenA, token2 = tokenB, oldAmount1 = 1e18, oldAmount2 = 1000e18,
 *      feePercentage = 3000/1e7 = 0.03%, protocolFee = 1000/1e7 = 0.01%.
 *
 *      The oracle requires newAmount1 == oldAmount1 * multiplier / 100, so with multiplier 110 the
 *      only legal newAmount1 is 1.1e18, and with multiplier 100 it is exactly 1e18.
 *
 *      THE DUST SENTINEL. Before crediting anything, `dispute()` calls `_getDustAmounts`, which
 *      writes 1 wei into `tokenHolder[disputer][token]` for both tokens if the slot is empty — a
 *      slot-warming device, not a payout. Every internal-balance expectation below therefore ends
 *      in `+ 1`, and the "no credit" cases expect exactly 1 rather than 0.
 *
 *      The branch selector is `newAmount2 * oldAmount1 > oldAmount2 * newAmount1`.
 *      With multiplier 110 that is `newAmount2 * 1e18 > 1000e18 * 1.1e18`, i.e. newAmount2 > 1100e18.
 *      With multiplier 100 it is `newAmount2 > 1000e18`.
 */
contract FundingBranchesTest is DisputeHelperBase {
    // ── !swapToken2 branch fees, on oldAmount1 = 1e18 ───────────────────
    // fee         = 1e18 * 3000 / 1e7 = 3e14
    // protocolFee = 1e18 * 1000 / 1e7 = 1e14
    uint256 internal constant FEE_ON_1 = 3e14;
    uint256 internal constant PROTO_ON_1 = 1e14;

    // ── swapToken2 branch fees, on oldAmount2 = 1000e18 ─────────────────
    // fee         = 1000e18 * 3000 / 1e7 = 3e17
    // protocolFee = 1000e18 * 1000 / 1e7 = 1e17
    uint256 internal constant FEE_ON_2 = 3e17;
    uint256 internal constant PROTO_ON_2 = 1e17;

    uint128 internal constant NEW_AMOUNT_1 = 1.1e18; // 1e18 * 110 / 100

    // ────────────────────────────────────────────────────────────────────
    //  !swapToken2 — token1 is the contributed side
    // ────────────────────────────────────────────────────────────────────

    /// @dev newAmount2 = 900e18 (< 1000e18), so requiredToken2 is zero and the oracle instead
    ///      CREDITS the disputer 1000e18 - 900e18 = 100e18 of token2 internally. This is the
    ///      token2-refund shape: the helper must fund only token1 and must not try to pull token2.
    ///
    ///      requiredToken1 = newAmount1 + oldAmount1 + fee + protocolFee
    ///                     = 1.1e18 + 1e18 + 3e14 + 1e14 = 2.1004e18
    function test_token1OnlyBranchCreditsTheDisputerTheToken2Difference() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 required1 = 2.1004e18;
        assertEq(required1, uint256(NEW_AMOUNT_1) + OLD_AMOUNT_1 + FEE_ON_1 + PROTO_ON_1, "derivation");

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 b0 = tokenB.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, required1, 0, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), required1, "token1 debit must equal the derivation");
        assertEq(tokenB.balanceOf(disputer), b0, "no token2 should move externally");
        assertEq(
            oracle.tokenHolder(disputer, address(tokenB)),
            100e18 + 1,
            "token2 credit = (1000e18 - 900e18) on top of the 1 wei dust sentinel"
        );
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB)));
    }

    /// @dev Supplying MORE than required must leave the disputer's net debit unchanged: the
    ///      surplus is returned by `_refundDelta`, not silently kept.
    function test_oversuppliedToken1IsRefundedInFull() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 required1 = 2.1004e18;
        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, required1 + 500e18, 0, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), required1, "surplus was not refunded");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB)));
    }

    /// @dev newAmount2 = 1050e18 sits between oldAmount2 and the branch boundary, so BOTH legs are
    ///      required at once.
    ///      requiredToken1 = 2.1004e18 (as above)
    ///      requiredToken2 = 1050e18 - 1000e18 = 50e18
    function test_bothLegsRequiredWhenToken2RisesBelowTheBranchBoundary() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 required1 = 2.1004e18;
        uint256 required2 = 50e18;

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 b0 = tokenB.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 1050e18, required1, required2, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), required1, "token1 debit");
        assertEq(b0 - tokenB.balanceOf(disputer), required2, "token2 debit");
        assertEq(
            oracle.tokenHolder(disputer, address(tokenB)), 1, "dust sentinel only -- no token2 credit on this branch"
        );
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB)));
    }

    /// @dev newAmount2 exactly equal to oldAmount2 is the seam between "contribute" and "receive":
    ///      requiredToken2 = 0 AND the internal credit is 0.
    function test_equalToken2AmountsRequireAndCreditNothing() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 b0 = tokenB.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, OLD_AMOUNT_2, 2.1004e18, 0, address(tokenA), 0, c, i, 0);

        assertEq(tokenB.balanceOf(disputer), b0, "token2 must not move");
        assertEq(oracle.tokenHolder(disputer, address(tokenB)), 1, "dust sentinel only -- no credit at the seam");
    }

    /// @dev newAmount2 = 1100e18 is the largest value still on the !swapToken2 branch:
    ///      1100e18 * 1e18 > 1000e18 * 1.1e18 is false (they are equal).
    ///      requiredToken2 = 1100e18 - 1000e18 = 100e18.
    function test_branchBoundaryStaysOnTheToken1Side() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 b0 = tokenB.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 1100e18, 2.1004e18, 100e18, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), 2.1004e18, "token1 debit is the full !swap form");
        assertEq(b0 - tokenB.balanceOf(disputer), 100e18, "token2 debit");
    }

    // ────────────────────────────────────────────────────────────────────
    //  swapToken2 — token2 is the contributed side
    // ────────────────────────────────────────────────────────────────────

    /// @dev One wei past the boundary flips the branch, and the fee base changes from oldAmount1 to
    ///      oldAmount2 — a ~1000x change in the fee. Pinning both sides of the boundary is what
    ///      makes a wrong comparison operator visible.
    ///      requiredToken1 = newAmount1 - oldAmount1 = 1e17
    ///      requiredToken2 = newAmount2 + oldAmount2 + fee + protocolFee
    ///                     = 1100e18 + 1 + 1000e18 + 3e17 + 1e17 = 2100.4e18 + 1
    function test_oneWeiPastTheBoundaryFlipsToTheToken2Branch() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 required1 = 1e17;
        uint256 required2 = 2100.4e18 + 1;

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 b0 = tokenB.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 1100e18 + 1, required1, required2, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), required1, "token1 debit is only the increment");
        assertEq(b0 - tokenB.balanceOf(disputer), required2, "token2 debit carries the fees");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB)));
    }

    /// @dev Deep on the swapToken2 branch.
    ///      requiredToken2 = 1200e18 + 1000e18 + 3e17 + 1e17 = 2200.4e18
    function test_token2BranchChargesFeesOnOldAmount2() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 required2 = 2200.4e18;
        assertEq(required2, 1200e18 + OLD_AMOUNT_2 + FEE_ON_2 + PROTO_ON_2, "derivation");

        uint256 b0 = tokenB.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 1200e18, 1e17, required2, address(tokenA), 0, c, i, 0);

        assertEq(b0 - tokenB.balanceOf(disputer), required2, "token2 debit");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB)));
    }

    /// @dev With multiplier 100 the legal newAmount1 equals oldAmount1, so on the swapToken2 branch
    ///      requiredToken1 is exactly zero — the only shape where token1 is untouched entirely.
    function test_flatMultiplierMakesToken1RequirementZero() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB), MULTIPLIER_FLAT, OLD_AMOUNT_1, OLD_AMOUNT_2);

        uint256 required2 = 2200.4e18; // 1200e18 + 1000e18 + 3e17 + 1e17
        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, OLD_AMOUNT_1, 1200e18, 0, required2, address(tokenA), 0, c, i, 0);

        assertEq(tokenA.balanceOf(disputer), a0, "token1 must not move at all");
        assertEq(tokenA.allowance(address(helper), address(oracle)), 0, "no approval for a zero requirement");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB)));
    }

    // ────────────────────────────────────────────────────────────────────
    //  FLAG_FEES_ONLY_AT_HALT
    // ────────────────────────────────────────────────────────────────────

    function test_haltOnlyFeesAreSkippedBelowHaltOnTheToken1Branch() public {
        Game memory ctx = _newGameConfigured(
            address(tokenA),
            address(tokenB),
            MULTIPLIER,
            OLD_AMOUNT_1,
            OLD_AMOUNT_2,
            FLAG_TIME_TYPE | FLAG_FEES_ONLY_AT_HALT,
            2e18
        );

        uint256 required1 = uint256(NEW_AMOUNT_1) + OLD_AMOUNT_1;
        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, required1, 0, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), required1, "fees charged below halt");
    }

    function test_haltOnlyFeesAreSkippedBelowHaltOnTheToken2Branch() public {
        Game memory ctx = _newGameConfigured(
            address(tokenA),
            address(tokenB),
            MULTIPLIER,
            OLD_AMOUNT_1,
            OLD_AMOUNT_2,
            FLAG_TIME_TYPE | FLAG_FEES_ONLY_AT_HALT,
            2e18
        );

        uint256 required1 = uint256(NEW_AMOUNT_1) - OLD_AMOUNT_1;
        uint256 required2 = 1200e18 + OLD_AMOUNT_2;
        uint256 b0 = tokenB.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 1200e18, required1, required2, address(tokenA), 0, c, i, 0);

        assertEq(b0 - tokenB.balanceOf(disputer), required2, "fees charged below halt");
    }

    function test_haltOnlyFeesAreChargedOnceCurrentLiquidityReachesHalt() public {
        Game memory ctx = _newGameConfigured(
            address(tokenA),
            address(tokenB),
            MULTIPLIER,
            OLD_AMOUNT_1,
            OLD_AMOUNT_2,
            FLAG_TIME_TYPE | FLAG_FEES_ONLY_AT_HALT,
            OLD_AMOUNT_1
        );

        uint128 newAmount1 = OLD_AMOUNT_1 + 1;
        uint256 required1 = uint256(newAmount1) + OLD_AMOUNT_1 + FEE_ON_1 + PROTO_ON_1;
        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, newAmount1, 900e18, required1, 0, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), required1, "fees omitted at halt");
    }

    // ────────────────────────────────────────────────────────────────────
    //  under-funding must revert rather than partially settle
    // ────────────────────────────────────────────────────────────────────

    /// @dev One wei short with no route offered. `shortfall1 > 0` sends the call into
    ///      `_executeRoute`, which rejects a zero maximum before any router interaction.
    function test_shortByOneWeiWithNoRouteIsRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _noRoute();
        vm.expectRevert(OracleDisputeHelper.InvalidMaximumSwapInput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 2.1004e18 - 1, 0, address(tokenA), 0, c, i, 0);
    }

    /// @dev Short on the second leg only — proves the shortfall test covers token2 independently.
    function test_shortOnToken2OnlyIsAlsoRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _noRoute();
        vm.expectRevert(OracleDisputeHelper.InvalidMaximumSwapInput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 1050e18, 2.1004e18, 50e18 - 1, address(tokenA), 0, c, i, 0);
    }

    /// @dev The real oracle cannot create a same-token game. Mutating a valid preimage into that
    ///      impossible shape is therefore rejected by authentication before funding validation.
    function test_mutatingThePreimageToIdenticalTokensIsRejectedByTheHash() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        ctx.game.token2 = address(tokenA);

        (bytes memory c, bytes[] memory i) = _noRoute();
        vm.expectRevert(OracleDisputeHelper.WrongHash.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 2.1004e18, 0, address(tokenA), 0, c, i, 0);
    }

    // ────────────────────────────────────────────────────────────────────
    //  msg.value accounting for ERC20-only games
    // ────────────────────────────────────────────────────────────────────

    /// @dev Neither oracle token is ETH and ETH is not the route input, so any msg.value at all is
    ///      unaccounted for and must be rejected — it would otherwise be stranded in the helper.
    function test_unexpectedEthOnAnErc20GameIsRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _noRoute();
        vm.expectRevert(OracleDisputeHelper.InvalidMsgValue.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 2.1004e18, 0, address(tokenA), 0, c, i, 1 wei);
    }

    // ────────────────────────────────────────────────────────────────────
    //  the derivation must survive a second dispute on the same game
    // ────────────────────────────────────────────────────────────────────

    /// @dev After the first dispute the game's amounts have moved, so the second dispute's legal
    ///      newAmount1 and required funding are different. This pins that the helper reads the
    ///      CURRENT game rather than anything cached.
    ///      Round 2: oldAmount1 = 1.1e18, oldAmount2 = 900e18, newAmount1 = 1.1e18*110/100 = 1.21e18
    ///      fee         = 1.1e18 * 3000 / 1e7 = 3.3e14
    ///      protocolFee = 1.1e18 * 1000 / 1e7 = 1.1e14
    ///      requiredToken1 = 1.21e18 + 1.1e18 + 3.3e14 + 1.1e14 = 2.31044e18
    function test_secondDisputeUsesTheUpdatedGameAmounts() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 2.1004e18, 0, address(tokenA), 0, c, i, 0);

        // Advance the local preimage exactly as the oracle did.
        ctx.game.currentAmount1 = NEW_AMOUNT_1;
        ctx.game.currentAmount2 = 900e18;
        ctx.game.currentReporter = disputer;
        ctx.game.reportTimestamp = uint48(block.timestamp);
        ctx.game.lastReportOppoTime = uint48(block.number);
        assertEq(
            oracle.oracleGame(ctx.reportId),
            keccak256(abi.encode(ctx.game, ctx.helper)),
            "local preimage diverged from the oracle after round 1"
        );

        uint256 required1Round2 = 2.31044e18;
        uint256 a0 = tokenA.balanceOf(disputer);

        _callDispute(ctx, 1.21e18, 800e18, required1Round2, 0, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), required1Round2, "round 2 debit");
    }
}
