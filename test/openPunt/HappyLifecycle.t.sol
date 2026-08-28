// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice One complete, real end-to-end position:
 *
 *         propose -> matchSwap -> opening game settles -> opening execute
 *              -> close() -> report() claims the Dutch reward
 *              -> closing game settles -> closing execute
 *
 *         ERC20 collateral, two ERC20 oracle legs, zero protocol fee, zero funding,
 *         unchanged opening-to-closing price, nonzero fulfillment fee, and distinct
 *         swapper / matcher / reporter / executors.
 *
 *         All expected economics below are derived by hand in this file, not by
 *         re-running the contract's own arithmetic.
 *
 * @dev Phase artifacts and baselines live in storage: the path touches far more
 *      live values than one stack frame can hold under via-IR.
 */
contract HappyLifecycleTest is OpenPuntBase {
    // ── independently derived expectations ──────────────────────────────
    //
    // Matched in the same block as propose, so zero fee-auction rounds elapse and
    // the fulfillment fee is exactly the auction's starting value.
    uint24 internal constant EXPECTED_FEE = uint24(uint32(FEE_AUCTION_START)); // 10_000 == 0.1%
    // notional * fee / 1e7 = 10_000e18 * 10_000 / 1e7 = 10e18
    uint128 internal constant EXPECTED_OPEN_FEE = 10e18;
    // Reported in the same block as close(), so zero Dutch rounds elapse.
    uint128 internal constant EXPECTED_DUTCH_REWARD = DUTCH_STARTING_REWARD; // 10e18
    uint128 internal constant EXPECTED_DUTCH_LEFTOVER = DUTCH_MAX_REWARD - DUTCH_STARTING_REWARD; // 40e18

    uint128 internal constant EXPECTED_MARGIN_SWAPPER_OPEN = INITIAL_MARGIN_SWAPPER - EXPECTED_OPEN_FEE; // 990e18
    uint256 internal constant EXPECTED_MARGIN_SUM = uint256(INITIAL_MARGIN_MATCHER) + EXPECTED_MARGIN_SWAPPER_OPEN; // 1990e18
    // zero funding + unchanged price => the opening margins return unchanged
    uint256 internal constant EXPECTED_OWED_SWAPPER = EXPECTED_MARGIN_SWAPPER_OPEN; // 990e18
    uint256 internal constant EXPECTED_OWED_MATCHER = EXPECTED_MARGIN_SUM - EXPECTED_OWED_SWAPPER; // 1000e18

    uint256 internal constant EXPECTED_TOTAL_ETH_IN = uint256(MATCHER_GAS_COMP) + SETTLER_REWARD + OPEN_EXEC_COMP;
    uint256 internal constant EXPECTED_CLOSING_COMP = uint256(CLOSE_EXEC_COMP) + REPORT_EXEC_COMP;

    // ── baselines ───────────────────────────────────────────────────────
    struct Baseline {
        uint256 swapperCollatExt;
        uint256 matcherCollatInt;
        uint256 matcherAInt;
        uint256 matcherBInt;
        uint256 reporterAInt;
        uint256 reporterBInt;
        uint256 reporterEthInt;
    }

    Baseline internal b;

    // ── phase artifacts (real values, produced by real calls) ───────────
    Proposal internal prop;
    Matched internal openingGame;
    Matched internal closingGame;
    OpenPuntStorage.MatchedSwap internal activeSwap;
    OpenPuntStorage.CloseDutch internal dutch;

    uint256 internal swapId;
    uint48 internal matchTs;
    uint48 internal openingReportTs;

    function setUp() public {
        _setUpAll();
        b = Baseline({
            swapperCollatExt: collat.balanceOf(swapper),
            matcherCollatInt: _spendable(matcher, address(collat)),
            matcherAInt: _spendable(matcher, address(tokenA)),
            matcherBInt: _spendable(matcher, address(tokenB)),
            reporterAInt: _spendable(reporter, address(tokenA)),
            reporterBInt: _spendable(reporter, address(tokenB)),
            reporterEthInt: _spendable(reporter, address(0))
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Full path with per-phase assertions
    // ═══════════════════════════════════════════════════════════════════

    function test_happyLifecycle() public {
        _phase1Propose();
        _phase2Match();
        _phase3OpeningExecute();
        _phase4Close();
        _phase5Report();
        _phase6ClosingExecute();
        _finalLedgerReconciliation();
    }

    // ── phase 1: propose ────────────────────────────────────────────────

    function _phase1Propose() internal {
        prop = _propose();
        swapId = prop.swapId;

        assertEq(punt.swaps(swapId), keccak256(abi.encode(prop.swap, prop.preimage)), "P1 stored proposal hash");
        assertTrue(punt.swaps(swapId) != bytes32(0), "P1 swap is live");
        assertEq(punt.nextSwapId(), swapId + 1, "P1 swapId sequence");
        assertEq(collat.balanceOf(swapper), b.swapperCollatExt - INITIAL_MARGIN_SWAPPER, "P1 swapper paid margin");
        assertEq(_spendable(address(punt), address(collat)), INITIAL_MARGIN_SWAPPER, "P1 punt holds swapper margin");
        assertEq(collat.balanceOf(address(punt)), 0, "P1 no external collat on punt");
        assertEq(address(punt).balance, EXPECTED_TOTAL_ETH_IN, "P1 punt holds all ETH comps");
    }

    // ── phase 2: matchSwap + opening oracle game ────────────────────────

    function _phase2Match() internal {
        matchTs = uint48(vm.getBlockTimestamp());
        uint256 expectedReportId = oracle.nextReportId();

        openingGame = _matchSwap(prop);

        assertEq(openingGame.reportId, expectedReportId, "P2 opening reportId");
        assertEq(punt.swapIdToReportId(swapId), expectedReportId, "P2 sidecar points at opening game");
        assertFalse(openingGame.swap.active, "P2 not yet active");
        assertEq(openingGame.swap.fulfillmentFee, EXPECTED_FEE, "P2 fee fixed at auction start");
        assertEq(openingGame.swap.fundingRate, 0, "P2 zero funding");
        assertEq(openingGame.swap.feeRecipient, address(0), "P2 no fee receiver at zero protocol fee");
        assertEq(
            punt.swaps(swapId),
            keccak256(abi.encode(_expectedMatchedAfterMatch())),
            "P2 stored hash equals hand-built matched state"
        );

        assertEq(_spendable(matcher, address(collat)), b.matcherCollatInt - INITIAL_MARGIN_MATCHER, "P2 matcher margin");
        assertEq(
            _spendable(address(punt), address(collat)),
            uint256(INITIAL_MARGIN_SWAPPER) + INITIAL_MARGIN_MATCHER,
            "P2 punt holds both margins"
        );
        assertEq(_spendable(matcher, address(tokenA)), b.matcherAInt - INITIAL_LIQUIDITY, "P2 matcher posted leg1");
        assertEq(_spendable(matcher, address(tokenB)), b.matcherBInt - AMOUNT2, "P2 matcher posted leg2");
        assertEq(punt.tempHolding(matcher), MATCHER_GAS_COMP, "P2 matcher gas comp queued");
        assertEq(address(punt).balance, EXPECTED_TOTAL_ETH_IN - SETTLER_REWARD, "P2 settler reward moved to oracle");
    }

    // ── phase 3: opening settlement eligibility + execute ───────────────

    function _phase3OpeningExecute() internal {
        openingReportTs = openingGame.game.lastReportOppoTime;
        _advanceToSettlementEligibility();

        activeSwap = _executeOpening(openingGame, executor);

        assertTrue(activeSwap.active, "P3 active");
        assertEq(punt.swapIdToReportId(swapId), 0, "P3 no live report");
        assertEq(activeSwap.initialMarginSwapper, EXPECTED_MARGIN_SWAPPER_OPEN, "P3 opening fee removed once");
        assertEq(activeSwap.initialMarginMatcher, INITIAL_MARGIN_MATCHER, "P3 matcher margin untouched");
        assertEq(activeSwap.oracleAmount1, INITIAL_LIQUIDITY, "P3 opening amount1 recorded");
        assertEq(activeSwap.oracleAmount2, AMOUNT2, "P3 opening amount2 recorded");
        assertEq(activeSwap.start, openingReportTs + SETTLEMENT_SECONDS, "P3 start == opening settlement eligibility");
        assertEq(
            activeSwap.maturity,
            openingReportTs + SETTLEMENT_SECONDS + MATURITY_WINDOW,
            "P3 maturity anchored to opening settlement eligibility"
        );
        assertEq(activeSwap.openExecutionComp, 0, "P3 opening comp consumed");
        assertEq(
            punt.swaps(swapId),
            keccak256(abi.encode(_expectedActive())),
            "P3 stored hash equals hand-built active state"
        );

        // opening fee paid to matcher exactly once; oracle legs returned by settlement
        assertEq(
            _spendable(matcher, address(collat)),
            b.matcherCollatInt - INITIAL_MARGIN_MATCHER + EXPECTED_OPEN_FEE,
            "P3 matcher received opening fee"
        );
        assertEq(_spendable(matcher, address(tokenA)), b.matcherAInt, "P3 matcher leg1 returned");
        assertEq(_spendable(matcher, address(tokenB)), b.matcherBInt, "P3 matcher leg2 returned");
        assertEq(_spendable(address(punt), address(collat)), EXPECTED_MARGIN_SUM, "P3 punt holds remaining margin");

        // executor compensation
        assertEq(punt.tempHolding(executor), OPEN_EXEC_COMP, "P3 opening executor comp");
        assertEq(_spendable(executor, address(0)), SETTLER_REWARD, "P3 settler reward forwarded to executor");
        assertEq(_spendable(address(punt), address(0)), 0, "P3 punt keeps no internal ETH");
    }

    // ── phase 4: close() starts the Dutch auction ───────────────────────

    function _phase4Close() internal {
        dutch = _close(swapId, activeSwap, CLOSE_EXEC_COMP);

        assertEq(_storedAuctionHash(swapId, activeSwap), keccak256(abi.encode(dutch)), "P4 auction stored");
        (uint128 pendingComp,, bool intent) = _closeState(swapId);
        assertTrue(intent, "P4 close request is live");
        assertEq(pendingComp, CLOSE_EXEC_COMP, "P4 close execution comp escrowed");

        assertEq(
            collat.balanceOf(swapper),
            b.swapperCollatExt - INITIAL_MARGIN_SWAPPER - DUTCH_MAX_REWARD,
            "P4 swapper funded max dutch reward"
        );
        assertEq(
            _spendable(address(punt), address(collat)),
            EXPECTED_MARGIN_SUM + DUTCH_MAX_REWARD,
            "P4 punt holds margin + dutch reward"
        );
        assertEq(_spendable(address(punt), address(0)), CLOSE_EXEC_COMP, "P4 punt holds close exec comp");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(activeSwap)), "P4 position hash unchanged by close");
    }

    // ── phase 5: report() claims the Dutch reward ───────────────────────

    function _phase5Report() internal {
        uint256 expectedClosingReportId = oracle.nextReportId();

        closingGame = _reportOnPosition(swapId, dutch, activeSwap, prop.preimage, reporter, REPORT_EXEC_COMP);

        assertEq(closingGame.reportId, expectedClosingReportId, "P5 closing reportId");
        assertTrue(closingGame.reportId != openingGame.reportId, "P5 distinct from opening game");
        assertTrue(closingGame.swap.active, "P5 still active");
        assertEq(_storedDutchState(swapId), bytes32(0), "P5 dutch consumed");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(activeSwap)), "P5 active position hash remains stable");
        (,, bool intent) = _closeState(swapId);
        assertTrue(intent, "P5 future close intent bound to the new report");

        assertEq(_spendable(reporter, address(collat)), EXPECTED_DUTCH_REWARD, "P5 dutch reward paid to reporter");
        assertEq(
            collat.balanceOf(swapper),
            b.swapperCollatExt - INITIAL_MARGIN_SWAPPER - DUTCH_MAX_REWARD + EXPECTED_DUTCH_LEFTOVER,
            "P5 dutch remainder pushed back to swapper"
        );
        assertEq(_spendable(swapper, address(collat)), 0, "P5 external auction creates no internal credit");
        assertEq(_spendable(address(punt), address(collat)), EXPECTED_MARGIN_SUM, "P5 punt back to margin only");

        assertEq(_spendable(reporter, address(tokenA)), b.reporterAInt - INITIAL_LIQUIDITY, "P5 reporter posted leg1");
        assertEq(_spendable(reporter, address(tokenB)), b.reporterBInt - AMOUNT2, "P5 reporter posted leg2");
        assertEq(_spendable(reporter, address(0)), b.reporterEthInt - REPORT_EXEC_COMP, "P5 reporter added exec comp");

        (uint128 pendingAfterReport,,) = _closeState(swapId);
        assertEq(pendingAfterReport, 0, "P5 pending comp migrated to the report");
        assertEq(
            punt.executionGasComp(closingGame.reportId),
            EXPECTED_CLOSING_COMP,
            "P5 execution comp accrued to closing report"
        );
        assertEq(_spendable(address(punt), address(0)), EXPECTED_CLOSING_COMP, "P5 punt holds the comp it owes");
    }

    // ── phase 6: closing settlement eligibility + execute ───────────────

    function _phase6ClosingExecute() internal {
        _advanceToSettlementEligibility();

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, closingGame.swap, closingGame.game, closingGame.helper, false);

        (uint256 owedSwapper, uint256 owedMatcher) = _decodePositionClosed(vm.getRecordedLogs(), swapId);

        assertEq(owedSwapper, EXPECTED_OWED_SWAPPER, "P6 owed to swapper");
        assertEq(owedMatcher, EXPECTED_OWED_MATCHER, "P6 owed to matcher");
        assertEq(owedSwapper + owedMatcher, EXPECTED_MARGIN_SUM, "P6 remaining margin conserved between the parties");

        assertEq(punt.swaps(swapId), bytes32(0), "P6 position finalised");
        (uint128 finalPending,, bool finalIntent) = _closeState(swapId);
        assertEq(finalPending, 0, "P6 close state cleared");
        assertFalse(finalIntent, "P6 close intent cleared");

        // close execution compensation paid exactly once, to the closing executor only
        assertEq(punt.executionGasComp(closingGame.reportId), 0, "P6 comp drained");
        assertEq(_spendable(closeExecutor, address(0)), EXPECTED_CLOSING_COMP, "P6 closing executor paid once");
        assertEq(punt.tempHolding(closeExecutor), 0, "P6 no opening comp double-pay");
        assertEq(punt.tempHolding(executor), OPEN_EXEC_COMP, "P6 opening executor comp unchanged");
    }

    // ── final reconciliation ────────────────────────────────────────────

    function _finalLedgerReconciliation() internal view {
        assertEq(
            collat.balanceOf(swapper),
            b.swapperCollatExt - INITIAL_MARGIN_SWAPPER - DUTCH_MAX_REWARD + EXPECTED_DUTCH_LEFTOVER
                + EXPECTED_OWED_SWAPPER,
            "final swapper external collat"
        );
        assertEq(_spendable(swapper, address(collat)), 0, "final swapper internal collat");
        assertEq(
            _spendable(matcher, address(collat)),
            b.matcherCollatInt - INITIAL_MARGIN_MATCHER + EXPECTED_OPEN_FEE + EXPECTED_OWED_MATCHER,
            "final matcher internal collat"
        );
        assertEq(_spendable(reporter, address(collat)), EXPECTED_DUTCH_REWARD, "final reporter internal collat");

        // With zero funding and an unchanged price, the only position-margin transfer
        // is the opening fulfillment fee (plus the swapper-funded reward).
        int256 swapperDelta = int256(collat.balanceOf(swapper)) + int256(_spendable(swapper, address(collat)))
            - int256(b.swapperCollatExt);
        int256 matcherDelta = int256(_spendable(matcher, address(collat))) - int256(b.matcherCollatInt);
        int256 reporterDelta = int256(_spendable(reporter, address(collat)));

        assertEq(
            swapperDelta,
            -int256(uint256(EXPECTED_OPEN_FEE) + EXPECTED_DUTCH_REWARD),
            "swapper paid exactly opening fee + dutch reward"
        );
        assertEq(matcherDelta, int256(uint256(EXPECTED_OPEN_FEE)), "matcher earned exactly the opening fee");
        assertEq(reporterDelta, int256(uint256(EXPECTED_DUTCH_REWARD)), "reporter earned exactly the dutch reward");
        assertEq(swapperDelta + matcherDelta + reporterDelta, int256(0), "collateral conserved system-wide");

        // oracle legs fully returned to whoever posted them
        assertEq(_spendable(matcher, address(tokenA)), b.matcherAInt, "final matcher leg1");
        assertEq(_spendable(matcher, address(tokenB)), b.matcherBInt, "final matcher leg2");
        assertEq(_spendable(reporter, address(tokenA)), b.reporterAInt, "final reporter leg1");
        assertEq(_spendable(reporter, address(tokenB)), b.reporterBInt, "final reporter leg2");

        _assertNoPuntResidue();

        // ETH reconciles: everything still on the core is exactly what tempHolding owes
        uint256 retained = address(punt).balance;
        assertEq(retained, EXPECTED_TOTAL_ETH_IN - SETTLER_REWARD, "core ETH == deposits minus the settler reward");
        assertEq(
            punt.tempHolding(matcher) + punt.tempHolding(executor),
            retained,
            "and is exactly the queued tempHolding claims"
        );
        assertEq(
            _spendable(executor, address(0)) + _spendable(closeExecutor, address(0)),
            uint256(SETTLER_REWARD) + EXPECTED_CLOSING_COMP,
            "all oracle-side ETH rewards landed with the executors"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Reachability
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Proves the happy-path helpers really drive the contract through every
    ///         lifecycle stage rather than skipping or short-circuiting one.
    function test_happyPathReachesEveryStage() public {
        bool[6] memory reached;

        Proposal memory p = _propose();
        reached[0] = punt.swaps(p.swapId) != bytes32(0) && p.swap.swapper == swapper;

        Matched memory mt = _matchSwap(p);
        reached[1] = mt.swap.matcher == matcher && punt.swapIdToReportId(p.swapId) == mt.reportId && !mt.swap.active
            && oracle.oracleGame(mt.reportId) != bytes32(0);

        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);
        reached[2] = active.active && punt.swapIdToReportId(p.swapId) == 0
            && punt.swaps(p.swapId) == keccak256(abi.encode(active));

        OpenPuntStorage.CloseDutch memory d = _close(p.swapId, active, CLOSE_EXEC_COMP);
        (,, bool intent) = _closeState(p.swapId);
        reached[3] = intent && _storedAuctionHash(p.swapId, active) == keccak256(abi.encode(d));

        Matched memory closing = _reportOnPosition(p.swapId, d, active, p.preimage, reporter, REPORT_EXEC_COMP);
        reached[4] = closing.swap.active && punt.swapIdToReportId(p.swapId) == closing.reportId
            && closing.reportId != mt.reportId && oracle.oracleGame(closing.reportId) != bytes32(0);

        _advanceToSettlementEligibility();
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, closing.game, closing.helper, false);
        reached[5] = punt.swaps(p.swapId) == bytes32(0);

        assertTrue(reached[0], "stage: proposed");
        assertTrue(reached[1], "stage: matched + opening report");
        assertTrue(reached[2], "stage: active");
        assertTrue(reached[3], "stage: close auction");
        assertTrue(reached[4], "stage: closing report");
        assertTrue(reached[5], "stage: finalized");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Hand-built expected states (independent of the contract's copy logic)
    // ═══════════════════════════════════════════════════════════════════

    function _expectedMatchedAfterMatch() internal view returns (OpenPuntStorage.MatchedSwap memory s) {
        s.swapper = swapper;
        s.matcher = matcher;
        s.collatToken = address(collat);
        s.oracleToken1 = address(tokenA);
        s.oracleToken2 = address(tokenB);
        s.initialMarginSwapper = INITIAL_MARGIN_SWAPPER;
        s.initialMarginMatcher = INITIAL_MARGIN_MATCHER;
        s.maintenanceMarginSwapper = MAINTENANCE_MARGIN;
        s.notional = NOTIONAL;
        s.swapperIsLong = true;
        s.fulfillmentFee = EXPECTED_FEE;
        s.fundingRate = 0;
        s.oracleAmount1 = 0;
        s.oracleAmount2 = 0;
        s.feeRecipient = address(0);
        s.matcherPreimageHash = keccak256(abi.encode(prop.preimage));
        s.priceTolerated = PRICE_TOLERATED;
        s.toleranceRange = TOLERANCE_RANGE;
        s.millisecondsPerBlock = MS_PER_BLOCK;
        s.maxGameTime = MAX_GAME_TIME;
        s.maxExecutionLatency = MAX_EXECUTION_LATENCY;
        s.liquidationHeartbeatMin = 0;
        s.liquidationHeartbeatMax = 0;
        s.start = matchTs;
        s.maturity = 0;
        s.maturityWindow = MATURITY_WINDOW;
        s.active = false;
        s.openExecutionComp = OPEN_EXEC_COMP;
        s.useInternalBalances = false;
    }

    function _expectedActive() internal view returns (OpenPuntStorage.MatchedSwap memory s) {
        s = _expectedMatchedAfterMatch();
        s.initialMarginSwapper = EXPECTED_MARGIN_SWAPPER_OPEN;
        s.oracleAmount1 = INITIAL_LIQUIDITY;
        s.oracleAmount2 = AMOUNT2;
        s.start = openingReportTs + uint48(SETTLEMENT_SECONDS);
        s.maturity = openingReportTs + uint48(SETTLEMENT_SECONDS) + MATURITY_WINDOW;
        s.active = true;
        s.openExecutionComp = 0;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _decodePositionClosed(Vm.Log[] memory logs, uint256 id)
        internal
        view
        returns (uint256 owedToSwapper, uint256 owedToMatcher)
    {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.PositionClosed.selector, id);
        (owedToSwapper, owedToMatcher) = abi.decode(l.data, (uint256, uint256));
    }

    function _assertNoPuntResidue() internal view {
        // no external ERC20 ever rests on the core
        assertEq(collat.balanceOf(address(punt)), 0, "residue: external collat");
        assertEq(tokenA.balanceOf(address(punt)), 0, "residue: external tokenA");
        assertEq(tokenB.balanceOf(address(punt)), 0, "residue: external tokenB");

        // internal oracle balances drained down to the virtual sentinel only
        assertEq(_spendable(address(punt), address(collat)), 0, "residue: internal collat");
        assertEq(_spendable(address(punt), address(tokenA)), 0, "residue: internal tokenA");
        assertEq(_spendable(address(punt), address(tokenB)), 0, "residue: internal tokenB");
        assertEq(_spendable(address(punt), address(0)), 0, "residue: internal ETH");
        assertLe(oracle.tokenHolder(address(punt), address(collat)), 1, "residue: collat slot is sentinel-only");
        assertLe(oracle.tokenHolder(address(punt), address(0)), 1, "residue: ETH slot is sentinel-only");

        // the module never custodies anything
        assertEq(address(lifecycleModule).balance, 0, "residue: module ETH");
        assertEq(collat.balanceOf(address(lifecycleModule)), 0, "residue: module collat");
    }
}
