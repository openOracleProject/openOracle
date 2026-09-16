// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenPuntHelperBase, IV2FactoryMin} from "./OpenPuntHelperBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice `matchWithRoute`: sourcing both opening oracle legs and matcher collateral, with and
 *         without a real Universal Router plan, and completing a genuine match.
 *
 * @dev The three obligations are `initialLiquidity` of oracleToken1, `amount2` of oracleToken2,
 *      and `initialMarginMatcher` of collatToken. They are aggregated by token; the summed requirement
 *      per token is deposited into the helper's own OpenOracle ledger, OpenPunt is granted an
 *      internal allowance over it, and only then is `matchSwap` called.
 *
 *      Every success path decodes `SwapMatched`, checks that the emitted `MatchedSwap` reconstructs
 *      `swaps[swapId]`, settles the genuine
 *      opening oracle game, and executes the opening through the core. A route that produced the
 *      right balances but a position that could not proceed would fail at those steps.
 *
 *      Venue coverage is V2/V3 in both directions plus V4 exact-input. V4 exact-output and the
 *      command-classification matrix live in `RoutingAndValidation.t.sol`.
 *
 *      Collateral, both oracle legs, compensation, and refunds are asserted separately. Aggregate
 *      ETH assertions are avoided because matcher gas
 *      compensation, the settler reward, and any ETH oracle leg all share `address(0)`, so a net
 *      figure can hide two errors cancelling out.
 */
