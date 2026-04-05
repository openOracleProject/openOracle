// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

contract OpenSwapHappyPathTest is Test {
    OpenOracle internal oracle;
    openSwapV2Permit internal swapContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    // Optimism mainnet addresses (will be mocked)
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
    uint24 constant PROTOCOL_FEE = 1000; // 0.01%
    uint24 constant MAX_GAME_TIME = 7200;

    // Swap params
    uint128 constant SELL_AMT = 10e18;
    uint128 constant MIN_OUT = 1e18;
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint96 constant GAS_COMPENSATION = 0.001 ether;

    // FulfillFeeParams
    uint24 constant MAX_FEE = 10000; // 0.1%
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000; // 1.5x
    uint16 constant MAX_ROUNDS = 10;

    function setUp() public {
        // Mock OP, WETH, USDC at their mainnet addresses
        MockERC20 mockOP = new MockERC20("Optimism", "OP");
        MockERC20 mockWETH = new MockERC20("Wrapped Ether", "WETH");
        MockERC20 mockUSDC = new MockERC20("USD Coin", "USDC");
        vm.etch(OP, address(mockOP).code);
        vm.etch(WETH, address(mockWETH).code);
        vm.etch(USDC, address(mockUSDC).code);

        // Deploy contracts
        oracle = new OpenOracle();

        // Deploy grant faucet

        // Deploy openSwap with grant faucet
        swapContract = new openSwapV2Permit(address(oracle));

        // Link openSwap to grant faucet

        // Fund grant faucet with OP tokens for rebates

        // Deploy tokens
        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new MockERC20("BuyToken", "BUY");

        // Fund accounts
        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(matcher, 100e18);
        sellToken.transfer(initialReporter, 100e18);
        buyToken.transfer(matcher, 100_000e18);
        buyToken.transfer(initialReporter, 100_000e18);

        // Give ETH
        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(initialReporter, 10 ether);
        vm.deal(settler, 1 ether);

        // Approvals for swapper
        vm.startPrank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        // Approvals for matcher
        vm.startPrank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);
        sellToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();
        vm.stopPrank();

        // Approvals for initial reporter (needs to approve bounty contract)
        vm.startPrank(initialReporter);
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

    function testHappyPath() public {
        // Track initial balances
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        uint256 matcherSellBefore = sellToken.balanceOf(matcher);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 reporterSellBefore = sellToken.balanceOf(initialReporter);
        uint256 reporterBuyBefore = buyToken.balanceOf(initialReporter);
        uint256 reporterEthBefore = initialReporter.balance;

        uint256 settlerEthBefore = settler.balance;

        // ============ STEP 1: Swapper creates swap ============
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
            priceTolerated: 5e14, // price = amount1 * 1e18 / amount2 = 1e18 / 2000 = 5e14
            toleranceRange: 1e7 - 1 // max tolerance to effectively bypass slippage
        });

        openSwapV2Permit.FulfillFeeParams memory fulfillFeeParams = openSwapV2Permit.FulfillFeeParams({
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });


        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        uint256 swapId = swapContract.swap{value: ethToSend}(
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

        // Verify swapper's sellToken transferred
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper should have sent sellToken");
        assertEq(sellToken.balanceOf(address(swapContract)), SELL_AMT, "SwapContract should hold sellToken");

        // ============ STEP 2: Matcher matches swap ============
        vm.startPrank(matcher);

        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());

        vm.stopPrank();

        // Verify matcher's buyToken transferred
        // matchSwap pulls minFulfillLiquidity + amount2 from matcher (25000e18 + 2000e18 = 27000e18)
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore - (MIN_FULFILL_LIQUIDITY + 2000e18), "Matcher should have sent buyToken");
        assertEq(buyToken.balanceOf(address(swapContract)), MIN_FULFILL_LIQUIDITY, "SwapContract should hold buyToken");

        // Get the reportId created by the oracle game
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;
        assertEq(reportId, 1, "ReportId should be 1 (first report)");

        // V2: No separate initial report step — matcher did it in matchSwap

        // Verify oracle has initial report
        (uint128 rsCheckAmount1,,,,,,) = oracle.reportStatus(reportId);
        assertEq(rsCheckAmount1, INITIAL_LIQUIDITY, "Oracle should have initial report from matcher");

        // ============ STEP 3: Wait for settlement time and settle ============
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        vm.prank(settler);
        oracle.settle(reportId);

        // ============ STEP 5: Verify final balances ============

        // Settler should have received settler reward
        assertEq(settler.balance, settlerEthBefore + SETTLER_REWARD, "Settler should receive settler reward");

        // Swap should be finished
        openSwapV2Permit.Swap memory finalSwap = swapContract.getSwap(swapId);
        assertTrue(finalSwap.finished, "Swap should be finished");

        // Calculate expected fulfillAmt based on oracle price
        // fulfillAmt = (sellAmt * oracleAmount2) / oracleAmount1
        // fulfillAmt -= fulfillAmt * fulfillmentFee / 1e7
        (uint128 rsFinalAmount1, uint128 rsFinalAmount2,,,,,) = oracle.reportStatus(reportId);
        uint256 currentAmount1 = rsFinalAmount1;
        uint256 currentAmount2 = rsFinalAmount2;
        uint256 fulfillAmt = (SELL_AMT * currentAmount2) / currentAmount1;
        fulfillAmt -= fulfillAmt * MAX_FEE / 1e7;

        // Swapper should have received buyToken
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + fulfillAmt, "Swapper should receive buyToken");

        // Matcher should have received sellToken and leftover buyToken
        assertEq(sellToken.balanceOf(matcher), matcherSellBefore + SELL_AMT, "Matcher should receive sellToken");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore - fulfillAmt, "Matcher should have remaining buyToken");

        // Initial reporter should have their oracle tokens back (after settlement)
        assertEq(sellToken.balanceOf(initialReporter), reporterSellBefore, "Reporter should have sellToken back");
        assertEq(buyToken.balanceOf(initialReporter), reporterBuyBefore, "Reporter should have buyToken back");

        // SwapContract should have no tokens left
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "SwapContract should have no sellToken");
        assertEq(buyToken.balanceOf(address(swapContract)), 0, "SwapContract should have no buyToken");

        console.log("=== Happy Path Complete ===");
        console.log("Swapper received buyToken:", fulfillAmt);
        console.log("Matcher received sellToken:", SELL_AMT);
        console.log("Settler reward:", SETTLER_REWARD);
    }

}
