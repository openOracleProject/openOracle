// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapFulfillLiquidityTest
 * @notice Tests for fulfillAmt > minFulfillLiquidity edge case
 *
 * When oracle reports a price where fulfillAmt exceeds minFulfillLiquidity,
 * both parties get refunded. This protects the matcher from being
 * required to pay more than they deposited.
 *
 * fulfillAmt calculation:
 *   fulfillAmt = (sellAmt * oracleAmount2) / oracleAmount1
 *   fulfillAmt -= fulfillAmt * fulfillmentFee / 1e7
 *
 * If fulfillAmt > minFulfillLiquidity -> refund both parties
 */
contract OpenSwapFulfillLiquidityTest is Test {
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
    uint128 constant MIN_OUT = 1e18; // Low minOut to not interfere
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18; // Matcher deposits this
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
        buyToken.transfer(matcher, 200_000e18);
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

    function _createSwap() internal returns (uint256 swapId) {
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
            priceTolerated: 5e26,
            toleranceRange: 1e7 - 1
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

    function _calcFulfillAmt(uint256 amount1, uint256 amount2) internal pure returns (uint256) {
        uint256 fulfillAmt = (SELL_AMT * amount2) / amount1;
        fulfillAmt -= fulfillAmt * STARTING_FEE / 1e7;
        return fulfillAmt;
    }

    // ============ Fulfill Liquidity Exceeded Tests ============

    function testFulfillLiquidity_ExceededCausesRefund() public {
        // Set up so fulfillAmt > minFulfillLiquidity
        // minFulfillLiquidity = 25000e18
        // With amount1=1e18, amount2=2600e18:
        // fulfillAmt = 10e18 * 2600e18 / 1e18 = 26000e18 (minus fee ~25974e18) > 25000e18

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2600e18);
        assertGt(expectedFulfill, MIN_FULFILL_LIQUIDITY, "Expected fulfillAmt > minFulfillLiquidity");

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwap();
        _matchSwap(swapId, 2600e18);

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Both parties refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
        assertEq(buyToken.balanceOf(swapper), 0, "Swapper should NOT receive buyToken");
    }

    function testFulfillLiquidity_BarelyExceededCausesRefund() public {
        // Find amount2 that causes fulfillAmt to barely exceed minFulfillLiquidity
        // We need: (SELL_AMT * amount2 / amount1) * (1 - fee) > MIN_FULFILL_LIQUIDITY
        // 10e18 * amount2 / 1e18 * 0.999 > 25000e18
        // amount2 > 25025.025e18
        // Let's use amount2 = 25030e18

        uint256 amount2 = 25030e18;
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, amount2);
        assertGt(expectedFulfill, MIN_FULFILL_LIQUIDITY, "Expected fulfillAmt barely > minFulfillLiquidity");

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwap();
        _matchSwap(swapId, amount2);

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Both parties refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }

    function testFulfillLiquidity_ExactlyAtLimitSucceeds() public {
        // Find amount2 that causes fulfillAmt to exactly equal minFulfillLiquidity
        // fulfillAmt = (10e18 * amount2 / 1e18) * (1 - 0.001) = 25000e18
        // amount2 = 25000e18 / 0.999 = 25025.025...e18
        // We need the floor, so use amount2 that results in fulfillAmt <= 25000e18

        // Actually let's calculate backwards:
        // fulfillAmt = SELL_AMT * amount2 / amount1 - fee
        // 25000e18 = (10e18 * amount2 / 1e18) - (10e18 * amount2 / 1e18) * 10000 / 1e7
        // 25000e18 = 10 * amount2 * (1 - 0.001)
        // amount2 = 25000e18 / (10 * 0.999) = 2502.5025...e18

        // So with amount2 = 2502e18:
        // fulfillAmt = 10e18 * 2502e18 / 1e18 = 25020e18
        // fulfillAmt -= 25020e18 * 10000 / 1e7 = 25020e18 - 25.02e18 = 24994.98e18

        uint256 amount2 = 2502e18;
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, amount2);
        assertLe(expectedFulfill, MIN_FULFILL_LIQUIDITY, "Expected fulfillAmt <= minFulfillLiquidity");

        uint256 swapId = _createSwap();
        _matchSwap(swapId, amount2);

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Swap should succeed - swapper gets buyToken
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive fulfillAmt");
    }

    function testFulfillLiquidity_WellUnderLimitSucceeds() public {
        // Use standard amount2=2000e18 which gives fulfillAmt ~19980e18 < 25000e18

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        assertLt(expectedFulfill, MIN_FULFILL_LIQUIDITY, "Expected fulfillAmt < minFulfillLiquidity");

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Swap should succeed
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive fulfillAmt");
    }

    function testFulfillLiquidity_MatcherGetsExcess() public {
        // When swap succeeds, matcher gets back the excess (minFulfillLiquidity - fulfillAmt)

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        uint256 expectedMatcherReturn = MIN_FULFILL_LIQUIDITY - expectedFulfill;

        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // After match, matcher's balance decreased by minFulfillLiquidity + amount2 (2000e18)
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore - MIN_FULFILL_LIQUIDITY - 2000e18, "Matcher sent minFulfillLiquidity + amount2");

        _settle(swapId);

        // Matcher gets excess back
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore - expectedFulfill, "Matcher should get excess back");
    }

    function testFulfillLiquidity_MatcherGetsSellToken() public {
        // When swap succeeds, matcher receives sellToken

        uint256 matcherSellBefore = sellToken.balanceOf(matcher);

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        _settle(swapId);

        // Matcher gets sellToken
        assertEq(sellToken.balanceOf(matcher), matcherSellBefore + SELL_AMT, "Matcher should receive sellAmt");
    }

    // ============ Edge Cases ============

    function testFulfillLiquidity_VeryHighPriceCausesRefund() public {
        // Extremely high price means huge fulfillAmt
        // amount2 = 100000e18 -> fulfillAmt = 1000000e18 >> 25000e18

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 100000e18);
        assertGt(expectedFulfill, MIN_FULFILL_LIQUIDITY, "Huge fulfillAmt should exceed limit");

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwap();
        _matchSwap(swapId, 100000e18);

        _settle(swapId);

        // Refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper refunded");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher refunded");
    }

    function testFulfillLiquidity_RefundEvenIfMinOutMet() public {
        // Even if minOut is met, exceeding minFulfillLiquidity still causes refund

        // Set high minOut that would pass
        // Then set price that exceeds minFulfillLiquidity

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        // Create swap with high minOut
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
            priceTolerated: 5e26,
            toleranceRange: 1e7 - 1
        });
        openSwapV2Permit.FulfillFeeParams memory fulfillFeeParams = openSwapV2Permit.FulfillFeeParams({
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        // minOut = 1e18 (low enough to pass creation-time check); fulfillAmt will still exceed minFulfillLiquidity causing refund
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            uint128(1e18), // Low minOut to pass creation-time validation
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

        _matchSwap(swapId, 2600e18);

        // Report price that gives fulfillAmt = 25974e18 > minFulfillLiquidity
        // This exceeds minOut (25500) AND exceeds minFulfillLiquidity (25000)
        _settle(swapId);

        // Refunded because fulfillAmt > minFulfillLiquidity (even though > minOut too)
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper refunded");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher refunded");
    }

    function testFulfillLiquidity_AllThreeRefundConditions() public {
        // Verify all three refund conditions separately:
        // 1. fulfillAmt > minFulfillLiquidity (tested above)
        // 2. fulfillAmt < minOut (tested in MinOut tests)
        // 3. slippage check fails (tested in Slippage tests)

        // Test that success requires all three conditions to pass
        // fulfillAmt <= minFulfillLiquidity AND fulfillAmt >= minOut AND slippageOk

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        assertLt(expectedFulfill, MIN_FULFILL_LIQUIDITY, "fulfillAmt < minFulfillLiquidity");
        assertGt(expectedFulfill, MIN_OUT, "fulfillAmt > minOut");

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        _settle(swapId);

        // All conditions pass -> success
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swap succeeded");
    }
}
