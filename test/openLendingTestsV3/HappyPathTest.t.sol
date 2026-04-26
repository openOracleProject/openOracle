// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "./OpenLendingBase.t.sol";

contract HappyPathTest is OpenLendingBaseTest {
    event BorrowRequested(
        address indexed borrower,
        uint256 indexed lendingId,
        address supplyToken,
        address borrowToken,
        uint128 supplyAmount,
        uint128 amountDemanded,
        uint48 term,
        uint24 liquidationThreshold,
        uint16 stake,
        openLend.OracleParams oracleParams,
        openLend.InterestRateParams interestRateParams
    );
    event LoanOriginated(
        uint256 indexed lendingId,
        address indexed lender,
        uint256 borrowAmount,
        uint256 rate,
        uint48 start,
        uint48 term,
        bool allowAnyLiquidator
    );
    event DebtRepaid(uint256 indexed lendingId, address indexed payer, uint256 amount, bool fullyRepaid);
    event CollateralClaimedByLender(uint256 indexed lendingId, uint256 supplyTokenClaimed, uint256 borrowTokenClaimed);

    address internal borrower = address(0x1);
    address internal lender = address(0x2);

    uint256 constant UNRELATED_SUPPLY = 500 ether;
    uint256 constant UNRELATED_BORROW = 1000 ether;

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 50 ether;
    uint48 constant LOAN_TERM = 30 days;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory supplyAccounts = new address[](1);
        supplyAccounts[0] = borrower;
        _fundSupply(supplyAccounts, 1000 ether);

        address[] memory borrowAccounts = new address[](2);
        borrowAccounts[0] = lender;
        borrowAccounts[1] = borrower;
        _fundBorrow(borrowAccounts, 1000 ether);

        _approveLendingBoth(borrower);
        _approveLendingBorrow(lender);

        _seedUnrelated(UNRELATED_SUPPLY, UNRELATED_BORROW);
    }

    function testHappyPath_BorrowAndRepayOnTime() public {
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);
        uint256 lendingSupplyBefore = supplyToken.balanceOf(address(lending));

        // 1. Borrower opens borrow request — emits BorrowRequested
        vm.expectEmit(true, true, false, true, address(lending));
        emit BorrowRequested(
            borrower,
            1,
            address(supplyToken),
            address(borrowToken),
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            LOAN_TERM,
            8e6,                 // liquidationThreshold per _requestBorrow
            100,                 // stake per _requestBorrow
            _standardOracleParams(),
            _standardInterestRateParams()
        );
        uint256 lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        assertEq(lendingId, 1, "First lending ID should be 1");

        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore - SUPPLY_AMOUNT,
            "Borrower should have sent collateral"
        );
        assertEq(
            supplyToken.balanceOf(address(lending)),
            lendingSupplyBefore + SUPPLY_AMOUNT,
            "Lending contract should have received collateral"
        );

        // 2. Lender accepts the curve at startingRate (no time has passed)
        uint32 expectedRate = _standardInterestRateParams().startingRate;
        vm.expectEmit(true, true, false, true, address(lending));
        emit LoanOriginated(lendingId, lender, BORROW_AMOUNT, expectedRate, uint48(block.timestamp), LOAN_TERM, false);
        _lend(lender, lendingId);

        // Borrower received funds
        assertEq(
            borrowToken.balanceOf(borrower),
            borrowerBorrowBefore + BORROW_AMOUNT,
            "Borrower should have received borrow amount"
        );
        assertEq(
            borrowToken.balanceOf(lender), lenderBorrowBefore - BORROW_AMOUNT, "Lender should have sent borrow amount"
        );

        // 3. Verify loan state
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.term, LOAN_TERM, "Term should match");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT, "Supply amount should match");
        assertEq(loan.borrowAmount, BORROW_AMOUNT, "Borrow amount should match");
        assertEq(loan.rate, expectedRate, "Rate should be the curve rate at lend time");
        assertEq(loan.start, block.timestamp, "Start should be now");
        assertTrue(loan.active, "Loan should be active");
        assertFalse(loan.finished, "Loan should not be finished");
        assertFalse(loan.curveOpen, "Curve should be closed after lend");
        assertEq(loan.borrower, borrower, "Borrower should match");
        assertEq(loan.lender, lender, "Lender should match");

        // 4. Repay at maturity-equivalent debt mid-loan
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, expectedRate, LOAN_TERM);

        vm.warp(block.timestamp + 15 days);
        uint256 borrowerBorrowBeforeRepay = borrowToken.balanceOf(borrower);
        uint256 borrowerSupplyBeforeRepay = supplyToken.balanceOf(borrower);
        uint256 lenderBorrowBeforeRepay = borrowToken.balanceOf(lender);

        vm.expectEmit(true, true, false, true, address(lending));
        emit DebtRepaid(lendingId, borrower, totalOwed, true);
        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished after full repayment");

        assertEq(
            borrowToken.balanceOf(borrower),
            borrowerBorrowBeforeRepay - totalOwed,
            "Borrower should have paid total owed"
        );
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBeforeRepay + SUPPLY_AMOUNT,
            "Borrower should have received collateral back"
        );
        assertEq(
            borrowToken.balanceOf(lender), lenderBorrowBeforeRepay + totalOwed, "Lender should have received total owed"
        );

        // Unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply untouched");
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow untouched");
    }

    function testLateRepay_LenderClaimsCollateral() public {
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);

        uint256 lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        uint32 rate = lending.getLending(lendingId).rate;

        vm.warp(block.timestamp + LOAN_TERM + 1);

        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "expired"));
        lending.repayDebt(lendingId, totalOwed, bytes32(0), 0, 0);

        vm.expectEmit(true, false, false, true, address(lending));
        emit CollateralClaimedByLender(lendingId, SUPPLY_AMOUNT, 0);
        lending.claimCollateral(lendingId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.finished, "Loan should be finished after claim");

        assertEq(
            supplyToken.balanceOf(lender), lenderSupplyBefore + SUPPLY_AMOUNT, "Lender should have received collateral"
        );
        assertEq(
            borrowToken.balanceOf(lender),
            lenderBorrowBefore - BORROW_AMOUNT,
            "Lender should still be down the borrow amount"
        );
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply untouched");
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow untouched");
    }

    function testPartialRepayThenLate_LenderGetsCollateralAndPartialRepay() public {
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);

        uint256 lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        uint128 partialRepayment = 20 ether;
        vm.warp(block.timestamp + 15 days);

        vm.prank(borrower);
        lending.repayDebt(lendingId, partialRepayment, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.repaidDebt, partialRepayment, "Repaid debt should match partial payment");

        vm.warp(block.timestamp + LOAN_TERM);

        lending.claimCollateral(lendingId);

        assertEq(
            supplyToken.balanceOf(lender), lenderSupplyBefore + SUPPLY_AMOUNT, "Lender should have received collateral"
        );
        assertEq(
            borrowToken.balanceOf(lender),
            lenderBorrowBefore - BORROW_AMOUNT + partialRepayment,
            "Lender should have received partial repayment"
        );

        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY);
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW);
    }

    function testInterestCalculation() public pure {
        uint256 owed1 = _calculateOwedAtMaturityPure(100 ether, 1e8, 365 days);
        assertEq(owed1, 110 ether, "1 year at 10% should be 110 total");

        uint256 owed2 = _calculateOwedAtMaturityPure(100 ether, 1e8, 30 days);
        uint256 expectedInterest30d = (100 ether * uint256(30 days) * uint256(1e8)) / (1e9 * 365 days);
        assertEq(owed2, 100 ether + expectedInterest30d, "30 days interest calculation");

        uint256 owed3 = _calculateOwedAtMaturityPure(50 ether, 2e8, 182 days);
        uint256 expectedInterest6mo = (50 ether * uint256(182 days) * uint256(2e8)) / (1e9 * 365 days);
        assertEq(owed3, 50 ether + expectedInterest6mo, "6 months at 20% calculation");
    }

    function _calculateOwedAtMaturityPure(uint256 principal, uint32 rate, uint48 term) internal pure returns (uint128) {
        uint256 year = 365 days;
        uint256 interest = (principal * uint256(term) * uint256(rate)) / (1e9 * year);
        return uint128(principal + interest);
    }

    function testCannotBorrow0() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "cant borrow 0"));
        lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            0,                    // amountDemanded = 0
            100,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    function testCannotSupply0() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "cant supply 0"));
        lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            0,                    // supplyAmount = 0
            BORROW_AMOUNT,
            100,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    // ---------------- lend() paramHash (origination) ----------------

    /// @dev Third-party full repayment via repayAnyDebt: payer funds the debt, BORROWER gets the collateral back.
    function testRepayAnyDebt_ThirdPartyFullRepay_CollateralToBorrower() public {
        uint256 lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        uint32 rate = lending.getLending(lendingId).rate;
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);

        // Third-party payer (not borrower, not lender)
        address payer = address(0xCAFE);
        borrowToken.transfer(payer, totalOwed);
        vm.prank(payer);
        borrowToken.approve(address(lending), type(uint256).max);

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);
        uint256 payerBorrowBefore = borrowToken.balanceOf(payer);
        uint256 payerSupplyBefore = supplyToken.balanceOf(payer);

        vm.prank(payer);
        lending.repayAnyDebt(lendingId, totalOwed, bytes32(0), 0, 0);

        // Loan finished
        assertTrue(lending.getLending(lendingId).finished, "loan should be finished");

        // Payer paid the debt
        assertEq(borrowToken.balanceOf(payer), payerBorrowBefore - totalOwed, "payer paid debt");
        // Lender received their owed amount
        assertEq(borrowToken.balanceOf(lender), lenderBorrowBefore + totalOwed, "lender received debt");
        // Borrower (NOT payer) received the collateral
        assertEq(supplyToken.balanceOf(borrower), borrowerSupplyBefore + SUPPLY_AMOUNT, "borrower received collateral");
        assertEq(supplyToken.balanceOf(payer), payerSupplyBefore, "payer should not receive collateral");
        // Borrower's borrow balance unchanged
        assertEq(borrowToken.balanceOf(borrower), borrowerBorrowBefore, "borrower borrow balance untouched");
    }

    function testLend_OriginationAcceptsCorrectParamHash() public {
        uint256 lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        bytes32 hash = lending.getParamHash(lendingId);

        vm.prank(lender);
        lending.lend(lendingId, hash, 0, type(uint128).max, 0, 0, false);

        assertTrue(lending.getLending(lendingId).active, "origination should succeed with correct hash");
    }

    function testLend_OriginationRejectsWrongParamHash() public {
        uint256 lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        bytes32 wrong = bytes32(uint256(0xdead));
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "params"));
        lending.lend(lendingId, wrong, 0, type(uint128).max, 0, 0, false);
    }

    /// @dev Replaces the V2 "view the offer" test. V3 has no offer slot — the curve is the offer.
    /// Verify that getLending returns sensible state pre-acceptance.
    function testLendingViewFunction() public {
        uint256 lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.borrower, borrower, "borrower set");
        assertEq(loan.lender, address(0), "no lender pre-acceptance");
        assertEq(loan.amountDemanded, BORROW_AMOUNT, "amountDemanded set");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT, "supplyAmount set");
        assertEq(loan.term, LOAN_TERM, "term set");
        assertTrue(loan.curveOpen, "curve should be open after requestBorrow");
        assertFalse(loan.active, "loan not active until lend()");
        assertFalse(loan.cancelled, "not cancelled");
        assertFalse(loan.finished, "not finished");
        assertEq(loan.requestStart, uint48(block.timestamp), "requestStart pinned to now");
    }
}
