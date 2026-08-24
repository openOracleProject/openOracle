// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ReentrancyBase.t.sol";

/**
 * @notice Callbacks fired during `propose()` funding under unbounded gas.
 *
 * @dev The funding pull runs through Permit2 into the hook token's `transferFrom`, which forwards
 *      all remaining gas, so nested transitions here are genuinely complete lifecycle calls.
 */
contract ReentrancyProposeFundingTest is ReentrancyBase {
    function setUp() public {
        _setUpReentrancy();
    }

    /**
     * @notice The outer proposal's hash is not written until funding completes, so a callback
     *         cannot act on the half-created proposal.
     */
    function test_hookDuringProposeCannotActOnTheHalfCreatedProposal() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _hookCfg();
        uint256 expectedId = punt.nextSwapId();
        OpenPuntStorage.MatchedSwap memory empty;

        hookToken.resetHook();
        hookToken.armHook(address(punt), abi.encodeCall(punt.liquidationHeartbeat, (expectedId, empty)));

        Proposal memory p = _actorPropose(actor, s, m);
        hookToken.disarmHook();

        assertEq(hookToken.hookCount(), 1, "the funding callback genuinely ran");
        assertFalse(hookToken.lastHookOk(), "and could not act on the outer proposal");
        assertEq(hookToken.lastHookSelector(), PuntErrors.WrongHash.selector, "the hash was not live yet");
        assertEq(p.swapId, expectedId, "the outer proposal took the expected id");
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "and completed normally");
    }

    /**
     * @notice A funded nested proposal during outer proposal funding.
     *
     * @dev `propose()` reserves its id with `nextSwapId++` before funding, so the outer proposal
     *      holds id N and the nested one — created inside the funding callback — holds N+1. That
     *      ordering is what makes a collision impossible: the outer id is already consumed when
     *      the callback runs. Both hashes, both emitted structs, the final `nextSwapId` and the
     *      independent usability of each are asserted, so the nested transition is a first-class
     *      survivor rather than a side effect.
     */
    function test_fundedNestedProposalTakesItsOwnIdAndBothSurvive() public {
        (OpenPuntStorage.ProposedSwap memory outer, OpenPuntStorage.MatcherPreimage memory outerM) = _hookCfg();
        // the nested proposal uses ETH collateral, so it does not recurse into the hook token
        (OpenPuntStorage.ProposedSwap memory nested, OpenPuntStorage.MatcherPreimage memory nestedM) = _ethCfg();

        uint256 firstId = punt.nextSwapId();
        hookToken.resetHook();
        hookToken.armHook(
            address(actor),
            abi.encodeCall(
                actor.exec,
                (
                    address(punt),
                    _correctMsgValue(nested),
                    abi.encodeCall(punt.propose, (nested, nestedM, _emptyPermit2()))
                )
            )
        );

        vm.recordLogs();
        uint256 value = _correctMsgValue(outer);
        bytes memory ret =
            actor.exec(address(punt), value, abi.encodeCall(punt.propose, (outer, outerM, _emptyPermit2())));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        hookToken.disarmHook();

        uint256 outerId = abi.decode(ret, (uint256));
        uint256 nestedId = firstId + 1;
        assertTrue(hookToken.lastHookOk(), "the nested proposal genuinely completed");

        // the id is reserved before funding, so the outer proposal holds N and the nested one N+1
        assertEq(outerId, firstId, "the outer proposal reserved its id before the callback");
        assertEq(punt.nextSwapId(), firstId + 2, "exactly two ids consumed");

        (OpenPuntStorage.ProposedSwap memory nEs, OpenPuntStorage.MatcherPreimage memory nEp) =
            _decodeSwapProposed(logs, nestedId);
        (OpenPuntStorage.ProposedSwap memory oEs, OpenPuntStorage.MatcherPreimage memory oEp) =
            _decodeSwapProposed(logs, outerId);

        assertEq(punt.swaps(nestedId), keccak256(abi.encode(nEs, nEp)), "nested hash intact");
        assertEq(punt.swaps(outerId), keccak256(abi.encode(oEs, oEp)), "outer hash intact");
        assertTrue(punt.swaps(nestedId) != punt.swaps(outerId), "the two proposals are genuinely distinct");
        assertEq(nEs.collatToken, address(0), "the nested proposal is the ETH-collateral one");
        assertEq(oEs.collatToken, address(hookToken), "and the outer is the hook-collateral one");
        assertEq(nEs.swapper, address(actor), "the actor owns the nested proposal");
        assertEq(oEs.swapper, address(actor), "and the outer");

        // both remain independently usable afterwards
        _advanceChain(uint256(oEs.expiration) - vm.getBlockTimestamp() + 2);
        actor.exec(address(punt), 0, abi.encodeCall(punt.cancelSwapOpen, (nestedId, nEs, nEp)));
        actor.exec(address(punt), 0, abi.encodeCall(punt.cancelSwapOpen, (outerId, oEs, oEp)));
        assertEq(punt.swaps(nestedId), bytes32(0), "nested proposal was independently usable");
        assertEq(punt.swaps(outerId), bytes32(0), "outer proposal was independently usable");
    }

    /// @dev If token funding itself fails, every id and all nested state roll back together.
    function test_revertingTokenFundingRollsBackIdsAndNestedState() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _hookCfg();
        uint256 idBefore = punt.nextSwapId();

        // Remove the allowance so the pull fails after the hook has already run.
        actor.approveToken(address(hookToken), PERMIT2, 0);
        hookToken.resetHook();
        hookToken.armHook(address(punt), abi.encodeCall(punt.dust, (address(actor2))));

        uint256 value = _correctMsgValue(s);
        vm.expectRevert();
        actor.exec(address(punt), value, abi.encodeCall(punt.propose, (s, m, _emptyPermit2())));
        hookToken.disarmHook();

        assertEq(punt.nextSwapId(), idBefore, "nextSwapId rolled back");
        assertEq(punt.swaps(idBefore), bytes32(0), "no proposal stored");
        assertEq(punt.tempHolding(address(actor2)), 0, "nested state rolled back too");
        assertEq(hookToken.hookCount(), 0, "the hook's own bookkeeping rolled back with it");
        _assertModuleClean(address(tokenA), address(tokenB), "reverting funding");
    }
}
