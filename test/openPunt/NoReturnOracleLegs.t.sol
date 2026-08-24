// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./TokenCompatBase.t.sol";
import {Errors as OracleErrors} from "../../src/libraries/Errors.sol";

/**
 * @notice A USDT-style empty-return ERC20 used as each oracle leg in turn.
 *
 * @dev Economics are flat and hand-derivable (both legs 1e18, zero fee, zero funding) so these
 *      tests isolate token behavior rather than re-testing PnL. Each settled leg must return to
 *      the designated oracle reporter rather than the funder, the
 *      core, or the module — and that the settled leg can then be withdrawn externally through
 *      the real `oracle.withdraw` entry point.
 */
contract NoReturnOracleLegsTest is TokenCompatBase {
    address internal designated = address(0x8201);

    function setUp() public {
        _setUpTokenCompat();

        // everyone who may post a no-return leg
        _nrtDeposit(matcher, 1_000_000e18);
        _nrtApproveInternal(matcher);
        _nrtDeposit(reporter, 1_000_000e18);
        _nrtApproveInternal(reporter);
        _nrtDeposit(adapter, 1_000_000e18);
        _nrtApproveInternal(adapter);

        // designated reporter: allowances only, deliberately no balances
        vm.startPrank(designated);
        oracle.approveInternal(address(punt), address(nrt), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev `nrtIsToken1` selects the orientation; collateral stays a vanilla ERC20 so this file
    ///      isolates the oracle-leg asset only.
    function _cfgFor(bool nrtIsToken1)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        return nrtIsToken1
            ? _tokenCfg(address(nrt), address(tokenB), address(collat), false)
            : _tokenCfg(address(tokenA), address(nrt), address(collat), false);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Both orientations, opening and active reports
    // ══════════════════════════════════════════════════════════════════

    function _runOrientation(bool nrtIsToken1) internal {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgFor(nrtIsToken1);
        address t1 = s.oracleToken1;
        address t2 = s.oracleToken2;
        address other = nrtIsToken1 ? t2 : t1;

        uint256 matcherNrt0 = _spendable(matcher, address(nrt));
        uint256 matcherOther0 = _spendable(matcher, other);

        // ── opening report ───────────────────────────────────────────────
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, OA2, matcher);

        assertEq(mt.game.token1, t1, "game token1");
        assertEq(mt.game.token2, t2, "game token2");
        assertEq(_spendable(matcher, address(nrt)), matcherNrt0 - OA1, "matcher posted the no-return leg");
        assertEq(_spendable(matcher, other), matcherOther0 - OA2, "matcher posted the vanilla leg");

        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);
        assertTrue(active.active, "opened");

        // Settlement returned both legs to the opening reporter.
        assertEq(_spendable(matcher, address(nrt)), matcherNrt0, "no-return leg returned to the matcher");
        assertEq(_spendable(matcher, other), matcherOther0, "vanilla leg returned to the matcher");
        assertEq(_spendable(address(punt), address(nrt)), 0, "core holds no oracle leg");
        assertEq(nrt.balanceOf(address(punt)), 0, "core holds no external leg");
        _assertModuleHoldsNothing(t1, t2, "no-return leg opening");

        // ── active-position report ───────────────────────────────────────
        uint256 reporterNrt0 = _spendable(reporter, address(nrt));
        uint256 reporterOther0 = _spendable(reporter, other);

        Matched memory closing =
            _reportOnPositionWithAmounts(p.swapId, _noDutch(), active, p.preimage, reporter, 0, OA1, OA2);
        assertEq(_spendable(reporter, address(nrt)), reporterNrt0 - OA1, "reporter posted the no-return leg");

        _advanceToSettlementEligibility();
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, closing.game, closing.helper, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, p.swapId), "reusable, pre-maturity");

        assertEq(_spendable(reporter, address(nrt)), reporterNrt0, "no-return leg returned to the REPORTER");
        assertEq(_spendable(reporter, other), reporterOther0, "vanilla leg returned to the reporter");
        assertEq(_spendable(matcher, address(nrt)), matcherNrt0, "the matcher gained nothing from this report");
        assertEq(_spendable(address(punt), address(nrt)), 0, "core holds no oracle leg");
        _assertModuleHoldsNothing(t1, t2, "no-return leg active report");

        // ── withdraw the settled no-return leg externally, for real ──────
        uint256 extBefore = nrt.balanceOf(reporter);
        uint256 intBefore = _spendable(reporter, address(nrt));
        vm.prank(reporter);
        uint256 sent = oracle.withdraw(address(nrt), uint128(OA1));

        assertEq(sent, OA1, "withdrawal reported the exact amount");
        assertEq(nrt.balanceOf(reporter) - extBefore, OA1, "recipient's external token balance grew");
        assertEq(_spendable(reporter, address(nrt)), intBefore - OA1, "and the ledger fell by the same");
    }

    function test_noReturnTokenAsOracleToken1() public {
        _runOrientation(true);
    }

    function test_noReturnTokenAsOracleToken2() public {
        _runOrientation(false);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Delegated reporter with a no-return leg
    // ══════════════════════════════════════════════════════════════════

    /// @dev The funder supplies the no-return leg, but the designated reporter is the oracle
    ///      reporter and is who settlement pays. Funder, designated reporter, core, module and
    ///      the oracle custodian are accounted for separately.
    function test_delegatedReporterWithANoReturnLeg() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgFor(true);
        address other = s.oracleToken2;

        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);

        uint256 adapterNrt0 = _spendable(adapter, address(nrt));
        uint256 adapterOther0 = _spendable(adapter, other);
        uint256 custody0 = nrt.balanceOf(address(oracle));
        assertEq(_spendable(designated, address(nrt)), 0, "designated reporter starts empty");

        vm.recordLogs();
        vm.prank(adapter);
        puntLifecycle.report(p.swapId, bytes32(0), active, p.preimage, _noTiming(), designated, OA1, OA2, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        OpenPuntStorage.MatchedSwap memory after1 =
            _decodeSingleSwapState(logs, OpenPuntStorage.PositionReportStarted.selector, p.swapId);
        uint256 reportId = punt.swapIdToReportId(p.swapId);
        (IOpenOracle2.OracleGame memory g, IOpenOracle2.PreimageHelper memory h) =
            _decodeReportSubmitted(logs, reportId);

        assertEq(g.currentReporter, designated, "the designated address is the oracle reporter");
        assertEq(_spendable(adapter, address(nrt)), adapterNrt0 - OA1, "the funder supplied the no-return leg");
        assertEq(_spendable(adapter, other), adapterOther0 - OA2, "and the vanilla leg");
        assertEq(_spendable(designated, address(nrt)), 0, "no residue passed through the designated reporter");
        assertEq(nrt.balanceOf(address(oracle)), custody0, "custody unchanged: the move was ledger-internal");

        // settle through a real execution and confirm who is paid
        Matched memory closing;
        closing.swapId = p.swapId;
        closing.swap = after1;
        closing.reportId = reportId;
        closing.game = g;
        closing.helper = h;

        _advanceToSettlementEligibility();
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, closing.game, closing.helper, false);

        assertEq(_spendable(designated, address(nrt)), OA1, "settlement paid the no-return leg to the REPORTER");
        assertEq(_spendable(designated, other), OA2, "and the vanilla leg too");
        assertEq(_spendable(adapter, address(nrt)), adapterNrt0 - OA1, "the funder does NOT get the leg back");
        assertEq(_spendable(address(punt), address(nrt)), 0, "core holds nothing");
        _assertModuleHoldsNothing(address(nrt), other, "delegated no-return leg");

        // and the designated reporter can take it out externally
        vm.prank(designated);
        uint256 sent = oracle.withdraw(address(nrt), uint128(OA1));
        assertEq(sent, OA1, "withdrew the settled leg");
        assertEq(nrt.balanceOf(designated), OA1, "external balance received");
    }
}
