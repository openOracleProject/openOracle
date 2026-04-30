// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";

/// @notice Recipient that rejects ETH (no receive/fallback). Used to exercise the WETH fallback in _payEth.
contract EthRejector {
    // No receive(), no fallback() — incoming ETH transfers revert.
}

contract GasCompensationTest is OpenLendingBaseTest {
    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal lender2 = address(0x3);
    address internal liquidator = address(0x4);
    address internal disputer = address(0x5);
    address internal settler = address(0x6);
    address internal randomCaller = address(0x7);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 70 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint16 constant STAKE = 100;
    uint96 constant GAS_COMP = 0.01 ether;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accounts = new address[](6);
        accounts[0] = borrower;
        accounts[1] = lender;
        accounts[2] = lender2;
        accounts[3] = liquidator;
        accounts[4] = disputer;
        accounts[5] = randomCaller;
        _fundSupply(accounts, 10_000 ether);
        _fundBorrow(accounts, 10_000 ether);

        address[] memory ethAccounts = new address[](7);
        ethAccounts[0] = borrower;
        ethAccounts[1] = lender;
        ethAccounts[2] = lender2;
        ethAccounts[3] = liquidator;
        ethAccounts[4] = disputer;
        ethAccounts[5] = settler;
        ethAccounts[6] = randomCaller;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(lender2);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);
    }

    // -------------------------------------------------------------------------
    // requestBorrow msg.value validation
    // -------------------------------------------------------------------------

    function testRequestBorrow_MsgValueMustEqualGasComp_TooLow() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "msg.value should be gasComp"));
        lending.requestBorrow{value: GAS_COMP - 1}(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            false,
            GAS_COMP,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    function testRequestBorrow_MsgValueMustEqualGasComp_TooHigh() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "msg.value should be gasComp"));
        lending.requestBorrow{value: GAS_COMP + 1}(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            false,
            GAS_COMP,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    // -------------------------------------------------------------------------
    // Zero gasComp path
    // -------------------------------------------------------------------------

    function testRequestBorrow_ZeroGasCompZeroMsgValue_Works() public {
        // _requestBorrowFlex defaults to 0/0; just verify lend doesn't transfer ETH.
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, 0);
        uint256 lenderEthBefore = lender.balance;
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);
        assertEq(lender.balance, lenderEthBefore, "no ETH transferred when gasComp = 0");
    }

    // -------------------------------------------------------------------------
    // Origination payout
    // -------------------------------------------------------------------------

    function testLend_OriginationPaysGasComp() public {
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, GAS_COMP);
        uint256 contractEthBefore = address(lending).balance;
        uint256 lenderEthBefore = lender.balance;

        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        assertEq(lender.balance - lenderEthBefore, GAS_COMP, "lender receives gasComp");
        assertEq(contractEthBefore - address(lending).balance, GAS_COMP, "contract ETH down by gasComp");
        assertEq(lending.getLending(lendingId).gasCompensation, 0, "gasComp storage cleared");
    }

    // -------------------------------------------------------------------------
    // Refinance msg.value validation (regression for the earlier bug)
    // -------------------------------------------------------------------------

    function testRefinance_MsgValueMustEqualParam_NotStorage() public {
        // Setup: origination zeroed lending.gasCompensation. If the check used storage instead of the parameter,
        // sending msg.value > 0 would revert. We verify here that msg.value == new gasComp parameter is what's checked.
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, 0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        // Storage gasComp is now 0. Borrower opens refi with a fresh non-zero gasComp.
        vm.prank(borrower);
        lending.refinance{value: GAS_COMP}(lendingId, 0, 0, 0, GAS_COMP, _standardInterestRateParams(), bytes32(0), 0, 0);

        assertEq(lending.getLending(lendingId).gasCompensation, GAS_COMP, "refi stored new gasComp");
    }

    function testRefinance_MsgValueMismatchReverts() public {
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, 0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "msg.value should be gasComp"));
        lending.refinance{value: GAS_COMP - 1}(lendingId, 0, 0, 0, GAS_COMP, _standardInterestRateParams(), bytes32(0), 0, 0);
    }

    // -------------------------------------------------------------------------
    // Refi acceptance payout
    // -------------------------------------------------------------------------

    function testLend_RefiAcceptancePaysGasComp() public {
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, 0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        vm.prank(borrower);
        lending.refinance{value: GAS_COMP}(lendingId, 0, 0, 0, GAS_COMP, _standardInterestRateParams(), bytes32(0), 0, 0);

        uint256 lender2EthBefore = lender2.balance;
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        assertEq(lender2.balance - lender2EthBefore, GAS_COMP, "refi acceptor receives gasComp");
        assertEq(lending.getLending(lendingId).gasCompensation, 0, "gasComp storage cleared after refi acceptance");
    }

    // -------------------------------------------------------------------------
    // Cancellation refunds
    // -------------------------------------------------------------------------

    function testCancelBorrowRequest_RefundsGasComp() public {
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, GAS_COMP);
        uint256 borrowerEthBefore = borrower.balance;

        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        assertEq(borrower.balance - borrowerEthBefore, GAS_COMP, "borrower refunded gasComp on cancel");
        assertEq(lending.getLending(lendingId).gasCompensation, 0, "gasComp storage cleared");
    }

    function testCancelRefinance_RefundsGasComp() public {
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, 0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        vm.prank(borrower);
        lending.refinance{value: GAS_COMP}(lendingId, 0, 0, 0, GAS_COMP, _standardInterestRateParams(), bytes32(0), 0, 0);

        uint256 borrowerEthBefore = borrower.balance;
        vm.prank(borrower);
        lending.cancelRefinance(lendingId);

        assertEq(borrower.balance - borrowerEthBefore, GAS_COMP, "borrower refunded refi gasComp on cancel");
        assertEq(lending.getLending(lendingId).gasCompensation, 0, "gasComp cleared");
    }

    // -------------------------------------------------------------------------
    // Refund-on-terminal with refi curve open
    // -------------------------------------------------------------------------

    function testFullRepayWithStagedRefi_RefundsGasComp() public {
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, 0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        vm.warp(block.timestamp + 5 days);

        vm.prank(borrower);
        lending.refinance{value: GAS_COMP}(lendingId, 0, 0, 0, GAS_COMP, _standardInterestRateParams(), bytes32(0), 0, 0);

        uint256 borrowerEthBefore = borrower.balance;
        vm.prank(borrower);
        lending.repayDebt(lendingId, type(uint128).max, bytes32(0), 0, 0);

        assertEq(borrower.balance - borrowerEthBefore, GAS_COMP, "staged refi gasComp refunded on full repay");
    }

    function testClaimCollateralWithStagedRefi_RefundsGasComp() public {
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, 0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        vm.warp(block.timestamp + 5 days);

        vm.prank(borrower);
        lending.refinance{value: GAS_COMP}(lendingId, 0, 0, 0, GAS_COMP, _standardInterestRateParams(), bytes32(0), 0, 0);

        // Warp past maturity; claim
        vm.warp(uint256(lending.getLending(lendingId).start) + LOAN_TERM);

        uint256 borrowerEthBefore = borrower.balance;
        lending.claimCollateral(lendingId);

        assertEq(borrower.balance - borrowerEthBefore, GAS_COMP, "staged refi gasComp refunded on claim");
    }

    function testUnderwaterLiquidationWithStagedRefi_RefundsGasComp() public {
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, 0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, true);

        vm.warp(block.timestamp + 10 days);

        // Open a staged refi with gasComp
        vm.prank(borrower);
        lending.refinance{value: GAS_COMP}(lendingId, 0, 0, 0, GAS_COMP, _standardInterestRateParams(), bytes32(0), 0, 0);

        // Liquidate, dispute to underwater
        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(lendingId, 6 ether * 1e18 / 10 ether, type(uint128).max, paramHash, 0);
        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 61);
        vm.prank(disputer);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);

        uint256 borrowerEthBefore = borrower.balance;
        (,,, uint48 disputeTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(disputeTs) + 301);
        vm.prank(settler);
        oracle.settle(reportId);

        assertEq(borrower.balance - borrowerEthBefore, GAS_COMP, "staged refi gasComp refunded on underwater liq");
    }

    // -------------------------------------------------------------------------
    // Failed liq does NOT refund (loan continues, gasComp stays staged)
    // -------------------------------------------------------------------------

    function testUnsuccessfulLiq_DoesNotRefundGasComp() public {
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, 0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, true);

        vm.warp(block.timestamp + 1 days);

        vm.prank(borrower);
        lending.refinance{value: GAS_COMP}(lendingId, 0, 0, 0, GAS_COMP, _standardInterestRateParams(), bytes32(0), 0, 0);

        // Liquidate to FAVORABLE-for-borrower price → failed liq
        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(lendingId, 12 ether * 1e18 / 10 ether, type(uint128).max, paramHash, 0);
        uint256 reportId = oracle.nextReportId() - 1;

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);
        uint256 borrowerEthBefore = borrower.balance;
        vm.prank(settler);
        oracle.settle(reportId);

        assertEq(borrower.balance, borrowerEthBefore, "failed liq does NOT refund gasComp");
        assertEq(lending.getLending(lendingId).gasCompensation, GAS_COMP, "gasComp still staged for next refi acceptor");
    }

    // -------------------------------------------------------------------------
    // _payEth WETH fallback
    // -------------------------------------------------------------------------

    function testPayEth_WethFallbackForRejectingLender() public {
        EthRejector rejector = new EthRejector();
        // Fund and approve so the rejector can act as a lender.
        borrowToken.transfer(address(rejector), 1000 ether);
        vm.prank(address(rejector));
        borrowToken.approve(address(lending), type(uint256).max);

        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, GAS_COMP);

        // Rejector accepts the loan. _payEth's call returns false; falls back to WETH.
        vm.prank(address(rejector));
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        assertEq(weth.balanceOf(address(rejector)), GAS_COMP, "rejector received gasComp as WETH");
    }

    // -------------------------------------------------------------------------
    // Multi-cycle accounting
    // -------------------------------------------------------------------------

    function testMultiCycle_EthAccountingClean() public {
        uint96 firstComp = 0.01 ether;
        uint96 secondComp = 0.02 ether;
        uint96 thirdComp = 0.03 ether;

        uint256 contractStart = address(lending).balance;

        // Origination
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, false, firstComp);
        assertEq(address(lending).balance - contractStart, firstComp, "after request: contract holds firstComp");

        uint256 lenderBefore = lender.balance;
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);
        assertEq(lender.balance - lenderBefore, firstComp, "lender paid firstComp");
        assertEq(address(lending).balance, contractStart, "after lend: contract back to baseline");

        // Refi #1, then cancel
        vm.prank(borrower);
        lending.refinance{value: secondComp}(lendingId, 0, 0, 0, secondComp, _standardInterestRateParams(), bytes32(0), 0, 0);
        assertEq(address(lending).balance - contractStart, secondComp, "after refi: secondComp escrowed");

        uint256 borrowerBefore = borrower.balance;
        vm.prank(borrower);
        lending.cancelRefinance(lendingId);
        assertEq(borrower.balance - borrowerBefore, secondComp, "borrower refunded secondComp");
        assertEq(address(lending).balance, contractStart, "back to baseline after cancel");

        // Refi #2 with new comp, lender2 accepts
        vm.prank(borrower);
        lending.refinance{value: thirdComp}(lendingId, 0, 0, 0, thirdComp, _standardInterestRateParams(), bytes32(0), 0, 0);
        uint256 lender2Before = lender2.balance;
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);
        assertEq(lender2.balance - lender2Before, thirdComp, "lender2 paid thirdComp");
        assertEq(address(lending).balance, contractStart, "final: contract back to baseline");
    }
}
