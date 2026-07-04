// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";
import {LendErrors} from "../../src/libraries/LendErrors.sol";

/// @notice End-to-end coverage for the amortization model: principal/interestAccrued/interestPaid/commitmentInterest
///         state, residual-vs-mark-to-market debt, refi math, overflow guards, paramHash-with-zeroed-amort-fields,
///         liquidatorFraction splits, and settlerReward forwarding.
contract AmortizationTest is OpenLendingBaseTest {
    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal lender2 = address(0x3);
    address internal liquidator = address(0x4);
    address internal disputer = address(0x5);
    address internal settler = address(0x6);
    address internal randomCaller = address(0x7);
    address internal payer = address(0x8);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 50 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint16 constant STAKE = 100;
    uint96 constant SETTLER_REWARD = 1e15;

    uint256 constant ORACLE_SETTLEMENT_TIME = 300;
    uint256 constant ORACLE_DISPUTE_DELAY = 60;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accts = new address[](8);
        accts[0] = borrower;
        accts[1] = lender;
        accts[2] = lender2;
        accts[3] = liquidator;
        accts[4] = disputer;
        accts[5] = settler;
        accts[6] = randomCaller;
        accts[7] = payer;
        _fundSupply(accts, 10_000 ether);
        _fundBorrow(accts, 10_000 ether);
        _dealETH(accts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(lender2);
        _approveLendingBoth(liquidator);
        _approveLendingBoth(payer);
        _approveLendingBoth(randomCaller);
        _approveOracleBoth(disputer);
    }

    // ---------------- helpers ----------------

    function _setupActiveLoan(uint24 liquidatorFraction) internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        _lendWithFraction(lender, lendingId, liquidatorFraction);
    }

    function _liquidateAt(address by, uint256 lendingId, uint256 priceRatio18, uint96 settlerReward)
        internal returns (uint256 reportId)
    {
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;
        vm.prank(by);
        lending.liquidate{value: uint256(settlerReward) + finalizerReward}(
            lendingId, priceRatio18, type(uint128).max, paramHash, 0, settlerReward, by, finalizerReward, _emptyTiming()
        );
        reportId = oracle.nextReportId() - 1;
    }

    function _priceRatioFor(uint256 borrowSize) internal pure returns (uint256) {
        return borrowSize * 1e18 / 10 ether;
    }

    function _settleableAtFor(uint256 reportId) internal view returns (uint48) {
        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        (,,,,, uint48 settlementTime,,,,,,) = _reportMeta(reportId);
        return reportTs + settlementTime;
    }

    function _supplyExposure(address account) internal view returns (uint256) {
        uint256 internalBalance = IOpenOracle2(address(oracle)).tokenHolder(account, address(supplyToken));
        return supplyToken.balanceOf(account) + (internalBalance == 0 ? 0 : internalBalance - 1);
    }

    /// @dev Compute commitmentInterest the way the contract does, in the test scope.
    function _expectedCommitInt(uint128 principal, uint48 term, uint32 rate, uint24 commitFrac)
        internal pure returns (uint128)
    {
        return uint128(uint256(principal) * term * commitFrac * rate / (1e7 * 1e9 * 365 days));
    }

    function _setupLoanWithInterestRemainder() internal returns (uint256 lendingId) {
        lendingId = _setupActiveLoan(0);

        vm.warp(block.timestamp + 1);
        vm.prank(payer);
        lending.repayAnyDebt(lendingId, 1, bytes32(0), 0, type(uint128).max, false);

        assertGt(lendView.getLending(lendingId).interestRemainder, 0, "interestRemainder seeded");
    }

    // -------------------------------------------------------------------------
    // 1. Amortization Core
    // -------------------------------------------------------------------------

    /// @dev Partial repay below the unpaid interest claim only increases interestPaid; principal is unchanged.
    function testAmort_PartialBelowInterestClaim_OnlyInterestPaid() public {
        uint256 lendingId = _setupActiveLoan(0);
        openLend.LendingArrangement memory loanBefore = lendView.getLending(lendingId);
        uint128 commitInt = loanBefore.commitmentInterest;

        // Pay strictly less than the interest claim (commitInt at t=0).
        uint128 small = commitInt / 2;
        assertGt(small, 0, "commitInt must be > 1 wei for the test to be meaningful");
        vm.prank(borrower);
        lending.repayDebt(lendingId, small, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory loanAfter = lendView.getLending(lendingId);
        assertEq(loanAfter.principal, loanBefore.principal, "principal unchanged");
        assertEq(loanAfter.interestPaid, small, "interestPaid increased by partial");
    }

    function testAmort_ZeroRoundedTouchCarriesRemainder() public {
        uint128 tinySupply = 100_000;
        uint128 tinyBorrow = 10_000;
        uint48 term = 30 days;

        uint256 lendingId = _requestBorrowFlex(borrower, tinySupply, tinyBorrow, term, 0, 0);
        _lend(lender, lendingId);

        openLend.LendingArrangement memory loanBefore = lendView.getLending(lendingId);
        assertEq(loanBefore.commitmentInterest, 0, "commitment floor disabled");

        uint48 firstTouch = loanBefore.start + 1;
        vm.warp(firstTouch);
        vm.prank(payer);
        lending.repayAnyDebt(lendingId, 1, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory afterDust = lendView.getLending(lendingId);
        assertEq(afterDust.interestAccrued, 0, "sub-unit interest not booked");
        assertGt(afterDust.interestRemainder, 0, "sub-unit interest carried");
        assertEq(afterDust.lastTouch, firstTouch, "carried touch advances lastTouch");

        uint48 secondTouch = loanBefore.start + 40_000;
        vm.warp(secondTouch);
        vm.prank(payer);
        lending.repayAnyDebt(lendingId, 1, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory afterAccrual = lendView.getLending(lendingId);
        assertGt(afterAccrual.interestAccrued, 0, "elapsed time eventually accrues");
        assertEq(afterAccrual.lastTouch, secondTouch, "nonzero accrual advances lastTouch");
    }

    function testAmort_PerBlockTouchesMatchSingleTouchWithinOneUnit() public {
        uint48 term = 1801;
        uint256 streamedId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, term, 0, 0);
        _lend(lender, streamedId);

        uint256 singleId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, term, 0, 0);
        _lend(lender, singleId);

        uint48 start = lendView.getLending(streamedId).start;
        for (uint256 i = 1; i <= 150; ++i) {
            vm.warp(uint256(start) + i * 12);
            vm.prank(payer);
            lending.repayAnyDebt(streamedId, 1, bytes32(0), 0, type(uint128).max, false);
        }

        vm.warp(uint256(start) + 150 * 12);
        vm.prank(payer);
        lending.repayAnyDebt(singleId, 1, bytes32(0), 0, type(uint128).max, false);

        uint256 streamedAccrued = lendView.getLending(streamedId).interestAccrued;
        uint256 singleAccrued = lendView.getLending(singleId).interestAccrued;
        uint256 delta = streamedAccrued > singleAccrued
            ? streamedAccrued - singleAccrued
            : singleAccrued - streamedAccrued;

        assertLe(delta, 1, "per-block carry matches single touch within one base unit");
    }

    /// @dev Partial repay exceeding unpaid interest claim caps interestPaid at the claim and reduces principal.
    function testAmort_PartialAboveInterestClaim_ReducesPrincipal() public {
        uint256 lendingId = _setupActiveLoan(0);
        openLend.LendingArrangement memory loanBefore = lendView.getLending(lendingId);
        uint128 commitInt = loanBefore.commitmentInterest;

        uint128 big = commitInt + 5 ether;
        vm.prank(borrower);
        lending.repayDebt(lendingId, big, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory loanAfter = lendView.getLending(lendingId);
        assertEq(loanAfter.interestPaid, commitInt, "interestPaid caps at interest claim");
        assertEq(loanAfter.principal, loanBefore.principal - 5 ether, "excess reduces principal");
    }

    /// @dev After amortization, future interest accrues on reduced principal, not original.
    function testAmort_FutureInterestAccruesOnReducedPrincipal() public {
        uint256 lendingId = _setupActiveLoan(0);
        openLend.LendingArrangement memory loanInit = lendView.getLending(lendingId);
        uint128 commitInt = loanInit.commitmentInterest;

        // Pay a chunk that pushes principal down significantly.
        vm.prank(borrower);
        lending.repayDebt(lendingId, commitInt + 30 ether, bytes32(0), 0, type(uint128).max, false);
        openLend.LendingArrangement memory loanAfterPartial = lendView.getLending(lendingId);
        uint128 reducedPrincipal = loanAfterPartial.principal;
        assertEq(reducedPrincipal, BORROW_AMOUNT - 30 ether, "principal reduced");

        // Warp and trigger another touch via a 1-wei repay (repayDebt has _touchAmort).
        vm.warp(block.timestamp + 10 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, 1 wei, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory loanAfterTouch = lendView.getLending(lendingId);
        // Interest accrued during the 10-day window must equal `reducedPrincipal * 10d * rate / year`,
        // strictly less than what would have accrued on the original principal.
        uint256 expectedSegment = uint256(reducedPrincipal) * 10 days * loanInit.rate / (1e9 * 365 days);
        uint256 wouldHaveBeen = uint256(BORROW_AMOUNT) * 10 days * loanInit.rate / (1e9 * 365 days);
        uint256 actualSegment = uint256(loanAfterTouch.interestAccrued) - uint256(loanAfterPartial.interestAccrued);
        assertEq(actualSegment, expectedSegment, "accrual computed on current principal");
        assertLt(actualSegment, wouldHaveBeen, "amortization saved interest vs original principal");
    }

    /// @dev Full repay after partials pulls only the residual debt and finalizes the loan.
    function testAmort_FullAfterPartialPullsResidualAndFinishes() public {
        uint256 lendingId = _setupActiveLoan(0);

        vm.prank(borrower);
        lending.repayDebt(lendingId, 10 ether, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        uint128 commitInt = loan.commitmentInterest;
        // Residual = principal + max(commitInt, interestAccrued) - interestPaid. At ~t=0, accrued≈0 so floor binds.
        uint256 expectedResidual = uint256(loan.principal)
            + (uint256(loan.interestAccrued) > commitInt ? uint256(loan.interestAccrued) : commitInt)
            - uint256(loan.interestPaid);

        uint256 borrowerBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBefore = borrowToken.balanceOf(lender);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        vm.prank(borrower);
        lending.repayDebt(lendingId, type(uint128).max, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory loanFinal = lendView.getLending(lendingId);
        assertTrue(loanFinal.finished, "loan finished after full close");
        assertEq(borrowerBefore - borrowToken.balanceOf(borrower), expectedResidual, "borrower paid only residual");
        assertEq(borrowToken.balanceOf(lender) - lenderBefore, expectedResidual, "lender received residual");
        assertEq(supplyToken.balanceOf(borrower) - borrowerSupplyBefore, SUPPLY_AMOUNT, "borrower got collateral back");
    }

    /// @dev Full repay before any interest accrual still requires the commitment-floor interest.
    function testAmort_FullRepayPreFloor_RequiresCommitmentInterest() public {
        uint256 lendingId = _setupActiveLoan(0);
        uint128 commitInt = lendView.getLending(lendingId).commitmentInterest;

        uint256 borrowerBefore = borrowToken.balanceOf(borrower);
        vm.prank(borrower);
        lending.repayDebt(lendingId, type(uint128).max, bytes32(0), 0, type(uint128).max, false);

        // Borrower paid principal + commitInt (since accrued ≈ 0 < commitInt).
        uint256 paid = borrowerBefore - borrowToken.balanceOf(borrower);
        assertEq(paid, uint256(BORROW_AMOUNT) + uint256(commitInt), "full close pays principal + commitment floor");
    }

    // -------------------------------------------------------------------------
    // 2. Liquidation debt
    // -------------------------------------------------------------------------

    /// @dev Liquidation debt is the symmetric `_residualDebt` (= principal + max(accrued, commitInt) - paid),
    ///      so paying into the commitment floor cannot drive liquidation owed to zero — the floor is part of
    ///      the lender's claim and remains liquidatable. This guards against any regression to the old
    ///      mark-to-market `_liquidationOwed` that clamped at zero.
    function testLiqDebt_FloorIncludedInLiquidationDebt() public {
        // principal = 0.5 ether, rate = 2e9 (200% APR), term = 365 days, commitFrac = 1e7 → commitInt = 1 ether.
        openLend.InterestRateParams memory ir = _standardInterestRateParams();
        ir.maxRate = 2e9;
        ir.startingRate = 2e9;
        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            uint48(365 days),
            address(supplyToken),
            address(borrowToken),
            8e6,
            uint128(2 ether),     // supplyAmount
            uint128(0.5 ether),   // amountDemanded (= principal)
            STAKE,
            uint24(1e7),
            0,
            borrower,address(0),
            
            _standardOracleParams(),
            ir
        );
        _lendWithFraction(lender, lendingId, 0);

        // Pay 0.5 ether into the floor: payInt caps at commitInt; principal unchanged.
        vm.prank(borrower);
        lending.repayDebt(lendingId, uint128(0.5 ether), bytes32(0), 0, type(uint128).max, false);

        // _residualDebt = principal(0.5) + commitInt(1.0) - paid(0.5) = 1 ether → still liquidatable.
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(lendingId, _priceRatioFor(0.06 ether), type(uint128).max, paramHash, 0, 1e15, liquidator, 0, _emptyTiming());

        assertTrue(lendView.getLending(lendingId).inLiquidation,
            "liquidation succeeded; commitment floor counted toward liquidation debt");
    }

    /// @dev Healthy-position liquidation attempt resolves as failed-liq when collateral comfortably covers
    ///      the commitment-inclusive residual debt. (Liquidation debt = principal + max(accrued, commitInt) - paid.)
    function testLiqDebt_HealthyPositionFailedLiquidation() public {
        uint256 lendingId = _setupActiveLoan(0);
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(lendingId, _priceRatioFor(6 ether), type(uint128).max, paramHash, 0, 1e15, liquidator, 0, _emptyTiming());

        uint256 reportId = oracle.nextReportId() - 1;
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.finished, "failed-liq: residual stayed under threshold");
        assertFalse(loan.inLiquidation, "liq cleared");
    }

    /// @dev After borrower amortizes principal, the underwater determination uses the reduced principal.
    ///      A price that would have been underwater on full principal is no longer underwater post-amort.
    function testLiqDebt_PrincipalAmortReducesLiquidationExposure() public {
        uint256 lendingId = _setupActiveLoan(0);

        // Move past commitWindow boundary so additional payments amortize principal aggressively.
        vm.warp(block.timestamp + 1 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, 30 ether, bytes32(0), 0, type(uint128).max, false);
        openLend.LendingArrangement memory loanAfterAmort = lendView.getLending(lendingId);
        assertLt(loanAfterAmort.principal, BORROW_AMOUNT, "principal reduced");

        // Now price that would trip threshold on full principal but not on reduced.
        // liqThresh = 80 ether. borrowValueInSupplyTerms must exceed for underwater.
        // With reduced principal ≈ 25 ether, even at oracleAmount2 = 6 ether (priceRatio 6e17), debt-in-supply
        // ≈ 25 * 10/6 ≈ 41.6 ether < 80 ether → not underwater.
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        vm.expectRevert(LendErrors.InitialReportNotLiquidationEligible.selector);
        lending.liquidate{value: 1e15}(lendingId, _priceRatioFor(6 ether), type(uint128).max, paramHash, 0, 1e15, liquidator, 0, _emptyTiming());
    }

    // -------------------------------------------------------------------------
    // 3. Refinance
    // -------------------------------------------------------------------------

    /// @dev On refi acceptance, the new lender pays the previous lender exactly _residualDebt
    ///      (which includes the commitment floor when accrued < commitInt).
    function testRefi_PaysPreviousLenderResidualWithFloor() public {
        uint256 lendingId = _setupActiveLoan(0);
        uint128 commitInt = lendView.getLending(lendingId).commitmentInterest;

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max
        );

        uint256 lenderBefore = borrowToken.balanceOf(lender);
        uint256 lender2Before = borrowToken.balanceOf(lender2);

        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();

        // Old lender was paid principal + commitInt.
        assertEq(borrowToken.balanceOf(lender) - lenderBefore, uint256(BORROW_AMOUNT) + uint256(commitInt),
            "old lender paid residual incl. commitment floor");
        assertEq(lender2Before - borrowToken.balanceOf(lender2), uint256(BORROW_AMOUNT) + uint256(commitInt),
            "new lender outlay = residual");
    }

    /// @dev After a partial principal repayment, refi acceptance sets new principal to
    ///      residualDebt + extraDemanded.
    function testRefi_NewPrincipalEqualsResidualPlusExtra() public {
        uint256 lendingId = _setupActiveLoan(0);
        uint128 commitInt = lendView.getLending(lendingId).commitmentInterest;

        // Partial: covers commitInt then reduces principal.
        vm.prank(borrower);
        lending.repayDebt(lendingId, commitInt + 10 ether, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory midLoan = lendView.getLending(lendingId);
        uint256 expectedResidual = uint256(midLoan.principal)
            + (uint256(midLoan.interestAccrued) > commitInt ? uint256(midLoan.interestAccrued) : commitInt)
            - uint256(midLoan.interestPaid);

        uint128 extra = 5 ether;
        vm.prank(borrower);
        lending.refinance(
            lendingId, extra, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max
        );

        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();

        openLend.LendingArrangement memory finalLoan = lendView.getLending(lendingId);
        assertEq(uint256(finalLoan.principal), expectedResidual + uint256(extra),
            "new principal = residual + extraDemanded");
    }

    /// @dev Refi acceptance resets interestAccrued, interestRemainder, interestPaid, lastTouch,
    ///      and recomputes commitmentInterest.
    function testRefi_ResetsAmortStateAndRecomputesCommitInt() public {
        uint256 lendingId = _setupActiveLoan(0);

        // Touch & partial to create non-zero amort state.
        vm.warp(block.timestamp + 5 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, 10 ether, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory mid = lendView.getLending(lendingId);
        assertGt(mid.interestAccrued, 0, "accrued > 0 after time + partial");
        assertGt(mid.interestPaid, 0, "interestPaid > 0 after partial");
        assertEq(mid.lastTouch, uint48(block.timestamp), "lastTouch updated");

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max
        );

        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();

        openLend.LendingArrangement memory after_ = lendView.getLending(lendingId);
        assertEq(after_.interestAccrued, 0, "interestAccrued reset on refi");
        assertEq(after_.interestRemainder, 0, "interestRemainder reset on refi");
        assertEq(after_.interestPaid, 0, "interestPaid reset on refi");
        assertEq(after_.lastTouch, uint48(block.timestamp), "lastTouch set to refi-acceptance time");

        uint128 expected = _expectedCommitInt(after_.principal, after_.term, after_.rate, after_.commitmentFraction);
        assertEq(after_.commitmentInterest, expected, "commitmentInterest recomputed for new loan");
    }

    /// @dev Lender's minLendAmount/maxLendAmount catches a residual that has shrunk or grown beyond expectation.
    function testRefi_MinMaxLendAmountCatchAmortizedResidualDrift() public {
        uint256 lendingId = _setupActiveLoan(0);
        uint128 commitInt = lendView.getLending(lendingId).commitmentInterest;

        // Snapshot the residual the lender would compute.
        uint256 expectedResidual = uint256(BORROW_AMOUNT) + uint256(commitInt);

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max
        );

        // Borrower partial reduces residual below the minLendAmount the lender pinned.
        vm.prank(borrower);
        lending.repayDebt(lendingId, 5 ether, bytes32(0), 0, type(uint128).max, false);

        // Lender expects newBorrowAmount >= expectedResidual; partial shrunk it.
        bytes32 paramHashExpected2 = lendView.getParamHash(lendingId);
        vm.startPrank(lender2);
        vm.expectRevert(LendErrors.LendAmountOutOfBounds.selector);
        lending.lend(lendingId,paramHashExpected2, uint128(expectedResidual), type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // 4. Overflow / Bounds
    // -------------------------------------------------------------------------

    /// @dev requestBorrow reverts on residual overflow when principal × (1e9·year + term·maxRate) overflows uint128.
    function testOverflow_RequestBorrowRevertsOnResidualOverflow() public {
        openLend.InterestRateParams memory ir = _standardInterestRateParams();
        ir.maxRate = type(uint32).max;       // ≈ 4.29e9 (~430% APR)
        ir.startingRate = type(uint32).max;

        // Worst-case residual ≈ principal × (1 + maxRate × term / (1e9 × year)). With max-uint32 rate
        // and 1y term, factor ≈ 5.29. Pick principal × 5.29 > uint128.max → principal > uint128.max / 5.29.
        uint128 huge = uint128(uint256(type(uint128).max) / 3);   // safely overflows the bound
        deal(address(supplyToken), borrower, huge);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.ResidualOverflow.selector);
        lending.requestBorrow(
            uint48(365 days),
            address(supplyToken),
            address(borrowToken),
            8e6,
            huge,
            huge,
            STAKE,
            uint24(1e7),
            0,
            borrower,address(0),
            
            _standardOracleParams(),
            ir
        );
    }

    /// @dev Refi acceptance reverts on residual overflow. Combine a 1-year newTerm with maxed-out rate so
    ///      the per-principal multiplier is large enough that even a moderate `extra` blows the bound.
    function testOverflow_RefiAcceptanceRevertsOnResidualOverflow() public {
        uint256 lendingId = _setupActiveLoan(0);

        // Refi-time interest params: maxed-out rate so factor ≈ 1 + maxRate × term / (1e9 × year) is large.
        openLend.InterestRateParams memory hotIr = _standardInterestRateParams();
        hotIr.maxRate = type(uint32).max;
        hotIr.startingRate = type(uint32).max;

        // extra such that newBorrowAmount (= residualPrev + extra) overflows the residual bound under hotIr × 1y.
        // Bound triggers when newBorrowAmount × (1e9·year + term·rate) > uint128.max × 1e9·year.
        // With maxRate = ~4.3e9, term = 1y → factor ≈ 5.29 → newBorrowAmount > uint128.max / 5.29.
        uint128 extra = uint128(uint256(type(uint128).max) / 4);
        deal(address(borrowToken), lender2, type(uint256).max);

        vm.prank(borrower);
        lending.refinance(
            lendingId, extra, 0, uint48(365 days), 0, hotIr, _zeroOracleParams(),
            bytes32(0), 0, type(uint128).max
        );

        bytes32 paramHashExpected3 = lendView.getParamHash(lendingId);
        vm.startPrank(lender2);
        vm.expectRevert(LendErrors.ResidualOverflow.selector);
        lending.lend(lendingId,paramHashExpected3, 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();
    }

    /// @dev Boundary: just below the overflow threshold succeeds.
    function testOverflow_RequestBorrowJustBelowLimitSucceeds() public {
        openLend.InterestRateParams memory ir = _standardInterestRateParams();
        ir.maxRate = 1e9;
        ir.startingRate = 1e9;

        // residual ≈ principal × (1 + maxRate × term / (1e9 · year)). With maxRate=1e9, term=30 days
        // → factor ≈ 1.082. Pick principal = uint128.max / 2 → residual ≈ 0.54 × uint128.max < uint128.max.
        uint128 big = uint128(uint256(type(uint128).max) / 2);
        deal(address(supplyToken), borrower, big);

        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            uint48(30 days),
            address(supplyToken),
            address(borrowToken),
            8e6,
            big,
            big,
            STAKE,
            uint24(1e7),
            0,
            borrower,address(0),
            
            _standardOracleParams(),
            ir
        );
        assertGt(lendingId, 0, "borrow request created at the boundary");
    }

    // -------------------------------------------------------------------------
    // 5. Expected-state / Hash
    // -------------------------------------------------------------------------

    /// @dev getParamHash zeros principal, interestAccrued, interestRemainder, interestPaid,
    ///      and lastTouch — so a stale hash stays valid after partial repayments that change those fields.
    function testHash_StaleHashRemainsValidAfterAmortMutations() public {
        uint256 lendingId = _setupActiveLoan(0);
        bytes32 staleHash = lendView.getParamHash(lendingId);

        // Mutate the volatile fields with a partial repay.
        vm.prank(borrower);
        lending.repayDebt(lendingId, 5 ether, bytes32(0), 0, type(uint128).max, false);

        // Stale hash still validates: the fields it covers haven't changed.
        vm.prank(borrower);
        lending.repayDebt(lendingId, 1 ether, staleHash, 0, type(uint128).max, false);
    }

    function testHash_RoundTripWithInterestRemainderRepayTopUpAndLend() public {
        uint256 repayId = _setupLoanWithInterestRemainder();
        bytes32 repayHash = lendView.getParamHash(repayId);
        vm.prank(borrower);
        lending.repayDebt(repayId, 1, repayHash, 0, type(uint128).max, false);

        uint256 topUpId = _setupLoanWithInterestRemainder();
        bytes32 topUpHash = lendView.getParamHash(topUpId);
        vm.prank(borrower);
        lending.topUpCollateral(topUpId, 1, topUpHash, 0, type(uint128).max);

        uint256 lendId = _setupLoanWithInterestRemainder();
        vm.prank(borrower);
        lending.refinance(
            lendId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max
        );
        vm.warp(block.timestamp + 1);
        vm.prank(payer);
        lending.repayAnyDebt(lendId, 1, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory lendLoan = lendView.getLending(lendId);
        assertGt(lendLoan.interestRemainder, 0, "lend path remainder seeded");

        bytes32 lendHash = lendView.getParamHash(lendId);
        vm.prank(lender2);
        lending.lend(lendId, lendHash, 0, type(uint128).max, 0, 0, 0, lender2, address(0));
    }

    /// @dev expectedMaxPrincipal rejects when principal exceeds the cap.
    function testHash_ExpectedMaxPrincipalRejectsAboveCap() public {
        uint256 lendingId = _setupActiveLoan(0);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.PrincipalTooHigh.selector);
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, uint128(BORROW_AMOUNT - 1), false);
    }

    /// @dev After a partial repayment that reduces principal, expectedMaxPrincipal can pin the lower value:
    ///      a cap at the new principal succeeds, a cap below reverts.
    function testHash_ExpectedMaxPrincipalPinsAmortizedValue() public {
        uint256 lendingId = _setupActiveLoan(0);
        uint128 commitInt = lendView.getLending(lendingId).commitmentInterest;

        vm.prank(borrower);
        lending.repayDebt(lendingId, commitInt + 5 ether, bytes32(0), 0, type(uint128).max, false);

        uint128 newPrincipal = lendView.getLending(lendingId).principal;
        uint128 lowCap = newPrincipal / 2;

        // Cap below current principal reverts.
        vm.prank(borrower);
        vm.expectRevert(LendErrors.PrincipalTooHigh.selector);
        lending.repayDebt(lendingId, 1 wei, bytes32(0), 0, lowCap, false);

        // Cap at current principal passes (no revert).
        vm.prank(borrower);
        lending.repayDebt(lendingId, 1 wei, bytes32(0), 0, newPrincipal, false);
    }

    /// @dev getParamHash projects the failed-liq state with amort fields zeroed; the projected hash
    ///      validates inside lend() after autoSettle resolves the failed liquidation.
    function testHash_ProjectedFailedLiqHashAcceptedByLend() public {
        uint256 lendingId = _setupActiveLoan(0);
        vm.warp(block.timestamp + 1 days);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(6 ether), 1e15);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max
        );

        uint48 settleableAt = _settleableAtFor(reportId);
        vm.warp(uint256(settleableAt) + 5);

        bytes32 projected = lendView.getParamHash(lendingId);
        vm.prank(lender2);
        lending.lend(lendingId, projected, 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        assertEq(lendView.getLending(lendingId).lender, lender2, "projected hash accepted post-auto-settle");
    }

    // -------------------------------------------------------------------------
    // 6. Liquidator fraction / settler reward
    // -------------------------------------------------------------------------

    /// @dev Liquidation is permissionless regardless of liquidatorFraction.
    function testLiq_PermissionlessNonLenderCanLiquidate() public {
        uint256 lendingId = _setupActiveLoan(0);
        vm.warp(block.timestamp + 10 days);

        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(randomCaller);
        lending.liquidate{value: 1e15}(lendingId, _priceRatioFor(6 ether), type(uint128).max, paramHash, 0, 1e15, randomCaller, 0, _emptyTiming());

        assertEq(lendView.getLending(lendingId).liquidator, randomCaller, "non-lender liquidated");
    }

    /// @dev liquidatorFraction = 0: lender keeps all of the equity buffer. Snapshot is taken BEFORE liquidate
    ///      so the round-trip of the liquidator's initialLiquidity (returned by oracle.settle) cancels out.
    function testLiq_FractionZero_LenderKeepsBuffer() public {
        uint256 lendingId = _setupActiveLoan(0);
        vm.warp(block.timestamp + 10 days);

        uint256 lenderBefore = supplyToken.balanceOf(lender);
        uint256 liquidatorBefore = _supplyExposure(liquidator);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(6 ether), 1e15);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        uint256 lenderGain = supplyToken.balanceOf(lender) - lenderBefore;
        // Liquidator's net change in supply over the whole flow: paid (initialLiquidity + stake), got back
        // initialLiquidity from oracle.settle, got tokenStake (and any buffer share) from finalize. Net = bufferShare.
        int256 liquidatorNet = int256(_supplyExposure(liquidator)) - int256(liquidatorBefore);
        // fraction=0: liquidator's buffer share is 0, so the round-trip is exactly net 0.
        assertEq(liquidatorNet, 0, "fraction=0: liquidator's net supply change is zero");
        // Lender gets the full supply (debt-equivalent + buffer).
        assertEq(lenderGain, SUPPLY_AMOUNT, "lender absorbs the entire collateral");
    }

    /// @dev liquidatorFraction = 1e7: liquidator gets all of the buffer.
    function testLiq_FractionMax_LiquidatorTakesBuffer() public {
        uint256 lendingId = _setupActiveLoan(1e7);
        vm.warp(block.timestamp + 10 days);

        uint256 lenderBefore = supplyToken.balanceOf(lender);
        uint256 liquidatorBefore = _supplyExposure(liquidator);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(6 ether), 1e15);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        uint256 lenderGain = supplyToken.balanceOf(lender) - lenderBefore;
        int256 liquidatorNet = int256(_supplyExposure(liquidator)) - int256(liquidatorBefore);
        // fraction=1e7: liquidator's net change = full buffer share. Lender gets only the debt-equivalent.
        assertGt(liquidatorNet, 0, "fraction=1e7: liquidator profits the entire buffer");
        assertLt(lenderGain, SUPPLY_AMOUNT, "lender gets only the debt-equivalent");
        // Total distributed: lenderGain + liquidator's net supply gain = SUPPLY_AMOUNT (no oracle fees, stake nets out).
        assertEq(int256(lenderGain) + liquidatorNet, int256(uint256(SUPPLY_AMOUNT)), "supply fully distributed");
    }

    /// @dev Mid-fraction (2.5e6 = 25%) splits buffer 75/25 (lender/liquidator).
    function testLiq_FractionMid_SplitsBufferProportionally() public {
        uint24 fraction = 2_500_000; // 25% to liquidator
        uint256 lendingId = _setupActiveLoan(fraction);
        vm.warp(block.timestamp + 10 days);

        uint256 lenderBefore = supplyToken.balanceOf(lender);
        uint256 liquidatorBefore = _supplyExposure(liquidator);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(6 ether), 1e15);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        uint256 lenderGain = supplyToken.balanceOf(lender) - lenderBefore;
        int256 liquidatorNet = int256(_supplyExposure(liquidator)) - int256(liquidatorBefore);

        // Net supply distributed = SUPPLY_AMOUNT (no oracle game fees, no dispute).
        assertEq(int256(lenderGain) + liquidatorNet, int256(uint256(SUPPLY_AMOUNT)), "supply fully distributed");

        // Both parties got a positive supply gain (lender > debt-equivalent, liquidator > 0 buffer share).
        assertGt(liquidatorNet, 0, "liquidator received some buffer share");
        assertGt(lenderGain, 0, "lender received some collateral");

        // Liquidator's buffer share / lender's buffer share ≈ fraction / (1e7 - fraction).
        // lenderBufferShare = lenderGain - debtEquivalent. Without computing debtEquivalent precisely, derive
        // total buffer = liquidatorBufferShare × 1e7 / fraction and verify the split inverts cleanly.
        uint256 liquidatorBufferShare = uint256(liquidatorNet);
        uint256 inferredTotalBuffer = liquidatorBufferShare * 1e7 / fraction;
        uint256 inferredLenderBufferShare = inferredTotalBuffer - liquidatorBufferShare;
        // Lender's gain = debtEquivalent + lenderBufferShare. Both pieces are positive; just sanity-check the
        // implied total buffer is plausible (less than SUPPLY_AMOUNT).
        assertLt(inferredTotalBuffer, SUPPLY_AMOUNT, "implied total buffer fits within supply");
        assertGt(inferredLenderBufferShare, 0, "lender's buffer share is positive at 25/75 split");
    }

    /// @dev ERC20/ERC20 liquidate() reverts unless msg.value equals the settlerReward arg.
    function testSettlerReward_MustEqualMsgValue() public {
        uint256 lendingId = _setupActiveLoan(0);
        vm.warp(block.timestamp + 10 days);

        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.liquidate{value: 1e15}(lendingId, _priceRatioFor(8 ether), type(uint128).max, paramHash, 0, 2e15, liquidator, 0, _emptyTiming());
    }

    /// @dev Custom settlerReward is forwarded to the settler when an external party calls _settleOracle().
    function testSettlerReward_CustomAmountForwardedToSettler() public {
        uint256 lendingId = _setupActiveLoan(0);
        vm.warp(block.timestamp + 10 days);

        uint96 customReward = 5e15;
        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(6 ether), customReward);

        uint256 settlerBefore = IOpenOracle2(address(oracle)).tokenHolder(settler, address(0));
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        vm.prank(settler);
        IOpenOracle2(address(oracle)).settle(reportId, game, helper);

        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(settler, address(0)) - settlerBefore,
            customReward + (settlerBefore == 0 ? 1 : 0),
            "settler received the custom reward internally"
        );
    }

    /// @dev finalize() forwards the configured finalizer reward to its caller.
    function testFinalizerReward_finalizeForwardsReward() public {
        uint64 customReward = 3e15;
        openLend.OracleParams memory params = _standardOracleParams();
        params.finalizerReward = customReward;

        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            uint24(1e7),
            0,
            borrower,address(0),
            
            params,
            _standardInterestRateParams()
        );
        _lendWithFraction(lender, lendingId, 0);

        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(6 ether), SETTLER_REWARD);

        uint48 settleableAt = _settleableAtFor(reportId);
        vm.warp(uint256(settleableAt) + 1);

        uint256 callerBefore = randomCaller.balance;
        vm.prank(randomCaller);
        lending.finalize(lendingId);

        assertEq(randomCaller.balance - callerBefore, customReward, "finalize forwarded the finalizer reward");
    }

    // -------------------------------------------------------------------------
    // 7. Regression
    // -------------------------------------------------------------------------

    /// @dev finalize() touches amort and follows the normal failed-liq near-grace stake split.
    function testRegression_FinalizeStakeSplitAndAmortTouched() public {
        uint256 lendingId = _setupActiveLoan(5e6);
        vm.warp(block.timestamp + LOAN_TERM - 900);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(6 ether), 1e15);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        uint48 settleableAt = _settleableAtFor(reportId);
        vm.warp(uint256(settleableAt) + 5);

        uint256 liqBefore = supplyToken.balanceOf(liquidator);
        uint256 lenderBefore = supplyToken.balanceOf(lender);
        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;
        uint48 lastTouchBefore = lendView.getLending(lendingId).lastTouch;

        vm.prank(randomCaller);
        lending.finalize(lendingId);

        assertEq(supplyToken.balanceOf(liquidator) - liqBefore, 0, "finalize does not return failed-liq stake");
        assertEq(supplyToken.balanceOf(lender), lenderBefore + tokenStake / 2, "lender receives half stake");
        assertGt(lendView.getLending(lendingId).lastTouch, lastTouchBefore, "finalize touched amort state");
    }

    /// @dev Fuzz: random partial repayments keep `interestPaid <= max(commitmentInterest, interestAccrued)`
    ///      (the lender's interest-claim cap) and lender's net receipt equals total payments streamed.
    ///      Note: `principal + interestAccrued >= interestPaid` does NOT hold under amort — borrowers
    ///      can prepay into the commitment-interest floor surplus, which is why `_liquidationOwed` clamps at 0.
    function testRegression_FuzzPartialRepaysReconcile(uint128 a1, uint128 a2, uint128 a3) public {
        uint256 lendingId = _setupActiveLoan(0);
        uint256 lenderBefore = borrowToken.balanceOf(lender);
        uint256 borrowerBefore = borrowToken.balanceOf(borrower);

        // Bound each partial to stay clearly below residual (avoid full-close branch).
        a1 = uint128(bound(a1, 1, 1 ether));
        a2 = uint128(bound(a2, 1, 1 ether));
        a3 = uint128(bound(a3, 1, 1 ether));

        vm.warp(block.timestamp + 1 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, a1, bytes32(0), 0, type(uint128).max, false);
        vm.warp(block.timestamp + 1 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, a2, bytes32(0), 0, type(uint128).max, false);
        vm.warp(block.timestamp + 1 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, a3, bytes32(0), 0, type(uint128).max, false);

        // Amort invariant: interestPaid <= max(commitmentInterest, interestAccrued).
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        uint256 interestClaim = loan.interestAccrued > loan.commitmentInterest
            ? uint256(loan.interestAccrued)
            : uint256(loan.commitmentInterest);
        assertLe(uint256(loan.interestPaid), interestClaim,
            "interestPaid <= max(commitmentInterest, interestAccrued)");

        // Conservation: borrower's outflow equals lender's inflow equals a1+a2+a3.
        uint256 totalPaid = borrowerBefore - borrowToken.balanceOf(borrower);
        uint256 totalReceived = borrowToken.balanceOf(lender) - lenderBefore;
        assertEq(totalPaid, uint256(a1) + uint256(a2) + uint256(a3), "borrower outflow = sum of partials");
        assertEq(totalReceived, totalPaid, "lender receipt = borrower outflow (streamed)");
    }

    // -------------------------------------------------------------------------
    // 8. Exactness add-ons (auditor-driven)
    // -------------------------------------------------------------------------

    /// @dev Mid-fraction (25%) split with EXACT arithmetic. Computes `borrowValueInSupplyTerms` and the
    ///      derived buffer the way the contract does, then asserts the liquidator and lender each receive
    ///      precisely their share — protects against denominator/scaling mistakes that the structural
    ///      `testLiq_FractionMid_SplitsBufferProportionally` test would let through.
    function testLiq_FractionMid_ExactSplit() public {
        uint24 fraction = 2_500_000; // 25% to liquidator
        uint256 lendingId = _setupActiveLoan(fraction);
        vm.warp(block.timestamp + 10 days);

        uint256 lenderBefore = supplyToken.balanceOf(lender);
        uint256 liquidatorBefore = _supplyExposure(liquidator);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(6 ether), 1e15);

        // Settle without dispute → no oracle game fees → all flows accounted by lender/liquidator.
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        // Read post-settle amort state to reproduce the contract's exact `_residualDebt` value (commitment-inclusive).
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        uint256 interestClaim = loan.interestAccrued > loan.commitmentInterest
            ? uint256(loan.interestAccrued)
            : uint256(loan.commitmentInterest);
        uint256 liqOwed = uint256(loan.principal) + interestClaim - uint256(loan.interestPaid);
        uint256 borrowValueInSupplyTerms = liqOwed * 10 ether / 6 ether;     // oracleAmount1=10, oracleAmount2=6
        uint256 buffer = uint256(SUPPLY_AMOUNT) - borrowValueInSupplyTerms;
        uint256 expectedLiquidatorBufferShare = buffer * fraction / 1e7;
        uint256 expectedLenderBufferShare = buffer - expectedLiquidatorBufferShare;

        uint256 lenderGain = supplyToken.balanceOf(lender) - lenderBefore;
        int256 liquidatorNet = int256(_supplyExposure(liquidator)) - int256(liquidatorBefore);

        // Lender receives borrowValueInSupplyTerms + lender's buffer share.
        assertEq(lenderGain, borrowValueInSupplyTerms + expectedLenderBufferShare,
            "lender receives debt-equivalent + 75% of buffer");
        // Liquidator's net supply change after the round-trip = liquidator's buffer share (stake nets out).
        assertEq(liquidatorNet, int256(expectedLiquidatorBufferShare),
            "liquidator's net supply change = 25% of buffer");
    }

    /// @dev Successful underwater liquidation AFTER the borrower has already amortized: lender + liquidator
    ///      payouts are based on (principal + interestAccrued - interestPaid), confirming amort state flows
    ///      through to settlement.
    function testLiq_PostAmortizationExactPayout() public {
        uint256 lendingId = _setupActiveLoan(0);

        // Borrower partial that hits commitment floor then reduces principal by 5 ether.
        uint128 commitInt = lendView.getLending(lendingId).commitmentInterest;
        vm.prank(borrower);
        lending.repayDebt(lendingId, commitInt + 5 ether, bytes32(0), 0, type(uint128).max, false);

        // Snapshot pre-liquidate state for exact payout math.
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        // Sanity: amort fields reflect the partial.
        assertEq(loan.principal, BORROW_AMOUNT - 5 ether, "principal reduced by amort excess");
        assertEq(loan.interestPaid, commitInt, "interestPaid capped at commitInt");

        vm.warp(block.timestamp + 10 days);

        uint256 lenderBefore = supplyToken.balanceOf(lender);
        uint256 liquidatorBefore = _supplyExposure(liquidator);

        // Lower priceRatio so the amortized residual still trips the underwater threshold (post-amort
        // principal is ~45 ether, accrued ~0.12, paid ~0.41 → ~44.7 owed; need oracleAmount2 ≤ ~5.6 for
        // borrowValueInSupplyTerms > 80% of supply).
        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(5 ether), 1e15);
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory loanFinal = lendView.getLending(lendingId);
        assertTrue(loanFinal.finished, "underwater succeeded post-amort");

        // Reproduce contract math from post-settle amort state (commitment-inclusive residual).
        uint256 interestClaim = loanFinal.interestAccrued > loanFinal.commitmentInterest
            ? uint256(loanFinal.interestAccrued)
            : uint256(loanFinal.commitmentInterest);
        uint256 liqOwed = uint256(loanFinal.principal) + interestClaim - uint256(loanFinal.interestPaid);
        uint256 borrowValueInSupplyTerms = liqOwed * 10 ether / 5 ether;

        uint256 lenderGain = supplyToken.balanceOf(lender) - lenderBefore;
        int256 liquidatorNet = int256(_supplyExposure(liquidator)) - int256(liquidatorBefore);

        assertLt(borrowValueInSupplyTerms, SUPPLY_AMOUNT, "amortized residual leaves a buffer");
        // fraction=0 → liquidator buffer share = 0; lender gets debt-equivalent + full buffer = SUPPLY_AMOUNT.
        assertEq(lenderGain, SUPPLY_AMOUNT, "fraction=0: lender absorbs entire collateral");
        assertEq(liquidatorNet, 0, "fraction=0 + amort: liquidator's net supply change = 0");
    }

    /// @dev `repayAnyDebt` shares `_repayDebt`, but verify the third-party path explicitly: small partial
    ///      below the floor only updates `interestPaid`, large partial above the floor also reduces principal.
    function testRepayAnyDebt_ThirdPartyAmortBehavior() public {
        uint256 lendingId = _setupActiveLoan(0);
        uint128 commitInt = lendView.getLending(lendingId).commitmentInterest;

        // Below interest claim → only interestPaid changes.
        uint128 small = commitInt / 2;
        assertGt(small, 0, "commitInt > 1 wei prerequisite");

        openLend.LendingArrangement memory before_ = lendView.getLending(lendingId);
        vm.prank(payer);
        lending.repayAnyDebt(lendingId, small, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory afterSmall = lendView.getLending(lendingId);
        assertEq(afterSmall.principal, before_.principal, "principal unchanged below floor");
        assertEq(afterSmall.interestPaid, small, "interestPaid grew by exactly the partial");

        // Above interest claim → cap interestPaid at the claim, excess reduces principal.
        uint128 remaining = commitInt - small;
        uint128 big = remaining + 3 ether;
        vm.prank(payer);
        lending.repayAnyDebt(lendingId, big, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory afterBig = lendView.getLending(lendingId);
        assertEq(afterBig.interestPaid, commitInt, "interestPaid capped at commitInt");
        assertEq(afterBig.principal, before_.principal - 3 ether, "excess reduced principal by exactly 3 ether");
    }
}
