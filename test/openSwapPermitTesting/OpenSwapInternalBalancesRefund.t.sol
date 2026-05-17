// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

/// @notice Force a slippage-bailout during execute under useInternalBalances=true and
///         assert refunds land in oracle internal balances (not external pushes).
contract OpenSwapInternalBalancesRefundTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
        _setupSwapperInternalBalance(swapper, address(sellToken), SELL_AMT);
    }

    // Use a tight tolerance around an off-band price so the slippage check fails at execute.
    function _defaultSlippage() internal view override returns (SwapCompat.SlippageParams memory) {
        // Price for amount2=2000e18, amount1=1e18 → 5e26.
        // We propose with priceTolerated far from 5e26 and a tight band → slippage fails at execute.
        return SwapCompat.SlippageParams({priceTolerated: 1e27, toleranceRange: 1000});
    }

    function testInternalBalance_ExecuteSlippageBailout_RefundsInternally() public {
        uint256 swapperInternalSellBefore = _spendable(swapper, address(sellToken));
        uint256 swapperBuyExternalBefore = buyToken.balanceOf(swapper);
        uint256 matcherInternalBuyBefore = _spendable(matcher, address(buyToken));

        (uint256 swapId, uint48 expiration) = _proposeWith(true);
        uint128 amount2 = 2000e18; // produces price 5e26, outside tight band around 1e27
        (uint128 reportId, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, amount2, expiration);

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, amount2);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(reportId, og, ph);

        // Verify SlippageBailout event fires, then check internal-balance refund accounting.
        vm.recordLogs();
        _execute(swapId, sPost, og, ph, address(0x99));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 slippageSig = keccak256("SlippageBailout(uint256)");
        bool sawSlippage;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == slippageSig) { sawSlippage = true; break; }
        }
        assertTrue(sawSlippage, "SlippageBailout emitted");

        // Swapper sellToken back internally; nothing pushed externally (test verifies internal-mode refund path).
        assertEq(_spendable(swapper, address(sellToken)), swapperInternalSellBefore, "swapper sellToken refunded internally");
        assertEq(buyToken.balanceOf(swapper), swapperBuyExternalBefore, "no external push to swapper");
        amount2;
        // Settle credits matcher back with their oracle-game amount2 stake; refund() returns minFulfillLiquidity.
        assertEq(_spendable(matcher, address(buyToken)), matcherInternalBuyBefore, "matcher buyToken fully restored internally");
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted");
    }
}
