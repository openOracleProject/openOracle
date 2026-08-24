// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ReentrancyBase.t.sol";

/**
 * @notice Structural facts used by the reentrancy tests.
 *
 * @dev Callback affordability is not part of the
 *      security argument, and ETH fallback-delivery behaviour lives in the ETH-delivery
 *      compatibility suites rather than here.
 */
contract ReentrancyGuardMapTest is ReentrancyBase {
    function setUp() public {
        _setUpReentrancy();
    }

    /// @dev The module's own storage is separate and inert; the core's is the live storage. The
    ///      behavioural consequence — a delegatecalled guarded function reading the core's guard
    ///      slot — is proven in ReentrancyModuleRoutingTest.
    function test_coreAndModuleAreDistinctWithSeparateOwnStorage() public view {
        assertTrue(address(punt) != address(lifecycleModule), "two distinct contracts");
        assertEq(punt.nextSwapId(), 1, "core storage is the live storage");
        assertEq(lifecycleModule.nextSwapId(), 1, "the module's own storage is separate and inert");
    }

    /// @dev The ERC20 branch of `pushOrCredit` forwards all remaining gas, which is what makes a
    ///      hook-collateral position a faithful unbounded callback surface. Demonstrated by
    ///      running a genuinely expensive payload from inside a real refund.
    function test_erc20RefundCallbacksAreUnbounded() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _hookCfg();
        Proposal memory p = _actorPropose(actor, s, m);
        _advanceChain(uint256(p.swap.expiration) - vm.getBlockTimestamp() + 2);

        // an expensive nested transition: a fully funded independent proposal
        (OpenPuntStorage.ProposedSwap memory ns, OpenPuntStorage.MatcherPreimage memory nm) = _hookCfg();
        uint256 idBefore = punt.nextSwapId();

        hookToken.armHook(
            address(actor),
            abi.encodeCall(
                actor.exec,
                (address(punt), _correctMsgValue(ns), abi.encodeCall(punt.propose, (ns, nm, _emptyPermit2())))
            )
        );
        actor.exec(address(punt), 0, abi.encodeCall(punt.cancelSwapOpen, (p.swapId, p.swap, p.preimage)));
        hookToken.disarmHook();

        assertGt(hookToken.hookCount(), 0, "the refund genuinely called back");
        assertTrue(hookToken.lastHookOk(), "and an expensive nested proposal completed inside it");
        assertEq(punt.nextSwapId(), idBefore + 1, "the nested proposal really was created");
    }
}
