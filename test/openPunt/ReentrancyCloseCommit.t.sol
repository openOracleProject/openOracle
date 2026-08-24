// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ReentrancyBase.t.sol";

/**
 * @notice `close()`'s fund-then-compare-and-commit boundary under unbounded callbacks.
 *
 * @dev `close()` validates and canonicalizes the Dutch, funds the ETH compensation and collateral
 *      reward, then revalidates the stable position hash, report sidecar, close request and stored
 *      auction before publishing the auction.
 *
 *      This is not a global reentrancy guard: callbacks may still transition unrelated swaps, and
 *      those transitions must survive. They may not act
 *      on a half-funded Dutch, or change the target position underneath the outer `close()`.
 *
 *      Every callback here runs with all remaining gas, through the token's real `transferFrom`.
 */
contract ReentrancyCloseCommitTest is ReentrancyBase {
    function setUp() public {
        _setUpReentrancy();
    }

    // ── fixtures ────────────────────────────────────────────────────────

    struct HookPos {
        uint256 swapId;
        OpenPuntStorage.MatchedSwap active;
        OpenPuntStorage.MatcherPreimage preimage;
    }

    function _openHookPosition(ReentrantActor a) internal returns (HookPos memory p) {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _hookCfg();
        Proposal memory pr = _actorPropose(a, s, m);
        Matched memory mt = _matchSwapWith(pr, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        p.active = _executeOpening(mt, executor);
        p.swapId = pr.swapId;
        p.preimage = pr.preimage;
        require(p.active.active && punt.swapIdToReportId(p.swapId) == 0, "fixture: idle active position");
    }

    function _closeCall(HookPos memory p, OpenPuntStorage.CloseDutch memory input)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(punt.close, (p.swapId, input, p.active, false, _emptyPermit2(), CLOSE_COMP));
    }

    struct CommitSnap {
        bytes32 swapHash;
        uint256 liveReportId;
        bytes32 dutchHash;
        uint128 pendingComp;
        bool intent;
        uint256 nextSwapId;
        uint256 nextReportId;
        uint256 coreHookInternal;
        uint256 coreEthInternal;
        uint256 actorHookExt;
        uint256 actorHookInternal;
        uint256 actorEthInternal;
        uint256 oracleHookExt;
        uint256 permitCalls;
        uint128 hbReportId;
        uint48 hbTimestamp;
        uint256 reporterTok1Internal;
        uint256 reporterTok2Internal;
        bytes32 prospectiveGameHash;
    }

    function _snap(uint256 swapId) internal view returns (CommitSnap memory z) {
        z.swapHash = punt.swaps(swapId);
        z.liveReportId = punt.swapIdToReportId(swapId);
        z.dutchHash = _storedDutchState(swapId);
        (z.pendingComp,, z.intent) = _closeState(swapId);
        z.nextSwapId = punt.nextSwapId();
        z.nextReportId = oracle.nextReportId();
        z.coreHookInternal = _spendable(address(punt), address(hookToken));
        z.coreEthInternal = _spendable(address(punt), address(0));
        z.actorHookExt = hookToken.balanceOf(address(actor));
        z.actorHookInternal = _spendable(address(actor), address(hookToken));
        z.actorEthInternal = _spendable(address(actor), address(0));
        z.oracleHookExt = hookToken.balanceOf(address(oracle));
        z.permitCalls = _permit2().callCount();
        (z.hbReportId, z.hbTimestamp) = punt.liquidationHeartbeats(swapId);
        // the actor is the reporter in the same-swap report test, so its oracle legs are the ones
        // a nested report would move
        z.reporterTok1Internal = _spendable(address(actor), address(tokenA));
        z.reporterTok2Internal = _spendable(address(actor), address(tokenB));
        z.prospectiveGameHash = oracle.oracleGame(oracle.nextReportId());
    }

    function _assertSnapEqual(CommitSnap memory a, CommitSnap memory b, string memory w) internal pure {
        require(a.swapHash == b.swapHash, string.concat(w, ": swap hash"));
        require(a.liveReportId == b.liveReportId, string.concat(w, ": live report id"));
        require(a.dutchHash == b.dutchHash, string.concat(w, ": Dutch hash"));
        require(a.pendingComp == b.pendingComp, string.concat(w, ": pending execution comp"));
        require(a.intent == b.intent, string.concat(w, ": close intent"));
        require(a.nextSwapId == b.nextSwapId, string.concat(w, ": nextSwapId"));
        require(a.nextReportId == b.nextReportId, string.concat(w, ": oracle nextReportId"));
        require(a.coreHookInternal == b.coreHookInternal, string.concat(w, ": core internal collateral"));
        require(a.coreEthInternal == b.coreEthInternal, string.concat(w, ": core internal ETH"));
        require(a.actorHookExt == b.actorHookExt, string.concat(w, ": actor external collateral"));
        require(a.actorHookInternal == b.actorHookInternal, string.concat(w, ": actor internal collateral"));
        require(a.actorEthInternal == b.actorEthInternal, string.concat(w, ": actor internal ETH"));
        require(a.oracleHookExt == b.oracleHookExt, string.concat(w, ": oracle custody"));
        require(a.permitCalls == b.permitCalls, string.concat(w, ": Permit2 recorder state"));
        require(a.hbReportId == b.hbReportId, string.concat(w, ": heartbeat report id"));
        require(a.hbTimestamp == b.hbTimestamp, string.concat(w, ": heartbeat timestamp"));
        require(a.reporterTok1Internal == b.reporterTok1Internal, string.concat(w, ": reporter token1 leg"));
        require(a.reporterTok2Internal == b.reporterTok2Internal, string.concat(w, ": reporter token2 leg"));
        require(a.prospectiveGameHash == b.prospectiveGameHash, string.concat(w, ": prospective oracle game hash"));
    }

    // ══════════════════════════════════════════════════════════════════
    //  1. The auction is not live during funding
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice During the funding callback, nothing about the target position has been published.
     *
     * @dev Observed directly from inside the window rather than inferred: the hook calls a view
     *      observer that reads the position hash, stored auction and close request at that instant.
     */
    function test_noAuctionStateIsVisibleDuringFunding() public {
        HookPos memory p = _openHookPosition(actor);
        CommitSnap memory before = _snap(p.swapId);
        OpenPuntStorage.CloseDutch memory input = _dutchInput();

        observer.reset();
        hookToken.armHook(address(observer), abi.encodeCall(observer.observe, (address(punt), p.swapId)));
        actor.exec(address(punt), CLOSE_COMP, _closeCall(p, input));
        hookToken.disarmHook();

        assertTrue(observer.observed(), "the funding callback genuinely ran");
        assertEq(observer.dutchHash(), bytes32(0), "the stored auction was still empty during funding");
        assertEq(observer.pendingComp(), before.pendingComp, "auction compensation was still unchanged");
        assertEq(observer.intent(), before.intent, "the close request was still unchanged");
        assertEq(observer.swapHash(), before.swapHash, "the position hash was unchanged during funding");
    }

    /**
     * @notice A reentrant cancellation sees the stable active hash but no committed request yet,
     *         so it reverts `NothingToWithdraw` and the outer close publishes normally.
     */
    function test_reentrantCancelDuringFundingHasNothingToWithdrawAndOuterStillPublishes() public {
        HookPos memory p = _openHookPosition(actor);
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        OpenPuntStorage.CloseDutch memory canonical =
            _canonicalFor(input, p.swapId, address(hookToken), address(actor), uint48(vm.getBlockTimestamp()));

        uint256 actorExtBefore = hookToken.balanceOf(address(actor));
        uint256 coreInternalBefore = _spendable(address(punt), address(hookToken));
        uint256 coreOracleEthBefore = _spendable(address(punt), address(0));

        hookToken.armHook(
            address(actor),
            abi.encodeCall(
                actor.exec, (address(punt), 0, abi.encodeCall(punt.cancelCloseAuction, (p.swapId, p.active)))
            )
        );

        vm.recordLogs();
        actor.exec(address(punt), CLOSE_COMP, _closeCall(p, input));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        hookToken.disarmHook();

        assertEq(hookToken.hookCount(), 1, "the funding callback ran");
        assertFalse(hookToken.lastHookOk(), "the reentrant cancellation failed");
        assertEq(hookToken.lastHookSelector(), PuntErrors.NothingToWithdraw.selector, "exactly NothingToWithdraw");

        // the outer close published a fully funded auction
        assertEq(_storedAuctionHash(p.swapId, p.active), keccak256(abi.encode(canonical)), "final stored Dutch hash");
        (uint128 pending,, bool intent) = _closeState(p.swapId);
        assertEq(pending, CLOSE_COMP, "pending execution compensation published");
        assertTrue(intent, "close request published");

        // exact funding, in each ledger separately
        assertEq(hookToken.balanceOf(address(actor)), actorExtBefore - input.maxReward, "reward paid exactly once");
        assertEq(
            _spendable(address(punt), address(hookToken)),
            coreInternalBefore + input.maxReward,
            "core credited exactly the reward"
        );
        assertEq(hookToken.balanceOf(address(punt)), 0, "no stranded raw collateral on the core");
        assertEq(
            _spendable(address(punt), address(0)),
            coreOracleEthBefore + CLOSE_COMP,
            "the core's oracle ETH rose by exactly the execution compensation"
        );
        _assertModuleClean(address(tokenA), address(tokenB), "reentrant cancel during funding");

        // Exactly one CloseAuctionStarted, asserted on the indexed hash topic and decoded
        // compensation, not merely on a rehash of the decoded struct
        (bytes32 topicHash, OpenPuntStorage.CloseDutch memory emitted, uint128 emittedComp) =
            _readAuctionStarted(logs, p.swapId);
        assertEq(topicHash, _storedAuctionHash(p.swapId, p.active), "the indexed dutchHash topic reconstructs storage");
        assertEq(topicHash, keccak256(abi.encode(canonical)), "and equals the independently derived canonical hash");
        assertEq(keccak256(abi.encode(emitted)), topicHash, "the emitted struct reconstructs that same topic");
        assertEq(emittedComp, CLOSE_COMP, "the emitted execution compensation");
        assertEq(_countLogs(logs, OpenPuntStorage.CloseAuctionStarted.selector), 1, "exactly one auction started");
        assertEq(_countLogs(logs, OpenPuntStorage.CloseAuctionCancelled.selector), 0, "no surviving cancellation event");
    }

    /// @dev Reads the indexed dutchHash topic and decoded compensation, so the assertions do
    ///      not merely re-hash the struct the event itself supplied.
    function _readAuctionStarted(Vm.Log[] memory logs, uint256 swapId)
        internal
        view
        returns (bytes32 dutchHashTopic, OpenPuntStorage.CloseDutch memory d, uint128 comp)
    {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.CloseAuctionStarted.selector, swapId);
        require(l.topics.length == 3, "CloseAuctionStarted: expected two indexed fields");
        dutchHashTopic = l.topics[2];
        (d, comp) = abi.decode(l.data, (OpenPuntStorage.CloseDutch, uint128));
    }

    function _countLogs(Vm.Log[] memory logs, bytes32 topic0) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(punt) && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) n++;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  2. The pooled flash-liquidity path is gone
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice The former construction — cancel mid-funding to be refunded `maxReward` out of
     *         pooled collateral, before paying it in — no longer works at all.
     *
     * @dev The actor is stripped of its external collateral immediately before `close()`, so the
     *      only way the outer pull could succeed is if the inner cancellation had first handed it
     *      other positions' funds. It cannot: there is no auction to cancel, so the inner call
     *      reverts `WrongHash` and the outer pull then fails for insufficient balance. The whole
     *      transaction rolls back.
     */
    function test_pooledFlashLiquidityPathIsGone() public {
        HookPos memory pA = _openHookPosition(actor2); // an unrelated position pooling collateral
        HookPos memory pB = _openHookPosition(actor);
        assertGt(_spendable(address(punt), address(hookToken)), 0, "fixture: the core pools collateral");

        // strip the actor's external collateral
        uint256 bal = hookToken.balanceOf(address(actor));
        actor.sendToken(address(hookToken), address(0xDEAD), bal);
        assertEq(hookToken.balanceOf(address(actor)), 0, "fixture: no external collateral");

        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        OpenPuntStorage.CloseDutch memory canonical =
            _canonicalFor(input, pB.swapId, address(hookToken), address(actor), uint48(vm.getBlockTimestamp()));

        CommitSnap memory beforeB = _snap(pB.swapId);
        CommitSnap memory beforeA = _snap(pA.swapId);
        hookToken.resetHook();

        hookToken.armHook(
            address(actor),
            abi.encodeCall(
                actor.exec, (address(punt), 0, abi.encodeCall(punt.cancelCloseAuction, (pB.swapId, pB.active)))
            )
        );

        vm.recordLogs();
        // the inner cancel finds no auction, so the outer pull is what fails - and it fails for
        // insufficient balance, surfacing as the recorder's own transfer failure
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "RecordingPermit2: transferFrom failed"));
        actor.exec(address(punt), CLOSE_COMP, _closeCall(pB, input));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        hookToken.disarmHook();

        // atomic rollback of everything, including the hook's own observations
        _assertSnapEqual(_snap(pB.swapId), beforeB, "target position rollback");
        _assertSnapEqual(_snap(pA.swapId), beforeA, "unrelated position rollback");
        assertEq(hookToken.hookCount(), 0, "the hook's own bookkeeping rolled back with the transaction");
        assertEq(_countLogs(logs, OpenPuntStorage.CloseAuctionStarted.selector), 0, "no auction event survived");
        assertEq(_countLogs(logs, OpenPuntStorage.CloseAuctionCancelled.selector), 0, "no cancellation event survived");
        _assertModuleClean(address(tokenA), address(tokenB), "flash liquidity rollback");

        // funded normally, the identical close succeeds
        hookToken.mint(address(actor), bal);
        actor.exec(address(punt), CLOSE_COMP, _closeCall(pB, input));
        assertEq(
            _storedAuctionHash(pB.swapId, pB.active),
            keccak256(abi.encode(canonical)),
            "the identical close now succeeds"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. Same-swap report during funding
    // ══════════════════════════════════════════════════════════════════

    /// @dev A hook-token callback can start a report before close() commits. The post-funding
    ///      sidecar check rejects the outer close, and the whole nested report rolls back with it.
    function test_sameSwapReportDuringFundingRevertsTheOuterCloseAtomically() public {
        HookPos memory p = _openHookPosition(actor);
        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);

        CommitSnap memory before = _snap(p.swapId);
        OpenPuntStorage.CloseDutch memory input = _dutchInput();

        // a lawful no-Dutch (zero sentinel) report, since no auction is published yet
        bytes memory reportCall = abi.encodeCall(
            puntLifecycle.report,
            (p.swapId, bytes32(0), p.active, p.preimage, _noTiming(), address(actor), A1, OA2, REPORT_EXEC_COMP)
        );
        hookToken.resetHook();
        hookToken.armHook(address(actor), abi.encodeCall(actor.exec, (address(punt), 0, reportCall)));

        vm.expectRevert(PuntErrors.WrongHash.selector);
        actor.exec(address(punt), CLOSE_COMP, _closeCall(p, input));
        hookToken.disarmHook();

        _assertSnapEqual(_snap(p.swapId), before, "same-swap report rollback");
        assertEq(hookToken.hookCount(), 0, "callback bookkeeping rolled back with the transaction");
        _assertModuleClean(address(tokenA), address(tokenB), "same-swap report rollback");
    }

    /**
     * @notice A direct report changes the report sidecar and oracle accounting without changing
     *         the active position hash.
     */
    function test_controlTheNestedReportSucceedsAndMovesTheReportSidecarAndFundingState() public {
        HookPos memory p = _openHookPosition(actor);
        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);

        CommitSnap memory before = _snap(p.swapId);
        uint256 prospectiveId = oracle.nextReportId();

        actor.exec(
            address(punt),
            0,
            abi.encodeCall(
                puntLifecycle.report,
                (p.swapId, bytes32(0), p.active, p.preimage, _noTiming(), address(actor), A1, OA2, REPORT_EXEC_COMP)
            )
        );

        CommitSnap memory after_ = _snap(p.swapId);

        assertEq(after_.nextReportId, before.nextReportId + 1, "a report id was allocated");
        assertEq(after_.swapHash, before.swapHash, "the active position hash remained stable");
        assertEq(after_.liveReportId, prospectiveId, "the report id was stored in the sidecar");
        assertLt(after_.reporterTok1Internal, before.reporterTok1Internal, "the reporter's token1 leg was consumed");
        assertLt(after_.reporterTok2Internal, before.reporterTok2Internal, "the reporter's token2 leg was consumed");
        assertTrue(oracle.oracleGame(prospectiveId) != bytes32(0), "the oracle game hash was populated");
        assertEq(before.prospectiveGameHash, bytes32(0), "and it was empty beforehand");
        assertEq(punt.executionGasComp(prospectiveId), REPORT_EXEC_COMP, "execution compensation was recorded");
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. Same-swap nested auction
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice A separately funded nested `close()` on the same position commits first, and the
     *         outer close then observes the nonzero Dutch slot and reverts — rolling the nested
     *         auction and both funding operations back with it.
     */
    function test_sameSwapNestedAuctionRevertsTheOuterCloseAtomically() public {
        HookPos memory p = _openHookPosition(actor);
        CommitSnap memory before = _snap(p.swapId);

        OpenPuntStorage.CloseDutch memory outerInput = _dutchInput();
        OpenPuntStorage.CloseDutch memory nestedInput = _dutchInput();
        nestedInput.startingReward = nestedInput.startingReward + 1; // a distinguishable auction

        // the nested close funds from the oracle ledger, so it does not recurse into the hook
        vm.startPrank(address(actor));
        hookToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(hookToken), 200_000e18, address(actor));
        oracle.approveInternal(address(punt), address(hookToken), type(uint256).max);
        oracle.deposit{value: 1 ether}(address(0), 1 ether, address(actor));
        // the internal ETH allowance to the core is already granted by _fundAsReporter
        vm.stopPrank();

        CommitSnap memory before2 = _snap(p.swapId);
        hookToken.resetHook();
        hookToken.armHook(
            address(actor),
            abi.encodeCall(
                actor.exec,
                (
                    address(punt),
                    0,
                    abi.encodeCall(punt.close, (p.swapId, nestedInput, p.active, true, _emptyPermit2(), CLOSE_COMP))
                )
            )
        );

        vm.recordLogs();
        vm.expectRevert(PuntErrors.WrongHash.selector);
        actor.exec(address(punt), CLOSE_COMP, _closeCall(p, outerInput));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        hookToken.disarmHook();

        _assertSnapEqual(_snap(p.swapId), before2, "nested auction rollback");
        assertEq(_storedDutchState(p.swapId), bytes32(0), "no auction survives");
        // As above: the log recorder captures events emitted inside frames that later revert, so
        // the nested CloseAuctionStarted appears in `logs` even though the transaction reverted and
        // nothing was emitted on chain. The state reconciliation is what proves the rollback.
        assertGt(
            _countLogs(logs, OpenPuntStorage.CloseAuctionStarted.selector),
            0,
            "the nested auction really did commit first, before the outer comparison rejected it"
        );
        _assertModuleClean(address(tokenA), address(tokenB), "nested auction rollback");
        before;
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. Unrelated-swap composability is preserved
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice The central reason this is compare-and-commit rather than a global guard: a valid
     *         owner-authorized transition on an unrelated swap must succeed during funding, and
     *         both it and the outer close must survive.
     *
     * @dev Compared field-by-field against the sequential reference path "cancel A, then close B".
     */
    function test_unrelatedSwapTransitionDuringFundingSurvivesAndMatchesTheSequentialPath() public {
        // A: an unmatched proposal owned by the actor, cancellable by its owner
        (OpenPuntStorage.ProposedSwap memory sa, OpenPuntStorage.MatcherPreimage memory ma) = _hookCfg();
        Proposal memory pa = _actorPropose(actor, sa, ma);
        HookPos memory pB = _openHookPosition(actor);
        OpenPuntStorage.CloseDutch memory input = _dutchInput();

        bytes memory cancelA = abi.encodeCall(punt.cancelSwapOpen, (pa.swapId, pa.swap, pa.preimage));

        uint256 snapId = vm.snapshotState();

        // ── reference: sequential ────────────────────────────────────────
        actor.exec(address(punt), 0, cancelA);
        actor.exec(address(punt), CLOSE_COMP, _closeCall(pB, input));
        CommitSnap memory refB = _snap(pB.swapId);
        CommitSnap memory refA = _snap(pa.swapId);
        uint256 refCoreEth = address(punt).balance;

        vm.revertToState(snapId);

        // ── composed: A cancelled from inside B's funding callback ───────
        hookToken.resetHook();
        hookToken.armHook(address(actor), abi.encodeCall(actor.exec, (address(punt), 0, cancelA)));
        actor.exec(address(punt), CLOSE_COMP, _closeCall(pB, input));
        hookToken.disarmHook();

        assertEq(hookToken.hookCount(), 1, "the funding callback ran");
        assertTrue(hookToken.lastHookOk(), "the unrelated transition SUCCEEDED");
        assertEq(punt.swaps(pa.swapId), bytes32(0), "A's proposal really was cancelled and stayed cancelled");
        assertTrue(_storedDutchState(pB.swapId) != bytes32(0), "and B's auction was still published");

        _assertSnapEqual(_snap(pB.swapId), refB, "B matches the sequential reference");
        _assertSnapEqual(_snap(pa.swapId), refA, "A matches the sequential reference");
        assertEq(address(punt).balance, refCoreEth, "core raw ETH matches the sequential reference");
        _assertModuleClean(address(tokenA), address(tokenB), "unrelated composition");
    }

    /// @dev The same for cancellation of an unrelated position's live auction during B's funding.
    function test_unrelatedAuctionCancellationDuringFundingSurvives() public {
        HookPos memory pA = _openHookPosition(actor);
        HookPos memory pB = _openHookPosition(actor);

        OpenPuntStorage.CloseDutch memory inputA = _dutchInput();
        actor.exec(address(punt), CLOSE_COMP, _closeCall(pA, inputA));
        OpenPuntStorage.CloseDutch memory canonicalA =
            _canonicalFor(inputA, pA.swapId, address(hookToken), address(actor), uint48(vm.getBlockTimestamp()));
        assertEq(
            _storedAuctionHash(pA.swapId, pA.active), keccak256(abi.encode(canonicalA)), "fixture: A has a live auction"
        );

        OpenPuntStorage.CloseDutch memory inputB = _dutchInput();
        hookToken.resetHook();
        hookToken.armHook(
            address(actor),
            abi.encodeCall(
                actor.exec, (address(punt), 0, abi.encodeCall(punt.cancelCloseAuction, (pA.swapId, pA.active)))
            )
        );
        actor.exec(address(punt), CLOSE_COMP, _closeCall(pB, inputB));
        hookToken.disarmHook();

        assertTrue(hookToken.lastHookOk(), "A's auction was cancelled from inside B's funding");
        assertEq(_storedDutchState(pA.swapId), bytes32(0), "and stayed cancelled");
        assertTrue(_storedDutchState(pB.swapId) != bytes32(0), "while B's auction was published");
        (uint128 pendingA,,) = _closeState(pA.swapId);
        assertEq(pendingA, 0, "A's pending compensation was refunded exactly once");
        (uint128 pendingB,,) = _closeState(pB.swapId);
        assertEq(pendingB, CLOSE_COMP, "B's pending compensation is its own");
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. Heartbeat composition on the same swap
    // ══════════════════════════════════════════════════════════════════

    /// @dev `close()` does not write heartbeat state, and a heartbeat does not change
    ///      `swaps[swapId]`, so this is valid composition rather than a conflict.
    function test_sameSwapHeartbeatDuringFundingIsValidComposition() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _hookCfg();
        s.liquidationHeartbeatMin = 30;
        s.liquidationHeartbeatMax = 300;
        Proposal memory pr = _actorPropose(actor, s, m);
        Matched memory mt = _matchSwapWith(pr, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);

        HookPos memory p = HookPos({swapId: pr.swapId, active: active, preimage: pr.preimage});
        OpenPuntStorage.CloseDutch memory input = _dutchInput();

        hookToken.resetHook();
        hookToken.armHook(
            address(actor),
            abi.encodeCall(
                actor.exec, (address(punt), 0, abi.encodeCall(punt.liquidationHeartbeat, (p.swapId, active)))
            )
        );
        actor.exec(address(punt), CLOSE_COMP, _closeCall(p, input));
        hookToken.disarmHook();

        assertTrue(hookToken.lastHookOk(), "the heartbeat succeeded during funding");
        (uint128 hbId, uint48 hbTs) = punt.liquidationHeartbeats(p.swapId);
        assertEq(hbId, 0, "unbound heartbeat window");
        assertEq(hbTs, uint48(vm.getBlockTimestamp()), "and it survived the outer close");
        assertTrue(_storedDutchState(p.swapId) != bytes32(0), "while the auction was still published");
    }
}
