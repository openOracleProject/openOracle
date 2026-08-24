// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./FeeReceiverBase.t.sol";

/**
 * @notice Counterfactual prediction and lazy deployment of the per-position fee receiver.
 */
contract FeeReceiverDeploymentTest is FeeReceiverBase {
    function setUp() public {
        _setUpFees();
    }

    // ══════════════════════════════════════════════════════════════════
    //  2. Counterfactual prediction
    // ══════════════════════════════════════════════════════════════════

    function test_matchCommitsTheIndependentlyPredictedAddress() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);

        address predicted = _predict(p.swapId, address(tokenA), address(tokenB), swapper, matcher, address(punt));

        assertEq(mt.swap.feeRecipient, predicted, "MatchedSwap.feeRecipient is the predicted address");
        assertEq(mt.game.protocolFeeRecipient, predicted, "the oracle game commits the same address");
        assertEq(predicted.code.length, 0, "no code at the counterfactual address yet");

        // the oracle has already seeded both sentinel slots there
        assertEq(oracle.tokenHolder(predicted, address(tokenA)), 1, "token1 sentinel initialised");
        assertEq(oracle.tokenHolder(predicted, address(tokenB)), 1, "token2 sentinel initialised");
        assertEq(_spendable(predicted, address(tokenA)), 0, "and nothing spendable yet");
        assertEq(_spendable(predicted, address(tokenB)), 0, "and nothing spendable yet");
    }

    function test_predictionUsesTheCoreAsDeployerNotTheModule() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);

        address viaCore = _predict(p.swapId, address(tokenA), address(tokenB), swapper, matcher, address(punt));
        address viaModule =
            _predict(p.swapId, address(tokenA), address(tokenB), swapper, matcher, address(lifecycleModule));

        assertEq(mt.swap.feeRecipient, viaCore, "the committed recipient is the core-deployed prediction");
        assertTrue(viaCore != viaModule, "the module-deployer prediction is a different address");

        // accrue and deploy for real; the module-deployer address must stay empty
        Game memory g = _gameOf(mt);
        (g,) = _disputeForToken1Fee(g, disputer);
        (address receiver,,,) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(receiver, viaCore, "deployed at the core-derived address");
        assertGt(viaCore.code.length, 0, "clone exists there");
        assertEq(viaModule.code.length, 0, "and nowhere else");
    }

    function test_differentSwapIdsGiveDistinctAddresses() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory pA, Matched memory mtA) = _matchAsset(s, m);
        (Proposal memory pB, Matched memory mtB) = _matchAsset(s, m);

        assertTrue(pA.swapId != pB.swapId, "two positions");
        assertEq(mtA.swap.swapper, mtB.swap.swapper, "identical parties");
        assertEq(mtA.swap.matcher, mtB.swap.matcher, "identical parties");
        assertEq(mtA.swap.oracleToken1, mtB.swap.oracleToken1, "identical assets");
        assertEq(mtA.swap.oracleToken2, mtB.swap.oracleToken2, "identical assets");

        assertTrue(
            mtA.swap.feeRecipient != mtB.swap.feeRecipient, "identical parties and assets still give distinct receivers"
        );
        assertEq(
            mtA.swap.feeRecipient,
            _predict(pA.swapId, address(tokenA), address(tokenB), swapper, matcher, address(punt)),
            "A matches its own prediction"
        );
        assertEq(
            mtB.swap.feeRecipient,
            _predict(pB.swapId, address(tokenA), address(tokenB), swapper, matcher, address(punt)),
            "B matches its own prediction"
        );
    }

    function test_zeroProtocolFeeCommitsNoReceiverAndCannotDeployOne() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _feeCfg(Legs.BothErc20, address(collat), 0);
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);

        assertEq(mt.swap.feeRecipient, address(0), "no fee recipient committed");
        assertEq(mt.game.protocolFeeRecipient, address(0), "the oracle game commits none either");

        address predicted = _predict(p.swapId, address(tokenA), address(tokenB), swapper, matcher, address(punt));
        assertEq(predicted.code.length, 0, "nothing deployed");

        // and the zero-fee game cannot be used to deploy one
        Game memory g = _gameOf(mt);
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(p.swapId, swapper, matcher, g.game, g.helper);
        assertEq(predicted.code.length, 0, "still nothing deployed");
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. Lazy deployment
    // ══════════════════════════════════════════════════════════════════

    function test_anyCallerMayDeployAndTheCloneCarriesTheExactImmutableArgs() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);

        Game memory g = _gameOf(mt);
        uint256 fee;
        (g, fee) = _disputeForToken1Fee(g, disputer);

        address predicted = _predictForPosition(p.swapId, mt.swap);
        (address receiver, uint256 fees1, uint256 fees2,) =
            _deployAndDistribute(p.swapId, swapper, matcher, g, outsider); // an unrelated caller

        assertEq(receiver, predicted, "returned receiver equals the prediction");
        assertGt(receiver.code.length, 0, "clone deployed there");
        assertEq(fees1, fee, "token1 fees distributed");
        assertEq(fees2, 0, "no token2 fees yet");

        OpenPuntFeeReceiver clone = OpenPuntFeeReceiver(receiver);
        assertEq(address(clone.ORACLE()), address(oracle), "ORACLE immutable");
        assertEq(clone.swapId(), p.swapId, "swapId arg");
        assertEq(clone.token1(), address(tokenA), "token1 arg");
        assertEq(clone.token2(), address(tokenB), "token2 arg");
        assertEq(clone.swapper(), swapper, "swapper arg");
        assertEq(clone.matcher(), matcher, "matcher arg");
    }

    function test_implementationItselfRejectsDistribute() public {
        address impl = punt.feeReceiverImpl();
        vm.expectRevert(OpenPuntFeeReceiver.NotClone.selector);
        OpenPuntFeeReceiver(impl).distribute();
    }

    /// @dev The module is not the deployer of core-created games, so a raw module call cannot
    ///      deploy a receiver for one: `oracleHelper.creator != address(this)`.
    function test_rawModuleCallCannotDeployForACoreCreatedGame() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);
        Game memory g = _gameOf(mt);
        (g,) = _disputeForToken1Fee(g, disputer);

        address predicted = _predictForPosition(p.swapId, mt.swap);

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        lifecycleModule.deployAndDistributeFeeReceiver(p.swapId, swapper, matcher, g.game, g.helper);

        assertEq(predicted.code.length, 0, "nothing deployed by the raw module call");
        assertEq(_spendable(predicted, address(tokenA)), FEE_PER_DISPUTE, "fees untouched");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Deployment is lazy but not conditional on fees existing
    // ══════════════════════════════════════════════════════════════════

    /// @dev A positive-fee game has a counterfactual receiver and both sentinel
    ///      slots from the moment it is created, before any dispute. Calling the routed function
    ///      at that point still deploys the clone and returns (receiver, 0, 0) without
    ///      emitting FeesDistributed. So deployment is lazy relative to match/report creation,
    ///      but it is not gated on fees having accrued.
    function test_deploymentBeforeAnyFeesAccrueStillCreatesTheClone() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);

        address predicted = _predictForPosition(p.swapId, mt.swap);
        assertEq(_spendable(predicted, address(tokenA)), 0, "no fees accrued yet");
        assertEq(_spendable(predicted, address(tokenB)), 0, "no fees accrued yet");

        FeeBook memory before = _feeBook(predicted, address(tokenA), address(tokenB));
        Game memory g = _gameOf(mt);
        (address receiver, uint256 fees1, uint256 fees2, Vm.Log[] memory logs) =
            _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(receiver, predicted, "returned the predicted address");
        assertGt(receiver.code.length, 0, "the clone was deployed despite there being no fees");
        assertEq(fees1, 0, "zero token1 fees");
        assertEq(fees2, 0, "zero token2 fees");
        assertFalse(_hasFeesDistributed(logs, receiver), "no FeesDistributed event when both are zero");

        // no beneficiary balance moved
        _assertDistributed(before, receiver, address(tokenA), address(tokenB), 0, 0, "empty distribution");
    }

    /// @dev And fees accrue normally to an already-deployed receiver.
    function test_feesAccrueNormallyToAnAlreadyDeployedReceiver() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);
        Game memory g = _gameOf(mt);

        // deploy first, with nothing to distribute
        (address receiver,,,) = _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);
        assertGt(receiver.code.length, 0, "clone exists");

        // then accrue for real
        uint256 fee;
        (g, fee) = _disputeForToken1Fee(g, disputer);
        assertEq(_spendable(receiver, address(tokenA)), fee, "the deployed clone accrued the fee");

        FeeBook memory before = _feeBook(receiver, address(tokenA), address(tokenB));
        (, uint256 fees1, uint256 fees2, Vm.Log[] memory logs) =
            _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(fees1, fee, "distributed the accrued fee");
        assertEq(fees2, 0, "nothing in token2");
        (uint256 e1, uint256 e2) = _readFeesDistributed(logs, receiver, p.swapId);
        assertEq(e1, fees1, "event fees1 matches the return value");
        assertEq(e2, fees2, "event fees2 matches the return value");
        _assertDistributed(before, receiver, address(tokenA), address(tokenB), fees1, fees2, "post-deploy accrual");
    }
}
