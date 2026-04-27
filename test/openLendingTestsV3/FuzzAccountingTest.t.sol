// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";

contract FuzzAccountingTest is OpenLendingBaseTest {
    address internal borrower = address(0x1);
    address internal lender1 = address(0x2);
    address internal lender2 = address(0x3);
    address internal topper = address(0x4);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 50 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint256 constant UNRELATED_SUPPLY = 500 ether;
    uint256 constant UNRELATED_BORROW = 1000 ether;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory supplyAccounts = new address[](2);
        supplyAccounts[0] = borrower;
        supplyAccounts[1] = topper;
        _fundSupply(supplyAccounts, 10_000 ether);

        address[] memory borrowAccounts = new address[](3);
        borrowAccounts[0] = borrower;
        borrowAccounts[1] = lender1;
        borrowAccounts[2] = lender2;
        _fundBorrow(borrowAccounts, 10_000 ether);

        _approveLendingBoth(borrower);
        _approveLendingBorrow(lender1);
        _approveLendingBorrow(lender2);
        _approveLendingSupply(topper);

        _seedUnrelated(UNRELATED_SUPPLY, UNRELATED_BORROW);
    }

    function testFuzz_PartialRepayTracksExactAmount(uint96 repayAmountRaw) public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        uint32 rate = lending.getLending(lendingId).rate;
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);
        uint128 repayAmount = uint128(bound(repayAmountRaw, 1, totalOwed - 1));

        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender1);
        uint256 contractBorrowBefore = borrowToken.balanceOf(address(lending));

        vm.prank(borrower);
        lending.repayDebt(lendingId, repayAmount, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.repaidDebt, repayAmount, "repaidDebt should equal partial payment");
        assertFalse(loan.finished, "partial repayment should not finish the loan");
        assertEq(
            borrowToken.balanceOf(borrower), borrowerBorrowBefore - repayAmount, "borrower should spend exact amount"
        );
        // Streaming: lender receives the partial directly at repay time
        assertEq(
            borrowToken.balanceOf(lender1),
            lenderBorrowBefore + repayAmount,
            "lender should receive streamed partial repayment immediately"
        );
        // Contract balance does not accumulate repaid debt under streaming
        assertEq(
            borrowToken.balanceOf(address(lending)),
            contractBorrowBefore,
            "contract should NOT hold the repaid amount under streaming"
        );
    }

    function testFuzz_FullRepayAcceptsOversizedInput(uint96 repayAmountRaw) public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        uint32 rate = lending.getLending(lendingId).rate;
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);
        uint128 repayAmount = uint128(bound(repayAmountRaw, totalOwed, totalOwed + 1_000 ether));

        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender1);

        vm.prank(borrower);
        lending.repayDebt(lendingId, repayAmount, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.finished, "full repayment branch should finish the loan");
        assertEq(
            borrowToken.balanceOf(borrower),
            borrowerBorrowBefore - totalOwed,
            "borrower should only pay terminal debt, not oversized input"
        );
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "borrower should receive collateral back"
        );
        assertEq(borrowToken.balanceOf(lender1), lenderBorrowBefore + totalOwed, "lender should receive terminal debt");
    }

    function testFuzz_TopUpCollateralAnyone_IncreasesSupplyAndBalance(uint96 topUpRaw) public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        uint128 topUpAmount = uint128(bound(topUpRaw, 1, 5_000 ether));

        uint256 topperSupplyBefore = supplyToken.balanceOf(topper);
        uint256 contractSupplyBefore = supplyToken.balanceOf(address(lending));

        vm.prank(topper);
        lending.topUpCollateralAnyone(lendingId, topUpAmount, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + topUpAmount, "supplyAmount should increase by top-up");
        assertEq(supplyToken.balanceOf(topper), topperSupplyBefore - topUpAmount, "topper should fund the exact amount");
        assertEq(
            supplyToken.balanceOf(address(lending)),
            contractSupplyBefore + topUpAmount,
            "contract should receive the top-up amount"
        );
    }

    /// @dev V3 refi: when a lender accepts the refi curve, newBorrowAmount = owedAtMaturity - repaidDebt + extraDemanded.
    function testFuzz_RefiNewBorrowAmountMatchesOwedPlusExtra(uint96 extraRaw) public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        uint32 origRate = lending.getLending(lendingId).rate;

        uint128 extraDemanded = uint128(bound(extraRaw, 0, 200 ether));

        // Borrower opens refi curve with extraDemanded
        vm.prank(borrower);
        lending.refinance(lendingId, extraDemanded, 0, 0, _standardInterestRateParams(), bytes32(0), 0, 0);

        // Lender2 accepts the refi at the current curve rate
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        uint128 expectedOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, origRate, LOAN_TERM);
        uint128 expectedNewBorrow = expectedOwed + extraDemanded;

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.borrowAmount, expectedNewBorrow, "post-refi borrowAmount = owedAtMaturity + extraDemanded");
        assertEq(loan.lender, lender2, "lender2 should be the new lender");
        assertEq(loan.repaidDebt, 0, "repaidDebt should reset on refi");
    }
}
