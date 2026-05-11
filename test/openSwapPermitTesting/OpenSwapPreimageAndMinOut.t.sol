// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

/**
 * @notice Tests specifically covering:
 *   1. oracleAndFeeParamHash preimage validation (negative tests for mismatched fields)
 *   2. Creation-time minOut validation (the "minOut inconsistent" revert path)
 *   3. Timestamp-aware preimage construction
 */
contract OpenSwapPreimageAndMinOutTest is Test {
    OpenOracle internal oracle;
    openSwapV2Permit internal swapContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address constant WETH = 0x4200000000000000000000000000000000000006;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);

    uint88 constant SETTLER_REWARD = 0.001 ether;
    uint128 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant PROTOCOL_FEE = 0;
    uint24 constant MAX_GAME_TIME = 7200;

    uint128 constant SELL_AMT = 10e18;
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint96 constant GAS_COMPENSATION = 0.001 ether;

    uint24 constant MAX_FEE = 10000;
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000;
    uint16 constant MAX_ROUNDS = 10;

    uint256 internal swapCreationTime;

    function setUp() public {
        vm.etch(WETH, address(new MockERC20("WETH", "WETH")).code);

        oracle = new OpenOracle();
        swapContract = new openSwapV2Permit(address(oracle));

        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new MockERC20("BuyToken", "BUY");

        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(matcher, 100e18);
        buyToken.transfer(matcher, 100_000e18);

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);

        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.startPrank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);
        sellToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();
    }

    function _oracleParams() internal pure returns (openSwapV2Permit.OracleParams memory) {
        return openSwapV2Permit.OracleParams({
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlerReward: SETTLER_REWARD,
            settlementTime: SETTLEMENT_TIME,
            maxGameTime: MAX_GAME_TIME,
            blocksPerSecond: uint16(500),
            disputeDelay: DISPUTE_DELAY,
            protocolFee: PROTOCOL_FEE,
            multiplier: uint16(110),
            timeType: true
        });
    }

    function _slippageParams() internal pure returns (openSwapV2Permit.SlippageParams memory) {
        return openSwapV2Permit.SlippageParams({ priceTolerated: 5e26, toleranceRange: 1e7 - 1 });
    }

    function _fulfillFeeParams() internal pure returns (openSwapV2Permit.FulfillFeeParams memory) {
        return openSwapV2Permit.FulfillFeeParams({
            maxFee: MAX_FEE, startingFee: STARTING_FEE, roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE, maxRounds: MAX_ROUNDS
        });
    }

    function _emptyPermit() internal pure returns (openSwapV2Permit.PermitParams memory) {
        return openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0));
    }

    function _preimageAt(uint48 timestamp) internal pure returns (openSwapV2Permit.MatcherPreimage memory) {
        return openSwapV2Permit.MatcherPreimage({
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            disputeDelay: DISPUTE_DELAY,
            protocolFee: PROTOCOL_FEE,
            multiplier: uint16(110),
            timeType: true,
            startFulfillFeeIncrease: timestamp,
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
    }

    function _createSwap() internal returns (uint256 swapId) {
        vm.startPrank(swapper);
        swapCreationTime = block.timestamp;
        swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), 1e18, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), _emptyPermit()
        );
        vm.stopPrank();
    }

    // ============ Preimage Validation: field mismatch tests ============

    function testPreimage_WrongInitialLiquidity_Reverts() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.MatcherPreimage memory bad = _preimageAt(uint48(swapCreationTime));
        bad.initialLiquidity = 2e18; // wrong

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "preimage params"));
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, bad);
        vm.stopPrank();
    }

    function testPreimage_WrongProtocolFee_Reverts() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.MatcherPreimage memory bad = _preimageAt(uint48(swapCreationTime));
        bad.protocolFee = 1000; // swap was created with 0

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "preimage params"));
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, bad);
        vm.stopPrank();
    }

    function testPreimage_WrongStartFulfillFeeIncrease_Reverts() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.MatcherPreimage memory bad = _preimageAt(uint48(swapCreationTime));
        bad.startFulfillFeeIncrease = uint48(swapCreationTime + 100); // wrong timestamp

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "preimage params"));
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, bad);
        vm.stopPrank();
    }

    function testPreimage_WrongMaxFee_Reverts() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.MatcherPreimage memory bad = _preimageAt(uint48(swapCreationTime));
        bad.maxFee = 5000; // wrong

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "preimage params"));
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, bad);
        vm.stopPrank();
    }

    function testPreimage_WrongMultiplier_Reverts() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.MatcherPreimage memory bad = _preimageAt(uint48(swapCreationTime));
        bad.multiplier = 120; // wrong, should be 110

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "preimage params"));
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, bad);
        vm.stopPrank();
    }

    function testPreimage_CorrectPreimage_Succeeds() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.MatcherPreimage memory good = _preimageAt(uint48(swapCreationTime));

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, good);
        vm.stopPrank();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.matched, "Swap should be matched with correct preimage");
    }

    // ============ Timestamp-aware preimage after vm.warp ============

    function testPreimage_AfterWarp_MustUseCreationTimestamp() public {
        // Create swap at time T
        uint256 swapId = _createSwap();
        uint48 creationTs = uint48(swapCreationTime);

        // Warp forward
        vm.warp(block.timestamp + 500);

        // Preimage with current (warped) timestamp should fail
        openSwapV2Permit.MatcherPreimage memory wrongTs = _preimageAt(uint48(block.timestamp));

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "preimage params"));
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, wrongTs);
        vm.stopPrank();

        // Preimage with original creation timestamp should succeed
        openSwapV2Permit.MatcherPreimage memory correctTs = _preimageAt(creationTs);

        vm.startPrank(matcher);
        swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, correctTs);
        vm.stopPrank();

        assertTrue(swapContract.getSwap(swapId).matched, "Should match with creation timestamp");
    }

    // ============ Creation-time minOut validation ============

    function testMinOutValidation_ExceedsWorstCase_Reverts() public {
        // With priceTolerated=5e14, toleranceRange=1e7-1, maxFee=10000:
        // upperPrice ≈ 1e15
        // worstFulfillAmt ≈ (10e18 * 1e18) / 1e15 = 1e22
        // after fee: ≈ 9.99e21
        // So minOut > 9.99e21 should revert

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "minOut inconsistent"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), uint128(1e22), address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), _emptyPermit()
        );
        vm.stopPrank();
    }

    function testMinOutValidation_AtBoundary_Succeeds() public {
        // Calculate exact worst case
        uint256 upperPrice = (uint256(5e14) * (uint256(1e7) + (1e7 - 1))) / 1e7;
        uint256 worstFulfillAmt = (uint256(SELL_AMT) * 1e18) / upperPrice;
        worstFulfillAmt -= worstFulfillAmt * MAX_FEE / 1e7;

        // minOut exactly at boundary should succeed
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), uint128(worstFulfillAmt), address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), _emptyPermit()
        );
        vm.stopPrank();

        assertTrue(swapContract.getSwap(swapId).active, "Swap should be created at exact boundary");
    }

    function testMinOutValidation_OnePastBoundary_Reverts() public {
        uint256 upperPrice = (uint256(5e14) * (uint256(1e7) + (1e7 - 1))) / 1e7;
        uint256 worstFulfillAmt = (uint256(SELL_AMT) * 1e18) / upperPrice;
        worstFulfillAmt -= worstFulfillAmt * MAX_FEE / 1e7;

        // minOut one past boundary should revert
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "minOut inconsistent"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), uint128(worstFulfillAmt + 1), address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), _emptyPermit()
        );
        vm.stopPrank();
    }

    function testMinOutValidation_HighFee_NarrowsWorstCase() public {
        // With maxFee near 100% (1e7 - 1), worstFulfillAmt is near zero
        openSwapV2Permit.FulfillFeeParams memory highFee = openSwapV2Permit.FulfillFeeParams({
            maxFee: uint24(1e7 - 1), startingFee: uint24(1e7 - 1), roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE, maxRounds: MAX_ROUNDS
        });

        // Even minOut = 1e18 should fail with near-100% fee
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "minOut inconsistent"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), uint128(1e18), address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), highFee, _emptyPermit()
        );
        vm.stopPrank();
    }

    function testMinOutValidation_ZeroMinOut_AlwaysSucceeds() public {
        // minOut = 0 should always pass the check (but reverts on "zero amounts")
        // Test with minOut = 1 instead
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), uint128(1), address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), _emptyPermit()
        );
        vm.stopPrank();

        assertTrue(swapContract.getSwap(swapId).active, "minOut=1 should always pass");
    }

    function testMinOutValidation_TightSlippage_ReducesWorstCase() public {
        // With tight tolerance (100 = 0.001%), worst price barely moves
        openSwapV2Permit.SlippageParams memory tight = openSwapV2Permit.SlippageParams({
            priceTolerated: 5e26, toleranceRange: 100
        });

        // Calculate worst case with tight slippage
        uint256 upperPrice = (uint256(5e14) * (uint256(1e7) + 100)) / 1e7;
        uint256 worstFulfillAmt = (uint256(SELL_AMT) * 1e18) / upperPrice;
        worstFulfillAmt -= worstFulfillAmt * MAX_FEE / 1e7;

        // Just above boundary should revert
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "minOut inconsistent"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), uint128(worstFulfillAmt + 1), address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), tight, _fulfillFeeParams(), _emptyPermit()
        );
        vm.stopPrank();

        // At boundary should succeed
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), uint128(worstFulfillAmt), address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), tight, _fulfillFeeParams(), _emptyPermit()
        );

        assertTrue(swapContract.getSwap(swapId).active, "At boundary with tight slippage should pass");
    }
}
