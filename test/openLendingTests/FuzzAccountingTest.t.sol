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
    uint32 constant INTEREST_RATE = 1e8;
    uint24 constant LIQUIDATION_THRESHOLD = 8e6;
    uint128 constant STAKE = 100;
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
        uint256 lendingId = _setupActiveLoan();
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);
        uint128 repayAmount = uint128(bound(repayAmountRaw, 1, totalOwed - 1));

        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender1);
        uint256 contractBorrowBefore = borrowToken.balanceOf(address(lending));

        vm.prank(borrower);
        lending.repayDebt(lendingId, repayAmount);

        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertEq(loan.repaidDebt, repayAmount, "repaidDebt should equal partial payment");
        assertFalse(loan.finished, "partial repayment should not finish the loan");
        assertEq(
            borrowToken.balanceOf(borrower), borrowerBorrowBefore - repayAmount, "borrower should spend exact amount"
        );
        assertEq(borrowToken.balanceOf(lender1), lenderBorrowBefore, "lender should not be paid before maturity");
        assertEq(
            borrowToken.balanceOf(address(lending)),
            contractBorrowBefore + repayAmount,
            "contract should hold the repaid amount"
        );
    }

    function testFuzz_FullRepayAcceptsOversizedInput(uint96 repayAmountRaw) public {
        uint256 lendingId = _setupActiveLoan();
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);
        uint128 repayAmount = uint128(bound(repayAmountRaw, totalOwed, totalOwed + 1_000 ether));

        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender1);

        vm.prank(borrower);
        lending.repayDebt(lendingId, repayAmount);

        openLending.LendingView memory loan = lending.getLending(lendingId);
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
        uint256 lendingId = _setupActiveLoan();
        uint128 topUpAmount = uint128(bound(topUpRaw, 1, 5_000 ether));

        uint256 topperSupplyBefore = supplyToken.balanceOf(topper);
        uint256 contractSupplyBefore = supplyToken.balanceOf(address(lending));

        vm.prank(topper);
        lending.topUpCollateralAnyone(lendingId, topUpAmount);

        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + topUpAmount, "supplyAmount should increase by top-up");
        assertEq(supplyToken.balanceOf(topper), topperSupplyBefore - topUpAmount, "topper should fund the exact amount");
        assertEq(
            supplyToken.balanceOf(address(lending)),
            contractSupplyBefore + topUpAmount,
            "contract should receive the top-up amount"
        );
    }

    function testFuzz_RefiOfferAmountMatchesOwedPlusExtra(uint96 extraRaw, uint32 rateRaw) public {
        uint256 lendingId = _setupActiveLoan();

        uint128 extraDemanded = uint128(bound(extraRaw, 0, 200 ether));
        uint32 refiRate = uint32(bound(rateRaw, 1, 2e8));

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, extraDemanded, 0);

        uint128 expectedOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        vm.prank(lender2);
        (uint256 refiOfferNumber, uint256 refiNonce) =
            lending.offerRefiBorrow(lendingId, refiRate, true, 0, extraDemanded, 0);

        openLending.RefiLendingOffers memory refiOffer =
            lending.getRefiLendingOffer(lendingId, refiNonce, refiOfferNumber);

        assertEq(refiOffer.amount, expectedOwed + extraDemanded, "refi offer amount should match owed plus extra");
        assertEq(refiOffer.rate, refiRate, "stored refi rate should match");
        assertEq(refiOffer.repaidDebtAtRefiOfferTime, 0, "repaidDebt snapshot should match");
    }

    function _setupActiveLoan() internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            _standardOracleParams()
        );

        vm.prank(lender1);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, false);

        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);
    }
}
