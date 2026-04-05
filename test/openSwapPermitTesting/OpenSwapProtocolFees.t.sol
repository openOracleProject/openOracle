// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../../src/oracleFeeReceiver.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapProtocolFeesTest
 * @notice Tests for protocol fee distribution mechanism
 *
 * New features:
 * - oracleFeeReceiver deployed per swap when protocolFee > 0
 * - grabOracleGameFees splits collected fees 50/50 between swapper/matcher
 * - grabOracleGameFeesAny allows anyone to trigger fee distribution
 */
contract OpenSwapProtocolFeesTest is Test {
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
    uint24 constant PROTOCOL_FEE = 1000; // 0.01%
    uint24 constant MAX_GAME_TIME = 7200;

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
        sellToken.approve(address(oracle), type(uint256).max);
        buyToken.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    function _createSwap() internal returns (uint256 swapId) {
        return _createSwapWithProtocolFee(PROTOCOL_FEE);
    }

    function _createSwapWithProtocolFee(uint24 protocolFee) internal returns (uint256 swapId) {
        vm.startPrank(swapper);

        openSwapV2Permit.OracleParams memory oracleParams = openSwapV2Permit.OracleParams({
            settlerReward: uint88(SETTLER_REWARD),
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            maxGameTime: MAX_GAME_TIME,
            blocksPerSecond: uint16(500),
            disputeDelay: DISPUTE_DELAY,
            protocolFee: protocolFee,
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
        return _preimageWithProtocolFee(PROTOCOL_FEE);
    }

    function _preimageWithProtocolFee(uint24 protocolFee) internal pure returns (openSwapV2Permit.MatcherPreimage memory) {
        return openSwapV2Permit.MatcherPreimage({
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            disputeDelay: DISPUTE_DELAY,
            protocolFee: protocolFee,
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

    function _matchSwapWithProtocolFee(uint256 swapId, uint24 protocolFee) internal {
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _preimageWithProtocolFee(protocolFee));
        vm.stopPrank();
    }

    function _settle(uint256 swapId) internal {
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(s.reportId);
    }

    // ============ FeeReceiver Deployment Tests ============

    function testProtocolFees_FeeReceiverDeployedWhenProtocolFeePositive() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory sBefore = swapContract.getSwap(swapId);
        assertEq(sBefore.feeRecipient, address(0), "feeRecipient should be zero before match");

        _matchSwap(swapId);

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.feeRecipient != address(0), "feeRecipient should be set after match");
    }

    function testProtocolFees_FeeReceiverNotDeployedWhenProtocolFeeZero() public {
        uint256 swapId = _createSwapWithProtocolFee(0);
        _matchSwapWithProtocolFee(swapId, 0);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.feeRecipient, address(0), "feeRecipient should be zero when protocolFee is 0");
    }

    function testProtocolFees_FeeReceiverHasCorrectOwner() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        assertEq(feeReceiver.owner(), address(swapContract), "FeeReceiver owner should be swapContract");
    }

    function testProtocolFees_FeeReceiverHasCorrectGameId() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        assertEq(feeReceiver.gameId(), swapId, "FeeReceiver gameId should match swapId");
    }

    function testProtocolFees_FeeReceiverHasCorrectOracle() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        assertEq(address(feeReceiver.oracle()), address(oracle), "FeeReceiver oracle should match");
    }

    function testProtocolFees_FeeReceiverHasCorrectTokens() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        assertEq(feeReceiver.token1(), address(sellToken), "FeeReceiver token1 should be sellToken");
        assertEq(feeReceiver.token2(), address(buyToken), "FeeReceiver token2 should be buyToken");
    }

    function testProtocolFees_EachSwapGetsUniqueFeeReceiver() public {
        uint256 swapId1 = _createSwap();
        _matchSwap(swapId1);

        uint256 swapId2 = _createSwap();
        _matchSwap(swapId2);

        openSwapV2Permit.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwapV2Permit.Swap memory s2 = swapContract.getSwap(swapId2);

        assertTrue(s1.feeRecipient != s2.feeRecipient, "Each swap should have unique feeRecipient");
    }

    // ============ FeeReceiver Access Control Tests ============

    function testProtocolFees_OnlyOwnerCanSweep() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        // Send some tokens to feeReceiver
        sellToken.transfer(address(feeReceiver), 1e18);

        // Random user cannot sweep
        vm.prank(randomUser);
        vm.expectRevert("not owner");
        feeReceiver.sweep(address(sellToken));

        // Swapper cannot sweep
        vm.prank(swapper);
        vm.expectRevert("not owner");
        feeReceiver.sweep(address(sellToken));

        // Matcher cannot sweep
        vm.prank(matcher);
        vm.expectRevert("not owner");
        feeReceiver.sweep(address(sellToken));
    }

    function testProtocolFees_AnyoneCanCallCollect() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        // Random user can call collect (no revert)
        vm.prank(randomUser);
        feeReceiver.collect();
    }

    // ============ grabOracleGameFeesAny Tests ============

    function testProtocolFees_GrabOracleGameFeesAny_RevertsIfZeroProtocolFee() public {
        uint256 swapId = _createSwapWithProtocolFee(0);
        _matchSwapWithProtocolFee(swapId, 0);

        // feeRecipient is address(0) when protocolFee is 0
        // Calling gameId() on address(0) will revert
        vm.prank(randomUser);
        vm.expectRevert();
        swapContract.grabOracleGameFeesAny(swapId);
    }

    function testProtocolFees_GrabOracleGameFeesAny_RevertsIfNotMatched() public {
        uint256 swapId = _createSwap();
        // Don't match

        // Calling gameId() on random address will revert
        vm.prank(randomUser);
        vm.expectRevert();
        swapContract.grabOracleGameFeesAny(swapId);
    }

    function testProtocolFees_GrabOracleGameFeesAny_AnyoneCanCall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);

        // Random user can call
        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);
    }

    // ============ Fee Distribution Tests ============

    function testProtocolFees_FeesDistributedOnSettle() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);

        // Verify feeRecipient is set
        assertTrue(s.feeRecipient != address(0), "feeRecipient should be set");

        // Record balances before settle
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherSellBefore = sellToken.balanceOf(matcher);

        // Settle
        _settle(swapId);

        // After settle, grabOracleGameFees should have been called
        // Any protocol fees collected should be split 50/50
        // (In this test, fees may be zero if oracle hasn't accumulated any)
        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished");
    }

    function testProtocolFees_FiftyFiftySplit() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        // Manually send tokens to feeReceiver to simulate collected fees
        uint256 feeAmount = 100e18;
        sellToken.transfer(address(feeReceiver), feeAmount);

        uint256 swapperBefore = sellToken.balanceOf(swapper);
        uint256 matcherBefore = sellToken.balanceOf(matcher);

        // Trigger fee distribution
        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);

        uint256 swapperAfter = sellToken.balanceOf(swapper);
        uint256 matcherAfter = sellToken.balanceOf(matcher);

        // 50/50 split - swapper gets half, matcher gets the rest
        uint256 swapperPiece = feeAmount / 2;
        uint256 matcherPiece = feeAmount - swapperPiece;

        assertEq(swapperAfter - swapperBefore, swapperPiece, "Swapper should get 50%");
        assertEq(matcherAfter - matcherBefore, matcherPiece, "Matcher should get 50%");
    }

    function testProtocolFees_BothTokensSplit() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        // Send both tokens to feeReceiver
        uint256 sellFee = 100e18;
        uint256 buyFee = 200e18;
        sellToken.transfer(address(feeReceiver), sellFee);
        buyToken.transfer(address(feeReceiver), buyFee);

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherSellBefore = sellToken.balanceOf(matcher);
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        // Trigger fee distribution
        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);

        // Check sellToken distribution
        assertEq(sellToken.balanceOf(swapper) - swapperSellBefore, sellFee / 2, "Swapper gets 50% of sellToken fees");
        assertEq(sellToken.balanceOf(matcher) - matcherSellBefore, sellFee - sellFee / 2, "Matcher gets 50% of sellToken fees");

        // Check buyToken distribution
        assertEq(buyToken.balanceOf(swapper) - swapperBuyBefore, buyFee / 2, "Swapper gets 50% of buyToken fees");
        assertEq(buyToken.balanceOf(matcher) - matcherBuyBefore, buyFee - buyFee / 2, "Matcher gets 50% of buyToken fees");
    }

    function testProtocolFees_OddAmountRounding() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        // Odd amount - 101 wei
        uint256 oddFee = 101;
        sellToken.transfer(address(feeReceiver), oddFee);

        uint256 swapperBefore = sellToken.balanceOf(swapper);
        uint256 matcherBefore = sellToken.balanceOf(matcher);

        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);

        // swapperPiece = 101 / 2 = 50
        // matcherPiece = 101 - 50 = 51 (matcher gets the extra wei)
        assertEq(sellToken.balanceOf(swapper) - swapperBefore, 50, "Swapper gets floor(101/2) = 50");
        assertEq(sellToken.balanceOf(matcher) - matcherBefore, 51, "Matcher gets remainder = 51");
    }

    function testProtocolFees_ZeroFeesNoOp() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherSellBefore = sellToken.balanceOf(matcher);

        // No tokens sent to feeReceiver - should be no-op
        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper balance unchanged");
        assertEq(sellToken.balanceOf(matcher), matcherSellBefore, "Matcher balance unchanged");
    }

    function testProtocolFees_CanCallMultipleTimes() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);


        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        // First batch of fees
        sellToken.transfer(address(feeReceiver), 100e18);

        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);

        uint256 swapperAfterFirst = sellToken.balanceOf(swapper);

        // Second batch of fees
        sellToken.transfer(address(feeReceiver), 50e18);

        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);

        uint256 swapperAfterSecond = sellToken.balanceOf(swapper);

        // Should have received both batches
        assertEq(swapperAfterSecond - swapperAfterFirst, 25e18, "Should receive second batch");
    }
}
