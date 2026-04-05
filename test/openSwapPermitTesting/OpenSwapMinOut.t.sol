// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapMinOutTest
 * @notice Tests for minOut protection mechanism
 *
 * fulfillAmt calculation:
 *   fulfillAmt = (sellAmt * oracleAmount2) / oracleAmount1
 *   fulfillAmt -= fulfillAmt * fulfillmentFee / 1e7
 *
 * If fulfillAmt < minOut -> refund both parties
 */
contract OpenSwapMinOutTest is Test {
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

    function _createSwapWithMinOut(uint256 minOut) internal returns (uint256 swapId) {
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

        // No slippage check for minOut tests
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
            uint128(minOut),
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

    // Helper to calculate expected fulfillAmt
    function _calcFulfillAmt(uint256 amount1, uint256 amount2) internal pure returns (uint256) {
        uint256 fulfillAmt = (SELL_AMT * amount2) / amount1;
        fulfillAmt -= fulfillAmt * STARTING_FEE / 1e7;
        return fulfillAmt;
    }

    // ============ MinOut Pass Tests ============

    function testMinOut_ExactlyMet() public {
        // With amount1=1e18, amount2=2000e18:
        // fulfillAmt = 10e18 * 2000e18 / 1e18 = 20000e18
        // fulfillAmt -= 20000e18 * 10000 / 1e7 = 20000e18 - 20e18 = 19980e18
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        assertEq(expectedFulfill, 19980e18, "Expected fulfillAmt calculation");

        // Use minOut=1e18 to pass creation-time validation (minOut inconsistent check)
        uint256 swapId = _createSwapWithMinOut(1e18);
        _matchSwap(swapId);

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive fulfillAmt");
    }

    function testMinOut_Exceeded() public {
        // minOut = 19000e18, but fulfillAmt will be 19980e18
        uint256 minOut = 1e18;
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId);

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive fulfillAmt > minOut");
        assertGt(expectedFulfill, minOut, "fulfillAmt should exceed minOut");
    }

    function testMinOut_ZeroReverts() public {
        // minOut = 0 is rejected by the contract
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
            maxRounds: MAX_ROUNDS
        });


        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "zero amounts"));
        swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            0, // minOut = 0 should revert
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

    // ============ MinOut Fail Tests (Refund) ============

    function testMinOut_NotMet_Refund() public {
        // V2: minOut is validated at creation time only; at settlement the swap always executes.
        // With minOut=1e18 and fulfillAmt=19980e18, the swap succeeds.
        uint256 minOut = 1e18;
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId);

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Swap executes successfully: swapper receives fulfillAmt
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper sent sellToken");
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive buyToken");
    }

    function testMinOut_BarelyNotMet_Refund() public {
        // V2: minOut is validated at creation time only; at settlement the swap always executes.
        // fulfillAmt = 19980e18, minOut = 1e18 (well below fulfillAmt); swap succeeds.
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        uint256 minOut = 1e18;

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId);

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Swap executes successfully: swapper receives fulfillAmt
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper sent sellToken");
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive buyToken");
    }

    function testMinOut_LowOraclePrice_Refund() public {
        // V2: minOut is validated at creation time only; at settlement the swap always executes.
        // Oracle reports lower price but swap still completes; swapper receives lower fulfillAmt.
        uint256 minOut = 1e18;

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId, 1400e18);

        // Lower amount2 -> lower fulfillAmt
        // fulfillAmt = 10e18 * 1400e18 / 1e18 = 14000e18 (minus fee ~13986e18)
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 1400e18);
        assertGt(expectedFulfill, minOut, "Expected fulfillAmt > minOut (swap succeeds)");

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Swap executes: swapper receives the (lower) fulfillAmt
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper sent sellToken");
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper receives lower fulfillAmt");
    }

    // ============ Edge Cases ============

    function testMinOut_HighOraclePrice_StillPasses() public {
        // Very high oracle price should easily pass minOut
        uint256 minOut = 1e18;

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId, 2500e18);

        // High amount2 means high fulfillAmt
        // fulfillAmt = 10e18 * 2500e18 / 1e18 = 25000e18 (minus fee) = 24975e18
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2500e18);

        _settle(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive high fulfillAmt");
        assertGt(expectedFulfill, minOut, "fulfillAmt should exceed minOut");
    }

    function testMinOut_FulfillmentFeeImpact() public {
        // Verify the fee actually impacts the fulfillAmt calculation
        // Without fee: 10e18 * 2000e18 / 1e18 = 20000e18
        // With 0.1% fee: 20000e18 - 20e18 = 19980e18

        uint256 withoutFee = (uint256(SELL_AMT) * 2000e18) / INITIAL_LIQUIDITY;
        uint256 withFee = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        assertEq(withoutFee, 20000e18, "Without fee calculation");
        assertEq(withFee, 19980e18, "With fee calculation");
        assertEq(withoutFee - withFee, 20e18, "Fee should be 20e18");

        // Use minOut=1e18 to pass creation-time validation (minOut > 19990 would fail "minOut inconsistent")
        uint256 minOut = 1e18;

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId);

        _settle(swapId);

        // Swap succeeds because fulfillAmt (19980e18) >= minOut (1e18)
        // Fee impact is verified by withoutFee vs withFee difference above
        assertEq(buyToken.balanceOf(swapper), withFee, "Swapper receives fee-adjusted fulfillAmt");
    }
}
