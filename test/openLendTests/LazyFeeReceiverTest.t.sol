// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LendErrors} from "../../src/libraries/LendErrors.sol";
import "./OpenLendingBase.t.sol";

contract LazyFeeReceiverTest is OpenLendingBaseTest {
    address internal borrower = address(0x101);
    address internal lender = address(0x102);
    address internal liquidator = address(0x103);
    address internal disputer = address(0x104);
    address internal settler = address(0x105);
    address internal randomCaller = address(0x106);
    address internal disputer2 = address(0x107);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 70 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint96 constant SETTLER_REWARD = 1e15;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accounts = new address[](5);
        accounts[0] = borrower;
        accounts[1] = lender;
        accounts[2] = liquidator;
        accounts[3] = disputer;
        accounts[4] = disputer2;
        _fundSupply(accounts, 10_000 ether);
        _fundBorrow(accounts, 10_000 ether);

        address[] memory ethAccounts = new address[](5);
        ethAccounts[0] = borrower;
        ethAccounts[1] = lender;
        ethAccounts[2] = liquidator;
        ethAccounts[3] = settler;
        ethAccounts[4] = randomCaller;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);
        _approveOracleBoth(disputer2);
    }

    function testLiquidateStoresPredictedButUndeployedFeeReceiver() public {
        uint256 lendingId = _setupLoan();
        uint256 reportId = oracle.nextReportId();
        address predicted = _predictFeeReceiver(reportId, lendingId, liquidator);

        _liquidate(lendingId, 8 ether);

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        assertEq(game.protocolFeeRecipient, predicted, "stored fee recipient");
        assertEq(predicted.code.length, 0, "clone not deployed by liquidate");
        assertEq(lendView.getFeeReceiver(lendingId).feeReceiver, predicted, "provider predicts same receiver");
        assertFalse(lendView.getFeeReceiver(lendingId).deployed, "provider reports undeployed");

        openLendDataProvider.Beneficiaries memory bens = lendView.getBeneficiaries(lendingId, predicted);
        assertEq(bens.borrower, address(0), "undeployed borrower zero");
        assertEq(bens.lender, address(0), "undeployed lender zero");
        assertEq(bens.liquidator, address(0), "undeployed liquidator zero");
    }

    function testFirstDistributionDeploysCloneAndPaysAccruedFees() public {
        uint256 lendingId = _setupLoan();
        uint256 reportId = _liquidate(lendingId, 8 ether);
        address feeRecipient = _predictFeeReceiver(reportId);

        _disputeSupplyFee(reportId);

        uint256 fee = 10 ether * 100_000 / 1e7;
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(supplyToken)), fee + 1, "fees pending");
        assertEq(feeRecipient.code.length, 0, "still undeployed before distribution");
        assertEq(lendView.getFeeReceiver(lendingId).fees1Pending, fee, "provider reports pending fees pre-deploy");
        assertEq(lendView.getFeeReceiver(lendingId).fees2Pending, 0, "provider reports no token2 fees pre-deploy");

        uint256 borrowerBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(supplyToken));
        uint256 lenderBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(supplyToken));
        uint256 liquidatorBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(supplyToken));

        _distributeOracleGameFees(reportId);

        assertGt(feeRecipient.code.length, 0, "clone deployed");
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(supplyToken)), 1, "receiver dust");
        _assertFeeSplit(address(supplyToken), fee, borrowerBefore, lenderBefore, liquidatorBefore);
        assertTrue(lendView.getFeeReceiver(lendingId).deployed, "provider reports deployed");
    }

    function testPostFinalizeDistributionUsesLiquidationSnapshot() public {
        uint256 lendingId = _setupLoan();
        uint256 reportId = _liquidate(lendingId, 8 ether);
        address feeRecipient = _predictFeeReceiver(reportId);

        _disputeSupplyFee(reportId);
        uint256 fee = 10 ether * 100_000 / 1e7;

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);
        openLend.LendingArrangement memory snapshot = lendView.getLending(lendingId);

        uint256 borrowerBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(supplyToken));
        uint256 lenderBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(supplyToken));
        uint256 liquidatorBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(supplyToken));

        vm.prank(randomCaller);
        lending.finalize(lendingId);

        assertEq(lending.lendingToReportId(lendingId), 0, "live report link cleared");
        assertEq(feeRecipient.code.length, 0, "clone still undeployed after finalize");

        _deployAndDistributeOracleGameFees(
            reportId,
            lendingId,
            snapshot.borrower,
            snapshot.lender,
            snapshot.liquidator
        );

        assertGt(feeRecipient.code.length, 0, "clone deployed after finalize");
        _assertFeeSplit(address(supplyToken), fee, borrowerBefore, lenderBefore, liquidatorBefore);
    }

    function testWrongSnapshotCannotDeployFeeReceiver() public {
        uint256 lendingId = _setupLoan();
        uint256 reportId = _liquidate(lendingId, 8 ether);
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);

        vm.expectRevert(LendErrors.FeeRecipientNotForLendingId.selector);
        lending.deployAndDistributeFeeReceiver(
            reportId,
            lendingId + 1,
            game.token1,
            game.token2,
            borrower,
            lender,
            liquidator
        );

        vm.expectRevert(LendErrors.FeeRecipientNotForLendingId.selector);
        lending.deployAndDistributeFeeReceiver(
            reportId,
            lendingId,
            game.token1,
            game.token2,
            borrower,
            randomCaller,
            liquidator
        );
    }

    function testSecondDistributionIsNoOp() public {
        uint256 lendingId = _setupLoan();
        uint256 reportId = _liquidate(lendingId, 8 ether);
        _disputeSupplyFee(reportId);

        _distributeOracleGameFees(reportId);

        uint256 borrowerBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(supplyToken));
        uint256 lenderBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(supplyToken));
        uint256 liquidatorBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(supplyToken));

        (, uint256 fees1, uint256 fees2) =
            _deployAndDistributeOracleGameFees(reportId, lendingId, borrower, lender, liquidator);

        assertEq(fees1, 0, "no second token1 sweep");
        assertEq(fees2, 0, "no token2 sweep");
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(borrower, address(supplyToken)), borrowerBefore, "borrower unchanged");
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(lender, address(supplyToken)), lenderBefore, "lender unchanged");
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(supplyToken)), liquidatorBefore, "liquidator unchanged");
    }

    function testReaccruedFeesCanBeDistributedAfterFirstSweep() public {
        uint256 lendingId = _setupLoan();
        uint256 reportId = _liquidate(lendingId, 8 ether);
        _disputeSupplyFee(reportId);
        _distributeOracleGameFees(reportId);

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.disputeDelay + 1);
        _disputeAndSwap(reportId, address(supplyToken), 40 ether, 32 ether, disputer2, 0, bytes32(0));

        uint256 fee = 20 ether * 100_000 / 1e7;
        address feeRecipient = _predictFeeReceiver(reportId);
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(supplyToken)), fee + 1, "second fees pending");
        assertEq(lendView.getFeeReceiver(lendingId).fees1Pending, fee, "provider reports second fees");

        uint256 borrowerBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(supplyToken));
        uint256 lenderBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(supplyToken));
        uint256 liquidatorBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(supplyToken));

        (, uint256 fees1, uint256 fees2) =
            _deployAndDistributeOracleGameFees(reportId, lendingId, borrower, lender, liquidator);

        assertEq(fees1, fee, "second token1 sweep");
        assertEq(fees2, 0, "no token2 sweep");
        _assertFeeSplit(address(supplyToken), fee, borrowerBefore, lenderBefore, liquidatorBefore);
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(supplyToken)), 1, "receiver dust after second sweep");
    }

    function testNonLendingOracleReportCannotDeployFeeReceiver() public {
        uint256 reportId = _directOracleReport(randomCaller);
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);

        vm.expectRevert(LendErrors.FeeRecipientNotForLendingId.selector);
        lending.deployAndDistributeFeeReceiver(
            reportId,
            1,
            game.token1,
            game.token2,
            borrower,
            lender,
            liquidator
        );
    }

    function _setupLoan() internal returns (uint256 lendingId) {
        lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
    }

    function _liquidate(uint256 lendingId, uint256 oracleAmount2Target) internal returns (uint256 reportId) {
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId,
            oracleAmount2Target * 1e18 / (SUPPLY_AMOUNT * 10 / 100),
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

    function _disputeSupplyFee(uint256 reportId) internal {
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.disputeDelay + 1);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 16 ether, disputer, 0, bytes32(0));
    }

    function _directOracleReport(address feeRecipient) internal returns (uint256 reportId) {
        IOpenOracle2.OracleGame memory params = IOpenOracle2.OracleGame({
            currentAmount1: 1 ether,
            currentAmount2: 2 ether,
            currentReporter: disputer,
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: address(supplyToken),
            lastReportOppoTime: 0,
            settlementTime: 300,
            escalationHalt: 10 ether,
            protocolFeeRecipient: feeRecipient,
            settlerReward: 0,
            token2: address(borrowToken),
            numReports: 0,
            disputeDelay: 60,
            feePercentage: 0,
            multiplier: 200,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: 0,
            flags: 5
        });

        vm.prank(disputer);
        reportId = IOpenOracle2(address(oracle)).report(params, false, false, _emptyTiming());
    }

    function _assertFeeSplit(
        address token,
        uint256 fee,
        uint256 borrowerBefore,
        uint256 lenderBefore,
        uint256 liquidatorBefore
    ) internal view {
        uint256 borrowerPiece = fee / 2;
        uint256 lenderPiece = borrowerPiece / 2;
        uint256 liquidatorPiece = fee - borrowerPiece - lenderPiece;

        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(borrower, token),
            _afterInternalCredit(borrowerBefore, borrowerPiece),
            "borrower fee"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(lender, token),
            _afterInternalCredit(lenderBefore, lenderPiece),
            "lender fee"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(liquidator, token),
            _afterInternalCredit(liquidatorBefore, liquidatorPiece),
            "liquidator fee"
        );
    }

    function _afterInternalCredit(uint256 beforeBalance, uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return beforeBalance;
        return beforeBalance == 0 ? amount + 1 : beforeBalance + amount;
    }
}
