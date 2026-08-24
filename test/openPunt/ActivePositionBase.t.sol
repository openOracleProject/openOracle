// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice Shared fixture for active-position PnL / funding accounting.
 *
 * @dev Design choices that make every expected amount hand-derivable:
 *
 *      1. `report()`'s liquidity gate forces `amount1 == initialLiquidity` whenever
 *         disputeDelay is nonzero, so both oracle games always carry the same token1 leg.
 *         With a1 identical, the contract's cross-multiplied PnL collapses to
 *             pricePnl = notional * |a2_close - a2_open| / a2_open
 *         because a1 cancels exactly in the rational value (so the floors agree too).
 *
 *      2. Setting `notional == a2_open == 10_000e18` makes that expression exactly
 *             pricePnl = |a2_close - a2_open|
 *         i.e. one wei of token2 movement is one wei of PnL. That gives wei-granular
 *         control of the liquidation boundary, which a coarser ratio cannot reach.
 *
 *      3. Direction. The contract's `priceIncreased` is `currentCross >= openingCross`,
 *         which reduces to `(a2/a1)_close >= (a2/a1)_open` — the token2/token1 ratio rose.
 *         That matches the documented meaning of `isLong` ("profits from oracleToken2 /
 *         oracleToken1 increasing"). Tests are written in terms of that ratio, referred to
 *         throughout as R.
 *
 *      4. Funding elapsed time. Writing D for
 *         `floor(settlementTime * millisecondsPerBlock / 1000)`, the elapsed time is
 *         `(closingReportWall + D) - start` with `start == openingReportWall + D`, so D cancels
 *         and it equals exactly the wall-clock gap between the two reports. In block mode the
 *         report's wall clock is `lastReportOppoTime`; `reportTimestamp` holds its block number.
 *         `_reportAndExecute` takes that gap directly.
 *
 *      5. Fee and funding are isolated from each other by two degenerate auctions:
 *           CFG_A: auctionFunding = true, fee fixed at 0, funding auction start == the
 *                  desired rate and matched in the proposal's own block, so no round elapses.
 *           CFG_B: auctionFunding = false, funding fixed by the swapper, fee auction with
 *                  start == end == 10_000 and growth 1x, so the fee is 10_000 at any time.
 *
 *      Heartbeat and max-execution-latency modes are disabled throughout this fixture so
 *      they cannot confound the accounting.
 */
abstract contract ActivePositionBase is OpenPuntBase {
    // ── accounting configuration ────────────────────────────────────────
    uint128 internal constant A1 = 1e18; // token1 leg, identical in both games
    uint128 internal constant A2_OPEN = 10_000e18; // token2 leg at open
    uint128 internal constant NOTIONAL_ACC = 10_000e18; // == A2_OPEN, so pricePnl == |delta a2|
    uint232 internal constant PT_ACC = 1e26; // mulDiv(1e18, 1e30, 10_000e18)
    uint128 internal constant MARGIN_S = 1000e18;
    uint128 internal constant MARGIN_M = 1000e18;
    uint128 internal constant MAINT = 200e18;

    uint24 internal constant FEE_BPS = 10_000; // 0.1% of notional
    uint128 internal constant FEE_AMOUNT = 10e18; // 10_000e18 * 10_000 / 1e7

    uint48 internal constant MATURITY_SHORT = 1 hours; // matures long before any report
    uint48 internal constant MATURITY_LONG = 7 days; // stays pre-maturity across these tests

    // 10% annual over 315_360s (3.65 days) is exactly one thousandth of notional:
    //   mulDiv(10_000e18, 1e6 * 315_360, 1e7 * 365 days) = 10_000e18 / 1000 = 10e18
    int32 internal constant RATE_10PCT = 1_000_000;
    uint256 internal constant ELAPSED_STD = 315_360;
    uint128 internal constant FUNDING_AMOUNT = 10e18;

    uint48 internal openingReportTs;

    function _setUpAccounting() internal {
        _setUpAll();
        collat.mint(swapper, 1_000_000e18);
        vm.deal(swapper, 1000 ether);
        _mintAndDeposit(collat, matcher, 1_000_000e18);
        _mintAndDeposit(tokenA, matcher, 1_000e18);
        _mintAndDeposit(tokenB, matcher, 10_000_000e18);
        _mintAndDeposit(tokenA, reporter, 1_000e18);
        _mintAndDeposit(tokenB, reporter, 10_000_000e18);
    }

    // ── proposal builders ───────────────────────────────────────────────

    function _accountingSwap() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap();
        s.initialMarginSwapper = MARGIN_S;
        s.initialMarginMatcher = MARGIN_M;
        s.maintenanceMarginSwapper = MAINT;
        s.notional = NOTIONAL_ACC;
        s.priceTolerated = PT_ACC;
        s.toleranceRange = 1e6;
        s.maturityWindow = MATURITY_LONG;
        s.maxExecutionLatency = 0; // disabled for accounting isolation
        s.liquidationHeartbeatMin = 0; // disabled for accounting isolation
        s.liquidationHeartbeatMax = 0;
    }

    function _accountingPreimage() internal view returns (OpenPuntStorage.MatcherPreimage memory m) {
        m = _defaultMatcherPreimage();
        m.initialLiquidity = A1;
        m.escalationHalt = 100 * uint128(A1);
        m.disputeDelay = 5; // nonzero: pins closing amount1 to initialLiquidity
    }

    /// @dev CFG_A: fulfillment fee fixed at zero, funding rate fixed at `rate`.
    function _cfgZeroFee(int32 rate)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        s = _accountingSwap();
        m = _accountingPreimage();
        s.auctionFunding = true;
        s.fulfillmentFee = 0;
        s.fundingRate = 0; // required zero in this mode
        m.auctionStart = rate; // matched in the same block -> round 0 -> exactly `rate`
        m.auctionEnd = rate + 1;
    }

    /// @dev CFG_B: fulfillment fee pinned at FEE_BPS for all time, funding fixed at `rate`.
    function _cfgWithFee(int32 rate)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        s = _accountingSwap();
        m = _accountingPreimage();
        s.auctionFunding = false;
        s.fulfillmentFee = 0; // required zero in this mode
        s.fundingRate = rate;
        m.auctionStart = int32(uint32(FEE_BPS));
        m.auctionEnd = int32(uint32(FEE_BPS)); // start == end, growth 1x -> constant fee
        m.growthRate = 10_000;
    }

    // ── lifecycle ───────────────────────────────────────────────────────

    /// @dev propose -> match -> settlement eligibility -> opening execute, all real calls.
    function _openAccounting(OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p)
    {
        p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, A2_OPEN, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        active = _executeOpening(mt, executor);
        swapId = p.swapId;
    }

    /// @dev Places the closing report so that the funding elapsed time is exactly `elapsed`
    ///      seconds, then executes it one settlement window later. Returns the execute logs.
    function _reportAndExecute(
        uint256 swapId,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.MatcherPreimage memory preimage,
        uint128 a2Close,
        uint256 elapsed
    ) internal returns (Vm.Log[] memory logs, uint256 reportId) {
        return _reportAndExecuteWithLegs(swapId, active, preimage, A1, a2Close, elapsed);
    }

    /// @dev Same, with the closing token1 leg supplied explicitly. The report gate requires it
    ///      to equal the position's initialLiquidity whenever disputeDelay is nonzero.
    function _reportAndExecuteWithLegs(
        uint256 swapId,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.MatcherPreimage memory preimage,
        uint128 a1Close,
        uint128 a2Close,
        uint256 elapsed
    ) internal returns (Vm.Log[] memory logs, uint256 reportId) {
        require(elapsed >= SETTLE_HOP_SECONDS, "elapsed below the opening settlement hop");
        uint256 extra = elapsed - (vm.getBlockTimestamp() - openingReportTs);
        _advanceTimeAndBlocks(extra, extra / 2);

        Matched memory closing = _reportOnPositionWithAmounts(
            swapId, _noDutch(), active, preimage, reporter, REPORT_EXEC_COMP, a1Close, a2Close
        );
        reportId = closing.reportId;

        assertEq(uint256(closing.game.lastReportOppoTime) - openingReportTs, elapsed, "funding elapsed time is exact");

        _advanceToSettlementEligibility();

        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(swapId, closing.swap, closing.game, closing.helper, false);
        logs = vm.getRecordedLogs();
    }

    // ── log readers ─────────────────────────────────────────────────────

    function _readPositionClosed(Vm.Log[] memory logs, uint256 swapId)
        internal
        view
        returns (uint256 owedToSwapper, uint256 owedToMatcher)
    {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.PositionClosed.selector, swapId);
        (, owedToSwapper, owedToMatcher) = abi.decode(l.data, (OpenPuntStorage.MatchedSwap, uint256, uint256));
    }

    function _hasLog(Vm.Log[] memory logs, bytes32 topic0, uint256 swapId) internal view returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(punt)) continue;
            if (logs[i].topics.length < 2 || logs[i].topics[0] != topic0) continue;
            if (uint256(logs[i].topics[1]) == swapId) return true;
        }
        return false;
    }
}
