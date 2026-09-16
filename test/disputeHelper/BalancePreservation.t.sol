// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase} from "./DisputeHelperBase.t.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";

/**
 * @notice The helper is stateless and holds nothing between calls, but anyone can send it tokens or
 *         ETH. These tests pin that a pre-existing balance is neither spendable by a caller nor
 *         payable out to one.
 *
 * @dev THE MECHANISM. `_startingBalance` snapshots each tracked asset BEFORE any pull (subtracting
 *      `msg.value` for ETH, since that arrived with this very call), `_assertFullyFunded` requires
 *      `balance >= start + required`, and `_refundDelta` returns only `current - start`. Together
 *      those three make a donated balance invisible: it can neither satisfy a requirement nor be
 *      swept out as a refund.
 *
 *      WHY THIS MATTERS. Without the snapshot, the first caller after a donation could fund their
 *      dispute from someone else's stranded tokens, or simply claim them as a refund. Both are
 *      tested directly below.
 */
contract BalancePreservationTest is DisputeHelperBase {
    uint128 internal constant NEW_AMOUNT_1 = 1.1e18;
    uint256 internal constant REQUIRED_1 = 2.1004e18;

    uint256 internal constant DONATION = 777e18;
    uint256 internal constant ETH_DONATION = 13 ether;

    // ────────────────────────────────────────────────────────────────────
    //  a donation cannot be spent
    // ────────────────────────────────────────────────────────────────────

    /// @dev The single most important case: a donated balance that exactly covers the requirement
    ///      must NOT satisfy it. The caller supplies nothing and the call fails closed.
    function test_aDonationCannotSubstituteForFunding() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        tokenA.mint(address(helper), REQUIRED_1);

        (bytes memory c, bytes[] memory i) = _noRoute();

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);

        assertEq(tokenA.balanceOf(address(helper)), REQUIRED_1, "the donation must still be there");
    }

    /// @dev Same for ETH on a game whose token2 is ETH.
    function test_anEthDonationCannotSubstituteForFunding() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);
        vm.deal(address(helper), ETH_DONATION);

        (bytes memory c, bytes[] memory i) = _noRoute();

        // requiredToken2 = 10.5 - 10 = 0.5 ether, supplied as 0.
        vm.expectRevert(OracleDisputeHelper.InvalidMaximumSwapInput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 0, address(tokenA), 0, c, i, 0);

        assertEq(address(helper).balance, ETH_DONATION, "the ETH donation must still be there");
    }

    // ────────────────────────────────────────────────────────────────────
    //  a donation cannot be claimed as a refund
    // ────────────────────────────────────────────────────────────────────

    function test_donatedErc20SurvivesASuccessfulDispute() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        tokenA.mint(address(helper), DONATION);
        tokenB.mint(address(helper), DONATION);

        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), REQUIRED_1, "the disputer must not be paid the donation");
        assertEq(tokenA.balanceOf(address(helper)), DONATION, "token1 donation consumed");
        assertEq(tokenB.balanceOf(address(helper)), DONATION, "token2 donation consumed");
    }

    /// @dev Oversupplying on top of a donation: the refund must be exactly the oversupply.
    function test_theRefundIsTheDeltaNotTheWholeBalance() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        tokenA.mint(address(helper), DONATION);

        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1 + 40e18, 0, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), REQUIRED_1, "only the oversupply should return");
        assertEq(tokenA.balanceOf(address(helper)), DONATION, "the donation was swept out with the refund");
    }

    /// @dev ETH donation on an ERC20-only game. `_startingBalance` subtracts msg.value, so the
    ///      donation is outside the tracked delta and cannot leak.
    function test_donatedEthSurvivesAnErc20Dispute() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        vm.deal(address(helper), ETH_DONATION);

        uint256 e0 = disputer.balance;

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(tokenA), 0, c, i, 0);

        assertEq(disputer.balance, e0, "no ETH should have reached the disputer");
        assertEq(address(helper).balance, ETH_DONATION, "the ETH donation was drained");
    }

    /// @dev ETH donation on a game whose token2 IS ETH, with an oversupplied ETH leg. The refund
    ///      must be the oversupply only — this is where a missing `-= msg.value` would show up as
    ///      an extra payout, and where a missing snapshot would hand over the whole donation.
    function test_donatedEthSurvivesAnOversuppliedEthLeg() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);
        vm.deal(address(helper), ETH_DONATION);

        uint256 e0 = disputer.balance;

        (bytes memory c, bytes[] memory i) = _noRoute();
        // requiredToken2 = 0.5 ether; supply 4 ether, so 3.5 ether must come back.
        _callDispute(ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 4 ether, address(tokenA), 0, c, i, 4 ether);

        assertEq(e0 - disputer.balance, 0.5 ether, "refund must be the oversupply, not the donation");
        assertEq(address(helper).balance, ETH_DONATION, "the ETH donation was drained");
    }

    /// @dev A donation of the third-asset route token is separately snapshotted by
    ///      `routeInputStartBalance` and must survive a routed dispute.
    function test_donatedRouteInputTokenSurvivesARoutedDispute() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        tokenC.mint(address(helper), DONATION);

        uint256 maxIn = 5e18;
        (bytes memory sc, bytes[] memory si) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);
        bytes[] memory sweepInput = new bytes[](1);
        sweepInput[0] = _sweep(address(tokenC), address(helper), 0);
        (bytes memory c, bytes[] memory i) = _join(sc, si, abi.encodePacked(CMD_SWEEP), sweepInput);

        uint256 c0 = tokenC.balanceOf(disputer);

        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        assertLt(c0 - tokenC.balanceOf(disputer), maxIn, "the unused input should have returned");
        assertEq(tokenC.balanceOf(address(helper)), DONATION, "the route-input donation was drained");
    }

    /// @dev And a donation of the route-input token cannot be spent as routing budget either:
    ///      `maxSwapInput` above what the caller actually supplied is still pulled from the caller.
    function test_routeBudgetIsPulledFromTheCallerNotFromADonation() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        tokenC.mint(address(helper), DONATION);

        uint256 maxIn = 5e18;
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);

        uint256 c0 = tokenC.balanceOf(disputer);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        assertEq(c0 - tokenC.balanceOf(disputer), maxIn, "the whole budget must come from the caller");
        assertEq(tokenC.balanceOf(address(helper)), DONATION, "the donation was spent as budget");
    }

    // ────────────────────────────────────────────────────────────────────
    //  the snapshot floor
    // ────────────────────────────────────────────────────────────────────

    /// @dev Back-to-back disputes over a standing donation: the donation must be exactly as large
    ///      after the second call as before the first.
    function test_repeatedDisputesNeverErodeADonation() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        tokenA.mint(address(helper), DONATION);
        tokenB.mint(address(helper), DONATION);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1 + 10e18, 0, address(tokenA), 0, c, i, 0);

        ctx.game.currentAmount1 = NEW_AMOUNT_1;
        ctx.game.currentAmount2 = 900e18;
        ctx.game.currentReporter = disputer;
        ctx.game.reportTimestamp = uint48(block.timestamp);
        ctx.game.lastReportOppoTime = uint48(block.number);

        // Round 2: oldAmount1 = 1.1e18 -> newAmount1 = 1.21e18
        //   fee = 1.1e18 * 3000 / 1e7 = 3.3e14, protocolFee = 1.1e18 * 1000 / 1e7 = 1.1e14
        //   requiredToken1 = 1.21e18 + 1.1e18 + 3.3e14 + 1.1e14 = 2.31044e18
        _callDispute(ctx, 1.21e18, 800e18, 2.31044e18 + 10e18, 0, address(tokenA), 0, c, i, 0);

        assertEq(tokenA.balanceOf(address(helper)), DONATION, "token1 donation eroded");
        assertEq(tokenB.balanceOf(address(helper)), DONATION, "token2 donation eroded");
    }
}
