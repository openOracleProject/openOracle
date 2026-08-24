// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice cancelSwapOpen(): who may cancel and when, how the margin and the three ETH
 *         compensations are split, and where each lands under all four funding modes.
 *
 * @dev Payout shape, read off the contract:
 *        totalGasComp = matcherGasComp + openExecutionComp
 *        swapper cancels (any time)          -> swapperPiece = totalGasComp, callerPiece = 0
 *        outsider cancels (past expiration)  -> callerPiece  = matcherGasComp
 *                                              swapperPiece = openExecutionComp
 *        settlerReward always rides with the swapper's piece.
 *
 *      Delivery route is chosen by `useInternalBalances`:
 *        false -> margin pushed externally by the oracle, ETH pushed by payEth
 *        true  -> margin moved inside the oracle ledger, ETH queued in tempHolding
 *      The outsider's matcherGasComp always lands in tempHolding, in either mode.
 *
 *      The post-hash `NotActive` branch is unreachable because `propose()` always stamps
 *      `swapper = msg.sender`, so a stored proposal with `swapper == address(0)` is unreachable
 *      without fabricated state.
 */
contract CancelSwapOpenTest is OpenPuntBase {
    uint256 internal constant EXTRA_ETH = uint256(MATCHER_GAS_COMP) + SETTLER_REWARD + OPEN_EXEC_COMP;
    uint256 internal constant SWAPPER_SHARE_WHEN_OUTSIDER_CANCELS = uint256(OPEN_EXEC_COMP) + SETTLER_REWARD;

    function setUp() public {
        _setUpAll();
        collat.mint(swapper, 1_000_000e18);
        // enough to pre-fund the oracle ETH ledger below AND still pay msg.value on proposals
        vm.deal(swapper, 100_000 ether);

        // internal-balance modes: swapper pre-funds its own oracle ledger
        vm.startPrank(swapper);
        collat.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(collat), 10 * INITIAL_MARGIN_SWAPPER, swapper);
        oracle.deposit{value: 10 * uint256(INITIAL_MARGIN_SWAPPER)}(address(0), 10 * INITIAL_MARGIN_SWAPPER, swapper);
        oracle.approveInternal(address(punt), address(collat), type(uint256).max);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();
    }

    // ── proposal shapes ─────────────────────────────────────────────────

    function _erc20External() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap();
    }

    function _erc20Internal() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap();
        s.useInternalBalances = true;
    }

    function _ethExternal() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap();
        s.collatToken = address(0);
    }

    function _ethInternal() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap();
        s.collatToken = address(0);
        s.useInternalBalances = true;
    }

    function _proposeShape(OpenPuntStorage.ProposedSwap memory s) internal returns (Proposal memory p) {
        return _proposeWith(s, _defaultMatcherPreimage(), swapper);
    }

    function _warpPastExpiration(Proposal memory p) internal {
        uint256 target = uint256(p.swap.expiration) + 1;
        vm.warp(target);
        vm.roll(vm.getBlockNumber() + 1);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Who may cancel, and when
    // ══════════════════════════════════════════════════════════════════

    function test_beforeExpiration_onlySwapperMayCancel() public {
        Proposal memory p = _propose();
        bytes32 storedBefore = punt.swaps(p.swapId);
        uint256 outsiderEth0 = outsider.balance;

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.NotSwapper.selector);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(punt.swaps(p.swapId), storedBefore, "proposal untouched by the rejected cancel");
        assertEq(punt.tempHolding(outsider), 0, "outsider credited nothing");
        assertEq(outsider.balance, outsiderEth0, "outsider ETH untouched");
        assertEq(address(punt).balance, EXTRA_ETH, "core still holds the compensations");

        // the swapper can still cancel
        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);
        assertEq(punt.swaps(p.swapId), bytes32(0), "swapper cancelled successfully");
    }

    /// @dev The window check is `block.timestamp <= expiration`, so the boundary instant is
    ///      still swapper-only.
    function test_atExactExpiration_outsiderRevertsAndSwapperSucceeds() public {
        Proposal memory p = _propose();
        vm.warp(uint256(p.swap.expiration));
        assertEq(vm.getBlockTimestamp(), p.swap.expiration, "sitting exactly on expiration");

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.NotSwapper.selector);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "still live after the rejected cancel");

        uint256 swapperEth0 = swapper.balance;
        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(punt.swaps(p.swapId), bytes32(0), "swapper cancelled at the boundary");
        assertEq(swapper.balance, swapperEth0 + EXTRA_ETH, "swapper received every compensation");
    }

    function test_oneSecondAfterExpiration_anyoneMayCancel() public {
        Proposal memory p = _propose();
        _warpPastExpiration(p);

        vm.prank(outsider);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(punt.swaps(p.swapId), bytes32(0), "outsider cancelled past expiration");
        assertEq(punt.tempHolding(outsider), MATCHER_GAS_COMP, "outsider earned the matcher gas comp");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Payout splits
    // ══════════════════════════════════════════════════════════════════

    function test_swapperCancelBeforeExpirationReceivesEverything() public {
        uint256 swapperCollat0 = collat.balanceOf(swapper);
        uint256 swapperEth0 = swapper.balance;

        Proposal memory p = _propose();
        assertEq(swapper.balance, swapperEth0 - EXTRA_ETH, "compensations paid in at propose");

        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(collat.balanceOf(swapper), swapperCollat0, "full margin returned");
        assertEq(swapper.balance, swapperEth0, "matcherGasComp + openExecutionComp + settlerReward all returned");
        assertEq(punt.tempHolding(swapper), 0, "nothing left queued");
        assertEq(address(punt).balance, 0, "core drained of ETH");
        assertEq(_spendable(address(punt), address(collat)), 0, "core drained of collateral");
    }

    function test_outsiderCancelAfterExpirationSplitsCompensations() public {
        uint256 swapperCollat0 = collat.balanceOf(swapper);
        uint256 swapperEth0 = swapper.balance;
        uint256 outsiderEth0 = outsider.balance;

        Proposal memory p = _propose();
        _warpPastExpiration(p);

        vm.prank(outsider);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        // outsider: exactly matcherGasComp, and only as a tempHolding claim
        assertEq(punt.tempHolding(outsider), MATCHER_GAS_COMP, "outsider receives exactly matcherGasComp");
        assertEq(outsider.balance, outsiderEth0, "outsider not paid directly");

        // swapper: full margin plus openExecutionComp + settlerReward, pushed
        assertEq(collat.balanceOf(swapper), swapperCollat0, "full margin returned to the swapper");
        assertEq(
            swapper.balance,
            swapperEth0 - EXTRA_ETH + SWAPPER_SHARE_WHEN_OUTSIDER_CANCELS,
            "swapper receives openExecutionComp + settlerReward"
        );
        assertEq(punt.tempHolding(swapper), 0, "swapper's share was pushed, not queued");

        // the only ETH left on the core is what it still owes the outsider
        assertEq(address(punt).balance, MATCHER_GAS_COMP, "core retains only the outsider's claim");
        assertEq(address(punt).balance, punt.tempHolding(outsider), "core ETH == outstanding claims");

        // and the claim is really payable
        vm.prank(outsider);
        punt.withdraw(outsider, false);
        assertEq(outsider.balance, outsiderEth0 + MATCHER_GAS_COMP, "outsider withdrew its claim");
        assertEq(address(punt).balance, 0, "core fully drained");
    }

    function test_swapperCancelAfterExpirationStillReceivesEverything() public {
        uint256 swapperCollat0 = collat.balanceOf(swapper);
        uint256 swapperEth0 = swapper.balance;

        Proposal memory p = _propose();
        _warpPastExpiration(p);

        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(collat.balanceOf(swapper), swapperCollat0, "full margin returned");
        assertEq(swapper.balance, swapperEth0, "swapper still receives all three compensations");
        assertEq(address(punt).balance, 0, "core drained: no matcherGasComp split off");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Funding modes: where the refunds land
    // ══════════════════════════════════════════════════════════════════

    function test_mode_erc20External_refundsExternallyAndPushesEth() public {
        uint256 collatExt0 = collat.balanceOf(swapper);
        uint256 collatInt0 = _spendable(swapper, address(collat));
        uint256 eth0 = swapper.balance;

        Proposal memory p = _proposeShape(_erc20External());
        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(collat.balanceOf(swapper), collatExt0, "margin returned to the external balance");
        assertEq(_spendable(swapper, address(collat)), collatInt0, "oracle ledger untouched");
        assertEq(swapper.balance, eth0, "compensations pushed as raw ETH");
        assertEq(punt.tempHolding(swapper), 0, "nothing queued");
    }

    function test_mode_erc20Internal_refundsToLedgerAndQueuesEth() public {
        uint256 collatExt0 = collat.balanceOf(swapper);
        uint256 collatInt0 = _spendable(swapper, address(collat));
        uint256 eth0 = swapper.balance;

        Proposal memory p = _proposeShape(_erc20Internal());
        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(_spendable(swapper, address(collat)), collatInt0, "margin returned to the oracle ledger");
        assertEq(collat.balanceOf(swapper), collatExt0, "external balance untouched");
        assertEq(punt.tempHolding(swapper), EXTRA_ETH, "compensations queued in tempHolding");
        assertEq(swapper.balance, eth0 - EXTRA_ETH, "not pushed yet");

        vm.prank(swapper);
        punt.withdraw(swapper, false);
        assertEq(swapper.balance, eth0, "queued compensations withdrawn in full");
        assertEq(address(punt).balance, 0, "core drained");
    }

    function test_mode_ethExternal_pushesMarginAndCompensations() public {
        uint256 eth0 = swapper.balance;
        uint256 ethInt0 = _spendable(swapper, address(0));

        Proposal memory p = _proposeShape(_ethExternal());
        assertEq(swapper.balance, eth0 - EXTRA_ETH - INITIAL_MARGIN_SWAPPER, "margin and comps paid in");

        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(swapper.balance, eth0, "ETH margin and all compensations pushed back");
        assertEq(_spendable(swapper, address(0)), ethInt0, "oracle ETH ledger untouched");
        assertEq(punt.tempHolding(swapper), 0, "nothing queued");
        assertEq(_spendable(address(punt), address(0)), 0, "core internal ETH drained");
    }

    function test_mode_ethInternal_refundsToLedgerAndQueuesCompensations() public {
        uint256 eth0 = swapper.balance;
        uint256 ethInt0 = _spendable(swapper, address(0));

        Proposal memory p = _proposeShape(_ethInternal());
        assertEq(_spendable(swapper, address(0)), ethInt0 - INITIAL_MARGIN_SWAPPER, "margin drawn from the ledger");

        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(_spendable(swapper, address(0)), ethInt0, "ETH margin returned to the oracle ledger");
        assertEq(punt.tempHolding(swapper), EXTRA_ETH, "compensations queued in tempHolding");
        assertEq(swapper.balance, eth0 - EXTRA_ETH, "not pushed yet");
        assertEq(_spendable(address(punt), address(0)), 0, "core internal ETH drained");

        vm.prank(swapper);
        punt.withdraw(swapper, false);
        assertEq(swapper.balance, eth0, "queued compensations withdrawn in full");
    }

    /// @dev The outsider's matcherGasComp is queued in tempHolding in both delivery modes.
    function test_outsiderClaimIsQueuedInInternalBalanceModeToo() public {
        uint256 outsiderEth0 = outsider.balance;

        Proposal memory p = _proposeShape(_erc20Internal());
        _warpPastExpiration(p);

        vm.prank(outsider);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(punt.tempHolding(outsider), MATCHER_GAS_COMP, "outsider claim queued");
        assertEq(punt.tempHolding(swapper), SWAPPER_SHARE_WHEN_OUTSIDER_CANCELS, "swapper claim queued");
        assertEq(outsider.balance, outsiderEth0, "nothing pushed to the outsider");
        assertEq(
            address(punt).balance,
            punt.tempHolding(outsider) + punt.tempHolding(swapper),
            "core ETH exactly equals the queued claims"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  Event, hash deletion, residue
    // ══════════════════════════════════════════════════════════════════

    function test_swapCancelledEventReconstructsTheCancelledProposal() public {
        Proposal memory p = _propose();
        bytes32 storedBefore = punt.swaps(p.swapId);

        vm.recordLogs();
        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        Vm.Log memory l =
            _findLog(vm.getRecordedLogs(), address(punt), OpenPuntStorage.SwapCancelled.selector, p.swapId);
        (OpenPuntStorage.ProposedSwap memory es, OpenPuntStorage.MatcherPreimage memory em) =
            abi.decode(l.data, (OpenPuntStorage.ProposedSwap, OpenPuntStorage.MatcherPreimage));

        // the event carries exactly the proposal that was cancelled
        assertEq(keccak256(abi.encode(es, em)), storedBefore, "event reconstructs the deleted proposal hash");
        assertEq(keccak256(abi.encode(es)), keccak256(abi.encode(p.swap)), "ProposedSwap emitted verbatim");
        assertEq(keccak256(abi.encode(em)), keccak256(abi.encode(p.preimage)), "MatcherPreimage emitted verbatim");
        assertEq(es.swapper, swapper, "emitted swapper");
        assertEq(es.initialMarginSwapper, INITIAL_MARGIN_SWAPPER, "emitted margin");

        // and the slot is gone
        assertEq(punt.swaps(p.swapId), bytes32(0), "swap hash deleted");
        assertEq(collat.balanceOf(address(punt)), 0, "no external collateral residue");
        assertEq(_spendable(address(punt), address(collat)), 0, "no internal collateral residue");
        assertEq(_spendable(address(punt), address(0)), 0, "no internal ETH residue");
        assertEq(address(punt).balance, 0, "no raw ETH residue");
    }

    /// @dev Cancelling one proposal must not disturb an unrelated live one.
    function test_cancelLeavesOtherProposalsIntact() public {
        Proposal memory keep = _propose();
        Proposal memory drop = _propose();
        bytes32 keepHash = punt.swaps(keep.swapId);

        vm.prank(swapper);
        punt.cancelSwapOpen(drop.swapId, drop.swap, drop.preimage);

        assertEq(punt.swaps(drop.swapId), bytes32(0), "cancelled proposal deleted");
        assertEq(punt.swaps(keep.swapId), keepHash, "unrelated proposal intact");
        assertEq(
            _spendable(address(punt), address(collat)), INITIAL_MARGIN_SWAPPER, "core still holds the other margin"
        );
        assertEq(address(punt).balance, EXTRA_ETH, "core still holds the other compensations");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Rejections
    // ══════════════════════════════════════════════════════════════════

    function _assertCancelRejected(
        uint256 swapId,
        OpenPuntStorage.ProposedSwap memory s,
        OpenPuntStorage.MatcherPreimage memory m,
        address who,
        bytes4 err,
        string memory what
    ) internal {
        bytes32 storedBefore = punt.swaps(swapId);
        uint256 puntEth = address(punt).balance;
        uint256 puntCollat = _spendable(address(punt), address(collat));
        uint256 swapperCollat = collat.balanceOf(swapper);
        uint256 swapperEth = swapper.balance;
        uint256 callerTemp = punt.tempHolding(who);

        vm.prank(who);
        vm.expectRevert(err);
        punt.cancelSwapOpen(swapId, s, m);

        assertEq(punt.swaps(swapId), storedBefore, string.concat(what, ": stored hash unchanged"));
        assertEq(address(punt).balance, puntEth, string.concat(what, ": core ETH unchanged"));
        assertEq(_spendable(address(punt), address(collat)), puntCollat, string.concat(what, ": core collat unchanged"));
        assertEq(collat.balanceOf(swapper), swapperCollat, string.concat(what, ": swapper collat unchanged"));
        assertEq(swapper.balance, swapperEth, string.concat(what, ": swapper ETH unchanged"));
        assertEq(punt.tempHolding(who), callerTemp, string.concat(what, ": caller credited nothing"));
    }

    function test_wrongProposalFieldRejects() public {
        Proposal memory p = _propose();
        OpenPuntStorage.ProposedSwap memory tampered = _copy(p.swap);
        tampered.initialMarginSwapper += 1;

        _assertCancelRejected(
            p.swapId, tampered, p.preimage, swapper, PuntErrors.WrongHash.selector, "tampered proposal"
        );
    }

    function test_wrongPreimageFieldRejects() public {
        Proposal memory p = _propose();
        OpenPuntStorage.MatcherPreimage memory tampered = _copy(p.preimage);
        tampered.settlementTime += 1;

        _assertCancelRejected(p.swapId, p.swap, tampered, swapper, PuntErrors.WrongHash.selector, "tampered preimage");
    }

    function test_nonexistentSwapIdRejects() public {
        Proposal memory p = _propose();
        uint256 ghost = p.swapId + 999;

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.cancelSwapOpen(ghost, p.swap, p.preimage);

        assertEq(punt.swaps(ghost), bytes32(0), "ghost slot still empty");
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "real proposal untouched");
    }

    function test_alreadyMatchedPositionRejects() public {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        bytes32 matchedHash = punt.swaps(p.swapId);

        _assertCancelRejected(p.swapId, p.swap, p.preimage, swapper, PuntErrors.WrongHash.selector, "already matched");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(mt.swap)), "matched phase preserved");
        assertEq(punt.swaps(p.swapId), matchedHash, "matched hash unchanged");
    }

    function test_repeatedCancellationCannotDoubleRefund() public {
        uint256 swapperCollat0 = collat.balanceOf(swapper);
        uint256 swapperEth0 = swapper.balance;

        Proposal memory p = _propose();
        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(collat.balanceOf(swapper), swapperCollat0, "refunded once");
        assertEq(swapper.balance, swapperEth0, "compensations returned once");

        _assertCancelRejected(
            p.swapId, p.swap, p.preimage, swapper, PuntErrors.WrongHash.selector, "second cancel by swapper"
        );

        _warpPastExpiration(p);
        _assertCancelRejected(
            p.swapId, p.swap, p.preimage, outsider, PuntErrors.WrongHash.selector, "second cancel by outsider"
        );

        assertEq(collat.balanceOf(swapper), swapperCollat0, "still refunded exactly once");
        assertEq(swapper.balance, swapperEth0, "compensations still returned exactly once");
        assertEq(address(punt).balance, 0, "core holds nothing further");
    }
}
