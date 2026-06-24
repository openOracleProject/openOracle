// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";
import {LendErrors} from "../../src/libraries/LendErrors.sol";

/// @notice Refinance edge-cases beyond what HappyPathRefinancingTest covers.
contract RefinancingTest is OpenLendingBaseTest {
    address internal borrower = address(0x1);
    address internal lender1 = address(0x2);
    address internal lender2 = address(0x3);
    address internal liquidator = address(0x4);
    address internal settler = address(0x5);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 50 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint16 constant STAKE = 100;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory supplyAccounts = new address[](2);
        supplyAccounts[0] = borrower;
        supplyAccounts[1] = liquidator;
        _fundSupply(supplyAccounts, 10_000 ether);

        address[] memory borrowAccounts = new address[](4);
        borrowAccounts[0] = borrower;
        borrowAccounts[1] = lender1;
        borrowAccounts[2] = lender2;
        borrowAccounts[3] = liquidator;
        _fundBorrow(borrowAccounts, 10_000 ether);

        address[] memory ethAccounts = new address[](5);
        ethAccounts[0] = borrower;
        ethAccounts[1] = lender1;
        ethAccounts[2] = lender2;
        ethAccounts[3] = liquidator;
        ethAccounts[4] = settler;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBorrow(lender1);
        _approveLendingBorrow(lender2);
        _approveLendingBoth(liquidator);
    }

    // ---------------- refinance() guards ----------------

    function testRefi_CannotReopenWhileCurveAlreadyOpen() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.CurveIsOpen.selector);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
    }

    function testRefi_RejectsSupplyPulledGreaterThanSupply() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.SupplyPulledTooHigh.selector);
        lending.refinance(
            lendingId,
            0,
            SUPPLY_AMOUNT,    // pull == supply → reverts at `>= supplyAmount`
            0,
            0,
            _standardInterestRateParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            0
        );
    }

    function testRefi_RejectsExpiredLoan() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        // Past maturity, no in-flight liquidation — refi should be rejected as expired
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        vm.warp(uint256(loan.start) + loan.term + 1);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.Expired.selector);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
    }

    function testRefi_FailsIfNotBorrower() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(lender1);
        vm.expectRevert(LendErrors.NotBorrower.selector);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
    }

    function testRefi_RejectsBadNewTerm() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.TermOutOfBounds.selector);
        lending.refinance(lendingId, 0, 0, 100 /* < 1800 floor */, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.TermOutOfBounds.selector);
        lending.refinance(lendingId, 0, 0, uint48(60 * 60 * 24 * 365 + 1), 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
    }

    /// @dev paramHash is the loose hash; verify the borrower can pin it.
    function testRefi_AcceptsCorrectLooseParamHash() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        bytes32 hash = lendView.getParamHash(lendingId);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), hash, 0, type(uint128).max);

        assertTrue(lendView.getLending(lendingId).curveOpen, "refi should open with correct hash");
    }

    function testRefi_RejectsWrongParamHash() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        bytes32 wrongHash = bytes32(uint256(1));

        vm.prank(borrower);
        vm.expectRevert(LendErrors.Params.selector);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), wrongHash, 0, type(uint128).max);
    }

    function testRefi_RejectsExpectedMaxPrincipalViolation() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.PrincipalTooHigh.selector);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, uint128(BORROW_AMOUNT - 1));
    }

    function testRefi_RejectsExpectedMinSupplyViolation() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.SupplyTooLow.selector);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), SUPPLY_AMOUNT + 1, type(uint128).max);
    }

    // ---------------- lend() refi-branch guards ----------------

    function testRefi_LendBlockedAfterFinishedFromFullRepay() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        // Borrower fully repays mid-curve — that finishes the loan and should clear curveOpen
        uint32 rate = lendView.getLending(lendingId).rate;
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);
        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed, bytes32(0), 0, type(uint128).max);

        // No lender can accept the refi anymore
        vm.prank(lender2);
        vm.expectRevert(LendErrors.Finished.selector);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender2);
    }

    /// @dev Two lenders race to fill a refi — only the first wins; second reverts on `!curveOpen`.
    function testRefi_OnlyFirstLenderWinsTheCurve() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        // First lender takes the curve
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender2);

        // Second lender attempts — curve is now closed
        vm.prank(lender1);
        vm.expectRevert(LendErrors.CurveIsNotOpen.selector);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender1);
    }

    /// @dev `minRate` floor: lender protects against curve reset between quote and tx.
    function testRefi_LendRejectsBelowMinRate() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        // No time has passed → curve is at startingRate (1e8). Asking for 2e8 fails.
        vm.prank(lender2);
        vm.expectRevert(LendErrors.MinRate.selector);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 2e8, 0, lender2);
    }

    function testRefi_LendRejectsBelowMinLendAmount() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        // Set a floor higher than the actual newBorrowAmount so the refi-branch bound check fires
        vm.prank(lender2);
        vm.expectRevert(LendErrors.LendAmountOutOfBounds.selector);
        lending.lend(lendingId, bytes32(0), type(uint128).max, type(uint128).max, 0, 0, 0, lender2);
    }

    function testRefi_LendRejectsAboveMaxLendAmount() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        vm.prank(lender2);
        vm.expectRevert(LendErrors.LendAmountOutOfBounds.selector);
        lending.lend(lendingId, bytes32(0), 0, 1, 0, 0, 0, lender2);
    }

    // ---------------- partialAmt repay does NOT void refi in V3 ----------------

    /// @dev V2 auto-voided the refi offer on partialAmt repay; V3 does NOT. The curve stays open and the new
    ///      principal at lend time = principal + max(interestAccrued, commitmentInterest) - interestPaid + extraDemanded
    ///      (the amortization residual claim).
    function testRefi_PartialRepayDoesNotVoidRefi() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        uint128 partialAmt = 5 ether;
        vm.prank(borrower);
        lending.repayDebt(lendingId, partialAmt, bytes32(0), 0, type(uint128).max);

        // Curve still open
        assertTrue(lendView.getLending(lendingId).curveOpen, "partialAmt repay should not close the refi curve");

        // Compute expected new principal directly from the post-repay amort state
        openLend.LendingArrangement memory pre = lendView.getLending(lendingId);
        uint256 interestClaim = pre.interestAccrued > pre.commitmentInterest
            ? uint256(pre.interestAccrued)
            : uint256(pre.commitmentInterest);
        uint128 expectedNewBorrow =
            uint128(uint256(pre.principal) + interestClaim - uint256(pre.interestPaid));

        // Lender2 accepts at the current curve
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lender2);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.principal, expectedNewBorrow,
            "new principal = principal + max(accrued, commitInt) - interestPaid (extra=0)");
    }

    // ---------------- lend() refi-branch paramHash ----------------

    function testLendRefi_AcceptsCorrectParamHash() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        bytes32 hash = lendView.getParamHash(lendingId);

        vm.prank(lender2);
        lending.lend(lendingId, hash, 0, type(uint128).max, 0, 0, 0, lender2);

        assertEq(lendView.getLending(lendingId).lender, lender2, "lender2 accepted with correct hash");
    }

    function testLendRefi_RejectsWrongParamHash() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        bytes32 wrong = bytes32(uint256(0xbeef));

        vm.prank(lender2);
        vm.expectRevert(LendErrors.Params.selector);
        lending.lend(lendingId, wrong, 0, type(uint128).max, 0, 0, 0, lender2);
    }

    // ---------------- stale loose hash + directional bounds ----------------

    /// @dev Snapshot a paramHash, then a benign third party tops up + partially repays. The loose hash zeros
    ///      supplyAmount and repaidDebt before hashing, so it still matches. Directional bounds set to the
    ///      pre-change values are still satisfied. lend() refi proceeds.
    function testStaleLooseHash_BenignTopUpAndPartialRepay_StillSucceeds() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        // Open refi so we have a curveOpen path that lend() can travel
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        // Snapshot loose hash + state
        bytes32 staleHash = lendView.getParamHash(lendingId);
        uint128 supplySnapshot = lendView.getLending(lendingId).supplyAmount;
        // uint128 repaidSnapshot = lendView.getLending(lendingId).repaidDebt;  // [amort: removed/no-op]

        // Benign third-party top-up
        _approveLendingSupply(address(this));
        supplyToken.approve(address(lending), type(uint128).max);
        // Need a topper account funded; use a fresh address
        address topper = address(0xBEEF);
        supplyToken.transfer(topper, 50 ether);
        vm.prank(topper);
        supplyToken.approve(address(lending), type(uint256).max);
        vm.prank(topper);
        lending.topUpCollateralAnyone(lendingId, 10 ether, bytes32(0), 0, type(uint128).max);

        // Benign borrower partial repay
        vm.prank(borrower);
        lending.repayDebt(lendingId, 3 ether, bytes32(0), 0, type(uint128).max);

        // Lender2 uses the stale hash + directional bounds set to snapshotted values — both still satisfied.
        // V3's `lend` only takes expectedMinSupply (no expectedRepaidDebtMin), so we just check supply here.
        vm.prank(lender2);
        lending.lend(lendingId, staleHash, 0, type(uint128).max, supplySnapshot, 0, 0, lender2);

        assertEq(lendView.getLending(lendingId).lender, lender2, "stale loose hash + satisfied bounds should succeed");

        // (Demonstrates that `repaidDebt` did go up before refi acceptance; it's reset to 0 after acceptance.)
        // repaidSnapshot;  // [amort: repaidSnapshot removed]
    }

    /// @dev Stale hash succeeds the hash check (loose), but expectedMinSupply higher than current reverts
    ///      (defends against an RPC under-reporting supply movements).
    function testStaleLooseHash_ExpectedMinSupplyTooHighReverts() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        bytes32 staleHash = lendView.getParamHash(lendingId);

        // Lender2 sets expectedMinSupply ABOVE actual — bounds catch this
        vm.prank(lender2);
        vm.expectRevert(LendErrors.MinSupply.selector);
        lending.lend(lendingId, staleHash, 0, type(uint128).max, SUPPLY_AMOUNT + 1, 0, 0, lender2);
    }

    /// @dev Same shape as above, exercising refinance()'s expectedMaxPrincipal bound.
    function testStaleLooseHash_RefinanceExpectedMaxPrincipalTooLowReverts() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        bytes32 staleHash = lendView.getParamHash(lendingId);

        // principal == BORROW_AMOUNT; cap at BORROW_AMOUNT - 1 → reverts. Loose hash is correct, so this
        // isolates the bound.
        vm.prank(borrower);
        vm.expectRevert(LendErrors.PrincipalTooHigh.selector);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), staleHash, 0, uint128(BORROW_AMOUNT - 1));
    }

    // ---------------- liquidation post-refi ----------------

    function testRefi_LiquidationWorksAfterRefi() public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        // Refi to lender2
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender2);

        // Move time so we're well past origination
        vm.warp(block.timestamp + 5 days);

        bytes32 paramHash = lendView.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            6 ether * 1e18 / 10 ether,
            type(uint128).max,
            paramHash,
             0,
            1e15, liquidator, 0, _emptyTiming()
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.inLiquidation, "post-refi liquidation should engage");
        assertEq(loan.liquidator, liquidator, "liquidator field set");
    }

    // ---------------- accounting across multiple cycles ----------------

    /// @dev Sanity check that repeated refis don't leak supply/borrow tokens out of the contract.
    function testRefi_AccountingAcrossMultipleCycles() public {
        uint256 contractSupplyStart = supplyToken.balanceOf(address(lending));
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        // Three refi cycles, alternating lenders
        address[3] memory lenders = [lender2, lender1, lender2];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(borrower);
            lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

            vm.prank(lenders[i]);
            lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0, lenders[i]);
        }

        // Contract still holds exactly the original supply collateral (no skim)
        assertEq(
            supplyToken.balanceOf(address(lending)),
            contractSupplyStart + SUPPLY_AMOUNT,
            "supplyAmount on contract should not drift across refi cycles"
        );
    }
}
