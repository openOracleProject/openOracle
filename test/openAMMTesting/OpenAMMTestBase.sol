// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {openAMM} from "../../src/openAMM.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";
import {WETH9} from "./WETH9.sol";
import {MockERC20Decimals} from "./MockERC20Decimals.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Integration base: real OpenOracle + real WETH9 + real openAMM.
abstract contract OpenAMMTestBase is Test {
    address constant WETH_ADDR = 0x4200000000000000000000000000000000000006;
    uint256 constant FEE_DENOMINATOR = 10_000_000;

    WETH9 internal weth;
    OpenOracle internal oracle;
    MockERC20Decimals internal usdc; // the AMM's token1

    /// @dev Override to model 6-decimal USDC.
    function _usdcDecimals() internal view virtual returns (uint8) {
        return 18;
    }
    openAMM internal amm;

    address internal owner = address(0xA0);
    address internal trader = address(0xB0);
    address internal recipient = address(0xC0);
    address internal disputer = address(0xD0);

    // Default oracle-game / quote params
    uint128 constant INIT_LIQUIDITY = 1e18; // currentAmount1 (ETH side)
    uint128 internal AMOUNT2; // currentAmount2 (USDC side) -> 4000 USDC / ETH, set in setUp per token decimals
    uint128 constant ESCALATION_HALT = 100e18;
    uint88 constant SETTLER_REWARD = 0.001 ether;
    uint48 constant SETTLEMENT_TIME = 20;
    uint48 constant EXECUTION_DELAY = 5;
    uint24 constant DISPUTE_DELAY = 2;
    uint16 constant MULTIPLIER = 110;

    // Captured at each _quote so disputes can rebuild the stored state hash.
    uint48 internal qTs;
    uint48 internal qBn;

    function setUp() public virtual {
        vm.warp(1_000);
        vm.roll(100);

        WETH9 wethImpl = new WETH9();
        vm.etch(WETH_ADDR, address(wethImpl).code);
        weth = WETH9(payable(WETH_ADDR));

        uint8 dec = _usdcDecimals();
        AMOUNT2 = uint128(4000 * (10 ** dec)); // 4000 USDC / ETH

        oracle = new OpenOracle();
        usdc = new MockERC20Decimals("USD Coin", "USDC", dec); // minted to this test contract
        amm = new openAMM(owner, address(oracle), address(usdc));

        // Owner one-time setup so the AMM can deposit token1 (USDC) into the oracle.
        vm.prank(owner);
        amm.oracleApproval(address(usdc));

        // This test contract funds AMM inventory; approve oracle to pull USDC from it.
        usdc.approve(address(oracle), type(uint256).max);

        // Owner liquidity that backs each report's escrow. report() is called by the AMM with
        // currentReporter = owner and tryInternalBalance = true, so the funding is a delegated
        // draw from owner's internal balance via the AMM's allowance.
        uint256 ownerUsdc = 100_000 * (10 ** dec);
        vm.deal(owner, 100 ether);
        usdc.transfer(owner, ownerUsdc);
        vm.startPrank(owner);
        oracle.deposit{value: 50 ether}(address(0), 50 ether, owner);
        usdc.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(usdc), uint128(ownerUsdc), owner);
        oracle.approveInternal(address(amm), address(0), type(uint256).max);
        oracle.approveInternal(address(amm), address(usdc), type(uint256).max);
        vm.stopPrank();
    }

    // ── param builders ──────────────────────────────────────────────────

    function _defaultParams() internal pure returns (openAMM.OracleParams memory) {
        return openAMM.OracleParams({
            initialLiquidity: INIT_LIQUIDITY,
            escalationHalt: ESCALATION_HALT,
            settlerReward: SETTLER_REWARD,
            settlementTime: SETTLEMENT_TIME,
            disputeDelay: DISPUTE_DELAY,
            multiplier: MULTIPLIER
        });
    }

    function _emptyTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory) {
        return IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
    }

    function _pathWethUsdc() internal view returns (address[] memory p) {
        p = new address[](2);
        p[0] = WETH_ADDR;
        p[1] = address(usdc);
    }

    function _pathUsdcWeth() internal view returns (address[] memory p) {
        p = new address[](2);
        p[0] = address(usdc);
        p[1] = WETH_ADDR;
    }

    // ── flow helpers ────────────────────────────────────────────────────

    function _quote(uint48 executionDelay, uint24 fee, uint128 amount2) internal returns (uint256 reportId) {
        reportId = oracle.nextReportId();
        qTs = uint48(block.timestamp);
        qBn = uint48(block.number);
        vm.prank(owner);
        amm.quote{value: SETTLER_REWARD}(_defaultParams(), _emptyTiming(), amount2, executionDelay, fee);
    }

    function _quoteDefault() internal returns (uint256 reportId) {
        reportId = _quote(EXECUTION_DELAY, 0, AMOUNT2);
    }

    /// @dev OracleGame with the mutable (per report/dispute) fields supplied; everything else fixed
    ///      to what the AMM committed. lastReportOppoTime == block.number (we never roll), == qBn.
    function _gameWith(uint128 a1, uint128 a2, address reporter, uint48 reportTs, uint24 numReports)
        internal
        view
        returns (IOpenOracle2.OracleGame memory g)
    {
        g = IOpenOracle2.OracleGame({
            currentAmount1: a1,
            currentAmount2: a2,
            currentReporter: reporter,
            reportTimestamp: reportTs,
            settlementTimestamp: 0,
            token1: address(0),
            lastReportOppoTime: qBn,
            settlementTime: SETTLEMENT_TIME,
            escalationHalt: ESCALATION_HALT,
            protocolFeeRecipient: address(0),
            settlerReward: SETTLER_REWARD,
            token2: address(usdc),
            numReports: numReports,
            disputeDelay: DISPUTE_DELAY,
            feePercentage: 0,
            multiplier: MULTIPLIER,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: 0,
            flags: 3
        });
    }

    /// @dev OracleGame exactly as report() stored it for the default quote (pre-dispute).
    function _storedGame() internal view returns (IOpenOracle2.OracleGame memory) {
        // report() overrides numReports to 1 when dispute-tracking is on.
        return _gameWith(INIT_LIQUIDITY, AMOUNT2, owner, qTs, 1);
    }

    function _storedHelper(uint256 reportId) internal view returns (IOpenOracle2.PreimageHelper memory) {
        return IOpenOracle2.PreimageHelper({
            reportId: reportId,
            creator: address(amm),
            blockTimestamp: qTs,
            blockNumber: qBn
        });
    }

    /// @dev Real first dispute on the default quote: disputer swaps token2 (USDC), escalating
    ///      amount1 by the multiplier and quoting (newA1, newA2). Returns the dispute timestamp.
    function _disputeUsdc(uint256 reportId, uint128 newA1, uint128 newA2) internal returns (uint48 dts) {
        uint256 usdcNeed = uint256(newA2) + AMOUNT2; // newAmount2 + oldAmount2
        usdc.transfer(disputer, usdcNeed);
        vm.deal(disputer, 1 ether);
        vm.prank(disputer);
        usdc.approve(address(oracle), type(uint256).max);

        dts = qTs + DISPUTE_DELAY + 1;
        vm.warp(dts);

        uint256 ethNeed = newA1 > INIT_LIQUIDITY ? uint256(newA1) - INIT_LIQUIDITY : 0;
        vm.prank(disputer);
        IOpenOracle2(address(oracle)).dispute{value: ethNeed}(
            reportId,
            address(usdc),
            newA1,
            newA2,
            disputer,
            false,
            false,
            _storedGame(),
            _storedHelper(reportId),
            _emptyTiming()
        );
    }

    function _multiplierUp(uint128 amount1) internal pure returns (uint128) {
        return uint128(uint256(amount1) * MULTIPLIER / 100);
    }

    // ── inventory funding (real oracle deposits to the AMM) ─────────────

    function _fundAmmUsdc(uint256 amount) internal {
        oracle.deposit(address(usdc), uint128(amount), address(amm));
    }

    function _fundAmmEth(uint256 amount) internal {
        vm.deal(address(this), address(this).balance + amount);
        oracle.deposit{value: amount}(address(0), uint128(amount), address(amm));
    }

    function _giveTraderWeth(address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.startPrank(who);
        weth.deposit{value: amount}();
        weth.approve(address(amm), type(uint256).max);
        vm.stopPrank();
    }

    function _giveTraderUsdc(address who, uint256 amount) internal {
        usdc.transfer(who, amount);
        vm.prank(who);
        usdc.approve(address(amm), type(uint256).max);
    }

    // ── pricing oracles (mirror the contract math) ──────────────────────

    function _expectedOut(uint256 amountIn, bool zeroForOne, uint24 fee, uint128 a1, uint128 a2)
        internal
        pure
        returns (uint256)
    {
        uint256 afterFee = amountIn - Math.mulDiv(amountIn, fee, FEE_DENOMINATOR);
        return zeroForOne ? Math.mulDiv(afterFee, a2, a1) : Math.mulDiv(afterFee, a1, a2);
    }

    function _expectedIn(uint256 amountOut, bool zeroForOne, uint24 fee, uint128 a1, uint128 a2)
        internal
        pure
        returns (uint256)
    {
        uint256 rawIn = zeroForOne
            ? Math.mulDiv(amountOut, a1, a2, Math.Rounding.Ceil)
            : Math.mulDiv(amountOut, a2, a1, Math.Rounding.Ceil);
        if (fee == 0) return rawIn;
        return Math.mulDiv(rawIn, FEE_DENOMINATOR, FEE_DENOMINATOR - fee, Math.Rounding.Ceil);
    }

    receive() external payable {}
}
