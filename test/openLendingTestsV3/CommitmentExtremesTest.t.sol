// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";

/// @notice Pins the two `commitmentFraction` extremes — 0 (pure prorated, "fully flexible") and 1e7 (full-term
///         locked yield). Both cases need the close-out / refi math to behave like the legacy boolean would have.
///         (CommitmentFractionTest covers the smooth interpolation in between.) No boolean flag exists on the
///         contract anymore — `commitmentFraction` is the single dial.
contract CommitmentExtremesTest is OpenLendingBaseTest {
    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal lender2 = address(0x3);
    address internal liquidator = address(0x4);
    address internal disputer = address(0x5);
    address internal settler = address(0x6);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 70 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint16 constant STAKE = 100;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accounts = new address[](5);
        accounts[0] = borrower;
        accounts[1] = lender;
        accounts[2] = lender2;
        accounts[3] = liquidator;
        accounts[4] = disputer;
        _fundSupply(accounts, 10_000 ether);
        _fundBorrow(accounts, 10_000 ether);

        address[] memory ethAccounts = new address[](6);
        ethAccounts[0] = borrower;
        ethAccounts[1] = lender;
        ethAccounts[2] = lender2;
        ethAccounts[3] = liquidator;
        ethAccounts[4] = disputer;
        ethAccounts[5] = settler;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(lender2);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);
    }

    function _setup(uint24 commitmentFraction) internal returns (uint256 lendingId) {
        lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, commitmentFraction, 0);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6);
    }

    function _owedNow(uint128 amount, uint32 rate, uint48 term, uint48 start) internal view returns (uint256) {
        uint256 year = 365 days;
        uint256 elapsed = block.timestamp > start ? block.timestamp - start : 0;
        if (elapsed > term) elapsed = term;
        return uint256(amount) + (uint256(amount) * elapsed * uint256(rate)) / (1e9 * year);
    }

    // -------------------------------------------------------------------------
    // Storage / event
    // -------------------------------------------------------------------------

    function testCommitment_StorageReflectsRequestParam() public {
        uint256 zeroId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, 0, 0);
        uint256 fullId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, 1e7, 0);
        uint256 halfId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, 5e6, 0);

        assertEq(lending.getLending(zeroId).commitmentFraction, 0, "0 stored");
        assertEq(lending.getLending(fullId).commitmentFraction, 1e7, "1e7 stored");
        assertEq(lending.getLending(halfId).commitmentFraction, 5e6, "5e6 stored");
    }

    // -------------------------------------------------------------------------
    // Full repay math diverges between modes
    // -------------------------------------------------------------------------

    function testCommitmentZero_FullRepayUsesTotalOwedNow() public {
        uint256 lendingId = _setup(0);
        uint32 rate = lending.getLending(lendingId).rate;
        uint48 start = lending.getLending(lendingId).start;

        vm.warp(block.timestamp + 10 days);

        uint256 expectedNow = _owedNow(BORROW_AMOUNT, rate, LOAN_TERM, start);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);

        // Pass oversized amount to force full close branch
        vm.prank(borrower);
        lending.repayDebt(lendingId, type(uint128).max, bytes32(0), 0, type(uint128).max);

        // Borrower should have paid exactly totalOwedNow
        assertEq(borrowerBorrowBefore - borrowToken.balanceOf(borrower), expectedNow, "borrower pays exactly totalOwedNow");
        // Lender should have received exactly totalOwedNow
        assertEq(borrowToken.balanceOf(lender) - lenderBorrowBefore, expectedNow, "lender receives totalOwedNow");
        assertTrue(lending.getLending(lendingId).finished, "finished");
    }

    function testCommitmentFull_FullRepayUsesTotalOwedAtMaturity() public {
        uint256 lendingId = _setup(1e7);
        uint32 rate = lending.getLending(lendingId).rate;

        vm.warp(block.timestamp + 10 days);

        uint128 expectedMaturity = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);

        vm.prank(borrower);
        lending.repayDebt(lendingId, type(uint128).max, bytes32(0), 0, type(uint128).max);

        assertEq(borrowerBorrowBefore - borrowToken.balanceOf(borrower), expectedMaturity, "borrower pays totalOwedAtMaturity even mid-term");
    }

    function testCommitmentZero_MidTermCostsLessThanCommitmentFull() public {
        // Same loan, two modes — flexible should pay strictly less mid-term.
        uint256 flexLoan = _setup(0);
        uint256 fixedLoan = _setup(1e7);

        vm.warp(block.timestamp + 10 days);

        uint256 borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(flexLoan, type(uint128).max, bytes32(0), 0, type(uint128).max);
        uint256 flexCost = borrowerBefore - borrowToken.balanceOf(borrower);

        borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(fixedLoan, type(uint128).max, bytes32(0), 0, type(uint128).max);
        uint256 fixedCost = borrowerBefore - borrowToken.balanceOf(borrower);

        assertLt(flexCost, fixedCost, "zero-commitment costs less mid-term");
    }

    // -------------------------------------------------------------------------
    // Refi prior-lender payout diverges
    // -------------------------------------------------------------------------

    function testCommitmentZero_RefiPaysPriorLenderTotalOwedNow() public {
        uint256 lendingId = _setup(0);
        uint32 rate = lending.getLending(lendingId).rate;
        uint48 start = lending.getLending(lendingId).start;

        vm.warp(block.timestamp + 10 days);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        uint256 expectedNow = _owedNow(BORROW_AMOUNT, rate, LOAN_TERM, start);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);

        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6);

        assertEq(borrowToken.balanceOf(lender) - lenderBorrowBefore, expectedNow, "prev lender paid totalOwedNow under flex");
        assertEq(lending.getLending(lendingId).principal, expectedNow, "new principal = totalOwedNow");
    }

    function testCommitmentFull_RefiPaysPriorLenderTotalOwedAtMaturity() public {
        uint256 lendingId = _setup(1e7);
        uint32 rate = lending.getLending(lendingId).rate;

        vm.warp(block.timestamp + 10 days);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        uint256 expectedMaturity = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);

        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6);

        assertEq(borrowToken.balanceOf(lender) - lenderBorrowBefore, expectedMaturity, "prev lender paid totalOwedAtMaturity");
        assertEq(lending.getLending(lendingId).principal, expectedMaturity, "new principal = totalOwedAtMaturity");
    }

    // -------------------------------------------------------------------------
    // Partial-then-full with commitFrac=0: amortization reduces total interest cost
    // -------------------------------------------------------------------------

    function testCommitmentZero_PartialThenFullAmortizesInterest() public {
        uint256 lendingId = _setup(0);
        uint32 rate = lending.getLending(lendingId).rate;
        uint48 start = lending.getLending(lendingId).start;

        vm.warp(block.timestamp + 5 days);

        // Partial repayment — exceeds accrued-interest-so-far, so excess reduces principal.
        uint128 partialAmt = 5 ether;
        uint256 borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(lendingId, partialAmt, bytes32(0), 0, type(uint128).max);

        vm.warp(block.timestamp + 15 days); // total elapsed = 20 days

        // Hypothetical no-amort cost: full simple interest on original principal.
        uint256 noAmortCost = _owedNow(BORROW_AMOUNT, rate, LOAN_TERM, start);

        vm.prank(borrower);
        lending.repayDebt(lendingId, type(uint128).max, bytes32(0), 0, type(uint128).max);

        // Total borrower outlay should be STRICTLY LESS than the no-amort baseline since the partial
        // covered Phase-1 accrual and reduced principal, lowering future interest.
        uint256 totalPaid = borrowerBefore - borrowToken.balanceOf(borrower);
        assertLt(totalPaid, noAmortCost, "amortization should save interest vs naive simple-interest baseline");
    }

    // -------------------------------------------------------------------------
    // Liquidation math unaffected by flag
    // -------------------------------------------------------------------------

    function testLiquidation_IdenticalAcrossExtremes() public {
        uint256 flexLoan = _setup(0);
        uint256 fixedLoan = _setup(1e7);

        vm.warp(block.timestamp + 10 days);

        uint256 lenderBefore = supplyToken.balanceOf(lender);

        // Liquidate flex loan
        bytes32 paramHash = lending.getParamHash(flexLoan);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(flexLoan, 6 ether * 1e18 / 10 ether, type(uint128).max, paramHash, 0, 1e15);
        uint256 flexReportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(flexReportId);

        vm.warp(block.timestamp + 61);
        vm.prank(disputer);
        oracle.disputeAndSwap(flexReportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);
        vm.warp(block.timestamp + 301);
        vm.prank(settler);
        oracle.settle(flexReportId);

        uint256 lenderAfterFlexLiq = supplyToken.balanceOf(lender);
        uint256 flexPayout = lenderAfterFlexLiq - lenderBefore;

        // Liquidate fixed loan, same shape. Read timestamps from oracle storage to defeat via_ir block.timestamp hoisting.
        paramHash = lending.getParamHash(fixedLoan);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(fixedLoan, 6 ether * 1e18 / 10 ether, type(uint128).max, paramHash, 0, 1e15);
        uint256 fixedReportId = oracle.nextReportId() - 1;
        (stateHash,,,,,,) = oracle.extraData(fixedReportId);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(fixedReportId);
        vm.warp(uint256(reportTs) + 61);
        vm.prank(disputer);
        oracle.disputeAndSwap(fixedReportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);
        (,,, uint48 disputeTs,,,) = oracle.reportStatus(fixedReportId);
        vm.warp(uint256(disputeTs) + 301);
        vm.prank(settler);
        oracle.settle(fixedReportId);

        uint256 fixedPayout = supplyToken.balanceOf(lender) - lenderAfterFlexLiq;

        assertEq(flexPayout, fixedPayout, "underwater liq payout identical regardless of commitmentFraction");
    }

    // -------------------------------------------------------------------------
    // paramHash includes commitmentFraction
    // -------------------------------------------------------------------------

    function testCommitment_ParamHashDistinguishesExtremes() public {
        uint256 flexLoan = _setup(0);
        uint256 fixedLoan = _setup(1e7);

        bytes32 flexHash = lending.getParamHash(flexLoan);
        bytes32 fixedHash = lending.getParamHash(fixedLoan);

        assertTrue(flexHash != fixedHash, "paramHash must distinguish flex vs fixed even with otherwise identical loans");
    }
}
