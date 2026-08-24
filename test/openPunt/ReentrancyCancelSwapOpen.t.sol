// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ReentrancyBase.t.sol";

/**
 * @notice Callbacks fired from `cancelSwapOpen()`'s two ETH deliveries.
 *
 * @dev A contract swapper whose collateral is the hook token receives an unbounded callback from
 *      `oracle.pushOrCredit`'s ERC20 branch when the margin is refunded.
 *      Affordability plays no part in any conclusion here: every payload runs with all remaining
 *      gas through real production code.
 *
 *      `cancelSwapOpen` is itself `nonReentrant`, so the classification splits cleanly:
 *      re-entering any guarded function is stopped by the guard, and re-entering an unguarded
 *      lifecycle function is stopped by the deleted proposal hash. Both are asserted by selector,
 *      never by `success == false` alone.
 */
contract ReentrancyCancelSwapOpenTest is ReentrancyBase {
    bytes4 internal constant REENTRANT_CALL = 0x3ee5aeb5; // OZ ReentrancyGuardReentrantCall()

    function setUp() public {
        _setUpReentrancy();
    }

    struct Ready {
        uint256 swapId;
        OpenPuntStorage.ProposedSwap swap;
        OpenPuntStorage.MatcherPreimage preimage;
    }

    /// @dev An expired, externally funded hook-collateral proposal owned by the actor, so the
    ///      margin refund is an unbounded ERC20 callback.
    function _expiredProposal(ReentrantActor a) internal returns (Ready memory r) {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _hookCfg();
        Proposal memory p = _actorPropose(a, s, m);
        r.swapId = p.swapId;
        r.swap = p.swap;
        r.preimage = p.preimage;
        _advanceChain(uint256(p.swap.expiration) - vm.getBlockTimestamp() + 2);
    }

    function _cancel(ReentrantActor a, Ready memory r) internal {
        a.exec(address(punt), 0, abi.encodeCall(punt.cancelSwapOpen, (r.swapId, r.swap, r.preimage)));
    }

    /// @dev The reentrant call is routed through the actor, so `msg.sender` is the genuine
    ///      position owner rather than the token contract.
    function _armAndCancel(ReentrantActor a, Ready memory r, bytes memory payload) internal {
        hookToken.resetHook();
        hookToken.armHook(address(a), abi.encodeCall(a.exec, (address(punt), 0, payload)));
        _cancel(a, r);
        hookToken.disarmHook();
        require(hookToken.hookCount() == 1, "the margin refund did not call back");
    }

    function _assertInnerHookRevertedWith(bytes4 expected, string memory what) internal view {
        require(!hookToken.lastHookOk(), string.concat(what, ": the reentrant call SUCCEEDED"));
        require(hookToken.lastHookSelector() == expected, string.concat(what, ": wrong inner revert selector"));
    }

    // ══════════════════════════════════════════════════════════════════
    //  Same function, same position
    // ══════════════════════════════════════════════════════════════════

    function test_callbackCannotCancelTheSameProposalTwice() public {
        Ready memory r = _expiredProposal(actor);
        Ledgers memory before = _ledgers(address(hookToken));

        _armAndCancel(actor, r, abi.encodeCall(punt.cancelSwapOpen, (r.swapId, r.swap, r.preimage)));

        _assertInnerHookRevertedWith(REENTRANT_CALL, "inner cancelSwapOpen");
        assertEq(punt.swaps(r.swapId), bytes32(0), "the proposal is deleted exactly once");

        _assertDeliveredExactlyOnce(before, r);
    }

    /// @dev The margin and ETH compensations land in different ledgers and are reconciled individually.
    function _assertDeliveredExactlyOnce(Ledgers memory before, Ready memory r) internal view {
        uint256 comps = uint256(r.swap.matcherGasComp) + r.swap.openExecutionComp + r.swap.settlerReward;

        // collateral: exactly the margin, in exactly one of the two collateral ledgers
        uint256 extGain = hookToken.balanceOf(address(actor)) - before.extCollatActor;
        uint256 intGain = _spendable(address(actor), address(hookToken)) - before.oracleCollatActor;
        assertEq(extGain + intGain, uint256(r.swap.initialMarginSwapper), "margin refunded exactly once");

        // ETH compensations: exactly `comps`, across raw / tempHolding / oracle ETH
        uint256 ethGain = (address(actor).balance - before.rawActor)
            + (punt.tempHolding(address(actor)) - before.tempActor)
            + (_spendable(address(actor), address(0)) - before.oracleEthActor);
        assertEq(ethGain, comps, "compensations delivered exactly once");

        assertEq(punt.tempHolding(address(actor2)), 0, "no compensation leaked to the other actor");
        _assertModuleClean(address(tokenA), address(tokenB), "cancelSwapOpen delivery");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Different function, same position
    // ══════════════════════════════════════════════════════════════════

    function test_callbackCannotMatchTheDeletedProposal() public {
        Ready memory r = _expiredProposal(actor);
        Ledgers memory before = _ledgers(address(hookToken));

        _armAndCancel(
            actor, r, abi.encodeCall(punt.matchSwap, (r.swapId, AMOUNT2, r.swap, r.preimage, _noTiming(), matcher))
        );

        // matchSwap is unguarded, so the deleted hash stops this reentry.
        _assertInnerHookRevertedWith(PuntErrors.WrongHash.selector, "inner matchSwap");
        assertEq(punt.swaps(r.swapId), bytes32(0), "still deleted");
        _assertDeliveredExactlyOnce(before, r);
    }

    function test_callbackCannotBailOutTheDeletedProposal() public {
        Ready memory r = _expiredProposal(actor);
        OpenPuntStorage.MatchedSwap memory empty;
        Ledgers memory before = _ledgers(address(hookToken));

        _armAndCancel(actor, r, abi.encodeCall(punt.bailOutOpen, (r.swapId, empty)));

        // bailOutOpen IS guarded, so the guard fires before any hash comparison
        _assertInnerHookRevertedWith(REENTRANT_CALL, "inner bailOutOpen");
        _assertDeliveredExactlyOnce(before, r);
    }

    function test_callbackCannotHeartbeatTheDeletedProposal() public {
        Ready memory r = _expiredProposal(actor);
        OpenPuntStorage.MatchedSwap memory empty;
        Ledgers memory before = _ledgers(address(hookToken));

        _armAndCancel(actor, r, abi.encodeCall(punt.liquidationHeartbeat, (r.swapId, empty)));

        _assertInnerHookRevertedWith(PuntErrors.WrongHash.selector, "inner liquidationHeartbeat");
        (uint128 hbId, uint48 hbTs) = punt.liquidationHeartbeats(r.swapId);
        assertEq(hbId, 0, "no heartbeat created on a deleted proposal");
        assertEq(hbTs, 0, "no heartbeat created on a deleted proposal");
        _assertDeliveredExactlyOnce(before, r);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Same function, different position
    // ══════════════════════════════════════════════════════════════════

    function test_callbackCannotCancelAnUnrelatedProposal() public {
        Ready memory mine = _expiredProposal(actor);
        Ready memory theirs = _expiredProposal(actor2);
        bytes32 theirHash = punt.swaps(theirs.swapId);
        assertTrue(theirHash != bytes32(0), "fixture: the unrelated proposal is live");

        uint256 otherTemp = punt.tempHolding(address(actor2));
        uint256 otherOracleEth = _spendable(address(actor2), address(0));
        uint256 otherCollat = hookToken.balanceOf(address(actor2));

        _armAndCancel(actor, mine, abi.encodeCall(punt.cancelSwapOpen, (theirs.swapId, theirs.swap, theirs.preimage)));

        _assertInnerHookRevertedWith(REENTRANT_CALL, "inner cancel of an unrelated proposal");
        assertEq(punt.swaps(theirs.swapId), theirHash, "the unrelated proposal is untouched");
        assertEq(punt.tempHolding(address(actor2)), otherTemp, "and its owner received nothing");
        assertEq(_spendable(address(actor2), address(0)), otherOracleEth, "in the oracle ETH ledger");
        assertEq(hookToken.balanceOf(address(actor2)), otherCollat, "nor any collateral");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Safely permitted independent transition
    // ══════════════════════════════════════════════════════════════════

    /// @dev `propose()` is unguarded, so a fully funded independent proposal completes during the
    ///      cancellation and must survive the outer completion. Nothing about this depends on how
    ///      expensive the nested call is.
    function test_callbackMayCreateAGenuineProposalThatSurvives() public {
        Ready memory r = _expiredProposal(actor);
        (OpenPuntStorage.ProposedSwap memory ns, OpenPuntStorage.MatcherPreimage memory nm) = _hookCfg();
        uint256 expectedId = punt.nextSwapId();

        hookToken.resetHook();
        hookToken.armHook(
            address(actor),
            abi.encodeCall(
                actor.exec,
                (address(punt), _correctMsgValue(ns), abi.encodeCall(punt.propose, (ns, nm, _emptyPermit2())))
            )
        );
        vm.recordLogs();
        _cancel(actor, r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        hookToken.disarmHook();

        assertEq(hookToken.hookCount(), 1, "the refund called back");
        assertTrue(hookToken.lastHookOk(), "the nested proposal completed");

        (OpenPuntStorage.ProposedSwap memory es, OpenPuntStorage.MatcherPreimage memory ep) =
            _decodeSwapProposed(logs, expectedId);
        assertEq(es.swapper, address(actor), "the actor genuinely owns the nested proposal");
        assertEq(punt.swaps(expectedId), keccak256(abi.encode(es, ep)), "nested proposal survived intact");
        assertEq(punt.nextSwapId(), expectedId + 1, "exactly one swapId consumed");
        assertEq(punt.swaps(r.swapId), bytes32(0), "and the outer cancellation still completed");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Bubbling: complete rollback of the outer cancellation
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice A reverting hook inside the ERC20 refund does not roll the cancellation back.
     *
     * @dev `oracle._pushOrCredit`'s ERC20 branch performs a low-level `transfer` and, on failure,
     *      credits the recipient's internal balance instead of reverting. A recipient token that
     *      reverts during delivery therefore converts its own refund into an internal credit — the
     *      collateral-side analogue of the ETH fallback — while the outer cancellation completes.
     *
     *      This is asserted because it is the ordering that matters for reentrancy: the refund is
     *      delivered exactly once, by exactly one route, and a failing recipient cannot use its
     *      own failure to keep the proposal alive.
     */
    function test_aRevertingHookConvertsTheRefundIntoAnInternalCreditExactlyOnce() public {
        Ready memory r = _expiredProposal(actor);
        uint256 extBefore = hookToken.balanceOf(address(actor));
        uint256 intBefore = _spendable(address(actor), address(hookToken));

        hookToken.armHook(address(punt), abi.encodeWithSelector(bytes4(0xdeadbeef)));
        hookToken.setBubbleHookRevert(true);

        _cancel(actor, r);
        hookToken.disarmHook();

        assertEq(punt.swaps(r.swapId), bytes32(0), "the cancellation still completed");
        assertEq(hookToken.balanceOf(address(actor)), extBefore, "no external collateral delivered");
        assertEq(
            _spendable(address(actor), address(hookToken)),
            intBefore + r.swap.initialMarginSwapper,
            "the margin fell back to the oracle internal ledger exactly once"
        );
        _assertModuleClean(address(tokenA), address(tokenB), "reverting hook refund");
    }
}
