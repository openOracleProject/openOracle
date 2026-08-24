// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./TokenCompatBase.t.sol";

/**
 * @notice USDT-style empty-return ERC20 used as position collateral, across the externally
 *         funded route and one internal-ledger smoke lifecycle.
 *
 * @dev The interesting semantic branches are (a) OpenOracle's `pushOrCredit`, which must treat a
 *      successful empty-return `transfer()` as success rather than falling back to an internal
 *      credit, and (b) plain internal ledger movement, which never touches the token at all.
 *      A four-way matrix would add no branch coverage.
 */
contract NoReturnCollateralTest is TokenCompatBase {
    uint128 internal constant CLOSE_REWARD = 50e18;

    function setUp() public {
        _setUpTokenCompat();

        // swapper funds externally through Permit2; matcher posts margin from the oracle ledger
        _nrtMint(swapper, 1_000_000e18);
        _nrtApprovePermit2(swapper);
        _nrtDeposit(matcher, 1_000_000e18);
        _nrtApproveInternal(matcher);
    }

    function _cfg(bool internalPos)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        return _tokenCfg(address(tokenA), address(tokenB), address(nrt), internalPos);
    }

    // ══════════════════════════════════════════════════════════════════
    //  External route: propose -> match -> open -> close auction -> close
    // ══════════════════════════════════════════════════════════════════

    function test_externalLifecycleWithNoReturnCollateral() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfg(false);
        s.maturityWindow = 1; // mature by the closing execution

        uint256 swapperExt0 = nrt.balanceOf(swapper);
        uint256 matcherInt0 = _spendable(matcher, address(nrt));
        uint256 oracleCustody0 = nrt.balanceOf(address(oracle));
        uint256 permitCalls0 = _permit2().callCount();

        // ── propose: pulled through the recording Permit2 ────────────────
        Proposal memory p = _proposeWith(s, m, swapper);

        assertEq(_permit2().callCount(), permitCalls0 + 1, "Permit2 transported the no-return token");
        assertEq(_permit2().lastCall().permittedToken, address(nrt), "the recorder saw the no-return token");
        assertEq(nrt.balanceOf(swapper), swapperExt0 - MARGIN_S, "swapper external balance debited");
        assertEq(nrt.balanceOf(address(oracle)) - oracleCustody0, MARGIN_S, "the oracle custodies the tokens");
        assertEq(_spendable(address(punt), address(nrt)), MARGIN_S, "core credited the margin internally");
        assertEq(nrt.balanceOf(address(punt)), 0, "core holds no external collateral");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(p.swap, p.preimage)), "stored proposal hash");

        // ── match and open ───────────────────────────────────────────────
        Matched memory mt = _matchSwapWith(p, OA2, matcher);
        assertEq(
            _spendable(matcher, address(nrt)), matcherInt0 - MARGIN_M, "matcher margin taken from the oracle ledger"
        );
        assertEq(
            _spendable(address(punt), address(nrt)),
            uint256(MARGIN_S) + MARGIN_M,
            "core holds both margins in the no-return token"
        );

        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);
        assertTrue(active.active, "opened");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(active)), "stored active hash");

        // ── close auction funded externally through the close Permit2 path ─
        uint256 permitBeforeClose = _permit2().callCount();
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        input.maxReward = CLOSE_REWARD;
        input.startingReward = 10e18;
        input.expiration = uint48(vm.getBlockTimestamp() + 1 hours);

        OpenPuntStorage.CloseDutch memory d = _startAuction(p.swapId, active, input, false, CLOSE_COMP);
        assertEq(_permit2().callCount(), permitBeforeClose + 1, "close reward pulled through Permit2");
        assertEq(_permit2().lastCall().permittedToken, address(nrt), "in the no-return token");
        assertEq(_storedAuctionHash(p.swapId, active), keccak256(abi.encode(d)), "auction stored");
        assertEq(
            _spendable(address(punt), address(nrt)),
            uint256(MARGIN_S) + MARGIN_M + CLOSE_REWARD,
            "core holds margins plus the reward escrow"
        );

        // ── report claims the reward at round 1, then closes ─────────────
        uint256 reporterInt0 = _spendable(reporter, address(nrt));
        uint256 swapperInt0 = _spendable(swapper, address(nrt));
        uint256 swapperExtBeforeClaim = nrt.balanceOf(swapper);
        _advanceTimeAndBlocks(60, 30);

        Matched memory closing =
            _reportOnPositionWithAmounts(p.swapId, d, active, p.preimage, reporter, 0, OA1, A2_CLOSE_UP);

        assertEq(_spendable(reporter, address(nrt)) - reporterInt0, 15e18, "reporter reward in the ledger");
        assertEq(_spendable(swapper, address(nrt)), swapperInt0, "external route leaves the ledger unchanged");
        assertEq(
            nrt.balanceOf(swapper) - swapperExtBeforeClaim, CLOSE_REWARD - 15e18, "remainder pushed to the swapper"
        );

        uint256 swapperExtBeforeClose = nrt.balanceOf(swapper);
        uint256 matcherIntBeforeClose = _spendable(matcher, address(nrt));

        _advanceToSettlementEligibility();
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, closing.game, closing.helper, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, p.swapId);
        assertEq(owedS + owedM, uint256(MARGIN_S) + MARGIN_M, "pool conserved");
        assertEq(owedS, EXPECTED_OWED_SWAPPER, "hand-derived swapper entitlement");
        assertEq(owedM, EXPECTED_OWED_MATCHER, "hand-derived matcher entitlement");

        // external delivery of the no-return token to the swapper really happened
        assertEq(nrt.balanceOf(swapper) - swapperExtBeforeClose, owedS, "swapper paid externally in the token");
        assertEq(_spendable(matcher, address(nrt)) - matcherIntBeforeClose, owedM, "matcher paid into its ledger");

        assertEq(punt.swaps(p.swapId), bytes32(0), "position deleted");
        (uint128 pending,, bool intent) = _closeState(p.swapId);
        assertEq(pending, 0, "close state cleared");
        assertFalse(intent, "close state cleared");
        assertEq(_spendable(address(punt), address(nrt)), 0, "core drained of collateral");
        assertEq(nrt.balanceOf(address(punt)), 0, "core holds no external collateral");
        _assertModuleHoldsNothing(address(tokenA), address(tokenB), "no-return external lifecycle");
        assertEq(_spendable(address(lifecycleModule), address(nrt)), 0, "module holds no collateral");
    }

    // ══════════════════════════════════════════════════════════════════
    //  pushOrCredit must treat an empty-return transfer as success
    // ══════════════════════════════════════════════════════════════════

    /// @dev The decisive case for a USDT-style token: a proposal cancellation refunds the margin
    ///      through `oracle.pushOrCredit`, whose fallback would create an internal
    ///      credit if it mistook empty return data for failure. The refund must land externally,
    ///      and the swapper's oracle ledger must be untouched.
    function test_cancellationRefundsExternallyAndCreatesNoFallbackCredit() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfg(false);

        uint256 swapperExt0 = nrt.balanceOf(swapper);
        uint256 swapperInt0 = _spendable(swapper, address(nrt));

        Proposal memory p = _proposeWith(s, m, swapper);
        assertEq(nrt.balanceOf(swapper), swapperExt0 - MARGIN_S, "margin paid in");

        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);

        assertEq(nrt.balanceOf(swapper), swapperExt0, "margin refunded EXTERNALLY, in full");
        assertEq(
            _spendable(swapper, address(nrt)),
            swapperInt0,
            "no internal fallback credit: the empty-return transfer was treated as success"
        );
        assertEq(punt.swaps(p.swapId), bytes32(0), "proposal deleted");
        assertEq(_spendable(address(punt), address(nrt)), 0, "core drained");
        assertEq(nrt.balanceOf(address(punt)), 0, "core holds nothing externally");
    }

    /// @dev Same property on the opening-refund path: a failed opening returns the margin
    ///      externally rather than as a fallback credit.
    function test_openingRefundDeliversExternallyWithNoFallbackCredit() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfg(false);
        s.priceTolerated = 2 * uint232(OPT); // guaranteed slippage bailout
        s.toleranceRange = 1;

        uint256 swapperExt0 = nrt.balanceOf(swapper);
        uint256 swapperInt0 = _spendable(swapper, address(nrt));
        uint256 matcherInt0 = _spendable(matcher, address(nrt));

        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasBailoutLog(logs, OpenPuntStorage.SlippageBailout.selector, p.swapId), "opening bailed out");
        assertEq(nrt.balanceOf(swapper), swapperExt0, "swapper margin refunded externally");
        assertEq(_spendable(swapper, address(nrt)), swapperInt0, "and NOT as an internal fallback credit");
        assertEq(_spendable(matcher, address(nrt)), matcherInt0, "matcher margin returned to its ledger");
        assertEq(punt.swaps(p.swapId), bytes32(0), "position deleted");
        assertEq(_spendable(address(punt), address(nrt)), 0, "core drained");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Internal-ledger smoke lifecycle
    // ══════════════════════════════════════════════════════════════════

    /// @dev Internal funding never touches the token contract: the whole movement is oracle
    ///      ledger arithmetic. One lifecycle plus a real transition is enough.
    function test_internalLedgerLifecycleWithNoReturnCollateral() public {
        _nrtDeposit(swapper, 500_000e18);
        _nrtApproveInternal(swapper);

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfg(true);
        s.maturityWindow = 1;

        uint256 swapperExt0 = nrt.balanceOf(swapper);
        uint256 swapperInt0 = _spendable(swapper, address(nrt));
        uint256 permitCalls0 = _permit2().callCount();

        Proposal memory p = _proposeWith(s, m, swapper);
        assertEq(_permit2().callCount(), permitCalls0, "internal funding never calls Permit2");
        assertEq(_spendable(swapper, address(nrt)), swapperInt0 - MARGIN_S, "margin taken from the ledger");
        assertEq(nrt.balanceOf(swapper), swapperExt0, "external balance untouched");

        Matched memory mt = _matchSwapWith(p, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);
        assertTrue(active.active, "opened");

        uint256 matcherIntBefore2 = _spendable(matcher, address(nrt));
        Matched memory closing =
            _reportOnPositionWithAmounts(p.swapId, _noDutch(), active, p.preimage, reporter, 0, OA1, A2_CLOSE_UP);
        _advanceToSettlementEligibility();

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, closing.game, closing.helper, false);
        (uint256 owedS, uint256 owedM) = _readPositionClosed(vm.getRecordedLogs(), p.swapId);
        assertEq(owedS, EXPECTED_OWED_SWAPPER, "hand-derived swapper entitlement");
        assertEq(_spendable(matcher, address(nrt)) - matcherIntBefore2, owedM, "matcher paid its own entitlement");

        assertEq(_spendable(swapper, address(nrt)), swapperInt0 - MARGIN_S + owedS, "payout returned to the ledger");
        assertEq(nrt.balanceOf(swapper), swapperExt0, "external balance still untouched");
        assertEq(punt.swaps(p.swapId), bytes32(0), "position deleted");
        assertEq(_spendable(address(punt), address(nrt)), 0, "core drained");
    }
}
