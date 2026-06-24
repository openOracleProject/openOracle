// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LendErrors} from "../../src/libraries/LendErrors.sol";
import "./OpenLendingBase.t.sol";
import "../../src/libraries/Errors.sol";
import "../../src/oracleFeeReceiver2.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BigMintERC20 is ERC20 {
    constructor() ERC20("Big Mint", "BIG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NewOracleIntegrationRegressionTest is OpenLendingBaseTest {
    address internal borrower = address(0xA11CE);
    address internal lender = address(0xB0B);
    address internal lender2 = address(0xCAFE);
    address internal liquidator = address(0xD00D);
    address internal disputer = address(0xD15);
    address internal disputer2 = address(0xD16);
    address internal depositor = address(0xDE90);

    uint128 internal constant SUPPLY_AMOUNT = 100 ether;
    uint128 internal constant BORROW_AMOUNT = 70 ether;
    uint48 internal constant LOAN_TERM = 30 days;
    uint96 internal constant SETTLER_REWARD = 1e15;

    event OracleGameFeesGrabbed(
        uint256 indexed lendingId,
        address indexed feeRecipient,
        uint256 feesSupply,
        uint256 feesBorrow
    );

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accounts = new address[](7);
        accounts[0] = borrower;
        accounts[1] = lender;
        accounts[2] = lender2;
        accounts[3] = liquidator;
        accounts[4] = disputer;
        accounts[5] = disputer2;
        accounts[6] = depositor;
        _fundSupply(accounts, 10_000 ether);
        _fundBorrow(accounts, 10_000 ether);
        _dealETH(accounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBorrow(lender);
        _approveLendingBorrow(lender2);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(liquidator);
        _approveOracleBoth(disputer);
        _approveOracleBoth(disputer2);
    }

    function testLiquidate_ForwardsValidTimingAndStoresExactOracleGameFields() public {
        uint256 lendingId = _setupActiveLoan(5e6);
        uint256 reportId = oracle.nextReportId();
        address feeRecipient = _predictFeeReceiver(reportId);
        IOpenOracle2.TimingBoundaries memory timing = _currentTiming();
        bytes32 paramHash = lendView.getParamHash(lendingId);

        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD,
            liquidator,
            0,
            timing
        );

        assertEq(oracle.nextReportId(), reportId + 1, "report consumed expected id");
        assertEq(lending.lendingToReportId(lendingId), reportId, "loan mapped to report");
        assertEq(lending.reportIdToLending(reportId), lendingId, "report mapped to loan");
        assertTrue(feeRecipient.code.length > 0, "fee receiver deployed");

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        assertEq(o.currentAmount1, 10 ether, "amount1");
        assertEq(o.currentAmount2, 8 ether, "amount2");
        assertEq(o.currentReporter, liquidator, "currentReporter");
        assertEq(o.reportTimestamp, uint48(block.timestamp), "reportTimestamp");
        assertEq(o.settlementTimestamp, 0, "settlementTimestamp");
        assertEq(o.token1, address(supplyToken), "token1");
        assertEq(o.lastReportOppoTime, uint48(block.number), "oppo block");
        assertEq(o.settlementTime, 300, "settlementTime");
        assertEq(o.escalationHalt, 100 ether, "escalationHalt");
        assertEq(o.protocolFeeRecipient, feeRecipient, "protocolFeeRecipient");
        assertEq(o.settlerReward, SETTLER_REWARD, "settlerReward");
        assertEq(o.token2, address(borrowToken), "token2");
        assertEq(o.numReports, 0, "numReports");
        assertEq(o.disputeDelay, 60, "disputeDelay");
        assertEq(o.feePercentage, 0, "feePercentage");
        assertEq(o.multiplier, 200, "multiplier");
        assertEq(o.callbackContract, address(0), "callbackContract");
        assertEq(o.callbackGasLimit, 0, "callbackGasLimit");
        assertEq(o.protocolFee, 100_000, "protocolFee");
        assertEq(o.flags, 5, "flags");

        IOpenOracle2.StoredHelper memory sh = IOpenOracle2(address(oracle)).storedHelper(reportId);
        assertEq(sh.creator, address(lending), "helper creator");
        assertEq(sh.blockTimestamp, uint48(block.timestamp), "helper timestamp");
        assertEq(sh.blockNumber, uint48(block.number), "helper block");
    }

    function testLiquidate_StaleTimingRevertsAndRollsBackAllLocalState() public {
        uint256 lendingId = _setupActiveLoan(5e6);
        uint256 reportId = oracle.nextReportId();
        address feeRecipient = _predictFeeReceiver(reportId);
        bytes32 paramHash = lendView.getParamHash(lendingId);
        IOpenOracle2.TimingBoundaries memory stale = IOpenOracle2.TimingBoundaries({
            blockNumber: block.number,
            blockNumberBound: 60,
            blockTimestamp: block.timestamp + 62,
            blockTimestampBound: 60
        });

        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 liquidatorBorrowBefore = borrowToken.balanceOf(liquidator);
        uint256 lendingSupplyBefore = supplyToken.balanceOf(address(lending));
        uint256 lendingBorrowBefore = borrowToken.balanceOf(address(lending));

        vm.prank(liquidator);
        vm.expectRevert(Errors.InvalidTiming.selector);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD,
            liquidator,
            0,
            stale
        );

        assertEq(oracle.nextReportId(), reportId, "report id rolled back");
        assertFalse(lendView.getLending(lendingId).inLiquidation, "loan not left in liquidation");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId rolled back");
        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending rolled back");
        assertEq(feeRecipient.code.length, 0, "fee receiver deployment rolled back");
        assertEq(supplyToken.balanceOf(liquidator), liquidatorSupplyBefore, "liquidator supply restored");
        assertEq(borrowToken.balanceOf(liquidator), liquidatorBorrowBefore, "liquidator borrow restored");
        assertEq(supplyToken.balanceOf(address(lending)), lendingSupplyBefore, "lending supply restored");
        assertEq(borrowToken.balanceOf(address(lending)), lendingBorrowBefore, "lending borrow restored");
    }

    function testLiquidate_StaleBlockNumberTimingRevertsAndRollsBackAllLocalState() public {
        uint256 lendingId = _setupActiveLoan(5e6);
        uint256 reportId = oracle.nextReportId();
        address feeRecipient = _predictFeeReceiver(reportId);
        bytes32 paramHash = lendView.getParamHash(lendingId);
        IOpenOracle2.TimingBoundaries memory stale = IOpenOracle2.TimingBoundaries({
            blockNumber: block.number + 1,
            blockNumberBound: 0,
            blockTimestamp: block.timestamp,
            blockTimestampBound: 60
        });

        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 liquidatorBorrowBefore = borrowToken.balanceOf(liquidator);
        uint256 lendingSupplyBefore = supplyToken.balanceOf(address(lending));
        uint256 lendingBorrowBefore = borrowToken.balanceOf(address(lending));

        vm.prank(liquidator);
        vm.expectRevert(Errors.InvalidTiming.selector);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD,
            liquidator,
            0,
            stale
        );

        assertEq(oracle.nextReportId(), reportId, "report id rolled back");
        assertFalse(lendView.getLending(lendingId).inLiquidation, "loan not left in liquidation");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId rolled back");
        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending rolled back");
        assertEq(feeRecipient.code.length, 0, "fee receiver deployment rolled back");
        assertEq(supplyToken.balanceOf(liquidator), liquidatorSupplyBefore, "liquidator supply restored");
        assertEq(borrowToken.balanceOf(liquidator), liquidatorBorrowBefore, "liquidator borrow restored");
        assertEq(supplyToken.balanceOf(address(lending)), lendingSupplyBefore, "lending supply restored");
        assertEq(borrowToken.balanceOf(address(lending)), lendingBorrowBefore, "lending borrow restored");
    }

    function testLiquidate_ZeroFeeStoresExactOracleGameWithoutFeeReceiver() public {
        openLend.OracleParams memory noFee = _standardOracleParams();
        noFee.oracleGameFee = 0;
        uint256 lendingId = _setupCustomLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, noFee);
        uint256 reportId = oracle.nextReportId();
        address predicted = _predictFeeReceiver(reportId);

        bytes32 paramHash = lendView.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        assertEq(predicted.code.length, 0, "zero-fee liquidation should not deploy receiver");
        assertEq(o.protocolFeeRecipient, address(0), "zero-fee recipient");
        assertEq(o.protocolFee, 0, "zero protocolFee");
        assertEq(o.flags, 5, "flags still store all timestamp mode");
        assertEq(o.callbackContract, address(0), "callbackContract");
        assertEq(o.callbackGasLimit, 0, "callbackGasLimit");
        assertEq(o.currentAmount1, 10 ether, "amount1");
        assertEq(o.currentAmount2, 8 ether, "amount2");
        assertEq(o.currentReporter, liquidator, "currentReporter");
        assertEq(o.token1, address(supplyToken), "token1");
        assertEq(o.token2, address(borrowToken), "token2");
    }

    function testLiquidate_InitialReportEligibilityExactBoundary() public {
        uint256 equalId = _setupThresholdLoan();
        vm.prank(liquidator);
        vm.expectRevert(LendErrors.InitialReportNotLiquidationEligible.selector);
        lending.liquidate{value: SETTLER_REWARD}(
            equalId,
            _priceRatioFor(10 ether),
            type(uint128).max,
            bytes32(0),
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );

        uint256 healthyId = _setupThresholdLoan();
        vm.prank(liquidator);
        vm.expectRevert(LendErrors.InitialReportNotLiquidationEligible.selector);
        lending.liquidate{value: SETTLER_REWARD}(
            healthyId,
            _priceRatioFor(10 ether + 10),
            type(uint128).max,
            bytes32(0),
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );

        uint256 underwaterId = _setupThresholdLoan();
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD}(
            underwaterId,
            _priceRatioFor(10 ether - 10),
            type(uint128).max,
            bytes32(0),
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );
        assertTrue(lendView.getLending(underwaterId).inLiquidation, "one tick underwater should pass");
    }

    function testLiquidate_TopUpBeforeLiquidatorTxCanInvalidateSubmittedPrice() public {
        uint256 lendingId = _setupThresholdLoan();

        vm.prank(borrower);
        lending.topUpCollateral(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);

        vm.prank(liquidator);
        vm.expectRevert(LendErrors.InitialReportNotLiquidationEligible.selector);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId,
            _priceRatioFor(10 ether - 10),
            type(uint128).max,
            bytes32(0),
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );
    }

    function testGrabOracleGameFeesAny_SweepsSupplyAndBorrowFeesInOneCollect() public {
        uint256 lendingId = _setupActiveLoan(5e6);
        uint256 reportId = _liquidate(lendingId, 8 ether);
        address feeRecipient = _predictFeeReceiver(reportId);

        vm.warp(uint256(IOpenOracle2(address(oracle)).storedGame(reportId).reportTimestamp) + 61);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 20 ether, disputer, 0, bytes32(0));

        vm.warp(uint256(IOpenOracle2(address(oracle)).storedGame(reportId).reportTimestamp) + 61);
        _disputeAndSwap(reportId, address(borrowToken), 40 ether, 40 ether, disputer2, 0, bytes32(0));

        uint256 feesSupply = 10 ether * 100_000 / 1e7;
        uint256 feesBorrow = 20 ether * 100_000 / 1e7;
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(supplyToken)), feesSupply + 1, "supply fees accrued");
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(borrowToken)), feesBorrow + 1, "borrow fees accrued");

        uint256 borrowerSupplyBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(supplyToken));
        uint256 lenderSupplyBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(supplyToken));
        uint256 liquidatorSupplyBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(supplyToken));
        uint256 borrowerBorrowBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(borrowToken));
        uint256 lenderBorrowBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(borrowToken));
        uint256 liquidatorBorrowBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(borrowToken));

        vm.expectEmit(true, true, false, true, address(lending));
        emit OracleGameFeesGrabbed(lendingId, feeRecipient, feesSupply, feesBorrow);
        lending.grabOracleGameFeesAny(lendingId, reportId);

        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(supplyToken)), 1, "supply fee receiver dust");
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(borrowToken)), 1, "borrow fee receiver dust");
        _assertFeeSplit(address(supplyToken), feesSupply, borrowerSupplyBefore, lenderSupplyBefore, liquidatorSupplyBefore);
        _assertFeeSplit(address(borrowToken), feesBorrow, borrowerBorrowBefore, lenderBorrowBefore, liquidatorBorrowBefore);
    }

    function testOracleFeeReceiver_DirectCollectRevertsAndPermissionlessGrabStillDistributes() public {
        uint256 lendingId = _setupActiveLoan(5e6);
        uint256 reportId = _liquidate(lendingId, 8 ether);
        address feeRecipient = _predictFeeReceiver(reportId);

        vm.warp(uint256(IOpenOracle2(address(oracle)).storedGame(reportId).reportTimestamp) + 61);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 20 ether, disputer, 0, bytes32(0));

        uint256 feesSupply = 10 ether * 100_000 / 1e7;
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(supplyToken)), feesSupply + 1, "supply fees accrued");

        vm.expectRevert();
        vm.prank(address(0xBEEF));
        oracleFeeReceiver(feeRecipient).collect();

        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(supplyToken)), feesSupply + 1, "fees remain in receiver");

        uint256 borrowerSupplyBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(supplyToken));
        uint256 lenderSupplyBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(supplyToken));
        uint256 liquidatorSupplyBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(supplyToken));

        vm.prank(address(0xCA11));
        lending.grabOracleGameFeesAny(lendingId, reportId);

        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(supplyToken)), 1, "fee receiver dust");
        _assertFeeSplit(address(supplyToken), feesSupply, borrowerSupplyBefore, lenderSupplyBefore, liquidatorSupplyBefore);
    }

    function testFinalize_ConsumesStoredGameAfterMultipleDisputes() public {
        uint256 lendingId = _setupActiveLoan(5e6);
        uint256 reportId = _liquidate(lendingId, 8 ether);

        _twoDisputesToOneToOne(reportId);

        IOpenOracle2.OracleGame memory beforeSettle = IOpenOracle2(address(oracle)).storedGame(reportId);
        assertEq(beforeSettle.currentAmount1, 40 ether, "rewritten amount1");
        assertEq(beforeSettle.currentAmount2, 40 ether, "rewritten amount2");
        assertEq(beforeSettle.currentReporter, disputer2, "rewritten reporter");

        vm.warp(uint256(beforeSettle.reportTimestamp) + beforeSettle.settlementTime + 1);
        vm.prank(disputer);
        lending.finalize(lendingId);

        IOpenOracle2.OracleGame memory afterSettle = IOpenOracle2(address(oracle)).storedGame(reportId);
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(afterSettle.settlementTimestamp, 0, "oracle accounting not settled by finalize");
        assertFalse(loan.inLiquidation, "liquidation cleared");
        assertFalse(loan.finished, "one-to-one final price is failed liquidation");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared");
        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + SUPPLY_AMOUNT / 100, "stake added to collateral");
    }

    function testOracleSettleAfterFinalize_ConsumesStoredHelperAfterMultipleDisputes() public {
        uint256 lendingId = _setupActiveLoan(5e6);
        uint256 reportId = _liquidate(lendingId, 8 ether);

        _twoDisputesToOneToOne(reportId);

        IOpenOracle2.OracleGame memory beforeSettle = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(beforeSettle.reportTimestamp) + beforeSettle.settlementTime + 1);
        vm.prank(lender2);
        lending.finalize(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation, "finalize clears liquidation");
        assertFalse(loan.finished, "one-to-one final price is failed liquidation");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared");
        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + SUPPLY_AMOUNT / 100, "stake added to collateral");

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        vm.prank(disputer2);
        IOpenOracle2(address(oracle)).settle(reportId, game, helper);

        assertGt(IOpenOracle2(address(oracle)).storedGame(reportId).settlementTimestamp, 0, "oracle settled after finalize");
    }

    function testOracleFeeReceiver_CollectCapsAtUint128MaxAndCanBeCalledAgain() public {
        BigMintERC20 bigSupply = new BigMintERC20();
        bigSupply.mint(borrower, 10_000 ether);
        bigSupply.mint(liquidator, 10_000 ether);
        bigSupply.mint(depositor, uint256(type(uint128).max) * 2);

        vm.prank(borrower);
        bigSupply.approve(address(lending), type(uint256).max);
        vm.prank(liquidator);
        bigSupply.approve(address(lending), type(uint256).max);
        vm.prank(liquidator);
        bigSupply.approve(address(oracle), type(uint256).max);
        vm.prank(depositor);
        bigSupply.approve(address(oracle), type(uint256).max);

        uint256 lendingId = _setupCustomLoan(address(bigSupply), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT);
        uint256 reportId = _liquidateWithTokens(lendingId, address(bigSupply), address(borrowToken), 8 ether);
        address feeRecipient = _predictFeeReceiver(reportId);

        vm.startPrank(depositor);
        IOpenOracle2(address(oracle)).deposit(address(bigSupply), type(uint128).max, feeRecipient);
        IOpenOracle2(address(oracle)).deposit(address(bigSupply), type(uint128).max, feeRecipient);
        vm.stopPrank();

        uint256 max = type(uint128).max;
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(bigSupply)), 1 + 2 * max, "seeded over uint128");

        uint256 borrowerBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(bigSupply));
        uint256 lenderBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(bigSupply));
        uint256 liquidatorBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(bigSupply));

        vm.expectEmit(true, true, false, true, address(lending));
        emit OracleGameFeesGrabbed(lendingId, feeRecipient, max, 0);
        lending.grabOracleGameFeesAny(lendingId, reportId);

        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(bigSupply)), 1 + max, "first capped collect leaves remainder");
        _assertFeeSplit(address(bigSupply), max, borrowerBefore, lenderBefore, liquidatorBefore);

        borrowerBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(bigSupply));
        lenderBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(bigSupply));
        liquidatorBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(bigSupply));

        vm.expectEmit(true, true, false, true, address(lending));
        emit OracleGameFeesGrabbed(lendingId, feeRecipient, max, 0);
        lending.grabOracleGameFeesAny(lendingId, reportId);

        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(bigSupply)), 1, "second collect drains remainder");
        _assertFeeSplit(address(bigSupply), max, borrowerBefore, lenderBefore, liquidatorBefore);
    }

    function _twoDisputesToOneToOne(uint256 reportId) internal {
        vm.warp(uint256(IOpenOracle2(address(oracle)).storedGame(reportId).reportTimestamp) + 61);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 20 ether, disputer, 0, bytes32(0));

        vm.warp(uint256(IOpenOracle2(address(oracle)).storedGame(reportId).reportTimestamp) + 61);
        _disputeAndSwap(reportId, address(borrowToken), 40 ether, 40 ether, disputer2, 0, bytes32(0));
    }

    function _setupActiveLoan(uint24 liquidatorFraction) internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        _lendWithFraction(lender, lendingId, liquidatorFraction);
    }

    function _setupThresholdLoan() internal returns (uint256 lendingId) {
        lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, 80 ether, LOAN_TERM, 0, 0);
        _lendWithFraction(lender, lendingId, 5e6);
    }

    function _setupCustomLoan(
        address supplyTokenAddress,
        address borrowTokenAddress,
        uint128 supplyAmount,
        uint128 borrowAmount
    ) internal returns (uint256 lendingId) {
        lendingId = _setupCustomLoan(
            supplyTokenAddress,
            borrowTokenAddress,
            supplyAmount,
            borrowAmount,
            _standardOracleParams()
        );
    }

    function _setupCustomLoan(
        address supplyTokenAddress,
        address borrowTokenAddress,
        uint128 supplyAmount,
        uint128 borrowAmount,
        openLend.OracleParams memory oracleParams
    ) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            supplyTokenAddress,
            borrowTokenAddress,
            8e6,
            supplyAmount,
            borrowAmount,
            100,
            uint24(1e7),
            0,
            borrower,
            oracleParams,
            _standardInterestRateParams()
        );

        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);
    }

    function _liquidate(uint256 lendingId, uint256 oracleAmount2Target) internal returns (uint256 reportId) {
        return _liquidateWithTokens(lendingId, address(supplyToken), address(borrowToken), oracleAmount2Target);
    }

    function _liquidateWithTokens(
        uint256 lendingId,
        address,
        address,
        uint256 oracleAmount2Target
    ) internal returns (uint256 reportId) {
        bytes32 paramHash = lendView.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId,
            _priceRatioFor(oracleAmount2Target),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );
        reportId = oracle.nextReportId() - 1;
    }

    function _priceRatioFor(uint256 oracleAmount2Target) internal pure returns (uint256) {
        return oracleAmount2Target * 1e18 / 10 ether;
    }

    function _currentTiming() internal view returns (IOpenOracle2.TimingBoundaries memory timing) {
        timing = IOpenOracle2.TimingBoundaries({
            blockNumber: block.number,
            blockNumberBound: 0,
            blockTimestamp: block.timestamp,
            blockTimestampBound: 0
        });
    }

    function _assertFeeSplit(
        address token,
        uint256 fees,
        uint256 borrowerBefore,
        uint256 lenderBefore,
        uint256 liquidatorBefore
    ) internal view {
        uint256 borrowerPiece = fees / 2;
        uint256 lenderPiece = borrowerPiece / 2;
        uint256 liquidatorPiece = fees - borrowerPiece - lenderPiece;

        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(borrower, token),
            borrowerBefore + borrowerPiece + (borrowerBefore == 0 ? 1 : 0),
            "borrower fee split"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(lender, token),
            lenderBefore + lenderPiece + (lenderBefore == 0 ? 1 : 0),
            "lender fee split"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(liquidator, token),
            liquidatorBefore + liquidatorPiece + (liquidatorBefore == 0 ? 1 : 0),
            "liquidator fee split"
        );
    }
}
