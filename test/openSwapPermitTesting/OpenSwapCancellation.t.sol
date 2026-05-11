// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

contract OpenSwapCancellationTest is Test {
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
    address internal randomUser = address(0x5);

    // Oracle params
    uint88 constant SETTLER_REWARD = 0.001 ether;
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
        buyToken = new MockERC20("BuyToken", "BUY");

        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(matcher, 100e18);
        sellToken.transfer(initialReporter, 100e18);
        buyToken.transfer(matcher, 100_000e18);
        buyToken.transfer(initialReporter, 100_000e18);

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(initialReporter, 10 ether);

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

    function _matchSwap(uint256 swapId) internal {
        _matchSwap(swapId, 2000e18);
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

    function _matchSwap(uint256 swapId, uint256 amount2) internal {
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(amount2), swapHash, _defaultPreimage());
        vm.stopPrank();
    }

    // ============ cancelSwap Tests ============

    function testCancelSwap_Success() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        uint256 swapId = _createSwap();

        // Verify tokens were transferred
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper should have sent sellToken");
        assertEq(swapper.balance, swapperEthBefore - ethToSend, "Swapper should have sent ETH");

        // Cancel the swap
        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        // Verify swap state
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.cancelled, "Swap should be cancelled");
        assertFalse(s.matched, "Swap should not be matched");
        assertFalse(s.finished, "Swap should not be finished");

        // Verify tokens returned
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(swapper.balance, swapperEthBefore, "Swapper should have ETH back");

        // Verify contract has no tokens
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "Contract should have no sellToken");
    }

    function testCancelSwap_FailsIfNotSwapper() public {
        uint256 swapId = _createSwap();

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "not swapper"));
        swapContract.cancelSwap(swapId);
    }

    function testCancelSwap_FailsIfAlreadyMatched() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "already matched"));
        swapContract.cancelSwap(swapId);
    }

    function testCancelSwap_FailsIfAlreadyCancelled() public {
        uint256 swapId = _createSwap();

        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "cancelled"));
        swapContract.cancelSwap(swapId);
    }

    function testCancelSwap_FailsIfNotActive() public {
        // SwapId 999 doesn't exist, so active = false
        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "not active"));
        swapContract.cancelSwap(999);
    }

    // ============ bailOut Tests ============

    function testBailOut_SuccessLatencyTimeout() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Verify tokens transferred
        assertEq(sellToken.balanceOf(address(swapContract)), SELL_AMT, "Contract should hold sellToken");
        assertEq(buyToken.balanceOf(address(swapContract)), MIN_FULFILL_LIQUIDITY, "Contract should hold buyToken");

        // Warp past latency bailout time without initial report
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // Anyone can call bailOut
        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        // Verify swap state
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Verify refunds
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        // amount2 (2000e18) was sent to oracle as initial report liquidity and remains there on bailout
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore - 2000e18, "Matcher should have buyToken back minus amount2 in oracle");

        // Verify contract empty
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "Contract should have no sellToken");
        assertEq(buyToken.balanceOf(address(swapContract)), 0, "Contract should have no buyToken");
    }

    function testBailOut_FailsIfNotMatched() public {
        uint256 swapId = _createSwap();

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "not matched"));
        swapContract.bailOut(swapId);
    }

    function testBailOut_FailsIfCancelled() public {
        uint256 swapId = _createSwap();

        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "not matched"));
        swapContract.bailOut(swapId);
    }

    function testBailOut_FailsIfFinished() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Warp past latency bailout
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // First bailout succeeds
        swapContract.bailOut(swapId);

        // Second bailout fails
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "finished"));
        swapContract.bailOut(swapId);
    }

    function testBailOut_NoOpIfLatencyNotReached() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Don't warp - latency not reached and no initial report
        // But also oracle not distributed, so neither condition met
        // Function should revert with "can't bail out yet"
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "can't bail out yet"));
        swapContract.bailOut(swapId);

        // Verify swap is NOT finished
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertFalse(s.finished, "Swap should NOT be finished - conditions not met");
        assertTrue(s.matched, "Swap should still be matched");
    }

    function testBailOut_OracleDistributedButCallbackSucceeds() public {
        // When callback succeeds, swap is finished, bailout reverts
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        (bytes32 stateHash,,,,,) = oracle.extraData(reportId);

        vm.startPrank(initialReporter);
        vm.stopPrank();

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        oracle.settle(reportId);

        // Swap should be finished via callback
        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished via callback");

        // Calling bailOut on finished swap should revert
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "finished"));
        swapContract.bailOut(swapId);
    }

    function testBailOut_OracleDistributedButCallbackFails() public {
        // Edge case: oracle settles (settlementTimestamp != 0) but callback fails.
        // bailOut now executes the swap at the discovered price rather than refunding,
        // so that a stuck callback can't be used as a free escape hatch.

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherSellBefore = sellToken.balanceOf(matcher);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // Mock the openOracleCallback callback to revert (simulating callback failure)
        vm.mockCallRevert(
            address(swapContract),
            abi.encodeWithSelector(openSwapV2Permit.openOracleCallback.selector),
            "callback failed"
        );

        // Settle oracle - callback will fail but oracle still marks settlementTimestamp
        oracle.settle(reportId);

        // Clear the mock so bailOut's _executeSwap can run normally
        vm.clearMockedCalls();

        // Verify oracle is settled
        (,,,, uint48 rsSettlementTimestamp,,) = oracle.reportStatus(reportId);
        assertTrue(rsSettlementTimestamp != 0, "Oracle should be settled");

        // Verify swap is NOT finished (callback failed)
        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertFalse(sAfter.finished, "Swap should NOT be finished since callback failed");

        // bailOut now executes the swap at the discovered price
        swapContract.bailOut(swapId);

        // Verify swap is now finished
        openSwapV2Permit.Swap memory sFinal = swapContract.getSwap(swapId);
        assertTrue(sFinal.finished, "Swap should be finished after bailout");

        // price = INITIAL_LIQUIDITY * 1e18 / amount2 = 1e18 * 1e18 / 2000e18 = 5e14 (matches priceTolerated)
        // raw fulfillAmt = SELL_AMT * amount2 / INITIAL_LIQUIDITY = 10e18 * 2000e18 / 1e18 = 20000e18
        // fulfillmentFee at match time = STARTING_FEE = 10000 (1e7 denom = 0.1%)
        // fulfillAmt -= 20000e18 * 10000 / 1e7 = 20e18  →  19980e18
        uint256 expectedFulfillAmt = 19980e18;

        // Swap executed: swapper sold SELL_AMT, received expectedFulfillAmt of buyToken
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper should have sold SELL_AMT");
        assertEq(buyToken.balanceOf(swapper), expectedFulfillAmt, "Swapper should have received fulfillAmt of buyToken");

        // Matcher: oracle returned the initialLiquidity sellToken stake (no disputes), then _executeSwap
        // transferred SELL_AMT of sellToken from openSwap → matcher. Net sellToken change = +SELL_AMT.
        assertEq(sellToken.balanceOf(matcher), matcherSellBefore + SELL_AMT, "Matcher should have received SELL_AMT of sellToken");
        // Matcher buyToken net change = -fulfillAmt (rest was returned by oracle and by _executeSwap residual)
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore - expectedFulfillAmt, "Matcher should be net out fulfillAmt of buyToken");
    }

    function testBailOut_MaxGameTimeTakesPriorityOverSettled() public {
        // Regression: once maxGameTime has elapsed, bailOut refunds even if the
        // oracle has already settled. The gameTooLong branch runs first so the
        // swapper always has a guaranteed recovery path past maxGameTime,
        // regardless of whether _executeSwap would succeed.

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;
        uint256 matchTime = s.start;

        // Advance just past settlementTime so the oracle is settleable.
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // Settle with the callback mocked to revert so the swap stays in
        // `matched && !finished` while the oracle records settlementTimestamp.
        vm.mockCallRevert(
            address(swapContract),
            abi.encodeWithSelector(openSwapV2Permit.openOracleCallback.selector),
            "callback failed"
        );
        oracle.settle(reportId);
        vm.clearMockedCalls();

        // Warp past maxGameTime.
        uint256 additionalSecs = MAX_GAME_TIME - SETTLEMENT_TIME;
        vm.warp(block.timestamp + additionalSecs);
        vm.roll(block.number + additionalSecs / 2);

        // Sanity: both branches' triggering conditions hold.
        (,,,, uint48 rsSettlementTimestamp,,) = oracle.reportStatus(reportId);
        assertTrue(rsSettlementTimestamp != 0, "Oracle should be settled");
        assertTrue(block.timestamp - matchTime > MAX_GAME_TIME, "maxGameTime should be exceeded");

        swapContract.bailOut(swapId);

        openSwapV2Permit.Swap memory sFinal = swapContract.getSwap(swapId);
        assertTrue(sFinal.finished, "Swap should be finished");

        // Refund branch: swapper gets sellToken back, matcher gets buyToken back.
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken refunded");
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore, "Swapper should not have received buyToken");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken refunded");
    }

    function testBailOut_FailsIfReportIdZero() public {
        // Create swap but don't match - reportId will be 0
        uint256 swapId = _createSwap();

        // Can't call bailOut on unmatched swap
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "not matched"));
        swapContract.bailOut(swapId);
    }

    function testBailOut_ExactLatencyBoundary() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 matchTime = s.start;

        // Warp to exactly latency bailout time - should revert (need to be > not >=)
        vm.warp(matchTime + MAX_GAME_TIME);
        vm.roll(block.number + MAX_GAME_TIME / 2);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "can't bail out yet"));
        swapContract.bailOut(swapId);

        openSwapV2Permit.Swap memory sMid = swapContract.getSwap(swapId);
        assertFalse(sMid.finished, "Swap should NOT be finished at exact boundary");

        // Warp 1 second more - should succeed
        vm.warp(matchTime + MAX_GAME_TIME + 1);
        vm.roll(block.number + 1);
        swapContract.bailOut(swapId);

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished after boundary");
    }

    function testCancelSwap_MatcherCannotCancel() public {
        uint256 swapId = _createSwap();

        vm.prank(matcher);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "not swapper"));
        swapContract.cancelSwap(swapId);
    }

    function testCancelSwap_EmitsEvent() public {
        uint256 swapId = _createSwap();

        vm.prank(swapper);
        vm.expectEmit(true, false, false, false);
        emit openSwapV2Permit.SwapCancelled(swapId);
        swapContract.cancelSwap(swapId);
    }

    function testCancelSwap_MultipleSwapsCancelIndependently() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        // Create two swaps
        uint256 swapId1 = _createSwap();
        uint256 swapId2 = _createSwap();

        // Cancel only the first one
        vm.prank(swapper);
        swapContract.cancelSwap(swapId1);

        openSwapV2Permit.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwapV2Permit.Swap memory s2 = swapContract.getSwap(swapId2);

        assertTrue(s1.cancelled, "Swap 1 should be cancelled");
        assertFalse(s2.cancelled, "Swap 2 should not be cancelled");
        assertTrue(s2.active, "Swap 2 should still be active");

        // Swapper should have one swap's worth of tokens back
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper should have 1 SELL_AMT still locked");

        // Contract should still hold swap2's tokens
        assertEq(sellToken.balanceOf(address(swapContract)), SELL_AMT, "Contract should hold swap2's sellToken");
    }
}
