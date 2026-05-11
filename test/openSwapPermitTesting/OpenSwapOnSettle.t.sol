// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";
import "../utils/MaliciousReentrantToken.sol";

/**
 * @title OpenSwapOnSettleTest
 * @notice Tests for openOracleCallback callback access control and behavior
 *
 * openOracleCallback is called by the oracle when a report settles.
 * Access control:
 * - Only oracle can call (msg.sender == oracle)
 * - reportId must match stored reportId
 * - Cannot be called if already finished
 */
contract OpenSwapOnSettleTest is Test {
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

    // ============ Access Control Tests ============

    function testOnSettle_OnlyOracleCanCall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Random user cannot call openOracleCallback
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "invalid sender"));
        swapContract.openOracleCallback(reportId, 1e18, 2000e18, 0, address(sellToken), address(buyToken));
    }

    function testOnSettle_SwapperCannotCall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "invalid sender"));
        swapContract.openOracleCallback(reportId, 1e18, 2000e18, 0, address(sellToken), address(buyToken));
    }

    function testOnSettle_MatcherCannotCall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        vm.prank(matcher);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "invalid sender"));
        swapContract.openOracleCallback(reportId, 1e18, 2000e18, 0, address(sellToken), address(buyToken));
    }

    function testOnSettle_BountyContractCannotCall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "invalid sender"));
        swapContract.openOracleCallback(reportId, 1e18, 2000e18, 0, address(sellToken), address(buyToken));
    }

    // ============ ReportId Validation Tests ============

    function testOnSettle_WrongReportIdReverts() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 correctReportId = s.reportId;
        uint256 wrongReportId = correctReportId + 100;

        // Even oracle can't call with wrong reportId
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "wrong reportId"));
        swapContract.openOracleCallback(wrongReportId, 1e18, 2000e18, 0, address(sellToken), address(buyToken));
    }

    function testOnSettle_ZeroReportIdReverts() public {
        // reportId 0 doesn't map to any swap, so swaps[reportIdToSwapId[0]] returns
        // a zero-initialized Swap. With osrf6, _executeSwap reads oracle.reportStatus
        // first and reverts on the explicit "not settled" guard before any division
        // is attempted, since reportStatus(0).settlementTimestamp is also 0.
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "not settled"));
        swapContract.openOracleCallback(0, 1e18, 2000e18, 0, address(sellToken), address(buyToken));
    }

    // ============ Already Finished Tests ============

    function testOnSettle_CannotCallTwice() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // First settle via oracle (normal flow)
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId);

        // Verify swap is finished
        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished");

        // Second call to openOracleCallback should fail
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "finished"));
        swapContract.openOracleCallback(reportId, 1e18, 2000e18, 0, address(sellToken), address(buyToken));
    }

    // ============ Normal Flow via Oracle Tests ============

    function testOnSettle_OracleSettleTriggersCallback() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        assertFalse(s.finished, "Swap should not be finished yet");

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId);

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished after oracle settle");
    }

    function testOnSettle_SetsFinishedFlag() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId);

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "finished flag should be set");
    }

    // ============ Multiple Swaps Isolation Tests ============

    function testOnSettle_OnlyAffectsMatchingSwap() public {
        uint256 swapId1 = _createSwap();
        uint256 swapId2 = _createSwap();

        _matchSwap(swapId1);
        _matchSwap(swapId2);

        openSwapV2Permit.Swap memory s1 = swapContract.getSwap(swapId1);
        uint256 reportId1 = s1.reportId;

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId1);

        // Swap 1 finished, swap 2 not
        openSwapV2Permit.Swap memory s1After = swapContract.getSwap(swapId1);
        openSwapV2Permit.Swap memory s2After = swapContract.getSwap(swapId2);

        assertTrue(s1After.finished, "Swap 1 should be finished");
        assertFalse(s2After.finished, "Swap 2 should NOT be finished");
    }

    // ============ Direct Oracle Call Test ============

    function testOnSettle_DirectOracleCallWorks() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Advance time/blocks to pass impliedBlocksPerSecond check
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // _executeSwap requires oracle.reportStatus(id).settlementTimestamp != 0.
        // Settle the oracle for real, but suppress its automatic callback so we can
        // exercise the direct openOracleCallback path afterwards.
        vm.mockCallRevert(
            address(swapContract),
            abi.encodeWithSelector(openSwapV2Permit.openOracleCallback.selector),
            "skipped"
        );
        oracle.settle(reportId);
        vm.clearMockedCalls();

        // Directly call openOracleCallback as oracle (simulating what the oracle does internally)
        vm.prank(address(oracle));
        swapContract.openOracleCallback(reportId, 1e18, 2000e18, block.timestamp, address(sellToken), address(buyToken));

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Direct oracle call should work");
    }

    /// @notice Reproduces the original v2 grief: an attacker calls swap() with a
    /// hook-bearing token whose transferFrom calls oracle.settle(targetReportId)
    /// while openSwap's nonReentrant lock is held by the outer swap() call.
    /// In v2 (nonReentrant on openOracleCallback), the inner callback would silently fail
    /// and leave the target swap stuck (refundable via bailOut → effective cancel).
    /// In osrf6 (nonReentrant removed from openOracleCallback), the callback succeeds and
    /// the target swap is finalized at the discovered price.
    function testReentrancy_OnSettleNotBlockedByOuterSwap() public {
        // 1. Set up target swap A and match it.
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherSellBefore = sellToken.balanceOf(matcher);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapA = _createSwap();
        _matchSwap(swapA);

        openSwapV2Permit.Swap memory sA = swapContract.getSwap(swapA);
        uint256 reportIdA = sA.reportId;

        // Advance past settlementTime so oracle.settle(reportIdA) is callable.
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // 2. Deploy malicious token, fund attacker, configure hook to fire on next transferFrom.
        MaliciousReentrantToken mal = new MaliciousReentrantToken();
        address attacker = address(0x99);
        vm.deal(attacker, 10 ether);
        mal.transfer(attacker, 100e18);
        vm.prank(attacker);
        mal.approve(address(swapContract), type(uint256).max);
        mal.armHook(oracle, reportIdA);

        // 3. Attacker calls swap() with mal as sellToken. While inside swap(),
        // openSwap's nonReentrant is held; the malicious token's transferFrom
        // hook calls oracle.settle(reportIdA), which calls back into openOracleCallback(A).
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

        vm.prank(attacker);
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            address(mal),
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

        // 4. Confirm: hook actually fired (consumed) — proves the reentry path was exercised.
        assertFalse(mal.hookArmed(), "Hook should have fired during attacker's swap()");

        // 5. Critical assertion: swap A was finalized in-line by the inner callback.
        // In v2 it would still be matched-but-not-finished here (callback bricked by lock).
        openSwapV2Permit.Swap memory sAFinal = swapContract.getSwap(swapA);
        assertTrue(sAFinal.finished, "Target swap A should be finalized via inner callback");

        // 6. And finalized via execute (not refund) — a no-bailout, full settlement at oracle price.
        uint256 expectedFulfillAmt = 19980e18;
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper sold SELL_AMT");
        assertEq(buyToken.balanceOf(swapper), expectedFulfillAmt, "Swapper received fulfillAmt");
        assertEq(sellToken.balanceOf(matcher), matcherSellBefore + SELL_AMT, "Matcher received sellToken");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore - expectedFulfillAmt, "Matcher net out fulfillAmt");
    }
}