contract MatchWithRouteTest is OpenPuntHelperBase {
    function setUp() public override {
        super.setUp();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));
    }

    // ────────────────────────────────────────────────────────────────────
    //  no route
    // ────────────────────────────────────────────────────────────────────

    /// @dev Three distinct ERC20 assets, everything supplied outright. The router calldata is
    ///      absent and `_hasShortfall` is false, so no routing happens at all.
    function test_fullySuppliedMatchWithThreeDistinctAssets() public {
        Proposal memory p = _propose();

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 b0 = tokenB.balanceOf(funder);
        uint256 c0 = collat.balanceOf(funder);

        Matched memory mt =
            _match(p, designatedMatcher, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false), 0);

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY, "oracle leg 1 debit");
        assertEq(b0 - tokenB.balanceOf(funder), AMOUNT2, "oracle leg 2 debit");
        assertEq(c0 - collat.balanceOf(funder), INITIAL_MARGIN_MATCHER, "collateral debit");
        _assertMatchedAndExecutable(mt);
        _assertHelperClean();
    }

    /// @dev Oversupplying every asset must refund the excess per asset, not net across them.
    function test_oversupplyIsRefundedPerAsset() public {
        Proposal memory p = _propose();

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 b0 = tokenB.balanceOf(funder);
        uint256 c0 = collat.balanceOf(funder);

        Matched memory mt = _match(
            p,
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY + 7e18, AMOUNT2 + 9e18, INITIAL_MARGIN_MATCHER + 11e18, false),
            0
        );

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY, "leg 1 oversupply not refunded");
        assertEq(b0 - tokenB.balanceOf(funder), AMOUNT2, "leg 2 oversupply not refunded");
        assertEq(c0 - collat.balanceOf(funder), INITIAL_MARGIN_MATCHER, "collateral oversupply not refunded");
        _assertMatchedAndExecutable(mt);
        _assertHelperClean();
    }

    /// @dev Undersupplying with no route offered fails in `_executeRoute` on the zero maximum,
    ///      before any router interaction.
    function test_shortWithNoRouteIsRejected() public {
        Proposal memory p = _propose();

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMaximumSwapInput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY - 1, AMOUNT2, INITIAL_MARGIN_MATCHER, false),
            router
        );
    }

    // ────────────────────────────────────────────────────────────────────
    //  one input token, multiple obligations
    // ────────────────────────────────────────────────────────────────────

    /// @dev A single third token routes into both oracle legs, with collateral supplied directly.
    function test_oneInputTokenRoutesIntoBothOracleLegs() public {
        Proposal memory p = _propose();

        uint256 maxIn = 6000e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(cj, ij, address(tokenC));

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 b0 = tokenB.balanceOf(funder);
        uint256 tc0 = tokenC.balanceOf(funder);

        Matched memory mt = _match(
            p,
            designatedMatcher,
            _routeFunding(0, 0, INITIAL_MARGIN_MATCHER, false, address(tokenC), maxIn, cmds, ins),
            0
        );

        assertEq(tokenA.balanceOf(funder), a0, "leg 1 must have come from the route");
        assertEq(tokenB.balanceOf(funder), b0, "leg 2 must have come from the route");
        uint256 spentC = tc0 - tokenC.balanceOf(funder);
        assertGt(spentC, 0, "the route consumed nothing");
        assertLt(spentC, maxIn, "the unused input was not swept back and refunded");
        _assertMatchedAndExecutable(mt);
        _assertHelperClean();
    }

    /// @dev One route sources all three obligations: both oracle legs and the collateral.
    function test_oneRouteSourcesBothLegsAndCollateral() public {
        Proposal memory p = _propose();

        uint256 maxIn = 8000e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory c3, bytes[] memory i3) =
            _v2ExactOut(address(tokenC), address(collat), INITIAL_MARGIN_MATCHER, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory ck, bytes[] memory ik) = _join(cj, ij, c3, i3);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(ck, ik, address(tokenC));

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 b0 = tokenB.balanceOf(funder);
        uint256 col0 = collat.balanceOf(funder);

        Matched memory mt =
            _match(p, designatedMatcher, _routeFunding(0, 0, 0, false, address(tokenC), maxIn, cmds, ins), 0);

        assertEq(tokenA.balanceOf(funder), a0, "leg 1 must have come from the route");
        assertEq(tokenB.balanceOf(funder), b0, "leg 2 must have come from the route");
        assertEq(collat.balanceOf(funder), col0, "collateral must have come from the route");
        _assertMatchedAndExecutable(mt);
        _assertHelperClean();
    }

    // ────────────────────────────────────────────────────────────────────
    //  venue and direction coverage
    // ────────────────────────────────────────────────────────────────────

    function test_v3ExactOutputRouteFundsALeg() public {
        _assertSingleLegRoute(_V3_EXACT_OUT);
    }

    function test_v3ExactInputRouteFundsALeg() public {
        _assertSingleLegRoute(_V3_EXACT_IN);
    }

    function test_v4ExactInputRouteFundsALeg() public {
        _assertSingleLegRoute(_V4_EXACT_IN);
    }

    function test_v2ExactInputRouteFundsALeg() public {
        _assertSingleLegRoute(_V2_EXACT_IN);
    }

    uint8 internal constant _V2_EXACT_IN = 0;
    uint8 internal constant _V3_EXACT_OUT = 1;
    uint8 internal constant _V3_EXACT_IN = 2;
    uint8 internal constant _V4_EXACT_IN = 3;

    /// @dev Routes tokenC into the token1 leg on the chosen venue; the other two obligations are
    ///      supplied directly so the assertion isolates the routed asset.
    function _assertSingleLegRoute(uint8 kind) internal {
        Proposal memory p = _propose();

        uint256 maxIn = 5e18;
        bytes memory cmds;
        bytes[] memory ins;

        if (kind == _V2_EXACT_IN) {
            (cmds, ins) = _v2ExactIn(address(tokenC), address(tokenA), maxIn, INITIAL_LIQUIDITY);
        } else if (kind == _V3_EXACT_OUT) {
            (cmds, ins) = _v3ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        } else if (kind == _V3_EXACT_IN) {
            (cmds, ins) = _v3ExactIn(address(tokenC), address(tokenA), maxIn, INITIAL_LIQUIDITY);
        } else {
            (cmds, ins) =
                _v4ExactInSingle(address(tokenC), address(tokenA), uint128(maxIn), INITIAL_LIQUIDITY, address(0));
        }
        (cmds, ins) = _withSweep(cmds, ins, address(tokenC));

        uint256 a0 = tokenA.balanceOf(funder);

        Matched memory mt = _match(
            p,
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), maxIn, cmds, ins),
            0
        );

        // `suppliedAmount1` is zero, so no token1 is ever pulled from the wallet. An exact-output
        // route buys precisely the requirement and leaves the balance untouched; an exact-input
        // route spends the whole budget, overshoots, and the excess token1 is refunded — so the
        // wallet ends up strictly richer. Either way the leg itself came from the route.
        if (kind == _V3_EXACT_OUT) {
            assertEq(tokenA.balanceOf(funder), a0, "an exact-output route should buy exactly the requirement");
        } else {
            assertGt(tokenA.balanceOf(funder), a0, "the exact-input overshoot should be refunded to the caller");
        }
        _assertMatchedAndExecutable(mt);
        _assertHelperClean();
    }

    // ────────────────────────────────────────────────────────────────────
    //  native ETH collateral
    // ────────────────────────────────────────────────────────────────────

    /// @dev With ETH collateral the third obligation shares `address(0)`. msg.value must cover it
    ///      exactly, and the collateral must be asserted on its own rather than netted against the
    ///      matcher gas compensation that also moves in ETH.
    function test_ethCollateralIsFundedThroughMsgValue() public {
        Proposal memory p = _proposeEthCollateral();

        uint256 e0 = funder.balance;
        uint256 matcherTemp = punt.tempHolding(designatedMatcher);

        Matched memory mt =
            _match(p, designatedMatcher, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, ETH_MARGIN, false), ETH_MARGIN);

        assertEq(e0 - funder.balance, ETH_MARGIN, "the funder must pay exactly the ETH collateral");
        assertEq(
            punt.tempHolding(designatedMatcher) - matcherTemp,
            MATCHER_GAS_COMP,
            "gas comp is a separate ETH flow and must reach the matcher"
        );
        assertEq(address(helper).balance, 0, "the helper retained ETH");
        _assertMatchedAndExecutable(mt);
    }

    /// @dev Excess ETH is accepted when ETH is a tracked asset and refunded after the match.
    function test_ethCollateralRefundsExcessValue() public {
        Proposal memory p = _proposeEthCollateral();

        uint256 e0 = funder.balance;
        vm.prank(funder);
        helper.matchWithRoute{value: ETH_MARGIN + 1}(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, ETH_MARGIN, false),
            router
        );

        assertEq(e0 - funder.balance, ETH_MARGIN, "excess ETH was not refunded");
        assertEq(address(helper).balance, 0, "helper retained excess ETH");
    }

    function test_ethCollateralRejectsInsufficientValue() public {
        Proposal memory p = _proposeEthCollateral();

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMsgValue.selector);
        helper.matchWithRoute{value: ETH_MARGIN - 1}(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, ETH_MARGIN, false),
            router
        );
    }

    /// @dev A route that produces the ETH collateral by unwrapping WETH. The ETH obligation is an
    ///      aggregated asset, so the route budget rides inside `suppliedAmount3`'s surplus.
    function test_ethCollateralCanBeRoutedFromAnEthSurplus() public {
        Proposal memory p = _proposeEthCollateral();

        // Supply the collateral requirement plus a routing surplus, all in ETH.
        uint256 routeBudget = 3 ether;
        uint256 supplied3 = ETH_MARGIN + routeBudget;

        // Route the surplus ETH into token1 so the leg need not be supplied directly.
        bytes memory path = abi.encodePacked(address(tokenA), V3_FEE, address(weth));
        bytes memory cmds = abi.encodePacked(CMD_WRAP_ETH, CMD_V3_SWAP_EXACT_OUT, CMD_UNWRAP_WETH);
        bytes[] memory ins = new bytes[](3);
        ins[0] = abi.encode(router, routeBudget);
        ins[1] = abi.encode(address(helper), INITIAL_LIQUIDITY, routeBudget, path, false, _noHopPrices());
        ins[2] = abi.encode(address(helper), uint256(0));
        (cmds, ins) = _withSweep(cmds, ins, ETH_ASSET);

        uint256 a0 = tokenA.balanceOf(funder);

        Matched memory mt = _match(
            p,
            designatedMatcher,
            _routeFunding(0, AMOUNT2, supplied3, false, ETH_ASSET, routeBudget, cmds, ins),
            supplied3
        );

        assertEq(tokenA.balanceOf(funder), a0, "the token1 leg must have come from the ETH route");
        _assertMatchedAndExecutable(mt);
        assertEq(address(helper).balance, 0, "the helper retained ETH");
    }

    /// @dev Native V4 consumes ETH without wrapping it. The mandatory zero-minimum unwrap is a
    ///      no-op, then the final ETH sweep returns the unused exact-output budget.
    function test_nativeV4RouteAcceptsTheWethCleanupNoOp() public {
        Proposal memory p = _propose();
        uint256 routeBudget = 2 ether;

        (bytes memory cmds, bytes[] memory ins) =
            _v4ExactOutSingle(ETH_ASSET, address(tokenA), INITIAL_LIQUIDITY, uint128(routeBudget));
        bytes[] memory unwrapInput = new bytes[](1);
        unwrapInput[0] = abi.encode(address(helper), uint256(0));
        (cmds, ins) = _join(cmds, ins, abi.encodePacked(CMD_UNWRAP_WETH), unwrapInput);
        (cmds, ins) = _withSweep(cmds, ins, ETH_ASSET);

        uint256 funderEthBefore = funder.balance;
        Matched memory mt = _match(
            p,
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, ETH_ASSET, routeBudget, cmds, ins),
            routeBudget
        );

        assertGt(funder.balance, funderEthBefore - routeBudget, "unused native input was not refunded");
        assertEq(address(helper).balance, 0, "the helper retained ETH");
        _assertMatchedAndExecutable(mt);
    }

    // ────────────────────────────────────────────────────────────────────
    //  designated matcher separation under routing
    // ────────────────────────────────────────────────────────────────────

    /// @dev The routed variant of the funder/designation split: capital is routed from the caller's
    ///      tokenC while the designated matcher gains the position and the compensation.
    function test_routedMatchStillCreditsTheDesignatedMatcher() public {
        Proposal memory p = _propose();
        _approveMatcherLegs(attacker, address(tokenA), address(tokenB));

        uint256 maxIn = 6000e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(cj, ij, address(tokenC));

        uint256 attackerTemp = punt.tempHolding(attacker);
        uint256 funderTemp = punt.tempHolding(funder);

        Matched memory mt = _match(
            p, attacker, _routeFunding(0, 0, INITIAL_MARGIN_MATCHER, false, address(tokenC), maxIn, cmds, ins), 0
        );

        assertEq(mt.swap.matcher, attacker, "the designated matcher must be recorded");
        assertEq(punt.tempHolding(attacker) - attackerTemp, MATCHER_GAS_COMP, "gas comp follows the designation");
        assertEq(punt.tempHolding(funder), funderTemp, "the funder must not be compensated");
        _assertMatchedAndExecutable(mt);
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    uint128 internal constant ETH_MARGIN = 5 ether;

    /// @dev A proposal whose collateral token is native ETH, built through the real `propose`.
    function _proposeEthCollateral() internal returns (Proposal memory) {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.collatToken = ETH_ASSET;
        s.initialMarginSwapper = ETH_MARGIN;
        s.initialMarginMatcher = ETH_MARGIN;
        s.maintenanceMarginSwapper = 1 ether;
        s.notional = 50 ether;
        return _proposeWith(s, _defaultMatcherPreimage(), swapper);
    }

    function _match(Proposal memory p, address who, OpenPuntHelper.RouteFunding memory route, uint256 value)
        internal
        returns (Matched memory mt)
    {
        vm.recordLogs();
        vm.prank(funder);
        helper.matchWithRoute{value: value}(p.swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), who, route, router);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        mt.swapId = p.swapId;
        (mt.reportId, mt.swap) = _decodeSwapMatched(logs, p.swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);
    }

    /// @dev The emitted MatchedSwap must reconstruct the stored hash, the genuine opening oracle
    ///      game must settle, and the opening must execute through the core.
    function _assertMatchedAndExecutable(Matched memory mt) internal {
        assertEq(
            punt.swaps(mt.swapId),
            keccak256(abi.encode(mt.swap)),
            "the emitted MatchedSwap does not reconstruct swaps[swapId]"
        );
        assertEq(punt.swapIdToReportId(mt.swapId), mt.reportId, "the sidecar report id disagrees with the oracle game");

        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory opened = _executeOpening(mt, executor);
        assertTrue(opened.active, "the position did not open");
    }

    /// @dev No new external or internal assets may remain on the helper. One sentinel per touched
    ///      token is normal: `deposit` seeds it and OpenPunt spends the rest.
    function _assertHelperClean() internal view {
        assertEq(tokenA.balanceOf(address(helper)), 0, "helper retained token1");
        assertEq(tokenB.balanceOf(address(helper)), 0, "helper retained token2");
        assertEq(collat.balanceOf(address(helper)), 0, "helper retained collateral");
        assertEq(tokenC.balanceOf(address(helper)), 0, "helper retained route input");
        assertEq(address(helper).balance, 0, "helper retained ETH");

        assertLe(oracle.tokenHolder(address(helper), address(tokenA)), 1, "helper retained internal token1");
        assertLe(oracle.tokenHolder(address(helper), address(tokenB)), 1, "helper retained internal token2");
        assertLe(oracle.tokenHolder(address(helper), address(collat)), 1, "helper retained internal collateral");
        assertLe(oracle.tokenHolder(address(helper), ETH_ASSET), 1, "helper retained internal ETH");
    }
}
