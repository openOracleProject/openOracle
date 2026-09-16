// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenPuntHelperBase, IV2FactoryMin} from "./OpenPuntHelperBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice Constructor wiring, and the funder / designated-party separation that is the whole point
 *         of this helper.
 *
 * @dev The helper is `msg.sender` to OpenPunt, so OpenPunt records it as `matcherFunder`.
 *      The `matcher` argument is the recorded counterparty and the opening oracle reporter. Capital
 *      therefore flows from the caller while rights and payouts accrue to the designated party.
 *
 *      `matchSwap` pushes both oracle legs to
 *      the matcher with `internalTransferFrom(matcherFunder, matcher, ...)`, then creates the
 *      oracle game with the matcher as `currentReporter`; that game consumes them with
 *      OpenPunt as `msg.sender`. So the matcher must hold
 *      `internalAllowance[matcher][punt][oracleToken1/2]`.
 *
 *      Collateral is different: it moves `internalTransferFrom(matcherFunder, punt, collatToken)`
 *      straight from the helper, and needs no matcher approval. The tests below pin that asymmetry
 *      rather than asserting a vague "approvals are needed".
 *
 *      `assetCount == 1` is unreachable. Both entry points always add two distinct oracle tokens
 *      (`TokensCannotBeSame` is checked first), so the aggregate can never collapse below two. The
 *      reachable counts are 2 (collateral equals an oracle token on a match, or an ETH oracle leg
 *      merges with the ETH execution-compensation slot on a report) and 3 (everything distinct).
 *      `AssetAggregation.t.sol` covers both. Count 1 is unreachable.
 */
