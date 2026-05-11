// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

contract OpenSwapAnyoneCanCancelTest is Test {
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
    address internal thirdParty = address(0x7);

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

    // Expiration duration in seconds
    uint256 constant EXPIRATION_DURATION = 1 hours;

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
        vm.deal(thirdParty, 10 ether);

        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.startPrank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);
        sellToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(initialReporter);
        vm.stopPrank();
    }

    function _createSwapWithGasComp(uint256 gasComp) internal returns (uint256 swapId) {
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


        uint256 ethToSend = gasComp + SETTLER_REWARD;

        swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(EXPIRATION_DURATION),
            uint96(gasComp),
            oracleParams,
            slippageParams,
            fulfillFeeParams,
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );

        vm.stopPrank();
    }

    function _createSwap() internal returns (uint256 swapId) {
        return _createSwapWithGasComp(GAS_COMPENSATION);
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

    // ============ Swapper cancels before expiration + 30 ============

    function testSwapperCancelsBeforeExpiration() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperEthBefore = swapper.balance;

        uint256 swapId = _createSwap();

        // Still well before expiration
        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper gets all sellToken back");
        assertEq(swapper.balance, swapperEthBefore, "Swapper gets all ETH back");
    }

    function testSwapperCancelsAfterExpirationButBeforeGracePeriod() public {
        uint256 swapperEthBefore = swapper.balance;

        uint256 swapId = _createSwap();

        // Warp to just past expiration but within 30s grace
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 15);

        // Swapper can still cancel, gets full gasCompensation
        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        assertEq(sellToken.balanceOf(swapper), 100e18, "Swapper gets all sellToken back");
        assertEq(swapper.balance, swapperEthBefore, "Swapper gets all ETH back including full gasComp");
    }

    // ============ Third party rejected before expiration + 30 ============

    function testThirdPartyCannotCancelBeforeGracePeriod() public {
        uint256 swapId = _createSwap();

        // Still before expiration
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "not swapper"));
        swapContract.cancelSwap(swapId);
    }

    function testThirdPartyCannotCancelDuringGracePeriod() public {
        uint256 swapId = _createSwap();

        // Warp to expiration + 29 (still within 30s window)
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 29);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "not swapper"));
        swapContract.cancelSwap(swapId);
    }

    // ============ Exact boundary at expiration + 30 ============

    function testThirdPartyCannotCancelAtExactBoundary() public {
        uint256 swapId = _createSwap();

        // Warp to exactly expiration + 30 (block.timestamp <= expiration + 30 is true)
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 30);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "not swapper"));
        swapContract.cancelSwap(swapId);
    }

    function testSwapperCanCancelAtExactBoundary() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 30);

        uint256 swapperEthBefore = swapper.balance;

        // Swapper should succeed at the exact boundary where third party is rejected
        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        // Full gasComp to swapper (no split)
        assertEq(
            swapper.balance,
            swapperEthBefore + GAS_COMPENSATION + SETTLER_REWARD,
            "Swapper gets full gasComp at exact boundary"
        );
        assertTrue(swapContract.getSwap(swapId).cancelled, "Swap should be cancelled");
    }

    function testThirdPartyCanCancelOneSecondAfterBoundary() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 swapperEthBefore = swapper.balance;
        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        uint256 expectedCallerPiece = GAS_COMPENSATION / 5;
        uint256 expectedSwapperPiece = GAS_COMPENSATION - expectedCallerPiece;

        assertEq(thirdParty.balance, thirdPartyEthBefore + expectedCallerPiece, "Third party gets 20% of gasComp");
        // Swapper gets sellToken + 80% gasComp + bounty + settlerReward + 1
        assertEq(
            swapper.balance,
            swapperEthBefore + expectedSwapperPiece + SETTLER_REWARD,
            "Swapper gets 80% gasComp + bounty + settlerReward + 1"
        );
        assertEq(sellToken.balanceOf(swapper), 100e18, "Swapper gets all sellToken back");
    }

    // ============ Swapper cancels after expiration + 30 (gets full gasComp) ============

    function testSwapperCancelsAfterGracePeriod_GetsFullGasComp() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 100);

        uint256 swapperEthBefore = swapper.balance;

        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        // Swapper should get full gasComp (not split) when they cancel themselves
        assertEq(
            swapper.balance,
            swapperEthBefore + GAS_COMPENSATION + SETTLER_REWARD,
            "Swapper gets full gasComp when self-cancelling after grace period"
        );
    }

    // ============ Third party cancels after expiration + 30 ============

    function testThirdPartyCancelSplitsGasCompCorrectly() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 swapperEthBefore = swapper.balance;
        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        // 20% to caller, 80% to swapper
        uint256 callerPiece = GAS_COMPENSATION / 5; // 0.0002 ether
        uint256 swapperPiece = GAS_COMPENSATION - callerPiece; // 0.0008 ether

        assertEq(thirdParty.balance, thirdPartyEthBefore + callerPiece, "Caller gets 20%");
        assertEq(
            swapper.balance,
            swapperEthBefore + swapperPiece + SETTLER_REWARD,
            "Swapper gets 80% + bounty + settlerReward + 1"
        );
    }

    function testThirdPartyCancelSwapStateIsCorrect() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.cancelled, "Swap should be cancelled");
        assertFalse(sAfter.matched, "Swap should not be matched");
        assertFalse(sAfter.finished, "Swap should not be finished");
    }

    function testThirdPartyCancelContractDrained() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        assertEq(sellToken.balanceOf(address(swapContract)), 0, "Contract should have no sellToken");
    }

    // ============ Tiny gasCompensation (1..4 wei) ============

    function testTinyGasComp_1Wei_ThirdPartyGetsNothing() public {
        uint256 swapId = _createSwapWithGasComp(1);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 swapperEthBefore = swapper.balance;
        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        // 1 / 5 = 0, so caller gets nothing, swapper gets all 1 wei
        assertEq(thirdParty.balance, thirdPartyEthBefore, "Caller gets 0 for 1 wei gasComp");
        assertEq(
            swapper.balance,
            swapperEthBefore + 1 + SETTLER_REWARD,
            "Swapper gets full 1 wei gasComp"
        );
    }

    function testTinyGasComp_2Wei_ThirdPartyGetsNothing() public {
        uint256 swapId = _createSwapWithGasComp(2);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        // 2 / 5 = 0
        assertEq(thirdParty.balance, thirdPartyEthBefore, "Caller gets 0 for 2 wei gasComp");
    }

    function testTinyGasComp_4Wei_ThirdPartyGetsNothing() public {
        uint256 swapId = _createSwapWithGasComp(4);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        // 4 / 5 = 0
        assertEq(thirdParty.balance, thirdPartyEthBefore, "Caller gets 0 for 4 wei gasComp");
    }

    function testTinyGasComp_5Wei_ThirdPartyGets1() public {
        uint256 swapId = _createSwapWithGasComp(5);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 swapperEthBefore = swapper.balance;
        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        // 5 / 5 = 1 to caller, 4 to swapper
        assertEq(thirdParty.balance, thirdPartyEthBefore + 1, "Caller gets 1 wei for 5 wei gasComp");
        assertEq(
            swapper.balance,
            swapperEthBefore + 4 + SETTLER_REWARD,
            "Swapper gets 4 wei gasComp"
        );
    }

    function testTinyGasComp_0Wei_ThirdPartyCanStillCancel() public {
        // gasCompensation = 0 should still allow cancellation, just no reward
        uint256 swapId = _createSwapWithGasComp(0);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 swapperEthBefore = swapper.balance;
        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        assertEq(thirdParty.balance, thirdPartyEthBefore, "Caller gets nothing for 0 gasComp");
        assertEq(
            swapper.balance,
            swapperEthBefore + SETTLER_REWARD,
            "Swapper gets bounty + settlerReward + 1"
        );
        assertTrue(swapContract.getSwap(swapId).cancelled, "Swap should be cancelled");
    }

    // ============ Conservation of ETH: gasComp split always sums correctly ============

    function testGasCompConservation_LargeValue() public {
        uint256 gasComp = 1 ether;
        uint256 swapId = _createSwapWithGasComp(gasComp);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 swapperEthBefore = swapper.balance;
        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        uint256 callerReceived = thirdParty.balance - thirdPartyEthBefore;
        uint256 swapperReceived = swapper.balance - swapperEthBefore;
        // swapperReceived includes bounty + settlerReward + 1 in addition to gasComp piece
        uint256 swapperGasCompPiece = swapperReceived - SETTLER_REWARD;

        assertEq(callerReceived + swapperGasCompPiece, gasComp, "gasComp split must sum to total");
    }

    function testGasCompConservation_OddValue() public {
        // 999 wei: 999/5 = 199 to caller, 800 to swapper. 199+800=999
        uint256 gasComp = 999;
        uint256 swapId = _createSwapWithGasComp(gasComp);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 swapperEthBefore = swapper.balance;
        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        uint256 callerReceived = thirdParty.balance - thirdPartyEthBefore;
        uint256 swapperGasCompPiece = (swapper.balance - swapperEthBefore) - SETTLER_REWARD;

        assertEq(callerReceived, 199, "Caller gets 199 from 999");
        assertEq(swapperGasCompPiece, 800, "Swapper gets 800 from 999");
        assertEq(callerReceived + swapperGasCompPiece, gasComp, "Must sum to total");
    }

    // ============ Double-cancel not possible ============

    function testThirdPartyCancelThenSwapperCannotCancelAgain() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "cancelled"));
        swapContract.cancelSwap(swapId);
    }

    function testThirdPartyCancelThenAnotherThirdPartyCannotCancelAgain() public {
        address thirdParty2 = address(0x8);
        vm.deal(thirdParty2, 1 ether);

        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        vm.prank(thirdParty2);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "cancelled"));
        swapContract.cancelSwap(swapId);
    }

    // ============ Matched swap cannot be anyone-cancelled ============

    function testThirdPartyCannotCancelMatchedSwap() public {
        uint256 swapId = _createSwap();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "already matched"));
        swapContract.cancelSwap(swapId);
    }

    // ============ Fuzz: gasComp split always conserves value ============

    function testFuzz_gasCompSplitConservation(uint256 gasComp) public {
        // Bound to reasonable range - need enough ETH in swapper
        gasComp = bound(gasComp, 0, 5 ether);

        uint256 swapId = _createSwapWithGasComp(gasComp);

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 swapperEthBefore = swapper.balance;
        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        uint256 callerReceived = thirdParty.balance - thirdPartyEthBefore;
        uint256 swapperGasCompPiece = (swapper.balance - swapperEthBefore) - SETTLER_REWARD;

        assertEq(callerReceived + swapperGasCompPiece, gasComp, "gasComp split must always sum to total");
    }

    // ============ Contract starts with zero balances ============

    function testCancelWithZeroContractStartingBalances() public {
        // Verify contract starts empty
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "Contract should start with 0 sellToken");
        assertEq(buyToken.balanceOf(address(swapContract)), 0, "Contract should start with 0 buyToken");
        assertEq(address(swapContract).balance, 0, "Contract should start with 0 ETH");

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperEthBefore = swapper.balance;

        uint256 swapId = _createSwap();

        // Contract now holds exactly the swap's tokens/ETH
        assertEq(sellToken.balanceOf(address(swapContract)), SELL_AMT, "Contract holds sellAmt");
        assertGt(address(swapContract).balance, 0, "Contract holds ETH");

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        // Contract should be fully drained back to 0
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "Contract should be empty of sellToken after cancel");
        assertEq(address(swapContract).balance, 0, "Contract should be empty of ETH after cancel");
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper got all sellToken back");
    }

    // ============ Contract has pre-existing unrelated balances ============

    function testCancelWithPreExistingTokenBalances() public {
        // Seed contract with unrelated token balances (simulating leftovers from other swaps)
        uint256 preExistingSell = 50e18;
        uint256 preExistingBuy = 10_000e18;
        uint256 preExistingEth = 2 ether;

        sellToken.transfer(address(swapContract), preExistingSell);
        buyToken.transfer(address(swapContract), preExistingBuy);
        vm.deal(address(swapContract), preExistingEth);

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperEthBefore = swapper.balance;

        uint256 swapId = _createSwap();

        // Contract now holds pre-existing + swap's tokens
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            preExistingSell + SELL_AMT,
            "Contract holds pre-existing + swap sellToken"
        );

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        // Pre-existing balances should be untouched
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            preExistingSell,
            "Pre-existing sellToken should remain"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            preExistingBuy,
            "Pre-existing buyToken should remain"
        );
        // ETH: preExisting - (gasComp was paid out from contract's ETH pool)
        // The contract received gasComp + bounty + settlerReward + 1 from swap creation
        // and returned swapperPiece + bounty + settlerReward + 1 to swapper + callerPiece to caller
        // Net ETH change to contract from the cancel = -(gasComp + bounty + settlerReward + 1)
        // So contract ETH should be back to preExistingEth
        assertEq(
            address(swapContract).balance,
            preExistingEth,
            "Pre-existing ETH should remain"
        );

        // Swapper gets exactly their tokens back, not the pre-existing ones
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper gets exactly their sellToken");

        uint256 callerPiece = GAS_COMPENSATION / 5;
        assertEq(thirdParty.balance, thirdPartyEthBefore + callerPiece, "Third party gets correct callerPiece");
    }

    function testCancelWithPreExistingWETHBalance() public {
        // Seed contract with WETH (the token openSwap uses for ETH fallback)
        uint256 preExistingWETH = 5e18;
        deal(WETH, address(swapContract), preExistingWETH);

        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        vm.warp(s.expiration + 31);

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId);

        // WETH balance should be untouched (cancel uses ETH path, not WETH)
        assertEq(
            MockERC20(WETH).balanceOf(address(swapContract)),
            preExistingWETH,
            "Pre-existing WETH should remain untouched"
        );
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "Swap sellToken fully returned");
    }

    function testSwapperCancelWithPreExistingBalances() public {
        // Same test but swapper cancels (no split) — verify pre-existing balances still safe
        uint256 preExistingSell = 25e18;
        sellToken.transfer(address(swapContract), preExistingSell);
        vm.deal(address(swapContract), 1 ether);

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperEthBefore = swapper.balance;

        uint256 swapId = _createSwap();

        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        assertEq(
            sellToken.balanceOf(address(swapContract)),
            preExistingSell,
            "Pre-existing sellToken untouched after swapper cancel"
        );
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper gets exactly their tokens");
        assertEq(swapper.balance, swapperEthBefore, "Swapper gets exactly their ETH");
    }
}
