// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AssetModeBase.t.sol";

/**
 * @notice All four delivery routes of `refund()`, reached through a real failed opening.
 *
 * @dev The failure is the same in every case: priceTolerated is far from the
 *      realised opening price with the tightest tolerance band — so only the delivery route
 *      varies. `refund()` branches on collateral type and the position's useInternalBalances;
 *      the matcher's margin always returns to its oracle ledger regardless.
 */
contract OpeningRefundModesTest is AssetModeBase {
    function setUp() public {
        _setUpAssets();
    }

    /// @dev Position whose opening price is guaranteed to sit outside the tolerance band.
    ///      Realised price is 1e30 (both legs 1e18); the tolerated price is 2e30 with a
    ///      one-unit band, so the opening can only bail out.
    function _slippageDoomedCfg(address collatToken, bool internalPos)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _assetCfg(Legs.BothErc20, collatToken, internalPos);
        s.priceTolerated = 2 * uint232(OPT);
        s.toleranceRange = 1;
    }

    struct Book {
        uint256 swapperExt;
        uint256 swapperInt;
        uint256 swapperRaw;
        uint256 swapperEthInt;
        uint256 matcherInt;
        uint256 matcherEthInt;
        uint256 executorTemp;
        uint256 executorEthInt;
    }

    function _book(address collatToken) internal view returns (Book memory b) {
        b.swapperExt = collat.balanceOf(swapper);
        b.swapperInt = _spendable(swapper, address(collat));
        b.swapperRaw = swapper.balance;
        b.swapperEthInt = _spendable(swapper, address(0));
        b.matcherInt = _spendable(matcher, collatToken);
        b.matcherEthInt = _spendable(matcher, address(0));
        b.executorTemp = punt.tempHolding(executor);
        b.executorEthInt = _spendable(executor, address(0));
    }

    /// @dev Runs the doomed opening and asserts everything that is route-independent.
    function _runFailedOpening(address collatToken, bool internalPos)
        internal
        returns (Book memory before, uint256 swapId)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _slippageDoomedCfg(collatToken, internalPos);

        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);
        swapId = p.swapId;
        before = _book(collatToken);

        _advanceToSettlementEligibility();
        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasBailoutLog(logs, OpenPuntStorage.SlippageBailout.selector, swapId), "slippage bailout");
        _findLog(logs, address(punt), OpenPuntStorage.PositionOpeningFailed.selector, swapId);
        _findLog(logs, address(punt), OpenPuntStorage.SwapRefunded.selector, swapId);

        // matcher margin always lands in its oracle ledger, and no opening fee is taken
        assertEq(
            _spendable(matcher, collatToken) - before.matcherInt,
            MARGIN_M,
            "matcher margin returned to its oracle ledger, with no fee deducted"
        );

        // executor still compensated exactly once, and the settler reward still forwarded
        assertEq(punt.tempHolding(executor) - before.executorTemp, OPEN_EXEC_COMP, "opening compensation paid once");
        assertEq(
            _spendable(executor, address(0)) - before.executorEthInt, SETTLER_REWARD, "settler reward forwarded once"
        );

        // position gone, core retains no position collateral
        assertEq(punt.swaps(swapId), bytes32(0), "position deleted");
        assertEq(_spendable(address(punt), collatToken), 0, "core retains no position collateral");
        assertEq(collat.balanceOf(address(punt)), 0, "core holds no external collateral");
    }

    // ══════════════════════════════════════════════════════════════════
    //  The four routes
    // ══════════════════════════════════════════════════════════════════

    function test_refund_erc20External() public {
        (Book memory b,) = _runFailedOpening(address(collat), false);

        assertEq(collat.balanceOf(swapper) - b.swapperExt, MARGIN_S, "swapper margin pushed externally");
        assertEq(_spendable(swapper, address(collat)), b.swapperInt, "swapper oracle ledger untouched");
    }

    function test_refund_erc20Internal() public {
        (Book memory b,) = _runFailedOpening(address(collat), true);

        assertEq(_spendable(swapper, address(collat)) - b.swapperInt, MARGIN_S, "swapper margin returned internally");
        assertEq(collat.balanceOf(swapper), b.swapperExt, "swapper external balance untouched");
    }

    function test_refund_ethExternal() public {
        (Book memory b,) = _runFailedOpening(address(0), false);

        // the swapper is an EOA, so the oracle's bounded-gas push succeeds
        assertEq(swapper.balance - b.swapperRaw, MARGIN_S, "swapper margin pushed as raw ETH");
        assertEq(_spendable(swapper, address(0)), b.swapperEthInt, "swapper ETH ledger untouched");
    }

    function test_refund_ethInternal() public {
        (Book memory b,) = _runFailedOpening(address(0), true);

        assertEq(_spendable(swapper, address(0)) - b.swapperEthInt, MARGIN_S, "swapper margin returned internally");
        assertEq(swapper.balance, b.swapperRaw, "swapper raw ETH untouched");
    }

    /// @dev With ETH collateral the matcher's refunded margin shares the address(0) slot with
    ///      nothing else it owns here, so its exact arrival is directly checkable.
    function test_refund_ethMatcherMarginIsSeparableFromEverythingElse() public {
        (Book memory b,) = _runFailedOpening(address(0), false);

        assertEq(_spendable(matcher, address(0)) - b.matcherEthInt, MARGIN_M, "matcher ETH margin returned exactly");
        assertEq(_spendable(address(punt), address(0)), 0, "core keeps no ETH of any purpose");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Manual bailOut() passes the stored mode through
    // ══════════════════════════════════════════════════════════════════

    /// @dev bailOut() calls the same refund() implementation, so the canonical lifecycle and
    ///      race coverage is not repeated four times. This is one non-canonical smoke case
    ///      (ETH collateral, internal delivery) proving the manual entry point reads the mode
    ///      out of the stored position rather than assuming the default.
    function test_manualBailoutHonoursTheStoredEthInternalMode() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _assetCfg(Legs.BothErc20, address(0), true);

        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);
        uint256 swapperEthInt0 = _spendable(swapper, address(0));
        uint256 swapperRaw0 = swapper.balance;
        uint256 matcherEthInt0 = _spendable(matcher, address(0));

        uint256 target = uint256(mt.swap.start) + uint256(mt.swap.maxGameTime) + 1;
        vm.warp(target);
        vm.roll(vm.getBlockNumber() + target / 2);

        vm.prank(outsider);
        punt.bailOut(p.swapId, mt.swap);

        assertEq(
            _spendable(swapper, address(0)) - swapperEthInt0, MARGIN_S, "swapper margin returned to the ETH ledger"
        );
        assertEq(swapper.balance, swapperRaw0, "nothing pushed as raw ETH");
        assertEq(_spendable(matcher, address(0)) - matcherEthInt0, MARGIN_M, "matcher margin returned internally");
        assertEq(punt.tempHolding(outsider), OPEN_EXEC_COMP, "caller compensated");
        assertEq(punt.swaps(p.swapId), bytes32(0), "position deleted");
        assertEq(_spendable(address(punt), address(0)), 0, "core retains no ETH collateral");
    }
}
