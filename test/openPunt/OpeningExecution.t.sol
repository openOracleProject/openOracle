// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @notice Opening execution: the success path, the slippage band boundaries, and the
 *         block-cadence band boundaries.
 *
 * @dev Boundary construction. The oracle price is `mulDiv(amount1, 1e30, amount2)`. Fixing
 *      amount2 at exactly 1e30 makes price == amount1 identically, so a boundary price can be
 *      posted as an exact integer amount1 with no rounding ambiguity. Every case asserts the
 *      realised price equals the intended boundary before asserting which side it landed on.
 *
 *      With priceTolerated = 1e30 and toleranceRange = 1e6 (10%):
 *        upper = mulDiv(1e30, 1e7 + 1e6, 1e7)  = 1.1e30
 *        lower = mulDiv(1e30, 1e7, 1e7 + 1e6)  = floor(1e37 / 1.1e7)
 *                                              = 909090909090909090909090909090
 */
contract OpeningExecutionTest is OpenPuntBase {
    uint232 internal constant PT = 1e30;
    uint24 internal constant TR = 1e6;
    uint128 internal constant A2 = 1e30;

    uint128 internal constant UPPER = 1_100_000_000_000_000_000_000_000_000_000;
    uint128 internal constant LOWER = 909_090_909_090_909_090_909_090_909_090;

    uint128 internal constant EXPECTED_OPEN_FEE = 10e18; // 10_000e18 * 10_000 / 1e7
    uint128 internal constant EXPECTED_MAX_OPEN_FEE = 20e18; // 10_000e18 * 20_000 / 1e7

    function setUp() public {
        _setUpAll();
        collat.mint(swapper, 1_000_000e18);
        vm.deal(swapper, 100 ether);
        _mintAndDeposit(collat, matcher, 1_000_000e18);
        _mintAndDeposit(tokenA, matcher, 10e30);
        _mintAndDeposit(tokenB, matcher, 10e30);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Success path
    // ══════════════════════════════════════════════════════════════════

    function test_openingSuccessAtExactExpectedPrice() public {
        uint256 matcherCollat0 = _spendable(matcher, address(collat));
        uint256 matcherA0 = _spendable(matcher, address(tokenA));
        uint256 matcherB0 = _spendable(matcher, address(tokenB));

        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        uint48 reportTs = mt.game.lastReportOppoTime; // block mode: the wall clock lives here

        // the realised price is exactly the tolerated price
        assertEq(
            Math.mulDiv(mt.game.currentAmount1, 1e30, mt.game.currentAmount2),
            uint256(PRICE_TOLERATED),
            "realised price == priceTolerated"
        );

        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);

        // position shape
        assertTrue(active.active, "active");
        assertEq(punt.swapIdToReportId(p.swapId), 0, "reportId cleared");
        assertEq(
            active.initialMarginSwapper,
            INITIAL_MARGIN_SWAPPER - EXPECTED_MAX_OPEN_FEE,
            "active margin excludes the maximum opening-fee reserve"
        );
        assertEq(active.initialMarginMatcher, INITIAL_MARGIN_MATCHER, "matcher margin untouched");
        assertEq(active.oracleAmount1, INITIAL_LIQUIDITY, "opening amount1 recorded");
        assertEq(active.oracleAmount2, AMOUNT2, "opening amount2 recorded");
        assertEq(active.start, reportTs + SETTLEMENT_SECONDS, "start == settlement eligibility");
        assertEq(active.maturity, reportTs + SETTLEMENT_SECONDS + MATURITY_WINDOW, "maturity == eligibility + window");
        assertEq(active.openExecutionComp, 0, "opening comp consumed");

        // hand-built expected active state
        OpenPuntStorage.MatchedSwap memory want = _copy(mt.swap);
        want.initialMarginSwapper = INITIAL_MARGIN_SWAPPER - EXPECTED_MAX_OPEN_FEE;
        want.oracleAmount1 = INITIAL_LIQUIDITY;
        want.oracleAmount2 = AMOUNT2;
        want.start = reportTs + uint48(SETTLEMENT_SECONDS);
        want.maturity = reportTs + uint48(SETTLEMENT_SECONDS) + MATURITY_WINDOW;
        want.active = true;
        want.openExecutionComp = 0;
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(want)), "stored hash == hand-built active state");

        // economics
        assertEq(
            _spendable(matcher, address(collat)),
            matcherCollat0 - INITIAL_MARGIN_MATCHER + EXPECTED_OPEN_FEE,
            "matcher receives exactly the opening fee"
        );
        assertEq(_spendable(matcher, address(tokenA)), matcherA0, "leg1 returned to the opening reporter");
        assertEq(_spendable(matcher, address(tokenB)), matcherB0, "leg2 returned to the opening reporter");

        // executor compensation
        assertEq(punt.tempHolding(executor), OPEN_EXEC_COMP, "opening comp credited once");
        assertEq(_spendable(executor, address(0)), SETTLER_REWARD, "settler reward forwarded to the executor");
        assertEq(_spendable(address(punt), address(0)), 0, "core keeps no internal ETH");
    }

    function test_longAndShortOpenIdentically() public {
        OpenPuntStorage.ProposedSwap memory sLong = _defaultProposedSwap();
        sLong.isLong = true;
        OpenPuntStorage.ProposedSwap memory sShort = _defaultProposedSwap();
        sShort.isLong = false;

        // same block for both, so start/maturity are identical
        Proposal memory pL = _proposeWith(sLong, _defaultMatcherPreimage(), swapper);
        Proposal memory pS = _proposeWith(sShort, _defaultMatcherPreimage(), swapper);
        Matched memory mL = _matchSwap(pL);
        Matched memory mS = _matchSwap(pS);

        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory openedLong = _executeOpening(mL, executor);
        OpenPuntStorage.MatchedSwap memory openedShort = _executeOpening(mS, executor);

        assertTrue(openedLong.swapperIsLong, "long orientation preserved");
        assertFalse(openedShort.swapperIsLong, "short orientation preserved");

        // flipping only the orientation flag makes the two states identical
        OpenPuntStorage.MatchedSwap memory shortAsLong = _copy(openedShort);
        shortAsLong.swapperIsLong = true;
        assertEq(
            keccak256(abi.encode(openedLong)),
            keccak256(abi.encode(shortAsLong)),
            "orientation is the only difference in the opened state"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  Slippage band
    // ══════════════════════════════════════════════════════════════════

    /// @dev Builds and matches a position whose opening price is exactly `a1`.
    function _matchAtPrice(uint128 a1) internal returns (Proposal memory p, Matched memory mt) {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.priceTolerated = PT;
        s.toleranceRange = TR;

        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();
        m.initialLiquidity = a1;
        m.escalationHalt = 5e30;

        p = _proposeWith(s, m, swapper);
        mt = _matchSwapWith(p, A2, matcher);

        assertEq(Math.mulDiv(mt.game.currentAmount1, 1e30, mt.game.currentAmount2), uint256(a1), "realised price == a1");
    }

    function _assertOpensAtPrice(uint128 a1, string memory what) internal {
        (Proposal memory p, Matched memory mt) = _matchAtPrice(a1);
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);

        assertTrue(active.active, string.concat(what, ": opened"));
        assertEq(active.oracleAmount1, a1, string.concat(what, ": opening amount1 recorded"));
        assertTrue(punt.swaps(p.swapId) != bytes32(0), string.concat(what, ": position still live"));
    }

    function _assertBailsOutAtPrice(uint128 a1, string memory what) internal {
        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherCollat0 = _spendable(matcher, address(collat));

        (Proposal memory p, Matched memory mt) = _matchAtPrice(a1);
        _advanceToSettlementEligibility();

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.SlippageBailout.selector, p.swapId),
            string.concat(what, ": SlippageBailout emitted")
        );
        _findLog(logs, address(punt), OpenPuntStorage.PositionOpeningFailed.selector, p.swapId);

        assertEq(punt.swaps(p.swapId), bytes32(0), string.concat(what, ": swap deleted"));
        // margins fully returned, and no opening fee anywhere
        assertEq(
            collat.balanceOf(swapper),
            swapperExt0, // margin out at propose, pushed back on bailout
            string.concat(what, ": swapper margin refunded externally")
        );
        assertEq(
            _spendable(matcher, address(collat)),
            matcherCollat0,
            string.concat(what, ": matcher margin returned in full")
        );
        assertEq(_spendable(address(punt), address(collat)), 0, string.concat(what, ": core drained"));
    }

    function test_slippage_upperBoundaryAccepted() public {
        _assertOpensAtPrice(UPPER, "upper boundary");
    }

    function test_slippage_oneUnitAboveUpperBoundaryBailsOut() public {
        _assertBailsOutAtPrice(UPPER + 1, "one above upper");
    }

    function test_slippage_lowerBoundaryAccepted() public {
        _assertOpensAtPrice(LOWER, "lower boundary");
    }

    function test_slippage_oneUnitBelowLowerBoundaryBailsOut() public {
        _assertBailsOutAtPrice(LOWER - 1, "one below lower");
    }

    /// @dev A failed opening still pays the executor and still forwards the settler reward,
    ///      and leaves no residue on the core.
    function test_slippageBailoutStillCompensatesTheExecutor() public {
        (Proposal memory p, Matched memory mt) = _matchAtPrice(UPPER + 1);
        _advanceToSettlementEligibility();

        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 0);

        assertEq(punt.tempHolding(executor), OPEN_EXEC_COMP, "opening comp still credited");
        assertEq(_spendable(executor, address(0)), SETTLER_REWARD, "settler reward still forwarded");
        assertEq(_spendable(address(punt), address(0)), 0, "no internal ETH residue");
        assertEq(_spendable(address(punt), address(collat)), 0, "no collateral residue");
        assertEq(collat.balanceOf(address(punt)), 0, "no external collateral residue");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Block cadence band
    // ══════════════════════════════════════════════════════════════════
    //
    // Base cadence: millisecondsPerBlock = 2_000 (one block every two seconds). Over dt = 400s:
    //     elapsedMilliseconds  = dt * 1000        = 400_000
    //     expectedMilliseconds = db * 2_000
    // The contract accepts db when |expected - elapsed| <= 2_000, i.e.
    //     398_000 <= db * 2_000 <= 402_000   ->   199 <= db <= 201
    // so 199, 200, 201 are accepted and 198, 202 are not. Derived from the inequality directly;
    // impliedMillisecondsPerBlock() is never called or reimplemented by a test.
    //
    // dt = 400 keeps the cadence band above the block-denominated settlement floor:
    // execute() reverts OracleSettlementNotEligible until db >= settlementTime (150 blocks here).
    // The whole cadence band must therefore sit above that floor, or the low variants are rejected
    // by eligibility before the cadence check is ever evaluated. At dt = 400 the band is 198..202,
    // comfortably clear of 150.
    //
    // The tolerance is two seconds of time, not two blocks: at 2_000 ms/block that happens to be
    // one block either side, which is why the accepted band is exactly three values here.

    uint256 internal constant CADENCE_DT = 400;

    function _openWithBlockDelta(uint256 blocks)
        internal
        returns (uint256 swapId, Vm.Log[] memory logs, uint256 swapperExt0, uint256 matcherCollat0)
    {
        swapperExt0 = collat.balanceOf(swapper);
        matcherCollat0 = _spendable(matcher, address(collat));

        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        _advanceTimeAndBlocks(CADENCE_DT, blocks);

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 0);
        logs = vm.getRecordedLogs();
        swapId = p.swapId;
    }

    function _assertCadenceAccepted(uint256 blocks, string memory what) internal {
        (uint256 swapId, Vm.Log[] memory logs,,) = _openWithBlockDelta(blocks);
        _findLog(logs, address(punt), OpenPuntStorage.PositionOpened.selector, swapId);
        assertTrue(punt.swaps(swapId) != bytes32(0), string.concat(what, ": position opened"));
    }

    function _assertCadenceRejected(uint256 blocks, string memory what) internal {
        (uint256 swapId, Vm.Log[] memory logs, uint256 swapperExt0, uint256 matcherCollat0) =
            _openWithBlockDelta(blocks);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, swapId),
            string.concat(what, ": ImpliedMillisecondsPerBlockBailout emitted")
        );
        _findLog(logs, address(punt), OpenPuntStorage.PositionOpeningFailed.selector, swapId);

        assertEq(punt.swaps(swapId), bytes32(0), string.concat(what, ": swap deleted"));
        assertEq(collat.balanceOf(swapper), swapperExt0, string.concat(what, ": swapper margin fully refunded"));
        assertEq(
            _spendable(matcher, address(collat)),
            matcherCollat0,
            string.concat(what, ": matcher margin fully refunded, no opening fee")
        );
        assertEq(_spendable(address(punt), address(collat)), 0, string.concat(what, ": core drained"));
    }

    /// @dev 200 blocks * 2_000 ms = 400_000 ms, exactly the elapsed 400 s.
    function test_cadence_exactAccepted() public {
        _assertCadenceAccepted(200, "exact cadence");
    }

    /// @dev 199 * 2_000 = 398_000 ms, exactly 2_000 ms below elapsed: the inclusive lower edge.
    function test_cadence_lowerEdgeAccepted() public {
        _assertCadenceAccepted(199, "lower tolerance edge");
    }

    /// @dev 201 * 2_000 = 402_000 ms, exactly 2_000 ms above elapsed: the inclusive upper edge.
    function test_cadence_upperEdgeAccepted() public {
        _assertCadenceAccepted(201, "upper tolerance edge");
    }

    /// @dev 198 * 2_000 = 396_000 ms, 4_000 ms below elapsed.
    function test_cadence_oneBlockBelowLowerEdgeRejected() public {
        _assertCadenceRejected(198, "one block below lower edge");
    }

    /// @dev 202 * 2_000 = 404_000 ms, 4_000 ms above elapsed.
    function test_cadence_oneBlockAboveUpperEdgeRejected() public {
        _assertCadenceRejected(202, "one block above upper edge");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Combined failure
    // ══════════════════════════════════════════════════════════════════

    /// @dev Slippage and cadence failing together refund exactly as either alone would.
    function test_slippageAndCadenceFailTogetherWithIdenticalRefunds() public {
        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 matcherCollat0 = _spendable(matcher, address(collat));
        uint256 matcherA0 = _spendable(matcher, address(tokenA));

        (Proposal memory p, Matched memory mt) = _matchAtPrice(UPPER + 1); // outside the band
        _advanceTimeAndBlocks(CADENCE_DT, 153); // and outside the cadence band

        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, mt.swap, mt.game, mt.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasBailoutLog(logs, OpenPuntStorage.SlippageBailout.selector, p.swapId), "SlippageBailout emitted");
        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, p.swapId),
            "ImpliedMillisecondsPerBlockBailout emitted"
        );
        _findLog(logs, address(punt), OpenPuntStorage.PositionOpeningFailed.selector, p.swapId);
        _findLog(logs, address(punt), OpenPuntStorage.SwapRefunded.selector, p.swapId);

        assertEq(punt.swaps(p.swapId), bytes32(0), "swap deleted");
        assertEq(collat.balanceOf(swapper), swapperExt0, "swapper margin refunded exactly once");
        assertEq(_spendable(matcher, address(collat)), matcherCollat0, "matcher margin refunded exactly once");
        assertEq(_spendable(matcher, address(tokenA)), matcherA0, "matcher leg1 returned");
        assertEq(_spendable(address(punt), address(collat)), 0, "core drained");
        assertEq(punt.tempHolding(executor), OPEN_EXEC_COMP, "executor still compensated once");
    }
}
