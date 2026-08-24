// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ReentrancyBase.t.sol";

/**
 * @notice Callbacks fired from `withdraw()`, OpenPunt's only unbounded ETH callback.
 *
 * @dev `withdraw` forwards all remaining gas, which is precisely why it is the one ETH-paying
 *      function carrying `nonReentrant`. It is therefore the surface where the deep same/cross
 *      function matrix is genuinely reachable, and the only ETH surface where a lawful nested
 *      transition can actually complete.
 *
 *      `withdraw` zeroes or sentinels `tempHolding[_to]` before the external call, so
 *      a reentrant read during the callback already sees the consumed balance. Both callback
 *      behaviours are covered: swallowing the inner failure so the outer withdrawal completes
 *      once, and bubbling it so the outer withdrawal and its pre-call ledger mutation roll back.
 */
contract ReentrancyWithdrawTest is ReentrancyBase {
    bytes4 internal constant REENTRANT_CALL = 0x3ee5aeb5;

    function setUp() public {
        _setUpReentrancy();
    }

    function _seed(address who, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.prank(outsider);
            punt.dust{value: 1}(who);
        }
        assertEq(punt.tempHolding(who), n, "fixture: seeded through real dust() calls");
    }

    function _withdraw(ReentrantActor a, address to, bool leaveOne) internal {
        a.exec(address(punt), 0, abi.encodeCall(punt.withdraw, (to, leaveOne)));
    }

    // ══════════════════════════════════════════════════════════════════
    //  Same function, same recipient
    // ══════════════════════════════════════════════════════════════════

    function test_reentrantWithdrawIsBlockedAndTheOuterCompletesOnce() public {
        _seed(address(actor), 10);
        uint256 rawBefore = address(actor).balance;

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(punt.withdraw, (address(actor), false)), 0);

        _withdraw(actor, address(actor), false);
        actor.disarm();

        _assertCallbackReached(actor, 1, "reentrant withdraw");
        _assertInnerRevertedWith(actor, REENTRANT_CALL, "inner withdraw");
        assertEq(punt.tempHolding(address(actor)), 0, "slot drained exactly once, no sentinel");
        assertEq(address(actor).balance, rawBefore + 10, "paid exactly once");
    }

    /// @dev leaveOne keeps the sentinel exactly, asserted on the slot rather than on a balance.
    function test_reentrantWithdrawWithLeaveOneKeepsExactlyOneWei() public {
        _seed(address(actor), 10);
        uint256 rawBefore = address(actor).balance;

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(punt.withdraw, (address(actor), true)), 0);

        _withdraw(actor, address(actor), true);
        actor.disarm();

        _assertCallbackReached(actor, 1, "reentrant withdraw with leaveOne");
        _assertInnerRevertedWith(actor, REENTRANT_CALL, "inner withdraw");
        assertEq(punt.tempHolding(address(actor)), 1, "exactly one wei sentinel remains");
        assertEq(address(actor).balance, rawBefore + 9, "paid amount minus the sentinel");
    }

    /**
     * @notice The ledger is consumed before the external call, observed directly from inside the
     *         callback rather than inferred from the guard.
     *
     * @dev The payload is a view call reading `tempHolding` for this recipient, so the test
     *      sees the slot exactly as a reentrant attacker would. Reading zero proves the write
     *      happens before the call — a property that is independent of `nonReentrant` and would
     *      survive the guard being removed.
     */
    function test_theLedgerIsConsumedBeforeTheCallbackRuns() public {
        _seed(address(actor), 10);

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(punt.tempHolding, (address(actor))), 0);
        _withdraw(actor, address(actor), false);
        actor.disarm();

        _assertCallbackReached(actor, 1, "ledger observation");
        _assertInnerSucceeded(actor, "inner tempHolding view");
        assertEq(actor.lastInnerWord(), 0, "the slot was ALREADY consumed when the callback ran");
        assertEq(punt.tempHolding(address(actor)), 0, "and consumed exactly once overall");
    }

    /// @dev Same observation for the sentinel path: the callback sees exactly 1, never the
    ///      pre-call balance.
    function test_theLeaveOneSentinelIsWrittenBeforeTheCallbackRuns() public {
        _seed(address(actor), 10);

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(punt.tempHolding, (address(actor))), 0);
        _withdraw(actor, address(actor), true);
        actor.disarm();

        _assertInnerSucceeded(actor, "inner tempHolding view");
        assertEq(actor.lastInnerWord(), 1, "the callback saw exactly the sentinel, not the balance");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Bubbling: complete rollback of the outer withdrawal
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice When the recipient propagates the inner failure, the entire outer withdrawal rolls
     *         back — including the ledger mutation that had already been written before the call.
     */
    function test_bubblingTheInnerFailureRollsBackTheOuterWithdrawal() public {
        _seed(address(actor), 10);
        uint256 rawBefore = address(actor).balance;
        uint256 coreRawBefore = address(punt).balance;

        actor.resetObservations();
        actor.setBubbleInnerRevert(true);
        actor.arm(address(punt), abi.encodeCall(punt.withdraw, (address(actor), false)), 0);

        vm.expectRevert(); // EthTransferFailed bubbles out of the outer withdraw
        _withdraw(actor, address(actor), false);

        actor.setBubbleInnerRevert(false);
        actor.disarm();

        assertEq(punt.tempHolding(address(actor)), 10, "the pre-call ledger mutation rolled back");
        assertEq(address(actor).balance, rawBefore, "no ETH moved");
        assertEq(address(punt).balance, coreRawBefore, "core ETH unchanged");
    }

    function test_bubblingRollsBackTheLeaveOneVariantToo() public {
        _seed(address(actor), 10);

        actor.setBubbleInnerRevert(true);
        actor.arm(address(punt), abi.encodeCall(punt.withdraw, (address(actor), true)), 0);

        vm.expectRevert();
        _withdraw(actor, address(actor), true);

        actor.setBubbleInnerRevert(false);
        actor.disarm();

        assertEq(punt.tempHolding(address(actor)), 10, "sentinel path rolled back to the full balance");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Same function, different recipient
    // ══════════════════════════════════════════════════════════════════

    /// @dev The guard is function-scoped, not recipient-scoped: withdrawing for a different
    ///      recipient during the callback is blocked just the same, and that recipient's slot is
    ///      untouched.
    function test_reentrantWithdrawForAnotherRecipientIsAlsoBlocked() public {
        _seed(address(actor), 10);
        _seed(address(actor2), 7);
        uint256 other = address(actor2).balance;

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(punt.withdraw, (address(actor2), false)), 0);

        _withdraw(actor, address(actor), false);
        actor.disarm();

        _assertInnerRevertedWith(actor, REENTRANT_CALL, "inner withdraw for another recipient");
        assertEq(punt.tempHolding(address(actor2)), 7, "the other recipient's slot is untouched");
        assertEq(address(actor2).balance, other, "and it received nothing");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Different function, guarded and unguarded
    // ══════════════════════════════════════════════════════════════════

    function test_reentrantBailOutIsBlockedByTheSharedGuard() public {
        _seed(address(actor), 10);
        OpenPuntStorage.MatchedSwap memory empty;

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(punt.bailOutOpen, (1, empty)), 0);
        _withdraw(actor, address(actor), false);
        actor.disarm();

        _assertInnerRevertedWith(actor, REENTRANT_CALL, "inner bailOutOpen");
    }

    function test_reentrantCancelSwapOpenIsBlockedByTheSharedGuard() public {
        _seed(address(actor), 10);
        OpenPuntStorage.ProposedSwap memory es;
        OpenPuntStorage.MatcherPreimage memory ep;

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(punt.cancelSwapOpen, (1, es, ep)), 0);
        _withdraw(actor, address(actor), false);
        actor.disarm();

        _assertInnerRevertedWith(actor, REENTRANT_CALL, "inner cancelSwapOpen");
    }

    /// @dev An unguarded lifecycle function is reached and stopped by its own hash gate
    ///      rather than by the guard. This separates the two defences on the same surface.
    function test_reentrantUnguardedLifecycleCallIsStoppedByItsHashGate() public {
        _seed(address(actor), 10);
        OpenPuntStorage.MatchedSwap memory empty;

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(punt.liquidationHeartbeat, (1, empty)), 0);
        _withdraw(actor, address(actor), false);
        actor.disarm();

        _assertInnerRevertedWith(actor, PuntErrors.WrongHash.selector, "inner liquidationHeartbeat");
        assertEq(punt.tempHolding(address(actor)), 0, "the outer withdrawal still completed once");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Safely permitted independent transition
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice An unguarded nested proposal may complete during the outer withdrawal.
     *
     * @dev The callback is unbounded, so the genuine nested proposal must survive the outer
     *      function's completion untouched.
     *      Safe composability means a lawful nested transition is not collateral damage. The
     *      outer withdrawal must neither delete nor overwrite the state the callback created.
     */
    function test_callbackMayCreateAGenuineProposalThatSurvivesTheOuterWithdrawal() public {
        _seed(address(actor), 10);

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _ethCfg();
        uint256 value = _correctMsgValue(s);
        uint256 expectedId = punt.nextSwapId();

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(punt.propose, (s, m, _emptyPermit2())), value);

        vm.recordLogs();
        _withdraw(actor, address(actor), false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        actor.disarm();

        _assertCallbackReached(actor, 1, "lawful nested propose");
        _assertInnerSucceeded(actor, "inner propose");

        // The nested proposal exists and remains intact after the outer call completes.
        (OpenPuntStorage.ProposedSwap memory es, OpenPuntStorage.MatcherPreimage memory ep) =
            _decodeSwapProposed(logs, expectedId);
        assertEq(es.swapper, address(actor), "the actor genuinely owns the nested proposal");
        assertEq(punt.swaps(expectedId), keccak256(abi.encode(es, ep)), "nested proposal survived intact");
        assertEq(punt.nextSwapId(), expectedId + 1, "exactly one swapId consumed");

        // and the outer withdrawal still completed exactly once
        assertEq(punt.tempHolding(address(actor)), 0, "outer withdrawal completed");
        _assertModuleClean(address(0), address(0), "lawful nested propose");
    }

    /// @dev The nested proposal remains independently usable afterwards, which is the real
    ///      meaning of "survives": not merely that its hash is present, but that it still works.
    function test_theNestedProposalRemainsUsableAfterwards() public {
        _seed(address(actor), 10);
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _ethCfg();
        uint256 value = _correctMsgValue(s);
        uint256 expectedId = punt.nextSwapId();

        actor.arm(address(punt), abi.encodeCall(punt.propose, (s, m, _emptyPermit2())), value);
        vm.recordLogs();
        _withdraw(actor, address(actor), false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        actor.disarm();

        (OpenPuntStorage.ProposedSwap memory es, OpenPuntStorage.MatcherPreimage memory ep) =
            _decodeSwapProposed(logs, expectedId);

        // cancel it normally, from outside any callback
        _advanceChain(uint256(es.expiration) - vm.getBlockTimestamp() + 2);
        actor.exec(address(punt), 0, abi.encodeCall(punt.cancelSwapOpen, (expectedId, es, ep)));
        assertEq(punt.swaps(expectedId), bytes32(0), "the nested proposal was fully usable afterwards");
    }
}
