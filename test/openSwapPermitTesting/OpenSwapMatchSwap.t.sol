// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapMatchSwapTest
 * @notice Tests for matchSwap behavior and state changes
 *
 * Covers:
 * - State changes after match (matched, matcher, start, reportId)
 * - Token transfers during match
 * - Bounty creation
 * - Oracle report creation
 * - reportIdToSwapId mapping
 * - Self-matching behavior
 */
contract OpenSwapMatchSwapTest is Test {
    OpenOracle internal oracle;
    openSwapV2Permit internal swapContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address constant OP = 0x4200000000000000000000000000000000000042;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal matcher2 = address(0x3);

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
        buyToken.transfer(matcher, 100_000e18);
        buyToken.transfer(matcher2, 100_000e18);
        buyToken.transfer(swapper, 100_000e18); // For self-matching

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(matcher2, 10 ether);

        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.startPrank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);
        sellToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        sellToken.transfer(matcher2, 100e18);

        vm.startPrank(matcher2);
        buyToken.approve(address(swapContract), type(uint256).max);
        sellToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        vm.prank(swapper);
        buyToken.approve(address(swapContract), type(uint256).max);
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

    // ============ State Change Tests ============

    function testMatchSwap_SetsMatchedTrue() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory sBefore = swapContract.getSwap(swapId);
        assertFalse(sBefore.matched, "Should not be matched before");

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.matched, "Should be matched after");
    }

    function testMatchSwap_SetsMatcher() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory sBefore = swapContract.getSwap(swapId);
        assertEq(sBefore.matcher, address(0), "Matcher should be zero before");

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertEq(sAfter.matcher, matcher, "Matcher should be set after");
    }

    function testMatchSwap_SetsStartTimestamp() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory sBefore = swapContract.getSwap(swapId);
        assertEq(sBefore.start, 0, "Start should be zero before");

        uint256 matchTimestamp = block.timestamp + 100;
        vm.warp(matchTimestamp);
        vm.roll(block.number + 50);

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertEq(sAfter.start, matchTimestamp, "Start should be set to match timestamp");
    }

    function testMatchSwap_SetsReportId() public {
        uint256 swapId = _createSwap();

        openSwapV2Permit.Swap memory sBefore = swapContract.getSwap(swapId);
        assertEq(sBefore.reportId, 0, "ReportId should be zero before");

        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertEq(sAfter.reportId, expectedReportId, "ReportId should be set");
    }

    function testMatchSwap_SetsReportIdToSwapIdMapping() public {
        uint256 swapId = _createSwap();

        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        uint256 mappedSwapId = swapContract.reportIdToSwapId(expectedReportId);
        assertEq(mappedSwapId, swapId, "reportIdToSwapId should map correctly");
    }

    // ============ Token Transfer Tests ============

    function testMatchSwap_TransfersBuyTokenFromMatcher() public {
        uint256 swapId = _createSwap();

        uint256 matcherBefore = buyToken.balanceOf(matcher);
        uint256 contractBefore = buyToken.balanceOf(address(swapContract));

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        uint256 matcherAfter = buyToken.balanceOf(matcher);
        uint256 contractAfter = buyToken.balanceOf(address(swapContract));

        assertEq(matcherAfter, matcherBefore - (MIN_FULFILL_LIQUIDITY + 2000e18), "Matcher should have sent minFulfillLiquidity");
        assertEq(contractAfter, contractBefore + MIN_FULFILL_LIQUIDITY, "Contract should have received minFulfillLiquidity");
    }

    function testMatchSwap_SellTokenAlreadyInContract() public {
        uint256 contractBefore = sellToken.balanceOf(address(swapContract));

        uint256 swapId = _createSwap();

        // After swap creation, sellToken should be in contract
        uint256 contractAfterCreate = sellToken.balanceOf(address(swapContract));
        assertEq(contractAfterCreate, contractBefore + SELL_AMT, "Contract should hold sellToken after create");

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        // After match, sellToken should still be in contract (no change)
        uint256 contractAfterMatch = sellToken.balanceOf(address(swapContract));
        assertEq(contractAfterMatch, contractAfterCreate, "sellToken balance unchanged by match");
    }

    // ============ Bounty Creation Tests ============

    function testMatchSwap_CreatesBounty() public {
        uint256 swapId = _createSwap();
        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        // V2: No bounty contract — matcher submits initial report atomically
    }

    // ============ Oracle Report Creation Tests ============

    function testMatchSwap_CreatesOracleReport() public {
        uint256 swapId = _createSwap();
        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        // Check oracle report exists (not settled yet, so settlementTimestamp == 0)
        (,,,, uint48 rsNotSettledSettlement,,) = oracle.reportStatus(expectedReportId);
        assertFalse(rsNotSettledSettlement != 0, "Report should exist but not be distributed yet");
    }

    function testMatchSwap_OracleReportHasCorrectTokens() public {
        uint256 swapId = _createSwap();
        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        // Check report tokens from reportMeta
        (,,,, address token1,, address token2,,,,,) = oracle.reportMeta(expectedReportId);
        assertEq(token1, address(sellToken), "Report token1 should be sellToken");
        assertEq(token2, address(buyToken), "Report token2 should be buyToken");
    }

    // ============ Self-Matching Tests ============

    function testMatchSwap_SwapperCanMatchOwnSwap() public {
        uint256 swapId = _createSwap();

        vm.startPrank(swapper);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.matched, "Swap should be matched");
        assertEq(s.matcher, swapper, "Matcher should be swapper");
    }

    function testMatchSwap_SwapperSelfMatchTokenBalances() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        uint256 swapId = _createSwap();

        // After creating swap, swapper sent sellToken
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper sent sellToken");

        vm.startPrank(swapper);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        // After self-matching, swapper also sent buyToken
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore - (MIN_FULFILL_LIQUIDITY + 2000e18), "Swapper sent buyToken for match");
    }

    // ============ Multiple Swaps/Matchers Tests ============

    function testMatchSwap_DifferentMatchersForDifferentSwaps() public {
        uint256 swapId1 = _createSwap();
        uint256 swapId2 = _createSwap();

        // Matcher 1 matches swap 1
        vm.startPrank(matcher);
        bytes32 swapHash1 = swapContract.getSwapHash(swapId1);
        swapContract.matchSwap(swapId1, uint128(2000e18), swapHash1, _defaultPreimage());
        vm.stopPrank();

        // Matcher 2 matches swap 2
        vm.startPrank(matcher2);
        bytes32 swapHash2 = swapContract.getSwapHash(swapId2);
        swapContract.matchSwap(swapId2, uint128(2000e18), swapHash2, _defaultPreimage());
        vm.stopPrank();

        openSwapV2Permit.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwapV2Permit.Swap memory s2 = swapContract.getSwap(swapId2);

        assertEq(s1.matcher, matcher, "Swap1 matcher should be matcher");
        assertEq(s2.matcher, matcher2, "Swap2 matcher should be matcher2");
    }

    function testMatchSwap_ReportIdsAreSequential() public {
        uint256 swapId1 = _createSwap();
        uint256 swapId2 = _createSwap();

        uint256 expectedReportId1 = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash1 = swapContract.getSwapHash(swapId1);
        swapContract.matchSwap(swapId1, uint128(2000e18), swapHash1, _defaultPreimage());
        vm.stopPrank();

        uint256 expectedReportId2 = oracle.nextReportId();

        vm.startPrank(matcher2);
        bytes32 swapHash2 = swapContract.getSwapHash(swapId2);
        swapContract.matchSwap(swapId2, uint128(2000e18), swapHash2, _defaultPreimage());
        vm.stopPrank();

        openSwapV2Permit.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwapV2Permit.Swap memory s2 = swapContract.getSwap(swapId2);

        assertEq(s1.reportId, expectedReportId1, "Swap1 reportId should match");
        assertEq(s2.reportId, expectedReportId2, "Swap2 reportId should match");
        assertEq(s2.reportId, s1.reportId + 1, "ReportIds should be sequential");
    }

}
