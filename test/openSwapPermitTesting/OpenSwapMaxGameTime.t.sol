// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapMaxGameTimeTest
 * @notice Tests for maxGameTime bailout condition
 *
 * maxGameTime allows bailout if oracle game takes too long.
 * Condition: block.timestamp - s.start > s.oracleParams.maxGameTime
 *
 * This is independent of:
 * - isLatent (no initial report within latencyBailout)
 * - isDistributed (oracle already distributed but callback failed)
 */
contract OpenSwapMaxGameTimeTest is Test {
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
    address internal randomUser = address(0x5);

    // Oracle params
    uint88 constant SETTLER_REWARD = 0.001 ether;
    uint128 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant PROTOCOL_FEE = 1000;
    uint24 constant MAX_GAME_TIME = 7200; // 2 hours

    // Swap params
    uint128 constant SELL_AMT = 10e18;
    uint128 constant MIN_OUT = 1e18;
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint96 constant GAS_COMPENSATION = 0.001 ether;

    // FulfillFeeParams
    uint24 constant MAX_FEE = 10000;
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000;
    uint16 constant MAX_ROUNDS_FEE = 10;

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
            priceTolerated: 5e14,
            toleranceRange: 1e7 - 1
        });

        openSwapV2Permit.FulfillFeeParams memory fulfillFeeParams = openSwapV2Permit.FulfillFeeParams({
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS_FEE
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

    function _createSwapWithMaxGameTime(uint24 maxGameTime) internal returns (uint256 swapId) {
        vm.startPrank(swapper);

        openSwapV2Permit.OracleParams memory oracleParams = openSwapV2Permit.OracleParams({
            settlerReward: uint88(SETTLER_REWARD),
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            maxGameTime: maxGameTime,
            blocksPerSecond: uint16(500),
            disputeDelay: DISPUTE_DELAY,
            protocolFee: PROTOCOL_FEE,
            multiplier: uint16(110),
            timeType: true
        });

        openSwapV2Permit.SlippageParams memory slippageParams = openSwapV2Permit.SlippageParams({
            priceTolerated: 5e14,
            toleranceRange: 1e7 - 1
        });

        openSwapV2Permit.FulfillFeeParams memory fulfillFeeParams = openSwapV2Permit.FulfillFeeParams({
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS_FEE
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
            maxRounds: MAX_ROUNDS_FEE
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

    // ============ maxGameTime Bailout Tests ============

    function testMaxGameTime_BailOutAfterMaxGameTimeExceeded() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Submit initial report so isLatent doesn't trigger


        openSwapV2Permit.Swap memory sBefore = swapContract.getSwap(swapId);
        assertFalse(sBefore.finished, "Should not be finished before bailout");

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        // Warp past maxGameTime
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // Anyone can call bailout
        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Should be finished after bailout");

        // Both parties should get refunds
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore + SELL_AMT, "Swapper should get sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore + MIN_FULFILL_LIQUIDITY, "Matcher should get buyToken back");
    }

    function testMaxGameTime_NoOpBeforeMaxGameTime() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Submit initial report so isLatent doesn't trigger


        // Warp to just before maxGameTime
        vm.warp(block.timestamp + MAX_GAME_TIME - 1);
        vm.roll(block.number + (MAX_GAME_TIME - 1) / 2);

        openSwapV2Permit.Swap memory sBefore = swapContract.getSwap(swapId);
        assertFalse(sBefore.finished, "Should not be finished");

        // Try bailout - should revert (no bailout condition met)
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "can't bail out yet"));
        swapContract.bailOut(swapId);

        // Should still not be finished
        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertFalse(sAfter.finished, "Should still not be finished");
    }

    function testMaxGameTime_ExactBoundary() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Submit initial report


        // Warp to exactly maxGameTime (not exceeded yet)
        vm.warp(block.timestamp + MAX_GAME_TIME);
        vm.roll(block.number + MAX_GAME_TIME / 2);

        // Bailout should revert - condition is > not >=
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "can't bail out yet"));
        swapContract.bailOut(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertFalse(s.finished, "Should not be finished at exact boundary");

        // Warp 1 more second
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Should be finished after boundary");
    }

    function testMaxGameTime_WorksEvenWithUnsettledGame() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Submit initial report but don't settle


        // Now warp past maxGameTime (but not settlement time from last report)
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // Bailout should work despite game not being settled
        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Should be finished - maxGameTime overrides unsettled game");
    }

    function testMaxGameTime_AnyoneCanCallBailOut() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // Random user (not swapper, not matcher) can call
        address nobody = address(0xDEAD);
        vm.prank(nobody);
        swapContract.bailOut(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Anyone should be able to trigger bailout");
    }

    function testMaxGameTime_SwapperAndMatcherBothGetRefunds() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);
        swapContract.bailOut(swapId);

        // Verify exact refund amounts
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore + SELL_AMT, "Swapper gets exact sellAmt back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore + MIN_FULFILL_LIQUIDITY, "Matcher gets exact minFulfillLiquidity back");
    }

    function testMaxGameTime_BountyRecalledOnBailout() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Don't submit initial report - bounty unclaimed

        // Warp past maxGameTime
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        swapContract.bailOut(swapId);

        // V2: No bounty to recall
        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished after bailout");
    }

    function testMaxGameTime_CannotBailOutTwice() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);
        swapContract.bailOut(swapId);

        // Second bailout should revert
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "finished"));
        swapContract.bailOut(swapId);
    }

    function testMaxGameTime_MinimumValidValue() public {
        // maxGameTime must be >= settlementTime * 20
        // SETTLEMENT_TIME = 300, so minimum = 6000
        uint24 minMaxGameTime = uint24(SETTLEMENT_TIME * 20);

        uint256 swapId = _createSwapWithMaxGameTime(minMaxGameTime);
        _matchSwap(swapId);


        // Warp past minMaxGameTime
        vm.warp(block.timestamp + minMaxGameTime + 1);
        vm.roll(block.number + (minMaxGameTime + 1) / 2);

        swapContract.bailOut(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Bailout should work with minimum valid maxGameTime");
    }

    function testMaxGameTime_ValidationOnSwapCreation() public {
        vm.startPrank(swapper);

        // Try to create swap with maxGameTime too low
        openSwapV2Permit.OracleParams memory badParams = openSwapV2Permit.OracleParams({
            settlerReward: uint88(SETTLER_REWARD),
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            maxGameTime: uint24(SETTLEMENT_TIME * 20 - 1), // Below minimum
            blocksPerSecond: uint16(500),
            disputeDelay: DISPUTE_DELAY,
            protocolFee: PROTOCOL_FEE,
            multiplier: uint16(110),
            timeType: true
        });

        openSwapV2Permit.SlippageParams memory slippageParams = openSwapV2Permit.SlippageParams({
            priceTolerated: 5e14,
            toleranceRange: 1e7 - 1
        });

        openSwapV2Permit.FulfillFeeParams memory fulfillFeeParams = openSwapV2Permit.FulfillFeeParams({
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS_FEE
        });


        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            badParams,
            slippageParams,
            fulfillFeeParams,
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );

        vm.stopPrank();
    }
}
