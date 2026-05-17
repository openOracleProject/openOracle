// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

/// @notice Regression test for the slippage fields copied in matchSwap. If the manual
///         field-by-field copy from ProposedSwap → MatchedSwap omits these fields,
///         the stored MatchedSwap has zero slippage params. At execute, toleranceCheck
///         against zero params fails for any real price, forcing a SlippageBailout
///         refund instead of a successful swap.
contract OpenSwapMatchedCopyTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    /// @notice Non-trivial slippage params + a price that sits inside the band must
    ///         result in a clean execute (no SlippageBailout). If slippage fields were
    ///         dropped during copy, toleranceCheck(price, 0, 0) → false → refund.
    function testMatchedCopy_SlippageParamsSurviveMatch() public {
        (uint256 swapId, uint48 expiration) = _propose();
        uint128 amount2 = 2000e18; // price = 1e18*1e30 / 2000e18 = 5e26, exactly within band
        (uint128 reportId, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, amount2, expiration);

        // Confirm slippage params actually copied through.
        SwapCompat.SlippageParams memory sp = _defaultSlippage();
        assertEq(sPost.priceTolerated, sp.priceTolerated, "priceTolerated copied");
        assertEq(sPost.toleranceRange, sp.toleranceRange, "toleranceRange copied");

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, amount2);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(reportId, og, ph);

        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        // Watch: SlippageBailout would emit if slippageParams were dropped.
        vm.recordLogs();
        _execute(swapId, sPost, og, ph, address(0x99));

        // Assert no SlippageBailout — we got tokens.
        assertGt(buyToken.balanceOf(swapper), swapperBuyBefore, "swapper received buyToken (no refund)");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 slippageSig = keccak256("SlippageBailout(uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != slippageSig, "no SlippageBailout emitted");
        }
    }
}
