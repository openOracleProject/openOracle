// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase} from "./DisputeHelperBase.t.sol";
import {UsdtStyleERC20} from "./util/UsdtStyleERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice `_ensureOracleApproval`: the first approval, the skipped repeat, and the re-approval of a
 *         token that refuses non-zero -> non-zero changes.
 *
 * @dev THE THREE STATES. The helper approves the oracle only when the CURRENT allowance is below
 *      what this call needs, and then grants `type(uint256).max`. So:
 *        - first ever call for a token: allowance 0 -> approve;
 *        - later calls on a normal token: allowance is still infinite -> no approval at all;
 *        - later calls on a token that decrements: allowance eventually drops below the
 *          requirement -> approve again, from a NON-ZERO starting allowance.
 *
 *      That last state is the dangerous one. USDT-style tokens revert on a non-zero -> non-zero
 *      approve, so a plain `approve` would brick the helper for that token permanently. SafeERC20's
 *      `forceApprove` resets to zero first, and `UsdtStyleERC20` exists to prove the fallback is
 *      genuinely reached rather than assumed.
 *
 *      Approval activity is observed through emitted `Approval` events rather than through the
 *      final allowance, because "approved to the same value again" and "not approved at all" are
 *      indistinguishable from the allowance alone.
 */
contract OracleApprovalsTest is DisputeHelperBase {
    uint128 internal constant NEW_AMOUNT_1 = 1.1e18;
    uint256 internal constant REQUIRED_1 = 2.1004e18;
    // Round 2 on the same game: oldAmount1 = 1.1e18, newAmount1 = 1.21e18,
    // fee = 3.3e14, protocolFee = 1.1e14  ->  1.21e18 + 1.1e18 + 3.3e14 + 1.1e14
    uint256 internal constant REQUIRED_1_ROUND_2 = 2.31044e18;

    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ────────────────────────────────────────────────────────────────────
    //  ordinary ERC20
    // ────────────────────────────────────────────────────────────────────

    function test_theFirstDisputeGrantsAnInfiniteApproval() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        assertEq(tokenA.allowance(address(helper), address(oracle)), 0, "precondition: no allowance");

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(tokenA), 0, c, i, 0);

        assertEq(
            tokenA.allowance(address(helper), address(oracle)),
            type(uint256).max,
            "the oracle should hold an infinite allowance"
        );
    }

    /// @dev token2 is not required on this branch, so it must NOT be approved. An unconditional
    ///      approval would grant the oracle an allowance the call never needed.
    function test_aTokenWithNoRequirementIsNotApproved() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(tokenA), 0, c, i, 0);

        assertEq(tokenB.allowance(address(helper), address(oracle)), 0, "token2 should not be approved");
    }

    /// @dev Both legs required means both get approved.
    function test_bothRequiredTokensAreApproved() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 1050e18, REQUIRED_1, 50e18, address(tokenA), 0, c, i, 0);

        assertEq(tokenA.allowance(address(helper), address(oracle)), type(uint256).max, "token1 allowance");
        assertEq(tokenB.allowance(address(helper), address(oracle)), type(uint256).max, "token2 allowance");
    }

    /// @dev A second dispute must emit NO Approval event for token1: the infinite allowance from the
    ///      first call still covers it, so the approval is skipped entirely.
    function test_aRepeatDisputeDoesNotReapproveANormalToken() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(tokenA), 0, c, i, 0);

        _advance(ctx, NEW_AMOUNT_1, 900e18);

        vm.recordLogs();
        _callDispute(ctx, 1.21e18, 800e18, REQUIRED_1_ROUND_2, 0, address(tokenA), 0, c, i, 0);

        assertEq(_countApprovals(address(tokenA)), 0, "token1 should not have been re-approved");
    }

    /// @dev ETH can never be approved — `_ensureOracleApproval` skips the sentinel entirely rather
    ///      than calling `allowance` on address(0), which would revert.
    function test_anEthLegIsNeverApproved() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 0.5 ether, address(tokenA), 0, c, i, 0.5 ether);

        assertEq(tokenA.allowance(address(helper), address(oracle)), type(uint256).max, "token1 allowance");
    }

    // ────────────────────────────────────────────────────────────────────
    //  USDT-style: no return data, and no non-zero -> non-zero approve
    // ────────────────────────────────────────────────────────────────────

    /// @dev A token whose `transfer`/`transferFrom` return nothing works end to end. SafeERC20 on
    ///      the helper side and the oracle's own transfer handling both have to tolerate it.
    function test_aNoReturnTokenCanFundALegAndBeRefunded() public {
        Game memory ctx = _newGame(address(usdtLike), address(tokenB));

        uint256 u0 = usdtLike.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1 + 25e18, 0, address(usdtLike), 0, c, i, 0);

        assertEq(u0 - usdtLike.balanceOf(disputer), REQUIRED_1, "the oversupply must be refunded");
        assertEq(usdtLike.balanceOf(address(helper)), 0, "helper retained a no-return token balance");
    }

    /// @dev The full USDT shape. Round 1 approves from zero. The token caps the stored allowance at
    ///      3e18 and always decrements, so after the round-1 pull of 2.1004e18 only 0.8996e18
    ///      remains — less than round 2 needs. Round 2 therefore has to approve again, starting from
    ///      a NON-ZERO allowance, which this token refuses on a direct `approve`. Only
    ///      `forceApprove`'s zero-first fallback can get through.
    function test_aUsdtStyleTokenIsReapprovedThroughTheZeroFirstFallback() public {
        UsdtStyleERC20 usdt = new UsdtStyleERC20("Real USDT shape", "USDT", 3e18);
        usdt.mint(disputer, 1_000e18);
        usdt.mint(reporter, 1_000e18);

        vm.prank(disputer);
        usdt.approve(address(helper), type(uint256).max);
        vm.prank(reporter);
        usdt.approve(address(oracle), type(uint256).max);

        Game memory ctx = _newGame(address(usdt), address(tokenB));
        (bytes memory c, bytes[] memory i) = _noRoute();

        // Round 1: allowance 0 -> capped 3e18.
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(usdt), 0, c, i, 0);
        assertEq(
            usdt.allowance(address(helper), address(oracle)),
            3e18 - REQUIRED_1,
            "the cap should have been granted then partly spent"
        );

        _advance(ctx, NEW_AMOUNT_1, 900e18);

        // The cap throttles the DISPUTER's own allowance to the helper too, so the caller has to
        // top it up between rounds — the ordinary USDT experience, and separate from the
        // helper -> oracle allowance actually under test here.
        vm.startPrank(disputer);
        usdt.approve(address(helper), 0);
        usdt.approve(address(helper), type(uint256).max);
        vm.stopPrank();

        // Round 2 needs 2.31044e18 but only 0.8996e18 is left, so a re-approval is unavoidable.
        assertLt(usdt.allowance(address(helper), address(oracle)), REQUIRED_1_ROUND_2, "precondition");

        vm.recordLogs();
        _callDispute(ctx, 1.21e18, 800e18, REQUIRED_1_ROUND_2, 0, address(usdt), 0, c, i, 0);

        // Two Approval events: the reset to zero, then the new cap.
        assertEq(_countApprovals(address(usdt)), 2, "the zero-first fallback should emit two approvals");
        assertEq(
            usdt.allowance(address(helper), address(oracle)),
            3e18 - REQUIRED_1_ROUND_2,
            "re-approved to the cap, then spent"
        );
    }

    /// @dev Control for the test above: a direct `approve` over a non-zero allowance really does
    ///      revert on this token. Without this the "fallback was needed" claim is unfounded.
    function test_theUsdtStyleTokenRejectsANonZeroToNonZeroApprove() public {
        UsdtStyleERC20 usdt = new UsdtStyleERC20("Real USDT shape", "USDT", 3e18);

        usdt.approve(address(oracle), 1e18);
        vm.expectRevert(bytes("UsdtStyleERC20: unsafe approve"));
        usdt.approve(address(oracle), 2e18);

        // ...and the zero-first sequence succeeds, which is exactly what forceApprove does.
        usdt.approve(address(oracle), 0);
        usdt.approve(address(oracle), 2e18);
        assertEq(usdt.allowance(address(this), address(oracle)), 2e18, "zero-first should work");
    }

    /// @dev A USDT-style token routed through a real pool: the helper's `safeTransfer` to the
    ///      router must also tolerate the missing return value.
    function test_aNoReturnTokenWorksAsARouteInput() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5e18;
        (bytes memory sc, bytes[] memory si) = _v2ExactOut(address(usdtLike), address(tokenA), REQUIRED_1, maxIn);
        bytes[] memory sweepInput = new bytes[](1);
        sweepInput[0] = _sweep(address(usdtLike), address(helper), 0);
        (bytes memory c, bytes[] memory i) = _join(sc, si, abi.encodePacked(CMD_SWEEP), sweepInput);

        uint256 u0 = usdtLike.balanceOf(disputer);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(usdtLike), maxIn, c, i, 0);

        assertGt(u0 - usdtLike.balanceOf(disputer), 0, "the route should have consumed the input");
        assertLt(u0 - usdtLike.balanceOf(disputer), maxIn, "the unused input should have come back");
        assertEq(usdtLike.balanceOf(address(helper)), 0, "helper retained the route input");
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    /// @dev Rolls the local preimage forward exactly as the oracle did, and checks it still hashes
    ///      to the stored state so a later round is testing the real game.
    function _advance(Game memory ctx, uint128 newAmount1, uint128 newAmount2) internal view {
        ctx.game.currentAmount1 = newAmount1;
        ctx.game.currentAmount2 = newAmount2;
        ctx.game.currentReporter = disputer;
        ctx.game.reportTimestamp = uint48(block.timestamp);
        ctx.game.lastReportOppoTime = uint48(block.number);
        assertEq(
            oracle.oracleGame(ctx.reportId),
            keccak256(abi.encode(ctx.game, ctx.helper)),
            "local preimage diverged from the oracle"
        );
    }

    /// @dev Counts Approval events emitted BY `token` FOR (helper -> oracle) since `vm.recordLogs`.
    function _countApprovals(address token) internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Approval(address,address,uint256)");
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].emitter != token || logs[k].topics.length < 3 || logs[k].topics[0] != sig) continue;
            if (
                address(uint160(uint256(logs[k].topics[1]))) == address(helper)
                    && address(uint160(uint256(logs[k].topics[2]))) == address(oracle)
            ) {
                ++n;
            }
        }
    }
}
