// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ReentrancyBase.t.sol";

/**
 * @notice The remaining ERC20 refund and payout callback surfaces: `cancelCloseAuction()`,
 *         a claimed Dutch remainder in `report()`, `bailOut()` and the terminal `execute()` payout.
 *
 * @dev All four deliver collateral through `oracle.pushOrCredit`, whose ERC20 branch forwards all
 *      remaining gas. With the hook token as position collateral these are genuine unbounded
 *      callbacks at exactly the production ordering boundary, so no conclusion here rests on a
 *      payload being too expensive.
 *
 *      They are kept separate from `cancelSwapOpen` because the equivalence rule only permits
 *      collapsing rows that share both the external-call site and the state-ordering path. The
 *      terminal `execute` payout additionally runs under a delegatecall from the core fallback.
 */
contract ReentrancyRefundSurfacesTest is ReentrancyBase {
    bytes4 internal constant REENTRANT_CALL = 0x3ee5aeb5;

    function setUp() public {
        _setUpReentrancy();
    }

    struct Live {
        uint256 swapId;
        OpenPuntStorage.MatchedSwap active;
        OpenPuntStorage.MatcherPreimage preimage;
        OpenPuntStorage.CloseDutch dutch;
        bytes32 dutchHash;
    }

    function _openHook(ReentrantActor a)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, OpenPuntStorage.MatcherPreimage memory pre)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _hookCfg();
        s.maturityWindow = 1; // mature by the closing execution
        Proposal memory p = _actorPropose(a, s, m);
        Matched memory mt = _matchSwapWith(p, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        active = _executeOpening(mt, executor);
        swapId = p.swapId;
        pre = p.preimage;
    }

    function _withAuction(ReentrantActor a) internal returns (Live memory l) {
        (l.swapId, l.active, l.preimage) = _openHook(a);
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        a.exec(
            address(punt),
            CLOSE_COMP,
            abi.encodeCall(punt.close, (l.swapId, input, l.active, false, _emptyPermit2(), CLOSE_COMP))
        );
        l.dutch = _canonicalFor(input, l.swapId, address(hookToken), address(a), uint48(vm.getBlockTimestamp()));
        l.dutchHash = keccak256(abi.encode(l.dutch));
        require(_storedAuctionHash(l.swapId, l.active) == l.dutchHash, "fixture: live auction");
    }

    function _armCancel(ReentrantActor a, Live memory l, bytes memory payload) internal {
        hookToken.resetHook();
        hookToken.armHook(address(a), abi.encodeCall(a.exec, (address(punt), 0, payload)));
        a.exec(address(punt), 0, abi.encodeCall(punt.cancelCloseAuction, (l.swapId, l.active)));
        hookToken.disarmHook();
        require(hookToken.hookCount() == 1, "the Dutch refund did not call back");
    }

    function _assertHookReverted(bytes4 expected, string memory what) internal view {
        require(!hookToken.lastHookOk(), string.concat(what, ": the reentrant call SUCCEEDED"));
        require(hookToken.lastHookSelector() == expected, string.concat(what, ": wrong inner selector"));
    }

    // ══════════════════════════════════════════════════════════════════
    //  cancelCloseAuction: deletion precedes delivery
    // ══════════════════════════════════════════════════════════════════

    function test_callbackCannotReCancelTheDeletedAuction() public {
        Live memory l = _withAuction(actor);
        _armCancel(actor, l, abi.encodeCall(punt.cancelCloseAuction, (l.swapId, l.active)));

        _assertHookReverted(PuntErrors.NothingToWithdraw.selector, "inner cancelCloseAuction");
        assertEq(_storedDutchState(l.swapId), bytes32(0), "the auction is deleted exactly once");
        (uint128 pending,,) = _closeState(l.swapId);
        assertEq(pending, 0, "pending execution compensation consumed exactly once");
        assertTrue(punt.swaps(l.swapId) != bytes32(0), "the position itself is still live");
    }

    /// @dev Reward and compensation are returned exactly once, reconciled per ledger.
    function test_rewardAndCompensationAreReturnedExactlyOnce() public {
        Live memory l = _withAuction(actor);
        uint256 extBefore = hookToken.balanceOf(address(actor));
        uint256 intBefore = _spendable(address(actor), address(hookToken));
        uint256 rawEthBefore = address(actor).balance;
        uint256 oracleEthBefore = _spendable(address(actor), address(0));
        uint256 tempBefore = punt.tempHolding(address(actor));

        _armCancel(actor, l, abi.encodeCall(punt.cancelCloseAuction, (l.swapId, l.active)));

        uint256 collatBack = (hookToken.balanceOf(address(actor)) - extBefore)
            + (_spendable(address(actor), address(hookToken)) - intBefore);
        assertEq(collatBack, l.dutch.maxReward, "the reward returned exactly once");

        uint256 ethBack = (address(actor).balance - rawEthBefore)
            + (_spendable(address(actor), address(0)) - oracleEthBefore) + (punt.tempHolding(address(actor)) - tempBefore);
        assertEq(ethBack, CLOSE_COMP, "the compensation returned exactly once");
        _assertModuleClean(address(tokenA), address(tokenB), "cancelCloseAuction delivery");
    }

    function test_callbackCannotHeartbeatDuringCancellation() public {
        Live memory l = _withAuction(actor);
        _armCancel(actor, l, abi.encodeCall(punt.liquidationHeartbeat, (l.swapId, l.active)));

        // the position has no heartbeat mode enabled, so its own validation refuses
        assertFalse(hookToken.lastHookOk(), "the heartbeat did not take");
        (uint128 hbId, uint48 hbTs) = punt.liquidationHeartbeats(l.swapId);
        assertEq(hbId, 0, "no heartbeat bound");
        assertEq(hbTs, 0, "no heartbeat bound");
    }

    function test_callbackCannotCancelAnotherPositionsAuction() public {
        Live memory mine = _withAuction(actor);
        Live memory theirs = _withAuction(actor2);
        uint256 otherExt = hookToken.balanceOf(address(actor2));

        _armCancel(actor, mine, abi.encodeCall(punt.cancelCloseAuction, (theirs.swapId, theirs.active)));

        _assertHookReverted(PuntErrors.NotSwapper.selector, "inner cancel of another auction");
        assertEq(_storedAuctionHash(theirs.swapId, theirs.active), theirs.dutchHash, "the other auction is intact");
        assertEq(hookToken.balanceOf(address(actor2)), otherExt, "and its owner received nothing");
    }

    /**
     * @notice A guarded function reached from this unguarded outer call is stopped by its own hash
     *         gate, not by the reentrancy guard.
     *
     * @dev `cancelCloseAuction` carries no `nonReentrant`, so the guard was never entered and
     *      `bailOut`'s modifier passes. What actually refuses the call is `bailOut`'s hash check
     *      against the still-live position. The exact selector is asserted so this cannot be
     *      misread as guard coverage.
     */
    function test_callbackIntoAGuardedFunctionIsStoppedByItsHashGateNotTheGuard() public {
        Live memory l = _withAuction(actor);
        OpenPuntStorage.MatchedSwap memory empty;

        _armCancel(actor, l, abi.encodeCall(punt.bailOut, (l.swapId, empty)));

        _assertHookReverted(PuntErrors.WrongHash.selector, "inner bailOut");
        assertTrue(punt.swaps(l.swapId) != bytes32(0), "the position survived");
    }

    /// @dev An unrelated transition from the same surface succeeds and survives.
    function test_callbackMayCancelAnUnrelatedAuctionOfItsOwn() public {
        Live memory a1 = _withAuction(actor);
        Live memory a2 = _withAuction(actor);

        _armCancel(actor, a1, abi.encodeCall(punt.cancelCloseAuction, (a2.swapId, a2.active)));

        assertTrue(hookToken.lastHookOk(), "the unrelated cancellation succeeded");
        assertEq(_storedDutchState(a1.swapId), bytes32(0), "the outer auction was cancelled");
        assertEq(_storedDutchState(a2.swapId), bytes32(0), "and so was the nested one");
        (uint128 p1,,) = _closeState(a1.swapId);
        (uint128 p2,,) = _closeState(a2.swapId);
        assertEq(p1, 0, "both compensations consumed");
        assertEq(p2, 0, "both compensations consumed");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Terminal execute(): payout through the module fallback
    // ══════════════════════════════════════════════════════════════════

    function test_claimedRemainderCallbackSeesTheLiveReport() public {
        Live memory l = _withAuction(actor);
        uint128 reportId = uint128(oracle.nextReportId());
        OpenPuntStorage.MatchedSwap memory committed = _copy(l.active);

        bytes memory nestedReport = abi.encodeCall(
            puntLifecycle.report,
            (l.swapId, bytes32(0), committed, l.preimage, _noTiming(), address(actor), A1, OA2, REPORT_EXEC_COMP)
        );
        hookToken.resetHook();
        hookToken.armHook(address(actor), abi.encodeCall(actor.exec, (address(punt), 0, nestedReport)));

        uint256 externalBefore = hookToken.balanceOf(address(actor));
        uint256 internalBefore = _spendable(address(actor), address(hookToken));
        Matched memory mt =
            _reportOnPositionWithAmounts(l.swapId, l.dutch, l.active, l.preimage, reporter, REPORT_EXEC_COMP, A1, OA2);
        hookToken.disarmHook();

        assertEq(hookToken.hookCount(), 1, "the claimed remainder called back exactly once");
        _assertHookReverted(PuntErrors.OracleGameInProgress.selector, "nested report during remainder delivery");
        assertEq(punt.swaps(l.swapId), keccak256(abi.encode(l.active)), "the active position hash remained stable");
        assertEq(punt.swapIdToReportId(l.swapId), reportId, "the expected report id was committed in the sidecar");
        assertEq(_storedDutchState(l.swapId), bytes32(0), "the claimed auction was deleted first");
        assertEq(
            hookToken.balanceOf(address(actor)) - externalBefore,
            uint256(l.dutch.maxReward) - l.dutch.startingReward,
            "the swapper received the round-zero remainder externally"
        );
        assertEq(
            _spendable(address(actor), address(hookToken)),
            internalBefore,
            "the successful external push made no credit"
        );
    }

    struct Terminal {
        uint256 swapId;
        Matched closing;
    }

    function _terminal() internal returns (Terminal memory t) {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, OpenPuntStorage.MatcherPreimage memory pre) =
            _openHook(actor);
        t.swapId = swapId;
        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);
        t.closing = _reportOnPositionWithAmounts(swapId, _noDutch(), active, pre, reporter, REPORT_EXEC_COMP, A1, OA2);
        _advanceToSettlementEligibility();
    }

    function _armExecute(Terminal memory t, bytes memory payload) internal {
        hookToken.resetHook();
        hookToken.armHook(address(actor), abi.encodeCall(actor.exec, (address(punt), 0, payload)));
        vm.prank(closeExecutor);
        puntLifecycle.execute(t.swapId, t.closing.swap, t.closing.game, t.closing.helper, false);
        hookToken.disarmHook();
        require(hookToken.hookCount() >= 1, "the terminal payout did not call back");
    }

    function test_terminalPayoutDeletesThePositionBeforeTheCallback() public {
        Terminal memory t = _terminal();
        OpenPuntStorage.MatchedSwap memory empty;

        _armExecute(t, abi.encodeCall(punt.liquidationHeartbeat, (t.swapId, empty)));

        _assertHookReverted(PuntErrors.WrongHash.selector, "inner liquidationHeartbeat");
        assertEq(punt.swaps(t.swapId), bytes32(0), "position deleted before the payout");
        _assertModuleClean(address(tokenA), address(tokenB), "terminal execute");
    }

    function test_terminalCallbackCannotReplayExecute() public {
        Terminal memory t = _terminal();
        _armExecute(
            t,
            abi.encodeCall(puntLifecycle.execute, (t.swapId, t.closing.swap, t.closing.game, t.closing.helper, false))
        );

        _assertHookReverted(PuntErrors.WrongHash.selector, "inner execute replay");
        assertEq(punt.executionGasComp(t.closing.reportId), 0, "compensation consumed exactly once");
    }

    function test_terminalCallbackCannotReviveThroughClose() public {
        Terminal memory t = _terminal();
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        OpenPuntStorage.MatchedSwap memory empty;

        _armExecute(t, abi.encodeCall(punt.close, (t.swapId, input, empty, false, _emptyPermit2(), CLOSE_COMP)));

        _assertHookReverted(PuntErrors.WrongHash.selector, "inner close");
        assertEq(_storedDutchState(t.swapId), bytes32(0), "no auction on a terminal position");
        (uint128 pending,, bool intent) = _closeState(t.swapId);
        assertEq(pending, 0, "no pending compensation");
        assertFalse(intent, "no close intent");
    }

    /// @dev A reverting recipient takes exactly one oracle-ledger credit and no external tokens.
    function test_revertingTerminalReceiverTakesExactlyOneOracleCredit() public {
        Terminal memory t = _terminal();
        uint256 extBefore = hookToken.balanceOf(address(actor));
        uint256 intBefore = _spendable(address(actor), address(hookToken));

        hookToken.armHook(address(punt), abi.encodeWithSelector(bytes4(0xdeadbeef)));
        hookToken.setBubbleHookRevert(true);
        vm.prank(closeExecutor);
        puntLifecycle.execute(t.swapId, t.closing.swap, t.closing.game, t.closing.helper, false);
        hookToken.disarmHook();

        assertEq(hookToken.balanceOf(address(actor)), extBefore, "no external collateral delivered");
        assertGt(_spendable(address(actor), address(hookToken)), intBefore, "exactly one oracle-ledger credit");
        assertEq(punt.swaps(t.swapId), bytes32(0), "the terminal transition still completed");
        _assertModuleClean(address(tokenA), address(tokenB), "reverting terminal receiver");
    }
}
