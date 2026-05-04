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
        uint256 lendingId = _setupActiveLoan(0);
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        vm.warp(uint256(loan.start) + loan.term + loan.gracePeriod);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "expired"));
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);
    }

    /// @dev `liquidate` reverts at `currentTime > start + term` (strict gt). So exactly at maturity is allowed.
    function testLiquidate_AtExactTerm_Succeeds() public {
        uint256 lendingId = _setupActiveLoan(5e6);
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
        , 1e15);

        assertTrue(lending.getLending(lendingId).inLiquidation, "exact-term liquidation should succeed");
    }

    /// @dev `claimCollateral` reverts at `currentTime < start + term + gracePeriod`. At exact boundary the claim succeeds.
    function testClaimCollateral_AtExactGraceBoundary_Succeeds() public {
        uint256 lendingId = _setupActiveLoan(5e6);
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
        , 1e15);

        uint256 reportId = oracle.nextReportId() - 1;
        vm.warp(block.timestamp + 301);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory afterFailedLiq = lending.getLending(lendingId);
        // No dispute, so gracePeriod = 1800 + 2 * settlementTime = 1800 + 600.
        assertEq(afterFailedLiq.gracePeriod, 1800 + 300 * 2, "exact gracePeriod from failed late liq");

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
        uint256 lendingId = _setupActiveLoan(5e6);

        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0
        , 1e15);

        address predicted = _predictFeeReceiver(_latestReportId());
        assertTrue(predicted.code.length > 0, "liquidation should deploy a fee receiver");

        oracleFeeReceiver feeReceiver = oracleFeeReceiver(predicted);
        assertEq(feeReceiver.owner(), address(lending), "clone owner mismatch");
        assertEq(feeReceiver.gameId(), lendingId, "clone gameId mismatch");
        assertEq(address(feeReceiver.oracle()), address(oracle), "clone oracle mismatch");
        assertEq(feeReceiver.token1(), address(supplyToken), "clone token1 mismatch");
        assertEq(feeReceiver.token2(), address(borrowToken), "clone token2 mismatch");
    }

    /// @dev Refinance does NOT deploy a fee receiver; only liquidate does. Cleared on lend-refi.
    function testRefinance_LeavesFeeRecipientUnsetUntilLiquidation() public {
        uint256 lendingId = _setupActiveLoan(5e6);
        assertEq(lending.lendingToReportId(lendingId), 0, "no report yet (no liquidation)");

        // Borrower opens refi
        vm.prank(borrower);
        lending.refinance(
            lendingId,
            10 ether,
            5 ether,
            0,
            0,
            _standardInterestRateParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        // Lender2 accepts
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6);

        assertEq(lending.lendingToReportId(lendingId), 0, "refi should not deploy a fee receiver");
    }

    // ---------------- grab oracle game fees ----------------

    function testGrabOracleGameFeesAny_SweepsBorrowFeesAndSecondSweepIsNoOp() public {
        uint256 lendingId = _setupActiveLoan(5e6);

        vm.warp(block.timestamp + 10 days);

        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0
        , 1e15);

        uint256 reportId = oracle.nextReportId() - 1;
        address feeRecipient = _predictFeeReceiver(reportId);
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
        uint256 lendingId = _setupActiveLoan(5e6);

        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            0
        , 1e15);

        address feeRecipient = _predictFeeReceiver(_latestReportId());

        // Set up a second loan to obtain a "wrong" lendingId that exists
        uint256 otherLendingId = _setupActiveLoan(5e6);
        assertTrue(otherLendingId != lendingId, "two distinct lending ids");

        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "feeRecipient not for lendingId"));
        lending.grabOracleGameFeesAny(otherLendingId, feeRecipient);
    }

    // ---------------- exact-boundary refi/lend ----------------

    /// @dev `refinance` reverts at `currentTime >= start + term + gracePeriod` (when not inLiquidation).
    ///      With gracePeriod = 0 this is `>= start + term`, so EXACTLY at maturity reverts.
    function testRefinance_AtExactMaturity_Reverts() public {
        uint256 lendingId = _setupActiveLoan(0);
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        vm.warp(uint256(loan.start) + loan.term);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "expired"));
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
    }

    /// @dev `lend` (active loan branch) reverts at `currentTime >= start + term + gracePeriod`.
    ///      Exactly at the boundary reverts.
    function testLend_RefiAtExactGraceEnd_Reverts() public {
        uint256 lendingId = _setupActiveLoanForGrace();
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        // _setupActiveLoanForGrace: liq + undisputed settle → gracePeriod = 1800 + 2 * settlementTime.
        assertEq(loan.gracePeriod, 1800 + 300 * 2, "exact gracePeriod from helper");

        // Exactly at the grace boundary
        vm.warp(uint256(loan.start) + loan.term + loan.gracePeriod);

        vm.prank(lender2);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "expired"));
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0);
    }

    /// @dev `lend` (active loan branch) succeeds one second BEFORE grace end.
    function testLend_RefiOneSecondBeforeGraceEnd_Succeeds() public {
        uint256 lendingId = _setupActiveLoanForGrace();
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        // One second before the grace boundary
        vm.warp(uint256(loan.start) + loan.term + loan.gracePeriod - 1);

        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0);

        assertEq(lending.getLending(lendingId).lender, lender2, "should accept refi 1s before grace end");
    }

    /// @dev Helper: originate, force a near-maturity failed liq to set gracePeriod, then open a refi during grace.
    function _setupActiveLoanForGrace() internal returns (uint256 lendingId) {
        lendingId = _setupActiveLoan(5e6);

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
        , 1e15);

        uint256 reportId = oracle.nextReportId() - 1;
        vm.warp(block.timestamp + 301);
        vm.prank(settler);
        oracle.settle(reportId);

        // Now gracePeriod > 0. Open a refi so a `lend` accept path exists
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);
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
            uint24(1e7),
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
            uint24(1e7),
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
            uint24(1e7),
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
        // initLiquidity must be <= escFactor; setting initLiquidity also = 9 still passes initLiquidity >= 10 check.
        // Use escFactor = 9, initLiquidity = 9 → both fail the lower bounds (10).
        p = openLend.OracleParams(300, 60, 100_000, 9, 9, 200);
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
            uint24(1e7),
            0,
            oracleParams,
            _standardInterestRateParams()
        );
    }

    function testRequestBorrow_OracleParamsValidationMatrix() public {
        // _validateOracleParams collapses every per-field check into a single revert("oracleParams").
        _expectInvalidInput("oracleParams");
        _request(_badOracle_settlementTimeBelowMin());

        _expectInvalidInput("oracleParams");
        _request(_badOracle_settlementTimeAboveMax());

        _expectInvalidInput("oracleParams");
        _request(_badOracle_disputeDelayGtSettlement());

        _expectInvalidInput("oracleParams");
        _request(_badOracle_escFactorBelowMin());

        _expectInvalidInput("oracleParams");
        _request(_badOracle_escFactorAboveMax());

        _expectInvalidInput("oracleParams");
        _request(_badOracle_initLiquidityBelowMin());

        _expectInvalidInput("oracleParams");
        _request(_badOracle_initLiquidityAboveMax());

        _expectInvalidInput("oracleParams");
        _request(_badOracle_escFactorBelowInitLiquidity());

        _expectInvalidInput("oracleParams");
        _request(_badOracle_feeTooHigh());

        _expectInvalidInput("oracleParams");
        _request(_badOracle_multiplierBelowMin());

        _expectInvalidInput("oracleParams");
        _request(_badOracle_multiplierAboveMax());
    }

    // ---------------- requestBorrow non-oracle guard matrix ----------------

    function _requestBorrowRaw(
        address supplyTokenAddr,
        address borrowTokenAddr,
        uint24 lt,
        uint128 supplyAmt,
        uint128 amountDemanded,
        uint16 stake,
        uint48 term,
        openLend.InterestRateParams memory ir
    ) internal {
        vm.prank(borrower);
        lending.requestBorrow(
            term,
            supplyTokenAddr,
            borrowTokenAddr,
            lt,
            supplyAmt,
            amountDemanded,
            stake,
            uint24(1e7),
            0,
            _standardOracleParams(),
            ir
        );
    }

    function testRequestBorrow_RejectsSameTokenOnBothSides() public {
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "supply == borrow"));
        _requestBorrowRaw(address(supplyToken), address(supplyToken), 8e6, SUPPLY_AMOUNT, BORROW_AMOUNT, 100, LOAN_TERM, _standardInterestRateParams());
    }

    function testRequestBorrow_RejectsLiquidationThresholdBelowMin() public {
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "LT out of bounds"));
        _requestBorrowRaw(address(supplyToken), address(borrowToken), 7e6 - 1, SUPPLY_AMOUNT, BORROW_AMOUNT, 100, LOAN_TERM, _standardInterestRateParams());
    }

    function testRequestBorrow_RejectsLiquidationThresholdAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "LT out of bounds"));
        _requestBorrowRaw(address(supplyToken), address(borrowToken), 1e7 + 1, SUPPLY_AMOUNT, BORROW_AMOUNT, 100, LOAN_TERM, _standardInterestRateParams());
    }

    function testRequestBorrow_RejectsStakeAboveBound() public {
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "stake too high"));
        _requestBorrowRaw(address(supplyToken), address(borrowToken), 8e6, SUPPLY_AMOUNT, BORROW_AMOUNT, 10001, LOAN_TERM, _standardInterestRateParams());
    }

    function testRequestBorrow_RejectsTermBelowMin() public {
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "term out of bounds"));
        _requestBorrowRaw(address(supplyToken), address(borrowToken), 8e6, SUPPLY_AMOUNT, BORROW_AMOUNT, 100, 1799, _standardInterestRateParams());
    }

    function testRequestBorrow_RejectsTermAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "term out of bounds"));
        _requestBorrowRaw(
            address(supplyToken), address(borrowToken), 8e6, SUPPLY_AMOUNT, BORROW_AMOUNT, 100,
            uint48(60 * 60 * 24 * 365 + 1), _standardInterestRateParams()
        );
    }

    /// @dev supply + (supply * stake / 10000) > uint128.max — pick supplyAmount near the cap with non-zero stake.
    function testRequestBorrow_RejectsSupplyPlusStakeOverflow() public {
        uint128 nearMax = uint128(type(uint128).max - 1);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "supply + stake too high"));
        _requestBorrowRaw(address(supplyToken), address(borrowToken), 8e6, nearMax, BORROW_AMOUNT, 100, LOAN_TERM, _standardInterestRateParams());
    }

    function testRequestBorrow_RejectsMaxRateBelowStartingRate() public {
        openLend.InterestRateParams memory bad = openLend.InterestRateParams({
            maxRate: 1e8,
            startingRate: 1e9,    // startingRate > maxRate → reject
            roundLength: 300,
            growthRate: 10500,
            maxRounds: 100
        });
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "interestRateParams"));
        _requestBorrowRaw(address(supplyToken), address(borrowToken), 8e6, SUPPLY_AMOUNT, BORROW_AMOUNT, 100, LOAN_TERM, bad);
    }

    function testRequestBorrow_RejectsZeroInterestRateField() public {
        openLend.InterestRateParams memory zeroStart = openLend.InterestRateParams({
            maxRate: 1e9,
            startingRate: 0,        // zero starting rate → reject
            roundLength: 300,
            growthRate: 10500,
            maxRounds: 100
        });
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "interestRateParams"));
        _requestBorrowRaw(address(supplyToken), address(borrowToken), 8e6, SUPPLY_AMOUNT, BORROW_AMOUNT, 100, LOAN_TERM, zeroStart);

        openLend.InterestRateParams memory zeroRound = openLend.InterestRateParams({
            maxRate: 1e9,
            startingRate: 1e8,
            roundLength: 0,        // zero roundLength → reject
            growthRate: 10500,
            maxRounds: 100
        });
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "interestRateParams"));
        _requestBorrowRaw(address(supplyToken), address(borrowToken), 8e6, SUPPLY_AMOUNT, BORROW_AMOUNT, 100, LOAN_TERM, zeroRound);
    }

    // ---------------- helpers ----------------

    function _priceRatioFor(uint256 oracleAmount2Target) internal pure returns (uint256) {
        return oracleAmount2Target * 1e18 / 10 ether;
    }

    function _setupActiveLoan(uint24 liquidatorFraction) internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, liquidatorFraction);
    }
}
