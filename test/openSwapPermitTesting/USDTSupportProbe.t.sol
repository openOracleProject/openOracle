// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "../utils/MockERC20.sol";
import "../utils/USDTStyleToken.sol";

/// @title USDTSupportProbe
/// @notice Regression guard for the documented "USDT-style" token support claim.
///
/// USDT-style tokens omit the bool return value on approve/transfer/transferFrom.
/// Solidity 0.8.x's high-level `IERC20(token).approve(...)` ABI-decodes the
/// declared bool return and reverts when the token returns 0 bytes.
/// _ensureOracleApproval must therefore use SafeERC20.forceApprove (not the
/// high-level approve) so that matchSwap can complete for USDT-style tokens
/// on either side of the trade.
contract USDTSupportProbe is Test {
    OpenOracle internal oracle;
    openSwapV2Permit internal swapContract;
    USDTStyleToken internal usdt;
    MockERC20 internal vanilla;

    address constant WETH = 0x4200000000000000000000000000000000000006;

    address swapper = address(0x1);
    address matcher = address(0x2);

    // Sized to match the proven-good numerology used by the existing happy-path tests.
    uint88 constant SETTLER_REWARD = 0.001 ether;
    uint128 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant MAX_GAME_TIME = 7200;
    uint128 constant SELL_AMT = 10e18;
    uint128 constant MIN_OUT = 1e18;
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint96 constant GAS_COMPENSATION = 0.001 ether;
    uint24 constant MAX_FEE = 10000;
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000;
    uint16 constant MAX_ROUNDS = 10;

    function setUp() public {
        vm.etch(WETH, address(new MockERC20("Wrapped Ether", "WETH")).code);

        oracle = new OpenOracle();
        swapContract = new openSwapV2Permit(address(oracle));

        usdt = new USDTStyleToken(1_000_000e18);
        vanilla = new MockERC20("Vanilla", "VAN");

        usdt.transfer(swapper, 100e18);
        // Matcher needs enough USDT to cover the buyToken=USDT case
        // (MIN_FULFILL_LIQUIDITY + amount2 = 27000e18 plus initialLiquidity for the sellToken=USDT case).
        usdt.transfer(matcher, 100_000e18);
        vanilla.transfer(swapper, 100e18);
        vanilla.transfer(matcher, 100_000e18);

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);

        vm.startPrank(swapper);
        usdt.approve(address(swapContract), type(uint256).max);
        vanilla.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(matcher);
        usdt.approve(address(swapContract), type(uint256).max);
        vanilla.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();
    }

    function _oracleParams() internal pure returns (openSwapV2Permit.OracleParams memory) {
        return openSwapV2Permit.OracleParams({
            settlerReward: SETTLER_REWARD,
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            maxGameTime: MAX_GAME_TIME,
            blocksPerSecond: 500,
            disputeDelay: DISPUTE_DELAY,
            protocolFee: 0,
            multiplier: 110,
            timeType: true
        });
    }

    function _slippageParams() internal pure returns (openSwapV2Permit.SlippageParams memory) {
        return openSwapV2Permit.SlippageParams({priceTolerated: 5e26, toleranceRange: 1e7 - 1});
    }

    function _fulfillFeeParams() internal pure returns (openSwapV2Permit.FulfillFeeParams memory) {
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
            protocolFee: 0,
            multiplier: 110,
            timeType: true,
            startFulfillFeeIncrease: uint48(1),
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
    }

    function _runMatchAgainstPair(address sellToken, address buyToken) internal returns (uint256 swapId) {
        vm.prank(swapper);
        swapId = swapContract.swap{value: GAS_COMPENSATION + SETTLER_REWARD}(
            SELL_AMT,
            sellToken,
            MIN_OUT,
            buyToken,
            MIN_FULFILL_LIQUIDITY,
            uint48(block.timestamp + 1 hours),
            GAS_COMPENSATION,
            _oracleParams(),
            _slippageParams(),
            _fulfillFeeParams(),
            openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0))
        );

        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.prank(matcher);
        swapContract.matchSwap(swapId, 2000e18, swapHash, _defaultPreimage());
    }

    function testMatchSwap_USDTAsSellToken() public {
        // Without forceApprove, this would revert at _ensureOracleApproval(usdt) when
        // Solidity tries to ABI-decode bool from USDT's empty approve return data.
        uint256 swapId = _runMatchAgainstPair(address(usdt), address(vanilla));

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.matched, "matchSwap must succeed when sellToken is USDT-style");
        assertGt(s.reportId, 0, "report should be created");
    }

    function testMatchSwap_USDTAsBuyToken() public {
        // Same approval issue, but on the buyToken side.
        uint256 swapId = _runMatchAgainstPair(address(vanilla), address(usdt));

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.matched, "matchSwap must succeed when buyToken is USDT-style");
        assertGt(s.reportId, 0, "report should be created");
    }

    function testMatchSwap_USDTOnBothSides() public {
        // Belt-and-braces: both legs need forceApprove. (Note: contract rejects
        // sellToken==buyToken, so we use two distinct USDT-style instances.)
        USDTStyleToken usdt2 = new USDTStyleToken(1_000_000e18);
        usdt2.transfer(swapper, 100e18);
        usdt2.transfer(matcher, 100_000e18);
        vm.startPrank(swapper);
        usdt2.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(matcher);
        usdt2.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        uint256 swapId = _runMatchAgainstPair(address(usdt), address(usdt2));

        openSwapV2Permit.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.matched, "matchSwap must succeed when both sides are USDT-style");
        assertGt(s.reportId, 0, "report should be created");
    }
}
