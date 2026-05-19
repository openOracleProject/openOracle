// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

contract OpenSwapInputValidationTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    function _bareCall(address sellTok, uint128 sellAmt, uint128 minOut, address buyTok, uint128 minFulfill,
        SwapCompat.OracleParams memory op, openSwapV2.FulfillFeeParams memory ff) internal
    {
        proposeTs = uint48(block.timestamp);
        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + op.settlerReward;
        // For ETH-sell case the test caller adds sellAmt to msg.value before this fn; not used here
        vm.prank(swapper);
        SwapCompat.proposeRaw(swapContract, ethToSend, 
            sellAmt, sellTok, minOut, buyTok, minFulfill,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            op, _defaultSlippage(), ff, _emptyPermit2(), false
        );
    }

    // ── Propose validation ──────────────────────────────────────────────

    function testSwap_SellTokenEqualsBuyToken_Reverts() public {
        vm.expectRevert(Errors.TokensCannotBeSame.selector);
        _bareCall(address(sellToken), SELL_AMT, MIN_OUT, address(sellToken), MIN_FULFILL_LIQUIDITY,
            _defaultOracleParams(), _defaultFulfillFee());
    }

    // WETH/ETH coupling check removed — openSwap is now chain-agnostic and no longer
    // hardcodes a WETH address. Swappers can freely propose WETH↔ETH if they want (silly but valid).

    function testSwap_ZeroSellAmt_Reverts() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        _bareCall(address(sellToken), 0, MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            _defaultOracleParams(), _defaultFulfillFee());
    }

    function testSwap_ZeroMinOut_Reverts() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        _bareCall(address(sellToken), SELL_AMT, 0, address(buyToken), MIN_FULFILL_LIQUIDITY,
            _defaultOracleParams(), _defaultFulfillFee());
    }

    function testSwap_ZeroMinFulfillLiquidity_Reverts() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        _bareCall(address(sellToken), SELL_AMT, MIN_OUT, address(buyToken), 0,
            _defaultOracleParams(), _defaultFulfillFee());
    }

    function testSwap_MaxFeeAt1e7_Reverts() public {
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();
        ff.maxFee = uint24(1e7);
        vm.expectRevert();
        _bareCall(address(sellToken), SELL_AMT, MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            _defaultOracleParams(), ff);
    }

    function testSwap_MaxFeeJustBelow1e7_Succeeds() public {
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();
        ff.maxFee = uint24(1e7 - 1);
        // With near-100% fee, worstFulfillAmt approaches 0, so minOut must be tiny to pass
        _bareCall(address(sellToken), SELL_AMT, 1, address(buyToken), MIN_FULFILL_LIQUIDITY,
            _defaultOracleParams(), ff);
    }

    function testSwap_SettlementTimeZero_Reverts() public {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.settlementTime = 0;
        vm.expectRevert();
        _bareCall(address(sellToken), SELL_AMT, MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            op, _defaultFulfillFee());
    }

    function testSwap_InitialLiquidityZero_Reverts() public {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.initialLiquidity = 0;
        vm.expectRevert();
        _bareCall(address(sellToken), SELL_AMT, MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            op, _defaultFulfillFee());
    }

    function testSwap_DisputeDelayGteSettlementTime_Reverts() public {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.disputeDelay = uint24(op.settlementTime); // >= → revert
        vm.expectRevert();
        _bareCall(address(sellToken), SELL_AMT, MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            op, _defaultFulfillFee());
    }

    function testSwap_EscalationHaltLtInitialLiquidity_Reverts() public {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.escalationHalt = op.initialLiquidity - 1;
        vm.expectRevert();
        _bareCall(address(sellToken), SELL_AMT, MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            op, _defaultFulfillFee());
    }

    function testSwap_SettlementTimeTooLong_Reverts() public {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.settlementTime = 4 * 60 * 60 + 1; // > 4 hours
        op.maxGameTime = uint24(op.settlementTime) * 20;
        vm.expectRevert();
        _bareCall(address(sellToken), SELL_AMT, MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            op, _defaultFulfillFee());
    }

    function testSwap_ProtocolFeeTooHigh_Reverts() public {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.protocolFee = uint24(1e7);
        vm.expectRevert();
        _bareCall(address(sellToken), SELL_AMT, MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            op, _defaultFulfillFee());
    }

    // ── matchSwap validation ────────────────────────────────────────────

    function testMatchSwap_ParamHashMismatch_Reverts() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        // Tamper one field
        m.protocolFee = m.protocolFee + 1;
        vm.prank(matcher);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }

    function testMatchSwap_Expired_Reverts() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        vm.warp(uint256(expiration) + 1);
        vm.roll(block.number + 1);
        vm.prank(matcher);
        vm.expectRevert(Errors.Expired.selector);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }

    function testMatchSwap_AlreadyMatched_Reverts() public {
        (uint256 swapId, uint48 expiration) = _propose();
        _match(swapId, 2000e18, expiration);
        // Try to re-match using pre-match struct; hash check fails
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        vm.prank(matcher);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }

    function testMatchSwap_Cancelled_Reverts() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);
        // Pre-cancel struct now hash-mismatches
        vm.prank(matcher);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }

    function testMatchSwap_NonexistentSwap_Reverts() public {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(999, uint48(block.timestamp + 1 hours));
        vm.prank(matcher);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.matchSwap(999, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }
}
