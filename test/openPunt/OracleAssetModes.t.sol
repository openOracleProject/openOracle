// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AssetModeBase.t.sol";

/**
 * @notice Positions whose oracle game uses native ETH as one leg, in both orientations.
 *
 * @dev Collateral stays ERC20 throughout so this file isolates the oracle-leg asset type.
 *      The ETH leg, the settler reward and the execution compensation all share the
 *      address(0) ledger slot, so every assertion is per owner and per purpose.
 */
contract OracleAssetModesTest is AssetModeBase {
    function setUp() public {
        _setUpAssets();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Opening game
    // ══════════════════════════════════════════════════════════════════

    function _runOpening(Legs legs) internal returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active) {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _assetCfg(legs, address(collat), false);

        address t1 = s.oracleToken1;
        address t2 = s.oracleToken2;
        assertTrue(t1 != t2, "oracle tokens stay distinct");

        uint256 matcherLeg1 = _spendable(matcher, t1);
        uint256 matcherLeg2 = _spendable(matcher, t2);
        uint256 executorEth0 = _spendable(executor, address(0));

        // ── propose + match create the genuine game ─────────────────────
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);

        assertEq(mt.game.token1, t1, "game records token1");
        assertEq(mt.game.token2, t2, "game records token2");
        assertEq(mt.game.currentAmount1, OA1, "game records leg1 amount");
        assertEq(mt.game.currentAmount2, OA2, "game records leg2 amount");
        assertEq(mt.game.currentReporter, matcher, "matcher is the opening reporter");
        assertEq(
            oracle.oracleGame(mt.reportId),
            keccak256(abi.encode(mt.game, mt.helper)),
            "the game reconstructs from its own packed log"
        );

        // the matcher's ledgers fell by exactly the legs posted, and by nothing else
        assertEq(_spendable(matcher, t1), matcherLeg1 - OA1, "matcher posted exactly leg1");
        assertEq(_spendable(matcher, t2), matcherLeg2 - OA2, "matcher posted exactly leg2");

        // ── opening execution settles the game ──────────────────────────
        _advanceToSettlementEligibility();
        active = _executeOpening(mt, executor);
        swapId = p.swapId;

        assertTrue(active.active, "position opened");
        assertEq(_spendable(matcher, t1), matcherLeg1, "leg1 returned in full");
        assertEq(_spendable(matcher, t2), matcherLeg2, "leg2 returned in full");

        // the settler reward reached the executor separately from the ETH leg
        assertEq(
            _spendable(executor, address(0)) - executorEth0,
            SETTLER_REWARD,
            "executor received exactly the settler reward, separate from any ETH leg"
        );

        _assertNoLegResidue(t1, t2);
        assertEq(_spendable(address(punt), address(0)), 0, "core keeps no internal ETH after opening");
    }

    function test_opening_ethIsToken1() public {
        (, OpenPuntStorage.MatchedSwap memory active) = _runOpening(Legs.EthIsToken1);
        assertEq(active.oracleToken1, address(0), "token1 is native ETH");
        assertEq(active.oracleAmount1, OA1, "opening leg1 recorded");
    }

    function test_opening_ethIsToken2() public {
        (, OpenPuntStorage.MatchedSwap memory active) = _runOpening(Legs.EthIsToken2);
        assertEq(active.oracleToken2, address(0), "token2 is native ETH");
        assertEq(active.oracleAmount2, OA2, "opening leg2 recorded");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Active-position report
    // ══════════════════════════════════════════════════════════════════

    function _runActiveReport(Legs legs) internal {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _assetCfg(legs, address(collat), false);
        address t1 = s.oracleToken1;
        address t2 = s.oracleToken2;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openAsset(s, m);

        // Purpose-separated snapshot taken after opening, so the settler reward is already banked.
        uint256 reporterLeg1 = _spendable(reporter, t1);
        uint256 reporterLeg2 = _spendable(reporter, t2);
        uint256 reporterEth = _spendable(reporter, address(0));
        uint256 closeExecEth = _spendable(closeExecutor, address(0));
        uint256 openExecEth = _spendable(executor, address(0));
        uint256 puntEth = _spendable(address(punt), address(0));

        Matched memory mt = _reportAsset(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);

        assertEq(mt.game.token1, t1, "closing game token1");
        assertEq(mt.game.token2, t2, "closing game token2");
        assertEq(mt.game.currentReporter, reporter, "reporter owns the closing game");

        // the reporter funded BOTH the ETH leg and the compensation out of the same slot,
        // and the two are separable: the ledger fell by exactly their sum
        uint256 ethLeg = t1 == address(0) ? OA1 : (t2 == address(0) ? OA2 : 0);
        assertEq(
            _spendable(reporter, address(0)),
            reporterEth - ethLeg - REPORTER_COMP,
            "reporter funded the ETH leg plus the compensation, and nothing more"
        );
        assertEq(punt.executionGasComp(mt.reportId), REPORTER_COMP, "only the compensation reached the core");
        assertEq(
            _spendable(address(punt), address(0)),
            puntEth + REPORTER_COMP,
            "the core holds the compensation, never the ETH oracle leg"
        );

        // a genuine close intent, so the report resolves the position
        vm.prank(swapper);
        punt.close{value: 0}(swapId, _dutchInput(), mt.swap, true, _emptyPermit2(), 0);

        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        assertTrue(
            _hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "timely intent closes the live report"
        );

        // Settlement returned both legs. The ERC20 leg is asserted directly. The ETH leg shares
        // the reporter's address(0) slot with the compensation, so its return is proven by that
        // slot landing at exactly `reporterEth - REPORTER_COMP`: the leg came back in full and
        // only the compensation was consumed. Asserting the ETH slot "unchanged" would be wrong.
        if (t1 == address(0)) {
            assertEq(_spendable(reporter, t2), reporterLeg2, "ERC20 leg2 returned to the reporter");
        } else {
            assertEq(_spendable(reporter, t1), reporterLeg1, "ERC20 leg1 returned to the reporter");
        }
        assertEq(
            _spendable(reporter, address(0)),
            reporterEth - REPORTER_COMP,
            "ETH leg returned in full; only the compensation left the reporter"
        );

        // compensation paid once, to the closing executor only
        assertEq(_spendable(closeExecutor, address(0)) - closeExecEth, REPORTER_COMP, "executor paid exactly once");
        assertEq(_spendable(executor, address(0)), openExecEth, "the opening executor got nothing extra");
        assertEq(punt.executionGasComp(mt.reportId), 0, "compensation drained");

        _assertNoLegResidue(t1, t2);
        assertEq(punt.swaps(swapId), bytes32(0), "position closes on the timely live-report intent");
    }

    function test_activeReport_ethIsToken1() public {
        _runActiveReport(Legs.EthIsToken1);
    }

    function test_activeReport_ethIsToken2() public {
        _runActiveReport(Legs.EthIsToken2);
    }

    /// @dev Without a close intent, a healthy pre-maturity report on an ETH-leg position
    ///      returns the position to idle and still returns both legs to the reporter.
    function test_activeReport_withoutIntentReturnsToIdle() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _assetCfg(Legs.EthIsToken1, address(collat), false);
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openAsset(s, m);

        uint256 reporterEth = _spendable(reporter, address(0));
        uint256 reporterLeg2 = _spendable(reporter, address(tokenB));

        Matched memory mt = _reportAsset(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "returned to idle");

        OpenPuntStorage.MatchedSwap memory idle =
            _decodeSingleSwapState(logs, OpenPuntStorage.LiquidationFailed.selector, swapId);
        assertEq(punt.swapIdToReportId(swapId), 0, "reportId cleared");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(idle)), "event reconstructs the stored hash");

        assertEq(_spendable(reporter, address(0)), reporterEth - REPORTER_COMP, "ETH leg returned, comp spent");
        assertEq(_spendable(reporter, address(tokenB)), reporterLeg2, "ERC20 leg returned");
        assertEq(_spendable(closeExecutor, address(0)), REPORTER_COMP, "executor still paid once");
    }
}
