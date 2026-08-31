// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice The oracle-state shapes `execute()` accepts and rejects when opening a position.
 *
 * @dev Every oracle state here originates from a real `report()` (decoded from its packed log)
 *      or a real `settle()`. Nothing hand-builds an oracle hash. Where a settled state is needed,
 *      the single field a settlement changes is applied to the decoded state and then verified
 *      against `oracle.oracleGame(reportId)` before use. Settlement emits no data, so applying
 *      the known transition is exactly what an indexer must do, and the equality check proves
 *      the result is the real committed state rather than a fabrication.
 */
contract OracleSettlementShapesTest is OpenPuntBase {
    function setUp() public {
        _setUpAll();
        collat.mint(swapper, 1_000_000e18);
        vm.deal(swapper, 100 ether);
        _mintAndDeposit(collat, matcher, 1_000_000e18);
        _mintAndDeposit(tokenA, matcher, 1_000e18);
        _mintAndDeposit(tokenB, matcher, 1_000_000e18);
    }

    function _matchedAndEligible() internal returns (Proposal memory p, Matched memory mt) {
        p = _propose();
        mt = _matchSwap(p);
        _advanceToSettlementEligibility();
    }

    /// @dev Applies the one field a real settlement changes, then proves the result is the
    ///      oracle's actual committed state.
    function _settledStateOf(Matched memory mt, uint48 settledAt)
        internal
        view
        returns (IOpenOracle2.OracleGame memory g)
    {
        g = abi.decode(abi.encode(mt.game), (IOpenOracle2.OracleGame));
        g.settlementTimestamp = settledAt; // block mode: a BLOCK NUMBER
        assertEq(
            oracle.oracleGame(mt.reportId),
            keccak256(abi.encode(g, mt.helper)),
            "reconstructed settled state is the oracle's real commitment"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  Accepted shapes
    // ══════════════════════════════════════════════════════════════════

    /// @dev Shape 1: nobody settled; execute() settles internally and forwards the reward.
    function test_unsettledPreimageIsSettledInternally() public {
        (, Matched memory mt) = _matchedAndEligible();
        bytes32 oracleHashBefore = oracle.oracleGame(mt.reportId);

        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);

        assertTrue(active.active, "position opened");
        assertTrue(oracle.oracleGame(mt.reportId) != oracleHashBefore, "oracle game was settled by execute");
        assertEq(_spendable(executor, address(0)), SETTLER_REWARD, "executor received the settler reward");
        assertEq(_spendable(settler, address(0)), 0, "nobody else settled");
        assertEq(punt.tempHolding(executor), OPEN_EXEC_COMP, "executor compensated");
    }

    /// @dev Shape 2: already settled out-of-band, and the exact settled preimage is supplied.
    function test_alreadySettledExactPreimageAccepted() public {
        (Proposal memory p, Matched memory mt) = _matchedAndEligible();

        uint48 settledAt = uint48(vm.getBlockNumber()); // block mode: settle() records the BLOCK NUMBER
        _settleDirect(mt, settler);
        assertEq(_spendable(settler, address(0)), SETTLER_REWARD, "external settler took the reward");

        IOpenOracle2.OracleGame memory settled = _settledStateOf(mt, settledAt);

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, settled, mt.helper, 0);
        OpenPuntStorage.MatchedSwap memory active =
            _decodeSingleSwapState(vm.getRecordedLogs(), OpenPuntStorage.PositionOpened.selector, p.swapId);

        assertTrue(active.active, "position opened from the settled preimage");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(active)), "stored hash tracks the opened state");
        assertEq(punt.tempHolding(executor), OPEN_EXEC_COMP, "executor still compensated");
        assertEq(_spendable(executor, address(0)), 0, "reward is not paid twice");
        assertEq(_spendable(settler, address(0)), SETTLER_REWARD, "reward stays with the actual settler");
    }

    /// @dev Shape 3: settle lands in the same block; one candidate is enough to recover it.
    function test_sameBlockSettlementRaceAcceptedWithOneCandidate() public {
        (Proposal memory p, Matched memory mt) = _matchedAndEligible();

        _settleDirect(mt, settler); // same block as the execute below

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 1);
        OpenPuntStorage.MatchedSwap memory active =
            _decodeSingleSwapState(vm.getRecordedLogs(), OpenPuntStorage.PositionOpened.selector, p.swapId);

        assertTrue(active.active, "opened through settlement lookback");
        assertEq(punt.tempHolding(executor), OPEN_EXEC_COMP, "executor compensated");
        assertEq(_spendable(executor, address(0)), 0, "no reward: the executor did not settle");
        assertEq(_spendable(settler, address(0)), SETTLER_REWARD, "reward stays with the actual settler");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Rejected shapes
    // ══════════════════════════════════════════════════════════════════

    function _assertExecuteRejects(
        uint256 swapId,
        OpenPuntStorage.MatchedSwap memory position,
        IOpenOracle2.OracleGame memory g,
        IOpenOracle2.PreimageHelper memory h,
        uint8 settlementTimestampSearchDepth,
        bytes4 err,
        string memory what
    ) internal {
        bytes32 storedBefore = punt.swaps(swapId);
        uint256 tempBefore = punt.tempHolding(executor);

        vm.prank(executor);
        vm.expectRevert(err);
        puntLifecycle.execute(swapId, position, g, h, settlementTimestampSearchDepth);

        assertEq(punt.swaps(swapId), storedBefore, string.concat(what, ": position unchanged"));
        assertEq(punt.tempHolding(executor), tempBefore, string.concat(what, ": executor uncompensated"));
    }

    function test_sameBlockSettlementRaceRejectedWithoutLookback() public {
        (Proposal memory p, Matched memory mt) = _matchedAndEligible();
        _settleDirect(mt, settler);

        _assertExecuteRejects(
            p.swapId,
            mt.swap,
            mt.game,
            mt.helper,
            0,
            PuntErrors.WrongOracleHash.selector,
            "same-block race without lookback"
        );
    }

    function test_oneBlockOldSettlementRequiresTwoCandidates() public {
        (Proposal memory p, Matched memory mt) = _matchedAndEligible();
        _settleDirect(mt, settler);

        _advanceChain(2); // settlement is now in a past block

        _assertExecuteRejects(
            p.swapId,
            mt.swap,
            mt.game,
            mt.helper,
            1,
            PuntErrors.WrongOracleHash.selector,
            "one candidate checks only the current block"
        );

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 2);
        OpenPuntStorage.MatchedSwap memory active =
            _decodeSingleSwapState(vm.getRecordedLogs(), OpenPuntStorage.PositionOpened.selector, p.swapId);
        assertTrue(active.active, "second candidate recovered the prior-block settlement");
    }

    function test_searchDepthAboveMaximumRejectsBeforeExecution() public {
        (Proposal memory p, Matched memory mt) = _matchedAndEligible();
        _assertExecuteRejects(
            p.swapId,
            mt.swap,
            mt.game,
            mt.helper,
            201,
            PuntErrors.InvalidSettlementLookback.selector,
            "search depth 201"
        );
    }

    function test_maximumSearchDepthFindsOldestIncludedCandidate() public {
        (Proposal memory p, Matched memory mt) = _matchedAndEligible();
        _settleDirect(mt, settler);

        _advanceChain(398); // settlement is 199 blocks old; depth 200 checks current through current - 199

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 200);
        OpenPuntStorage.MatchedSwap memory active =
            _decodeSingleSwapState(vm.getRecordedLogs(), OpenPuntStorage.PositionOpened.selector, p.swapId);
        assertTrue(active.active, "maximum search depth includes the 200th candidate");
    }

    function test_wrongHelperCreatorRejected() public {
        (Proposal memory p, Matched memory mt) = _matchedAndEligible();

        IOpenOracle2.PreimageHelper memory h = abi.decode(abi.encode(mt.helper), (IOpenOracle2.PreimageHelper));
        h.creator = outsider;

        _assertExecuteRejects(
            p.swapId, mt.swap, mt.game, h, 0, PuntErrors.WrongOracleHash.selector, "wrong helper creator"
        );
    }

    function test_wrongHelperReportIdRejected() public {
        (Proposal memory p, Matched memory mt) = _matchedAndEligible();

        IOpenOracle2.PreimageHelper memory h = abi.decode(abi.encode(mt.helper), (IOpenOracle2.PreimageHelper));
        h.reportId = mt.reportId + 1;

        _assertExecuteRejects(
            p.swapId, mt.swap, mt.game, h, 0, PuntErrors.InvalidReportId.selector, "wrong helper reportId"
        );
    }

    function test_wrongHelperBlockNumberRejected() public {
        (Proposal memory p, Matched memory mt) = _matchedAndEligible();

        IOpenOracle2.PreimageHelper memory h = abi.decode(abi.encode(mt.helper), (IOpenOracle2.PreimageHelper));
        h.blockNumber = mt.helper.blockNumber + 1;

        _assertExecuteRejects(
            p.swapId, mt.swap, mt.game, h, 0, PuntErrors.WrongOracleHash.selector, "wrong helper blockNumber"
        );
    }

    function test_wrongGameStateFieldsRejected() public {
        (Proposal memory p, Matched memory mt) = _matchedAndEligible();

        IOpenOracle2.OracleGame memory g1 = abi.decode(abi.encode(mt.game), (IOpenOracle2.OracleGame));
        g1.currentAmount2 = mt.game.currentAmount2 + 1; // a "better" price for the swapper
        _assertExecuteRejects(
            p.swapId, mt.swap, g1, mt.helper, 0, PuntErrors.WrongOracleHash.selector, "tampered amount2"
        );

        IOpenOracle2.OracleGame memory g2 = abi.decode(abi.encode(mt.game), (IOpenOracle2.OracleGame));
        g2.currentReporter = outsider;
        _assertExecuteRejects(
            p.swapId, mt.swap, g2, mt.helper, 0, PuntErrors.WrongOracleHash.selector, "tampered reporter"
        );

        IOpenOracle2.OracleGame memory g3 = abi.decode(abi.encode(mt.game), (IOpenOracle2.OracleGame));
        g3.settlerReward = mt.game.settlerReward + 1;
        _assertExecuteRejects(
            p.swapId, mt.swap, g3, mt.helper, 0, PuntErrors.WrongOracleHash.selector, "tampered settlerReward"
        );

        // ...and the genuine state still opens the position afterwards
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);
        assertTrue(active.active, "genuine state still works after every rejection");
    }

    /// @dev Executing against a live game before its settlement window closes is refused,
    ///      and the position is untouched.
    function test_executeBeforeSettlementEligibilityRejected() public {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);

        _advanceChain(SETTLE_HOP_SECONDS - 4); // still inside the settlement window

        _assertExecuteRejects(
            p.swapId,
            mt.swap,
            mt.game,
            mt.helper,
            0,
            PuntErrors.OracleSettlementNotEligible.selector,
            "before eligibility"
        );

        assertTrue(oracle.oracleGame(mt.reportId) != bytes32(0), "oracle game still unsettled");
    }
}
