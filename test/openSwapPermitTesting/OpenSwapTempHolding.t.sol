// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

/**
 * @title BlacklistToken
 * @notice Token that can blacklist addresses from receiving tokens
 */
contract BlacklistToken is MockERC20 {
    mapping(address => bool) public blacklisted;

    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {}

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[to], "Blacklisted");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[to], "Blacklisted");
        return super.transferFrom(from, to, amount);
    }
}

/**
 * @title OpenSwapTempHoldingTest
 * @notice Tests for tempHolding fallback mechanism
 *
 * When token transfer fails (e.g., recipient is blacklisted),
 * tokens are stored in tempHolding instead of reverting.
 * Users can later call getTempHolding to withdraw.
 */
contract OpenSwapTempHoldingTest is Test {
    OpenOracle internal oracle;
    openSwapV2Permit internal swapContract;
    MockERC20 internal sellToken;
    BlacklistToken internal buyToken;

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
        buyToken = new BlacklistToken("BuyToken", "BUY");

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

        openSwapV2Permit.SlippageParams memory slippageParams = openSwapV2Permit.SlippageParams({
            priceTolerated: 5e14,
            toleranceRange: 1e7 - 1
        });

        openSwapV2Permit.FulfillFeeParams memory fulfillFeeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
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

    function _matchSwap(uint256 swapId) internal {
        _matchSwap(swapId, 2000e18);
    }

    function _matchSwap(uint256 swapId, uint256 amount2) internal {
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(amount2), swapHash);
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

    // ============ Normal Transfer Tests ============

    function testTempHolding_NormalTransferNoTempHolding() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        _settle(swapId);

        // Normal transfer works - no tempHolding
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), 0, "No tempHolding for normal transfer");
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper received buyToken directly");
    }

    // ============ Blacklisted Recipient Tests ============

    function testTempHolding_BlacklistedSwapperGoesToTempHolding() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        // Blacklist swapper before settlement
        buyToken.setBlacklisted(swapper, true);

        _settle(swapId);

        // Swapper is blacklisted, so buyToken goes to tempHolding
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), expectedFulfill, "TempHolding should have fulfillAmt");
        assertEq(buyToken.balanceOf(swapper), 0, "Swapper should NOT have buyToken directly");
    }

    function testTempHolding_BlacklistedMatcherExcessGoesToTempHolding() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        uint256 matcherExcess = MIN_FULFILL_LIQUIDITY - expectedFulfill;

        // Blacklist matcher before settlement
        buyToken.setBlacklisted(matcher, true);

        _settle(swapId);

        // Matcher is blacklisted, so excess buyToken goes to tempHolding
        assertEq(swapContract.tempHolding(matcher, address(buyToken)), matcherExcess, "TempHolding should have matcher excess");
        // Swapper is not blacklisted, so they get their tokens directly
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive buyToken directly");
    }

    // ============ getTempHolding Tests ============

    function testTempHolding_GetTempHoldingWithdrawsTokens() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        // Blacklist swapper
        buyToken.setBlacklisted(swapper, true);

        _settle(swapId);

        // Verify tempHolding has tokens
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), expectedFulfill, "TempHolding should have tokens");

        // Remove blacklist
        buyToken.setBlacklisted(swapper, false);

        // Swapper withdraws
        vm.prank(swapper);
        swapContract.getTempHolding(address(buyToken), swapper);

        // TempHolding cleared, swapper has tokens
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), 0, "TempHolding should be cleared");
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should have tokens now");
    }

    function testTempHolding_AnyoneCanCallGetTempHolding() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        buyToken.setBlacklisted(swapper, true);
        _settle(swapId);

        buyToken.setBlacklisted(swapper, false);

        // Random address can call getTempHolding for swapper
        address randomUser = address(0x999);
        vm.prank(randomUser);
        swapContract.getTempHolding(address(buyToken), swapper);

        // Swapper receives tokens
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should have tokens");
    }

    function testTempHolding_GetTempHoldingZeroAmountNoOp() public {
        // Calling getTempHolding when nothing is held should be a no-op
        uint256 balanceBefore = buyToken.balanceOf(swapper);

        vm.prank(swapper);
        swapContract.getTempHolding(address(buyToken), swapper);

        assertEq(buyToken.balanceOf(swapper), balanceBefore, "Balance unchanged");
    }

    // ============ Multiple Accumulation Tests ============

    function testTempHolding_MultipleSwapsAccumulate() public {
        // First swap
        uint256 swapId1 = _createSwap();
        _matchSwap(swapId1);
        buyToken.setBlacklisted(swapper, true);
        _settle(swapId1);

        uint256 expectedFulfill1 = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), expectedFulfill1, "First swap in tempHolding");

        // Second swap
        uint256 swapId2 = _createSwap();
        _matchSwap(swapId2, 2100e18);
        _settle(swapId2);

        uint256 expectedFulfill2 = _calcFulfillAmt(INITIAL_LIQUIDITY, 2100e18);
        uint256 totalExpected = expectedFulfill1 + expectedFulfill2;

        assertEq(swapContract.tempHolding(swapper, address(buyToken)), totalExpected, "Both swaps accumulated in tempHolding");

        // Withdraw all at once
        buyToken.setBlacklisted(swapper, false);
        swapContract.getTempHolding(address(buyToken), swapper);

        assertEq(buyToken.balanceOf(swapper), totalExpected, "Swapper got all accumulated tokens");
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), 0, "TempHolding cleared");
    }

    // ============ Refund Scenario Tests ============

    function testTempHolding_RefundSellTokenToSwapper() public {
        // In a refund scenario, sellToken goes back to swapper
        // sellToken is MockERC20 (no blacklist), so it should transfer normally

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        uint256 swapId = _createSwap();
        _matchSwap(swapId, 2600e18);

        // Verify sellToken left swapper
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper sent sellToken");

        // Trigger refund by exceeding minFulfillLiquidity
        _settle(swapId);

        // Swapper gets sellToken back (direct transfer, no tempHolding)
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper got sellToken back");
        assertEq(swapContract.tempHolding(swapper, address(sellToken)), 0, "No tempHolding for sellToken");
    }

    function testTempHolding_RefundSellTokenToBlacklistedSwapper() public {
        // Use a blacklist token as sellToken to test tempHolding on refund
        BlacklistToken blacklistSellToken = new BlacklistToken("BlacklistSell", "BSELL");
        blacklistSellToken.transfer(swapper, 100e18);
        blacklistSellToken.transfer(initialReporter, 100e18);
        // Matcher needs initialLiquidity of sellToken for the oracle game in V2 matchSwap
        blacklistSellToken.transfer(matcher, 10e18);

        vm.prank(swapper);
        blacklistSellToken.approve(address(swapContract), type(uint256).max);

        vm.prank(matcher);
        blacklistSellToken.approve(address(swapContract), type(uint256).max);

        // Create swap with blacklist sellToken
        vm.startPrank(swapper);
        openSwapV2Permit.OracleParams memory oracleParams = openSwapV2Permit.OracleParams({
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
        openSwapV2Permit.SlippageParams memory slippageParams = openSwapV2Permit.SlippageParams({
            priceTolerated: 5e14,
            toleranceRange: 1e7 - 1
        });
        openSwapV2Permit.FulfillFeeParams memory fulfillFeeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(blacklistSellToken),
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

        _matchSwap(swapId, 2600e18);

        // Blacklist swapper for the sellToken before refund
        blacklistSellToken.setBlacklisted(swapper, true);

        // Trigger refund
        _settle(swapId);

        // Swapper is blacklisted, so sellToken refund goes to tempHolding
        assertEq(swapContract.tempHolding(swapper, address(blacklistSellToken)), SELL_AMT, "SellToken in tempHolding");
        assertEq(blacklistSellToken.balanceOf(swapper), 100e18 - SELL_AMT, "Swapper didn't get sellToken directly");

        // Unblacklist and withdraw
        blacklistSellToken.setBlacklisted(swapper, false);
        swapContract.getTempHolding(address(blacklistSellToken), swapper);

        assertEq(blacklistSellToken.balanceOf(swapper), 100e18, "Swapper recovered sellToken");
        assertEq(swapContract.tempHolding(swapper, address(blacklistSellToken)), 0, "TempHolding cleared");
    }

    function testTempHolding_RefundBuyTokenToBlacklistedMatcher() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId, 2600e18);

        // Blacklist matcher before settlement
        buyToken.setBlacklisted(matcher, true);

        // Trigger refund
        _settle(swapId);

        // Matcher's buyToken refund goes to tempHolding
        assertEq(swapContract.tempHolding(matcher, address(buyToken)), MIN_FULFILL_LIQUIDITY, "Matcher buyToken in tempHolding");

        // Unblacklist and withdraw
        buyToken.setBlacklisted(matcher, false);
        swapContract.getTempHolding(address(buyToken), matcher);

        // In V2 matchSwap pulls minFulfillLiquidity + amount2 from matcher;
        // only minFulfillLiquidity is refunded, so matcher loses amount2 (2600e18) to the oracle game.
        assertEq(buyToken.balanceOf(matcher), 100_000e18 - 2600e18, "Matcher recovered refunded buyToken");
    }
}
