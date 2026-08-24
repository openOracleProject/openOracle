// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";

/**
 * @notice Fixture for the asset/mode matrix: native-ETH oracle legs, native-ETH collateral,
 *         and collateral that shares a token with one of the oracle legs.
 *
 * @dev Both oracle legs are 1e18 so the opening price is exactly 1e30 in either orientation,
 *      which keeps native-ETH legs affordable (1 ETH per leg rather than thousands) while
 *      staying inside a single tolerance band shared by every orientation.
 *
 *      When address(0) is simultaneously an oracle leg, the collateral token, the execution
 *      compensation and the settler reward, all four live in the same oracle ledger slot.
 *      Tests here therefore reconcile by owner and purpose; a single aggregate ETH
 *      assertion would hide cross-accounting between them.
 */
abstract contract AssetModeBase is CloseBase {
    uint128 internal constant OA1 = 1e18; // token1 leg, both orientations
    uint128 internal constant OA2 = 1e18; // token2 leg, both orientations
    uint232 internal constant OPT = 1e30; // mulDiv(1e18, 1e30, 1e18)

    uint128 internal constant REPORTER_COMP = 0.0005 ether;

    enum Legs {
        BothErc20,
        EthIsToken1,
        EthIsToken2
    }

    function _setUpAssets() internal {
        _setUpClose();

        // native-ETH oracle legs and ETH collateral need real internal ETH on every participant
        vm.deal(reporter, 100_000 ether);
        vm.deal(adapter, 100_000 ether);
        vm.deal(outsider, 100_000 ether);

        // the reporter's internal allowances (including address(0)) are already granted by
        // OpenPuntBase._armReporter; only the balance needs topping up for native-ETH legs
        vm.prank(reporter);
        oracle.deposit{value: 5_000 ether}(address(0), 5_000 ether, reporter);

        vm.startPrank(adapter);
        oracle.deposit{value: 5_000 ether}(address(0), 5_000 ether, adapter);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        vm.stopPrank();
        _mintAndDeposit(tokenA, adapter, 10_000e18);
        _mintAndDeposit(tokenB, adapter, 10_000e18);
    }

    // ── configuration ───────────────────────────────────────────────────

    function _assetCfg(Legs legs, address collatToken, bool internalPos)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_LONG;
        s.collatToken = collatToken;
        s.useInternalBalances = internalPos;
        s.priceTolerated = OPT;
        s.toleranceRange = 1e6;

        m.initialLiquidity = OA1;
        m.escalationHalt = 100 * OA1;

        if (legs == Legs.EthIsToken1) {
            s.oracleToken1 = address(0);
            s.oracleToken2 = address(tokenB);
        } else if (legs == Legs.EthIsToken2) {
            s.oracleToken1 = address(tokenA);
            s.oracleToken2 = address(0);
        }
    }

    // ── lifecycle at the asset-mode leg sizes ───────────────────────────

    function _openAsset(OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p, Matched memory mt)
    {
        p = _proposeWith(s, m, swapper);
        mt = _matchSwapWith(p, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        active = _executeOpening(mt, executor);
        swapId = p.swapId;
    }

    function _matchAsset(OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
        internal
        returns (Proposal memory p, Matched memory mt)
    {
        p = _proposeWith(s, m, swapper);
        mt = _matchSwapWith(p, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
    }

    function _reportAsset(
        uint256 swapId,
        OpenPuntStorage.CloseDutch memory d,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.MatcherPreimage memory preimage,
        address who,
        uint128 comp
    ) internal returns (Matched memory mt) {
        return _reportOnPositionWithAmounts(swapId, d, active, preimage, who, comp, OA1, OA2);
    }

    // ── purpose-separated ETH accounting ────────────────────────────────

    /// @dev Every distinct claim on the shared address(0) ledger slot, captured separately so
    ///      that cross-accounting between them cannot pass unnoticed.
    struct EthBook {
        uint256 matcherLedger; // oracle-leg capital and, when collateral is ETH, margin
        uint256 reporterLedger; // oracle-leg capital plus compensation the reporter funded
        uint256 swapperLedger;
        uint256 swapperRaw;
        uint256 puntLedger; // position collateral + escrowed compensation
        uint256 puntRaw;
        uint256 openingExecutorLedger; // settler reward from the opening settlement
        uint256 closingExecutorLedger; // execution compensation
        uint256 adapterLedger;
        uint256 designatedLedger;
    }

    function _ethBook(address designated) internal view returns (EthBook memory b) {
        b.matcherLedger = _spendable(matcher, address(0));
        b.reporterLedger = _spendable(reporter, address(0));
        b.swapperLedger = _spendable(swapper, address(0));
        b.swapperRaw = swapper.balance;
        b.puntLedger = _spendable(address(punt), address(0));
        b.puntRaw = address(punt).balance;
        b.openingExecutorLedger = _spendable(executor, address(0));
        b.closingExecutorLedger = _spendable(closeExecutor, address(0));
        b.adapterLedger = _spendable(adapter, address(0));
        b.designatedLedger = designated == address(0) ? 0 : _spendable(designated, address(0));
    }

    /// @dev No spendable oracle-leg residue may sit on the core or the module for any token.
    function _assertNoLegResidue(address token1, address token2) internal view {
        assertEq(_spendable(address(lifecycleModule), token1), 0, "module holds no leg1");
        assertEq(_spendable(address(lifecycleModule), token2), 0, "module holds no leg2");
        assertEq(address(lifecycleModule).balance, 0, "module holds no raw ETH");
        if (token1 != address(0)) {
            assertEq(_spendable(address(punt), token1), 0, "core holds no leg1");
        }
        if (token2 != address(0)) {
            assertEq(_spendable(address(punt), token2), 0, "core holds no leg2");
        }
    }
}
