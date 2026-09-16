// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase, IERC20Like} from "./DisputeHelperBase.t.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";

/**
 * @notice The four shapes `routeInputToken` can take — oracle token1, oracle token2, an unrelated
 *         third ERC20, and native ETH as a third asset — plus a single route that sources BOTH
 *         missing legs.
 *
 * @dev THE TWO FUNDING REGIMES. When `routeInputToken` is one of the oracle tokens, the routing
 *      budget must come out of that token's own SURPLUS (`supplied - required`); nothing extra is
 *      pulled. When it is a third asset, exactly `maxSwapInput` is pulled on top of both supplied
 *      amounts, and its unspent remainder is refunded separately at the end of the call. These
 *      tests pin which regime applies by observing what the disputer is actually debited.
 *
 *      Every route below is genuine Universal Router calldata executed against a real pool, and
 *      always with `payerIsUser = false` so the router pays from the balance the helper pushed to
 *      it. Pools are 1:1 with deep liquidity, so the amounts consumed are close to the amounts
 *      out; no test asserts an exact quote.
 */
contract RouteInputAssetsTest is DisputeHelperBase {
    uint128 internal constant NEW_AMOUNT_1 = 1.1e18;

    // requiredToken1 on the !swapToken2 branch = 1.1e18 + 1e18 + 3e14 + 1e14
    uint256 internal constant REQUIRED_1 = 2.1004e18;
    // requiredToken2 for newAmount2 = 1050e18 is 1050e18 - 1000e18
    uint256 internal constant REQUIRED_2_AT_1050 = 50e18;
    // swapToken2 branch at newAmount2 = 1200e18: 1200e18 + 1000e18 + 3e17 + 1e17
    uint256 internal constant REQUIRED_2_AT_1200 = 2200.4e18;
    uint256 internal constant REQUIRED_1_ON_SWAP2 = 1e17; // 1.1e18 - 1e18

    // ────────────────────────────────────────────────────────────────────
    //  third-asset ERC20 route input
    // ────────────────────────────────────────────────────────────────────

    /// @dev tokenC is neither oracle token, so exactly `maxSwapInput` of it is pulled in addition
    ///      to the supplied amounts, and whatever the route does not consume comes back.
    function test_thirdErc20FundsTheToken1LegAndRefundsTheRemainder() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5e18;
        (bytes memory sc, bytes[] memory si) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);
        (bytes memory c, bytes[] memory i) = _appendSweep(sc, si, address(tokenC));

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 c0 = tokenC.balanceOf(disputer);

        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        assertEq(tokenA.balanceOf(disputer), a0, "token1 was supplied entirely by the route");
        uint256 spentC = c0 - tokenC.balanceOf(disputer);
        assertGt(spentC, 0, "the route must have consumed some tokenC");
        assertLt(spentC, maxIn, "the unspent tokenC was not returned");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    /// @dev Without a SWEEP the router keeps the unconsumed input. The dispute still succeeds
    ///      because both legs are funded — but the disputer eats the whole `maxSwapInput`. This is
    ///      the documented cost of an incomplete plan, and it is the disputer's own capital, so it
    ///      is a loss of efficiency rather than a loss of safety.
    function test_omittingTheSweepStrandsTheUnusedInputInTheRouter() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5e18;
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);

        uint256 c0 = tokenC.balanceOf(disputer);
        uint256 routerBefore = tokenC.balanceOf(router);

        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        assertEq(c0 - tokenC.balanceOf(disputer), maxIn, "the full maximum was spent");
        assertGt(tokenC.balanceOf(router) - routerBefore, 0, "the remainder should sit in the router");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    /// @dev A single plan sourcing BOTH missing legs from one input token.
    ///      newAmount2 = 1050e18 makes requiredToken1 = 2.1004e18 AND requiredToken2 = 50e18.
    function test_oneRouteSourcesBothMissingLegs() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 100e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), REQUIRED_2_AT_1050, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory c, bytes[] memory i) = _appendSweep(cj, ij, address(tokenC));

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 b0 = tokenB.balanceOf(disputer);
        uint256 c0 = tokenC.balanceOf(disputer);

        _callDispute(ctx, NEW_AMOUNT_1, 1050e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        assertEq(tokenA.balanceOf(disputer), a0, "token1 leg came from the route");
        assertEq(tokenB.balanceOf(disputer), b0, "token2 leg came from the route");
        uint256 spentC = c0 - tokenC.balanceOf(disputer);
        // Both legs are ~2.1e18 + ~50e18 of output at a 1:1 price, so consumption must clear 50e18.
        assertGt(spentC, 50e18, "both legs should have consumed input");
        assertLt(spentC, maxIn, "unused input was not swept back");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    // ────────────────────────────────────────────────────────────────────
    //  oracle token as its own route input
    // ────────────────────────────────────────────────────────────────────

    /// @dev routeInputToken == token1. The budget must come from token1's surplus, so the disputer
    ///      supplies required1 PLUS a routing surplus and nothing else is pulled.
    function test_token1SurplusFundsTheToken2Leg() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 surplus = 60e18;
        uint256 supplied1 = REQUIRED_1 + surplus;

        (bytes memory sc, bytes[] memory si) =
            _v2ExactOut(address(tokenA), address(tokenB), REQUIRED_2_AT_1050, surplus);
        (bytes memory c, bytes[] memory i) = _appendSweep(sc, si, address(tokenA));

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 b0 = tokenB.balanceOf(disputer);

        _callDispute(ctx, NEW_AMOUNT_1, 1050e18, supplied1, 0, address(tokenA), surplus, c, i, 0);

        assertEq(tokenB.balanceOf(disputer), b0, "token2 leg came from the route, not the wallet");
        uint256 spentA = a0 - tokenA.balanceOf(disputer);
        assertGt(spentA, REQUIRED_1, "the routing budget must come out of the token1 surplus");
        assertLt(spentA, supplied1, "the unspent surplus was not refunded");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB)));
    }

    /// @dev The route budget is capped by the surplus, not by the supplied amount: asking to route
    ///      more than `supplied1 - required1` must be rejected before any transfer to the router.
    function test_routingMoreThanTheToken1SurplusIsRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 surplus = 60e18;
        uint256 supplied1 = REQUIRED_1 + surplus;

        (bytes memory c, bytes[] memory i) =
            _v2ExactOut(address(tokenA), address(tokenB), REQUIRED_2_AT_1050, surplus + 1);

        vm.expectRevert(OracleDisputeHelper.InvalidMaximumSwapInput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 1050e18, supplied1, 0, address(tokenA), surplus + 1, c, i, 0);
    }

    /// @dev routeInputToken == token2, on the swapToken2 branch where token1 is the short leg.
    function test_token2SurplusFundsTheToken1Leg() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 surplus = 200e18;
        uint256 supplied2 = REQUIRED_2_AT_1200 + surplus;

        (bytes memory sc, bytes[] memory si) =
            _v2ExactOut(address(tokenB), address(tokenA), REQUIRED_1_ON_SWAP2, surplus);
        (bytes memory c, bytes[] memory i) = _appendSweep(sc, si, address(tokenB));

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 b0 = tokenB.balanceOf(disputer);

        _callDispute(ctx, NEW_AMOUNT_1, 1200e18, 0, supplied2, address(tokenB), surplus, c, i, 0);

        assertEq(tokenA.balanceOf(disputer), a0, "token1 leg came from the route");
        uint256 spentB = b0 - tokenB.balanceOf(disputer);
        assertGt(spentB, REQUIRED_2_AT_1200, "the budget came out of the token2 surplus");
        assertLt(spentB, supplied2, "the unspent surplus was not refunded");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB)));
    }

    // ────────────────────────────────────────────────────────────────────
    //  native ETH as a third route asset
    // ────────────────────────────────────────────────────────────────────

    /// @dev Neither oracle token is ETH, so `maxSwapInput` of ETH is expected ON TOP of the supplied
    ///      amounts and must arrive as msg.value. The plan wraps it, swaps WETH for token1, then
    ///      unwraps the remaining WETH back to the helper so the leftover is refundable as ETH.
    function test_thirdAssetEthFundsTheToken1Leg() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5 ether;
        (bytes memory c, bytes[] memory i) = _ethRoute(address(tokenA), REQUIRED_1, maxIn);

        uint256 e0 = disputer.balance;
        uint256 a0 = tokenA.balanceOf(disputer);

        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, ETH, maxIn, c, i, maxIn);

        assertEq(tokenA.balanceOf(disputer), a0, "token1 leg came from the route");
        uint256 spentEth = e0 - disputer.balance;
        assertGt(spentEth, 0, "some ETH must have been consumed");
        assertLt(spentEth, maxIn, "leftover ETH was not refunded");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB)));
    }

    /// @dev ETH is tracked as the route input, so excess msg.value is accepted and refunded.
    function test_ethRouteRefundsTooMuchValue() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5 ether;
        (bytes memory c, bytes[] memory i) = _ethRoute(address(tokenA), REQUIRED_1, maxIn);

        uint256 e0 = disputer.balance;
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, ETH, maxIn, c, i, maxIn + 1);

        assertGt(disputer.balance, e0 - (maxIn + 1), "excess msg.value was not refunded");
    }

    /// @dev ...and no less.
    function test_ethRouteRejectsTooLittleValue() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5 ether;
        (bytes memory c, bytes[] memory i) = _ethRoute(address(tokenA), REQUIRED_1, maxIn);

        vm.expectRevert(OracleDisputeHelper.InvalidMsgValue.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, ETH, maxIn, c, i, maxIn - 1);
    }

    // ────────────────────────────────────────────────────────────────────
    //  ETH as an ORACLE token — the budget is NOT additional
    // ────────────────────────────────────────────────────────────────────

    /// @dev With token2 == ETH, msg.value must equal `suppliedAmount2` alone. `additionalNativeValue`
    ///      stays zero because ETH is not a "separate" route input, so any routing budget has to be
    ///      inside that same supplied amount. Pinning this separates the two ETH regimes.
    function test_ethAsAnOracleTokenTakesNoAdditionalValue() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);

        // !swapToken2 branch (newAmount2 = 9 ether < 11 ether boundary):
        //   requiredToken1 = 1.1e18 + 1e18 + 3e14 + 1e14 = 2.1004e18
        //   requiredToken2 = 0, and 1 ether is credited internally instead.
        uint256 e0 = disputer.balance;

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 9 ether, REQUIRED_1, 0, address(tokenA), 0, c, i, 0);

        assertEq(disputer.balance, e0, "no ETH should move when the ETH leg needs nothing");
        assertEq(oracle.tokenHolder(disputer, ETH), 1 ether + 1, "ETH credit plus the dust sentinel");
        _assertHelperHoldsNothing(_tokens(address(tokenA), ETH));
    }

    /// @dev The same game, but the ETH leg genuinely needs funding: msg.value must equal
    ///      suppliedAmount2 exactly and the ETH is forwarded to the oracle with the dispute.
    ///      newAmount2 = 10.5 ether: requiredToken2 = 10.5 - 10 = 0.5 ether.
    function test_ethOracleLegIsFundedFromMsgValue() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);

        uint256 e0 = disputer.balance;

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 0.5 ether, address(tokenA), 0, c, i, 0.5 ether);

        assertEq(e0 - disputer.balance, 0.5 ether, "exactly the required ETH left the disputer");
        _assertHelperHoldsNothing(_tokens(address(tokenA), ETH));
    }

    /// @dev Oversupplied ETH on an ETH oracle leg is refunded by `_refundDelta`, not stranded.
    function test_oversuppliedEthOracleLegIsRefunded() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);

        uint256 e0 = disputer.balance;

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 3 ether, address(tokenA), 0, c, i, 3 ether);

        assertEq(e0 - disputer.balance, 0.5 ether, "only the requirement should be retained");
        _assertHelperHoldsNothing(_tokens(address(tokenA), ETH));
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    /// @dev Appends a SWEEP of `token` back to the helper — the only recipient the helper accepts.
    function _appendSweep(bytes memory commands, bytes[] memory inputs, address token)
        internal
        view
        returns (bytes memory, bytes[] memory)
    {
        bytes[] memory sweepInput = new bytes[](1);
        sweepInput[0] = _sweep(token, address(helper), 0);
        return _join(commands, inputs, abi.encodePacked(CMD_SWEEP), sweepInput);
    }

    /// @dev WRAP_ETH -> V3 exact-out WETH->tokenOut -> UNWRAP_WETH back to the helper. The final
    ///      unwrap is what makes the leftover refundable, since the helper only tracks ETH here.
    function _ethRoute(address tokenOut, uint256 amountOut, uint256 maxIn)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes memory path = abi.encodePacked(tokenOut, V3_FEE, address(weth));

        commands = abi.encodePacked(CMD_WRAP_ETH, CMD_V3_SWAP_EXACT_OUT, CMD_UNWRAP_WETH);
        inputs = new bytes[](3);
        inputs[0] = abi.encode(router, maxIn);
        inputs[1] = abi.encode(address(helper), amountOut, maxIn, path, false, _noHopPrices());
        inputs[2] = abi.encode(address(helper), uint256(0));
    }
}
