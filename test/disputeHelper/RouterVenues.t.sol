// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase} from "./DisputeHelperBase.t.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";

/**
 * @notice Real Universal Router encodings against real V2, V3 and V4 venues, in both exact-input
 *         and exact-output form, always paid from the router's own balance.
 *
 * @dev WHY ROUTER-HELD PAYMENT IS THE ONLY SUPPORTED SHAPE. The helper pushes `maxSwapInput` to the
 *      router and then calls `execute`. It never grants Permit2 allowances and never approves the
 *      router, so a plan encoded with `payerIsUser = true` has nothing to pull from and cannot
 *      fund the swap. `test_payerIsUserPlansCannotFundTheLegs` pins that this fails closed rather
 *      than silently drawing on the disputer's wallet.
 *
 *      UNDER-DELIVERY. `_assertFullyFunded` is the backstop for every opaque plan: whatever the
 *      route did, the helper's balance must have grown by at least the required amount over the
 *      pre-call snapshot. A route that swaps too little, sends output elsewhere, or does nothing
 *      at all lands on the same `InsufficientRouterOutput`.
 *
 *      All games use token1 = tokenA, token2 = tokenB, oldAmount1 = 1e18, oldAmount2 = 1000e18,
 *      newAmount1 = 1.1e18 and newAmount2 = 900e18, so requiredToken1 = 2.1004e18 and
 *      requiredToken2 = 0 unless a test says otherwise.
 */
