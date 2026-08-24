// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice Wiring, fallback routing and module-isolation checks.
 *
 * @dev Storage-layout equivalence between core and module is deliberately not
 *      probed with runtime slot writes here; a compile-artifact comparison is a
 *      separate concern.
 */
contract DeploymentAndRoutingTest is OpenPuntBase {
    function setUp() public {
        _setUpAll();
    }

    // ── wiring ──────────────────────────────────────────────────────────

    function test_coreAndModuleShareOracle() public view {
        assertEq(address(punt.oracle()), address(oracle), "core oracle");
        assertEq(address(lifecycleModule.oracle()), address(oracle), "module oracle");
        assertEq(address(punt.oracle()), address(lifecycleModule.oracle()), "core/module oracle agree");
    }

    function test_coreAndModuleShareFeeReceiverImpl() public view {
        assertEq(punt.feeReceiverImpl(), lifecycleModule.feeReceiverImpl(), "feeReceiverImpl agree");
        assertEq(punt.lifecycleModule(), address(lifecycleModule), "lifecycleModule pointer");
    }

    function test_feeReceiverImplHasCode() public view {
        assertGt(punt.feeReceiverImpl().code.length, 0, "impl has code");
    }

    // ── constructor rejection ───────────────────────────────────────────

    function test_constructorRejectsCodelessLifecycle() public {
        vm.expectRevert(PuntErrors.InvalidLifecycleModule.selector);
        new openPunt(address(oracle), address(0xDEAD));
    }

    function test_constructorRejectsForeignOracleLifecycle() public {
        OpenOracle otherOracle = new OpenOracle();
        OpenPuntLifecycle foreign = new OpenPuntLifecycle(address(otherOracle));

        vm.expectRevert(PuntErrors.InvalidLifecycleModule.selector);
        new openPunt(address(oracle), address(foreign));
    }

    // ── fallback routing ────────────────────────────────────────────────

    function test_unknownSelectorReverts() public {
        vm.expectRevert(PuntErrors.InvalidSelector.selector);
        (bool ok,) = address(punt).call(abi.encodeWithSignature("definitelyNotARealFunction()"));
        ok; // expectRevert asserts on the low-level call
    }

    function test_emptyCalldataReverts() public {
        vm.expectRevert(PuntErrors.InvalidSelector.selector);
        (bool ok,) = address(punt).call("");
        ok;
    }

    /// @dev A hash-mismatched report() must reach the module and bubble WrongHash verbatim.
    function test_routedReportBubblesWrongHash() public {
        OpenPuntStorage.MatchedSwap memory empty;
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();
        OpenPuntStorage.CloseDutch memory d;

        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.report(999, _expectedDutchHash(d), empty, m, _noTiming(), reporter, INITIAL_LIQUIDITY, AMOUNT2, 0);
    }

    /// @dev AmountsCannotBeZero exists only inside the lifecycle module, so bubbling it
    ///      proves the delegatecall actually executed module code past its hash gate.
    function test_routedReportBubblesModuleOnlyError() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openPosition();
        OpenPuntStorage.CloseDutch memory d;

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.AmountsCannotBeZero.selector);
        puntLifecycle.report(swapId, _expectedDutchHash(d), active, p.preimage, _noTiming(), reporter, 0, AMOUNT2, 0);
    }

    function test_routedExecuteBubblesWrongHash() public {
        OpenPuntStorage.MatchedSwap memory empty;
        IOpenOracle2.OracleGame memory g;
        IOpenOracle2.PreimageHelper memory h;

        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.execute(999, empty, g, h, false);
    }

    /// @dev NoOracleGame is module-only; an active position with no live report reaches it.
    function test_routedExecuteBubblesModuleOnlyError() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openPosition();
        IOpenOracle2.OracleGame memory g;
        IOpenOracle2.PreimageHelper memory h;

        vm.expectRevert(PuntErrors.NoOracleGame.selector);
        puntLifecycle.execute(swapId, active, g, h, false);
    }

    // ── module isolation ────────────────────────────────────────────────

    function test_directModuleExecuteCannotTouchCorePosition() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openPosition();
        bytes32 storedBefore = punt.swaps(swapId);
        uint256 nextSwapIdBefore = punt.nextSwapId();
        assertTrue(storedBefore != bytes32(0), "core position exists");

        IOpenOracle2.OracleGame memory g;
        IOpenOracle2.PreimageHelper memory h;

        // The module's own `swaps` mapping is empty, so the core's live position hash
        // cannot match anything there.
        vm.prank(executor);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        lifecycleModule.execute(swapId, active, g, h, false);

        assertEq(punt.swaps(swapId), storedBefore, "core position untouched");
        assertEq(punt.nextSwapId(), nextSwapIdBefore, "core nextSwapId untouched");
        assertEq(lifecycleModule.swaps(swapId), bytes32(0), "module storage still empty");
        assertEq(lifecycleModule.nextSwapId(), 1, "module nextSwapId untouched");
    }

    function test_directModuleReportCannotTouchCorePosition() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openPosition();
        bytes32 storedBefore = punt.swaps(swapId);
        OpenPuntStorage.CloseDutch memory d;

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        lifecycleModule.report(swapId, _expectedDutchHash(d), active, p.preimage, _noTiming(), reporter, INITIAL_LIQUIDITY, AMOUNT2, 0);

        assertEq(punt.swaps(swapId), storedBefore, "core position untouched");
        assertEq(lifecycleModule.swaps(swapId), bytes32(0), "module storage still empty");
        assertEq(punt.swapIdToReportId(swapId), 0, "core report sidecar untouched");
        assertEq(punt.executionGasComp(oracle.nextReportId()), 0, "next report compensation untouched");
    }

    function test_directModuleHoldsNoFunds() public {
        _openPosition();
        assertEq(address(lifecycleModule).balance, 0, "module holds no ETH");
        assertEq(collat.balanceOf(address(lifecycleModule)), 0, "module holds no collat");
        assertEq(_spendable(address(lifecycleModule), address(collat)), 0, "module has no internal collat");
        assertEq(_spendable(address(lifecycleModule), address(0)), 0, "module has no internal ETH");
    }

    // ── selector disjointness ───────────────────────────────────────────

    function test_routedSelectorsAreDisjointFromCoreSelectors() public {
        bytes4[3] memory routed = [
            OpenPuntLifecycle.report.selector,
            OpenPuntLifecycle.execute.selector,
            OpenPuntLifecycle.deployAndDistributeFeeReceiver.selector
        ];

        bytes4[] memory core = _coreSelectors();

        for (uint256 r = 0; r < routed.length; r++) {
            for (uint256 c = 0; c < core.length; c++) {
                assertTrue(routed[r] != core[c], "routed selector collides with a core selector");
            }
        }

        // routed selectors are also distinct from each other
        assertTrue(routed[0] != routed[1], "report != execute");
        assertTrue(routed[0] != routed[2], "report != deployAndDistributeFeeReceiver");
        assertTrue(routed[1] != routed[2], "execute != deployAndDistributeFeeReceiver");
    }

    /// @dev Every externally reachable selector declared on the core itself, including
    ///      the public state-variable getters inherited from OpenPuntStorage.
    function _coreSelectors() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](20);
        uint256 i;
        sels[i++] = openPunt.propose.selector;
        sels[i++] = openPunt.matchSwap.selector;
        sels[i++] = openPunt.liquidationHeartbeat.selector;
        sels[i++] = openPunt.close.selector;
        sels[i++] = openPunt.cancelCloseAuction.selector;
        sels[i++] = openPunt.cancelSwapOpen.selector;
        sels[i++] = openPunt.bailOutOpen.selector;
        sels[i++] = openPunt.dust.selector;
        sels[i++] = openPunt.withdraw.selector;
        sels[i++] = bytes4(keccak256("feeReceiverImpl()"));
        sels[i++] = bytes4(keccak256("lifecycleModule()"));
        sels[i++] = bytes4(keccak256("oracle()"));
        sels[i++] = bytes4(keccak256("swaps(uint256)"));
        sels[i++] = bytes4(keccak256("closeAuctions(uint256)"));
        sels[i++] = bytes4(keccak256("swapIdToReportId(uint256)"));
        sels[i++] = bytes4(keccak256("executionGasComp(uint256)"));
        sels[i++] = bytes4(keccak256("closeRequestBlock(uint256)"));
        sels[i++] = bytes4(keccak256("liquidationHeartbeats(uint256)"));
        sels[i++] = bytes4(keccak256("nextSwapId()"));
        sels[i++] = bytes4(keccak256("tempHolding(address)"));
        require(i == sels.length, "selector array sized wrong");
    }

    /// @dev The getters above must actually exist on the deployed core, otherwise the
    ///      disjointness test would be asserting against phantom signatures.
    function test_coreGetterSignaturesAreReal() public view {
        bytes[] memory calls = new bytes[](11);
        calls[0] = abi.encodeWithSignature("feeReceiverImpl()");
        calls[1] = abi.encodeWithSignature("lifecycleModule()");
        calls[2] = abi.encodeWithSignature("oracle()");
        calls[3] = abi.encodeWithSignature("swaps(uint256)", uint256(1));
        calls[4] = abi.encodeWithSignature("closeAuctions(uint256)", uint256(1));
        calls[5] = abi.encodeWithSignature("swapIdToReportId(uint256)", uint256(1));
        calls[6] = abi.encodeWithSignature("executionGasComp(uint256)", uint256(1));
        calls[7] = abi.encodeWithSignature("nextSwapId()");
        calls[8] = abi.encodeWithSignature("tempHolding(address)", address(this));
        calls[9] = abi.encodeWithSignature("closeRequestBlock(uint256)", uint256(1));
        calls[10] = abi.encodeWithSignature("liquidationHeartbeats(uint256)", uint256(1));

        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = address(punt).staticcall(calls[i]);
            assertTrue(ok, "core getter missing");
        }
    }
}
