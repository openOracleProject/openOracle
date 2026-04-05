// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";
import "../../src/interfaces/IWETH.sol";

/**
 * @title OpenSwapETHTest
 * @notice Tests for native ETH swaps (sellToken or buyToken = address(0))
 */
contract OpenSwapETHTest is Test {
    OpenOracle internal oracle;
    openSwapV2Permit internal swapContract;
    MockERC20 internal token;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal initialReporter = address(0x3);
    address internal settler = address(0x4);

    address constant OP = 0x4200000000000000000000000000000000000042;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    // Oracle params
    uint88 constant SETTLER_REWARD = 0.001 ether;
    uint128 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant PROTOCOL_FEE = 1000;
    uint24 constant MAX_GAME_TIME = 7200;

    // Swap params
    uint128 constant SELL_AMT = 1 ether;
    uint128 constant MIN_OUT = 1e18;
    uint128 constant MIN_FULFILL_LIQUIDITY = 2500e18;
    uint96 constant GAS_COMPENSATION = 0.001 ether;

    // FulfillFeeParams
    uint24 constant MAX_FEE = 10000;
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000;
    uint16 constant MAX_ROUNDS = 10;

    function setUp() public {
        // Deploy mock tokens and use vm.etch to put them at mainnet addresses
        vm.etch(OP, address(new MockERC20("Optimism", "OP")).code);
        vm.etch(WETH, address(new MockERC20("WETH", "WETH")).code);
        vm.etch(USDC, address(new MockERC20("USD Coin", "USDC")).code);

        oracle = new OpenOracle();
        swapContract = new openSwapV2Permit(address(oracle));


        token = new MockERC20("Token", "TKN");

        // Fund participants
        token.transfer(swapper, 100e18);
        token.transfer(matcher, 100_000e18);
        token.transfer(initialReporter, 100_000e18);

        // Give reporter mock WETH tokens using deal (sets balance directly)
        deal(WETH, initialReporter, 10e18);
        // Give matcher WETH for oracle game participation in ETH flows
        // Needs enough for amount2 (2000e18) pulled as WETH when buyToken=address(0)
        deal(WETH, matcher, 10000e18);

        vm.deal(swapper, 100 ether);
        vm.deal(matcher, 100 ether);
        vm.deal(initialReporter, 10 ether);
        vm.deal(settler, 1 ether);

        // Approvals
        vm.prank(swapper);
        token.approve(address(swapContract), type(uint256).max);

        vm.startPrank(matcher);
        token.approve(address(swapContract), type(uint256).max);
        MockERC20(WETH).approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(initialReporter);
        // Need WETH approval for oracle game
        IERC20(WETH).approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    function _getOracleParams() internal pure returns (openSwapV2Permit.OracleParams memory) {
        return openSwapV2Permit.OracleParams({
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
    }

    function _getSlippageParams() internal pure returns (openSwapV2Permit.SlippageParams memory) {
        return openSwapV2Permit.SlippageParams({
            priceTolerated: 5e14,
            toleranceRange: 1e7 - 1
        });
    }

    function _getFulfillFeeParams() internal pure returns (openSwapV2Permit.FulfillFeeParams memory) {
        return openSwapV2Permit.FulfillFeeParams({
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
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


    // ============ ETH → ERC20 Tests ============

    function testETHToToken_CreateSwap() public {
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = SELL_AMT + GAS_COMPENSATION + SETTLER_REWARD;

        vm.startPrank(swapper);

        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(0), // sellToken = ETH
            MIN_OUT,
            address(token),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );

        vm.stopPrank();

        // Verify ETH transferred
        assertEq(swapper.balance, swapperEthBefore - ethToSend, "Swapper should have sent ETH");
        // Contract holds sellAmt + bounty + settlerReward + gasComp + 1 (bounty forwarded on match)
        assertEq(address(swapContract).balance, ethToSend, "Contract should hold all ETH until match");

        // Verify swap state
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.sellToken, address(0), "sellToken should be address(0)");
        assertEq(s.sellAmt, SELL_AMT, "sellAmt should match");
        assertEq(s.buyToken, address(token), "buyToken should be token");
        assertTrue(s.active, "Swap should be active");
    }

    function testETHToToken_FullFlow() public {
        uint256 swapperTokenBefore = token.balanceOf(swapper);
        uint256 matcherTokenBefore = token.balanceOf(matcher);
        uint256 matcherEthBefore = matcher.balance;
        uint256 ethToSend = SELL_AMT + GAS_COMPENSATION + SETTLER_REWARD;

        // Create swap: ETH → Token
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(0),
            MIN_OUT,
            address(token),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();

        // Match swap
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        // Verify matcher sent tokens (minFulfillLiquidity + amount2, amount2 goes to oracle)
        assertEq(token.balanceOf(matcher), matcherTokenBefore - (MIN_FULFILL_LIQUIDITY + 2000e18), "Matcher should have sent tokens");

        // Submit report and settle
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        (bytes32 stateHash,,,,,,) = oracle.extraData(s.reportId);

        // Reporter already has mock WETH from setUp, just submit report
        // Report: 1 WETH = 2000 tokens (amount1=WETH, amount2=token)
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(s.reportId);

        // Verify swap completed
        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished");

        // Calculate expected fulfillAmt (uses startingFee since matched immediately)
        uint256 fulfillAmt = (uint256(SELL_AMT) * 2000e18) / INITIAL_LIQUIDITY;
        fulfillAmt -= fulfillAmt * STARTING_FEE / 1e7;

        // Swapper should have received tokens (initial balance + fulfillAmt)
        assertEq(token.balanceOf(swapper), swapperTokenBefore + fulfillAmt, "Swapper should have received tokens");

        // Matcher should have received ETH (sellAmt + gasCompensation)
        // Note: matcher is address(0x2) which is the sha256 precompile; oracle settle sends 1 wei to it as part of distribution
        assertEq(matcher.balance, matcherEthBefore + SELL_AMT + GAS_COMPENSATION, "Matcher should have received ETH + gasComp");
    }

    function testETHToToken_Cancel() public {
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = SELL_AMT + GAS_COMPENSATION + SETTLER_REWARD;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(0),
            MIN_OUT,
            address(token),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );

        // Cancel
        swapContract.cancelSwap(swapId);
        vm.stopPrank();

        // Verify ETH returned
        assertEq(swapper.balance, swapperEthBefore, "Swapper should have all ETH back");
        assertEq(address(swapContract).balance, 0, "Contract should have no ETH");
    }

    // ============ ERC20 → ETH Tests ============

    function testTokenToETH_CreateSwap() public {
        uint256 swapperTokenBefore = token.balanceOf(swapper);
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        vm.startPrank(swapper);

        uint256 swapId = swapContract.swap{value: ethToSend}(
            uint128(10e18), // sellAmt in tokens
            address(token), // sellToken = token
            uint128(1e17), // minOut in ETH (0.1 ETH)
            address(0), // buyToken = ETH
            uint128(1 ether), // minFulfillLiquidity in ETH
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );

        vm.stopPrank();

        // Verify tokens transferred
        assertEq(token.balanceOf(swapper), swapperTokenBefore - 10e18, "Swapper should have sent tokens");
        assertEq(token.balanceOf(address(swapContract)), 10e18, "Contract should hold tokens");

        // Verify swap state
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.sellToken, address(token), "sellToken should be token");
        assertEq(s.buyToken, address(0), "buyToken should be address(0)");
    }

    function testTokenToETH_MatchWithETH() public {
        uint256 matcherEthBefore = matcher.balance;
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;
        uint256 minFulfillETH = 1 ether;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            uint128(10e18),
            address(token),
            uint128(1e17),
            address(0),
            uint128(minFulfillETH),
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();

        // Match with ETH
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap{value: minFulfillETH}(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        // Verify matcher sent ETH (minus gasCompensation they receive)
        assertEq(matcher.balance, matcherEthBefore - minFulfillETH + GAS_COMPENSATION, "Matcher should have sent ETH (minus gasComp received)");

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.matched, "Swap should be matched");
        assertEq(s.matcher, matcher, "Matcher should be set");
    }

    function testTokenToETH_FullFlow() public {
        uint256 matcherTokenBefore = token.balanceOf(matcher);
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;
        uint256 minFulfillETH = 1 ether;
        uint256 sellAmtTokens = 10e18;

        // Create swap: Token → ETH
        // Oracle price = amount1 * 1e18 / amount2 = 1e18 * 1e18 / 5e16 = 2e19
        // (initial report: amount1=initialLiquidity=1e18 token, amount2=5e16 WETH)
        openSwapV2Permit.SlippageParams memory slippageParams = openSwapV2Permit.SlippageParams({
            priceTolerated: 2e19,
            toleranceRange: 1e7 - 1
        });
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            uint128(sellAmtTokens),
            address(token),
            uint128(1e17), // minOut
            address(0),
            uint128(minFulfillETH),
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            slippageParams,
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();

        uint256 swapperEthAfterCreate = swapper.balance;

        // Match with ETH; amount2=5e16 WETH (0.05 WETH per token oracle price)
        // oracle: amount1=initialLiquidity=1e18 token, amount2=5e16 WETH → price=1e18*1e9/5e16=2e10
        uint256 amount2 = 5e16;
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap{value: minFulfillETH}(swapId, uint128(amount2), swapHash, _defaultPreimage());
        vm.stopPrank();

        // Submit report and settle
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        (bytes32 stateHash,,,,,,) = oracle.extraData(s.reportId);

        // Report: 1 token = 0.05 ETH (so 10 tokens = 0.5 ETH)
        // token1 = token, token2 = WETH
        // amount1 = 1e18 (token), amount2 = 5e16 (0.05 WETH)
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        vm.prank(settler);
        oracle.settle(s.reportId);

        // Verify swap completed
        openSwapV2Permit.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished");

        // Calculate expected fulfillAmt in ETH (uses startingFee since matched immediately)
        uint256 fulfillAmt = (sellAmtTokens * amount2) / INITIAL_LIQUIDITY;
        fulfillAmt -= fulfillAmt * STARTING_FEE / 1e7;

        // Swapper should have received ETH (fulfillAmt)
        assertEq(swapper.balance, swapperEthAfterCreate + fulfillAmt, "Swapper should have received ETH");

        // Matcher should have received tokens
        assertEq(token.balanceOf(matcher), matcherTokenBefore + sellAmtTokens, "Matcher should have received tokens");
    }

    // ============ ETH msg.value Validation Tests ============

    function testETHToToken_WrongMsgValue_Reverts() public {
        uint256 ethToSend = SELL_AMT + GAS_COMPENSATION + SETTLER_REWARD;

        vm.startPrank(swapper);

        // Send wrong amount (missing sellAmt)
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "msg.value vs sellAmt mismatch"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            address(0),
            MIN_OUT,
            address(token),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );

        vm.stopPrank();
    }

    function testTokenToETH_MatchWrongMsgValue_Reverts() public {
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;
        uint256 minFulfillETH = 1 ether;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            uint128(10e18),
            address(token),
            uint128(1e17),
            address(0),
            uint128(minFulfillETH),
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();

        // Match with wrong ETH amount
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);

        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "msg.value"));
        swapContract.matchSwap{value: minFulfillETH - 1}(swapId, uint128(2000e18), swapHash, _defaultPreimage());

        vm.stopPrank();
    }

    function testTokenToToken_MatchWithETH_Reverts() public {
        // Create ERC20 → ERC20 swap
        MockERC20 otherToken = new MockERC20("Other", "OTH");
        otherToken.transfer(matcher, 100_000e18);

        vm.prank(matcher);
        otherToken.approve(address(swapContract), type(uint256).max);

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            uint128(10e18),
            address(token),
            uint128(1e18),
            address(otherToken),
            uint128(100e18),
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();

        // Try to match with ETH (should fail since buyToken is not ETH)
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);

        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "msg.value must be 0"));
        swapContract.matchSwap{value: 1 ether}(swapId, uint128(2000e18), swapHash, _defaultPreimage());

        vm.stopPrank();
    }

    // ============ BailOut with ETH Tests ============

    function testETHToToken_BailOut() public {
        uint256 matcherTokenBefore = token.balanceOf(matcher);
        uint256 ethToSend = SELL_AMT + GAS_COMPENSATION + SETTLER_REWARD;

        // Create and match
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(0),
            MIN_OUT,
            address(token),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();

        uint256 swapperEthAfterCreate = swapper.balance;

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        // Warp past latency bailout
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);
        swapContract.bailOut(swapId);

        // Verify swap finished
        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Swapper gets sellAmt ETH back
        assertEq(swapper.balance, swapperEthAfterCreate + SELL_AMT, "Swapper should have sellAmt ETH back");
        // Matcher gets minFulfillLiquidity tokens back; amount2 (2000e18) remains in oracle on bailout
        assertEq(token.balanceOf(matcher), matcherTokenBefore - 2000e18, "Matcher should have tokens back minus amount2 in oracle");
    }

    function testTokenToETH_BailOut() public {
        uint256 swapperTokenBefore = token.balanceOf(swapper);
        uint256 matcherEthBefore = matcher.balance;
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;
        uint256 minFulfillETH = 1 ether;

        // Create and match
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            uint128(10e18),
            address(token),
            uint128(1e17),
            address(0),
            uint128(minFulfillETH),
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap{value: minFulfillETH}(swapId, uint128(2000e18), swapHash, _defaultPreimage());
        vm.stopPrank();

        // Warp past latency bailout
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);
        swapContract.bailOut(swapId);

        // Verify refunds (matcher also received gasCompensation at match time)
        assertEq(token.balanceOf(swapper), swapperTokenBefore, "Swapper should have tokens back");
        assertEq(matcher.balance, matcherEthBefore + GAS_COMPENSATION, "Matcher should have ETH back + gasComp");
    }
}
