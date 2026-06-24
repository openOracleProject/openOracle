// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LendErrors} from "../../src/libraries/LendErrors.sol";
import "./OpenLendingBase.t.sol";

contract NativeEthRejector {
    // No receive/fallback.
}

contract NativeEthRejectingBorrower {
    function requestNativeSupply(
        openLend lending,
        uint48 term,
        address borrowToken,
        uint24 liquidationThreshold,
        uint128 supplyAmount,
        uint128 amountDemanded,
        uint16 stake,
        uint24 commitmentFraction,
        openLend.OracleParams calldata oracleParams,
        openLend.InterestRateParams calldata interestRateParams
    ) external payable returns (uint256 lendingId) {
        lendingId = lending.requestBorrow{value: msg.value}(
            term,
            address(0),
            borrowToken,
            liquidationThreshold,
            supplyAmount,
            amountDemanded,
            stake,
            commitmentFraction,
            0,
            address(this),
            oracleParams,
            interestRateParams
        );
    }

    function refinance(
        openLend lending,
        uint256 lendingId,
        uint128 extraDemanded,
        uint128 supplyPulled,
        openLend.InterestRateParams calldata interestRateParams
    ) external {
        lending.refinance(
            lendingId,
            extraDemanded,
            supplyPulled,
            0,
            0,
            interestRateParams,
            openLend.OracleParams(0, 0, 0, 0, 0, 0, 0, 0),
            bytes32(0),
            0,
            type(uint128).max
        );
    }
    // No receive/fallback.
}

contract NativeEthReentrantReceiver {
    openLend internal immutable lending;
    bytes internal payload;

    bool public lastReentryReverted;
    bytes public lastReentryReason;

    constructor(openLend _lending) {
        lending = _lending;
    }

    function setPayload(bytes calldata _payload) external {
        payload = _payload;
    }

    receive() external payable {
        if (payload.length == 0) return;
        (bool ok, bytes memory ret) = address(lending).call(payload);
        lastReentryReverted = !ok;
        lastReentryReason = ret;
    }
}

