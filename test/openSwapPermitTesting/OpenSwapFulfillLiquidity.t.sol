// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";

/// @notice Tests around minFulfillLiquidity behavior at execute time.
contract OpenSwapFulfillLiquidityTest is SlimTestBase {
    uint128 internal _minFulfill;

    function setUp() public {
        _setUpAll();
        _minFulfill = MIN_FULFILL_LIQUIDITY;
    }

    function _proposeWithMinFulfill(uint128 minFulfill) internal returns (uint256 swapId, uint48 expiration) {
        _minFulfill = minFulfill;
        expiration = uint48(block.timestamp + 1 hours);
        proposeTs = uint48(block.timestamp);
        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        vm.prank(swapper);
        swapId = SwapCompat.proposeRaw(swapContract, ethToSend, 
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), minFulfill,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            _defaultOracleParams(), _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), false
        );
    }

    function _buildWith(uint256 swapId, uint48 expiration)
        internal
        view
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        (s, m) = _buildSwapAndPreimage(swapId, expiration);
        s.minFulfillLiquidity = _minFulfill;
    }

    function _runToExecute(uint128 minFulfill, uint128 amount2) internal returns (bool refunded) {
        (uint256 swapId, uint48 expiration) = _proposeWithMinFulfill(minFulfill);
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _buildWith(swapId, expiration);
        // We need to use the test-specific s in matchSwap (which has minFulfillLiquidity set correctly).
        // _match() builds its own s from _buildSwapAndPreimage which won't have _minFulfill applied — call inline.
        IOpenOracle2.TimingBoundaries memory timing = IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        uint128 reportId = uint128(oracle.nextReportId());

        vm.prank(matcher);
        swapContract.matchSwap(swapId, amount2, s, m, timing);

        openSwapV2.MatchedSwap memory sPost = _postMatchSwap(s, reportId, _calcFulfillFee(), reportTs);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, amount2);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(reportId, og, ph);

        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        _execute(swapId, sPost, og, ph, address(0x99));

        // Refund happened iff swapper didn't receive buyToken externally
        refunded = buyToken.balanceOf(swapper) == swapperBuyBefore;
    }

    function testFulfillLiquidity_FulfillAmountExceedsMinFulfill_Refunds() public {
        // sellAmt=10e18, amount2=2000e18, initialLiquidity=1e18 → fulfillAmt=20000e18 (before fee)
        // With minFulfillLiquidity = 1000e18, fulfillAmt > minFulfillLiquidity → refund branch
        bool refunded = _runToExecute(1000e18, 2000e18);
        assertTrue(refunded, "should refund when fulfillAmt > minFulfillLiquidity");
    }

    function testFulfillLiquidity_BarelyExceeded_Refunds() public {
        // fulfillAmt = 19980e18, set minFulfill = 19979e18 → refunds
        bool refunded = _runToExecute(19979e18, 2000e18);
        assertTrue(refunded, "should refund when fulfillAmt just exceeds minFulfillLiquidity");
    }

    function testFulfillLiquidity_ExactlyAtLimit_Succeeds() public {
        // fulfillAmt = 19980e18, set minFulfill = 19980e18 → completes
        bool refunded = _runToExecute(19980e18, 2000e18);
        assertFalse(refunded, "should NOT refund when fulfillAmt exactly equals minFulfillLiquidity");
    }

    function testFulfillLiquidity_WellUnderLimit_Succeeds() public {
        bool refunded = _runToExecute(MIN_FULFILL_LIQUIDITY, 2000e18); // 25000e18 well above 19980
        assertFalse(refunded, "should NOT refund when fulfillAmt well under minFulfillLiquidity");
    }

    function testFulfillLiquidity_MatcherGetsExcess() public {
        // Confirm matcher receives (minFulfill - fulfillAmt) of buyToken
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));
        (uint256 swapId, uint48 expiration) = _proposeWithMinFulfill(MIN_FULFILL_LIQUIDITY);
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _buildWith(swapId, expiration);

        IOpenOracle2.TimingBoundaries memory timing = IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        uint128 reportId = uint128(oracle.nextReportId());
        vm.prank(matcher);
        swapContract.matchSwap(swapId, 2000e18, s, m, timing);

        openSwapV2.MatchedSwap memory sPost = _postMatchSwap(s, reportId, _calcFulfillFee(), reportTs);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(reportId, og, ph);
        _execute(swapId, sPost, og, ph, address(0x99));

        // Compute fulfillAmt
        uint256 fulfillAmt = (uint256(SELL_AMT) * 2000e18) / INITIAL_LIQUIDITY;
        fulfillAmt -= (fulfillAmt * STARTING_FEE) / 1e7;

        // Matcher gained: amount2 returned by settle + (minFulfill - fulfillAmt) excess credited internally
        // Matcher already had matcherBuyInternalBefore. After match: -amount2 -minFulfill. After settle: +amount2.
        // After execute: +(minFulfill - fulfillAmt). Net: matcherBuyInternalBefore - fulfillAmt
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore - fulfillAmt,
            "matcher net buyToken delta = -fulfillAmt"
        );
    }
}
