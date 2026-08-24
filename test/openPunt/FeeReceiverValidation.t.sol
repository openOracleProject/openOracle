// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./FeeReceiverBase.t.sol";

/**
 * @notice Binding and authentication failures for `deployAndDistributeFeeReceiver`.
 *
 * @dev Check order in the source is: helper creator, then the oracle hash, then the predicted
 *      recipient. So a tampered game or helper fails as WrongOracleHash, while a genuine game
 *      paired with the wrong (swapId, swapper, matcher) tuple fails as InvalidFeeReceiver.
 *
 *      There is no separate caller-supplied asset parameter: token1 and token2 come out of the
 *      authenticated oracle state, so tampering with them fails at the hash, not at the
 *      receiver-address comparison.
 */
contract FeeReceiverValidationTest is FeeReceiverBase {
    function setUp() public {
        _setUpFees();
    }

    struct Ctx {
        uint256 swapId;
        address receiver;
        Game g;
        uint256 fee;
    }

    /// @dev A position with a genuine accrued token1 fee, receiver still undeployed.
    function _accrued() internal returns (Ctx memory c) {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);
        c.swapId = p.swapId;
        c.receiver = _predictForPosition(p.swapId, mt.swap);
        c.g = _gameOf(mt);
        (c.g, c.fee) = _disputeForToken1Fee(c.g, disputer);
    }

    function _assertRejected(Ctx memory c, string memory what) internal view {
        assertEq(c.receiver.code.length, 0, string.concat(what, ": no clone deployed"));
        assertEq(_spendable(c.receiver, address(tokenA)), c.fee, string.concat(what, ": fees unmoved"));
        assertEq(_spendable(c.receiver, address(tokenB)), 0, string.concat(what, ": token2 unmoved"));
    }

    // ══════════════════════════════════════════════════════════════════
    //  Oracle-state authentication
    // ══════════════════════════════════════════════════════════════════

    function test_perturbedOracleGameRejects() public {
        Ctx memory c = _accrued();

        IOpenOracle2.OracleGame memory tampered = abi.decode(abi.encode(c.g.game), (IOpenOracle2.OracleGame));
        tampered.currentAmount2 = c.g.game.currentAmount2 + 1;

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongOracleHash.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(c.swapId, swapper, matcher, tampered, c.g.helper);
        _assertRejected(c, "tampered game");
    }

    /// @dev Tampering with an asset fails at the hash, not at the receiver comparison: the
    ///      oracle state is what authenticates token1 and token2.
    function test_perturbedAssetInTheOracleStateRejectsAtTheHash() public {
        Ctx memory c = _accrued();

        IOpenOracle2.OracleGame memory tampered = abi.decode(abi.encode(c.g.game), (IOpenOracle2.OracleGame));
        tampered.token2 = address(collat);

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongOracleHash.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(c.swapId, swapper, matcher, tampered, c.g.helper);
        _assertRejected(c, "tampered asset");
    }

    function test_perturbedHelperReportIdRejects() public {
        Ctx memory c = _accrued();

        IOpenOracle2.PreimageHelper memory h = abi.decode(abi.encode(c.g.helper), (IOpenOracle2.PreimageHelper));
        h.reportId = c.g.reportId + 1;

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongOracleHash.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(c.swapId, swapper, matcher, c.g.game, h);
        _assertRejected(c, "wrong report id");
    }

    function test_perturbedHelperCreatorRejects() public {
        Ctx memory c = _accrued();

        IOpenOracle2.PreimageHelper memory h = abi.decode(abi.encode(c.g.helper), (IOpenOracle2.PreimageHelper));
        h.creator = outsider;

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(c.swapId, swapper, matcher, c.g.game, h);
        _assertRejected(c, "wrong creator");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Tuple binding
    // ══════════════════════════════════════════════════════════════════

    function test_wrongSwapIdRejects() public {
        Ctx memory c = _accrued();

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(c.swapId + 1, swapper, matcher, c.g.game, c.g.helper);
        _assertRejected(c, "wrong swapId");
    }

    function test_wrongSwapperRejects() public {
        Ctx memory c = _accrued();

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(c.swapId, outsider, matcher, c.g.game, c.g.helper);
        _assertRejected(c, "wrong swapper");
    }

    function test_wrongMatcherRejects() public {
        Ctx memory c = _accrued();

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(c.swapId, swapper, outsider, c.g.game, c.g.helper);
        _assertRejected(c, "wrong matcher");
    }

    /// @dev Position A's oracle state paired with position B's swapId: the state authenticates,
    ///      but the derived receiver no longer matches the recipient the game committed.
    function test_crossingTwoPositionsRejects() public {
        Ctx memory a = _accrued();
        Ctx memory b = _accrued();
        assertTrue(a.swapId != b.swapId, "two distinct positions");
        assertTrue(a.receiver != b.receiver, "two distinct receivers");

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(b.swapId, swapper, matcher, a.g.game, a.g.helper);

        _assertRejected(a, "crossed positions: A");
        _assertRejected(b, "crossed positions: B");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Outside games and zero-fee games
    // ══════════════════════════════════════════════════════════════════

    /// @dev An outsider's own oracle report, even one configured with a plausible predicted
    ///      recipient, cannot be swept: its helper creator is the outsider, not the core.
    function test_outsiderCreatedGameRejects() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);
        address plausible = _predictForPosition(p.swapId, mt.swap);

        // an entirely independent oracle game created BY the outsider, naming that address
        // the outsider funds its own report: reporter == msg.sender, so no allowance is needed
        vm.startPrank(outsider);
        _mintAndDepositAs(tokenA, outsider, 100e18);
        _mintAndDepositAs(tokenB, outsider, 100e18);
        vm.stopPrank();

        IOpenOracle2.OracleGame memory params = IOpenOracle2.OracleGame({
            currentAmount1: OA1,
            currentAmount2: OA2,
            currentReporter: outsider,
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: address(tokenA),
            lastReportOppoTime: 0,
            settlementTime: 300,
            escalationHalt: 100e18,
            protocolFeeRecipient: plausible,
            settlerReward: 0,
            token2: address(tokenB),
            numReports: 0,
            disputeDelay: 5,
            feePercentage: 0,
            multiplier: 110,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: PROTO_FEE,
            flags: 1
        });

        vm.recordLogs();
        vm.prank(outsider);
        uint256 rogueId = IOpenOracle2(address(oracle)).report(params, true, true, _noTiming());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (IOpenOracle2.OracleGame memory rg, IOpenOracle2.PreimageHelper memory rh) =
            _decodeReportSubmitted(logs, rogueId);

        assertEq(rh.creator, outsider, "the rogue game's creator is the outsider");
        assertEq(rg.protocolFeeRecipient, plausible, "and it names the plausible receiver");

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(p.swapId, swapper, matcher, rg, rh);
        assertEq(plausible.code.length, 0, "no clone deployed from an outsider-created game");
    }

    function _mintAndDepositAs(MintableERC20 token, address who, uint128 amount) internal {
        token.mint(who, amount);
        token.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(token), amount, who);
    }

    function test_zeroProtocolFeeGameRejects() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _feeCfg(Legs.BothErc20, address(collat), 0);
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);
        Game memory g = _gameOf(mt);

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(p.swapId, swapper, matcher, g.game, g.helper);

        assertEq(_predictForPosition(p.swapId, mt.swap).code.length, 0, "nothing deployed");
    }

    function test_rawModuleCallRejects() public {
        Ctx memory c = _accrued();

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        lifecycleModule.deployAndDistributeFeeReceiver(c.swapId, swapper, matcher, c.g.game, c.g.helper);
        _assertRejected(c, "raw module call");
    }

    // ══════════════════════════════════════════════════════════════════
    //  After the clone exists
    // ══════════════════════════════════════════════════════════════════

    /// @dev A wrong tuple or state must not be able to trigger distribution from the valid clone.
    function test_wrongCallsStillRejectOnceTheCloneExists() public {
        Ctx memory c = _accrued();

        // deploy for real, then accrue again so there is something worth stealing
        _deployAndDistribute(c.swapId, swapper, matcher, c.g, outsider);
        assertGt(c.receiver.code.length, 0, "clone exists");
        uint256 newFee;
        (c.g, newFee) = _disputeForToken1Fee(c.g, disputer2);
        assertEq(_spendable(c.receiver, address(tokenA)), newFee, "fresh fees waiting");

        uint256 swapper1 = _spendable(swapper, address(tokenA));
        uint256 matcher1 = _spendable(matcher, address(tokenA));

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(c.swapId, outsider, matcher, c.g.game, c.g.helper);

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.InvalidFeeReceiver.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(c.swapId + 1, swapper, matcher, c.g.game, c.g.helper);

        IOpenOracle2.OracleGame memory tampered = abi.decode(abi.encode(c.g.game), (IOpenOracle2.OracleGame));
        tampered.currentAmount1 = c.g.game.currentAmount1 + 1;
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongOracleHash.selector);
        puntLifecycle.deployAndDistributeFeeReceiver(c.swapId, swapper, matcher, tampered, c.g.helper);

        assertEq(_spendable(c.receiver, address(tokenA)), newFee, "fees still sitting in the clone");
        assertEq(_spendable(swapper, address(tokenA)), swapper1, "swapper unchanged");
        assertEq(_spendable(matcher, address(tokenA)), matcher1, "matcher unchanged");

        // and the correct call still works
        (, uint256 fees1,,) = _deployAndDistribute(c.swapId, swapper, matcher, c.g, outsider);
        assertEq(fees1, newFee, "the genuine call distributes");
    }
}
