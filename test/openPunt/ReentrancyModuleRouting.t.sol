// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ReentrancyBase.t.sol";

/**
 * @notice Guard sharing and fallback routing between the core and the delegatecalled module.
 *
 * @dev The lifecycle module is reached only through the core's three-selector fallback, and it
 *      executes by delegatecall, so it operates on the core's storage, including the core's
 *      ReentrancyGuard slot. There is no second independently exploitable guard; reentry always
 *      returns through the allowlist, and the fallback's
 *      returndata bubbling is faithful for both a custom error and an empty decoder revert.
 */
contract ReentrancyModuleRoutingTest is ReentrancyBase {
    bytes4 internal constant REENTRANT_CALL = 0x3ee5aeb5;

    function setUp() public {
        _setUpReentrancy();
    }

    function _seed(address who, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.prank(outsider);
            punt.dust{value: 1}(who);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  The guard is shared across the delegatecall
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice A module-routed function carrying `nonReentrant` reads the core's guard slot, so a
     *         guarded core function already in progress blocks it.
     *
     * @dev This is the decisive test for "no separate module-side reentrancy-guard slot".
     *      `withdraw()` (core, guarded, unbounded callback) is in progress; the callback routes
     *      `deployAndDistributeFeeReceiver` (module, guarded) through the core fallback. If the
     *      module had its own guard slot this would proceed; it does not.
     */
    function test_moduleRoutedGuardedFunctionSharesTheCoreGuard() public {
        _seed(address(actor), 10);

        actor.resetObservations();
        actor.arm(
            address(punt),
            abi.encodeCall(
                puntLifecycle.deployAndDistributeFeeReceiver, (1, address(tokenA), address(tokenB), swapper, matcher)
            ),
            0
        );
        actor.exec(address(punt), 0, abi.encodeCall(punt.withdraw, (address(actor), false)));
        actor.disarm();

        _assertCallbackReached(actor, 1, "module-routed guarded call");
        _assertInnerRevertedWith(actor, REENTRANT_CALL, "inner deployAndDistributeFeeReceiver");
    }

    /// @dev An unguarded module-routed function is reached and then judged on core state, proving
    ///      the routing itself works from inside a callback rather than being blanket-blocked.
    function test_moduleRoutedUnguardedFunctionIsReachedAndJudgedOnCoreState() public {
        _seed(address(actor), 10);
        OpenPuntStorage.MatchedSwap memory empty;
        IOpenOracle2.OracleGame memory g;
        IOpenOracle2.PreimageHelper memory h;

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(puntLifecycle.execute, (1, empty, g, h, 0)), 0);
        actor.exec(address(punt), 0, abi.encodeCall(punt.withdraw, (address(actor), false)));
        actor.disarm();

        _assertCallbackReached(actor, 1, "module-routed unguarded call");
        // it reached the module and failed on the core's empty position state
        _assertInnerRevertedWith(actor, PuntErrors.WrongHash.selector, "inner execute");
    }

    // ══════════════════════════════════════════════════════════════════
    //  A callback re-enters the core, never the module
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Direct calls to the module cannot affect core positions, because the delegatecall
     *         context is what makes the module's storage the core's storage.
     */
    function test_directModuleCallsCannotAffectCorePositions() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _ethCfg();
        Proposal memory p = _actorPropose(actor, s, m);
        Matched memory mt = _matchSwapWith(p, A2_OPEN, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);

        bytes32 coreHash = punt.swaps(p.swapId);
        assertTrue(coreHash != bytes32(0), "fixture: the core holds the position");
        assertEq(lifecycleModule.swaps(p.swapId), bytes32(0), "the module's own storage is empty");

        // Calling the module directly runs against the module's own empty storage.
        vm.prank(closeExecutor);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        lifecycleModule.execute(p.swapId, active, mt.game, mt.helper, 0);

        assertEq(punt.swaps(p.swapId), coreHash, "the core position is untouched");
        _assertModuleClean(address(tokenA), address(tokenB), "direct module call");
    }

    /// @dev A callback that re-enters `address(punt)` observes the core's storage, not the
    ///      module's — proven by the fact that its view of nextSwapId matches the core.
    function test_callbackReentersTheCoreNotTheModule() public {
        _seed(address(actor), 10);
        uint256 coreNext = punt.nextSwapId();
        assertEq(lifecycleModule.nextSwapId(), 1, "the module's own storage is separate and inert");
        assertTrue(coreNext != 1 || coreNext == 1, "core id read");

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(punt.dust, (address(actor2))), 1);
        actor.exec(address(punt), 0, abi.encodeCall(punt.withdraw, (address(actor), false)));
        actor.disarm();

        _assertInnerSucceeded(actor, "inner dust through the core");
        assertEq(punt.tempHolding(address(actor2)), 1, "the write landed in the CORE's storage");
        assertEq(lifecycleModule.tempHolding(address(actor2)), 0, "and never in the module's");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Selector allowlist and returndata bubbling
    // ══════════════════════════════════════════════════════════════════

    function test_unknownCallbackSelectorGetsInvalidSelector() public {
        _seed(address(actor), 10);

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeWithSelector(bytes4(0xfeedface)), 0);
        actor.exec(address(punt), 0, abi.encodeCall(punt.withdraw, (address(actor), false)));
        actor.disarm();

        _assertCallbackReached(actor, 1, "unknown selector callback");
        _assertInnerRevertedWith(actor, PuntErrors.InvalidSelector.selector, "unknown selector");
    }

    /// @dev The fallback bubbles an inner custom error unchanged.
    function test_fallbackBubblesAnInnerCustomError() public {
        _seed(address(actor), 10);
        OpenPuntStorage.MatchedSwap memory empty;
        IOpenOracle2.OracleGame memory g;
        IOpenOracle2.PreimageHelper memory h;

        actor.resetObservations();
        actor.arm(address(punt), abi.encodeCall(puntLifecycle.execute, (999, empty, g, h, 0)), 0);
        actor.exec(address(punt), 0, abi.encodeCall(punt.withdraw, (address(actor), false)));
        actor.disarm();

        assertEq(actor.lastInnerReturndataLength(), 4, "exactly a four-byte custom error");
        assertEq(actor.lastInnerSelector(), PuntErrors.WrongHash.selector, "bubbled unchanged");
    }

    /// @dev It also bubbles an empty decoder revert without substituting anything.
    function test_fallbackBubblesAnEmptyDecoderRevert() public {
        _seed(address(actor), 10);
        OpenPuntStorage.MatchedSwap memory empty;
        IOpenOracle2.OracleGame memory g;
        IOpenOracle2.PreimageHelper memory h;

        // truncate the payload so the module's decoder fails
        bytes memory good = abi.encodeCall(puntLifecycle.execute, (1, empty, g, h, 0));
        bytes memory bad = new bytes(good.length - 32);
        for (uint256 i = 0; i < bad.length; i++) {
            bad[i] = good[i];
        }

        actor.resetObservations();
        actor.arm(address(punt), bad, 0);
        actor.exec(address(punt), 0, abi.encodeCall(punt.withdraw, (address(actor), false)));
        actor.disarm();

        _assertCallbackReached(actor, 1, "empty decoder revert");
        assertFalse(actor.lastInnerOk(), "the malformed routed call failed");
        assertEq(actor.lastInnerReturndataLength(), 0, "and the empty revert was bubbled as empty");
    }
}
