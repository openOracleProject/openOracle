// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/openLend.sol";
import "../../src/openLendParamHashHelper.sol";
import "../../src/OpenOracleSlim.sol";
import "../../src/interfaces/IOpenOracle2.sol";
import "../utils/MockWETH.sol";

contract Usdc6Token is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UsdcEthIntegrationTest is Test {
    openLend internal lending;
    openLendParamHashHelper internal lendView;
    OpenOracle internal oracle;
    MockWETH internal weth;
    Usdc6Token internal usdc;

    address internal borrower = address(0xA01);
    address internal lender = address(0xA02);
    address internal lender2 = address(0xA03);
    address internal liquidator = address(0xA04);
    address internal disputer = address(0xA05);
    address internal finalizer = address(0xA06);

    uint128 internal constant USDC_SUPPLY = 100_000e6;
    uint128 internal constant ETH_BORROW = 50 ether;
    uint128 internal constant ETH_COLLATERAL = 100 ether;
    uint128 internal constant USDC_DEBT = 70_000e6;
    uint48 internal constant LOAN_TERM = 30 days;
    uint96 internal constant SETTLER_REWARD = 0.001 ether;

    function setUp() public {
        oracle = new OpenOracle();
        weth = new MockWETH();
        lending = new openLend(IOpenOracle2(address(oracle)), address(weth));
        lendView = new openLendParamHashHelper(lending, IOpenOracle2(address(oracle)));
        usdc = new Usdc6Token();

        usdc.mint(borrower, 10_000_000e6);
        usdc.mint(lender, 10_000_000e6);
        usdc.mint(lender2, 10_000_000e6);
        usdc.mint(liquidator, 10_000_000e6);
        usdc.mint(disputer, 10_000_000e6);

        vm.deal(borrower, 1_000 ether);
        vm.deal(lender, 1_000 ether);
        vm.deal(lender2, 1_000 ether);
        vm.deal(liquidator, 1_000 ether);
        vm.deal(disputer, 1_000 ether);
        vm.deal(finalizer, 1_000 ether);

        vm.prank(borrower);
        usdc.approve(address(lending), type(uint256).max);
        vm.prank(lender);
        usdc.approve(address(lending), type(uint256).max);
        vm.prank(lender2);
        usdc.approve(address(lending), type(uint256).max);
        vm.prank(liquidator);
        usdc.approve(address(lending), type(uint256).max);
        vm.prank(liquidator);
        usdc.approve(address(oracle), type(uint256).max);
        vm.prank(disputer);
        usdc.approve(address(oracle), type(uint256).max);
    }

    function testUsdcEth_RequestLendRepayUsesSixDecimalCollateralAndNativeDebt() public {
        uint256 borrowerEthBefore = borrower.balance;
        uint256 lenderEthBefore = lender.balance;
        uint256 lendingUsdcBefore = usdc.balanceOf(address(lending));

        uint256 lendingId = _requestUsdcEthLoan(USDC_SUPPLY, ETH_BORROW);

        vm.prank(lender);
        lending.lend{value: ETH_BORROW}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        openLend.LendingArrangement memory live = lendView.getLending(lendingId);
        assertEq(usdc.decimals(), 6);
        assertEq(live.supplyToken, address(usdc));
        assertEq(live.borrowToken, address(0));
        assertEq(live.supplyAmount, USDC_SUPPLY);
        assertEq(live.principal, ETH_BORROW);
        assertEq(borrower.balance, borrowerEthBefore + ETH_BORROW);
        assertEq(lender.balance, lenderEthBefore - ETH_BORROW);
        assertEq(usdc.balanceOf(address(lending)), lendingUsdcBefore + USDC_SUPPLY);

        vm.prank(borrower);
        lending.repayDebt{value: ETH_BORROW + 1 ether}(
            lendingId,
            ETH_BORROW + 1 ether,
            bytes32(0),
            0,
            type(uint128).max
        );

        openLend.LendingArrangement memory closed = lendView.getLending(lendingId);
        assertTrue(closed.finished);
        assertEq(borrower.balance, borrowerEthBefore);
        assertEq(lender.balance, lenderEthBefore);
        assertEq(usdc.balanceOf(borrower), 10_000_000e6);
    }

    function testUsdcEth_TopUpAndRefiSupplyPullUseSixDecimalBaseUnits() public {
        uint128 topUp = 1_250e6;
        uint128 supplyPulled = 2_500e6;
        uint128 extraDemanded = 1 ether;
        uint256 lendingId = _requestUsdcEthLoan(USDC_SUPPLY, ETH_BORROW);

        vm.prank(lender);
        lending.lend{value: ETH_BORROW}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        vm.prank(borrower);
        lending.topUpCollateral(lendingId, topUp, bytes32(0), 0, type(uint128).max);

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            extraDemanded,
            supplyPulled,
            0,
            0,
            _standardInterestRateParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);
        uint256 borrowerEthBefore = borrower.balance;
        uint256 lenderEthBefore = lender.balance;
        uint256 lender2EthBefore = lender2.balance;
        uint128 expectedPrePullSupply = USDC_SUPPLY + topUp;
        uint128 expectedPostPullSupply = expectedPrePullSupply - supplyPulled;
        bytes32 paramHash = lendView.getParamHash(lendingId);

        vm.prank(lender2);
        lending.lend{value: uint256(ETH_BORROW) + extraDemanded}(
            lendingId,
            paramHash,
            0,
            type(uint128).max,
            expectedPrePullSupply,
            0,
            0,
            lender2
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.supplyAmount, expectedPostPullSupply);
        assertEq(loan.principal, uint256(ETH_BORROW) + extraDemanded);
        assertEq(loan.lender, lender2);
        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore + supplyPulled);
        assertEq(borrower.balance, borrowerEthBefore + extraDemanded);
        assertEq(lender.balance, lenderEthBefore + ETH_BORROW);
        assertEq(lender2.balance, lender2EthBefore - uint256(ETH_BORROW) - extraDemanded);
    }

    function testUsdcEth_LiquidationReportStoresUsdcToken1AndNativeEthToken2() public {
        uint256 lendingId = _originateUsdcEthLoan();
        uint256 oracleAmount2 = 6 ether;
        uint256 initialLiquidity = uint256(USDC_SUPPLY) * 10 / 100;
        uint256 tokenStake = uint256(USDC_SUPPLY) * 100 / 10000;

        uint256 liquidatorUsdcBefore = usdc.balanceOf(liquidator);
        uint256 liquidatorEthBefore = liquidator.balance;
        uint256 reportId = _liquidate(lendingId, oracleAmount2);

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        assertEq(game.token1, address(usdc));
        assertEq(game.token2, address(0));
        assertEq(game.currentAmount1, initialLiquidity);
        assertEq(game.currentAmount2, oracleAmount2);
        assertEq(game.escalationHalt, USDC_SUPPLY);
        assertEq(game.settlerReward, SETTLER_REWARD);
        assertEq(game.flags, 5);
        assertEq(usdc.balanceOf(liquidator), liquidatorUsdcBefore - initialLiquidity - tokenStake);
        assertEq(liquidator.balance, liquidatorEthBefore - oracleAmount2 - SETTLER_REWARD);
    }

    function testUsdcEth_FailedLiquidationAddsStakeInSixDecimalUnits() public {
        uint256 lendingId = _originateUsdcEthLoan();
        uint256 reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingUsdcEthPrice(reportId);

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);

        vm.prank(finalizer);
        lending.finalize(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation);
        assertFalse(loan.finished);
        assertEq(loan.supplyAmount, USDC_SUPPLY + USDC_SUPPLY / 100);
        assertEq(usdc.balanceOf(address(lending)), USDC_SUPPLY + USDC_SUPPLY / 100);
    }

    function testUsdcEth_SuccessfulLiquidationPaysUsdcCollateralAndStake() public {
        uint256 lendingId = _originateUsdcEthLoan();
        uint256 lenderUsdcBefore = usdc.balanceOf(lender);
        uint256 liquidatorUsdcBefore = usdc.balanceOf(liquidator);
        uint256 reportId = _liquidate(lendingId, 4 ether);

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);

        vm.prank(finalizer);
        lending.finalize(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished);
        assertFalse(loan.inLiquidation);
        assertEq(usdc.balanceOf(lender), lenderUsdcBefore + USDC_SUPPLY);
        assertEq(usdc.balanceOf(liquidator), liquidatorUsdcBefore - uint256(USDC_SUPPLY) * 10 / 100);
    }

    function testFuzzUsdcEth_LiquidationLegsStayNonzeroAndStoreExactBaseUnits(uint96 supplySeed) public {
        uint128 supplyAmount = uint128(bound(uint256(supplySeed), 100e6, 1_000_000e6));
        uint256 lendingId = _originateUsdcEthLoan(supplyAmount, ETH_BORROW);
        uint256 initialLiquidity = uint256(supplyAmount) * 10 / 100;
        uint256 oracleAmount2 = uint256(ETH_BORROW) / 9;

        assertGt(initialLiquidity, 0);
        assertGt(uint256(supplyAmount) * 100 / 10000, 0);

        uint256 reportId = _liquidate(lendingId, oracleAmount2);
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        uint256 priceRatio = oracleAmount2 * 1e18 / initialLiquidity;
        uint256 expectedAmount2 = initialLiquidity * priceRatio / 1e18;
        assertEq(game.currentAmount1, initialLiquidity);
        assertEq(game.currentAmount2, expectedAmount2);
        assertEq(game.escalationHalt, supplyAmount);
    }

    function testEthUsdc_RequestLendRepayUsesNativeCollateralAndSixDecimalDebt() public {
        uint256 borrowerEthBefore = borrower.balance;
        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);
        uint256 lenderUsdcBefore = usdc.balanceOf(lender);
        uint256 lendingEthBefore = address(lending).balance;

        uint256 lendingId = _requestEthUsdcLoan(ETH_COLLATERAL, USDC_DEBT);

        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        openLend.LendingArrangement memory live = lendView.getLending(lendingId);
        assertEq(live.supplyToken, address(0));
        assertEq(live.borrowToken, address(usdc));
        assertEq(live.supplyAmount, ETH_COLLATERAL);
        assertEq(live.principal, USDC_DEBT);
        assertEq(address(lending).balance, lendingEthBefore + ETH_COLLATERAL);
        assertEq(borrower.balance, borrowerEthBefore - ETH_COLLATERAL);
        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore + USDC_DEBT);
        assertEq(usdc.balanceOf(lender), lenderUsdcBefore - USDC_DEBT);

        vm.prank(borrower);
        lending.repayDebt(lendingId, USDC_DEBT, bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory closed = lendView.getLending(lendingId);
        assertTrue(closed.finished);
        assertEq(borrower.balance, borrowerEthBefore);
        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore);
        assertEq(usdc.balanceOf(lender), lenderUsdcBefore);
    }

    function testEthUsdc_LiquidationReportStoresNativeEthToken1AndSixDecimalUsdcToken2() public {
        uint256 lendingId = _originateEthUsdcLoan();
        uint256 oracleAmount2 = 6_000e6;
        uint256 initialLiquidity = uint256(ETH_COLLATERAL) * 10 / 100;
        uint256 tokenStake = uint256(ETH_COLLATERAL) * 100 / 10000;

        uint256 liquidatorEthBefore = liquidator.balance;
        uint256 liquidatorUsdcBefore = usdc.balanceOf(liquidator);
        uint256 reportId = _liquidateEthUsdcDebt(lendingId, oracleAmount2);

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        assertEq(game.token1, address(0));
        assertEq(game.token2, address(usdc));
        assertEq(game.currentAmount1, initialLiquidity);
        assertEq(game.currentAmount2, oracleAmount2);
        assertEq(game.escalationHalt, ETH_COLLATERAL);
        assertEq(game.settlerReward, SETTLER_REWARD);
        assertEq(game.flags, 5);
        assertEq(liquidator.balance, liquidatorEthBefore - initialLiquidity - tokenStake - SETTLER_REWARD);
        assertEq(usdc.balanceOf(liquidator), liquidatorUsdcBefore - oracleAmount2);
    }

    function testEthUsdc_SuccessfulLiquidationPaysNativeCollateralWithSixDecimalDebt() public {
        uint256 lendingId = _originateEthUsdcLoan();
        uint256 lenderEthBefore = lender.balance;
        uint256 liquidatorEthBefore = liquidator.balance;
        uint256 reportId = _liquidateEthUsdcDebt(lendingId, 6_000e6);

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);

        vm.prank(finalizer);
        lending.finalize(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished);
        assertFalse(loan.inLiquidation);
        assertEq(lender.balance, lenderEthBefore + ETH_COLLATERAL);
        assertEq(liquidator.balance, liquidatorEthBefore - uint256(ETH_COLLATERAL) * 10 / 100 - SETTLER_REWARD);
    }

    function _requestUsdcEthLoan(uint128 supplyAmount, uint128 borrowAmount) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(usdc),
            address(0),
            8e6,
            supplyAmount,
            borrowAmount,
            100,
            0,
            0,
            borrower,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    function _requestEthUsdcLoan(uint128 supplyAmount, uint128 borrowAmount) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow{value: supplyAmount}(
            LOAN_TERM,
            address(0),
            address(usdc),
            8e6,
            supplyAmount,
            borrowAmount,
            100,
            0,
            0,
            borrower,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    function _originateUsdcEthLoan() internal returns (uint256 lendingId) {
        lendingId = _originateUsdcEthLoan(USDC_SUPPLY, ETH_BORROW);
    }

    function _originateUsdcEthLoan(uint128 supplyAmount, uint128 borrowAmount) internal returns (uint256 lendingId) {
        lendingId = _requestUsdcEthLoan(supplyAmount, borrowAmount);
        vm.prank(lender);
        lending.lend{value: borrowAmount}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);
    }

    function _originateEthUsdcLoan() internal returns (uint256 lendingId) {
        lendingId = _requestEthUsdcLoan(ETH_COLLATERAL, USDC_DEBT);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);
    }

    function _liquidate(uint256 lendingId, uint256 oracleAmount2) internal returns (uint256 reportId) {
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        uint256 initialLiquidity = uint256(loan.supplyAmount) * loan.oracleParams.initialLiquidity / 100;
        uint256 priceRatio = oracleAmount2 * 1e18 / initialLiquidity;
        bytes32 paramHash = lendView.getParamHash(lendingId);

        vm.prank(liquidator);
        lending.liquidate{value: oracleAmount2 + SETTLER_REWARD}(
            lendingId,
            priceRatio,
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD,
            liquidator,
            0,
            _emptyTiming()
        );
        reportId = oracle.nextReportId() - 1;
    }

    function _liquidateEthUsdcDebt(uint256 lendingId, uint256 oracleAmount2) internal returns (uint256 reportId) {
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        uint256 initialLiquidity = uint256(loan.supplyAmount) * loan.oracleParams.initialLiquidity / 100;
        uint256 tokenStake = uint256(loan.supplyAmount) * loan.stake / 10000;
        uint256 priceRatio = oracleAmount2 * 1e18 / initialLiquidity;
        bytes32 paramHash = lendView.getParamHash(lendingId);

        vm.prank(liquidator);
        lending.liquidate{value: initialLiquidity + tokenStake + SETTLER_REWARD}(
            lendingId,
            priceRatio,
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD,
            liquidator,
            0,
            _emptyTiming()
        );
        reportId = oracle.nextReportId() - 1;
    }

    function _disputeToNonLiquidatingUsdcEthPrice(uint256 reportId) internal {
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        uint256 disputeReadyAt = uint256(game.reportTimestamp) + game.disputeDelay;
        if (block.timestamp < disputeReadyAt) vm.warp(disputeReadyAt);

        uint128 newAmount1 = uint128(uint256(game.currentAmount1) * game.multiplier / 100);
        uint128 newAmount2 = 30 ether;
        uint256 ethRequired = uint256(newAmount2) - game.currentAmount2;
        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);

        vm.prank(disputer);
        IOpenOracle2(address(oracle)).dispute{value: ethRequired}(
            reportId,
            address(usdc),
            newAmount1,
            newAmount2,
            disputer,
            false,
            false,
            game,
            helper,
            _emptyTiming()
        );
    }

    function _helperFor(uint256 reportId) internal view returns (IOpenOracle2.PreimageHelper memory ph) {
        IOpenOracle2.StoredHelper memory sh = IOpenOracle2(address(oracle)).storedHelper(reportId);
        ph.reportId = reportId;
        ph.creator = sh.creator;
        ph.blockTimestamp = sh.blockTimestamp;
        ph.blockNumber = sh.blockNumber;
    }

    function _standardOracleParams() internal pure returns (openLend.OracleParams memory) {
        return openLend.OracleParams({
            settlementTime: 600,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 100,
            initialLiquidity: 10,
            multiplier: 200,
            maxBaseFee: 0,
            finalizerReward: 0
        });
    }

    function _zeroOracleParams() internal pure returns (openLend.OracleParams memory) {
        return openLend.OracleParams({
            settlementTime: 0,
            disputeDelay: 0,
            oracleGameFee: 0,
            escalationFactor: 0,
            initialLiquidity: 0,
            multiplier: 0,
            maxBaseFee: 0,
            finalizerReward: 0
        });
    }

    function _standardInterestRateParams() internal pure returns (openLend.InterestRateParams memory) {
        return openLend.InterestRateParams({
            maxRate: 2e8,
            startingRate: 5e7,
            roundLength: 60,
            growthRate: 10500,
            maxRounds: 20
        });
    }

    function _emptyTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory timing) {}
}
