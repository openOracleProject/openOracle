// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase} from "./DisputeHelperBase.t.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";
import {ContractDisputer} from "./util/Actors.sol";

/**
 * @notice Native ETH refunds, and what happens when the recipient refuses them.
 *
 * @dev THE DESIGN CHOICE UNDER TEST. `_refundDelta` sends ETH with a plain `call` and reverts with
 *      `EthTransferFailed` if the recipient rejects it. The helper does NOT fall back to crediting
 *      an internal balance, because it holds no per-user state — there would be nowhere to put the
 *      funds. Reverting is therefore the only safe outcome: the caller keeps their capital and the
 *      dispute simply does not happen.
 *
 *      THE COST. A contract that cannot receive ETH cannot use a refundable ETH path at all. It can
 *      still dispute — by supplying EXACTLY the required amount, so no refund is ever attempted.
 *      `test_aRefusingCallerSucceedsWhenNothingNeedsRefunding` pins that escape hatch, which is
 *      what makes the revert an inconvenience rather than a lockout.
 *
 *      An EOA cannot reject ETH, so every test here needs a real contract caller. `ContractDisputer`
 *      is only a caller: it forwards a genuine `disputeWithRoute` call and bubbles the revert.
 */
contract EthRefundsTest is DisputeHelperBase {
    uint128 internal constant NEW_AMOUNT_1 = 1.1e18;
    uint256 internal constant REQUIRED_1 = 2.1004e18;

    ContractDisputer internal caller;

    function setUp() public override {
        super.setUp();

        caller = new ContractDisputer();
        tokenA.mint(address(caller), 1_000_000e18);
        tokenB.mint(address(caller), 1_000_000e18);
        tokenC.mint(address(caller), 1_000_000e18);
        vm.deal(address(caller), 1_000 ether);

        caller.approveToken(address(tokenA), address(helper), type(uint256).max);
        caller.approveToken(address(tokenB), address(helper), type(uint256).max);
        caller.approveToken(address(tokenC), address(helper), type(uint256).max);
    }

    // ────────────────────────────────────────────────────────────────────
    //  a contract that accepts ETH
    // ────────────────────────────────────────────────────────────────────

    /// @dev Baseline: an oversupplied ETH oracle leg refunds the difference to a contract caller.
    ///      requiredToken2 = 10.5 - 10 = 0.5 ether, supplied 4 ether, so 3.5 ether returns.
    function test_aContractCallerReceivesAnEthRefund() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);

        uint256 e0 = address(caller).balance;
        _fire(ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 4 ether, address(tokenA), 0, 4 ether);

        assertEq(e0 - address(caller).balance, 0.5 ether, "only the requirement should be retained");
        assertEq(caller.ethReceipts(), 1, "exactly one refund transfer");
    }

    // ────────────────────────────────────────────────────────────────────
    //  a contract that refuses ETH
    // ────────────────────────────────────────────────────────────────────

    /// @dev The oracle-token ETH refund path.
    function test_aRefusingCallerBlocksAnOversuppliedEthLeg() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);
        caller.setAcceptEth(false);

        vm.expectRevert(OracleDisputeHelper.EthTransferFailed.selector);
        _fire(ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 4 ether, address(tokenA), 0, 4 ether);
    }

    /// @dev The escape hatch: supply the requirement exactly and `_refundDelta` returns before ever
    ///      attempting a transfer, so a refusing contract can still dispute.
    function test_aRefusingCallerSucceedsWhenNothingNeedsRefunding() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);
        caller.setAcceptEth(false);

        _fire(ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 0.5 ether, address(tokenA), 0, 0.5 ether);

        assertEq(caller.ethReceipts(), 0, "no refund should have been attempted");
        _assertHelperHoldsNothing(_tokens(address(tokenA), ETH));
    }

    /// @dev The SEPARATE third-asset ETH refund path, which runs after the dispute rather than
    ///      inside `_disputeAndRefund`. It fails the same way.
    function test_aRefusingCallerBlocksTheThirdAssetEthRemainder() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        caller.setAcceptEth(false);

        uint256 maxIn = 5 ether;
        (bytes memory c, bytes[] memory i) = _ethRoute(address(tokenA), REQUIRED_1, maxIn);

        vm.expectRevert(OracleDisputeHelper.EthTransferFailed.selector);
        _fireRoute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, ETH, maxIn, c, i, maxIn);
    }

    /// @dev The same route succeeds once the caller accepts ETH again — so the failure above is the
    ///      refund, not the route.
    function test_theSameThirdAssetEthRouteSucceedsWhenEthIsAccepted() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5 ether;
        (bytes memory c, bytes[] memory i) = _ethRoute(address(tokenA), REQUIRED_1, maxIn);

        uint256 e0 = address(caller).balance;
        _fireRoute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, ETH, maxIn, c, i, maxIn);

        assertLt(e0 - address(caller).balance, maxIn, "the ETH remainder was not refunded");
        assertEq(caller.ethReceipts(), 1, "exactly one refund transfer");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB)));
    }

    /// @dev A refused refund must leave nothing behind: the oracle state is untouched and the
    ///      helper holds none of the caller's ETH.
    function test_aRefusedRefundRollsBackTheEntireDispute() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);
        caller.setAcceptEth(false);

        bytes32 stateBefore = oracle.oracleGame(ctx.reportId);
        uint256 helperEthBefore = address(helper).balance;
        uint256 callerA = tokenA.balanceOf(address(caller));

        vm.expectRevert(OracleDisputeHelper.EthTransferFailed.selector);
        _fire(ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 4 ether, address(tokenA), 0, 4 ether);

        assertEq(oracle.oracleGame(ctx.reportId), stateBefore, "the dispute survived a failed refund");
        assertEq(address(helper).balance, helperEthBefore, "ETH was stranded in the helper");
        assertEq(tokenA.balanceOf(address(caller)), callerA, "token1 was consumed by a reverted call");
    }

    /// @dev ERC20 refunds do not go through the ETH path at all, so a caller that refuses ETH is
    ///      still refunded normally in tokens.
    function test_aRefusingCallerStillReceivesErc20Refunds() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        caller.setAcceptEth(false);

        uint256 a0 = tokenA.balanceOf(address(caller));
        _fire(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1 + 300e18, 0, address(tokenA), 0, 0);

        assertEq(a0 - tokenA.balanceOf(address(caller)), REQUIRED_1, "the ERC20 oversupply was not refunded");
        assertEq(caller.ethReceipts(), 0, "no ETH transfer should occur");
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    function _fire(
        Game memory ctx,
        uint128 newAmount1,
        uint128 newAmount2,
        uint256 supplied1,
        uint256 supplied2,
        address routeInputToken,
        uint256 maxSwapInput,
        uint256 ethValue
    ) internal {
        (bytes memory c, bytes[] memory i) = _noRoute();
        _fireRoute(ctx, newAmount1, newAmount2, supplied1, supplied2, routeInputToken, maxSwapInput, c, i, ethValue);
    }

    function _fireRoute(
        Game memory ctx,
        uint128 newAmount1,
        uint128 newAmount2,
        uint256 supplied1,
        uint256 supplied2,
        address routeInputToken,
        uint256 maxSwapInput,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 ethValue
    ) internal {
        bytes memory payload = abi.encodeCall(
            OracleDisputeHelper.disputeWithRoute,
            (
                _dd(ctx, newAmount1, newAmount2),
                ctx.game,
                ctx.helper,
                _emptyTiming(),
                supplied1,
                supplied2,
                false,
                routeInputToken,
                maxSwapInput,
                commands,
                inputs,
                block.timestamp + 1,
                router
            )
        );
        caller.fire(address(helper), ethValue, payload);
    }

    /// @dev WRAP_ETH -> V3 exact-out WETH->tokenOut -> UNWRAP_WETH back to the helper, so the
    ///      leftover returns as native ETH and is refundable.
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