contract RouterVenuesTest is DisputeHelperBase {
    uint128 internal constant NEW_AMOUNT_1 = 1.1e18;
    uint256 internal constant REQUIRED_1 = 2.1004e18;

    /// @dev v4-periphery's ActionConstants.OPEN_DELTA — "settle whatever is owed".
    uint128 internal constant OPEN_DELTA = 0;

    // ────────────────────────────────────────────────────────────────────
    //  V2
    // ────────────────────────────────────────────────────────────────────

    function test_v2ExactOutputFundsTheLegExactly() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory sc, bytes[] memory si) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, 5e18);
        (bytes memory c, bytes[] memory i) = _withSweep(sc, si, address(tokenC));

        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    /// @dev Exact-INPUT spends the whole budget, so there is nothing left to sweep. The route must
    ///      still clear the requirement, and the surplus token1 above the requirement is refunded
    ///      to the disputer rather than kept.
    function test_v2ExactInputRefundsTheOutputSurplus() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5e18;
        (bytes memory c, bytes[] memory i) = _v2ExactIn(address(tokenC), address(tokenA), maxIn, REQUIRED_1);

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 c0 = tokenC.balanceOf(disputer);

        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        assertEq(c0 - tokenC.balanceOf(disputer), maxIn, "exact-input consumes the whole budget");
        // ~5e18 of tokenC bought ~5e18 of tokenA at 1:1; only 2.1004e18 was needed.
        assertGt(tokenA.balanceOf(disputer), a0, "the excess token1 output must be refunded");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    /// @dev An exact-input route sized below the requirement swaps successfully but leaves the leg
    ///      short. The helper's own assertion is what stops it.
    function test_v2UnderDeliveryIsRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        // 1e18 of tokenC buys well under the 2.1004e18 of tokenA required.
        (bytes memory c, bytes[] memory i) = _v2ExactIn(address(tokenC), address(tokenA), 1e18, 1);

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 1e18, c, i, 0);
    }

    // ────────────────────────────────────────────────────────────────────
    //  V3
    // ────────────────────────────────────────────────────────────────────

    function test_v3ExactOutputFundsTheLeg() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory sc, bytes[] memory si) = _v3ExactOut(address(tokenC), address(tokenA), REQUIRED_1, 5e18);
        (bytes memory c, bytes[] memory i) = _withSweep(sc, si, address(tokenC));

        uint256 c0 = tokenC.balanceOf(disputer);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);

        assertLt(c0 - tokenC.balanceOf(disputer), 5e18, "exact-output should leave a sweepable remainder");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    function test_v3ExactInputFundsTheLeg() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _v3ExactIn(address(tokenC), address(tokenA), 5e18, REQUIRED_1);

        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    function test_v3UnderDeliveryIsRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _v3ExactIn(address(tokenC), address(tokenA), 1e18, 1);

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 1e18, c, i, 0);
    }

    // ────────────────────────────────────────────────────────────────────
    //  V4
    // ────────────────────────────────────────────────────────────────────

    /// @dev V4's TAKE_ALL credits the router's caller, which is the helper. That is why a V4 plan
    ///      needs no explicit recipient and still cannot divert the output.
    function test_v4ExactInputSingleFundsTheLeg() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) =
            _v4ExactInSingle(address(tokenC), address(tokenA), 5e18, uint128(REQUIRED_1), address(0));

        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    function test_v4ExactOutputSingleFundsTheLegAndSweepsTheRemainder() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory sc, bytes[] memory si) =
            _v4ExactOutSingle(address(tokenC), address(tokenA), uint128(REQUIRED_1), 5e18);
        (bytes memory c, bytes[] memory i) = _withSweep(sc, si, address(tokenC));

        uint256 c0 = tokenC.balanceOf(disputer);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);

        assertLt(c0 - tokenC.balanceOf(disputer), 5e18, "exact-output should leave a sweepable remainder");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    function test_v4UnderDeliveryIsRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _v4ExactInSingle(address(tokenC), address(tokenA), 1e18, 1, address(0));

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 1e18, c, i, 0);
    }

    /// @dev A V4 plan may name any recipient in its nested TAKE — the top-level SWEEP rule does not
    ///      reach inside V4_SWAP. Diverting the output is still useless: the helper's balance never
    ///      grows, so the whole call reverts and the diverted funds are rolled back with it.
    function test_v4TakeToAnOutsideAddressStillRevertsTheWholeCall() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        address thief = address(0xBAD);

        (bytes memory c, bytes[] memory i) = _v4ExactInSingleTakingTo(address(tokenC), address(tokenA), 5e18, thief);

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);

        assertEq(tokenA.balanceOf(thief), 0, "the diverted output must not survive the revert");
    }

    // ────────────────────────────────────────────────────────────────────
    //  funding-source and delivery-target negatives
    // ────────────────────────────────────────────────────────────────────

    /// @dev `payerIsUser = true` makes the router pull from `msgSender()` — the helper — through
    ///      Permit2. The helper holds no Permit2 allowance, so the plan cannot fund itself.
    function test_payerIsUserPlansCannotFundTheLegs() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        address[] memory path = new address[](2);
        path[0] = address(tokenC);
        path[1] = address(tokenA);

        bytes memory c = abi.encodePacked(CMD_V2_SWAP_EXACT_IN);
        bytes[] memory i = new bytes[](1);
        i[0] = abi.encode(address(helper), uint256(5e18), uint256(1), path, true, _noHopPrices());

        vm.expectRevert();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);
    }

    /// @dev A V2/V3 swap CAN name any recipient — only SWEEP is recipient-constrained. Sending the
    ///      output to a third party leaves the helper unfunded and the call reverts atomically.
    function test_swapOutputSentElsewhereRevertsAndIsRolledBack() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        address thief = address(0xBAD);

        address[] memory path = new address[](2);
        path[0] = address(tokenC);
        path[1] = address(tokenA);

        bytes memory c = abi.encodePacked(CMD_V2_SWAP_EXACT_IN);
        bytes[] memory i = new bytes[](1);
        i[0] = abi.encode(thief, uint256(5e18), uint256(1), path, false, _noHopPrices());

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);

        assertEq(tokenA.balanceOf(thief), 0, "the diverted output must not survive the revert");
    }

    /// @dev An empty command list is a well-formed route that simply does nothing. It must not be
    ///      mistaken for "no routing needed".
    function test_emptyCommandListStillFailsTheFundingAssertion() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _noRoute();

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);
    }

    /// @dev A route that swaps the WRONG token1 — output arrives, but in an asset the oracle does
    ///      not need. The helper does not track it and cannot return it, which is exactly what the
    ///      contract's NatSpec warns about; the dispute itself still fails closed.
    function test_outputInAnUntrackedTokenDoesNotSatisfyTheRequirement() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) = _v2ExactIn(address(tokenC), address(tokenB), 5e18, 1);

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);
    }

    /// @dev A mismatched commands/inputs pair is rejected by the caller-selected router.
    function test_commandAndInputCountsMustMatch() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory sc, bytes[] memory si) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, 5e18);
        bytes memory c = abi.encodePacked(sc, CMD_SWEEP); // two commands, one input

        vm.expectRevert(bytes4(keccak256("LengthMismatch()")));
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, si, 0);
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    function _withSweep(bytes memory commands, bytes[] memory inputs, address token)
        internal
        view
        returns (bytes memory, bytes[] memory)
    {
        bytes[] memory sweepInput = new bytes[](1);
        sweepInput[0] = _sweep(token, address(helper), 0);
        return _join(commands, inputs, abi.encodePacked(CMD_SWEEP), sweepInput);
    }

    struct ExactOutSingle {
        PoolKeyLite poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @dev SETTLE with OPEN_DELTA pays whatever the exact-output swap ended up owing, from the
    ///      router's own balance.
    function _v4ExactOutSingle(address tokenIn, address tokenOut, uint128 amountOut, uint128 amountInMax)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        PoolKeyLite memory key = _poolKey(tokenIn, tokenOut, address(0));

        bytes memory actions = abi.encodePacked(ACTION_SWAP_EXACT_OUT_SINGLE, ACTION_SETTLE, ACTION_TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactOutSingle({
                poolKey: key,
                zeroForOne: tokenIn == key.currency0,
                amountOut: amountOut,
                amountInMaximum: amountInMax,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(tokenIn, uint256(OPEN_DELTA), false);
        params[2] = abi.encode(tokenOut, uint256(amountOut));

        commands = abi.encodePacked(CMD_V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    /// @dev Same as `_v4ExactInSingle` but with an explicit TAKE to an arbitrary recipient.
    function _v4ExactInSingleTakingTo(address tokenIn, address tokenOut, uint128 amountIn, address recipient)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        PoolKeyLite memory key = _poolKey(tokenIn, tokenOut, address(0));

        bytes memory actions = abi.encodePacked(ACTION_SWAP_EXACT_IN_SINGLE, ACTION_SETTLE, ACTION_TAKE);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInSingle({
                poolKey: key,
                zeroForOne: tokenIn == key.currency0,
                amountIn: amountIn,
                amountOutMinimum: 1,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(tokenIn, uint256(amountIn), false);
        // OPEN_DELTA takes the full credit, so nothing is left unsettled.
        params[2] = abi.encode(tokenOut, recipient, uint256(OPEN_DELTA));

        commands = abi.encodePacked(CMD_V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }
}
