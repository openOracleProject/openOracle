// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenAMMTestBase} from "./OpenAMMTestBase.sol";

/// @dev Same flow with realistic 6-decimal USDC against 18-decimal WETH, to catch
///      scaling/rounding surprises in the price math and price tolerance.
contract OpenAMMUsdc6Test is OpenAMMTestBase {
    function _usdcDecimals() internal view virtual override returns (uint8) {
        return 6;
    }

    function _warpIntoWindow() internal {
        vm.warp(block.timestamp + EXECUTION_DELAY + 1);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 100;
    }

    function test_decimals_areSix() public view {
        assertEq(usdc.decimals(), 6);
        assertEq(AMOUNT2, 4000e6);
    }

    function test_price_exactInput_wethToUsdc6() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e6);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], 4000e6, "1 WETH -> 4000 USDC(6)");
        assertEq(a[1], _expectedOut(1e18, true, 0, INIT_LIQUIDITY, AMOUNT2));
    }

    function test_price_exactInput_usdcToWeth6() public {
        _quoteDefault();
        _fundAmmEth(10e18);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsOut(4000e6, _pathUsdcWeth());
        assertEq(a[1], 1e18, "4000 USDC(6) -> 1 WETH");
        assertEq(a[1], _expectedOut(4000e6, false, 0, INIT_LIQUIDITY, AMOUNT2));
    }

    function test_price_exactOutput_wethToUsdc6() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e6);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsIn(4000e6, _pathWethUsdc());
        assertEq(a[0], 1e18);
        assertEq(a[0], _expectedIn(4000e6, true, 0, INIT_LIQUIDITY, AMOUNT2));
    }

    function test_swap_wethToUsdc6_effects() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e6);
        _fundAmmEth(10e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 1e18);

        uint256 ethBefore = oracle.tokenHolder(address(amm), address(0));
        uint256 usdcBefore = oracle.tokenHolder(address(amm), address(usdc));

        vm.prank(trader);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), recipient, _deadline());

        assertEq(usdc.balanceOf(recipient), 4000e6);
        assertEq(oracle.tokenHolder(address(amm), address(0)), ethBefore + 1e18);
        assertEq(oracle.tokenHolder(address(amm), address(usdc)), usdcBefore - 4000e6);
    }

    function test_priceTolerance_scalesWithDecimals() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e6);
        // price = mulDiv(1e18, 1e30, 4000e6) = 2.5e38; tolerate it within 1%.
        vm.prank(owner);
        amm.setExecutionParams(2.5e38, 1e5);
        _warpIntoWindow();
        // In-band: the live quote price equals priceTolerated, so this must succeed.
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], 4000e6);
    }
}
