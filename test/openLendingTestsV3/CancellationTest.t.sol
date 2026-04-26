// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "./OpenLendingBase.t.sol";

contract CancellationTest is OpenLendingBaseTest {
    event BorrowRequestCancelled(address indexed borrower, uint256 indexed lendingId);
    event RefiCancelled(uint256 indexed lendingId);

    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal otherLender = address(0x3);
    address internal randomUser = address(0x4);

    // Unrelated funds to verify no skimming
    uint256 constant UNRELATED_SUPPLY = 500e18;
    uint256 constant UNRELATED_BORROW = 1000e18;

    // Loan parameters
    uint128 constant SUPPLY_AMOUNT = 100e18;
    uint128 constant BORROW_AMOUNT = 70e18;
    uint48 constant LOAN_TERM = 30 days;

    function setUp() public {
        _deployCore("Supply", "SUP", "Borrow", "BOR");

        address[] memory supplyAccounts = new address[](1);
        supplyAccounts[0] = borrower;
        _fundSupply(supplyAccounts, 1000e18);

        address[] memory borrowAccounts = new address[](2);
        borrowAccounts[0] = lender;
        borrowAccounts[1] = otherLender;
        _fundBorrow(borrowAccounts, 1000e18);

        _seedUnrelated(UNRELATED_SUPPLY, UNRELATED_BORROW);

        _approveLendingSupply(borrower);
        _approveLendingBorrow(lender);
        _approveLendingBorrow(otherLender);
    }

    // =========================================================================
    // cancelBorrowRequest — borrower closes a pre-acceptance request
    // =========================================================================

    function testCancelBorrowRequest_Success() public {
        uint256 lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 contractSupplyBefore = supplyToken.balanceOf(address(lending));

        vm.expectEmit(true, true, false, true, address(lending));
        emit BorrowRequestCancelled(borrower, lendingId);
        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        // Borrower gets collateral back
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "Borrower should receive collateral back"
        );

        // Contract balance decreased by exactly SUPPLY_AMOUNT
        assertEq(
            supplyToken.balanceOf(address(lending)),
            contractSupplyBefore - SUPPLY_AMOUNT,
            "Contract should lose exactly SUPPLY_AMOUNT"
        );

        // Unrelated funds untouched
        assertEq(
            supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply funds should be untouched"
        );
        assertEq(
            borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow funds should be untouched"
        );

        // Verify cancelled state and curveOpen cleared (defense-in-depth)
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.cancelled, "Loan should be marked as cancelled");
        assertFalse(loan.curveOpen, "Curve should be closed after cancellation");
    }

    function testCancelBorrowRequest_FailsAfterAccepted() public {
        uint256 lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        // Borrower tries to cancel after origination — should fail because loan is active
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "lendingId active"));
        lending.cancelBorrowRequest(lendingId);
    }

    function testCancelBorrowRequest_FailsIfAlreadyCancelled() public {
        uint256 lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "lendingId cancelled"));
        lending.cancelBorrowRequest(lendingId);
    }

    function testCancelBorrowRequest_FailsIfNotBorrower() public {
        uint256 lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "msg.sender"));
        lending.cancelBorrowRequest(lendingId);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "msg.sender"));
        lending.cancelBorrowRequest(lendingId);
    }

    /// @dev After cancellation, lend() must be unable to fire on this lendingId.
    function testCancelBorrowRequest_BlocksSubsequentLend() public {
        uint256 lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "cancelled"));
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);
    }

    // =========================================================================
    // cancelRefinance — borrower closes an open refi curve before acceptance
    // =========================================================================

    function testCancelRefinance_Success() public {
        uint256 lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        // Borrower opens a refi curve
        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,                           // extraDemanded
            0,                           // supplyPulled
            0,                           // newTerm (keep)
            _standardInterestRateParams(),
            bytes32(0),
            0,
            0
        );

        // Curve is now open
        openLend.LendingArrangement memory before = lending.getLending(lendingId);
        assertTrue(before.curveOpen, "curve should be open after refinance()");

        // Cancel the refi
        vm.expectEmit(true, false, false, true, address(lending));
        emit RefiCancelled(lendingId);
        vm.prank(borrower);
        lending.cancelRefinance(lendingId);

        // Curve closed and refi params cleared
        openLend.LendingArrangement memory after_ = lending.getLending(lendingId);
        assertFalse(after_.curveOpen, "curve should be closed");
        openLend.RefiParams memory rp = lending.getRefiParams(lendingId);
        assertEq(rp.extraDemanded, 0, "extraDemanded cleared");
        assertEq(rp.supplyPulled, 0, "supplyPulled cleared");
        assertEq(rp.newTerm, 0, "newTerm cleared");

        // Loan is still active and live (cancelRefinance does not finish the loan)
        assertTrue(after_.active, "loan should still be active");
        assertFalse(after_.finished, "loan should not be finished");
        assertFalse(after_.cancelled, "loan should not be cancelled");
    }

    function testCancelRefinance_FailsIfNotBorrower() public {
        uint256 lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, _standardInterestRateParams(), bytes32(0), 0, 0);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "not borrower"));
        lending.cancelRefinance(lendingId);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "not borrower"));
        lending.cancelRefinance(lendingId);
    }

    function testCancelRefinance_FailsIfCurveNotOpen() public {
        uint256 lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        // No refinance has been opened
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "curve is not open"));
        lending.cancelRefinance(lendingId);
    }

    function testCancelRefinance_FailsIfLoanNotActive() public {
        // Borrow request created but no lender accepted yet
        uint256 lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "not active"));
        lending.cancelRefinance(lendingId);
    }

    function testCancelRefinance_FailsIfDoubleCancel() public {
        uint256 lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, _standardInterestRateParams(), bytes32(0), 0, 0);

        vm.prank(borrower);
        lending.cancelRefinance(lendingId);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "curve is not open"));
        lending.cancelRefinance(lendingId);
    }

    /// @dev After cancellation the loan continues; another refi can be opened.
    function testCancelRefinance_AllowsReopening() public {
        uint256 lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, _standardInterestRateParams(), bytes32(0), 0, 0);

        vm.prank(borrower);
        lending.cancelRefinance(lendingId);

        // Reopen successfully
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, _standardInterestRateParams(), bytes32(0), 0, 0);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.curveOpen, "curve should be reopened");
    }
}