contract NativeEthTest is OpenLendingBaseTest {
    address internal constant ETH = address(0);

    address internal borrower = address(0xE1);
    address internal lender = address(0xE2);
    address internal lender2 = address(0xE22);
    address internal liquidator = address(0xE3);
    address internal settler = address(0xE4);

    uint128 internal constant SUPPLY_AMOUNT = 100 ether;
    uint128 internal constant BORROW_AMOUNT = 70 ether;
    uint48 internal constant LOAN_TERM = 30 days;
    uint96 internal constant SETTLER_REWARD = 1e15;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accounts = new address[](5);
        accounts[0] = borrower;
        accounts[1] = lender;
        accounts[2] = liquidator;
        accounts[3] = settler;
        accounts[4] = lender2;
        _fundSupply(accounts, 10_000 ether);
        _fundBorrow(accounts, 10_000 ether);
        _dealETH(accounts, 1_000 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(lender2);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(liquidator);
    }

    function testNativeSupply_RequestBorrowAndCancelReturnsEthCollateral() public {
        uint256 borrowerBefore = borrower.balance;
        uint256 lendingBefore = address(lending).balance;

        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow{value: SUPPLY_AMOUNT}(
            LOAN_TERM,
            ETH,
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            0,
            0,
            borrower,
            _standardOracleParams(),
            _standardInterestRateParams()
        );

        assertEq(borrower.balance, borrowerBefore - SUPPLY_AMOUNT, "borrower paid native collateral");
        assertEq(address(lending).balance, lendingBefore + SUPPLY_AMOUNT, "contract holds native collateral");

        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        assertEq(borrower.balance, borrowerBefore, "borrower received native collateral");
        assertEq(address(lending).balance, lendingBefore, "contract native balance restored");
    }

    function testNativeSupply_FullRepayReturnsEthCollateral() public {
        uint256 borrowerEthBefore = borrower.balance;
        uint256 lendingId = _requestNativeSupplyLoan(0);

        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        vm.prank(borrower);
        lending.repayDebt(lendingId, type(uint128).max, bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "loan closed");
        assertEq(borrower.balance, borrowerEthBefore, "native collateral returned");
    }

    function testNativeSupply_TopUpRequiresExactMsgValueAndIncreasesCollateral() public {
        uint256 lendingId = _requestNativeSupplyLoan(0);

        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.topUpCollateral{value: 1 ether - 1}(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);

        vm.prank(borrower);
        lending.topUpCollateral{value: 1 ether}(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);

        assertEq(lendView.getLending(lendingId).supplyAmount, SUPPLY_AMOUNT + 1 ether, "native top-up counted");
    }

    function testNativeSupply_TopUpRejectsOverpay() public {
        uint256 lendingId = _requestNativeSupplyLoan(0);

        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.topUpCollateral{value: 1 ether + 1}(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);
    }

    function testNativeBorrow_LendFundsBorrowerWithEthAndRepayRefundsOverpay() public {
        uint256 borrowerEthBefore = borrower.balance;
        uint256 lenderEthBefore = lender.balance;
        uint256 lendingId = _requestNativeBorrowLoan(0);

        vm.prank(lender);
        lending.lend{value: BORROW_AMOUNT}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        assertEq(borrower.balance, borrowerEthBefore + BORROW_AMOUNT, "borrower received native borrow");
        assertEq(lender.balance, lenderEthBefore - BORROW_AMOUNT, "lender funded native borrow");

        vm.prank(borrower);
        lending.repayDebt{value: BORROW_AMOUNT + 1 ether}(
            lendingId,
            BORROW_AMOUNT + 1 ether,
            bytes32(0),
            0,
            type(uint128).max
        );

        assertTrue(lendView.getLending(lendingId).finished, "loan closed");
        assertEq(borrower.balance, borrowerEthBefore, "borrower only paid owed amount after refund");
        assertEq(lender.balance, lenderEthBefore, "lender received native principal");
        assertEq(supplyToken.balanceOf(borrower), 10_000 ether, "collateral returned");
    }

    function testNativeBorrow_RepayAnyDebtExactAndRejectsWrongMsgValue() public {
        uint256 lendingId = _requestNativeBorrowLoan(0);
        vm.prank(lender);
        lending.lend{value: BORROW_AMOUNT}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        vm.prank(lender2);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.repayAnyDebt{value: 1 ether + 1}(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);

        uint256 lenderBalanceBefore = lender.balance;
        vm.prank(lender2);
        lending.repayAnyDebt{value: 1 ether}(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);

        assertEq(lender.balance, lenderBalanceBefore + 1 ether, "third-party native repay streams to lender");
        assertEq(lendView.getLending(lendingId).principal, BORROW_AMOUNT - 1 ether, "principal amortized");
    }

    function testNativeBorrow_RefiPaysPreviousLenderAndExtraDemandedInEth() public {
        uint256 lendingId = _requestNativeBorrowLoan(0);
        vm.prank(lender);
        lending.lend{value: BORROW_AMOUNT}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        vm.prank(borrower);
        lending.refinance(lendingId, 1 ether, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        uint256 lenderBefore = lender.balance;
        uint256 lender2Before = lender2.balance;
        uint256 borrowerBefore = borrower.balance;

        vm.prank(lender2);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.lend{value: BORROW_AMOUNT}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender2);

        vm.prank(lender2);
        lending.lend{value: BORROW_AMOUNT + 1 ether}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender2);

        assertEq(lender.balance, lenderBefore + BORROW_AMOUNT, "previous lender paid native residual");
        assertEq(borrower.balance, borrowerBefore + 1 ether, "borrower received native extraDemanded");
        assertEq(lender2.balance, lender2Before - BORROW_AMOUNT - 1 ether, "new lender funded native refi");
        assertEq(lendView.getLending(lendingId).principal, BORROW_AMOUNT + 1 ether, "new native principal");
    }

    function testNativeSupply_RefiWithExtraDemandedAndSupplyPulled() public {
        uint256 lendingId = _requestNativeSupplyLoan(0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        uint256 borrowerEthBefore = borrower.balance;
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            2 ether,
            5 ether,
            0,
            0,
            _standardInterestRateParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender2);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(borrower.balance, borrowerEthBefore + 5 ether, "borrower received native collateral pull");
        assertEq(borrowToken.balanceOf(borrower), borrowerBorrowBefore + 2 ether, "borrower received extra borrow");
        assertEq(borrowToken.balanceOf(lender), lenderBorrowBefore + BORROW_AMOUNT, "previous lender paid residual");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT - 5 ether, "native collateral reduced");
        assertEq(loan.principal, BORROW_AMOUNT + 2 ether, "principal includes extraDemanded");
    }

    function testNativeSupply_RefiPullsEthCollateralAndFallbacksToWethForRejectingBorrower() public {
        NativeEthRejectingBorrower rejectingBorrower = new NativeEthRejectingBorrower();
        borrowToken.transfer(address(rejectingBorrower), 1_000 ether);
        vm.deal(address(rejectingBorrower), 1_000 ether);

        uint256 lendingId = rejectingBorrower.requestNativeSupply{value: SUPPLY_AMOUNT}(
            lending,
            LOAN_TERM,
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            0,
            _standardOracleParams(),
            _standardInterestRateParams()
        );

        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        uint256 borrowerEthBeforeRefiPull = address(rejectingBorrower).balance;
        rejectingBorrower.refinance(lending, lendingId, 0, 5 ether, _standardInterestRateParams());

        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender2);

        assertEq(address(rejectingBorrower).balance, borrowerEthBeforeRefiPull, "borrower contract rejected plain ETH pull");
        assertEq(weth.balanceOf(address(rejectingBorrower)), 5 ether, "supplyPulled paid as WETH");
        assertEq(lendView.getLending(lendingId).supplyAmount, SUPPLY_AMOUNT - 5 ether, "native collateral reduced");
    }

    function testNativeSupply_LiquidationFundsOracleWithEthAndSettlesUnderwater() public {
        uint256 lendingId = _requestNativeSupplyLoan(0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        uint256 lenderEthBefore = lender.balance;
        uint256 liquidatorEthBefore = liquidator.balance;
        uint256 ethRequired = SETTLER_REWARD + 10 ether + 1 ether;
        bytes32 paramHash = lendView.getParamHash(lendingId);

        vm.prank(liquidator);
        lending.liquidate{value: ethRequired}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );

        uint256 reportId = oracle.nextReportId() - 1;
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        assertEq(o.token1, ETH, "oracle token1 is native ETH");
        assertEq(o.currentAmount1, 10 ether, "native initial liquidity");
        assertEq(o.settlerReward, SETTLER_REWARD, "settler reward");
        assertEq(liquidator.balance, liquidatorEthBefore - ethRequired, "liquidator paid native report legs");

        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);
        vm.prank(settler);
        lending.finalize(lendingId);

        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        vm.prank(settler);
        IOpenOracle2(address(oracle)).settle(reportId, o, helper);

        assertTrue(lendView.getLending(lendingId).finished, "underwater native collateral liquidation finished");
        assertEq(lender.balance, lenderEthBefore + SUPPLY_AMOUNT, "lender received native collateral");
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(liquidator, ETH), 10 ether + 1, "oracle credited native report liquidity");
    }

    function testNativeSupply_OracleEthInternalCreditWithdrawsAsPlainEth() public {
        uint256 lendingId = _requestNativeSupplyLoan(0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        uint256 reportId = _liquidateNativeSupply(lendingId, 6 ether);
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);
        vm.prank(settler);
        lending.finalize(lendingId);

        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        vm.prank(settler);
        IOpenOracle2(address(oracle)).settle(reportId, o, helper);

        assertEq(IOpenOracle2(address(oracle)).tokenHolder(liquidator, ETH), 10 ether + 1, "native credit before withdraw");

        uint256 liquidatorBefore = liquidator.balance;
        vm.prank(liquidator);
        uint256 sent = IOpenOracle2(address(oracle)).withdraw(ETH, type(uint256).max);

        assertEq(sent, 10 ether, "withdraw leaves one wei sentinel");
        assertEq(liquidator.balance, liquidatorBefore + 10 ether, "oracle paid native ETH");
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(liquidator, ETH), 1, "native sentinel remains");
    }

    function testNativeSupply_ZeroFeeLiquidationStoresExactFields() public {
        openLend.OracleParams memory oracleParams = _standardOracleParams();
        oracleParams.oracleGameFee = 0;

        uint256 lendingId = _requestNativeSupplyLoanWithOracleParams(0, oracleParams);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        uint256 reportId = _liquidateNativeSupply(lendingId, 6 ether);
        address feeRecipient = _predictFeeReceiver(reportId);
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);

        assertEq(feeRecipient.code.length, 0, "zero-fee liquidation does not deploy fee receiver");
        assertEq(o.protocolFeeRecipient, address(0), "no protocol fee recipient");
        assertEq(o.protocolFee, 0, "no protocol fee");
        assertEq(o.flags, 5, "store-all and dispute tracking stay enabled");
        assertEq(o.token1, ETH, "native collateral token1");
        assertEq(o.token2, address(borrowToken), "borrow token2");
    }

    function testNativeSupply_FailedLiquidationAddsStakeToCollateral() public {
        uint256 lendingId = _requestNativeSupplyLoan(0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        uint256 reportId = _liquidateNativeSupply(lendingId, 8 ether);
        _selfDisputeToken1Eth(reportId, 20 ether, 30 ether);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);
        vm.prank(settler);
        lending.finalize(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.finished, "failed liquidation keeps loan alive");
        assertFalse(loan.inLiquidation, "liquidation cleared");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + 1 ether, "native stake added to collateral");
    }

    function testNativeSupply_NearMaturityFailedLiquidationStakeToRejectingLenderFallsBackToWeth() public {
        NativeEthRejector rejector = new NativeEthRejector();
        borrowToken.transfer(address(rejector), 1_000 ether);
        vm.prank(address(rejector));
        borrowToken.approve(address(lending), type(uint256).max);

        uint256 lendingId = _requestNativeSupplyLoan(0);
        vm.prank(address(rejector));
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, address(rejector));

        vm.warp(block.timestamp + LOAN_TERM - 900);
        uint256 reportId = _liquidateNativeSupply(lendingId, 8 ether);
        _selfDisputeToken1Eth(reportId, 20 ether, 30 ether);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);
        vm.prank(settler);
        lending.finalize(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertGt(loan.gracePeriod, 0, "near-maturity failed liq grants grace");
        assertEq(weth.balanceOf(address(rejector)), 0.5 ether, "half native stake paid as WETH");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + 0.5 ether, "remaining half stake added to collateral");
    }

    function testNativeSupply_FinalizePaysEthCollateral() public {
        uint256 lendingId = _requestNativeSupplyLoan(0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        uint256 lenderBefore = lender.balance;
        uint256 reportId = _liquidateNativeSupply(lendingId, 6 ether);
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);

        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);
        vm.prank(settler);
        lending.finalize(lendingId);

        assertTrue(lendView.getLending(lendingId).finished, "finalize finishes underwater native collateral loan");
        assertEq(lender.balance, lenderBefore + SUPPLY_AMOUNT, "finalize pays lender native collateral");
    }

    function testNativeSupply_FinalizeSweepsEthProtocolFees() public {
        uint256 lendingId = _requestNativeSupplyLoan(0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        uint256 reportId = _liquidateNativeSupply(lendingId, 8 ether);
        _selfDisputeToken1Eth(reportId, 20 ether, 20 ether);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);

        uint256 fee = 10 ether * 100_000 / 1e7;
        uint256 borrowerBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, ETH);
        uint256 lenderBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, ETH);
        uint256 liquidatorBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, ETH);

        vm.prank(settler);
        lending.finalize(lendingId);

        _assertOracleFeeSplit(ETH, fee, borrowerBefore, lenderBefore, liquidatorBefore);
        assertFalse(lendView.getLending(lendingId).inLiquidation, "finalize clears native liquidation");
    }

    function testNativeBorrow_LiquidationForwardsEthAmount2AndRefundsExcess() public {
        uint256 lendingId = _requestNativeBorrowLoan(0);
        vm.prank(lender);
        lending.lend{value: BORROW_AMOUNT}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        uint256 liquidatorEthBefore = liquidator.balance;
        uint256 ethRequired = SETTLER_REWARD + 8 ether;
        bytes32 paramHash = lendView.getParamHash(lendingId);

        vm.prank(liquidator);
        lending.liquidate{value: ethRequired + 1 ether}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );

        uint256 reportId = oracle.nextReportId() - 1;
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        assertEq(o.token2, ETH, "oracle token2 is native ETH");
        assertEq(o.currentAmount2, 8 ether, "native amount2");
        assertEq(liquidator.balance, liquidatorEthBefore - ethRequired, "excess msg.value refunded");
    }

    function testNativeSupply_OracleEthProtocolFeesDistributeInternally() public {
        uint256 lendingId = _requestNativeSupplyLoan(0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        uint256 reportId = _liquidateNativeSupply(lendingId, 8 ether);
        address feeRecipient = _predictFeeReceiver(reportId);

        _selfDisputeToken1Eth(reportId, 20 ether, 20 ether);

        uint256 fee = 10 ether * 100_000 / 1e7;
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, ETH), fee + 1, "native supply fee accrued");

        uint256 borrowerBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, ETH);
        uint256 lenderBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, ETH);
        uint256 liquidatorBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, ETH);

        lending.grabOracleGameFeesAny(lendingId, reportId);

        _assertOracleFeeSplit(ETH, fee, borrowerBefore, lenderBefore, liquidatorBefore);
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, ETH), 1, "fee receiver dust");
    }

    function testNativeBorrow_OracleEthProtocolFeesDistributeInternally() public {
        uint256 lendingId = _requestNativeBorrowLoan(0);
        vm.prank(lender);
        lending.lend{value: BORROW_AMOUNT}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        uint256 reportId = _liquidateNativeBorrow(lendingId, 8 ether, 0);
        address feeRecipient = _predictFeeReceiver(reportId);

        _selfDisputeToken2Eth(reportId, 20 ether, 20 ether);

        uint256 fee = 8 ether * 100_000 / 1e7;
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, ETH), fee + 1, "native borrow fee accrued");

        uint256 borrowerBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, ETH);
        uint256 lenderBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, ETH);
        uint256 liquidatorBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, ETH);

        lending.grabOracleGameFeesAny(lendingId, reportId);

        _assertOracleFeeSplit(ETH, fee, borrowerBefore, lenderBefore, liquidatorBefore);
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, ETH), 1, "fee receiver dust");
    }

    function testNativeSupply_PayoutFallsBackToWethWhenLenderRejectsEth() public {
        NativeEthRejector rejector = new NativeEthRejector();
        borrowToken.transfer(address(rejector), 1_000 ether);

        vm.prank(address(rejector));
        borrowToken.approve(address(lending), type(uint256).max);

        uint256 lendingId = _requestNativeSupplyLoan(0);

        vm.prank(address(rejector));
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, address(rejector));

        vm.warp(block.timestamp + LOAN_TERM + 1);
        lending.claimCollateral(lendingId);

        assertEq(address(rejector).balance, 0, "rejector cannot receive plain ETH");
        assertEq(weth.balanceOf(address(rejector)), SUPPLY_AMOUNT, "native collateral paid as WETH");
    }

    function testNativeSupply_FinalizeEthPayoutReentryFallsBackToWethAndCannotMutate() public {
        NativeEthReentrantReceiver receiver = new NativeEthReentrantReceiver(lending);
        borrowToken.transfer(address(receiver), 1_000 ether);
        vm.prank(address(receiver));
        borrowToken.approve(address(lending), type(uint256).max);

        uint256 lendingId = _requestNativeSupplyLoan(0);
        vm.prank(address(receiver));
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, address(receiver));

        receiver.setPayload(
            abi.encodeWithSelector(
                openLend.repayAnyDebt.selector,
                lendingId,
                uint128(1),
                bytes32(0),
                uint128(0),
                type(uint128).max
            )
        );

        uint256 reportId = _liquidateNativeSupply(lendingId, 6 ether);
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);
        _settleOracle(reportId);

        assertTrue(lendView.getLending(lendingId).finished, "loan remains finished");
        assertEq(address(receiver).balance, 0, "gas-capped direct ETH send failed");
        assertEq(weth.balanceOf(address(receiver)), SUPPLY_AMOUNT, "finalize payout fell back to WETH");
    }

    function testNativeSupply_ClaimCollateralPaysPlainEthToNormalLender() public {
        uint256 lendingId = _requestNativeSupplyLoan(0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        uint256 lenderBefore = lender.balance;
        vm.warp(block.timestamp + LOAN_TERM + 1);
        lending.claimCollateral(lendingId);

        assertEq(lender.balance, lenderBefore + SUPPLY_AMOUNT, "normal lender receives native collateral");
    }

    function testNativeMsgValueRejectMatrixAndBothNativeRejected() public {
        vm.prank(borrower);
        vm.expectRevert(LendErrors.SupplyEqualsBorrow.selector);
        lending.requestBorrow{value: SUPPLY_AMOUNT}(
            LOAN_TERM,
            ETH,
            ETH,
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            0,
            0,
            borrower,
            _standardOracleParams(),
            _standardInterestRateParams()
        );

        vm.prank(borrower);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.requestBorrow{value: SUPPLY_AMOUNT - 1}(
            LOAN_TERM,
            ETH,
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            0,
            0,
            borrower,
            _standardOracleParams(),
            _standardInterestRateParams()
        );

        vm.prank(borrower);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.requestBorrow{value: SUPPLY_AMOUNT + 1}(
            LOAN_TERM,
            ETH,
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            0,
            0,
            borrower,
            _standardOracleParams(),
            _standardInterestRateParams()
        );

        uint256 nativeBorrowId = _requestNativeBorrowLoan(0);
        vm.prank(lender);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.lend{value: BORROW_AMOUNT - 1}(nativeBorrowId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        vm.prank(lender);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.lend{value: BORROW_AMOUNT + 1}(nativeBorrowId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender);

        vm.prank(lender);
        lending.lend{value: BORROW_AMOUNT}(nativeBorrowId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        uint256 ethRequired = SETTLER_REWARD + 8 ether;
        bytes32 paramHash = lendView.getParamHash(nativeBorrowId);
        vm.prank(liquidator);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.liquidate{value: ethRequired - 1}(
            nativeBorrowId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );
    }

    function _requestNativeSupplyLoan(uint24 commitmentFraction) internal returns (uint256 lendingId) {
        lendingId = _requestNativeSupplyLoanWithOracleParams(commitmentFraction, _standardOracleParams());
    }

    function _requestNativeSupplyLoanWithOracleParams(uint24 commitmentFraction, openLend.OracleParams memory oracleParams)
        internal
        returns (uint256 lendingId)
    {
        vm.prank(borrower);
        lendingId = lending.requestBorrow{value: SUPPLY_AMOUNT}(
            LOAN_TERM,
            ETH,
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            commitmentFraction,
            0,
            borrower,
            oracleParams,
            _standardInterestRateParams()
        );
    }

    function _requestNativeBorrowLoan(uint24 commitmentFraction) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            ETH,
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            commitmentFraction,
            0,
            borrower,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    function _priceRatioFor(uint256 oracleAmount2Target) internal pure returns (uint256) {
        return oracleAmount2Target * 1e18 / 10 ether;
    }

    function _liquidateNativeSupply(uint256 lendingId, uint256 oracleAmount2Target) internal returns (uint256 reportId) {
        bytes32 paramHash = lendView.getParamHash(lendingId);
        uint256 ethRequired = SETTLER_REWARD + 10 ether + 1 ether;
        vm.prank(liquidator);
        lending.liquidate{value: ethRequired}(
            lendingId,
            _priceRatioFor(oracleAmount2Target),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );
        reportId = oracle.nextReportId() - 1;
    }

    function _liquidateNativeBorrow(uint256 lendingId, uint256 oracleAmount2Target, uint256 extraValue)
        internal
        returns (uint256 reportId)
    {
        bytes32 paramHash = lendView.getParamHash(lendingId);
        uint256 ethRequired = SETTLER_REWARD + oracleAmount2Target;
        vm.prank(liquidator);
        lending.liquidate{value: ethRequired + extraValue}(
            lendingId,
            _priceRatioFor(oracleAmount2Target),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD, liquidator, 0, _emptyTiming()
        );
        reportId = oracle.nextReportId() - 1;
    }

    function _selfDisputeToken1Eth(uint256 reportId, uint128 newAmount1, uint128 newAmount2) internal {
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        uint256 protocolFee = uint256(game.currentAmount1) * game.protocolFee / 1e7;
        uint256 ethContribution = uint256(newAmount1) - game.currentAmount1 + protocolFee;

        vm.warp(uint256(game.reportTimestamp) + game.disputeDelay + 1);
        vm.prank(liquidator);
        IOpenOracle2(address(oracle)).dispute{value: ethContribution}(
            reportId,
            ETH,
            newAmount1,
            newAmount2,
            liquidator,
            false,
            false,
            game,
            helper, _emptyTiming()
        );
    }

    function _selfDisputeToken2Eth(uint256 reportId, uint128 newAmount1, uint128 newAmount2) internal {
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        uint256 protocolFee = uint256(game.currentAmount2) * game.protocolFee / 1e7;
        uint256 ethContribution = uint256(newAmount2) + protocolFee - game.currentAmount2;

        vm.warp(uint256(game.reportTimestamp) + game.disputeDelay + 1);
        vm.prank(liquidator);
        IOpenOracle2(address(oracle)).dispute{value: ethContribution}(
            reportId,
            ETH,
            newAmount1,
            newAmount2,
            liquidator,
            false,
            false,
            game,
            helper, _emptyTiming()
        );
    }

    function _assertOracleFeeSplit(
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
            "borrower oracle fee split"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(lender, token),
            lenderBefore + lenderPiece + (lenderBefore == 0 ? 1 : 0),
            "lender oracle fee split"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(liquidator, token),
            liquidatorBefore + liquidatorPiece + (liquidatorBefore == 0 ? 1 : 0),
            "liquidator oracle fee split"
        );
    }
}
