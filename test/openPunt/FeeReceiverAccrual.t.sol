// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./FeeReceiverBase.t.sol";

/**
 * @notice Real protocol-fee accrual through genuine `OpenOracle.dispute()` calls.
 *
 * @dev Both branches are exercised. Which token the fee lands in is decided by
 *      `newAmount2 * oldAmount1 > oldAmount2 * newAmount1`, and the expected amount is derived
 *      from the pre-dispute leg on that side, independently of the contract.
 */
contract FeeReceiverAccrualTest is FeeReceiverBase {
    function setUp() public {
        _setUpFees();
    }

    function _matched() internal returns (Proposal memory p, Matched memory mt, address receiver) {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (p, mt) = _matchAsset(s, m);
        receiver = _predictForPosition(p.swapId, mt.swap);
        assertEq(mt.game.protocolFeeRecipient, receiver, "game commits the counterfactual receiver");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Token1 fee
    // ══════════════════════════════════════════════════════════════════

    function test_token1FeeAccruesToAnUndeployedReceiver() public {
        (, Matched memory mt, address receiver) = _matched();
        Game memory g = _gameOf(mt);

        uint128 oldA1 = g.game.currentAmount1;
        uint128 newA1 = uint128(uint256(oldA1) * g.game.multiplier / 100);
        uint128 newA2 = g.game.currentAmount2;

        (bool swapToken2, address feeToken, uint256 expected) = _expectedFee(g, newA1, newA2);
        assertFalse(swapToken2, "token1 branch");
        assertEq(feeToken, address(tokenA), "fee token is token1");
        assertEq(expected, uint256(oldA1) * PROTO_FEE / 1e7, "derived from the OLD token1 amount");
        assertEq(expected, FEE_PER_DISPUTE, "and equals the hand-derived 1% of 1e18");

        Game memory next = _dispute(g, newA1, newA2, disputer);

        assertEq(_spendable(receiver, address(tokenA)), expected, "receiver gained exactly the token1 fee");
        assertEq(oracle.tokenHolder(receiver, address(tokenA)), expected + 1, "raw balance is fee plus the sentinel");
        assertEq(_spendable(receiver, address(tokenB)), 0, "token2 side untouched");
        assertEq(receiver.code.length, 0, "the clone is still undeployed while holding the credit");
        assertEq(next.game.currentAmount1, A1_AFTER_ONE_DISPUTE, "escalated leg1");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Token2 fee
    // ══════════════════════════════════════════════════════════════════

    function test_token2FeeAccruesAndLeavesToken1FeesUntouched() public {
        (, Matched memory mt, address receiver) = _matched();
        Game memory g = _gameOf(mt);

        // first a token1 fee, from the genuine opening state
        uint256 fee1;
        (g, fee1) = _disputeForToken1Fee(g, disputer);
        assertEq(_spendable(receiver, address(tokenA)), fee1, "token1 fee accrued");

        // then a token2 fee, from the genuine post-dispute state
        uint128 oldA2 = g.game.currentAmount2;
        uint128 newA1 = uint128(uint256(g.game.currentAmount1) * g.game.multiplier / 100);
        uint128 newA2 = uint128(uint256(oldA2) * 2);

        (bool swapToken2, address feeToken, uint256 expected2) = _expectedFee(g, newA1, newA2);
        assertTrue(swapToken2, "token2 branch");
        assertEq(feeToken, address(tokenB), "fee token is token2");
        assertEq(expected2, uint256(oldA2) * PROTO_FEE / 1e7, "derived from the OLD token2 amount");

        _dispute(g, newA1, newA2, disputer2);

        assertEq(_spendable(receiver, address(tokenB)), expected2, "receiver gained exactly the token2 fee");
        assertEq(_spendable(receiver, address(tokenA)), fee1, "previously accrued token1 fees are untouched");
        assertEq(oracle.tokenHolder(receiver, address(tokenB)), expected2 + 1, "sentinel preserved on token2");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Both tokens before deployment, then one distribution
    // ══════════════════════════════════════════════════════════════════

    function test_bothTokenFeesAccrueBeforeDeploymentAndDistributeTogether() public {
        (Proposal memory p, Matched memory mt, address receiver) = _matched();
        Game memory g = _gameOf(mt);

        uint256 fee1;
        uint256 fee2;
        (g, fee1) = _disputeForToken1Fee(g, disputer);
        (g, fee2) = _disputeForToken2Fee(g, disputer2);

        assertEq(receiver.code.length, 0, "still undeployed while both fees sit there");
        assertEq(_spendable(receiver, address(tokenA)), fee1, "token1 fee held");
        assertEq(_spendable(receiver, address(tokenB)), fee2, "token2 fee held");

        FeeBook memory before = _feeBook(receiver, address(tokenA), address(tokenB));

        // The latest genuine state authenticates the deployment.
        (address deployed, uint256 fees1, uint256 fees2, Vm.Log[] memory logs) =
            _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(deployed, receiver, "deployed at the counterfactual address");
        assertEq(fees1, fee1, "token1 fees distributed in full");
        assertEq(fees2, fee2, "token2 fees distributed in full");

        (uint256 e1, uint256 e2) = _readFeesDistributed(logs, receiver, p.swapId);
        assertEq(e1, fees1, "event matches the return value");
        assertEq(e2, fees2, "event matches the return value");

        _assertDistributed(before, receiver, address(tokenA), address(tokenB), fees1, fees2, "both tokens");
        _assertOnlySentinelsRemain(receiver, address(tokenA), address(tokenB), "both tokens");
    }

    /// @dev Fees accrue against the state the game is in when each dispute lands, so a second
    ///      token1 dispute pays a larger fee than the first because the leg has escalated.
    function test_successiveToken1FeesTrackTheEscalatingLeg() public {
        (, Matched memory mt, address receiver) = _matched();
        Game memory g = _gameOf(mt);

        uint256 fee1;
        uint256 fee2;
        (g, fee1) = _disputeForToken1Fee(g, disputer);
        (g, fee2) = _disputeForToken1Fee(g, disputer2);

        assertEq(fee1, uint256(A1) * PROTO_FEE / 1e7, "first fee on the original leg");
        assertEq(fee2, uint256(A1_AFTER_ONE_DISPUTE) * PROTO_FEE / 1e7, "second fee on the escalated leg");
        assertGt(fee2, fee1, "the escalated leg pays more");
        assertEq(_spendable(receiver, address(tokenA)), fee1 + fee2, "both accrued to the same receiver");
        assertEq(g.game.currentAmount1, A1_AFTER_TWO_DISPUTES, "leg escalated twice");
    }
}
