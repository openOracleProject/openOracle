// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapFulfillFeeParamsTest
 * @notice Tests for dynamic fulfillment fee mechanism (FulfillFeeParams)
 *
 * FulfillFeeParams:
 *   - startFulfillFeeIncrease: set to block.timestamp on swap creation
 *   - maxFee: max fee that can be charged (1000 = 0.01%)
 *   - startingFee: initial fee when swap is created
 *   - roundLength: duration of each round in seconds
 *   - growthRate: multiplier per round (15000 = 1.5x)
 *   - maxRounds: maximum number of fee increase rounds
 *
 * calcFee logic:
 *   - timeDelta = (block.timestamp - startFulfillFeeIncrease) / roundLength
 *   - timeDelta capped at maxRounds
 *   - currentFee = startingFee * (growthRate/10000)^timeDelta
 *   - capped at maxFee
 */
contract OpenSwapFulfillFeeParamsTest is Test {
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
    uint96 constant SETTLER_REWARD = 0.001 ether;
    uint128 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant PROTOCOL_FEE = 1000;
    uint24 constant MAX_GAME_TIME = 7200;

    // Swap params
    uint128 constant SELL_AMT = 10e18;
    uint128 constant MIN_OUT = 1e18;
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint96 constant GAS_COMPENSATION = 0.001 ether;

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

    function _getOracleParams() internal pure returns (openSwapV2Permit.OracleParams memory) {
        return openSwapV2Permit.OracleParams({
            settlerReward: SETTLER_REWARD,
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
    }

    function _getSlippageParams() internal pure returns (openSwapV2Permit.SlippageParams memory) {
        return openSwapV2Permit.SlippageParams({
            priceTolerated: 5e14,
            toleranceRange: 1e7 - 1
        });
    }


    function _createSwapWithFeeParams(openSwapV2Permit.FulfillFeeParams memory feeParams) internal returns (uint256 swapId) {
        vm.startPrank(swapper);

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            feeParams,
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );

        vm.stopPrank();
    }

    function _matchSwap(uint256 swapId) internal {
        _matchSwap(swapId, 2000e18);
    }

    function _matchSwap(uint256 swapId, uint256 amount2) internal {
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(amount2), swapHash);
        vm.stopPrank();
    }

    // ============ FulfillFeeParams Validation Tests ============

    function testFulfillFeeParams_MaxFeeZero_Reverts() public {
        openSwapV2Permit.FulfillFeeParams memory badParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 0,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams, openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_StartingFeeZero_Reverts() public {
        openSwapV2Permit.FulfillFeeParams memory badParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000,
            startingFee: 0,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams, openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_GrowthRateZero_Reverts() public {
        openSwapV2Permit.FulfillFeeParams memory badParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 0,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams, openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_MaxRoundsZero_Reverts() public {
        openSwapV2Permit.FulfillFeeParams memory badParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 0
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams, openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_RoundLengthZero_Reverts() public {
        openSwapV2Permit.FulfillFeeParams memory badParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000,
            startingFee: 10000,
            roundLength: 0,
            growthRate: 15000,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams, openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_MaxFeeLessThanStartingFee_Reverts() public {
        openSwapV2Permit.FulfillFeeParams memory badParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 5000,
            startingFee: 10000, // startingFee > maxFee
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams, openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_MaxFeeAbove1e7_Reverts() public {
        openSwapV2Permit.FulfillFeeParams memory badParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: uint24(1e7 + 1),
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "fulfillmentFee"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams, openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    // ============ Fee Calculation Tests ============

    function testFulfillFee_ImmediateMatch_UsesStartingFee() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000, // 0.1%
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Match immediately (same block)
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.fulfillmentFee, 10000, "Fee should be starting fee when matched immediately");
    }

    function testFulfillFee_AfterOneRound_Increases() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000, // 0.1%
            roundLength: 60,
            growthRate: 15000, // 1.5x per round
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait one round
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 30);

        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        // Fee should be 10000 * 1.5 = 15000
        assertEq(s.fulfillmentFee, 15000, "Fee should increase after one round");
    }

    function testFulfillFee_AfterTwoRounds_IncreasesExponentially() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000, // 1.5x per round
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait two rounds
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 60);

        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        // Fee should be 10000 * 1.5 * 1.5 = 22500
        assertEq(s.fulfillmentFee, 22500, "Fee should increase exponentially");
    }

    function testFulfillFee_CappedAtMaxFee() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 20000, // Cap at 20000
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000, // 1.5x per round
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait many rounds (would be 10000 * 1.5^5 = 75937 without cap)
        vm.warp(block.timestamp + 300);
        vm.roll(block.number + 150);

        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.fulfillmentFee, 20000, "Fee should be capped at maxFee");
    }

    function testFulfillFee_CappedAtMaxRounds() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 1000000, // Very high cap
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000, // 1.5x per round
            maxRounds: 3 // Only 3 rounds allowed
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait 10 rounds (but maxRounds = 3)
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 300);

        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        // Fee should be 10000 * 1.5^3 = 33750 (capped at 3 rounds, not 10)
        assertEq(s.fulfillmentFee, 33750, "Fee should be capped at maxRounds worth of growth");
    }

    function testFulfillFee_PartialRoundNotCounted() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait less than one round
        vm.warp(block.timestamp + 59);
        vm.roll(block.number + 29);

        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.fulfillmentFee, 10000, "Fee should not increase for partial round");
    }

    // ============ getCurrentFulfillmentFee Tests ============

    function testGetCurrentFulfillmentFee_BeforeMatch() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        uint256 fee = swapContract.getCurrentFulfillmentFee(swapId);
        assertEq(fee, 10000, "Should return starting fee right after creation");
    }

    function testGetCurrentFulfillmentFee_IncreasesOverTime() public {
        // Set a known starting timestamp
        uint256 startTime = 1000;
        vm.warp(startTime);
        vm.roll(block.number + 500);

        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Check at different times using absolute timestamps
        assertEq(swapContract.getCurrentFulfillmentFee(swapId), 10000, "Fee at t=0");

        vm.warp(startTime + 60);
        vm.roll(block.number + 30);
        assertEq(swapContract.getCurrentFulfillmentFee(swapId), 15000, "Fee at t=60");

        vm.warp(startTime + 120);
        vm.roll(block.number + 30);
        assertEq(swapContract.getCurrentFulfillmentFee(swapId), 22500, "Fee at t=120");
    }

    function testGetCurrentFulfillmentFee_ReturnsZeroIfMatched() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);
        _matchSwap(swapId);

        uint256 fee = swapContract.getCurrentFulfillmentFee(swapId);
        assertEq(fee, 0, "Should return 0 after match");
    }

    // ============ getFulfillmentFeeParams Tests ============

    function testGetFulfillmentFeeParams_ReturnsCorrectParams() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 50000,
            startingFee: 5000,
            roundLength: 120,
            growthRate: 20000,
            maxRounds: 5
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        openSwapV2Permit.FulfillFeeParams memory retrieved = swapContract.getFulfillmentFeeParams(swapId);

        // startFulfillFeeIncrease is set by contract to block.timestamp
        assertEq(retrieved.maxFee, 50000, "maxFee should match");
        assertEq(retrieved.startingFee, 5000, "startingFee should match");
        assertEq(retrieved.roundLength, 120, "roundLength should match");
        assertEq(retrieved.growthRate, 20000, "growthRate should match");
        assertEq(retrieved.maxRounds, 5, "maxRounds should match");
    }

    function testGetFulfillmentFeeParams_StartTimestampSetCorrectly() public {
        uint256 startTime = block.timestamp;

        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 50000,
            startingFee: 5000,
            roundLength: 120,
            growthRate: 20000,
            maxRounds: 5
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        openSwapV2Permit.FulfillFeeParams memory retrieved = swapContract.getFulfillmentFeeParams(swapId);

        assertEq(retrieved.startFulfillFeeIncrease, startTime, "startFulfillFeeIncrease should be block.timestamp at creation");
    }

    // ============ Fee Applied to Fulfill Amount Tests ============

    function testFulfillFee_AppliedCorrectlyOnSettle() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000, // 0.1%
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        uint256 swapId = _createSwapWithFeeParams(feeParams);
        _matchSwap(swapId);

        // Submit report and settle
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        (bytes32 stateHash,,,,,,) = oracle.extraData(s.reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(s.reportId);

        // Calculate expected fulfillAmt
        // fulfillAmt = (10e18 * 2000e18) / 1e18 = 20000e18
        // fee = 10000 / 1e7 = 0.001 (0.1%)
        // fulfillAmt after fee = 20000e18 - 20e18 = 19980e18
        uint256 expectedFulfill = 20000e18 - (20000e18 * 10000 / 1e7);

        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + expectedFulfill, "Swapper should receive fulfillAmt minus fee");
    }

    function testFulfillFee_HigherFeeReducesFulfillAmount() public {
        // Create two swaps with different fees
        openSwapV2Permit.FulfillFeeParams memory lowFeeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000, // 0.1%
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 1
        });

        openSwapV2Permit.FulfillFeeParams memory highFeeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000, // 1%
            startingFee: 100000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 1
        });

        uint256 swapId1 = _createSwapWithFeeParams(lowFeeParams);
        uint256 swapId2 = _createSwapWithFeeParams(highFeeParams);

        _matchSwap(swapId1);
        _matchSwap(swapId2);

        openSwapV2Permit.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwapV2Permit.Swap memory s2 = swapContract.getSwap(swapId2);

        assertEq(s1.fulfillmentFee, 10000, "Swap 1 should have low fee");
        assertEq(s2.fulfillmentFee, 100000, "Swap 2 should have high fee");

        // Higher fee means less output for swapper
        // With 0.1% fee: swapper gets 99.9% of fulfillAmt
        // With 1% fee: swapper gets 99% of fulfillAmt
    }

    // ============ Fee Locked at Match Time ============

    function testFulfillFee_LockedAtMatchTime() public {
        openSwapV2Permit.FulfillFeeParams memory feeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait one round
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 30);
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 lockedFee = s.fulfillmentFee;
        assertEq(lockedFee, 15000, "Fee should be locked at 15000");

        // Wait more time - fee in struct should NOT change
        vm.warp(block.timestamp + 300);
        vm.roll(block.number + 150);

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertEq(sAfter.fulfillmentFee, lockedFee, "Fee should remain locked after match");
    }
}
