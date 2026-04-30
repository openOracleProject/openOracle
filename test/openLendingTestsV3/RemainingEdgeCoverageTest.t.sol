// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";
import "../../src/oracleFeeReceiver.sol";

contract RemainingEdgeCoverageTest is OpenLendingBaseTest {
    address internal borrower = address(0x11);
    address internal lender = address(0x12);
    address internal lender2 = address(0x13);
    address internal liquidator = address(0x14);
    address internal disputer = address(0x15);
    address internal settler = address(0x16);

    uint128 internal constant SUPPLY_AMOUNT = 100 ether;
    uint128 internal constant BORROW_AMOUNT = 70 ether;
    uint48 internal constant LOAN_TERM = 30 days;
    uint16 internal constant STAKE = 100;

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
        _approveLendingBorrow(lender);
        _approveLendingBorrow(lender2);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);
    }

    // ---------------- onSettle gating ----------------

    function testOnSettle_RevertsForNonOracleCaller() public {
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "invalid sender"));
        lending.onSettle(999, 0, 0, address(supplyToken), address(borrowToken));
    }

    function testOnSettle_RevertsForUnknownReportIdEvenFromOracle() public {
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "no lendingId for reportId"));
        lending.onSettle(999, 0, 0, address(supplyToken), address(borrowToken));
    }

    // ---------------- exact-boundary timing ----------------

    /// @dev `_repayDebt` reverts at `currentTime >= start + term + gracePeriod`. So exactly at the boundary reverts.
    function testRepayDebt_AtExactExpiry_Reverts() public {
        uint256 lendingId = _setupActiveLoan(false);
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        vm.warp(uint256(loan.start) + loan.term + loan.gracePeriod);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "expired"));
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, 0);
    }

    /// @dev `liquidate` reverts at `currentTime > start + term` (strict gt). So exactly at maturity is allowed.
    function testLiquidate_AtExactTerm_Succeeds() public {
        uint256 lendingId = _setupActiveLoan(true);
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        vm.warp(uint256(loan.start) + loan.term);

        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0
        );

        assertTrue(lending.getLending(lendingId).inLiquidation, "exact-term liquidation should succeed");
    }

    /// @dev `claimCollateral` reverts at `currentTime < start + term + gracePeriod`. At exact boundary the claim succeeds.
    function testClaimCollateral_AtExactGraceBoundary_Succeeds() public {
        uint256 lendingId = _setupActiveLoan(true);
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        // Trigger a near-maturity liquidation that fails so a grace period gets set
        vm.warp(uint256(loan.start) + loan.term - 100);

        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(20 ether),
            type(uint128).max,
            paramHash,
            0
        );

        uint256 reportId = oracle.nextReportId() - 1;
        vm.warp(block.timestamp + 301);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory afterFailedLiq = lending.getLending(lendingId);
        // liqStart = start + term - 100, settle at liqStart + 301 → delta 301 → gracePeriod = 1800 + 602
        assertEq(afterFailedLiq.gracePeriod, 1800 + 301 * 2, "exact gracePeriod from failed late liq");

        vm.warp(uint256(loan.start) + loan.term + afterFailedLiq.gracePeriod);

        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        lending.claimCollateral(lendingId);

        openLend.LendingArrangement memory afterClaim = lending.getLending(lendingId);
        assertTrue(afterClaim.finished, "claim at exact grace boundary should succeed");
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBefore + afterFailedLiq.supplyAmount,
            "lender should receive collateral"
        );
    }

    // ---------------- fee receiver clone wiring ----------------

    function testLiquidate_InitializesCloneFeeReceiver() public {
        uint256 lendingId = _setupActiveLoan(true);
        openLend.LendingArrangement memory loanBefore = lending.getLending(lendingId);

        assertEq(loanBefore.feeRecipient, address(0), "fee recipient should stay unset before liquidation");

        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0
        );

        openLend.LendingArrangement memory loanDuring = lending.getLending(lendingId);
        assertTrue(loanDuring.feeRecipient != address(0), "liquidation should deploy a fee receiver");

        oracleFeeReceiver feeReceiver = oracleFeeReceiver(loanDuring.feeRecipient);
        assertEq(feeReceiver.owner(), address(lending), "clone owner mismatch");
        assertEq(feeReceiver.gameId(), lendingId, "clone gameId mismatch");
        assertEq(address(feeReceiver.oracle()), address(oracle), "clone oracle mismatch");
        assertEq(feeReceiver.token1(), address(supplyToken), "clone token1 mismatch");
        assertEq(feeReceiver.token2(), address(borrowToken), "clone token2 mismatch");
    }

    /// @dev Refinance does NOT deploy a fee receiver; only liquidate does. Cleared on lend-refi.
    function testRefinance_LeavesFeeRecipientUnsetUntilLiquidation() public {
        uint256 lendingId = _setupActiveLoan(true);
        assertEq(lending.getLending(lendingId).feeRecipient, address(0), "fee recipient should start unset");

        // Borrower opens refi
        vm.prank(borrower);
        lending.refinance(
            lendingId,
            10 ether,
            5 ether,
            0,
            0,
            _standardInterestRateParams(),
            bytes32(0),
            0,
            0
        );

        // Lender2 accepts
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, true);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.feeRecipient, address(0), "refi should not deploy a fee receiver");
    }

    // ---------------- grab oracle game fees ----------------

    function testGrabOracleGameFeesAny_SweepsBorrowFeesAndSecondSweepIsNoOp() public {
        uint256 lendingId = _setupActiveLoan(true);

        vm.warp(block.timestamp + 10 days);

        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0
        );

        address feeRecipient = lending.getLending(lendingId).feeRecipient;
        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        vm.warp(block.timestamp + 120);
        vm.prank(disputer);
        oracle.disputeAndSwap(reportId, address(borrowToken), 20 ether, 20 ether, disputer, 8 ether, stateHash);

        uint256 feeAccrued = oracle.protocolFees(feeRecipient, address(borrowToken));
        assertEq(feeAccrued, 8 ether * 100_000 / 1e7, "borrow-side fee accrual mismatch");

        uint256 borrowerBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBefore = borrowToken.balanceOf(lender);
        uint256 liquidatorBefore = borrowToken.balanceOf(liquidator);

        lending.grabOracleGameFeesAny(lendingId, feeRecipient);

        assertEq(oracle.protocolFees(feeRecipient, address(borrowToken)), 0, "fees should be fully swept");
        uint256 firstSweepTotal = (borrowToken.balanceOf(borrower) - borrowerBefore)
            + (borrowToken.balanceOf(lender) - lenderBefore) + (borrowToken.balanceOf(liquidator) - liquidatorBefore);
        assertEq(firstSweepTotal, feeAccrued, "beneficiaries should receive full accrued borrow fees");

        // Second sweep: nothing more accrued, no balance change
        borrowerBefore = borrowToken.balanceOf(borrower);
        lenderBefore = borrowToken.balanceOf(lender);
        liquidatorBefore = borrowToken.balanceOf(liquidator);

        lending.grabOracleGameFeesAny(lendingId, feeRecipient);

        assertEq(borrowToken.balanceOf(borrower), borrowerBefore, "second sweep should be a no-op for borrower");
        assertEq(borrowToken.balanceOf(lender), lenderBefore, "second sweep should be a no-op for lender");
        assertEq(borrowToken.balanceOf(liquidator), liquidatorBefore, "second sweep should be a no-op for liquidator");
    }

    function testGrabOracleGameFeesAny_RevertsForWrongLendingId() public {
        uint256 lendingId = _setupActiveLoan(true);

        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0
        );

        address feeRecipient = lending.getLending(lendingId).feeRecipient;

        // Set up a second loan to obtain a "wrong" lendingId that exists
        uint256 otherLendingId = _setupActiveLoan(true);
        assertTrue(otherLendingId != lendingId, "two distinct lending ids");

        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "feeRecipient not for lendingId"));
        lending.grabOracleGameFeesAny(otherLendingId, feeRecipient);
    }

    // ---------------- exact-boundary refi/lend ----------------

    /// @dev `refinance` reverts at `currentTime >= start + term + gracePeriod` (when not inLiquidation).
    ///      With gracePeriod = 0 this is `>= start + term`, so EXACTLY at maturity reverts.
    function testRefinance_AtExactMaturity_Reverts() public {
        uint256 lendingId = _setupActiveLoan(false);
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        vm.warp(uint256(loan.start) + loan.term);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "expired"));
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), bytes32(0), 0, 0);
    }

    /// @dev `lend` (active loan branch) reverts at `currentTime >= start + term + gracePeriod`.
    ///      Exactly at the boundary reverts.
    function testLend_RefiAtExactGraceEnd_Reverts() public {
        uint256 lendingId = _setupActiveLoanForGrace();
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        // _setupActiveLoanForGrace: liq at start+term-900, settle +301 → delta 301 → gracePeriod = 1800 + 602
        assertEq(loan.gracePeriod, 1800 + 301 * 2, "exact gracePeriod from helper");

        // Exactly at the grace boundary
        vm.warp(uint256(loan.start) + loan.term + loan.gracePeriod);

        vm.prank(lender2);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "expired"));
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);
    }

    /// @dev `lend` (active loan branch) succeeds one second BEFORE grace end.
    function testLend_RefiOneSecondBeforeGraceEnd_Succeeds() public {
        uint256 lendingId = _setupActiveLoanForGrace();
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        // One second before the grace boundary
        vm.warp(uint256(loan.start) + loan.term + loan.gracePeriod - 1);

        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        assertEq(lending.getLending(lendingId).lender, lender2, "should accept refi 1s before grace end");
    }

    /// @dev Helper: originate, force a near-maturity failed liq to set gracePeriod, then open a refi during grace.
    function _setupActiveLoanForGrace() internal returns (uint256 lendingId) {
        lendingId = _setupActiveLoan(true);

        // Get into the grace-trigger window
        vm.warp(block.timestamp + LOAN_TERM - 900);

        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(12 ether),
            type(uint128).max,
            paramHash,
            0
        );

        uint256 reportId = oracle.nextReportId() - 1;
        vm.warp(block.timestamp + 301);
        vm.prank(settler);
        oracle.settle(reportId);

        // Now gracePeriod > 0. Open a refi so a `lend` accept path exists
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), bytes32(0), 0, 0);
    }

    // ---------------- interest rate params validation ----------------

    function testInterestRateParams_RejectsMaxRoundsAbove100() public {
        openLend.InterestRateParams memory bad = openLend.InterestRateParams({
            maxRate: 1e9,
            startingRate: 1e8,
            roundLength: 300,
            growthRate: 10500,
            maxRounds: 101
        });

        vm.prank(borrower);
        supplyToken.approve(address(lending), type(uint256).max);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "interestRateParams"));
        lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            false,
            0,
            _standardOracleParams(),
            bad
        );
    }

    function testInterestRateParams_RejectsGrowthRateAtOrBelow10000() public {
        openLend.InterestRateParams memory flat = openLend.InterestRateParams({
            maxRate: 1e9,
            startingRate: 1e8,
            roundLength: 300,
            growthRate: 10000, // must be > 10000
            maxRounds: 100
        });

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "interestRateParams"));
        lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            false,
            0,
            _standardOracleParams(),
            flat
        );
    }

    function testInterestRateParams_RejectsMaxRateBelowStartingRate() public {
        openLend.InterestRateParams memory bad = openLend.InterestRateParams({
            maxRate: 1e7,         // less than startingRate
            startingRate: 1e8,
            roundLength: 300,
            growthRate: 10500,
            maxRounds: 100
        });

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "interestRateParams"));
        lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            false,
            0,
            _standardOracleParams(),
            bad
        );
    }

    // ---------------- requestBorrow oracle parameter validation matrix ----------------

    function _badOracle_settlementTimeBelowMin() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(119, 60, 100_000, 100, 10, 200);
    }

    function _badOracle_settlementTimeAboveMax() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(uint48(60 * 60 * 4 + 1), 60, 100_000, 100, 10, 200);
    }

    function _badOracle_disputeDelayGtSettlement() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(300, 300, 100_000, 100, 10, 200); // disputeDelay >= settlementTime
    }

    function _badOracle_escFactorBelowMin() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(300, 60, 100_000, 99, 10, 200);
    }

    function _badOracle_escFactorAboveMax() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(300, 60, 100_000, 1001, 10, 200);
    }

    function _badOracle_initLiquidityBelowMin() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(300, 60, 100_000, 100, 9, 200);
    }

    function _badOracle_initLiquidityAboveMax() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(300, 60, 100_000, 100, 201, 200);
    }

    function _badOracle_escFactorBelowInitLiquidity() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(300, 60, 100_000, 100, 150, 200); // escFactor 100 < initLiquidity 150
    }

    function _badOracle_feeTooHigh() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(300, 60, uint24(1e6 + 1), 100, 10, 200);
    }

    function _badOracle_multiplierBelowMin() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(300, 60, 100_000, 100, 10, 99);
    }

    function _badOracle_multiplierAboveMax() internal pure returns (openLend.OracleParams memory p) {
        p = openLend.OracleParams(300, 60, 100_000, 100, 10, 1001);
    }

    function _expectInvalidInput(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, reason));
    }

    function _request(openLend.OracleParams memory oracleParams) internal {
        vm.prank(borrower);
        lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            false,
            0,
            oracleParams,
            _standardInterestRateParams()
        );
    }

    function testRequestBorrow_OracleParamsValidationMatrix() public {
        _expectInvalidInput("oracle settlementTime out of bounds");
        _request(_badOracle_settlementTimeBelowMin());

        _expectInvalidInput("oracle settlementTime out of bounds");
        _request(_badOracle_settlementTimeAboveMax());

        // escalationFactor bound is checked before disputeDelay; escalationFactor=100, initialLiquidity=10 ok here
        _expectInvalidInput("disputeDelay >= settlementTime");
        _request(_badOracle_disputeDelayGtSettlement());

        _expectInvalidInput("oracle escalation factor out of bounds");
        _request(_badOracle_escFactorBelowMin());

        _expectInvalidInput("oracle escalation factor out of bounds");
        _request(_badOracle_escFactorAboveMax());

        _expectInvalidInput("oracle initial liquidity out of bounds");
        _request(_badOracle_initLiquidityBelowMin());

        _expectInvalidInput("oracle initial liquidity out of bounds");
        _request(_badOracle_initLiquidityAboveMax());

        _expectInvalidInput("escalation factor too small");
        _request(_badOracle_escFactorBelowInitLiquidity());

        _expectInvalidInput("oracle game fees too high");
        _request(_badOracle_feeTooHigh());

        _expectInvalidInput("oracle game multiplier out of bounds");
        _request(_badOracle_multiplierBelowMin());

        _expectInvalidInput("oracle game multiplier out of bounds");
        _request(_badOracle_multiplierAboveMax());
    }

    // ---------------- helpers ----------------

    function _priceRatioFor(uint256 oracleAmount2Target) internal pure returns (uint256) {
        return oracleAmount2Target * 1e18 / 10 ether;
    }

    function _setupActiveLoan(bool allowAnyLiquidator) internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, allowAnyLiquidator);
    }
}
