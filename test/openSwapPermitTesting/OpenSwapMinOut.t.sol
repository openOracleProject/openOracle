// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";

contract OpenSwapMinOutTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    function _proposeWithMinOut(uint128 minOut) internal returns (uint256 swapId, uint48 expiration) {
        expiration = uint48(block.timestamp + 1 hours);
        proposeTs = uint48(block.timestamp);
        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        vm.prank(swapper);
        swapId = SwapCompat.proposeRaw(swapContract, ethToSend, 
            SELL_AMT,
            address(sellToken),
            minOut,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(), false
        );
    }

    function _calcFulfillAmt(uint256 amount1, uint256 amount2) internal pure returns (uint256) {
        uint256 fulfillAmt = (uint256(SELL_AMT) * amount2) / amount1;
        fulfillAmt -= (fulfillAmt * STARTING_FEE) / 1e7;
        return fulfillAmt;
    }

    function _runToExecute(uint256 swapId, uint48 expiration, uint128 amount2)
        internal
        returns (uint256 fulfillAmt)
    {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, amount2, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, amount2);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        _settle(reportId, og, ph);
        _execute(swapId, sPost, og, ph, address(0x99));

        fulfillAmt = _calcFulfillAmt(INITIAL_LIQUIDITY, amount2);
    }

    // ── Validation at propose ───────────────────────────────────────────

    function testMinOut_ZeroReverts() public {
        vm.prank(swapper);
        vm.expectRevert(Errors.ZeroAmount.selector);
        SwapCompat.proposeRaw(swapContract, MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD, 
            SELL_AMT,
            address(sellToken),
            0,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(), false
        );
    }

    function testMinOut_TooHighReverts() public {
        // minOut > worstFulfillAmt should revert with "minOut inconsistent".
        // With the default slippage params, worstFulfillAmt is computed against the upper price
        // and the max fulfillment fee. Setting minOut absurdly high triggers the check.
        vm.prank(swapper);
        vm.expectRevert(Errors.MinOutInconsistent.selector);
        SwapCompat.proposeRaw(swapContract, MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD, 
            SELL_AMT,
            address(sellToken),
            type(uint128).max, // unreachable minOut
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(), false
        );
    }

    // ── Successful executes at various oracle amounts ──────────────────

    function testMinOut_ExactlyMet() public {
        (uint256 swapId, uint48 expiration) = _proposeWithMinOut(1e18);
        uint256 fulfillAmt = _runToExecute(swapId, expiration, 2000e18);
        assertEq(fulfillAmt, 19980e18, "fulfillAmt math");
        assertEq(buyToken.balanceOf(swapper), fulfillAmt, "swapper got fulfillAmt");
    }

    function testMinOut_Exceeded() public {
        uint256 minOut = 1e18;
        (uint256 swapId, uint48 expiration) = _proposeWithMinOut(uint128(minOut));
        uint256 fulfillAmt = _runToExecute(swapId, expiration, 2000e18);
        assertGt(fulfillAmt, minOut, "fulfillAmt > minOut");
        assertEq(buyToken.balanceOf(swapper), fulfillAmt, "swapper got fulfillAmt");
    }

    function testMinOut_LowOraclePrice() public {
        // Lower amount2 → lower fulfillAmt. With loose slippage tolerance the swap still executes.
        (uint256 swapId, uint48 expiration) = _proposeWithMinOut(1e18);
        uint256 fulfillAmt = _runToExecute(swapId, expiration, 1400e18);
        // 10e18 * 1400e18 / 1e18 = 14000e18, minus 0.1% fee = 13986e18
        assertEq(fulfillAmt, 13986e18, "fulfillAmt at lower price");
        assertEq(buyToken.balanceOf(swapper), fulfillAmt, "swapper got lower fulfillAmt");
    }

    function testMinOut_HighOraclePrice() public {
        (uint256 swapId, uint48 expiration) = _proposeWithMinOut(1e18);
        uint256 fulfillAmt = _runToExecute(swapId, expiration, 2500e18);
        // 10e18 * 2500e18 / 1e18 = 25000e18, minus 0.1% fee = 24975e18
        assertEq(fulfillAmt, 24975e18, "fulfillAmt at higher price");
        assertEq(buyToken.balanceOf(swapper), fulfillAmt, "swapper got higher fulfillAmt");
    }

    function testMinOut_FulfillmentFeeImpact() public {
        // Verify the fee math: raw = sellAmt * amt2 / amt1; fulfilled = raw - raw*fee/1e7
        uint256 raw = (uint256(SELL_AMT) * 2000e18) / INITIAL_LIQUIDITY;
        uint256 withFee = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        assertEq(raw, 20000e18, "raw without fee");
        assertEq(withFee, 19980e18, "with 0.1% fee");
        assertEq(raw - withFee, 20e18, "fee delta");

        (uint256 swapId, uint48 expiration) = _proposeWithMinOut(1e18);
        _runToExecute(swapId, expiration, 2000e18);
        assertEq(buyToken.balanceOf(swapper), withFee, "swapper got fee-adjusted fulfillAmt");
    }
}
