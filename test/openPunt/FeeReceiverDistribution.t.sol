// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./FeeReceiverBase.t.sol";

/**
 * @notice Distribution mechanics, repeated accrual, reuse across a position's oracle games,
 *         survival past terminal position deletion, and the uint128 per-call tranche ceiling.
 */
contract FeeReceiverDistributionTest is FeeReceiverBase {
    function setUp() public {
        _setUpFees();
    }

    function _matched() internal returns (Proposal memory p, Matched memory mt, address receiver) {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (p, mt) = _matchAsset(s, m);
        receiver = _predictForPosition(p.swapId, mt.swap);
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. Split mechanics
    // ══════════════════════════════════════════════════════════════════

    function test_evenFeeSplitsEvenly() public {
        (Proposal memory p, Matched memory mt, address receiver) = _matched();
        Game memory g = _gameOf(mt);
        uint256 fee;
        (g, fee) = _disputeForToken1Fee(g, disputer);
        assertEq(fee % 2, 0, "the accrued fee is even");

        FeeBook memory before = _feeBook(receiver, address(tokenA), address(tokenB));
        (, uint256 fees1,,) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(_spendable(swapper, address(tokenA)) - before.swapper1, fee / 2, "swapper half");
        assertEq(_spendable(matcher, address(tokenA)) - before.matcher1, fee / 2, "matcher half");
        _assertDistributed(before, receiver, address(tokenA), address(tokenB), fees1, 0, "even split");
    }

    /// @dev Isolated receiver mechanics. Odd and one-unit amounts are not reachable through the
    ///      1%-of-1e18 protocol fee, so these are credited by a direct oracle deposit into a
    ///      clone that was itself deployed by the real routed path. This is a receiver-rounding
    ///      boundary, not evidence of organic protocol-fee routing.
    function _deployedCloneWithFees(uint256 topUp1, uint256 topUp2)
        internal
        returns (uint256 swapId, address receiver, Game memory g)
    {
        Proposal memory p;
        Matched memory mt;
        (p, mt, receiver) = _matched();
        g = _gameOf(mt);
        (g,) = _disputeForToken1Fee(g, disputer);

        // deploy and clear the organically accrued fee first
        _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);
        _assertOnlySentinelsRemain(receiver, address(tokenA), address(tokenB), "cleared before the top-up");

        if (topUp1 > 0) {
            tokenA.mint(address(this), topUp1);
            tokenA.approve(address(oracle), type(uint256).max);
            oracle.deposit(address(tokenA), uint128(topUp1), receiver);
        }
        if (topUp2 > 0) {
            tokenB.mint(address(this), topUp2);
            tokenB.approve(address(oracle), type(uint256).max);
            oracle.deposit(address(tokenB), uint128(topUp2), receiver);
        }
        swapId = p.swapId;
    }

    function test_oddFeeGivesTheRemainderToTheMatcher() public {
        (uint256 swapId, address receiver, Game memory g) = _deployedCloneWithFees(7, 0);

        FeeBook memory before = _feeBook(receiver, address(tokenA), address(tokenB));
        (, uint256 fees1,,) = _deployAndDistribute(swapId, swapper, matcher, g, outsider);

        assertEq(fees1, 7, "collected the odd amount");
        assertEq(_spendable(swapper, address(tokenA)) - before.swapper1, 3, "swapper gets the floor");
        assertEq(_spendable(matcher, address(tokenA)) - before.matcher1, 4, "matcher gets the remainder");
        _assertDistributed(before, receiver, address(tokenA), address(tokenB), fees1, 0, "odd split");
    }

    function test_oneUnitFeeGivesNothingToTheSwapper() public {
        (uint256 swapId, address receiver, Game memory g) = _deployedCloneWithFees(1, 0);

        FeeBook memory before = _feeBook(receiver, address(tokenA), address(tokenB));
        (, uint256 fees1,,) = _deployAndDistribute(swapId, swapper, matcher, g, outsider);

        assertEq(fees1, 1, "collected one unit");
        assertEq(_spendable(swapper, address(tokenA)) - before.swapper1, 0, "swapper receives nothing");
        assertEq(_spendable(matcher, address(tokenA)) - before.matcher1, 1, "matcher receives the single unit");
        _assertDistributed(before, receiver, address(tokenA), address(tokenB), fees1, 0, "one unit");
        _assertOnlySentinelsRemain(receiver, address(tokenA), address(tokenB), "one unit");
    }

    function test_bothTokensDrainInOneCallAndASecondCallIsANoOp() public {
        (uint256 swapId, address receiver, Game memory g) = _deployedCloneWithFees(11, 4);

        FeeBook memory before = _feeBook(receiver, address(tokenA), address(tokenB));
        (, uint256 fees1, uint256 fees2, Vm.Log[] memory logs) =
            _deployAndDistribute(swapId, swapper, matcher, g, outsider);

        assertEq(fees1, 11, "token1 drained");
        assertEq(fees2, 4, "token2 drained");
        (uint256 e1, uint256 e2) = _readFeesDistributed(logs, receiver, swapId);
        assertEq(e1, fees1, "event fees1");
        assertEq(e2, fees2, "event fees2");
        _assertDistributed(before, receiver, address(tokenA), address(tokenB), fees1, fees2, "drain both");
        _assertOnlySentinelsRemain(receiver, address(tokenA), address(tokenB), "drain both");

        // a second call with nothing new
        FeeBook memory before2 = _feeBook(receiver, address(tokenA), address(tokenB));
        (, uint256 again1, uint256 again2, Vm.Log[] memory logs2) =
            _deployAndDistribute(swapId, swapper, matcher, g, outsider);

        assertEq(again1, 0, "nothing further in token1");
        assertEq(again2, 0, "nothing further in token2");
        assertFalse(_hasFeesDistributed(logs2, receiver), "no event when both are zero");
        _assertDistributed(before2, receiver, address(tokenA), address(tokenB), 0, 0, "second call");
    }

    function test_feesDistributedIsEmittedByTheCloneNotTheCore() public {
        (Proposal memory p, Matched memory mt, address receiver) = _matched();
        Game memory g = _gameOf(mt);
        (g,) = _disputeForToken1Fee(g, disputer);

        (,,, Vm.Log[] memory logs) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        bool fromClone;
        bool fromCore;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != OpenPuntFeeReceiver.FeesDistributed.selector) continue;
            if (logs[i].emitter == receiver) {
                fromClone = true;
                assertEq(uint256(logs[i].topics[1]), p.swapId, "indexed swap id");
            }
            if (logs[i].emitter == address(punt)) fromCore = true;
        }
        assertTrue(fromClone, "emitted by the clone");
        assertFalse(fromCore, "not emitted by the core");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Direct calls on a deployed clone
    // ══════════════════════════════════════════════════════════════════

    /// @dev Once materialised, the clone is a standalone permissionless sweeper: anyone may call
    ///      `distribute()` on it directly, with no core routing, no oracle preimage and no
    ///      position-state input or lookup. The position remains live, but the clone neither reads
    ///      nor requires it. Proven across a populated call, an
    ///      empty call, and a later repeat.
    function test_directCloneDistributeIsPermissionlessAndRepeatable() public {
        address sweeperA = address(0x7001);
        address sweeperB = address(0x7002);

        (Proposal memory p, Matched memory mt, address receiver) = _matched();
        Game memory g = _gameOf(mt);

        // materialise the clone through the routed path while it is still empty
        (address deployed, uint256 z1, uint256 z2,) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);
        assertEq(deployed, receiver, "clone materialised at the predicted address");
        assertEq(z1, 0, "nothing accrued yet");
        assertEq(z2, 0, "nothing accrued yet");
        assertGt(receiver.code.length, 0, "clone deployed");

        // Accrue genuine fees on both legs through real disputes.
        uint256 fee1;
        uint256 fee2;
        (g, fee1) = _disputeForToken1Fee(g, disputer);
        (g, fee2) = _disputeForToken2Fee(g, disputer2);
        assertEq(_spendable(receiver, address(tokenA)), fee1, "token1 fee waiting");
        assertEq(_spendable(receiver, address(tokenB)), fee2, "token2 fee waiting");

        // ── an unrelated address calls the clone directly ───────────────
        // no core routing, no oracle preimage, no position-state input or lookup
        FeeBook memory before = _feeBook(receiver, address(tokenA), address(tokenB));
        (uint256 out1, uint256 out2, Vm.Log[] memory logs) = _distributeDirect(receiver, sweeperA);

        assertEq(out1, fee1, "direct call returned the token1 fee");
        assertEq(out2, fee2, "direct call returned the token2 fee");

        (uint256 s1, uint256 m1) = _split(fee1);
        (uint256 s2, uint256 m2) = _split(fee2);
        assertEq(_spendable(swapper, address(tokenA)) - before.swapper1, s1, "swapper token1 share");
        assertEq(_spendable(matcher, address(tokenA)) - before.matcher1, m1, "matcher token1 share");
        assertEq(_spendable(swapper, address(tokenB)) - before.swapper2, s2, "swapper token2 share");
        assertEq(_spendable(matcher, address(tokenB)) - before.matcher2, m2, "matcher token2 share");
        assertGe(m1, s1, "any token1 remainder goes to the matcher");
        assertGe(m2, s2, "any token2 remainder goes to the matcher");

        (uint256 e1, uint256 e2) = _readFeesDistributed(logs, receiver, p.swapId);
        assertEq(e1, out1, "clone-emitted event fees1");
        assertEq(e2, out2, "clone-emitted event fees2");

        _assertDistributed(before, receiver, address(tokenA), address(tokenB), out1, out2, "direct call");
        _assertOnlySentinelsRemain(receiver, address(tokenA), address(tokenB), "direct call");
        assertEq(_spendable(sweeperA, address(tokenA)), 0, "the caller receives nothing");
        assertEq(_spendable(sweeperA, address(tokenB)), 0, "the caller receives nothing");

        // ── a second direct call with nothing new ───────────────────────
        FeeBook memory before2 = _feeBook(receiver, address(tokenA), address(tokenB));
        (uint256 again1, uint256 again2, Vm.Log[] memory logs2) = _distributeDirect(receiver, sweeperA);

        assertEq(again1, 0, "no token1 fees left");
        assertEq(again2, 0, "no token2 fees left");
        assertFalse(_hasFeesDistributed(logs2, receiver), "no event when both are zero");
        _assertDistributed(before2, receiver, address(tokenA), address(tokenB), 0, 0, "empty direct call");

        // ── another genuine tranche, swept directly by a different caller ─
        uint256 fee3;
        (g, fee3) = _disputeForToken1Fee(g, disputer);
        assertGt(fee3, 0, "a third genuine fee accrued");

        FeeBook memory before3 = _feeBook(receiver, address(tokenA), address(tokenB));
        (uint256 out3, uint256 out4, Vm.Log[] memory logs3) = _distributeDirect(receiver, sweeperB);

        assertEq(out3, fee3, "repeated direct distribution works");
        assertEq(out4, 0, "nothing on the other leg");
        (uint256 e3,) = _readFeesDistributed(logs3, receiver, p.swapId);
        assertEq(e3, out3, "clone-emitted event on the repeat");
        _assertDistributed(before3, receiver, address(tokenA), address(tokenB), out3, 0, "repeated direct call");
        _assertOnlySentinelsRemain(receiver, address(tokenA), address(tokenB), "repeated direct call");
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. Repeated accrual and repeated distribution
    // ══════════════════════════════════════════════════════════════════

    function test_secondAccrualDistributesOnlyTheNewAmount() public {
        (Proposal memory p, Matched memory mt, address receiver) = _matched();
        Game memory g = _gameOf(mt);

        uint256 fee1;
        (g, fee1) = _disputeForToken1Fee(g, disputer);
        (, uint256 firstOut,,) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);
        assertEq(firstOut, fee1, "first distribution");

        bytes32 codeHashBefore;
        assembly {
            codeHashBefore := extcodehash(receiver)
        }

        uint256 fee2;
        (g, fee2) = _disputeForToken1Fee(g, disputer2);

        FeeBook memory before = _feeBook(receiver, address(tokenA), address(tokenB));
        (address again, uint256 secondOut,,) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(again, receiver, "no second clone: the same address");
        bytes32 codeHashAfter;
        assembly {
            codeHashAfter := extcodehash(receiver)
        }
        assertEq(codeHashAfter, codeHashBefore, "the deployed code is unchanged");

        OpenPuntFeeReceiver clone = OpenPuntFeeReceiver(receiver);
        assertEq(clone.swapId(), p.swapId, "immutable args unchanged");
        assertEq(clone.swapper(), swapper, "immutable args unchanged");
        assertEq(clone.matcher(), matcher, "immutable args unchanged");

        assertEq(secondOut, fee2, "only the newly accrued amount is distributed");
        assertTrue(fee2 != fee1, "and it is a different amount from the first");
        _assertDistributed(before, receiver, address(tokenA), address(tokenB), secondOut, 0, "second distribution");
        _assertOnlySentinelsRemain(receiver, address(tokenA), address(tokenB), "second distribution");
    }

    /// @dev One receiver serves the whole position, not a single report: an active-position
    ///      report commits the same address and its disputes accrue to the same clone.
    function test_theSameReceiverServesLaterOracleGamesOfThePosition() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory p, Matched memory openingMt) = _matchAsset(s, m);
        address receiver = _predictForPosition(p.swapId, openingMt.swap);

        // fees on the opening game, then distribute
        Game memory g = _gameOf(openingMt);
        uint256 openingFee;
        (g, openingFee) = _disputeForToken1Fee(g, disputer);
        (, uint256 out1,,) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);
        assertEq(out1, openingFee, "opening-game fees distributed");

        // settle and execute the opening, using the genuine post-dispute state
        _advanceValidToEligibility(g);
        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, openingMt.swap, g.game, g.helper, 0);
        OpenPuntStorage.MatchedSwap memory active =
            _decodeSingleSwapState(vm.getRecordedLogs(), OpenPuntStorage.PositionOpened.selector, p.swapId);
        assertTrue(active.active, "position opened");
        assertEq(active.feeRecipient, receiver, "the active position keeps the same fee receiver");

        // an active-position report commits the same receiver
        Matched memory reportMt =
            _reportOnPositionWithAmounts(p.swapId, _noDutch(), active, p.preimage, reporter, 0, OA1, OA2);
        assertEq(reportMt.game.protocolFeeRecipient, receiver, "the active report commits the same receiver");

        // accrue on that report and distribute through the same clone
        Game memory g2 = _gameOf(reportMt);
        uint256 activeFee;
        (g2, activeFee) = _disputeForToken1Fee(g2, disputer2);
        assertEq(_spendable(receiver, address(tokenA)), activeFee, "the same clone accrued the new fee");

        FeeBook memory before = _feeBook(receiver, address(tokenA), address(tokenB));
        (address again, uint256 out2,,) = _deployAndDistribute(p.swapId, swapper, matcher, g2, outsider);

        assertEq(again, receiver, "still the same receiver across two different oracle games");
        assertEq(out2, activeFee, "the active-report fee is distributed");
        _assertDistributed(before, receiver, address(tokenA), address(tokenB), out2, 0, "cross-game reuse");
    }

    /// @dev Settlement eligibility measured from the current post-dispute report timestamp,
    ///      with the block cadence kept inside the tolerated band.
    function _advanceValidToEligibility(Game memory g) internal {
        // In block mode, eligibility is a block target measured from the report's block number.
        uint256 targetBlock = uint256(g.game.reportTimestamp) + g.game.settlementTime + 1;
        uint256 hopBlocks = targetBlock - vm.getBlockNumber();
        _advanceTimeAndBlocks(_secondsForBlocks(hopBlocks), hopBlocks);
    }

    // ══════════════════════════════════════════════════════════════════
    //  7. Distribution after terminal position deletion
    // ══════════════════════════════════════════════════════════════════

    /// @dev Fee ownership survives the position because the clone's immutable arguments carry it,
    ///      so no live position hash or oracle preimage is required.
    function test_feesRemainDistributableAfterThePositionIsDeleted() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        s.maturityWindow = 1; // mature by the time the closing report executes, so it truly closes
        (Proposal memory p, Matched memory openingMt) = _matchAsset(s, m);
        address receiver = _predictForPosition(p.swapId, openingMt.swap);

        // accrue on the opening game
        Game memory g = _gameOf(openingMt);
        uint256 fee;
        (g, fee) = _disputeForToken1Fee(g, disputer);
        assertEq(_spendable(receiver, address(tokenA)), fee, "fee accrued and NOT yet swept");

        // open, then close the position for real
        _advanceValidToEligibility(g);
        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, openingMt.swap, g.game, g.helper, 0);
        OpenPuntStorage.MatchedSwap memory active =
            _decodeSingleSwapState(vm.getRecordedLogs(), OpenPuntStorage.PositionOpened.selector, p.swapId);

        Matched memory closing =
            _reportOnPositionWithAmounts(p.swapId, _noDutch(), active, p.preimage, reporter, 0, OA1, OA2);
        _advanceTimeAndBlocks(_secondsForBlocks(m.settlementTime) + 2, (_secondsForBlocks(m.settlementTime) + 2) / 2);
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, closing.game, closing.helper, 0);

        assertEq(punt.swaps(p.swapId), bytes32(0), "the position is terminal");
        assertEq(receiver.code.length, 0, "the receiver was never deployed");

        FeeBook memory before = _feeBook(receiver, address(tokenA), address(tokenB));
        (address deployed, uint256 fees1, uint256 fees2,) =
            _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(deployed, receiver, "deployed permissionlessly after deletion");
        assertEq(fees1, fee, "all previously accrued fees distributed");
        assertEq(fees2, 0, "nothing in token2");
        _assertDistributed(before, receiver, address(tokenA), address(tokenB), fees1, fees2, "post-deletion sweep");
        _assertOnlySentinelsRemain(receiver, address(tokenA), address(tokenB), "post-deletion sweep");

        // idempotent
        FeeBook memory before2 = _feeBook(receiver, address(tokenA), address(tokenB));
        (, uint256 again1, uint256 again2,) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);
        assertEq(again1, 0, "repeat is a no-op");
        assertEq(again2, 0, "repeat is a no-op");
        _assertDistributed(before2, receiver, address(tokenA), address(tokenB), 0, 0, "idempotent repeat");
    }

    // ══════════════════════════════════════════════════════════════════
    //  10. uint128 per-call tranche ceiling
    // ══════════════════════════════════════════════════════════════════

    /// @dev Isolated capacity test rather than organic accrual. Two uint128.max tranches are credited
    ///      by direct oracle deposits into a clone that the real routed path deployed. The
    ///      protocol-fee arithmetic cannot reach this magnitude; this isolates the receiver's
    ///      per-call ceiling.
    function test_perCallCeilingIsUint128Max() public {
        (Proposal memory p, Matched memory mt, address receiver) = _matched();
        Game memory g = _gameOf(mt);
        (g,) = _disputeForToken1Fee(g, disputer);
        _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);
        assertGt(receiver.code.length, 0, "clone deployed by the real path");

        uint256 max = type(uint128).max;
        tokenA.mint(address(this), 2 * max);
        tokenA.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(tokenA), uint128(max), receiver);
        oracle.deposit(address(tokenA), uint128(max), receiver);
        assertEq(_spendable(receiver, address(tokenA)), 2 * max, "two full tranches credited");

        // first call takes exactly one tranche
        FeeBook memory b1 = _feeBook(receiver, address(tokenA), address(tokenB));
        (, uint256 first,,) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);
        assertEq(first, max, "capped at uint128.max");
        (uint256 s1, uint256 m1) = _split(max);
        assertEq(_spendable(swapper, address(tokenA)) - b1.swapper1, s1, "odd tranche: swapper floor");
        assertEq(_spendable(matcher, address(tokenA)) - b1.matcher1, m1, "odd tranche: matcher remainder");
        assertEq(m1 - s1, 1, "the remainder really is the odd unit");
        _assertDistributed(b1, receiver, address(tokenA), address(tokenB), first, 0, "first tranche");
        assertEq(_spendable(receiver, address(tokenA)), max, "exactly one tranche left");

        // second call takes the rest
        FeeBook memory b2 = _feeBook(receiver, address(tokenA), address(tokenB));
        (, uint256 second,,) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);
        assertEq(second, max, "second full tranche");
        _assertDistributed(b2, receiver, address(tokenA), address(tokenB), second, 0, "second tranche");
        assertEq(oracle.tokenHolder(receiver, address(tokenA)), 1, "sentinel preserved");

        // third call is empty: zero returns, no event, and nothing moves
        FeeBook memory b3 = _feeBook(receiver, address(tokenA), address(tokenB));
        (, uint256 third, uint256 third2, Vm.Log[] memory logs3) =
            _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(third, 0, "nothing left in token1");
        assertEq(third2, 0, "nothing left in token2");
        assertFalse(_hasFeesDistributed(logs3, receiver), "no event on the empty call");
        _assertDistributed(b3, receiver, address(tokenA), address(tokenB), 0, 0, "empty third call");
    }
}
