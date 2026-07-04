// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LendErrors} from "../../src/libraries/LendErrors.sol";
import "./OpenLendingBase.t.sol";

/// @notice Pins the smooth interpolation of `commitmentFraction`: close-out interest = max(committed, accrued).
///         The two extremes (0 = pure accrued, 1e7 = full term) were already covered in FlexibleRepaymentTest;
///         this file pins the intermediate inflection behavior — the whole point of the smooth dial.
contract CommitmentFractionTest is OpenLendingBaseTest {
    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal lender2 = address(0x3);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 70 ether;
    uint48 constant LOAN_TERM = 30 days;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accounts = new address[](3);
        accounts[0] = borrower;
        accounts[1] = lender;
        accounts[2] = lender2;
        _fundSupply(accounts, 10_000 ether);
        _fundBorrow(accounts, 10_000 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(lender2);
    }

    function _setup(uint24 commitmentFraction) internal returns (uint256 lendingId) {
        lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, commitmentFraction, 0);
        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 5e6, lender, address(0));
        vm.stopPrank();
    }

    /// @dev Compute interest for a given elapsed-equivalent (effectiveElapsed) under the contract's formula.
    function _interest(uint128 amount, uint32 rate, uint256 effectiveElapsed) internal pure returns (uint256) {
        uint256 year = 365 days;
        return (uint256(amount) * effectiveElapsed * uint256(rate)) / (1e9 * year);
    }

    // -------------------------------------------------------------------------
    // Inside-window: closing at any t < commitWindow charges committed interest (flat)
    // -------------------------------------------------------------------------

    function testCommitment_FlatInsideWindow_50pct() public {
        // commitmentFraction = 50% → commitWindow = 15 days
        uint256 lendingId = _setup(5e6);
        uint32 rate = lendView.getLending(lendingId).rate;
        uint256 commitWindow = uint256(LOAN_TERM) * 5e6 / 1e7; // 15 days
        uint256 expectedInterest = _interest(BORROW_AMOUNT, rate, commitWindow);

        // Close at day 1
        vm.warp(block.timestamp + 1 days);
        uint256 borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(lendingId, type(uint128).max, bytes32(0), 0, type(uint128).max, false);
        assertEq(
            borrowerBefore - borrowToken.balanceOf(borrower),
            uint256(BORROW_AMOUNT) + expectedInterest,
            "day 1 inside window: pays committed (15d) interest"
        );
    }

    function testCommitment_FlatAtMidWindow_70pct() public {
        // commitmentFraction = 70% → commitWindow = 21 days
        uint256 lendingId = _setup(7e6);
        uint32 rate = lendView.getLending(lendingId).rate;
        uint256 commitWindow = uint256(LOAN_TERM) * 7e6 / 1e7; // 21 days
        uint256 expectedInterest = _interest(BORROW_AMOUNT, rate, commitWindow);

        // Close at day 10 — well inside the 21-day commit window
        vm.warp(block.timestamp + 10 days);
        uint256 borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(lendingId, type(uint128).max, bytes32(0), 0, type(uint128).max, false);
        assertEq(
            borrowerBefore - borrowToken.balanceOf(borrower),
            uint256(BORROW_AMOUNT) + expectedInterest,
            "day 10 inside 21d window: pays committed interest"
        );
    }

    // -------------------------------------------------------------------------
    // Boundary: closing exactly at commitWindow → committed = accrued
    // -------------------------------------------------------------------------

    function testCommitment_AtBoundary_50pct() public {
        // commitmentFraction = 50% → commitWindow = 15 days. Close exactly at day 15.
        uint256 lendingId = _setup(5e6);
        uint32 rate = lendView.getLending(lendingId).rate;
        uint256 commitWindow = uint256(LOAN_TERM) * 5e6 / 1e7;
        uint256 expectedInterest = _interest(BORROW_AMOUNT, rate, commitWindow);

        vm.warp(block.timestamp + 15 days);
        uint256 borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(lendingId, type(uint128).max, bytes32(0), 0, type(uint128).max, false);

        // At the boundary committed == accrued, both formulas yield the same result.
        assertEq(
            borrowerBefore - borrowToken.balanceOf(borrower),
            uint256(BORROW_AMOUNT) + expectedInterest,
            "boundary at day 15: committed equals accrued"
        );
    }

    // -------------------------------------------------------------------------
    // Past boundary: closing at any t > commitWindow charges accrued (rises with elapsed)
    // -------------------------------------------------------------------------

    function testCommitment_AccruedPastBoundary_50pct() public {
        // 50% commitment, commitWindow = 15 days. Close at day 20, day 25.
        uint256 lendingId1 = _setup(5e6);
        uint256 lendingId2 = _setup(5e6);
        uint32 rate = lendView.getLending(lendingId1).rate;

        // Day 20 close on loan 1
        vm.warp(block.timestamp + 20 days);
        uint256 expectedAt20 = _interest(BORROW_AMOUNT, rate, 20 days);
        uint256 borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(lendingId1, type(uint128).max, bytes32(0), 0, type(uint128).max, false);
        assertEq(
            borrowerBefore - borrowToken.balanceOf(borrower),
            uint256(BORROW_AMOUNT) + expectedAt20,
            "day 20 past boundary: pays accrued (20d) interest"
        );

        // Day 25 close on loan 2 (warp another 5 days)
        vm.warp(block.timestamp + 5 days);
        uint256 expectedAt25 = _interest(BORROW_AMOUNT, rate, 25 days);
        borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(lendingId2, type(uint128).max, bytes32(0), 0, type(uint128).max, false);
        assertEq(
            borrowerBefore - borrowToken.balanceOf(borrower),
            uint256(BORROW_AMOUNT) + expectedAt25,
            "day 25 past boundary: pays accrued (25d) interest"
        );
    }

    // -------------------------------------------------------------------------
    // Maturity / past maturity always pays full-term interest regardless of fraction
    // -------------------------------------------------------------------------

    function testCommitment_NearMaturity_FractionIrrelevant() public {
        // At elapsed close to term, accrued > any committed amount, so both 50% and 90% loans charge the same
        // (accrued at that elapsed). Confirms commitmentFraction has no effect at maturity.
        uint256 lendingId50 = _setup(5e6);
        uint256 lendingId90 = _setup(9e6);
        uint32 rate = lendView.getLending(lendingId50).rate;
        // Both started at the same block.timestamp; close 1 sec before maturity (exact maturity reverts as expired).
        uint256 elapsedAtClose = uint256(LOAN_TERM) - 1;
        uint256 expectedInterest = _interest(BORROW_AMOUNT, rate, elapsedAtClose);

        vm.warp(block.timestamp + LOAN_TERM - 1);

        uint256 borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(lendingId50, type(uint128).max, bytes32(0), 0, type(uint128).max, false);
        assertEq(
            borrowerBefore - borrowToken.balanceOf(borrower),
            uint256(BORROW_AMOUNT) + expectedInterest,
            "50% fraction near maturity: pays accrued"
        );

        borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(lendingId90, type(uint128).max, bytes32(0), 0, type(uint128).max, false);
        assertEq(
            borrowerBefore - borrowToken.balanceOf(borrower),
            uint256(BORROW_AMOUNT) + expectedInterest,
            "90% fraction near maturity: pays same accrued (fraction doesn't matter once past boundary)"
        );
    }

    // -------------------------------------------------------------------------
    // Refi prior-lender payout follows the same inflection logic
    // -------------------------------------------------------------------------

    function testCommitment_RefiPaysPriorLenderCommitted_InsideWindow() public {
        // 50% commitment, refi at day 5 (well inside 15-day window) → prior lender paid committed (15d) interest.
        uint256 lendingId = _setup(5e6);
        uint32 rate = lendView.getLending(lendingId).rate;
        uint256 commitWindow = uint256(LOAN_TERM) * 5e6 / 1e7;
        uint256 expectedInterest = _interest(BORROW_AMOUNT, rate, commitWindow);

        vm.warp(block.timestamp + 5 days);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        uint256 lenderBefore = borrowToken.balanceOf(lender);
        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 5e6, lender2, address(0));
        vm.stopPrank();

        assertEq(
            borrowToken.balanceOf(lender) - lenderBefore,
            uint256(BORROW_AMOUNT) + expectedInterest,
            "prior lender at day 5 (inside 15d window) paid committed interest"
        );
        // New principal = committed payout
        assertEq(
            lendView.getLending(lendingId).principal,
            uint256(BORROW_AMOUNT) + expectedInterest,
            "new principal = prior owed"
        );
    }

    function testCommitment_RefiPaysPriorLenderAccrued_PastBoundary() public {
        // 50% commitment, refi at day 22 (past 15-day window) → prior lender paid accrued (22d) interest.
        uint256 lendingId = _setup(5e6);
        uint32 rate = lendView.getLending(lendingId).rate;
        uint256 expectedInterest = _interest(BORROW_AMOUNT, rate, 22 days);

        vm.warp(block.timestamp + 22 days);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        uint256 lenderBefore = borrowToken.balanceOf(lender);
        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 5e6, lender2, address(0));
        vm.stopPrank();

        assertEq(
            borrowToken.balanceOf(lender) - lenderBefore,
            uint256(BORROW_AMOUNT) + expectedInterest,
            "prior lender at day 22 (past 15d boundary) paid accrued interest"
        );
    }

    // -------------------------------------------------------------------------
    // Validation
    // -------------------------------------------------------------------------

    function testCommitment_RejectsCommitmentFractionAboveBound() public {
        vm.prank(borrower);
        vm.expectRevert(LendErrors.CommitmentFractionTooHigh.selector);
        lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            uint24(1e7 + 1),
            0,
            borrower,address(0),
            
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }
}
