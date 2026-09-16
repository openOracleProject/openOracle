// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenPuntHelperBase} from "./OpenPuntHelperBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice `RouteFunding.tryInternalBalances`: sourcing each declared budget from the caller's
 *         OpenOracle ledger before touching their wallet.
 *
 * @dev For every aggregated asset and separate route input, the helper
 *      takes `min(declared, spendable, allowance)` via one `internalTransferFrom`, withdraws it to
 *      itself, and pulls only the remainder externally. `spendable` excludes the 1-unit sentinel.
 *
 *      When collateral shares a token with an oracle leg,
 *      `_addAsset` has already summed them, so the internal draw is made against one combined
 *      budget rather than two independent pulls. `test_aMergedTokenIsSourcedAsOneCombinedBudget`
 *      pins that: an internal balance smaller than the combined requirement but larger than either
 *      component must be drawn once and topped up once.
 *
 *      `msg.value` covers only the external ETH remainder. ETH sourced internally arrives by
 *      withdrawal, never by call value, so the two must not be double counted.
 *
 *      Every balance below comes from a real `deposit()` and every allowance from a real
 *      `approveInternal()`; no ledger is written directly.
 */
contract InternalBalanceFundingTest is OpenPuntHelperBase {
    function setUp() public override {
        super.setUp();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));
        _approveReporterLegs(designatedReporter, address(tokenA), address(tokenB));
    }

    // ────────────────────────────────────────────────────────────────────
    //  the flag is opt-in
    // ────────────────────────────────────────────────────────────────────

    /// @dev With the flag false a fully funded internal balance is ignored entirely.
    function test_flagFalseIgnoresInternalBalances() public {
        Proposal memory p = _propose();
        _fundInternal(address(tokenA), INITIAL_LIQUIDITY, type(uint256).max);

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 i0 = oracle.tokenHolder(funder, address(tokenA));

        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false), 0);

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY, "the wallet must pay in full");
        assertEq(oracle.tokenHolder(funder, address(tokenA)), i0, "the internal balance must be untouched");
    }

    // ────────────────────────────────────────────────────────────────────
    //  each match obligation, full and partial
    // ────────────────────────────────────────────────────────────────────

    function test_matchOracleToken1FullyInternal() public {
        Proposal memory p = _propose();
        _fundInternal(address(tokenA), INITIAL_LIQUIDITY, type(uint256).max);

        uint256 a0 = tokenA.balanceOf(funder);
        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true), 0);

        assertEq(tokenA.balanceOf(funder), a0, "no external token1 should have been pulled");
        assertEq(oracle.tokenHolder(funder, address(tokenA)), 1, "the sentinel must survive and nothing more");
    }

    function test_matchOracleToken1PartiallyInternal() public {
        Proposal memory p = _propose();
        uint256 internalPart = INITIAL_LIQUIDITY / 4;
        _fundInternal(address(tokenA), internalPart, type(uint256).max);

        uint256 a0 = tokenA.balanceOf(funder);
        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true), 0);

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY - internalPart, "wallet pays only the remainder");
        assertEq(oracle.tokenHolder(funder, address(tokenA)), 1, "internal balance drained to the sentinel");
    }

    function test_matchOracleToken2FullyInternal() public {
        Proposal memory p = _propose();
        _fundInternal(address(tokenB), AMOUNT2, type(uint256).max);

        uint256 b0 = tokenB.balanceOf(funder);
        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true), 0);

        assertEq(tokenB.balanceOf(funder), b0, "no external token2 should have been pulled");
        assertEq(oracle.tokenHolder(funder, address(tokenB)), 1, "sentinel only");
    }

    function test_matcherCollateralFullyInternal() public {
        Proposal memory p = _propose();
        _fundInternal(address(collat), INITIAL_MARGIN_MATCHER, type(uint256).max);

        uint256 c0 = collat.balanceOf(funder);
        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true), 0);

        assertEq(collat.balanceOf(funder), c0, "no external collateral should have been pulled");
        assertEq(oracle.tokenHolder(funder, address(collat)), 1, "sentinel only");
    }

    function test_matcherCollateralPartiallyInternal() public {
        Proposal memory p = _propose();
        uint256 internalPart = 250e18;
        _fundInternal(address(collat), internalPart, type(uint256).max);

        uint256 c0 = collat.balanceOf(funder);
        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true), 0);

        assertEq(c0 - collat.balanceOf(funder), INITIAL_MARGIN_MATCHER - internalPart, "wallet pays the remainder");
    }

    /// @dev All three obligations internal at once.
    function test_allThreeMatchObligationsFullyInternal() public {
        Proposal memory p = _propose();
        _fundInternal(address(tokenA), INITIAL_LIQUIDITY, type(uint256).max);
        _fundInternal(address(tokenB), AMOUNT2, type(uint256).max);
        _fundInternal(address(collat), INITIAL_MARGIN_MATCHER, type(uint256).max);

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 b0 = tokenB.balanceOf(funder);
        uint256 c0 = collat.balanceOf(funder);

        Matched memory mt = _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true), 0);

        assertEq(tokenA.balanceOf(funder), a0, "token1 wallet untouched");
        assertEq(tokenB.balanceOf(funder), b0, "token2 wallet untouched");
        assertEq(collat.balanceOf(funder), c0, "collateral wallet untouched");
        assertEq(mt.swap.matcher, designatedMatcher, "the match must still complete");
        _assertHelperClean();
    }

    // ────────────────────────────────────────────────────────────────────
    //  the merged-asset case
    // ────────────────────────────────────────────────────────────────────

    /// @dev collatToken == oracleToken1, so `_addAsset` has already summed leg and collateral into
    ///      one budget. An internal balance between one component and the sum must be drawn once
    ///      against the combined figure, with a single external top-up — not two separate pulls.
    function test_aMergedTokenIsSourcedAsOneCombinedBudget() public {
        Proposal memory p = _proposeCollat(address(tokenA));
        uint256 combined = uint256(INITIAL_LIQUIDITY) + COLLAT_MARGIN;

        // Larger than either component, smaller than the sum.
        // combined = 1e18 + 800e18 = 801e18, so this sits strictly between the larger component
        // (800e18) and the sum.
        uint256 internalPart = COLLAT_MARGIN + 0.5e18;
        assertLt(internalPart, combined, "precondition: must not cover the whole combined budget");
        assertGt(internalPart, INITIAL_LIQUIDITY, "precondition: must exceed the leg alone");
        _fundInternal(address(tokenA), internalPart, type(uint256).max);

        uint256 a0 = tokenA.balanceOf(funder);

        Matched memory mt = _match(p, _noRouteFunding(combined, AMOUNT2, 0, true), 0);

        assertEq(
            a0 - tokenA.balanceOf(funder),
            combined - internalPart,
            "the wallet must top up the COMBINED budget exactly once"
        );
        assertEq(oracle.tokenHolder(funder, address(tokenA)), 1, "internal balance drained to the sentinel");
        // Both purposes still land independently.
        assertEq(mt.game.currentAmount1, INITIAL_LIQUIDITY, "the leg component was not funded");
        assertEq(mt.swap.initialMarginMatcher, COLLAT_MARGIN, "the collateral component was not recorded");
    }

    // ────────────────────────────────────────────────────────────────────
    //  allowance and balance ceilings
    // ────────────────────────────────────────────────────────────────────

    function test_allowanceBelowBalanceCapsTheDraw() public {
        Proposal memory p = _propose();
        _fundInternal(address(tokenA), INITIAL_LIQUIDITY, INITIAL_LIQUIDITY / 5);

        uint256 a0 = tokenA.balanceOf(funder);
        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true), 0);

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY - INITIAL_LIQUIDITY / 5, "allowance binds");
        assertEq(_spendable(funder, address(tokenA)), INITIAL_LIQUIDITY - INITIAL_LIQUIDITY / 5, "balance remains");
        assertEq(oracle.internalAllowance(funder, address(helper), address(tokenA)), 0, "allowance fully consumed");
    }

    function test_balanceBelowAllowanceCapsTheDraw() public {
        Proposal memory p = _propose();
        uint256 small = INITIAL_LIQUIDITY / 5;
        _fundInternal(address(tokenA), small, INITIAL_LIQUIDITY);

        uint256 a0 = tokenA.balanceOf(funder);
        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true), 0);

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY - small, "balance binds");
        assertEq(oracle.tokenHolder(funder, address(tokenA)), 1, "drained to the sentinel");
        assertEq(
            oracle.internalAllowance(funder, address(helper), address(tokenA)),
            INITIAL_LIQUIDITY - small,
            "the allowance must fall by exactly what was taken"
        );
    }

    /// @dev No allowance means no internal draw, however large the balance.
    function test_withoutAnAllowanceNothingIsDrawn() public {
        Proposal memory p = _propose();
        _fundInternal(address(tokenA), INITIAL_LIQUIDITY, 0);

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 i0 = oracle.tokenHolder(funder, address(tokenA));

        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true), 0);

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY, "the wallet must pay in full");
        assertEq(oracle.tokenHolder(funder, address(tokenA)), i0, "the internal balance must be untouched");
    }

    /// @dev A balance of exactly the sentinel is not spendable.
    function test_theSentinelAloneIsNotSpendable() public {
        Proposal memory p = _propose();
        _fundInternal(address(tokenA), 0, type(uint256).max);
        assertEq(oracle.tokenHolder(funder, address(tokenA)), 1, "precondition: sentinel only");

        uint256 a0 = tokenA.balanceOf(funder);
        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true), 0);

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY, "the wallet must pay in full");
        assertEq(oracle.tokenHolder(funder, address(tokenA)), 1, "the sentinel must survive");
    }

    // ────────────────────────────────────────────────────────────────────
    //  ETH
    // ────────────────────────────────────────────────────────────────────

    /// @dev Report execution compensation sourced entirely from the internal ETH ledger, so
    ///      msg.value must be zero.
    function test_reportExecutionCompensationFullyInternalTakesNoMsgValue() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openPositionForReport();

        _fundInternal(ETH_ASSET, REPORT_EXEC_COMP, type(uint256).max);

        uint256 e0 = funder.balance;

        vm.prank(funder);
        helper.reportWithRoute{value: 0}(
            sid,
            bytes32(0),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, true),
            router
        );

        assertEq(funder.balance, e0, "no external ETH should have moved");
        assertEq(oracle.tokenHolder(funder, ETH_ASSET), 1, "internal ETH drained to the sentinel");
    }

    function test_reportExecutionCompensationPartiallyInternal() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openPositionForReport();

        uint128 internalPart = REPORT_EXEC_COMP / 5;
        _fundInternal(ETH_ASSET, internalPart, type(uint256).max);

        uint256 e0 = funder.balance;
        uint256 external_ = uint256(REPORT_EXEC_COMP) - internalPart;

        vm.prank(funder);
        helper.reportWithRoute{value: external_}(
            sid,
            bytes32(0),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, true),
            router
        );

        assertEq(e0 - funder.balance, external_, "only the external remainder may leave the wallet");
    }

    /// @dev A stale caller estimate may overpay after an internal ETH credit. The helper accepts
    ///      the surplus and refunds it instead of making the credit a one-wei denial of service.
    function test_partiallyInternalEthRefundsOneWeiOverpayment() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openPositionForReport();

        uint128 internalPart = REPORT_EXEC_COMP / 5;
        _fundInternal(ETH_ASSET, internalPart, type(uint256).max);
        uint256 external_ = uint256(REPORT_EXEC_COMP) - internalPart;

        uint256 e0 = funder.balance;
        vm.prank(funder);
        helper.reportWithRoute{value: external_ + 1}(
            sid,
            bytes32(0),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, true),
            router
        );

        assertEq(e0 - funder.balance, external_, "the ETH surplus was not refunded");
        assertEq(address(helper).balance, 0, "helper retained the ETH surplus");
    }

    function test_partiallyInternalEthRejectsOneWeiUnderpayment() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openPositionForReport();

        uint128 internalPart = REPORT_EXEC_COMP / 5;
        _fundInternal(ETH_ASSET, internalPart, type(uint256).max);
        uint256 external_ = uint256(REPORT_EXEC_COMP) - internalPart;

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMsgValue.selector);
        helper.reportWithRoute{value: external_ - 1}(
            sid,
            bytes32(0),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, true),
            router
        );
    }

    /// @dev A third party may credit one wei to the caller's oracle ETH balance. A transaction
    ///      prepared before that credit remains valid: the newly internal wei is used and the
    ///      now-excess call value is returned.
    function test_thirdPartyInternalEthCreditCannotInvalidatePreparedCallValue() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openPositionForReport();

        _approveInternalToHelper(funder, ETH_ASSET, type(uint256).max);
        vm.prank(attacker);
        oracle.deposit{value: 1}(ETH_ASSET, 1, funder);

        uint256 e0 = funder.balance;
        vm.prank(funder);
        helper.reportWithRoute{value: REPORT_EXEC_COMP}(
            sid,
            bytes32(0),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, true),
            router
        );

        assertEq(e0 - funder.balance, REPORT_EXEC_COMP - 1, "the credited wei was not used");
        assertEq(oracle.tokenHolder(funder, ETH_ASSET), 1, "only the sentinel should remain");
        assertEq(address(helper).balance, 0, "helper retained ETH");
    }

    /// @dev The helper must use the oracle's returned withdrawal amount, not merely assume that
    ///      the requested amount was delivered.
    function test_internalWithdrawalUnderDeliveryRevertsImmediately() public {
        Proposal memory p = _propose();
        _fundInternal(address(tokenA), INITIAL_LIQUIDITY, type(uint256).max);

        vm.mockCall(
            address(oracle),
            abi.encodeCall(IOpenOracle2.withdrawTo, (address(tokenA), INITIAL_LIQUIDITY, address(helper))),
            abi.encode(uint256(INITIAL_LIQUIDITY - 1))
        );

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InternalWithdrawalShortfall.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true),
            router
        );
        vm.clearMockedCalls();
    }

    // ────────────────────────────────────────────────────────────────────
    //  a separate route input
    // ────────────────────────────────────────────────────────────────────

    /// @dev tokenC is not an aggregated asset, so its budget is a separate pull that also honours
    ///      the internal-first rule.
    function test_separateRouteInputFullyInternal() public {
        Proposal memory p = _propose();

        uint256 maxIn = 6000e18;
        _fundInternal(address(tokenC), maxIn, type(uint256).max);

        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(cj, ij, address(tokenC));

        uint256 tc0 = tokenC.balanceOf(funder);

        _match(p, _routeFunding(0, 0, INITIAL_MARGIN_MATCHER, true, address(tokenC), maxIn, cmds, ins), 0);

        // The whole budget came from the ledger; the swept remainder returns to the wallet.
        assertEq(oracle.tokenHolder(funder, address(tokenC)), 1, "route budget drained to the sentinel");
        assertGt(tokenC.balanceOf(funder), tc0, "the unspent internal budget should return externally");
        _assertHelperClean();
    }

    function test_separateRouteInputPartiallyInternal() public {
        Proposal memory p = _propose();

        uint256 maxIn = 6000e18;
        uint256 internalPart = 2000e18;
        _fundInternal(address(tokenC), internalPart, type(uint256).max);

        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(cj, ij, address(tokenC));

        uint256 tc0 = tokenC.balanceOf(funder);

        _match(p, _routeFunding(0, 0, INITIAL_MARGIN_MATCHER, true, address(tokenC), maxIn, cmds, ins), 0);

        assertEq(oracle.tokenHolder(funder, address(tokenC)), 1, "internal part drained to the sentinel");
        // The wallet supplied maxIn - internalPart and got the sweep back, so the net is smaller.
        assertLt(tc0 - tokenC.balanceOf(funder), maxIn - internalPart, "the sweep should offset the external pull");
    }

    // ────────────────────────────────────────────────────────────────────
    //  the uint128 ceiling
    // ────────────────────────────────────────────────────────────────────

    /// @dev `internalTransferFrom` takes a uint128, so a larger internal draw is rejected rather
    ///      than truncated. Reaching it needs two deposits, since `deposit` is itself uint128.
    function test_anInternalDrawAboveUint128MaxIsRejected() public {
        Proposal memory p = _propose();

        uint256 huge = uint256(type(uint128).max);
        tokenA.mint(funder, 2 * huge);
        _depositInternal(funder, address(tokenA), huge);
        _depositInternal(funder, address(tokenA), huge);
        _approveInternalToHelper(funder, address(tokenA), type(uint256).max);

        assertGt(_spendable(funder, address(tokenA)), huge, "precondition: spendable exceeds uint128.max");

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMaximumSwapInput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(2 * huge, AMOUNT2, INITIAL_MARGIN_MATCHER, true),
            router
        );
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    uint128 internal constant COLLAT_MARGIN = 800e18;

    /// @dev A real deposit plus a real internal approval to the helper.
    function _fundInternal(address token, uint256 amount, uint256 allowance) internal {
        if (token == ETH_ASSET) {
            _depositInternal(funder, ETH_ASSET, amount);
        } else {
            _depositInternal(funder, token, amount);
        }
        _approveInternalToHelper(funder, token, allowance);
    }

    function _proposeCollat(address token) internal returns (Proposal memory) {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.collatToken = token;
        s.initialMarginSwapper = COLLAT_MARGIN;
        s.initialMarginMatcher = COLLAT_MARGIN;
        s.maintenanceMarginSwapper = 150e18;
        s.notional = 8000e18;

        MintableLike(token).mint(swapper, 1_000_000e18);
        vm.prank(swapper);
        MintableLike(token).approve(PERMIT2, type(uint256).max);

        return _proposeWith(s, _defaultMatcherPreimage(), swapper);
    }

    function _openPositionForReport()
        internal
        returns (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre)
    {
        Proposal memory p = _propose();
        pre = p.preimage;
        Matched memory mt = _matchSwap(p);
        _advanceToSettlementEligibility();
        live = _executeOpening(mt, executor);
        sid = p.swapId;
    }

    function _match(Proposal memory p, OpenPuntHelper.RouteFunding memory route, uint256 value)
        internal
        returns (Matched memory mt)
    {
        vm.recordLogs();
        vm.prank(funder);
        helper.matchWithRoute{value: value}(
            p.swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), designatedMatcher, route, router
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        mt.swapId = p.swapId;
        (mt.reportId, mt.swap) = _decodeSwapMatched(logs, p.swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);
    }

    function _assertHelperClean() internal view {
        assertEq(tokenA.balanceOf(address(helper)), 0, "helper retained token1");
        assertEq(tokenB.balanceOf(address(helper)), 0, "helper retained token2");
        assertEq(collat.balanceOf(address(helper)), 0, "helper retained collateral");
        assertEq(tokenC.balanceOf(address(helper)), 0, "helper retained route input");
        assertEq(address(helper).balance, 0, "helper retained ETH");
        assertLe(oracle.tokenHolder(address(helper), address(tokenA)), 1, "internal token1 beyond the sentinel");
        assertLe(oracle.tokenHolder(address(helper), address(tokenB)), 1, "internal token2 beyond the sentinel");
        assertLe(oracle.tokenHolder(address(helper), address(collat)), 1, "internal collateral beyond the sentinel");
        assertLe(oracle.tokenHolder(address(helper), address(tokenC)), 1, "internal route input beyond the sentinel");
        assertLe(oracle.tokenHolder(address(helper), ETH_ASSET), 1, "internal ETH beyond the sentinel");
    }
}

interface MintableLike {
    function mint(address, uint256) external;
    function approve(address, uint256) external returns (bool);
}
