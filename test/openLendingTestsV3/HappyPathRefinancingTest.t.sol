// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "./OpenLendingBase.t.sol";

contract HappyPathRefinancingTest is OpenLendingBaseTest {
    address internal borrower = address(0x1);
    address internal lender1 = address(0x2); // Original lender
    address internal lender2 = address(0x3); // Refi lender

    // Unrelated funds to verify no skimming
    uint256 constant UNRELATED_SUPPLY = 500e18;
    uint256 constant UNRELATED_BORROW = 1000e18;

    // Original loan parameters
    uint128 constant SUPPLY_AMOUNT = 100e18;
    uint128 constant BORROW_AMOUNT = 50e18;
    uint48 constant LOAN_TERM = 30 days;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory supplyAccounts = new address[](1);
        supplyAccounts[0] = borrower;
        _fundSupply(supplyAccounts, 10000e18);

        address[] memory borrowAccounts = new address[](3);
        borrowAccounts[0] = borrower;
        borrowAccounts[1] = lender1;
        borrowAccounts[2] = lender2;
        _fundBorrow(borrowAccounts, 10000e18);

        _approveLendingBoth(borrower);
        _approveLendingBorrow(lender1);
        _approveLendingBorrow(lender2);

        _seedUnrelated(UNRELATED_SUPPLY, UNRELATED_BORROW);
    }

    /// @dev Originate, wait some time, open refi, accept refi from lender2.
    /// Returns lendingId and (rate1, owedAtMaturity1) for the original loan, and the new borrowAmount post-refi.
    function setupRefinancedLoan()
        internal
        returns (uint256 lendingId, uint32 rate1, uint128 owedAtMaturity1, uint128 refiBorrowAmount)
    {
        lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        rate1 = lending.getLending(lendingId).rate;

        vm.warp(block.timestamp + 5 days);

        // Borrower opens refi (no extra borrow, no supply pull, keep term)
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, _standardInterestRateParams(), bytes32(0), 0, 0);

        owedAtMaturity1 = _calculateOwedAtMaturity(BORROW_AMOUNT, rate1, LOAN_TERM);
        refiBorrowAmount = owedAtMaturity1;

        // Lender2 accepts the refi curve
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);
    }

    function testRefiLoan_BorrowAndRepayOnTime() public {
        (uint256 lendingId,, , uint128 refiBorrowAmount) = setupRefinancedLoan();

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        uint32 rate2 = loan.rate;

        assertEq(loan.lender, lender2, "Lender should be lender2 after refi");
        assertEq(loan.borrowAmount, refiBorrowAmount, "Borrow amount should be refi amount");
        assertTrue(loan.active, "Loan should be active");
        assertFalse(loan.finished, "Loan should not be finished");
        assertEq(loan.repaidDebt, 0, "Repaid debt should be 0 after refi");

        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);

        uint128 totalOwed = _calculateOwedAtMaturity(refiBorrowAmount, rate2, LOAN_TERM);

        vm.warp(block.timestamp + 15 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished after full repayment");

        assertEq(
            borrowToken.balanceOf(borrower), borrowerBorrowBefore - totalOwed, "Borrower should have paid total owed"
        );
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "Borrower should have received collateral back"
        );
        assertEq(
            borrowToken.balanceOf(lender2), lender2BorrowBefore + totalOwed, "Lender2 should have received total owed"
        );
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply untouched");
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow untouched");
    }

    function testRefiLoan_LateRepay_LenderClaimsCollateral() public {
        (uint256 lendingId,, , uint128 refiBorrowAmount) = setupRefinancedLoan();

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        uint32 rate2 = loan.rate;
        uint256 lender2SupplyBefore = supplyToken.balanceOf(lender2);
        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);

        // Past expiration
        vm.warp(uint256(loan.start) + LOAN_TERM + 1);

        uint128 totalOwed = _calculateOwedAtMaturity(refiBorrowAmount, rate2, LOAN_TERM);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "expired"));
        lending.repayDebt(lendingId, totalOwed, bytes32(0), 0, 0);

        // Lender2 claims collateral (anyone can call but funds go to lender)
        vm.prank(lender2);
        lending.claimCollateral(lendingId);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished after claim");
        assertEq(
            supplyToken.balanceOf(lender2),
            lender2SupplyBefore + SUPPLY_AMOUNT,
            "Lender2 should have received collateral"
        );
        assertEq(
            borrowToken.balanceOf(lender2),
            lender2BorrowBefore,
            "Lender2 borrow balance unchanged (refi funds went to lender1)"
        );
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply untouched");
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow untouched");
    }

    function testRefiLoan_PartialRepayThenLate_LenderGetsCollateralAndPartialRepay() public {
        (uint256 lendingId,,,) = setupRefinancedLoan();

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        uint256 lender2SupplyBefore = supplyToken.balanceOf(lender2);
        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);

        uint128 partialRepayment = 20e18;
        vm.warp(block.timestamp + 10 days);

        vm.prank(borrower);
        lending.repayDebt(lendingId, partialRepayment, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loanMid = lending.getLending(lendingId);
        assertEq(loanMid.repaidDebt, partialRepayment, "Repaid debt should match partial payment");

        vm.warp(uint256(loan.start) + LOAN_TERM + 1);

        vm.prank(lender2);
        lending.claimCollateral(lendingId);

        assertEq(
            supplyToken.balanceOf(lender2),
            lender2SupplyBefore + SUPPLY_AMOUNT,
            "Lender2 should have received collateral"
        );
        assertEq(
            borrowToken.balanceOf(lender2),
            lender2BorrowBefore + partialRepayment,
            "Lender2 should have received partial repayment"
        );
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply untouched");
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow untouched");
    }

    function testRefiLoan_MultiplePartialRepayments() public {
        (uint256 lendingId,, , uint128 refiBorrowAmount) = setupRefinancedLoan();

        uint32 rate2 = lending.getLending(lendingId).rate;
        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        uint128 totalOwed = _calculateOwedAtMaturity(refiBorrowAmount, rate2, LOAN_TERM);

        // First partial
        uint128 payment1 = 10e18;
        vm.warp(block.timestamp + 5 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, payment1, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loan1 = lending.getLending(lendingId);
        assertEq(loan1.repaidDebt, payment1, "First partial payment tracked");
        assertFalse(loan1.finished, "Loan not finished after partial");

        // Second partial
        uint128 payment2 = 15e18;
        vm.warp(block.timestamp + 5 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, payment2, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loan2 = lending.getLending(lendingId);
        assertEq(loan2.repaidDebt, payment1 + payment2, "Both payments tracked");
        assertFalse(loan2.finished, "Loan still not finished");

        // Final remainder
        uint128 remaining = totalOwed - payment1 - payment2;
        vm.warp(block.timestamp + 5 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, remaining, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loanFinal = lending.getLending(lendingId);
        assertTrue(loanFinal.finished, "Loan should be finished after full payment");

        assertEq(
            borrowToken.balanceOf(lender2), lender2BorrowBefore + totalOwed, "Lender2 should have received total owed"
        );
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "Borrower should have received collateral"
        );
    }

    function testRefiLoan_StateCorrect() public {
        (uint256 lendingId,, , uint128 refiBorrowAmount) = setupRefinancedLoan();

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        assertEq(loan.lender, lender2, "Lender should be lender2");
        assertEq(loan.borrower, borrower, "Borrower unchanged");
        assertEq(loan.borrowAmount, refiBorrowAmount, "Borrow amount is refi amount");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT, "Supply unchanged (no pull)");
        assertEq(loan.term, LOAN_TERM, "Term unchanged (newTerm=0 keeps existing)");
        assertTrue(loan.active, "Still active");
        assertFalse(loan.finished, "Not finished");
        assertFalse(loan.cancelled, "Not cancelled");
        assertFalse(loan.curveOpen, "Curve closed after lend");
        assertEq(loan.repaidDebt, 0, "Repaid debt reset to 0");
        assertEq(loan.gracePeriod, 0, "Grace period reset to 0");
        assertEq(loan.liquidator, address(0), "No liquidator");
    }

    function testDoubleRefi_ThenRepay() public {
        (uint256 lendingId,, , uint128 refiBorrowAmount) = setupRefinancedLoan();
        uint32 rate2 = lending.getLending(lendingId).rate;

        // Second refi: lender1 takes it back
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, _standardInterestRateParams(), bytes32(0), 0, 0);

        uint128 owedToLender2 = _calculateOwedAtMaturity(refiBorrowAmount, rate2, LOAN_TERM);
        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);

        vm.prank(lender1);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        // Lender2 paid out the owed-at-maturity from the second loan
        assertEq(
            borrowToken.balanceOf(lender2), lender2BorrowBefore + owedToLender2, "Lender2 should receive owed amount"
        );

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.lender, lender1, "Lender should be back to lender1");
        assertEq(loan.borrowAmount, owedToLender2, "Borrow amount is what was owed to lender2");

        uint32 rate3 = loan.rate;
        uint128 finalOwed = _calculateOwedAtMaturity(owedToLender2, rate3, LOAN_TERM);
        uint256 lender1BorrowBefore = borrowToken.balanceOf(lender1);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        vm.warp(block.timestamp + 15 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, finalOwed, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loanFinal = lending.getLending(lendingId);
        assertTrue(loanFinal.finished, "Loan should be finished");
        assertEq(
            borrowToken.balanceOf(lender1), lender1BorrowBefore + finalOwed, "Lender1 should receive final payment"
        );
        assertEq(
            supplyToken.balanceOf(borrower), borrowerSupplyBefore + SUPPLY_AMOUNT, "Borrower should receive collateral"
        );
    }

    function testRefiWithSupplyPulled_ThenRepay() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        uint32 rate1 = lending.getLending(lendingId).rate;

        uint128 supplyPulled = 30e18;
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, supplyPulled, 0, _standardInterestRateParams(), bytes32(0), 0, 0);

        uint128 owedToLender1 = _calculateOwedAtMaturity(BORROW_AMOUNT, rate1, LOAN_TERM);

        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + supplyPulled,
            "Borrower should have received pulled supply"
        );

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT - supplyPulled, "Collateral reduced");

        uint32 rate2 = loan.rate;
        uint128 totalOwed = _calculateOwedAtMaturity(owedToLender1, rate2, LOAN_TERM);
        uint256 borrowerSupplyBeforeRepay = supplyToken.balanceOf(borrower);

        vm.warp(block.timestamp + 15 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed, bytes32(0), 0, 0);

        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBeforeRepay + (SUPPLY_AMOUNT - supplyPulled),
            "Borrower should get remaining collateral"
        );
    }
}
