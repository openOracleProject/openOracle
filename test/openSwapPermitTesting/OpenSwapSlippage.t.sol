// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

contract OpenSwapSlippageTest is SlimTestBase {
    // State that the overridable param helper reads.
    SwapCompat.SlippageParams internal _slippage;

    function setUp() public {
        _setUpAll();
        // Default loose slippage so happy-flow tests pass.
        _slippage = SwapCompat.SlippageParams({priceTolerated: 5e26, toleranceRange: 1e7 - 1});
    }

    function _defaultSlippage() internal view override returns (SwapCompat.SlippageParams memory) {
        return _slippage;
    }

    function _setSlippage(uint232 priceTolerated, uint24 toleranceRange) internal {
        _slippage = SwapCompat.SlippageParams({priceTolerated: priceTolerated, toleranceRange: toleranceRange});
    }

    function _runToExecute(uint128 amount2) internal {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, amount2, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, amount2);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        _settle(reportId, og, ph);
        _execute(swapId, sPost, og, ph, address(0x99));

        // Terminal: both complete and refund branches delete the swap hash
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-execute");
    }

    // ── Validation at propose ───────────────────────────────────────────

    function testSlippage_RevertWhenPriceToleratedZero() public {
        _setSlippage(0, 100000);
        vm.expectRevert();
        _propose();
    }

    function testSlippage_RevertWhenToleranceRangeZero() public {
        _setSlippage(5e26, 0);
        vm.expectRevert();
        _propose();
    }

    function testSlippage_RevertWhenBothZero() public {
        _setSlippage(0, 0);
        vm.expectRevert();
        _propose();
    }

    function testSlippage_RevertWhenToleranceRangeTooHigh() public {
        _setSlippage(5e26, uint24(1e7 + 1));
        vm.expectRevert();
        _propose();
    }

    // ── Slippage pass paths (swap executes) ─────────────────────────────

    function testSlippage_PassExactPrice() public {
        // priceTolerated = 5e26 corresponds to amount1*1e30/amount2 = 1e18*1e30/2000e18 = 5e26. Exact match.
        _setSlippage(5e26, 100000); // 1%
        _runToExecute(2000e18);
        assertGt(buyToken.balanceOf(swapper), 0, "swap completed");
    }

    function testSlippage_PassPriceWithinRange() public {
        _setSlippage(5e26, 100000); // 1%
        // amount2 = 1990e18 → price = 1e18*1e30/1990e18 ≈ 5.025e26 (within 1%)
        _runToExecute(1990e18);
        assertGt(buyToken.balanceOf(swapper), 0, "swap completed");
    }

    function testSlippage_TightTolerance_Pass() public {
        _setSlippage(5e26, 10000); // 0.1%
        // amount2 = 1999e18 → price ≈ 5.0025e26 (within 0.1%)
        _runToExecute(1999e18);
        assertGt(buyToken.balanceOf(swapper), 0, "swap completed");
    }

    function testSlippage_WideTolerance_Pass() public {
        _setSlippage(5e26, 1000000); // 10%
        // amount2 = 1850e18 → price ≈ 5.4e26 (within 10%)
        _runToExecute(1850e18);
        assertGt(buyToken.balanceOf(swapper), 0, "swap completed");
    }

    // ── Slippage fail paths (refund) ────────────────────────────────────

    function testSlippage_FailPriceOutsideRange() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        _setSlippage(5e26, 100000); // 1%
        // amount2 = 1800e18 → price = 1e18*1e30/1800e18 ≈ 5.56e26 (>10% off)
        _runToExecute(1800e18);

        // Refund branch: swapper gets sellToken externally, matcher gets minFulfillLiquidity internally
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "swapper sellToken refunded");
        // amount2 sits in oracle game escrow until settle; settle credits it back to matcher.
        // Net matcher delta for buyToken after refund: amount2 returned by settle, minFulfillLiquidity returned by refund.
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore,
            "matcher buyToken fully refunded"
        );
    }

    function testSlippage_FailWildlyDifferentPrice() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        _setSlippage(5e26, 100000); // 1%
        // amount2 = 500e18 → price way off
        _runToExecute(500e18);

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "swapper sellToken refunded");
        assertEq(_spendable(matcher, address(buyToken)), matcherBuyInternalBefore, "matcher buyToken refunded");
    }

    function testSlippage_TightTolerance_Fail() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        _setSlippage(5e26, 10000); // 0.1%
        // amount2 = 1980e18 → ~1% off (outside 0.1%)
        _runToExecute(1980e18);

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "swapper sellToken refunded");
        assertEq(_spendable(matcher, address(buyToken)), matcherBuyInternalBefore, "matcher buyToken refunded");
    }

    function testSlippage_WideTolerance_Fail() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        _setSlippage(5e26, 1000000); // 10%
        // amount2 = 1500e18 → ~33% off (outside 10%)
        _runToExecute(1500e18);

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "swapper sellToken refunded");
        assertEq(_spendable(matcher, address(buyToken)), matcherBuyInternalBefore, "matcher buyToken refunded");
    }
}
