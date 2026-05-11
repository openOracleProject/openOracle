// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../../src/oracleFeeReceiver.sol";
import "../utils/MockERC20.sol";
import "../utils/MaliciousReentrantToken.sol";

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

        // feeRecipient is address(0) when protocolFee is 0; the contract reverts
        // explicitly with InvalidInput("no fee recipient") before any external call.
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "no fee recipient"));
        swapContract.grabOracleGameFeesAny(swapId);
    }

    function testProtocolFees_GrabOracleGameFeesAny_RevertsIfNotMatched() public {
        uint256 swapId = _createSwap();
        // Don't match — feeRecipient is still address(0), so the "no fee recipient"
        // guard fires before the !matched check.
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "no fee recipient"));
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

    function testProtocolFees_FeeReentryNoDoubleDistribution() public {
        // The cross-contract reentry path we spent time reasoning about:
        //   grabOracleGameFeesAny → sweep → token hook → oracle.settle → openOracleCallback → nested grabOracleGameFees
        //
        // The receiver's nonReentrant blocks the nested sweep/collect attempts, so
        // the nested grabOracleGameFees distributes 0. The outer sweep returns the
        // actual fee amount, and the outer call distributes those fees exactly once.
        // Net: no double distribution, no funds stuck or duplicated.

        // Deploy hook-bearing token; fund parties; configure approvals.
        MaliciousReentrantToken mal = new MaliciousReentrantToken();
        mal.transfer(swapper, 100e18);
        mal.transfer(matcher, 100e18);
        vm.prank(swapper);
        mal.approve(address(swapContract), type(uint256).max);
        vm.prank(matcher);
        mal.approve(address(swapContract), type(uint256).max);

        // Snapshot balances *before* any swap activity so net-change assertions are clean.
        uint256 swapperMalBefore = mal.balanceOf(swapper);
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        uint256 matcherMalBefore = mal.balanceOf(matcher);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        // Create swap A with mal as sellToken so the receiver's mal-sweep triggers our hook.
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

        vm.prank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
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

        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.prank(matcher);
        swapContract.matchSwap(swapId, 2000e18, swapHash, _defaultPreimage());

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        address feeRecipient = s.feeRecipient;

        // Seed fees (in mal) into the receiver to simulate accrued protocol fees.
        uint256 seededFees = 100e18;
        mal.transfer(feeRecipient, seededFees);

        // Advance past settlementTime so oracle.settle(reportId) is callable.
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // Arm the hook to fire oracle.settle on the next mal _update (sweep transfer).
        mal.armHook(oracle, s.reportId);

        // Trigger the cascade. randomUser is uninvolved and gets nothing.
        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);

        // Hook fired (and disarmed) — confirms we exercised the reentry path.
        assertFalse(mal.hookArmed(), "Hook should have fired during outer sweep");

        // Swap A finalized in-line by the inner callback.
        openSwapV2Permit.Swap memory sFinal = swapContract.getSwap(swapId);
        assertTrue(sFinal.finished, "Swap A should be finalized via inner callback");

        // Receiver fully drained — fees were swept exactly once, by the outer call.
        assertEq(mal.balanceOf(feeRecipient), 0, "Receiver drained, no double-distribution stragglers");

        // Net distributions across the whole cascade. INITIAL_LIQUIDITY (mal) is a
        // round-trip: deposited at match, returned by oracle.settle.
        // Fee split: floor(seededFees/2) to swapper, remainder to matcher.
        uint256 expectedFulfillAmt = 19980e18;
        uint256 swapperFeeShare = seededFees / 2;
        uint256 matcherFeeShare = seededFees - swapperFeeShare;

        // Swapper: sold SELL_AMT mal, received expectedFulfillAmt of buyToken, plus 1/2 of fees in mal.
        assertEq(mal.balanceOf(swapper), swapperMalBefore - SELL_AMT + swapperFeeShare, "Swapper mal: -SELL_AMT + 1/2 fees");
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + expectedFulfillAmt, "Swapper buyToken: +fulfillAmt");

        // Matcher: net +SELL_AMT mal (initialLiquidity wash) + 1/2 fees, net -fulfillAmt buyToken.
        assertEq(mal.balanceOf(matcher), matcherMalBefore + SELL_AMT + matcherFeeShare, "Matcher mal: +SELL_AMT + 1/2 fees");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore - expectedFulfillAmt, "Matcher buyToken: -fulfillAmt");

        // randomUser uninvolved, no inadvertent payouts (e.g. via misrouted residual).
        assertEq(mal.balanceOf(randomUser), 0, "Random user gets no mal");
    }

    function testProtocolFees_PostSettlementFeeRetry() public {
        // Grief boundary: a sweep failure during openOracleCallback's grabOracleGameFees must
        // not brick the swap (try/catch absorbs it). Fees can be recovered later by
        // anyone calling grabOracleGameFeesAny once sweep is unblocked.
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        address feeRecipient = s.feeRecipient;

        // Seed the receiver with fees that should eventually distribute.
        sellToken.transfer(feeRecipient, 100e18);

        // Make sweep(sellToken) revert for the duration of openOracleCallback. buyToken sweep is
        // left alone (would be a no-op anyway since receiver has no buyToken seeded).
        vm.mockCallRevert(
            feeRecipient,
            abi.encodeWithSelector(oracleFeeReceiver.sweep.selector, address(sellToken)),
            "sweep blocked"
        );

        // Settle: callback runs, _executeSwap completes, grabOracleGameFees swallows
        // the sweep revert, swap is marked finished.
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(s.reportId);

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished even if fee sweep failed");

        // Fees stayed in the receiver — no distribution happened on the failed path.
        // Snapshot post-settlement balances (which include the swap-execute payouts
        // but NOT the fees) so we can assert the fee retry adds exactly 50e18 on top.
        assertEq(sellToken.balanceOf(feeRecipient), 100e18, "Fees should still be in receiver after failed sweep");
        uint256 swapperSellPostSettle = sellToken.balanceOf(swapper);
        uint256 matcherSellPostSettle = sellToken.balanceOf(matcher);

        // Unblock sweep and recover via the anyone-callable retry path.
        vm.clearMockedCalls();

        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);

        assertEq(sellToken.balanceOf(swapper) - swapperSellPostSettle, 50e18, "Swapper gets 50e18 on retry");
        assertEq(sellToken.balanceOf(matcher) - matcherSellPostSettle, 50e18, "Matcher gets 50e18 on retry");
        assertEq(sellToken.balanceOf(feeRecipient), 0, "Receiver should be drained on retry");
    }

    function testProtocolFees_CloneFirstCallWorks() public {
        // oracleFeeReceiver inherits ReentrancyGuard. EIP-1167 clones do NOT run the
        // implementation's constructor, so _status starts at 0 (not NOT_ENTERED=1).
        // OZ's modifier checks `_status == ENTERED (=2)`, so 0 passes — but explicit
        // coverage guards against accidental future regressions (e.g. switching to a
        // guard variant that requires constructor-set state).
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        // Sanity: this is a fresh clone (different address than the implementation,
        // and "initialized" via the swap match — but constructor never ran on it).
        assertTrue(s.feeRecipient != address(0), "feeRecipient should be set");
        assertTrue(s.feeRecipient != swapContract.feeReceiverImpl(), "Should be a clone, not the impl");

        // Seed it so sweep has something non-trivial to do.
        sellToken.transfer(address(feeReceiver), 100e18);

        // First-ever invocation of collect() and sweep() on this clone — must succeed.
        // Calling them directly (not via grabOracleGameFees) makes this a strict guard
        // on the clone's nonReentrant init state for both functions.
        vm.startPrank(address(swapContract));
        feeReceiver.collect();
        uint256 swept = feeReceiver.sweep(address(sellToken));
        vm.stopPrank();

        assertEq(swept, 100e18, "First sweep on a clone should return the seeded balance");
        assertEq(sellToken.balanceOf(address(feeReceiver)), 0, "Receiver should be drained");
        assertEq(sellToken.balanceOf(address(swapContract)), 100e18 + SELL_AMT, "Funds should land on owner (swapContract)");
    }

    function testProtocolFees_DoubleCallNoDoubleDistribution() public {
        // Idempotence proxy for the reentry concern: calling grabOracleGameFeesAny
        // twice in a row, with no fees added between calls, must distribute nothing
        // on the second call (no double-spending of openSwap's general balance).
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(s.feeRecipient);

        // Seed the receiver with fees and pre-fund openSwap with extra balance to make
        // any over-distribution observable as a real drain rather than a revert.
        sellToken.transfer(address(feeReceiver), 100e18);
        sellToken.transfer(address(swapContract), 500e18);

        uint256 swapperBefore = sellToken.balanceOf(swapper);
        uint256 matcherBefore = sellToken.balanceOf(matcher);
        uint256 openSwapBefore = sellToken.balanceOf(address(swapContract));

        // First call distributes the 100e18 fees: 50/50 split.
        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);

        assertEq(sellToken.balanceOf(swapper) - swapperBefore, 50e18, "First call: swapper gets 50e18");
        assertEq(sellToken.balanceOf(matcher) - matcherBefore, 50e18, "First call: matcher gets 50e18");
        // Sweep moves 100e18 in, distribution moves 100e18 out → openSwap balance unchanged.
        assertEq(sellToken.balanceOf(address(swapContract)), openSwapBefore, "First call: contract balance unchanged (sweep in == distribute out)");

        // Second call with no new fees must be a no-op — must not touch openSwap's pre-funded balance.
        uint256 openSwapAfterFirst = sellToken.balanceOf(address(swapContract));
        uint256 swapperAfterFirst = sellToken.balanceOf(swapper);
        uint256 matcherAfterFirst = sellToken.balanceOf(matcher);

        vm.prank(randomUser);
        swapContract.grabOracleGameFeesAny(swapId);

        assertEq(sellToken.balanceOf(swapper), swapperAfterFirst, "Second call: swapper unchanged");
        assertEq(sellToken.balanceOf(matcher), matcherAfterFirst, "Second call: matcher unchanged");
        assertEq(sellToken.balanceOf(address(swapContract)), openSwapAfterFirst, "Second call: contract balance unchanged (no drain)");
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
