// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenAMMTestBase} from "./OpenAMMTestBase.sol";
import {openAMM} from "../../src/openAMM.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";

/// @dev Adapter-focused integration tests for openAMM against the real OpenOracle.
contract OpenAMMTest is OpenAMMTestBase {
    // Local mirror of the AMM's event for vm.expectEmit matching.
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 100;
    }

    function _warpIntoWindow() internal {
        vm.warp(block.timestamp + EXECUTION_DELAY + 1);
    }

    // ────────────────────────── 1. Deployment ──────────────────────────

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert();
        new openAMM(address(0), address(oracle), address(usdc));
    }

    function test_constructor_rejectsZeroOracle() public {
        vm.expectRevert();
        new openAMM(owner, address(0), address(usdc));
    }

    function test_constructor_rejectsZeroToken1() public {
        vm.expectRevert();
        new openAMM(owner, address(oracle), address(0));
    }

    function test_constructor_rejectsToken1IsWeth() public {
        vm.expectRevert();
        new openAMM(owner, address(oracle), WETH_ADDR);
    }

    function test_constructor_storesState() public view {
        assertEq(amm.owner(), owner);
        assertEq(address(amm.openOracle()), address(oracle));
        assertEq(amm.token0(), WETH_ADDR);
        assertEq(amm.token1(), address(usdc));
    }

    // ─────────────────────── 2. Quote creation ─────────────────────────

    function test_quote_setsHighestReportIdAndRules() public {
        uint256 reportId = _quoteDefault();
        assertEq(amm.highestReportId(), reportId);

        (uint48 ed, uint48 st, uint24 fee, bool inactive) = amm.quoteRules(reportId);
        assertEq(ed, EXECUTION_DELAY);
        assertEq(st, SETTLEMENT_TIME);
        assertEq(fee, 0);
        assertEq(inactive, false);
    }

    function test_quote_onlyOwner() public {
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        vm.expectRevert(openAMM.NotOwner.selector);
        amm.quote{value: SETTLER_REWARD}(_defaultParams(), _emptyTiming(), AMOUNT2, EXECUTION_DELAY, 0);
    }

    function test_quote_wrongMsgValueReverts() public {
        vm.prank(owner);
        vm.expectRevert(openAMM.InvalidMsgValue.selector);
        amm.quote{value: SETTLER_REWARD + 1}(_defaultParams(), _emptyTiming(), AMOUNT2, EXECUTION_DELAY, 0);
    }

    function test_quote_settlementTimeTooHighReverts() public {
        openAMM.OracleParams memory p = _defaultParams();
        p.settlementTime = 31;
        vm.prank(owner);
        vm.expectRevert(openAMM.InvalidSettlementTime.selector);
        amm.quote{value: SETTLER_REWARD}(p, _emptyTiming(), AMOUNT2, EXECUTION_DELAY, 0);
    }

    function test_quote_executionDelayGteSettlementReverts() public {
        vm.prank(owner);
        vm.expectRevert(openAMM.InvalidExecutionDelay.selector);
        amm.quote{value: SETTLER_REWARD}(_defaultParams(), _emptyTiming(), AMOUNT2, SETTLEMENT_TIME, 0);
    }

    function test_quote_invalidFeeReverts() public {
        vm.prank(owner);
        vm.expectRevert(openAMM.InvalidFee.selector);
        amm.quote{value: SETTLER_REWARD}(
            _defaultParams(), _emptyTiming(), AMOUNT2, EXECUTION_DELAY, uint24(FEE_DENOMINATOR)
        );
    }

    function test_quote_oracleGameUsesEthAndToken1() public {
        uint256 reportId = _quoteDefault();
        // The stored state hash only matches if the AMM built the game with exactly these
        // params: token1 = ETH sentinel, token2 = USDC, flags = 3, currentReporter = owner, etc.
        assertEq(oracle.oracleGame(reportId), keccak256(abi.encode(_storedGame(), _storedHelper(reportId))));
        // Initial tracked row written at index 0; reportIdToReportNumber still default 0.
        (uint128 a1, uint128 a2,, uint48 ts) = oracle.disputeHistory(reportId, 0);
        assertEq(a1, INIT_LIQUIDITY);
        assertEq(a2, AMOUNT2);
        assertEq(ts, qTs);
        assertEq(oracle.reportIdToReportNumber(reportId), 0);
    }

    // ────────────────────── 3. Quote lifecycle ─────────────────────────

    function test_window_beforeExecutionDelay_reverts() public {
        _quoteDefault();
        vm.warp(block.timestamp + EXECUTION_DELAY - 1);
        vm.expectRevert(openAMM.QuoteNotReady.selector);
        amm.getAmountsOut(1e18, _pathWethUsdc());
    }

    function test_window_atSettlement_reverts() public {
        _quoteDefault();
        vm.warp(block.timestamp + SETTLEMENT_TIME);
        vm.expectRevert(openAMM.QuoteExpired.selector);
        amm.getAmountsOut(1e18, _pathWethUsdc());
    }

    function test_window_live_quotesWork() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], _expectedOut(1e18, true, 0, INIT_LIQUIDITY, AMOUNT2));
    }

    function test_setQuoteInactive_reverts() public {
        uint256 reportId = _quoteDefault();
        vm.prank(owner);
        amm.setQuoteParams(reportId, true, EXECUTION_DELAY, 0);
        _warpIntoWindow();
        vm.expectRevert(openAMM.QuoteInactive.selector);
        amm.getAmountsOut(1e18, _pathWethUsdc());
    }

    function test_pause_blocksSwaps_notQuotes() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 1e18);

        vm.prank(owner);
        amm.pause(true);

        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], _expectedOut(1e18, true, 0, INIT_LIQUIDITY, AMOUNT2));

        vm.prank(trader);
        vm.expectRevert(openAMM.Paused.selector);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), recipient, _deadline());
    }

    // ───────────────────────────── 4. Pricing ──────────────────────────

    function test_price_exactInput_wethToUsdc() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], 4000e18);
        assertEq(a[1], _expectedOut(1e18, true, 0, INIT_LIQUIDITY, AMOUNT2));
    }

    function test_price_exactInput_usdcToWeth() public {
        _quoteDefault();
        _fundAmmEth(10e18);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsOut(4000e18, _pathUsdcWeth());
        assertEq(a[1], 1e18);
        assertEq(a[1], _expectedOut(4000e18, false, 0, INIT_LIQUIDITY, AMOUNT2));
    }

    function test_price_exactOutput_wethToUsdc() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsIn(4000e18, _pathWethUsdc());
        assertEq(a[0], 1e18);
        assertEq(a[0], _expectedIn(4000e18, true, 0, INIT_LIQUIDITY, AMOUNT2));
    }

    function test_price_exactOutput_usdcToWeth() public {
        _quoteDefault();
        _fundAmmEth(10e18);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsIn(1e18, _pathUsdcWeth());
        assertEq(a[0], 4000e18);
        assertEq(a[0], _expectedIn(1e18, false, 0, INIT_LIQUIDITY, AMOUNT2));
    }

    function test_price_feeReducesOutput() public {
        uint24 fee = 30000; // 0.3%
        _quote(EXECUTION_DELAY, fee, AMOUNT2);
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], _expectedOut(1e18, true, fee, INIT_LIQUIDITY, AMOUNT2));
        assertLt(a[1], 4000e18);
    }

    function test_price_maxFee_noOverflow() public {
        uint24 fee = uint24(FEE_DENOMINATOR - 1);
        _quote(EXECUTION_DELAY, fee, AMOUNT2);
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsIn(1e6, _pathWethUsdc());
        assertEq(a[0], _expectedIn(1e6, true, fee, INIT_LIQUIDITY, AMOUNT2));
        assertGt(a[0], 1e6);
    }

    function test_invalidPath_wrongPair_reverts() public {
        _quoteDefault();
        _warpIntoWindow();
        address[] memory bad = new address[](2);
        bad[0] = WETH_ADDR;
        bad[1] = WETH_ADDR;
        vm.expectRevert(openAMM.InvalidPath.selector);
        amm.getAmountsOut(1e18, bad);
    }

    function test_invalidPath_wrongLength_reverts() public {
        _quoteDefault();
        _warpIntoWindow();
        address[] memory bad = new address[](3);
        bad[0] = WETH_ADDR;
        bad[1] = address(usdc);
        bad[2] = WETH_ADDR;
        vm.expectRevert(openAMM.InvalidPath.selector);
        amm.getAmountsOut(1e18, bad);
    }

    function test_zeroAmounts_revert() public {
        _quoteDefault();
        _warpIntoWindow();
        vm.expectRevert(openAMM.InsufficientInputAmount.selector);
        amm.getAmountsOut(0, _pathWethUsdc());
        vm.expectRevert(openAMM.InsufficientOutputAmount.selector);
        amm.getAmountsIn(0, _pathWethUsdc());
    }

    function test_slippage_amountOutMin_reverts() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 1e18);
        vm.prank(trader);
        vm.expectRevert(openAMM.InsufficientOutputAmount.selector);
        amm.swapExactTokensForTokens(1e18, 4001e18, _pathWethUsdc(), recipient, _deadline());
    }

    function test_slippage_amountInMax_reverts() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 1e18);
        vm.prank(trader);
        vm.expectRevert(openAMM.ExcessiveInputAmount.selector);
        amm.swapTokensForExactTokens(4000e18, 0.5e18, _pathWethUsdc(), recipient, _deadline());
    }

    // ──────────────────────── 5. Inventory checks ──────────────────────

    function test_getAmountsOut_insufficientInventory_reverts() public {
        _quoteDefault();
        _warpIntoWindow();
        vm.expectRevert(openAMM.InsufficientInventory.selector);
        amm.getAmountsOut(1e18, _pathWethUsdc());
    }

    function test_getAmountsIn_insufficientInventory_reverts() public {
        _quoteDefault();
        _warpIntoWindow();
        vm.expectRevert(openAMM.InsufficientInventory.selector);
        amm.getAmountsIn(4000e18, _pathWethUsdc());
    }

    function test_swap_insufficientInventory_revertsBeforePull() public {
        _quoteDefault();
        _warpIntoWindow();
        _giveTraderWeth(trader, 1e18);
        uint256 before = weth.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(openAMM.InsufficientInventory.selector);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), recipient, _deadline());
        assertEq(weth.balanceOf(trader), before, "no funds pulled on revert");
    }

    function test_inventorySentinel_boundary() public {
        _quoteDefault();
        _warpIntoWindow();
        _giveTraderWeth(trader, 2e18);
        uint256 out = 4000e18; // 1e18 in @ 4000, fee 0

        _fundAmmUsdc(out - 1); // first credit -> tokenHolder = out  => bal <= amountOut, revert
        vm.prank(trader);
        vm.expectRevert(openAMM.InsufficientInventory.selector);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), recipient, _deadline());

        _fundAmmUsdc(1); // tokenHolder = out + 1 => ok
        vm.prank(trader);
        uint256[] memory a = amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), recipient, _deadline());
        assertEq(a[1], out);
        assertEq(usdc.balanceOf(recipient), out);
    }

    // ─────────────────────── 6. Swap execution ─────────────────────────

    function test_swap_wethToUsdc_effects() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _fundAmmEth(10e18); // seed ETH slot so the deposit delta is exact
        _warpIntoWindow();
        _giveTraderWeth(trader, 1e18);

        uint256 ethBefore = oracle.tokenHolder(address(amm), address(0));
        uint256 usdcBefore = oracle.tokenHolder(address(amm), address(usdc));

        vm.prank(trader);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), recipient, _deadline());

        assertEq(weth.balanceOf(trader), 0, "trader WETH spent");
        assertEq(usdc.balanceOf(recipient), 4000e18, "recipient got USDC");
        assertEq(oracle.tokenHolder(address(amm), address(0)), ethBefore + 1e18, "AMM ETH up by input");
        assertEq(oracle.tokenHolder(address(amm), address(usdc)), usdcBefore - 4000e18, "AMM USDC down by output");
    }

    function test_swap_usdcToWeth_effects() public {
        _quoteDefault();
        _fundAmmEth(10e18);
        _fundAmmUsdc(50_000e18); // seed USDC slot so the deposit delta is exact
        _warpIntoWindow();
        _giveTraderUsdc(trader, 4000e18);

        uint256 ethBefore = oracle.tokenHolder(address(amm), address(0));
        uint256 usdcBefore = oracle.tokenHolder(address(amm), address(usdc));

        vm.prank(trader);
        amm.swapExactTokensForTokens(4000e18, 0, _pathUsdcWeth(), recipient, _deadline());

        assertEq(usdc.balanceOf(trader), 0, "trader USDC spent");
        assertEq(weth.balanceOf(recipient), 1e18, "recipient got WETH");
        assertEq(oracle.tokenHolder(address(amm), address(usdc)), usdcBefore + 4000e18, "AMM USDC up by input");
        assertEq(oracle.tokenHolder(address(amm), address(0)), ethBefore - 1e18, "AMM ETH down by output");
    }

    function test_swap_emitsSwap_wethToUsdc() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 1e18);

        vm.expectEmit(true, true, false, true, address(amm));
        emit Swap(trader, 1e18, 0, 0, 4000e18, recipient);
        vm.prank(trader);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), recipient, _deadline());
    }

    function test_swap_emitsSwap_usdcToWeth() public {
        _quoteDefault();
        _fundAmmEth(10e18);
        _warpIntoWindow();
        _giveTraderUsdc(trader, 4000e18);

        vm.expectEmit(true, true, false, true, address(amm));
        emit Swap(trader, 0, 4000e18, 1e18, 0, recipient);
        vm.prank(trader);
        amm.swapExactTokensForTokens(4000e18, 0, _pathUsdcWeth(), recipient, _deadline());
    }

    function test_swap_rejectsBadTo() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 3e18);

        vm.startPrank(trader);
        vm.expectRevert(openAMM.InvalidTo.selector);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), address(0), _deadline());

        vm.expectRevert(openAMM.InvalidTo.selector);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), WETH_ADDR, _deadline());

        vm.expectRevert(openAMM.InvalidTo.selector);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), address(usdc), _deadline());
        vm.stopPrank();
    }

    // ─────────────────── 7. Dispute tracking integration ───────────────

    function test_initialQuote_usesRowZero() public {
        uint256 reportId = _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        assertEq(oracle.reportIdToReportNumber(reportId), 0);
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], 4000e18);
    }

    function test_afterDispute_usesLatestRow() public {
        uint256 reportId = _quoteDefault();
        _fundAmmUsdc(50_000e18);

        // Real dispute: escalate amount1 by multiplier, quote 5000 USDC/ETH (1.1e18 : 5500e18).
        uint48 dts = _disputeUsdc(reportId, _multiplierUp(INIT_LIQUIDITY), 5500e18);
        assertEq(oracle.reportIdToReportNumber(reportId), 1);

        vm.warp(dts + EXECUTION_DELAY + 1);
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], 5000e18, "uses disputed row price");
    }

    function test_priceOutOfBounds_whenDisputeMovesPrice() public {
        uint256 reportId = _quoteDefault();
        // Tolerate the original price (2.5e26) within 1%.
        vm.prank(owner);
        amm.setExecutionParams(2.5e26, 1e5);

        // Dispute to 1.1e18 : 6000e18 -> price 1.833e26, well below the lower bound.
        uint48 dts = _disputeUsdc(reportId, _multiplierUp(INIT_LIQUIDITY), 6000e18);
        vm.warp(dts + EXECUTION_DELAY + 1);

        vm.expectRevert(openAMM.PriceOutOfBounds.selector);
        amm.getAmountsOut(1e18, _pathWethUsdc());
    }

    function test_toleranceDisabled_allowsOutOfBand() public {
        uint256 reportId = _quoteDefault();
        _fundAmmUsdc(50_000e18);
        // priceTolerated stays 0 (disabled).
        uint128 newA1 = _multiplierUp(INIT_LIQUIDITY);
        uint128 newA2 = 6000e18;
        uint48 dts = _disputeUsdc(reportId, newA1, newA2);
        vm.warp(dts + EXECUTION_DELAY + 1);

        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], _expectedOut(1e18, true, 0, newA1, newA2));
    }

    // ───────────────────────── 8. Owner controls ───────────────────────

    function test_setExecutionParams_maxTolerance() public {
        vm.startPrank(owner);
        amm.setExecutionParams(1e26, uint24(FEE_DENOMINATOR / 100)); // exactly 1% ok
        assertEq(amm.toleranceRange(), uint24(FEE_DENOMINATOR / 100));

        vm.expectRevert(openAMM.InvalidTolerance.selector);
        amm.setExecutionParams(1e26, uint24(FEE_DENOMINATOR / 100) + 1);
        vm.stopPrank();
    }

    function test_setQuoteParams_updatesAndPreservesSettlementTime() public {
        uint256 reportId = _quoteDefault();
        vm.prank(owner);
        amm.setQuoteParams(reportId, true, 7, 1000);

        (uint48 ed, uint48 st, uint24 fee, bool inactive) = amm.quoteRules(reportId);
        assertEq(ed, 7);
        assertEq(st, SETTLEMENT_TIME, "settlementTime preserved");
        assertEq(fee, 1000);
        assertEq(inactive, true);
    }

    function test_setQuoteParams_executionDelayGteSettlement_reverts() public {
        uint256 reportId = _quoteDefault();
        vm.prank(owner);
        vm.expectRevert(openAMM.InvalidExecutionDelay.selector);
        amm.setQuoteParams(reportId, false, SETTLEMENT_TIME, 0);
    }

    function test_pause_unpause_restoresSwaps() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 1e18);

        vm.prank(owner);
        amm.pause(true);
        vm.prank(trader);
        vm.expectRevert(openAMM.Paused.selector);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), recipient, _deadline());

        vm.prank(owner);
        amm.pause(false);
        vm.prank(trader);
        uint256[] memory a = amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), recipient, _deadline());
        assertEq(a[1], 4000e18);
    }

    function test_oracleInternalTransfer_movesBalanceToOwner() public {
        _fundAmmUsdc(1000e18);
        uint256 ammBefore = oracle.tokenHolder(address(amm), address(usdc));
        uint256 ownerBefore = oracle.tokenHolder(owner, address(usdc));

        vm.prank(owner);
        amm.oracleInternalTransfer(address(usdc), 400e18);

        assertEq(oracle.tokenHolder(address(amm), address(usdc)), ammBefore - 400e18);
        assertEq(oracle.tokenHolder(owner, address(usdc)), ownerBefore + 400e18);
    }

    function test_oracleApproval_setsAllowance() public view {
        assertEq(usdc.allowance(address(amm), address(oracle)), type(uint256).max);
    }

    function test_ownerControls_onlyOwner() public {
        vm.startPrank(trader);
        vm.expectRevert(openAMM.NotOwner.selector);
        amm.pause(true);
        vm.expectRevert(openAMM.NotOwner.selector);
        amm.oracleApproval(address(usdc));
        vm.expectRevert(openAMM.NotOwner.selector);
        amm.oracleInternalTransfer(address(usdc), 1);
        vm.expectRevert(openAMM.NotOwner.selector);
        amm.setExecutionParams(1, 1);
        vm.expectRevert(openAMM.NotOwner.selector);
        amm.setQuoteParams(1, false, 1, 0);
        vm.stopPrank();
    }

    function test_oracleInternalTransfer_eth() public {
        _fundAmmEth(5e18);
        uint256 ammBefore = oracle.tokenHolder(address(amm), address(0));
        uint256 ownerBefore = oracle.tokenHolder(owner, address(0));

        vm.prank(owner);
        amm.oracleInternalTransfer(address(0), 2e18);

        assertEq(oracle.tokenHolder(address(amm), address(0)), ammBefore - 2e18);
        assertEq(oracle.tokenHolder(owner, address(0)), ownerBefore + 2e18);
    }

    function test_toleranceRangeZero_disablesGuard() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        // priceTolerated set to a value that does NOT match the live price (2.5e26),
        // but toleranceRange == 0 disables the guard entirely.
        vm.prank(owner);
        amm.setExecutionParams(1e26, 0);
        _warpIntoWindow();
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], 4000e18);
    }

    function test_swapExactOutput_rejectsBadPathAndTo() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 2e18);

        address[] memory bad = new address[](2);
        bad[0] = WETH_ADDR;
        bad[1] = WETH_ADDR;

        vm.startPrank(trader);
        vm.expectRevert(openAMM.InvalidPath.selector);
        amm.swapTokensForExactTokens(4000e18, 2e18, bad, recipient, _deadline());

        vm.expectRevert(openAMM.InvalidTo.selector);
        amm.swapTokensForExactTokens(4000e18, 2e18, _pathWethUsdc(), WETH_ADDR, _deadline());
        vm.stopPrank();
    }

    // ──────────────── 9. Exact-output swap execution ───────────────────

    function test_swapExactOutput_wethToUsdc_effects() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _fundAmmEth(10e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 2e18);

        uint256 expIn = _expectedIn(4000e18, true, 0, INIT_LIQUIDITY, AMOUNT2);
        uint256 ethBefore = oracle.tokenHolder(address(amm), address(0));
        uint256 usdcBefore = oracle.tokenHolder(address(amm), address(usdc));

        vm.prank(trader);
        uint256[] memory a = amm.swapTokensForExactTokens(4000e18, 2e18, _pathWethUsdc(), recipient, _deadline());

        assertEq(a[0], expIn);
        assertEq(a[1], 4000e18);
        assertEq(weth.balanceOf(trader), 2e18 - expIn, "trader WETH down by input");
        assertEq(usdc.balanceOf(recipient), 4000e18, "recipient got exact USDC");
        assertEq(oracle.tokenHolder(address(amm), address(0)), ethBefore + expIn);
        assertEq(oracle.tokenHolder(address(amm), address(usdc)), usdcBefore - 4000e18);
    }

    function test_swapExactOutput_usdcToWeth_effects() public {
        _quoteDefault();
        _fundAmmEth(10e18);
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        _giveTraderUsdc(trader, 5000e18);

        uint256 expIn = _expectedIn(1e18, false, 0, INIT_LIQUIDITY, AMOUNT2);
        uint256 ethBefore = oracle.tokenHolder(address(amm), address(0));
        uint256 usdcBefore = oracle.tokenHolder(address(amm), address(usdc));

        vm.prank(trader);
        uint256[] memory a = amm.swapTokensForExactTokens(1e18, 5000e18, _pathUsdcWeth(), recipient, _deadline());

        assertEq(a[0], expIn);
        assertEq(a[1], 1e18);
        assertEq(usdc.balanceOf(trader), 5000e18 - expIn, "trader USDC down by input");
        assertEq(weth.balanceOf(recipient), 1e18, "recipient got exact WETH");
        assertEq(oracle.tokenHolder(address(amm), address(usdc)), usdcBefore + expIn);
        assertEq(oracle.tokenHolder(address(amm), address(0)), ethBefore - 1e18);
    }

    // ──────────────────────── 10. Boundary timing ──────────────────────

    function test_window_atExecutionDelayEdge_works() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        vm.warp(qTs + EXECUTION_DELAY); // exactly ready
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], 4000e18);
    }

    function test_window_lastValidSecond_works() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        vm.warp(qTs + SETTLEMENT_TIME - 1); // last valid second
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], 4000e18);
    }

    // ─────────────── 11. ETH-side inventory sentinel boundary ───────────

    function test_inventorySentinel_ethBoundary() public {
        _quoteDefault();
        _warpIntoWindow();
        _giveTraderUsdc(trader, 8000e18); // enough for two attempts
        uint256 out = 1e18; // 4000e18 USDC in @ 4000 -> 1e18 WETH out, fee 0

        _fundAmmEth(out - 1); // tokenHolder[amm][ETH] = out  => bal <= amountOut, revert
        vm.prank(trader);
        vm.expectRevert(openAMM.InsufficientInventory.selector);
        amm.swapExactTokensForTokens(4000e18, 0, _pathUsdcWeth(), recipient, _deadline());

        _fundAmmEth(1); // tokenHolder = out + 1 => ok
        vm.prank(trader);
        uint256[] memory a = amm.swapExactTokensForTokens(4000e18, 0, _pathUsdcWeth(), recipient, _deadline());
        assertEq(a[1], out);
        assertEq(weth.balanceOf(recipient), out);
    }

    // ───────────────────────── 12. Deadline expiry ─────────────────────

    function test_deadlineExpired_exactInput() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 1e18);
        vm.prank(trader);
        vm.expectRevert(openAMM.Expired.selector);
        amm.swapExactTokensForTokens(1e18, 0, _pathWethUsdc(), recipient, block.timestamp - 1);
    }

    function test_deadlineExpired_exactOutput() public {
        _quoteDefault();
        _fundAmmUsdc(50_000e18);
        _warpIntoWindow();
        _giveTraderWeth(trader, 2e18);
        vm.prank(trader);
        vm.expectRevert(openAMM.Expired.selector);
        amm.swapTokensForExactTokens(4000e18, 2e18, _pathWethUsdc(), recipient, block.timestamp - 1);
    }

    // ──────────────────────── 13. AmountTooLarge ───────────────────────

    function test_amountTooLarge_exactInput() public {
        _quoteDefault();
        _warpIntoWindow();
        vm.prank(trader);
        vm.expectRevert(openAMM.AmountTooLarge.selector);
        amm.swapExactTokensForTokens(uint256(type(uint128).max) + 1, 0, _pathWethUsdc(), recipient, _deadline());
    }

    function test_amountTooLarge_exactOutput() public {
        _quoteDefault();
        _warpIntoWindow();
        vm.prank(trader);
        vm.expectRevert(openAMM.AmountTooLarge.selector);
        amm.swapTokensForExactTokens(
            uint256(type(uint128).max) + 1, type(uint256).max, _pathWethUsdc(), recipient, _deadline()
        );
    }

    // ──────────────── 14. Failed quote does not poison state ────────────

    function test_failedQuote_doesNotPoisonState() public {
        uint256 r1 = _quoteDefault();
        assertEq(amm.highestReportId(), r1);
        uint256 nextId = oracle.nextReportId();

        // amount2 == 0 makes oracle.report revert (InvalidAmount2); the whole quote must roll back.
        vm.prank(owner);
        vm.expectRevert();
        amm.quote{value: SETTLER_REWARD}(_defaultParams(), _emptyTiming(), 0, EXECUTION_DELAY, 0);

        assertEq(amm.highestReportId(), r1, "highestReportId not advanced by failed quote");
        (, uint48 st,,) = amm.quoteRules(nextId);
        assertEq(st, 0, "no quoteRules persisted for failed quote");
    }

    // ──────────────────────── 15. Second dispute row ───────────────────

    function test_secondDispute_followsRow2() public {
        uint256 reportId = _quoteDefault();
        _fundAmmUsdc(50_000e18);

        // Dispute 1 -> row 1: 1.1e18 : 5500e18 (price 5000)
        uint128 a1_1 = _multiplierUp(INIT_LIQUIDITY);
        uint128 a2_1 = 5500e18;
        uint48 dts1 = _disputeUsdc(reportId, a1_1, a2_1);
        assertEq(oracle.reportIdToReportNumber(reportId), 1);

        // Dispute 2 -> row 2: 1.21e18 : 7260e18 (price 6000), by a fresh disputer.
        uint128 a1_2 = _multiplierUp(a1_1);
        uint128 a2_2 = 7260e18;
        address d2 = address(0xD1);
        usdc.transfer(d2, uint256(a2_2) + a2_1); // newAmount2 + oldAmount2
        vm.deal(d2, 1 ether);
        vm.prank(d2);
        usdc.approve(address(oracle), type(uint256).max);

        uint48 dts2 = dts1 + DISPUTE_DELAY + 1;
        vm.warp(dts2);
        vm.prank(d2);
        IOpenOracle2(address(oracle)).dispute{value: uint256(a1_2) - a1_1}(
            reportId,
            address(usdc),
            a1_2,
            a2_2,
            d2,
            false,
            false,
            _gameWith(a1_1, a2_1, disputer, dts1, 2), // game as stored after dispute 1
            _storedHelper(reportId),
            _emptyTiming()
        );
        assertEq(oracle.reportIdToReportNumber(reportId), 2);

        vm.warp(dts2 + EXECUTION_DELAY + 1);
        uint256[] memory a = amm.getAmountsOut(1e18, _pathWethUsdc());
        assertEq(a[1], 6000e18, "follows row 2, not row 1");
    }
}
