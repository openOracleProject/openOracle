// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ActivePositionBase.t.sol";

/**
 * @notice Payout clamping and the overflow-safe PnL path.
 *
 * @dev Two distinct clamps exist and are tested separately:
 *        - `pnlCap` inside mulDivCapped, which bounds the raw PnL to
 *          marginSum + funding + closeFee + 1 before any signing happens
 *        - the terminal `[0, marginSum]` clamp on owedToSwapper in the close branch
 *      The overflow case forces the first one through a real oracle price move whose
 *      `notional * priceDelta` product cannot be represented in 256 bits.
 */
contract ActivePositionCapsTest is ActivePositionBase {
    function setUp() public {
        _setUpAccounting();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Losses beyond the swapper's equity
    // ══════════════════════════════════════════════════════════════════

    /// @dev With a positive maintenance margin, any equity at or below zero is already a
    ///      liquidation, so the whole pool moves to the matcher and the swapper gets nothing.
    function test_lossBeyondEquityGivesMatcherTheWholePool() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherInt0 = _spendable(matcher, address(collat));

        // drop of 1500e18 against a 1000e18 margin: equity would be -500e18
        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_OPEN - 1500e18, ELAPSED_STD);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "liquidated");
        assertEq(collat.balanceOf(swapper), swapperExt0, "swapper payout clamped to zero");
        assertEq(_spendable(matcher, address(collat)) - matcherInt0, 2000e18, "matcher receives the whole pool");
        assertEq(_spendable(address(punt), address(collat)), 0, "core drained");
    }

    /// @dev The `swapperEquity <= 0` clamp inside the close branch is only reachable at exactly
    ///      zero, and only when the maintenance margin is zero — otherwise liquidation fires
    ///      first. This pins that single reachable point.
    function test_zeroMaintenance_equityExactlyZeroClosesWithZeroPayout() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maintenanceMarginSwapper = 0;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherInt0 = _spendable(matcher, address(collat));

        // exactly 1000e18 of loss against a 1000e18 margin -> equity == 0, not < 0
        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_OPEN - 1000e18, ELAPSED_STD);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "closed, not liquidated");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "equity zero is still healthy");

        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);
        assertEq(owedS, 0, "owedToSwapper clamped to zero");
        assertEq(owedM, 2000e18, "matcher takes the pool");
        assertEq(owedS + owedM, 2000e18, "conserved");
        assertEq(collat.balanceOf(swapper), swapperExt0, "no collateral pushed to the swapper");
        assertEq(_spendable(matcher, address(collat)) - matcherInt0, 2000e18, "matcher delta matches the event");
    }

    function test_zeroMaintenance_oneUnitBelowZeroLiquidates() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maintenanceMarginSwapper = 0;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_OPEN - 1000e18 - 1, ELAPSED_STD);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "equity -1 liquidates");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Profits beyond the matcher's equity
    // ══════════════════════════════════════════════════════════════════

    /// @dev Equity exactly equal to the pool needs no clamp; the swapper takes everything.
    function test_profitExactlyAtPoolTakesEverything() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        uint256 swapperExt0 = collat.balanceOf(swapper);

        // gain of exactly 1000e18 -> equity 2000e18 == marginSum
        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_OPEN + 1000e18, ELAPSED_STD);

        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);
        assertEq(owedS, 2000e18, "swapper takes the whole pool");
        assertEq(owedM, 0, "matcher receives nothing");
        assertEq(collat.balanceOf(swapper) - swapperExt0, 2000e18, "balance delta matches");
    }

    function test_profitBeyondPoolClampsToMarginSum() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);
        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherInt0 = _spendable(matcher, address(collat));

        // gain of 1500e18 -> equity 2500e18, above the 2000e18 pool
        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_OPEN + 1500e18, ELAPSED_STD);

        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);
        assertEq(owedS, 2000e18, "clamped to the pool");
        assertEq(owedM, 0, "matcher receives nothing");
        assertEq(owedS + owedM, 2000e18, "conserved");
        assertEq(collat.balanceOf(swapper) - swapperExt0, 2000e18, "swapper delta matches");
        assertEq(_spendable(matcher, address(collat)), matcherInt0, "matcher delta is zero");
    }

    /// @dev A gain large enough that the internal pnlCap binds first, then the terminal clamp.
    function test_profitLargeEnoughToBindThePnlCap() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_SHORT;

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openAccounting(s, m);

        // raw PnL would be 5000e18; pnlCap is marginSum + 0 + 0 + 1 = 2000e18 + 1
        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, active, p.preimage, A2_OPEN + 5000e18, ELAPSED_STD);

        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);
        assertEq(owedS, 2000e18, "capped then clamped to the pool");
        assertEq(owedM, 0, "matcher receives nothing");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Overflow-scale price movement
    // ══════════════════════════════════════════════════════════════════
    //
    // Oracle legs of 1e30 opening and 1e38 closing give
    //     priceDelta   = |1e38*1e30 - 1e30*1e30| ~ 1e68
    //     openingCross = 1e30 * 1e30            = 1e60
    // and notional * priceDelta ~ 1e90, far beyond uint256 (~1.16e77). mulDivCapped never
    // forms that product: quotient (~1e8) exceeds cap/notional (which floors to 0), so it
    // short-circuits straight to the cap.

    uint128 internal constant BIG_A1 = 1e30;
    uint128 internal constant BIG_A2_OPEN = 1e30;
    uint128 internal constant BIG_A2_CLOSE = 1e38;

    function _bigConfig(bool isLong)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _cfgZeroFee(0);
        s.isLong = isLong;
        s.maturityWindow = MATURITY_SHORT;
        s.priceTolerated = 1e30; // mulDiv(1e30, 1e30, 1e30)
        s.toleranceRange = 1e6;
        m.initialLiquidity = BIG_A1;
        m.escalationHalt = 2 * BIG_A1;
    }

    function _fundBigLegs() internal {
        _mintAndDeposit(tokenA, matcher, 10 * BIG_A1);
        _mintAndDeposit(tokenB, matcher, 10 * BIG_A2_OPEN);
        _mintAndDeposit(tokenA, reporter, 10 * BIG_A1);
        _mintAndDeposit(tokenB, reporter, 2 * BIG_A2_CLOSE);
    }

    function _openBig(bool isLong)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p)
    {
        _fundBigLegs();
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _bigConfig(isLong);

        p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, BIG_A2_OPEN, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        active = _executeOpening(mt, executor);
        swapId = p.swapId;

        assertEq(active.oracleAmount1, BIG_A1, "opening leg1 recorded");
        assertEq(active.oracleAmount2, BIG_A2_OPEN, "opening leg2 recorded");
    }

    /// @dev Establishes that the naive product really would overflow, from the real amounts.
    function _assertProductWouldOverflow(OpenPuntStorage.MatchedSwap memory active) internal pure {
        uint256 currentCross = uint256(BIG_A2_CLOSE) * active.oracleAmount1;
        uint256 openingCross = uint256(active.oracleAmount2) * BIG_A1;
        uint256 priceDelta = currentCross - openingCross;

        assertGt(
            priceDelta,
            type(uint256).max / uint256(active.notional),
            "notional * priceDelta cannot be represented in 256 bits"
        );
    }

    function test_overflowScaleGain_completesAndClampsToPool() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openBig(true);
        _assertProductWouldOverflow(active);

        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 reporterA0 = _spendable(reporter, address(tokenA));
        uint256 reporterB0 = _spendable(reporter, address(tokenB));

        (Vm.Log[] memory logs,) =
            _reportAndExecuteWithLegs(swapId, active, p.preimage, BIG_A1, BIG_A2_CLOSE, ELAPSED_STD);

        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);
        assertEq(owedS, 2000e18, "gain capped then clamped to the whole pool");
        assertEq(owedM, 0, "matcher receives nothing");
        assertEq(collat.balanceOf(swapper) - swapperExt0, 2000e18, "balance delta matches the event");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");

        // the extreme oracle legs came back to the reporter
        assertEq(_spendable(reporter, address(tokenA)), reporterA0, "leg1 returned");
        assertEq(_spendable(reporter, address(tokenB)), reporterB0, "leg2 returned");
        assertEq(_spendable(address(punt), address(collat)), 0, "core drained");
    }

    function test_overflowScaleLoss_completesAndLiquidates() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openBig(false);
        _assertProductWouldOverflow(active);

        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherInt0 = _spendable(matcher, address(collat));

        (Vm.Log[] memory logs,) =
            _reportAndExecuteWithLegs(swapId, active, p.preimage, BIG_A1, BIG_A2_CLOSE, ELAPSED_STD);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "short is wiped out");
        assertEq(collat.balanceOf(swapper), swapperExt0, "swapper receives nothing");
        assertEq(_spendable(matcher, address(collat)) - matcherInt0, 2000e18, "matcher takes the whole pool");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
    }
}