contract DeploymentAndActorsTest is OpenPuntHelperBase {
    /// @dev OpenOracle's strict-delegation failure. `oracleGame` funds the opening report from the
    ///      matcher's ledger with OpenPunt as `msg.sender`, and `_tryInternalBalanceFull` reverts
    ///      with this when the matcher's balance-plus-allowance cannot cover the whole leg:
    ///
    ///          if (tib && owner != msg.sender && fromInternal < amount) revert InsufficientInternalBalance();
    ///
    ///      Asserted by selector rather than with a bare `vm.expectRevert()`, so an unrelated
    ///      fixture or funding failure cannot masquerade as the missing approval.
    bytes4 internal constant INSUFFICIENT_INTERNAL_BALANCE = bytes4(keccak256("InsufficientInternalBalance()"));

    // ────────────────────────────────────────────────────────────────────
    //  construction
    // ────────────────────────────────────────────────────────────────────

    function test_immutablesPointAtTheRealSystem() public view {
        assertEq(address(helper.punt()), address(punt), "punt immutable");
        // Reading the oracle from OpenPunt prevents inconsistent constructor configuration.
        assertEq(address(helper.oracle()), address(oracle), "oracle immutable");
        assertEq(address(helper.oracle()), address(punt.oracle()), "oracle must be OpenPunt's own");
    }

    function test_zeroOpenPuntAddressReverts() public {
        vm.expectRevert(OpenPuntHelper.AddressCannotBeZero.selector);
        new OpenPuntHelper(address(0));
    }

    // ────────────────────────────────────────────────────────────────────
    //  the helper may not be the designated party
    // ────────────────────────────────────────────────────────────────────

    /// @dev If the helper were the matcher, `matcherFunder == matcher` and OpenPunt would skip the
    ///      push entirely — the position would be counterparty to a contract that holds no capital
    ///      of its own and has no way to act on it.
    function test_theHelperCannotBeTheDesignatedMatcher() public {
        Proposal memory p = _propose();

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.HelperCannotBeParticipant.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            address(helper),
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false),
            router
        );
    }

    function test_theHelperCannotBeTheDesignatedReporter() public {
        Matched memory mt = _openViaHelper();
        OpenPuntStorage.MatchedSwap memory opened = _executeOpening(mt, executor);

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.HelperCannotBeParticipant.selector);
        helper.reportWithRoute(
            mt.swapId,
            bytes32(0),
            opened,
            _emptyPreimage(),
            _noTiming(),
            address(helper),
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, false),
            router
        );
    }

    /// @dev Identical oracle tokens are rejected before any funding is touched.
    function test_identicalOracleTokensAreRejected() public {
        Proposal memory p = _propose();
        OpenPuntStorage.ProposedSwap memory bad = p.swap;
        bad.oracleToken2 = bad.oracleToken1;

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.TokensCannotBeSame.selector);
        helper.matchWithRoute(
            p.swapId, AMOUNT2, bad, p.preimage, _noTiming(), designatedMatcher, _noRouteFunding(0, 0, 0, false), router
        );
    }

    // ────────────────────────────────────────────────────────────────────
    //  designated-party approvals
    // ────────────────────────────────────────────────────────────────────

    /// @dev Without the matcher's internal allowances the call reverts late, after the helper has
    ///      already pulled the caller's assets, deposited them, and approved OpenPunt. Everything
    ///      unwinds.
    function test_missingMatcherApprovalRevertsLateAndAtomically() public {
        Proposal memory p = _propose();

        uint256 funderA = tokenA.balanceOf(funder);
        uint256 funderB = tokenB.balanceOf(funder);
        uint256 funderC = collat.balanceOf(funder);
        bytes32 swapHashBefore = punt.swaps(p.swapId);

        vm.prank(funder);
        vm.expectRevert(INSUFFICIENT_INTERNAL_BALANCE);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher, // never approved
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false),
            router
        );

        assertEq(tokenA.balanceOf(funder), funderA, "token1 was consumed by a reverted match");
        assertEq(tokenB.balanceOf(funder), funderB, "token2 was consumed by a reverted match");
        assertEq(collat.balanceOf(funder), funderC, "collateral was consumed by a reverted match");
        assertEq(punt.swaps(p.swapId), swapHashBefore, "the proposal hash moved");
        assertEq(oracle.tokenHolder(address(helper), address(tokenA)), 0, "helper retained an internal balance");
    }

    /// @dev Granting the approvals and retrying the identical call proves the failure consumed nothing.
    function test_grantingApprovalsAndRetryingTheSameCallSucceeds() public {
        Proposal memory p = _propose();

        vm.prank(funder);
        vm.expectRevert(INSUFFICIENT_INTERNAL_BALANCE);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false),
            router
        );

        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false),
            router
        );

        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the swap should now be matched");
    }

    /// @dev Collateral needs no matcher approval: approving only the two oracle legs is sufficient,
    ///      because collateral moves helper -> OpenPunt directly.
    function test_collateralNeedsNoMatcherApproval() public {
        Proposal memory p = _propose();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        assertEq(
            oracle.internalAllowance(designatedMatcher, address(punt), address(collat)),
            0,
            "precondition: no collateral allowance"
        );

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false),
            router
        );

        assertTrue(punt.swaps(p.swapId) != bytes32(0), "match should succeed without a collateral allowance");
    }

    // ────────────────────────────────────────────────────────────────────
    //  capital comes from the caller, rights go to the designated party
    // ────────────────────────────────────────────────────────────────────

    /// @dev The designated matcher's own wallet is untouched, and the funder pays for everything.
    function test_theCallerSuppliesCapitalAndTheDesignatedPartyBecomesTheMatcher() public {
        Proposal memory p = _propose();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        uint256 matcherA = tokenA.balanceOf(designatedMatcher);
        uint256 matcherB = tokenB.balanceOf(designatedMatcher);
        uint256 matcherC = collat.balanceOf(designatedMatcher);
        uint256 funderA = tokenA.balanceOf(funder);
        uint256 funderB = tokenB.balanceOf(funder);
        uint256 funderCollat = collat.balanceOf(funder);

        Matched memory mt = _matchViaHelper(p, designatedMatcher);

        assertEq(mt.swap.matcher, designatedMatcher, "the designated party must be the recorded matcher");
        assertEq(funderA - tokenA.balanceOf(funder), INITIAL_LIQUIDITY, "funder paid oracle leg 1");
        assertEq(funderB - tokenB.balanceOf(funder), AMOUNT2, "funder paid oracle leg 2");
        assertEq(funderCollat - collat.balanceOf(funder), INITIAL_MARGIN_MATCHER, "funder paid collateral");
        assertEq(tokenA.balanceOf(designatedMatcher), matcherA, "designated matcher's wallet must be untouched");
        assertEq(tokenB.balanceOf(designatedMatcher), matcherB, "designated matcher's wallet must be untouched");
        assertEq(collat.balanceOf(designatedMatcher), matcherC, "designated matcher's wallet must be untouched");
    }

    /// @dev The matcher gas compensation accrues to the designated matcher, not the funder — the
    ///      clearest single proof that rights follow the designation rather than the capital.
    function test_matcherGasCompensationAccruesToTheDesignatedMatcher() public {
        Proposal memory p = _propose();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        uint256 before = punt.tempHolding(designatedMatcher);
        uint256 funderBefore = punt.tempHolding(funder);

        _matchViaHelper(p, designatedMatcher);

        assertEq(punt.tempHolding(designatedMatcher) - before, MATCHER_GAS_COMP, "gas comp must go to the matcher");
        assertEq(punt.tempHolding(funder), funderBefore, "the funder must not receive the gas comp");
        assertEq(punt.tempHolding(address(helper)), 0, "the helper must not retain compensation");
    }

    /// @dev A preexisting internal balance belonging to the designated matcher is not consumed:
    ///      the legs pushed in by the helper are what the oracle game spends. A finite allowance,
    ///      however, is consumed because it is the matcher's permission, even though the
    ///      capital came from someone else. These are tracked separately on purpose.
    function test_designatedMatcherBalancesSurviveButFiniteAllowancesAreConsumed() public {
        Proposal memory p = _propose();

        // Real mints and real deposits, with finite (not infinite) allowances so consumption is
        // observable. The designated matcher normally holds nothing; here it deliberately holds a
        // preexisting balance so its preservation is observable.
        tokenA.mint(designatedMatcher, 40e18);
        tokenB.mint(designatedMatcher, 40_000e18);
        _depositInternal(designatedMatcher, address(tokenA), 40e18);
        _depositInternal(designatedMatcher, address(tokenB), 40_000e18);
        vm.startPrank(designatedMatcher);
        oracle.approveInternal(address(punt), address(tokenA), 10e18);
        oracle.approveInternal(address(punt), address(tokenB), 20_000e18);
        vm.stopPrank();

        uint256 balA = oracle.tokenHolder(designatedMatcher, address(tokenA));
        uint256 balB = oracle.tokenHolder(designatedMatcher, address(tokenB));

        _matchViaHelper(p, designatedMatcher);

        // The pushed legs arrive and are immediately spent by the oracle game, so the preexisting
        // balance is left exactly as it was.
        assertEq(oracle.tokenHolder(designatedMatcher, address(tokenA)), balA, "preexisting token1 balance consumed");
        assertEq(oracle.tokenHolder(designatedMatcher, address(tokenB)), balB, "preexisting token2 balance consumed");

        assertEq(
            oracle.internalAllowance(designatedMatcher, address(punt), address(tokenA)),
            10e18 - INITIAL_LIQUIDITY,
            "token1 allowance must fall by exactly the leg"
        );
        assertEq(
            oracle.internalAllowance(designatedMatcher, address(punt), address(tokenB)),
            20_000e18 - AMOUNT2,
            "token2 allowance must fall by exactly the leg"
        );
    }

    /// @dev Any address may be designated — including one with no relationship to the caller.
    function test_anArbitraryAddressMayBeDesignatedAsMatcher() public {
        Proposal memory p = _propose();
        _approveMatcherLegs(attacker, address(tokenA), address(tokenB));

        Matched memory mt = _matchViaHelper(p, attacker);
        assertEq(mt.swap.matcher, attacker, "an arbitrary designated matcher should be recorded");
    }

    // ────────────────────────────────────────────────────────────────────
    //  fixture sanity
    // ────────────────────────────────────────────────────────────────────

    function test_venuesArePlacedAndTrade() public {
        assertGt(router.code.length, 0, "router has no code");
        assertGt(poolManager.code.length, 0, "pool manager has no code");

        address pair = IV2FactoryMin(v2Factory).getPair(address(tokenC), address(tokenA));
        assertTrue(pair != address(0), "v2 pair missing");
        assertEq(tokenC.balanceOf(pair), POOL_LIQUIDITY, "pair not seeded");
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    function _matchViaHelper(Proposal memory p, address who) internal returns (Matched memory mt) {
        vm.recordLogs();
        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            who,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false),
            router
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        mt.swapId = p.swapId;
        (mt.reportId, mt.swap) = _decodeSwapMatched(logs, p.swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);
    }

    function _openViaHelper() internal returns (Matched memory mt) {
        Proposal memory p = _propose();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));
        mt = _matchViaHelper(p, designatedMatcher);
        _advanceToSettlementEligibility();
    }

    function _zeroDutch() internal pure returns (OpenPuntStorage.CloseDutch memory d) {
        d;
    }

    /// @dev The reporter check runs before any state is read, so an empty preimage is enough.
    function _emptyPreimage() internal pure returns (OpenPuntStorage.MatcherPreimage memory m) {
        m;
    }
}
