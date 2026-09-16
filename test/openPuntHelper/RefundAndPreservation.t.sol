// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenPuntHelperBase} from "./OpenPuntHelperBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice Preexisting helper balances are preserved, and refunds are deltas rather than sweeps.
 *
 * @dev `_assertFullyFunded` compares against
 *      `startBalance + required`, not against `required` alone, and `_refundDelta` returns
 *      `current - start`, not `current`. Without a preexisting balance both checks
 *      degrade silently: the oracle deposit would revert on its own if the helper were truly
 *      short, and a sweep-style refund would look identical to a delta refund. A donated balance is
 *      the only thing that separates them.
 *
 *      Anyone can send tokens or ETH to the helper, so a donation is not a contrived state.
 */
contract RefundAndPreservationTest is OpenPuntHelperBase {
    uint256 internal constant DONATION = 5_000e18;
    uint256 internal constant ETH_DONATION = 7 ether;

    struct HelperBalances {
        uint256 externalA;
        uint256 externalB;
        uint256 externalCollateral;
        uint256 externalRouteInput;
        uint256 externalEth;
        uint256 internalA;
        uint256 internalB;
        uint256 internalCollateral;
        uint256 internalRouteInput;
    }

    function setUp() public override {
        super.setUp();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));
        _approveReporterLegs(designatedReporter, address(tokenA), address(tokenB));
    }

    // ────────────────────────────────────────────────────────────────────
    //  a donation cannot be spent as funding
    // ────────────────────────────────────────────────────────────────────

    /// @dev A donation that would exactly cover the collateral must not satisfy it. Only
    ///      `_assertFullyFunded`'s snapshot term stops this: the oracle deposit alone would happily
    ///      spend the donated balance.
    function test_aDonationCannotSubstituteForCollateral() public {
        Proposal memory p = _propose();
        collat.mint(address(helper), INITIAL_MARGIN_MATCHER);

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InsufficientRouterOutput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            // Collateral declared as supplied but never actually provided; a route is offered so the
            // shortfall path is entered rather than tripping the zero-maximum check.
            _routeFunding(INITIAL_LIQUIDITY, AMOUNT2, 0, false, address(tokenC), 1e18, _inertRoute(), _inertInputs()),
            router
        );

        assertEq(collat.balanceOf(address(helper)), INITIAL_MARGIN_MATCHER, "the donation must still be there");
    }

    /// @dev The same for an oracle leg, proving the assertion covers every aggregated asset rather
    ///      than only the first.
    function test_aDonationCannotSubstituteForTheLastAsset() public {
        Proposal memory p = _propose();
        collat.mint(address(helper), INITIAL_MARGIN_MATCHER);
        tokenA.mint(address(helper), INITIAL_LIQUIDITY);
        tokenB.mint(address(helper), AMOUNT2);

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InsufficientRouterOutput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, 0, 0, false, address(tokenC), 1e18, _inertRoute(), _inertInputs()),
            router
        );

        assertEq(tokenA.balanceOf(address(helper)), INITIAL_LIQUIDITY, "token1 donation consumed");
        assertEq(tokenB.balanceOf(address(helper)), AMOUNT2, "token2 donation consumed");
        assertEq(collat.balanceOf(address(helper)), INITIAL_MARGIN_MATCHER, "collateral donation consumed");
    }

    /// @dev An ETH donation cannot fund a report's execution compensation.
    function test_anEthDonationCannotSubstituteForCompensation() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openPositionForReport();
        vm.deal(address(helper), ETH_DONATION);

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InsufficientRouterOutput.selector);
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
            _routeFunding(INITIAL_LIQUIDITY, AMOUNT2, 0, false, address(tokenC), 1e18, _inertRoute(), _inertInputs()),
            router
        );

        assertEq(address(helper).balance, ETH_DONATION, "the ETH donation must still be there");
    }

    // ────────────────────────────────────────────────────────────────────
    //  a donation cannot be claimed as a refund
    // ────────────────────────────────────────────────────────────────────

    /// @dev Oversupplying over a standing donation: the refund must be exactly the oversupply. A
    ///      sweep-style refund would hand the caller the donation as well.
    function test_theRefundIsTheDeltaNotTheHelperBalance() public {
        Proposal memory p = _propose();
        tokenA.mint(address(helper), DONATION);
        collat.mint(address(helper), DONATION);

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 c0 = collat.balanceOf(funder);

        _match(p, _noRouteFunding(INITIAL_LIQUIDITY + 40e18, AMOUNT2, INITIAL_MARGIN_MATCHER + 60e18, false), 0);

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY, "only the token1 oversupply may return");
        assertEq(c0 - collat.balanceOf(funder), INITIAL_MARGIN_MATCHER, "only the collateral oversupply may return");
        assertEq(tokenA.balanceOf(address(helper)), DONATION, "the token1 donation was swept out");
        assertEq(collat.balanceOf(address(helper)), DONATION, "the collateral donation was swept out");
    }

    /// @dev The ETH equivalent, on a report whose compensation is oversupplied.
    function test_anEthDonationSurvivesAnOversuppliedReport() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openPositionForReport();
        vm.deal(address(helper), ETH_DONATION);

        uint256 e0 = funder.balance;
        uint256 supplied3 = uint256(REPORT_EXEC_COMP) + 2 ether;

        vm.prank(funder);
        helper.reportWithRoute{value: supplied3}(
            sid,
            bytes32(0),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, supplied3, false),
            router
        );

        assertEq(e0 - funder.balance, REPORT_EXEC_COMP, "only the compensation should be retained");
        assertEq(address(helper).balance, ETH_DONATION, "the ETH donation was drained");
    }

    /// @dev A donated route-input balance is separately snapshotted and must survive.
    function test_aDonatedRouteInputSurvivesARoutedMatch() public {
        Proposal memory p = _propose();
        tokenC.mint(address(helper), DONATION);

        uint256 maxIn = 6000e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(cj, ij, address(tokenC));

        _match(p, _routeFunding(0, 0, INITIAL_MARGIN_MATCHER, false, address(tokenC), maxIn, cmds, ins), 0);

        assertEq(tokenC.balanceOf(address(helper)), DONATION, "the route-input donation was drained");
    }

    /// @dev And a donated route input cannot be spent as routing budget either.
    function test_theRouteBudgetComesFromTheCallerNotADonation() public {
        Proposal memory p = _propose();
        tokenC.mint(address(helper), DONATION);

        uint256 maxIn = 6000e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory joined, bytes[] memory joinedInputs) = _join(c1, i1, c2, i2);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(joined, joinedInputs, address(tokenC));

        uint256 tc0 = tokenC.balanceOf(funder);

        _match(p, _routeFunding(0, 0, INITIAL_MARGIN_MATCHER, false, address(tokenC), maxIn, cmds, ins), 0);

        assertGt(tc0 - tokenC.balanceOf(funder), 0, "the route must spend caller funds");
        assertLt(tc0 - tokenC.balanceOf(funder), maxIn, "the unused caller budget must be refunded");
        assertEq(tokenC.balanceOf(address(helper)), DONATION, "the donation was spent as routing budget");
    }

    /// @dev A preexisting internal balance on the helper survives beyond the sentinel the
    ///      oracle maintains.
    function test_aPreexistingHelperInternalBalanceSurvives() public {
        Proposal memory p = _propose();

        tokenA.mint(address(this), 500e18);
        tokenA.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(tokenA), 500e18, address(helper));
        uint256 before = oracle.tokenHolder(address(helper), address(tokenA));

        _match(p, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false), 0);

        assertEq(
            oracle.tokenHolder(address(helper), address(tokenA)),
            before,
            "the helper's preexisting internal balance must not be spent"
        );
    }

    /// @dev A successful routed call may temporarily move every tracked asset through the helper,
    ///      but both its external balances and its OpenOracle ledger must finish exactly where they
    ///      started. This combines routed output, an internally sourced route budget, collateral,
    ///      and preexisting balances in one success path.
    function test_aRoutedMatchRestoresAllStartingHelperBalances() public {
        Proposal memory p = _propose();

        tokenA.mint(address(helper), 11e18);
        tokenB.mint(address(helper), 12e18);
        collat.mint(address(helper), 13e18);
        tokenC.mint(address(helper), 14e18);
        vm.deal(address(helper), 2 ether);

        uint128 internalDonation = 17e18;
        tokenA.mint(address(this), internalDonation);
        tokenB.mint(address(this), internalDonation);
        collat.mint(address(this), internalDonation);
        tokenC.mint(address(this), internalDonation);
        tokenA.approve(address(oracle), type(uint256).max);
        tokenB.approve(address(oracle), type(uint256).max);
        collat.approve(address(oracle), type(uint256).max);
        tokenC.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(tokenA), internalDonation, address(helper));
        oracle.deposit(address(tokenB), internalDonation, address(helper));
        oracle.deposit(address(collat), internalDonation, address(helper));
        oracle.deposit(address(tokenC), internalDonation, address(helper));

        uint256 maxIn = 6000e18;
        vm.startPrank(funder);
        oracle.deposit(address(tokenC), uint128(maxIn), funder);
        oracle.approveInternal(address(helper), address(tokenC), type(uint256).max);
        vm.stopPrank();

        HelperBalances memory before_ = _helperBalances();

        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory joined, bytes[] memory joinedInputs) = _join(c1, i1, c2, i2);
        (bytes memory commands, bytes[] memory inputs) = _withSweep(joined, joinedInputs, address(tokenC));

        _match(p, _routeFunding(0, 0, INITIAL_MARGIN_MATCHER, true, address(tokenC), maxIn, commands, inputs), 0);

        _assertHelperBalancesEqual(_helperBalances(), before_);
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    /// @dev A well-formed but economically inert plan: a legal command the helper accepts, whose
    ///      input is unusable, so the route cannot fund anything. Used to enter the shortfall path
    ///      without letting the router supply the missing asset.
    function _inertRoute() internal pure returns (bytes memory) {
        return abi.encodePacked(CMD_SWEEP);
    }

    function _inertInputs() internal view returns (bytes[] memory ins) {
        ins = new bytes[](1);
        ins[0] = _sweepInput(address(tokenC));
    }

    function _helperBalances() internal view returns (HelperBalances memory balances) {
        balances.externalA = tokenA.balanceOf(address(helper));
        balances.externalB = tokenB.balanceOf(address(helper));
        balances.externalCollateral = collat.balanceOf(address(helper));
        balances.externalRouteInput = tokenC.balanceOf(address(helper));
        balances.externalEth = address(helper).balance;
        balances.internalA = oracle.tokenHolder(address(helper), address(tokenA));
        balances.internalB = oracle.tokenHolder(address(helper), address(tokenB));
        balances.internalCollateral = oracle.tokenHolder(address(helper), address(collat));
        balances.internalRouteInput = oracle.tokenHolder(address(helper), address(tokenC));
    }

    function _assertHelperBalancesEqual(HelperBalances memory actual, HelperBalances memory expected) internal pure {
        assertEq(actual.externalA, expected.externalA, "external token1 changed");
        assertEq(actual.externalB, expected.externalB, "external token2 changed");
        assertEq(actual.externalCollateral, expected.externalCollateral, "external collateral changed");
        assertEq(actual.externalRouteInput, expected.externalRouteInput, "external route input changed");
        assertEq(actual.externalEth, expected.externalEth, "external ETH changed");
        assertEq(actual.internalA, expected.internalA, "internal token1 changed");
        assertEq(actual.internalB, expected.internalB, "internal token2 changed");
        assertEq(actual.internalCollateral, expected.internalCollateral, "internal collateral changed");
        assertEq(actual.internalRouteInput, expected.internalRouteInput, "internal route input changed");
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
}
