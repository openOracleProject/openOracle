// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapSlippageTest
 * @notice Thorough tests for slippage protection mechanism
 *
 * toleranceCheck logic:
 *   if (priceTolerated == 0 || toleranceRange == 0) return true;  // bypassed
 *   maxDiff = (priceTolerated * toleranceRange) / 1e7;
 *   return abs(price - priceTolerated) <= maxDiff;
 *
 * If slippage check fails -> refund both parties
 */
contract OpenSwapSlippageTest is Test {
    OpenOracle internal oracle;
    openSwapV2Permit internal swapContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address constant OP = 0x4200000000000000000000000000000000000042;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal initialReporter = address(0x3);
    address internal settler = address(0x4);

    // Oracle params
    uint88 constant SETTLER_REWARD = 0.001 ether;
    uint128 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant PROTOCOL_FEE = 1000;
    uint24 constant MAX_GAME_TIME = 7200;

    // Swap params
    uint128 constant SELL_AMT = 10e18;
    uint128 constant MIN_OUT = 1e18; // Low minOut to not interfere with slippage tests
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint96 constant GAS_COMPENSATION = 0.001 ether;

    // FulfillFeeParams
    uint24 constant MAX_FEE = 10000;
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000;
    uint16 constant MAX_ROUNDS = 10;

    function setUp() public {
        vm.etch(OP, address(new MockERC20("Optimism", "OP")).code);
        vm.etch(WETH, address(new MockERC20("Wrapped Ether", "WETH")).code);
        vm.etch(USDC, address(new MockERC20("USD Coin", "USDC")).code);

        oracle = new OpenOracle();
        swapContract = new openSwapV2Permit(address(oracle));


        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new MockERC20("BuyToken", "BUY");

        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(matcher, 100e18);
        sellToken.transfer(initialReporter, 100e18);
        buyToken.transfer(matcher, 100_000e18);
        buyToken.transfer(initialReporter, 100_000e18);

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(initialReporter, 10 ether);
        vm.deal(settler, 1 ether);

        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.startPrank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);
        sellToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(initialReporter);
        vm.stopPrank();
    }

    function _createSwapWithSlippage(uint256 priceTolerated, uint24 toleranceRange) internal returns (uint256 swapId) {
        vm.startPrank(swapper);

        openSwapV2Permit.OracleParams memory oracleParams = openSwapV2Permit.OracleParams({
            settlerReward: uint88(SETTLER_REWARD),
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            maxGameTime: MAX_GAME_TIME,
            blocksPerSecond: uint16(500),
            disputeDelay: DISPUTE_DELAY,
            protocolFee: PROTOCOL_FEE,
            multiplier: uint16(110),
            timeType: true
        });

        openSwapV2Permit.SlippageParams memory slippageParams = openSwapV2Permit.SlippageParams({
            priceTolerated: uint232(priceTolerated),
            toleranceRange: toleranceRange
        });

        openSwapV2Permit.FulfillFeeParams memory fulfillFeeParams = openSwapV2Permit.FulfillFeeParams({
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });


        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            oracleParams,
            slippageParams,
            fulfillFeeParams,
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );

        vm.stopPrank();
    }

    function _defaultPreimage() internal pure returns (openSwapV2Permit.MatcherPreimage memory) {
        return openSwapV2Permit.MatcherPreimage({
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            disputeDelay: DISPUTE_DELAY,
            protocolFee: PROTOCOL_FEE,
            multiplier: uint16(110),
            timeType: true,
            startFulfillFeeIncrease: uint48(1),
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
    }

    function _matchSwap(uint256 swapId) internal {
        _matchSwap(swapId, 2000e18);
    }

    function _matchSwap(uint256 swapId, uint256 amount2) internal {
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(amount2), swapHash, _defaultPreimage());
        vm.stopPrank();
    }

    function _settle(uint256 swapId) internal {
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId);
    }

    // ============ Slippage Validation Tests ============

    function testSlippage_RevertWhenPriceToleratedZero() public {
        // priceTolerated = 0 now reverts
        vm.expectRevert();
        _createSwapWithSlippage(0, 100000);
    }

    function testSlippage_RevertWhenToleranceRangeZero() public {
        // toleranceRange = 0 now reverts
        vm.expectRevert();
        _createSwapWithSlippage(5e14, 0);
    }

    function testSlippage_RevertWhenBothZero() public {
        vm.expectRevert();
        _createSwapWithSlippage(0, 0);
    }

    function testSlippage_RevertWhenToleranceRangeTooHigh() public {
        // toleranceRange > 1e7 reverts
        vm.expectRevert();
        _createSwapWithSlippage(5e14, uint24(1e7 + 1));
    }

    // ============ Slippage Pass Tests ============
    // NOTE: Oracle price = (amount1 * 1e18) / amount2
    // So with amount1=1e18, amount2=2000e18: price = 5e14 (not 2000e18!)

    function testSlippage_PassExactPrice() public {
        // With amount1=1e18, amount2=2000e18: oracle price = 5e14
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 100000; // 1%

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId);

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");
        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    function testSlippage_PassPriceWithinRange() public {
        // priceTolerated = 5e14, 1% tolerance = maxDiff of 5e12
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 100000; // 1%

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId, 1990e18);

        // Report amount2=1990e18 -> price = 1e18*1e18/1990e18 ≈ 5.025e14 (within 1%)
        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");
        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    // ============ Slippage Fail Tests (Refund) ============

    function testSlippage_FailPriceOutsideRange() public {
        // priceTolerated = 5e14, 1% tolerance
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 100000; // 1%

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId, 1800e18);

        // Report amount2=1800e18 -> price = 1e18*1e18/1800e18 ≈ 5.55e14 (>10% off)
        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Both parties should be refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }

    function testSlippage_FailWildlyDifferentPrice() public {
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 100000; // 1%

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId, 500e18);

        // Report amount2=500e18 -> price = 2e15 (way off from 5e14)
        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }

    // ============ Tolerance Range Tests ============

    function testSlippage_TightTolerance_Pass() public {
        // 0.1% tolerance
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 10000; // 0.1%

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId, 1999e18);

        // Report amount2=1999e18 -> price ≈ 5.0025e14 (within 0.1%)
        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");
        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    function testSlippage_TightTolerance_Fail() public {
        // 0.1% tolerance
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 10000; // 0.1%

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId, 1980e18);

        // Report amount2=1980e18 -> price ≈ 5.05e14 (~1% off, outside 0.1%)
        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }

    function testSlippage_WideTolerance_Pass() public {
        // 10% tolerance
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 1000000; // 10%

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId, 1850e18);

        // Report amount2=1850e18 -> price ≈ 5.4e14 (within 10%)
        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");
        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    function testSlippage_WideTolerance_Fail() public {
        // 10% tolerance
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 1000000; // 10%

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId, 1500e18);

        // Report amount2=1500e18 -> price ≈ 6.67e14 (~33% off, outside 10%)
        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }
}
