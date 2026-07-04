// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LendErrors} from "../../src/libraries/LendErrors.sol";
import "./OpenLendingBase.t.sol";

/// @notice Liquidation paths interacting with refinance flows.
/// @dev Coverage: liquidation on a freshly-refi'd loan, refi opened during liquidation, failure paths.
contract LiquidationTestRefi is OpenLendingBaseTest {
    event LiqFinishedUnderwater(uint256 indexed lendingId);
    event LiqUnsuccessful(uint256 indexed lendingId);

    address internal borrower = address(0x1);
    address internal lender1 = address(0x2);
    address internal lender2 = address(0x3);
    address internal liquidator = address(0x4);
    address internal disputer = address(0x5);
    address internal settler = address(0x6);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 70 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint16 constant STAKE = 100;

    uint256 constant ORACLE_SETTLEMENT_TIME = 300;
    uint256 constant ORACLE_DISPUTE_DELAY = 60;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accounts = new address[](5);
        accounts[0] = borrower;
        accounts[1] = lender1;
        accounts[2] = lender2;
        accounts[3] = liquidator;
        accounts[4] = disputer;
        _fundSupply(accounts, 10_000 ether);
        _fundBorrow(accounts, 10_000 ether);

        address[] memory ethAccounts = new address[](6);
        ethAccounts[0] = borrower;
        ethAccounts[1] = lender1;
        ethAccounts[2] = lender2;
        ethAccounts[3] = liquidator;
        ethAccounts[4] = disputer;
        ethAccounts[5] = settler;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBorrow(lender1);
        _approveLendingBorrow(lender2);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);
    }

    // ---------------- helpers ----------------

    function _priceRatioFor(uint256 oracleAmount2Target, uint256 supplyForLiq) internal pure returns (uint256) {
        // initialLiquidity = supplyForLiq * 10 / 100
        return oracleAmount2Target * 1e18 / (supplyForLiq * 10 / 100);
    }

    /// @dev Originate a loan with liquidatorFraction = true so any liquidator can run a liq.
    function _setupActiveLoanAllowAnyLiq() internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        vm.startPrank(lender1);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 5e6, lender1, address(0));
        vm.stopPrank();
    }

    /// @dev Originate, then refi to lender2 with liquidatorFraction on the refi acceptance.
    function _setupRefiLoan() internal returns (uint256 lendingId) {
        lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 5e6, lender2, address(0));
        vm.stopPrank();
    }

    function _liquidate(address who, uint256 lendingId, uint256 oracleAmount2Target) internal {
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        uint128 supplyAmount = lendView.getLending(lendingId).supplyAmount;
        vm.prank(who);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(oracleAmount2Target, supplyAmount),
            type(uint128).max,
            paramHash,
             0,
            1e15, who, 0, _emptyTiming()
        );
    }

    // ---------------- liquidation on a refi'd loan ----------------

    function testRefiLiq_UnderwaterPaysRefiLenderNotOriginal() public {
        uint256 lendingId = _setupRefiLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 lender1SupplyBefore = supplyToken.balanceOf(lender1);
        uint256 lender2SupplyBefore = supplyToken.balanceOf(lender2);

        _liquidate(liquidator, lendingId, 6 ether);

        uint256 reportId = oracle.nextReportId() - 1;
        bytes32 stateHash = bytes32(0);

        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.expectEmit(true, false, false, true, address(lending));
        emit LiqFinishedUnderwater(lendingId);
        vm.prank(settler);
        _settleOracle(reportId);
        _distributeOracleGameFees(reportId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "Loan should be finished");

        // Underwater no-equity branch: lender2 gets supplyAmount externally; fee share is oracle-internal.
        uint256 lender2FeePiece = (10 ether * 100_000 / 1e7) / 2 / 2;
        assertEq(
            supplyToken.balanceOf(lender2) - lender2SupplyBefore,
            uint256(SUPPLY_AMOUNT),
            "lender2 receives full supply underwater"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(lender2, address(supplyToken)),
            lender2FeePiece + 1,
            "lender2 fee share credited internally"
        );
        assertEq(supplyToken.balanceOf(lender1), lender1SupplyBefore, "lender1 should not receive anything from this liq");
    }

    function testRefiLiq_FailedRefundsStakeToBorrower() public {
        uint256 lendingId = _setupRefiLoan();
        vm.warp(block.timestamp + 10 days);

        _liquidate(liquidator, lendingId, 6 ether);

        uint256 reportId = oracle.nextReportId() - 1;
        bytes32 stateHash = bytes32(0);

        // Dispute lands at favorable-for-borrower ratio
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 30 ether, disputer, 12 ether, stateHash);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.expectEmit(true, false, false, true, address(lending));
        emit LiqUnsuccessful(lendingId);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.finished, "Loan should remain live");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
        assertEq(loan.lender, lender2, "post-refi lender should still be lender2");

        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + tokenStake, "Borrower should gain liquidator stake");
    }

    function testRefiLiq_CannotRepayOrTopupDuringLiquidation() public {
        uint256 lendingId = _setupRefiLoan();
        vm.warp(block.timestamp + 10 days);

        _liquidate(liquidator, lendingId, 8 ether);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.InLiquidation.selector);
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, type(uint128).max, false);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.InLiquidation.selector);
        lending.topUpCollateral(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);
    }

    // ---------------- refi-during-liquidation ----------------

    /// @dev V3 explicitly allows refinance() while inLiquidation. The curve opens but no lender can accept until
    ///      finalize clears inLiquidation. After a failed liq, requestStart resets so the curve starts fresh.
    function testRefiDuringLiq_OpensCurveButLendBlocksUntilSettle() public {
        uint256 lendingId = _setupActiveLoanAllowAnyLiq();
        vm.warp(block.timestamp + 10 days);

        _liquidate(liquidator, lendingId, 6 ether);

        // Borrower opens a refi while liquidation is in flight
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory midLoan = lendView.getLending(lendingId);
        assertTrue(midLoan.curveOpen, "refi curve should open mid-liquidation");
        assertTrue(midLoan.inLiquidation, "loan still inLiquidation");

        // A lender attempting to fill the refi curve is blocked by the inLiquidation gate in lend()
        bytes32 paramHashExpected5 = lendView.getParamHash(lendingId);
        vm.startPrank(lender2);
        vm.expectRevert(LendErrors.InLiquidation.selector);
        lending.lend(lendingId,paramHashExpected5, 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();

        // Resolve liquidation as failed
        uint256 reportId = oracle.nextReportId() - 1;
        bytes32 stateHash = bytes32(0);
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 30 ether, disputer, 12 ether, stateHash);

        // Capture the dispute-shifted reportTimestamp so we can pin requestStart against settleableAt below.
        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        uint48 settleableAt = reportTs + uint48(ORACLE_SETTLEMENT_TIME);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory afterLiq = lendView.getLending(lendingId);
        assertFalse(afterLiq.inLiquidation, "liq cleared");
        assertTrue(afterLiq.curveOpen, "refi curve persists across failed liq");
        assertEq(afterLiq.requestStart, settleableAt, "requestStart pinned to settleableAt on failed liq");

        // Now lender2 can accept the refi
        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();

        assertEq(lendView.getLending(lendingId).lender, lender2, "lender2 should be the new lender");
    }

    /// @dev Post-maturity refi-during-liquidation: liq starts pre-maturity, time crosses maturity while liq is in
    ///      flight, borrower opens refi mid-liq AFTER maturity, lend() blocks until settle, failed liq grants
    ///      gracePeriod, then a lender accepts the refi within grace.
    function testRefiDuringLiq_PostMaturityFlow() public {
        uint256 lendingId = _setupActiveLoanAllowAnyLiq();

        // Start liq close to maturity so settlement window crosses maturity
        vm.warp(block.timestamp + LOAN_TERM - 200);

        _liquidate(liquidator, lendingId, 6 ether);

        // Crawl past nominal maturity while still inLiquidation
        openLend.LendingArrangement memory beforeRefi = lendView.getLending(lendingId);
        vm.warp(uint256(beforeRefi.start) + beforeRefi.term + 50); // past maturity by 50s
        assertGt(block.timestamp, uint256(beforeRefi.start) + beforeRefi.term, "past maturity");
        assertTrue(lendView.getLending(lendingId).inLiquidation, "still in liquidation");

        // Borrower opens refi while past maturity AND inLiquidation — V3 explicitly allows this
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
        assertTrue(lendView.getLending(lendingId).curveOpen, "refi curve should open past maturity during liq");

        // lend() blocked by inLiquidation
        bytes32 paramHashExpected6 = lendView.getParamHash(lendingId);
        vm.startPrank(lender2);
        vm.expectRevert(LendErrors.InLiquidation.selector);
        lending.lend(lendingId,paramHashExpected6, 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();

        uint256 reportId = oracle.nextReportId() - 1;
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);
        (,,, uint48 finalReportTs,,,) = _reportStatus(reportId);
        uint48 expectedGrace =
            uint48(1800 + (uint256(finalReportTs) + ORACLE_SETTLEMENT_TIME - beforeRefi.liquidationStart));
        vm.warp(uint256(finalReportTs) + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory afterLiq = lendView.getLending(lendingId);
        assertFalse(afterLiq.inLiquidation, "liq cleared");
        assertTrue(afterLiq.curveOpen, "refi curve survives failed liq");
        assertEq(afterLiq.gracePeriod, expectedGrace, "exact gracePeriod from post-maturity failed liq");

        // We're past nominal maturity but inside gracePeriod. lend()'s expiry check uses prevTerm + gracePeriod.
        uint256 graceEnd = uint256(afterLiq.start) + afterLiq.term + afterLiq.gracePeriod;
        assertLt(block.timestamp, graceEnd, "still inside gracePeriod");

        // Lender2 accepts the refi within grace
        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();

        openLend.LendingArrangement memory finalLoan = lendView.getLending(lendingId);
        assertEq(finalLoan.lender, lender2, "lender2 should be new lender");
        assertFalse(finalLoan.curveOpen, "curve closed after lend");
    }

    // ---------------- refi-first, then liquidate ----------------

    /// @dev Open refi → start liq while curveOpen == true. lend() blocked. Failed liq keeps curve, resets requestStart.
    function testRefiFirst_FailedLiquidationKeepsCurveAndResets() public {
        uint256 lendingId = _setupActiveLoanAllowAnyLiq();

        vm.warp(block.timestamp + 1 days);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
        uint48 requestStartBefore = lendView.getLending(lendingId).requestStart;

        // Tick curve a bit to confirm reset on settle
        vm.warp(block.timestamp + 1 hours);

        _liquidate(liquidator, lendingId, 6 ether);

        // lend() blocked while inLiquidation
        bytes32 paramHashExpected7 = lendView.getParamHash(lendingId);
        vm.startPrank(lender2);
        vm.expectRevert(LendErrors.InLiquidation.selector);
        lending.lend(lendingId,paramHashExpected7, 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();

        uint256 reportId = oracle.nextReportId() - 1;
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        uint48 settleableAt = reportTs + uint48(ORACLE_SETTLEMENT_TIME);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory afterLiq = lendView.getLending(lendingId);
        assertFalse(afterLiq.inLiquidation, "liq cleared");
        assertTrue(afterLiq.curveOpen, "curve survives failed liq");
        assertLt(requestStartBefore, settleableAt, "pre-liq refi clock was older than failed-liq reanchor");
        assertEq(afterLiq.requestStart, settleableAt, "requestStart pinned to settleableAt on failed liq");

        // Lender2 can still accept the (re-anchored) refi
        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();
        assertEq(lendView.getLending(lendingId).lender, lender2, "lender2 accepted post-settle refi");
    }

    /// @dev Open refi → start liq → successful liq closes loan AND clears the orphaned curve via _clearRefiCurve.
    function testRefiFirst_SuccessfulLiquidationClearsCurve() public {
        uint256 lendingId = _setupActiveLoanAllowAnyLiq();

        vm.warp(block.timestamp + 10 days);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
        assertTrue(lendView.getLending(lendingId).curveOpen, "curve open before liq");

        _liquidate(liquidator, lendingId, 6 ether);

        // Dispute to underwater price
        uint256 reportId = oracle.nextReportId() - 1;
        bytes32 stateHash = bytes32(0);
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "loan finished by underwater liq");
        assertFalse(loan.curveOpen, "_clearRefiCurve should clear orphaned curve on terminal liq");

        openLend.RefiParams memory rp = lendView.getRefiParams(lendingId);
        assertEq(rp.extraDemanded, 0, "refi extraDemanded cleared");
        assertEq(rp.supplyPulled, 0, "refi supplyPulled cleared");
        assertEq(rp.newTerm, 0, "refi newTerm cleared");
    }

    // ---------------- cancel refi during liquidation ----------------

    /// @dev Borrower opens refi mid-liq, cancels it before settle. Failed settle should leave curveOpen=false.
    ///      Borrower can still repay during the resulting grace window.
    function testCancelRefiDuringLiq_LeavesCurveClosed() public {
        uint256 lendingId = _setupActiveLoanAllowAnyLiq();

        // Get into the grace-trigger window so the failed liq actually grants grace
        vm.warp(block.timestamp + LOAN_TERM - 900);

        _liquidate(liquidator, lendingId, 6 ether);

        // Borrower opens refi mid-liq, then cancels it
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
        assertTrue(lendView.getLending(lendingId).curveOpen, "curve open after refinance");

        vm.prank(borrower);
        lending.cancelRefinance(lendingId);
        assertFalse(lendView.getLending(lendingId).curveOpen, "curve closed after cancelRefinance");

        uint256 reportId = oracle.nextReportId() - 1;
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory afterLiq = lendView.getLending(lendingId);
        assertFalse(afterLiq.curveOpen, "curve still closed after failed liq with cancel-during-liq");
        assertEq(afterLiq.gracePeriod, 1800 + (ORACLE_DISPUTE_DELAY + ORACLE_SETTLEMENT_TIME), "exact gracePeriod from near-maturity failed liq");

        // Borrower can repay during grace
        uint128 totalOwed = _calculateOwedAtMaturity(afterLiq.principal, afterLiq.rate, afterLiq.term);
        vm.warp(uint256(afterLiq.start) + afterLiq.term + (afterLiq.gracePeriod / 2));
        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed + 1 ether, bytes32(0), 0, type(uint128).max, false);
        assertTrue(lendView.getLending(lendingId).finished, "repay during grace should finish loan");
    }

    // ---------------- partial repay then refi (with extraDemanded) ----------------

    /// @dev Borrower partially repays, opens refi with extraDemanded, lender accepts.
    ///      newBorrowAmount = principal + max(interestAccrued, commitmentInterest) - interestPaid + extraDemanded
    ///      (the amortization residual claim, computed from actual struct state).
    function testPartialRepayThenRefi_NewBorrowAmountMath() public {
        uint256 lendingId = _setupActiveLoanAllowAnyLiq();

        uint128 partialAmt = 7 ether;
        vm.prank(borrower);
        lending.repayDebt(lendingId, partialAmt, bytes32(0), 0, type(uint128).max, false);

        // Now open refi with extra demand
        uint128 extra = 3 ether;
        vm.prank(borrower);
        lending.refinance(lendingId, extra, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        // Compute expected new principal from the actual post-repay amort state
        openLend.LendingArrangement memory pre = lendView.getLending(lendingId);
        uint256 interestClaim = pre.interestAccrued > pre.commitmentInterest
            ? uint256(pre.interestAccrued)
            : uint256(pre.commitmentInterest);
        uint128 expectedNewBorrow = uint128(
            uint256(pre.principal) + interestClaim - uint256(pre.interestPaid) + uint256(extra)
        );

        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);

        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.principal, expectedNewBorrow,
            "newBorrowAmount = principal + max(accrued, commitInt) - interestPaid + extra");

        // Lender2 funded newBorrowAmount
        assertEq(
            borrowToken.balanceOf(lender2),
            lender2BorrowBefore - expectedNewBorrow,
            "lender2 funded the new principal"
        );
        // Borrower received extraDemanded; prior lender (lender1) received owedAtMaturity
        assertEq(
            borrowToken.balanceOf(borrower),
            borrowerBorrowBefore + extra,
            "borrower received extraDemanded"
        );
    }

    /// @dev If the in-flight liquidation succeeds (loan finishes), an open refi curve is left orphan but harmless —
    ///      `finished` blocks any future `lend()` so the curve cannot be filled.
    function testRefiDuringLiq_LiquidationSucceedsBlocksOrphanedRefi() public {
        uint256 lendingId = _setupActiveLoanAllowAnyLiq();
        vm.warp(block.timestamp + 10 days);

        _liquidate(liquidator, lendingId, 6 ether);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        // Resolve as underwater (loan finishes)
        uint256 reportId = oracle.nextReportId() - 1;
        bytes32 stateHash = bytes32(0);
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "Loan should be finished");
        // _clearRefiCurve in finalize's finished branch clears curveOpen too
        assertFalse(loan.curveOpen, "successful liq should clear orphan refi curve");

        // Even if curveOpen had stayed true, `finished` blocks lend(); double-check
        bytes32 paramHashExpected8 = lendView.getParamHash(lendingId);
        vm.startPrank(lender2);
        vm.expectRevert(LendErrors.Finished.selector);
        lending.lend(lendingId,paramHashExpected8, 0, type(uint128).max, 0, 0, 0, lender2, address(0));
        vm.stopPrank();
    }
}
