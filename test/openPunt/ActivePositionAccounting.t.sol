// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ActivePositionBase.t.sol";

/**
 * @notice Deterministic PnL / funding / fee matrix for active positions.
 *
 * @dev Every expected amount is a literal derived by hand in the accompanying comment.
 *      No test calls a copy of mulDivCapped or any production accounting helper.
 *      "R" is the token2/token1 ratio the swapper's orientation is defined against.
 */
contract ActivePositionAccountingTest is ActivePositionBase {
    function setUp() public {
        _setUpAccounting();
    }

    /// @dev Runs one complete case and returns the realised payouts, checking conservation.
    function _runClose(
        OpenPuntStorage.ProposedSwap memory s,
        OpenPuntStorage.MatcherPreimage memory m,
        uint128 a2Close,
        uint256 elapsed
    ) internal returns (uint256 owedSwapper, uint256 owedMatcher, uint256 marginSum) {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        marginSum = uint256(active.initialMarginSwapper) + active.initialMarginMatcher;

        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherInt0 = _spendable(matcher, address(collat));

        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, a2Close, elapsed);
        (owedSwapper, owedMatcher) = _readPositionClosed(logs, swapId);

        // conservation, event vs. realised balances, and terminal cleanliness
        assertEq(owedSwapper + owedMatcher, marginSum, "payouts conserve the margin pool");
        assertEq(collat.balanceOf(swapper) - swapperExt0, owedSwapper, "swapper delta matches the event");
        assertEq(_spendable(matcher, address(collat)) - matcherInt0, owedMatcher, "matcher delta matches the event");
        assertEq(punt.swaps(swapId), bytes32(0), "position hash deleted");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "close state cleared");
        assertFalse(intent, "close intent cleared");
        assertEq(_spendable(address(punt), address(collat)), 0, "core retains no position collateral");
    }

    // ══════════════════════════════════════════════════════════════════
    //  1. Price PnL matrix   (fee 0, funding 0)
    // ══════════════════════════════════════════════════════════════════
    //
    // pricePnl = |a2_close - a2_open|, since notional == a2_open.
    // a2 = 10_020e18 -> R up   by 20e18 -> pnl 20e18
    // a2 =  9_980e18 -> R down by 20e18 -> pnl 20e18
    // marginSum = 1000e18 + 1000e18 = 2000e18 (no opening fee in this configuration)

    uint128 internal constant A2_UP = 10_020e18;
    uint128 internal constant A2_DOWN = 9_980e18;
    uint128 internal constant PNL_20 = 20e18;

    function test_long_ratioUp_profits() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_UP, ELAPSED_STD);

        // equity = 1000e18 + 20e18
        assertEq(owedS, 1020e18, "long profits on R up");
        assertEq(owedM, 980e18, "matcher pays the swapper's gain");
    }

    function test_long_ratioDown_loses() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_DOWN, ELAPSED_STD);

        assertEq(owedS, 980e18, "long loses on R down");
        assertEq(owedM, 1020e18, "matcher collects the swapper's loss");
    }

    function test_long_ratioUnchanged_flat() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_OPEN, ELAPSED_STD);

        assertEq(owedS, 1000e18, "no movement, no PnL");
        assertEq(owedM, 1000e18, "matcher keeps its margin");
    }

    function test_short_ratioUp_loses() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = false;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_UP, ELAPSED_STD);

        assertEq(owedS, 980e18, "short loses on R up");
        assertEq(owedM, 1020e18, "matcher collects");
    }

    function test_short_ratioDown_profits() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = false;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_DOWN, ELAPSED_STD);

        assertEq(owedS, 1020e18, "short profits on R down");
        assertEq(owedM, 980e18, "matcher pays");
    }

    function test_short_ratioUnchanged_flat() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = false;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_OPEN, ELAPSED_STD);

        assertEq(owedS, 1000e18, "no movement, no PnL");
        assertEq(owedM, 1000e18, "matcher keeps its margin");
    }

    /// @dev Ordinary fractional movement: priceDelta is far below openingCross, so the
    ///      quotient is zero and the whole result comes from the fractional branch.
    ///      a2 = 10_000e18 + 7 -> pnl = 7 wei exactly.
    function test_fractionalMovementUsesTheSubUnitPath() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        uint256 priceDelta = uint256(A1) * 7; // |a2c - a2o| * a1
        uint256 openingCross = uint256(A2_OPEN) * A1;
        assertLt(priceDelta, openingCross, "priceDelta < openingCross: quotient is zero");

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_OPEN + 7, ELAPSED_STD);

        assertEq(owedS, 1000e18 + 7, "seven wei of movement is seven wei of PnL");
        assertEq(owedM, 1000e18 - 7, "matcher pays exactly seven wei");
    }

    // ══════════════════════════════════════════════════════════════════
    //  2. Funding   (flat price, fee 0)
    // ══════════════════════════════════════════════════════════════════
    //
    // fundingMagnitude = mulDiv(10_000e18, 1e6 * 315_360, 1e7 * 365 days) = 10e18

    function test_funding_positiveSwapperPaysMatcher() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(RATE_10PCT);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_OPEN, ELAPSED_STD);

        assertEq(owedS, 1000e18 - FUNDING_AMOUNT, "swapper paid funding");
        assertEq(owedM, 1000e18 + FUNDING_AMOUNT, "matcher received funding");
    }

    function test_funding_zeroMovesNothing() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_OPEN, ELAPSED_STD);

        assertEq(owedS, 1000e18, "no funding accrued");
        assertEq(owedM, 1000e18, "no funding accrued");
    }

    function test_funding_negativeMatcherPaysSwapper() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(-RATE_10PCT);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_OPEN, ELAPSED_STD);

        assertEq(owedS, 1000e18 + FUNDING_AMOUNT, "swapper received funding");
        assertEq(owedM, 1000e18 - FUNDING_AMOUNT, "matcher paid funding");
    }

    /// @dev Funding direction depends only on the rate's sign, never on orientation.
    function test_funding_directionIsIndependentOfOrientation() public {
        (OpenPuntStorage.ProposedSwap memory sLong, OpenPuntStorage.MatcherPreimage memory mLong) =
            _cfgZeroFee(RATE_10PCT);
        sLong.isLong = true;
        sLong.maturityWindow = MATURITY_SHORT;
        (uint256 longS, uint256 longM,) = _runClose(sLong, mLong, A2_OPEN, ELAPSED_STD);

        (OpenPuntStorage.ProposedSwap memory sShort, OpenPuntStorage.MatcherPreimage memory mShort) =
            _cfgZeroFee(RATE_10PCT);
        sShort.isLong = false;
        sShort.maturityWindow = MATURITY_SHORT;
        (uint256 shortS, uint256 shortM,) = _runClose(sShort, mShort, A2_OPEN, ELAPSED_STD);

        assertEq(longS, shortS, "positive funding debits the swapper either way");
        assertEq(longM, shortM, "positive funding credits the matcher either way");
        assertEq(longS, 1000e18 - FUNDING_AMOUNT, "and by exactly the derived amount");
    }

    /// @dev Doubling the elapsed time doubles the accrual.
    function test_funding_scalesWithElapsedTime() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(RATE_10PCT);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS,,) = _runClose(s, m, A2_OPEN, 2 * ELAPSED_STD);

        assertEq(owedS, 1000e18 - 2 * uint256(FUNDING_AMOUNT), "funding doubles with double the time");
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. Fees and combined accounting
    // ══════════════════════════════════════════════════════════════════

    /// @dev The fulfillment fee is charged once at open and once again at close.
    function test_fulfillmentFeeIsChargedAtOpenAndAgainAtClose() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgWithFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        uint256 matcherInt0 = _spendable(matcher, address(collat));
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);

        // opening fee: taken out of the swapper's margin, paid to the matcher
        assertEq(active.fulfillmentFee, FEE_BPS, "fee pinned by the degenerate auction");
        assertEq(active.initialMarginSwapper, MARGIN_S - FEE_AMOUNT, "opening fee deducted once");
        assertEq(
            _spendable(matcher, address(collat)),
            matcherInt0 - MARGIN_M + FEE_AMOUNT,
            "matcher received exactly the opening fee"
        );

        uint256 marginSum = uint256(active.initialMarginSwapper) + active.initialMarginMatcher; // 1990e18
        assertEq(marginSum, 1990e18, "pool shrank by the opening fee");

        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_OPEN, ELAPSED_STD);
        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);

        // flat price, zero funding: equity = 990e18 - 10e18
        assertEq(owedS, 980e18, "closing fee charged again");
        assertEq(owedM, 1010e18, "matcher collects the closing fee");
        assertEq(owedS + owedM, marginSum, "pool conserved");

        // matcher earned exactly two fees over the whole life of the position
        assertEq(
            _spendable(matcher, address(collat)), matcherInt0 + 2 * uint256(FEE_AMOUNT), "exactly two fees collected"
        );
    }

    /// @dev Profit offsets funding and the close fee.
    ///      openFee 10e18 -> margin 990e18, pool 1990e18
    ///      +pnl 20e18, -funding 10e18, -closeFee 10e18  => net 0
    function test_combined_effectsOffset() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgWithFee(RATE_10PCT);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM, uint256 marginSum) = _runClose(s, m, A2_UP, ELAPSED_STD);

        assertEq(marginSum, 1990e18, "pool after the opening fee");
        assertEq(owedS, 990e18, "gain exactly cancels funding plus the close fee");
        assertEq(owedM, 1000e18, "matcher back to its own margin");
    }

    /// @dev Loss reinforces funding and the close fee.
    ///      -pnl 20e18, -funding 10e18, -closeFee 10e18 => net -40e18
    function test_combined_effectsReinforce() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgWithFee(RATE_10PCT);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM, uint256 marginSum) = _runClose(s, m, A2_DOWN, ELAPSED_STD);

        assertEq(marginSum, 1990e18, "pool after the opening fee");
        assertEq(owedS, 950e18, "990e18 - 20e18 - 10e18 - 10e18");
        assertEq(owedM, 1040e18, "matcher collects loss, funding and fee");
    }

    /// @dev Negative funding reinforces a gain.
    ///      +pnl 20e18, +funding 10e18, -closeFee 10e18 => net +20e18
    function test_combined_negativeFundingReinforcesGain() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgWithFee(-RATE_10PCT);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 owedS, uint256 owedM,) = _runClose(s, m, A2_UP, ELAPSED_STD);

        assertEq(owedS, 1010e18, "990e18 + 20e18 + 10e18 - 10e18");
        assertEq(owedM, 980e18, "matcher pays gain and funding, keeps the fee");
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. Liquidation boundary   (maintenance 200e18, fee 0, funding 0)
    // ══════════════════════════════════════════════════════════════════
    //
    // equity = 1000e18 - |delta a2|.  equity == 200e18 needs a drop of exactly 800e18.

    uint128 internal constant A2_AT_MAINT = A2_OPEN - 800e18; // equity exactly 200e18
    uint128 internal constant A2_ONE_BELOW = A2_OPEN - 800e18 - 1; // equity 200e18 - 1

    function test_liquidation_equityExactlyAtMaintenanceIsHealthy() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_AT_MAINT, ELAPSED_STD);

        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "not liquidated at equality");
        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);
        assertEq(owedS, MAINT, "swapper keeps exactly the maintenance margin");
        assertEq(owedM, 2000e18 - MAINT, "matcher takes the rest");
    }

    function test_liquidation_oneUnitBelowMaintenanceLiquidates() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherInt0 = _spendable(matcher, address(collat));

        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_ONE_BELOW, ELAPSED_STD);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "liquidated one wei below");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "not a close");

        assertEq(collat.balanceOf(swapper), swapperExt0, "swapper receives nothing");
        assertEq(_spendable(matcher, address(collat)) - matcherInt0, 2000e18, "matcher takes the whole pool");
        assertEq(punt.swaps(swapId), bytes32(0), "position hash deleted");
        assertEq(_spendable(address(punt), address(collat)), 0, "core retains no position collateral");
    }

    /// @dev A mature but unhealthy position liquidates rather than closing.
    function test_liquidation_takesPrecedenceOverMaturity() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT; // long matured by report time

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        assertTrue(
            vm.getBlockTimestamp() + ELAPSED_STD >= active.maturity, "the position really is mature at execution"
        );

        uint256 matcherInt0 = _spendable(matcher, address(collat));
        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_ONE_BELOW, ELAPSED_STD);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "liquidation wins over maturity");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "no close event");
        assertEq(_spendable(matcher, address(collat)) - matcherInt0, 2000e18, "entire pool to the matcher");
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. Healthy report behaviour
    // ══════════════════════════════════════════════════════════════════

    function test_healthyAndMatureCloses() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_UP, ELAPSED_STD);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "closed on maturity");
        assertEq(punt.swaps(swapId), bytes32(0), "terminal");
    }

    /// @dev Healthy, pre-maturity, no close intent: a no-op report that only clears reportId.
    function test_healthyPreMaturityNoIntentEmitsLiquidationFailedAndIsReusable() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_LONG; // stays pre-maturity

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherInt0 = _spendable(matcher, address(collat));
        uint256 corePool0 = _spendable(address(punt), address(collat));

        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_UP, ELAPSED_STD);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "LiquidationFailed emitted");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "not closed");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "not liquidated");

        // The reusable report releases the sidecar without changing the active position hash.
        OpenPuntStorage.MatchedSwap memory after1 =
            _decodeSingleSwapState(logs, OpenPuntStorage.LiquidationFailed.selector, swapId);
        assertEq(punt.swapIdToReportId(swapId), 0, "reportId cleared");
        OpenPuntStorage.MatchedSwap memory expected = _copy(active);
        assertEq(keccak256(abi.encode(after1)), keccak256(abi.encode(expected)), "active state unchanged");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(expected)), "stored hash remains stable");

        // margins untouched
        assertEq(collat.balanceOf(swapper), swapperExt0, "swapper margin untouched");
        assertEq(_spendable(matcher, address(collat)), matcherInt0, "matcher margin untouched");
        assertEq(_spendable(address(punt), address(collat)), corePool0, "pool untouched");

        // and the position still works for a second real report that does close it
        vm.warp(uint256(after1.maturity));
        vm.roll(vm.getBlockNumber() + 1);
        openingReportTs = uint48(vm.getBlockTimestamp()) - uint48(SETTLE_HOP_SECONDS);

        Matched memory second =
            _reportOnPositionWithAmounts(swapId, _noDutch(), after1, p.preimage, reporter, REPORT_EXEC_COMP, A1, A2_UP);
        _advanceToSettlementEligibility();

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, second.swap, second.game, second.helper, false);

        assertTrue(
            _hasLog(vm.getRecordedLogs(), OpenPuntStorage.PositionClosed.selector, swapId),
            "second report closes the position"
        );
        assertEq(punt.swaps(swapId), bytes32(0), "terminal after the second report");
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. Payout conservation details
    // ══════════════════════════════════════════════════════════════════

    function test_oracleLegsReturnAndExecutionCompensationIsPaidOnce() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        uint256 reporterA0 = _spendable(reporter, address(tokenA));
        uint256 reporterB0 = _spendable(reporter, address(tokenB));
        uint256 reporterEth0 = _spendable(reporter, address(0));

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        (Vm.Log[] memory logs, uint256 reportId) = _reportAndExecute(swapId, active, p.preimage, A2_UP, ELAPSED_STD);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "closed");

        // the closing reporter posted both legs and got both back at settlement
        assertEq(_spendable(reporter, address(tokenA)), reporterA0, "leg1 returned to the reporter");
        assertEq(_spendable(reporter, address(tokenB)), reporterB0, "leg2 returned to the reporter");
        assertEq(_spendable(reporter, address(0)), reporterEth0 - REPORT_EXEC_COMP, "reporter funded the exec comp");

        // execution compensation paid exactly once, to the executor
        assertEq(punt.executionGasComp(reportId), 0, "comp drained");
        assertEq(_spendable(closeExecutor, address(0)), REPORT_EXEC_COMP, "executor paid exactly once");
        assertEq(_spendable(address(punt), address(0)), 0, "core keeps no internal ETH");
        assertEq(collat.balanceOf(address(punt)), 0, "core holds no external collateral");
    }
}
