// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapInputValidationTest
 * @notice Tests for swap() and matchSwap() input validations
 */
contract OpenSwapInputValidationTest is Test {
    OpenOracle internal oracle;
    openSwapV2Permit internal swapContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);

    address constant OP = 0x4200000000000000000000000000000000000042;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    uint96 constant SETTLER_REWARD = 0.001 ether;
    uint128 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant PROTOCOL_FEE = 1000;
    uint24 constant MAX_GAME_TIME = 7200;

    uint128 constant SELL_AMT = 10e18;
    uint128 constant MIN_OUT = 19000e18;
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint96 constant GAS_COMPENSATION = 0.001 ether;

    // FulfillFeeParams
    uint24 constant MAX_FEE = 10000;
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000;
    uint16 constant MAX_ROUNDS = 10;

    function setUp() public {
        // Mock OP, WETH, USDC
        vm.etch(OP, address(new MockERC20("Optimism", "OP")).code);
        vm.etch(WETH, address(new MockERC20("WETH", "WETH")).code);
        vm.etch(USDC, address(new MockERC20("USD Coin", "USDC")).code);

        oracle = new OpenOracle();
        swapContract = new openSwapV2Permit(address(oracle));


        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new MockERC20("BuyToken", "BUY");

        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(matcher, 100e18);
        buyToken.transfer(matcher, 100_000e18);

        vm.deal(swapper, 100 ether);
        vm.deal(matcher, 100 ether);

        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.startPrank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);
        sellToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();
    }

    function _validOracleParams() internal pure returns (openSwapV2Permit.OracleParams memory) {
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

    function _validSlippageParams() internal pure returns (openSwapV2Permit.SlippageParams memory) {
        return openSwapV2Permit.SlippageParams({priceTolerated: 5e14, toleranceRange: 1e7 - 1});
    }

    function _validFulfillFeeParams() internal pure returns (openSwapV2Permit.FulfillFeeParams memory) {
        return openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
    }


    // ============ swap() Token Validation Tests ============

    function testSwap_SellTokenEqualsBuyToken_Reverts() public {
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "sellToken = buyToken"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(sellToken), // same as sellToken
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_WETHSellETHBuy_Reverts() public {
        // Give swapper WETH tokens and approve
        deal(WETH, swapper, 100e18);
        vm.prank(swapper);
        IERC20(WETH).approve(address(swapContract), type(uint256).max);

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "sellToken = buyToken"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            WETH,
            MIN_OUT,
            address(0), // ETH
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_ETHSellWETHBuy_Reverts() public {
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "sellToken = buyToken"));
        swapContract.swap{value: SELL_AMT + GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            address(0), // ETH
            MIN_OUT,
            WETH,
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    // ============ swap() Zero Amount Tests ============

    function testSwap_ZeroSellAmt_Reverts() public {
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "zero amounts"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            0, // zero sellAmt
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_ZeroMinOut_Reverts() public {
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "zero amounts"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            address(sellToken),
            0, // zero minOut
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_ZeroMinFulfillLiquidity_Reverts() public {
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "zero amounts"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            0, // zero minFulfillLiquidity
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    // ============ swap() FulfillFeeParams Tests ============

    function testSwap_MaxFeeTooHigh_Reverts() public {
        openSwapV2Permit.FulfillFeeParams memory badFeeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: uint24(1e7), // maxFee >= 1e7
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "fulfillmentFee"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            badFeeParams,
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_MaxFeeAtBoundary_Reverts() public {
        openSwapV2Permit.FulfillFeeParams memory badFeeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: uint24(1e7), // Exactly 1e7 should revert
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "fulfillmentFee"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            badFeeParams,
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_MaxFeeBelowBoundary_Succeeds() public {
        openSwapV2Permit.FulfillFeeParams memory goodFeeParams = openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: uint24(1e7 - 1), // 1e7 - 1 should work
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            goodFeeParams,
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        assertGt(swapId, 0, "Swap should be created");
        vm.stopPrank();
    }

    // ============ swap() OracleParams Tests ============

    function testSwap_SettlerRewardTooLow_Reverts() public {
        openSwapV2Permit.OracleParams memory params = _validOracleParams();
        params.settlerReward = 99; // < 100

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + 99}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    // V2: swapFee removed (hardcoded to 1 in oracle game)

    function testSwap_SettlementTimeZero_Reverts() public {
        openSwapV2Permit.OracleParams memory params = _validOracleParams();
        params.settlementTime = 0;

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_InitialLiquidityZero_Reverts() public {
        openSwapV2Permit.OracleParams memory params = _validOracleParams();
        params.initialLiquidity = 0;

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_DisputeDelayGteSettlementTime_Reverts() public {
        openSwapV2Permit.OracleParams memory params = _validOracleParams();
        params.disputeDelay = uint24(params.settlementTime); // disputeDelay >= settlementTime

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_EscalationHaltLtInitialLiquidity_Reverts() public {
        openSwapV2Permit.OracleParams memory params = _validOracleParams();
        params.escalationHalt = params.initialLiquidity - 1; // escalationHalt < initialLiquidity

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_SettlementTimeTooLong_Reverts() public {
        openSwapV2Permit.OracleParams memory params = _validOracleParams();
        params.settlementTime = 4 * 60 * 60 + 1; // > 4 hours

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    function testSwap_ProtocolFeeTooHigh_Reverts() public {
        openSwapV2Permit.OracleParams memory params = _validOracleParams();
        params.protocolFee = uint24(1e7); // protocolFee >= 1e7

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
    }

    // ============ matchSwap() Validation Tests ============

    function testMatchSwap_ParamHashMismatch_Reverts() public {
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _validOracleParams(), _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();

        vm.startPrank(matcher);
        bytes32 wrongHash = keccak256("wrong");
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "params"));
        swapContract.matchSwap(swapId, uint128(2000e18), wrongHash);
        vm.stopPrank();
    }

    function testMatchSwap_Expired_Reverts() public {
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _validOracleParams(), _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();

        // Warp past expiration
        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 1 hours);

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "expired"));
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash);
        vm.stopPrank();
    }

    function testMatchSwap_AlreadyMatched_Reverts() public {
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _validOracleParams(), _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();

        // First match succeeds
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash);

        // Second match fails - need to get new hash since swap state changed
        bytes32 newSwapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "swap matched"));
        swapContract.matchSwap(swapId, uint128(2000e18), newSwapHash);
        vm.stopPrank();
    }

    function testMatchSwap_Cancelled_Reverts() public {
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, uint48(block.timestamp + 1 hours), GAS_COMPENSATION,
            _validOracleParams(), _validSlippageParams(), _validFulfillFeeParams(), openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );
        swapContract.cancelSwap(swapId);
        vm.stopPrank();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "swap cancelled"));
        swapContract.matchSwap(swapId, uint128(2000e18), swapHash);
        vm.stopPrank();
    }

    function testMatchSwap_NotActive_Reverts() public {
        vm.startPrank(matcher);
        bytes32 fakeHash = keccak256(abi.encode(swapContract.getSwap(999)));
        vm.expectRevert(abi.encodeWithSelector(openSwapV2Permit.InvalidInput.selector, "swap not active"));
        swapContract.matchSwap(999, uint128(2000e18), fakeHash);
        vm.stopPrank();
    }
}
