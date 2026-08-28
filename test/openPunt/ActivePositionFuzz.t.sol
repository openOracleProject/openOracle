// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ActivePositionBase.t.sol";

/**
 * @notice Constrained fuzz over real positions, checked against an independently written
 *         signed-equity model.
 *
 * @dev The model below is written from the protocol's *description*, not from its code:
 *      it uses plain `a * b / c` integer arithmetic over the token2 leg rather than the
 *      contract's cross-multiplied form, and re-derives the ordering of PnL, funding
 *      and the two clamps independently. It never calls mulDivCapped, calcFee,
 *      calcLinearRate, or any other production helper.
 *
 *      Two modelling assumptions are stated explicitly and are separately pinned by the
 *      deterministic matrix:
 *        (1) With the token1 leg identical in both games, token2/token1 PnL reduces to
 *            notional*|dA2|/a2Open, while token1/token2 PnL reduces to
 *            notional*|dA2|/a2Close.
 *        (2) mulDivCapped(x, y, d, cap) == min(floor(x*y/d), cap).
 */
contract ActivePositionFuzzTest is ActivePositionBase {
    struct Model {
        uint256 marginSwapperOpen;
        uint256 marginSum;
        uint256 fundingMag;
        uint256 pnl;
        int256 equity;
        bool liquidates;
        uint256 owedSwapper;
        uint256 owedMatcher;
    }

    function setUp() public {
        _setUpAccounting();
    }

    // ── independent reference model ─────────────────────────────────────

    function _model(uint128 a2Close, int32 rate, uint256 elapsed, bool isLong, bool token1PerToken2)
        internal
        pure
        returns (Model memory r)
    {
        uint256 notional = uint256(NOTIONAL_ACC);

        // the fulfillment fee is charged once, when the position opens
        uint256 fee = notional * uint256(FEE_BPS) / 1e7;
        r.marginSwapperOpen = uint256(MARGIN_S) - fee;
        r.marginSum = r.marginSwapperOpen + uint256(MARGIN_M);

        // funding accrues on notional, pro-rata over a 365-day year
        uint256 absRate = rate < 0 ? uint256(uint32(-rate)) : uint256(uint32(rate));
        r.fundingMag = notional * (absRate * elapsed) / (1e7 * 365 days);

        // price PnL, expressed directly over the token2 leg (assumption 1)
        uint256 delta = a2Close >= A2_OPEN ? uint256(a2Close) - A2_OPEN : uint256(A2_OPEN) - a2Close;
        uint256 denominator = token1PerToken2 ? uint256(a2Close) : uint256(A2_OPEN);
        uint256 rawPnl = notional * delta / denominator;

        // the contract bounds raw PnL before signing it (assumption 2)
        uint256 cap = r.marginSum + r.fundingMag + 1;
        r.pnl = rawPnl > cap ? cap : rawPnl;

        bool ratioUp = token1PerToken2 ? a2Close <= A2_OPEN : a2Close >= A2_OPEN;
        bool profits = (ratioUp == isLong);

        int256 net = profits ? int256(r.pnl) : -int256(r.pnl);
        if (rate > 0) net -= int256(r.fundingMag); // swapper pays matcher

        else if (rate < 0) net += int256(r.fundingMag); // matcher pays swapper
        r.equity = int256(r.marginSwapperOpen) + net;
        r.liquidates = r.equity < int256(uint256(MAINT));

        if (r.liquidates) {
            r.owedSwapper = 0;
            r.owedMatcher = r.marginSum;
        } else {
            uint256 owed = r.equity <= 0 ? 0 : uint256(r.equity);
            if (owed > r.marginSum) owed = r.marginSum;
            r.owedSwapper = owed;
            r.owedMatcher = r.marginSum - owed;
        }
    }

    // ── fuzz ────────────────────────────────────────────────────────────

    function testFuzz_activePositionAccountingMatchesModel(
        uint128 a2CloseSeed,
        int32 rateSeed,
        uint32 elapsedSeed,
        bool isLong,
        bool token1PerToken2
    ) public {
        uint128 a2Close = uint128(bound(uint256(a2CloseSeed), 1e18, 20_000e18));
        int32 rate = int32(int256(bound(int256(rateSeed), -int256(1_000_000), int256(1_000_000))));
        uint256 elapsed = bound(uint256(elapsedSeed), 3600, 2_592_000);

        Model memory want = _model(a2Close, rate, elapsed, isLong, token1PerToken2);

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgWithFee(rate);
        s.isLong = isLong;
        s.pnlUsesToken1PerToken2 = token1PerToken2;
        s.maturityWindow = MATURITY_SHORT; // always mature by execution time

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);

        // The model's post-opening state must match production before terminal accounting.
        assertEq(active.initialMarginSwapper, want.marginSwapperOpen, "margin after the opening fee");
        assertEq(active.fundingRate, rate, "funding rate fixed at the proposed value");
        assertEq(active.fulfillmentFee, FEE_BPS, "fee pinned by the degenerate auction");
        assertEq(uint256(active.initialMarginSwapper) + active.initialMarginMatcher, want.marginSum, "pool size");

        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherInt0 = _spendable(matcher, address(collat));

        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, a2Close, elapsed);

        // outcome kind
        bool liquidated = _hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId);
        bool closed = _hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId);
        assertEq(liquidated, want.liquidates, "liquidation decision matches the model");
        assertEq(closed, !want.liquidates, "close decision matches the model");

        // realised balance deltas
        assertEq(collat.balanceOf(swapper) - swapperExt0, want.owedSwapper, "swapper delta matches the model");
        assertEq(
            _spendable(matcher, address(collat)) - matcherInt0, want.owedMatcher, "matcher delta matches the model"
        );

        // event amounts, where the close branch emits them
        if (closed) {
            (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);
            assertEq(owedS, want.owedSwapper, "event owedToSwapper matches the model");
            assertEq(owedM, want.owedMatcher, "event owedToMatcher matches the model");
            assertEq(owedS + owedM, want.marginSum, "event amounts conserve the pool");
        }

        // conservation and terminal cleanliness in both branches
        assertEq(want.owedSwapper + want.owedMatcher, want.marginSum, "model conserves the pool");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        assertEq(_spendable(address(punt), address(collat)), 0, "core retains no position collateral");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "close state cleared");
        assertFalse(intent, "close intent cleared");
    }

    /// @dev Narrower sweep pinned around the liquidation boundary, where an off-by-one in the
    ///      comparator or in any single term would show up first.
    function testFuzz_liquidationBoundaryMatchesModel(uint96 offsetSeed, bool below) public {
        // zero fee and zero funding so equity == MARGIN_S - |delta a2| exactly
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        // equity == MAINT requires a drop of exactly MARGIN_S - MAINT.
        uint256 dropAtBoundary = uint256(MARGIN_S) - uint256(MAINT);
        uint256 offset = bound(uint256(offsetSeed), 1, 100e18);
        uint256 drop = below ? dropAtBoundary + offset : dropAtBoundary - offset;
        uint128 a2Close = uint128(uint256(A2_OPEN) - drop);

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        uint256 matcherInt0 = _spendable(matcher, address(collat));
        uint256 swapperExt0 = collat.balanceOf(swapper);

        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, a2Close, ELAPSED_STD);

        int256 equity = int256(uint256(MARGIN_S)) - int256(drop);
        bool shouldLiquidate = equity < int256(uint256(MAINT));
        assertEq(shouldLiquidate, below, "the constructed side is the intended one");

        assertEq(
            _hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId),
            shouldLiquidate,
            "liquidation decision matches the strict comparator"
        );

        if (shouldLiquidate) {
            assertEq(collat.balanceOf(swapper), swapperExt0, "liquidated swapper receives nothing");
            assertEq(_spendable(matcher, address(collat)) - matcherInt0, 2000e18, "matcher takes the pool");
        } else {
            assertEq(collat.balanceOf(swapper) - swapperExt0, uint256(equity), "healthy swapper receives its equity");
            assertEq(
                _spendable(matcher, address(collat)) - matcherInt0,
                2000e18 - uint256(equity),
                "matcher receives the remainder"
            );
        }
    }
}
