// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AssetModeBase.t.sol";

/**
 * @notice Liquidation delivery modes.
 *
 * @dev Liquidation does not branch on useInternalBalances — the whole pool always moves into
 *      the matcher's oracle ledger — so this is deliberately not a four-way matrix. It adds
 *      the two genuinely untested delivery shapes: ERC20 collateral funded through the
 *      internal position mode, and native-ETH collateral. The exact maintenance-boundary
 *      arithmetic stays canonical in ActivePositionAccounting.
 */
contract LiquidationDeliveryModesTest is AssetModeBase {
    uint128 internal constant LIQ_COMP = 0.0007 ether;

    function setUp() public {
        _setUpAssets();
    }

    /// @dev Drives the position deep under water: notional is 10_000e18 and the token2 leg is
    ///      1e18, so a closing leg of 1 wei is a catastrophic move for a long. Equity is far
    ///      below the 200e18 maintenance margin, hence a certain liquidation.
    uint128 internal constant WIPEOUT_A2 = 1;

    struct Pre {
        uint256 matcherCollat;
        uint256 swapperCollatInt;
        uint256 swapperCollatExt;
        uint256 swapperRaw;
        uint256 swapperEthInt;
        uint256 reporterEth;
        uint256 closeExecEth;
        uint256 openExecEth;
    }

    /// @dev Baselines are captured after opening, so the matcher's own posted margin is already
    ///      out of its ledger and the liquidation delta is the whole pool arriving, not a net.
    function _runLiquidation(address collatToken, bool internalPos)
        internal
        returns (uint256 swapId, uint256 marginSum, Pre memory pre)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _assetCfg(Legs.BothErc20, collatToken, internalPos);
        s.maturityWindow = MATURITY_LONG; // pre-maturity: only liquidation can end this

        OpenPuntStorage.MatchedSwap memory active;
        Proposal memory p;
        (swapId, active, p,) = _openAsset(s, m);
        marginSum = uint256(active.initialMarginSwapper) + active.initialMarginMatcher;

        pre.matcherCollat = _spendable(matcher, collatToken);
        pre.swapperCollatInt = _spendable(swapper, address(collat));
        pre.swapperCollatExt = collat.balanceOf(swapper);
        pre.swapperRaw = swapper.balance;
        pre.swapperEthInt = _spendable(swapper, address(0));
        pre.reporterEth = _spendable(reporter, address(0));
        pre.closeExecEth = _spendable(closeExecutor, address(0));
        pre.openExecEth = _spendable(executor, address(0));

        Matched memory mt =
            _reportOnPositionWithAmounts(swapId, _noDutch(), active, p.preimage, reporter, LIQ_COMP, OA1, WIPEOUT_A2);
        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "liquidated");
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "not a close");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "close state cleared");
        assertFalse(intent, "close state cleared");
        assertEq(punt.executionGasComp(mt.reportId), 0, "execution compensation drained");
    }

    // ══════════════════════════════════════════════════════════════════
    //  ERC20 collateral, internal position mode
    // ══════════════════════════════════════════════════════════════════

    function test_liquidation_erc20InternalPositionMode() public {
        (, uint256 marginSum, Pre memory pre) = _runLiquidation(address(collat), true);

        assertEq(_spendable(matcher, address(collat)) - pre.matcherCollat, marginSum, "matcher took the whole pool");
        assertEq(_spendable(swapper, address(collat)), pre.swapperCollatInt, "swapper received nothing internally");
        assertEq(collat.balanceOf(swapper), pre.swapperCollatExt, "swapper received nothing externally");
        assertEq(_spendable(address(punt), address(collat)), 0, "core drained of position collateral");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Native-ETH collateral
    // ══════════════════════════════════════════════════════════════════

    /// @dev Here the margin pool, the execution compensation, the settler reward and the
    ///      swapper's own funds all live in the address(0) ledger. Each is asserted separately,
    ///      because a single aggregate ETH check would hide one being paid out of another.
    function test_liquidation_ethCollateral() public {
        (, uint256 marginSum, Pre memory pre) = _runLiquidation(address(0), false);

        // 1. the matcher receives the complete ETH margin pool, in its ledger
        assertEq(_spendable(matcher, address(0)) - pre.matcherCollat, marginSum, "matcher received the entire ETH pool");

        // 2. the swapper receives nothing, by either route
        assertEq(swapper.balance, pre.swapperRaw, "swapper received no raw ETH");
        assertEq(_spendable(swapper, address(0)), pre.swapperEthInt, "swapper received no internal ETH");

        // 3. compensation and oracle legs were not mistaken for collateral
        assertEq(
            _spendable(closeExecutor, address(0)) - pre.closeExecEth,
            LIQ_COMP,
            "closing executor received exactly the execution compensation"
        );
        assertEq(_spendable(executor, address(0)), pre.openExecEth, "opening executor received nothing further");
        assertEq(
            _spendable(reporter, address(0)),
            pre.reporterEth - LIQ_COMP,
            "the reporter funded only the compensation; its ERC20 legs are unrelated"
        );

        // 4. nothing left on the core once every obligation is discharged
        assertEq(_spendable(address(punt), address(0)), 0, "core spendable ETH is zero");
        assertEq(_spendable(address(punt), address(tokenA)), 0, "no leg1 residue");
        assertEq(_spendable(address(punt), address(tokenB)), 0, "no leg2 residue");
    }

    /// @dev Liquidation ignores useInternalBalances: the ETH pool lands internally either way.
    function test_liquidation_ethCollateralInternalPositionModeDeliversIdentically() public {
        (, uint256 marginSum, Pre memory pre) = _runLiquidation(address(0), true);

        assertEq(
            _spendable(matcher, address(0)) - pre.matcherCollat,
            marginSum,
            "internal position mode delivers the pool the same way"
        );
        assertEq(swapper.balance, pre.swapperRaw, "still nothing pushed to the swapper");
    }
}
