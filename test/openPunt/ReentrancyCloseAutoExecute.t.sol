// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ReentrancyBase.t.sol";

/**
 * @notice Reentrancy boundaries created when `close()` first auto-executes an eligible report.
 *
 * @dev Terminal execution deletes the position before collateral delivery, then `close()` returns
 *      its unused call value. Reusable execution clears the old report before the ordinary
 *      fund-then-compare-and-commit auction path begins. These tests exercise those compositions
 *      through real token and ETH callbacks.
 */
contract ReentrancyCloseAutoExecuteTest is ReentrancyBase {
    struct AutoCloseCase {
        uint256 swapId;
        OpenPuntStorage.MatchedSwap active;
        OpenPuntStorage.MatcherPreimage preimage;
        Matched report;
    }

    function setUp() public {
        _setUpReentrancy();
    }

    function _case(bool hookCollateral, bool terminal) internal returns (AutoCloseCase memory c) {
        OpenPuntStorage.ProposedSwap memory s;
        OpenPuntStorage.MatcherPreimage memory m;
        if (hookCollateral) {
            (s, m) = _hookCfg();
        } else {
            (s, m) = _erc20Cfg();
        }
        s.maturityWindow = terminal ? 1 : MATURITY_LONG;

        uint128 amount2 = hookCollateral ? OA2 : A2_OPEN;
        Proposal memory p = _actorPropose(actor, s, m);
        Matched memory opening = _matchSwapWith(p, amount2, matcher);
        openingReportTs = opening.game.lastReportOppoTime;
        _advanceToSettlementEligibility();

        c.swapId = p.swapId;
        c.active = _executeOpening(opening, executor);
        c.preimage = p.preimage;

        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);
        c.report = _reportOnPositionWithAmounts(
            c.swapId, _noDutch(), c.active, c.preimage, reporter, REPORT_EXEC_COMP, A1, amount2
        );
        _advanceToSettlementEligibility();

        require(punt.swapIdToReportId(c.swapId) == c.report.reportId, "fixture: report not live");
        if (terminal) require(vm.getBlockTimestamp() >= c.active.maturity, "fixture: not mature");
    }

    function _closeData(AutoCloseCase memory c) internal view returns (bytes memory) {
        return abi.encodeCall(
            punt.close,
            (c.swapId, _dutchInput(), c.report.swap, false, _emptyPermit2(), CLOSE_COMP, c.report.game, c.report.helper)
        );
    }

    function _samePositionCloseData(AutoCloseCase memory c) internal view returns (bytes memory) {
        return abi.encodeCall(
            punt.close,
            (
                c.swapId,
                _dutchInput(),
                c.report.swap,
                false,
                _emptyPermit2(),
                0,
                _emptyOracleGame(),
                _emptyOracleHelper()
            )
        );
    }

    function test_terminalCollateralCallbackSeesThePositionAlreadyDeleted() public {
        AutoCloseCase memory c = _case(true, true);

        hookToken.resetHook();
        hookToken.armHook(address(actor), abi.encodeCall(actor.exec, (address(punt), 0, _samePositionCloseData(c))));

        actor.exec(address(punt), CLOSE_COMP, _closeData(c));
        hookToken.disarmHook();

        assertEq(hookToken.hookCount(), 1, "terminal collateral delivery called back once");
        assertFalse(hookToken.lastHookOk(), "same-position close unexpectedly succeeded");
        assertEq(hookToken.lastHookSelector(), PuntErrors.WrongHash.selector, "callback saw nonterminal state");
        assertEq(punt.swaps(c.swapId), bytes32(0), "position remains terminal");
        assertEq(punt.swapIdToReportId(c.swapId), 0, "report remains deleted");
        assertEq(punt.executionGasComp(c.report.reportId), 0, "execution compensation consumed once");
        _assertModuleClean(address(tokenA), address(tokenB), "auto-executed terminal collateral callback");
    }

    function test_tooExpensiveEthReentryFallsBackToOneRecoverableCredit() public {
        AutoCloseCase memory c = _case(false, true);
        uint256 actorEthBefore = address(actor).balance;
        uint256 coreEthBefore = address(punt).balance;
        uint256 tempBefore = punt.tempHolding(address(actor));

        actor.resetObservations();
        actor.arm(address(punt), _samePositionCloseData(c), 0);
        actor.exec(address(punt), CLOSE_COMP, _closeData(c));
        actor.disarm();

        // `payEth` deliberately caps this transition-time callback at 50k gas. The realistic
        // same-position payload cannot finish inside that cap, so its observation writes revert
        // with the failed receive. The value must still become one fully-backed fallback credit.
        assertEq(actor.callbackCount(), 0, "failed receive leaked callback state");
        assertEq(address(actor).balance, actorEthBefore - CLOSE_COMP, "failed push paid raw ETH anyway");
        assertEq(address(punt).balance, coreEthBefore + CLOSE_COMP, "fallback credit lacks exact backing");
        assertEq(punt.tempHolding(address(actor)) - tempBefore, CLOSE_COMP, "fallback credit counted incorrectly");
        assertEq(punt.swaps(c.swapId), bytes32(0), "position remains terminal");

        actor.exec(address(punt), 0, abi.encodeCall(punt.withdraw, (address(actor), false)));
        assertEq(address(actor).balance, actorEthBefore, "credit did not return the failed push exactly once");
        assertEq(address(punt).balance, coreEthBefore, "core retained credit backing after withdrawal");
        assertEq(punt.tempHolding(address(actor)), 0, "credit remained after withdrawal");
    }

    function test_unrelatedCancellationDuringTerminalDeliveryMatchesSequentialExecution() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _hookCfg();
        Proposal memory unrelated = _actorPropose(actor, s, m);
        AutoCloseCase memory c = _case(true, true);
        bytes memory cancelUnrelated =
            abi.encodeCall(punt.cancelSwapOpen, (unrelated.swapId, unrelated.swap, unrelated.preimage));

        uint256 snap = vm.snapshotState();

        actor.exec(address(punt), 0, cancelUnrelated);
        actor.exec(address(punt), CLOSE_COMP, _closeData(c));
        bytes32 sequentialLedgers = keccak256(abi.encode(_ledgers(address(hookToken))));
        uint256 sequentialNextSwapId = punt.nextSwapId();

        vm.revertToState(snap);

        hookToken.resetHook();
        hookToken.armHook(address(actor), abi.encodeCall(actor.exec, (address(punt), 0, cancelUnrelated)));
        actor.exec(address(punt), CLOSE_COMP, _closeData(c));
        hookToken.disarmHook();

        assertEq(hookToken.hookCount(), 1, "terminal collateral delivery called back once");
        assertTrue(hookToken.lastHookOk(), "unrelated cancellation failed during delivery");
        assertEq(punt.swaps(unrelated.swapId), bytes32(0), "unrelated proposal stayed cancelled");
        assertEq(punt.swaps(c.swapId), bytes32(0), "auto-executed position stayed terminal");
        assertEq(
            keccak256(abi.encode(_ledgers(address(hookToken)))),
            sequentialLedgers,
            "composed ledgers differ from sequential execution"
        );
        assertEq(punt.nextSwapId(), sequentialNextSwapId, "global id state differs from sequential execution");
    }

    function test_reusableAutoExecutionThenNestedReportRollsBackAtomically() public {
        AutoCloseCase memory c = _case(true, false);
        Phase memory beforePhase = _phase(c.swapId, c.report.reportId);
        Ledgers memory beforeLedgers = _ledgers(address(hookToken));

        bytes memory nestedReport = abi.encodeCall(
            puntLifecycle.report,
            (c.swapId, bytes32(0), c.active, c.preimage, _noTiming(), address(actor), A1, OA2, REPORT_EXEC_COMP)
        );
        hookToken.resetHook();
        hookToken.armHook(address(actor), abi.encodeCall(actor.exec, (address(punt), 0, nestedReport)));

        vm.expectRevert(PuntErrors.WrongHash.selector);
        actor.exec(address(punt), CLOSE_COMP, _closeData(c));
        hookToken.disarmHook();

        _assertPhaseUnchanged(beforePhase, c.swapId, c.report.reportId, "auto-execute/report rollback");
        _assertLedgersUnchanged(beforeLedgers, address(hookToken), "auto-execute/report rollback");
        assertEq(hookToken.hookCount(), 0, "callback bookkeeping did not roll back");
        assertEq(_storedDutchState(c.swapId), bytes32(0), "no future auction survived");
        assertEq(punt.closeRequestBlock(c.swapId), 0, "no future request survived");
        _assertModuleClean(address(tokenA), address(tokenB), "auto-execute/report rollback");
    }

    function test_rejectedUnusedCallValueCreatesOneRecoverableCredit() public {
        AutoCloseCase memory c = _case(false, true);
        uint256 actorEthBefore = address(actor).balance;
        uint256 coreEthBefore = address(punt).balance;
        uint256 tempBefore = punt.tempHolding(address(actor));

        actor.setRejectEth(true);
        actor.exec(address(punt), CLOSE_COMP, _closeData(c));
        actor.setRejectEth(false);

        assertEq(address(actor).balance, actorEthBefore - CLOSE_COMP, "failed push paid raw ETH anyway");
        assertEq(address(punt).balance, coreEthBefore + CLOSE_COMP, "credit is backed once by core ETH");
        assertEq(punt.tempHolding(address(actor)) - tempBefore, CLOSE_COMP, "one fallback credit created");
        assertEq(punt.swaps(c.swapId), bytes32(0), "terminal execution persisted");

        actor.exec(address(punt), 0, abi.encodeCall(punt.withdraw, (address(actor), false)));
        assertEq(address(actor).balance, actorEthBefore, "credit withdrew exactly the failed call value");
        assertEq(address(punt).balance, coreEthBefore, "core released the complete backing");
        assertEq(punt.tempHolding(address(actor)), 0, "credit consumed once");
    }
}
