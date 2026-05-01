// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";

contract VirtualTimeAndStakeSplitTest is OpenLendingBaseTest {
    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal lender2 = address(0x3);
    address internal liquidator = address(0x4);
    address internal disputer = address(0x5);
    address internal settler = address(0x6);
    address internal randomCaller = address(0x7);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 70 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint16 constant STAKE = 100;
    uint96 constant SETTLER_REWARD = 1e15;
    uint256 constant ORACLE_SETTLEMENT_TIME = 300;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accts = new address[](7);
        accts[0] = borrower;
        accts[1] = lender;
        accts[2] = lender2;
        accts[3] = liquidator;
        accts[4] = disputer;
        accts[5] = settler;
        accts[6] = randomCaller;
        _fundSupply(accts, 10_000 ether);
        _fundBorrow(accts, 10_000 ether);
        _dealETH(accts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(lender2);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);
    }

    // ---------------- helpers ----------------

    function _setupActiveLoan(bool allowAnyLiquidator) internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, allowAnyLiquidator);
    }

    function _liquidateAt(address by, uint256 lendingId, uint256 priceRatio18) internal returns (uint256 reportId) {
        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(by);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId, priceRatio18, type(uint128).max, paramHash, 0
        );
        reportId = oracle.nextReportId() - 1;
    }

    /// @dev priceRatio that produces oracleAmount2 = `borrowSize` at default initialLiquidity (10% of 100 = 10 ether).
    function _priceRatioFor(uint256 borrowSize) internal pure returns (uint256) {
        return borrowSize * 1e18 / 10 ether;
    }

    function _settleableAtFor(uint256 reportId) internal view returns (uint48) {
        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        (,,,,, uint48 settlementTime,,,,,,) = oracle.reportMeta(reportId);
        return reportTs + settlementTime;
    }

    // -------------------------------------------------------------------------
    // 1. refinance during liquidation parks requestStart at zero
    // -------------------------------------------------------------------------

    function testRefiDuringLiq_RequestStartParkedAtZero() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + 1 days);

        _liquidateAt(liquidator, lendingId, _priceRatioFor(12 ether));

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, 0
        );

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.curveOpen, "curve open after refi during liq");
        assertEq(loan.requestStart, 0, "requestStart parked at 0 while in liq");
        assertTrue(loan.inLiquidation, "still in liq");
    }

    // -------------------------------------------------------------------------
    // 2. failed liquidation sets virtual requestStart = settleableAt
    // -------------------------------------------------------------------------

    function testLiqFailed_SetsVirtualRequestStart() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + 1 days);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(12 ether));

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, 0
        );

        uint48 settleableAt = _settleableAtFor(reportId);

        // Settle 7s past settleableAt -- block.timestamp at settle will not equal settleableAt.
        vm.warp(uint256(settleableAt) + 7);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertFalse(loan.inLiquidation, "liq cleared");
        assertEq(loan.requestStart, settleableAt, "requestStart pinned to settleableAt");
        assertLt(loan.requestStart, uint48(block.timestamp), "requestStart strictly earlier than current block");
    }

    // -------------------------------------------------------------------------
    // 3. lend auto-settles failed liquidation and accepts the parked refi
    // -------------------------------------------------------------------------

    function testLend_AutoSettlesFailedLiqAndAcceptsRefi() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + 1 days);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(12 ether));

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, 0
        );

        uint48 settleableAt = _settleableAtFor(reportId);

        // Warp 1 round (300s) + 5s past settleableAt -> exactly 1 virtual round elapsed at lend time.
        vm.warp(uint256(settleableAt) + 300 + 5);

        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertFalse(loan.inLiquidation, "liq cleared by auto-settle");
        assertFalse(loan.finished, "loan not finished -- failed liq, refi accepted");
        assertEq(loan.lender, lender2, "lender2 accepted refi");

        // 1 virtual round: rate = startingRate * 10500 / 10000 = 1.05e8.
        assertEq(loan.rate, 105_000_000, "rate from 1 virtual round");
    }

    // -------------------------------------------------------------------------
    // 4. late settlement increases the refi rate (no free time after settle eligibility)
    // -------------------------------------------------------------------------

    function testLateSettlement_IncreasesRefiRate() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + 1 days);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(12 ether));

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, 0
        );

        uint48 settleableAt = _settleableAtFor(reportId);

        // 5 roundLengths (5 * 300 = 1500s) past settleableAt -> 5 virtual rounds elapsed.
        vm.warp(uint256(settleableAt) + 5 * 300 + 5);

        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        // 1e8 * (10500/10000)^5, with floor at each round:
        //   1.05e8 -> 110_250_000 -> 115_762_500 -> 121_550_625 -> 127_628_156
        assertEq(loan.rate, 127_628_156, "rate after 5 virtual rounds");
        assertGt(loan.rate, 1e8, "rate strictly above startingRate");
    }

    // -------------------------------------------------------------------------
    // 5. getParamHash projection matches post-auto-settle state (failed liq, no grace)
    // -------------------------------------------------------------------------

    function testGetParamHash_ProjectionMatchesPostAutoSettleState() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + 1 days);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(12 ether));

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, 0
        );

        uint48 settleableAt = _settleableAtFor(reportId);
        vm.warp(uint256(settleableAt) + 5);

        // Hash must reflect the post-failed-liq projection so that lend()'s _checkParamsLoose validates.
        bytes32 paramHash = lending.getParamHash(lendingId);
        assertTrue(paramHash != bytes32(0), "projected hash non-zero");

        vm.prank(lender2);
        lending.lend(lendingId, paramHash, 0, type(uint128).max, 0, 0, false);

        assertEq(lending.getLending(lendingId).lender, lender2, "lender2 accepted refi using projected hash");
    }

    // -------------------------------------------------------------------------
    // 6. getParamHash near-maturity projection includes the half-stake split
    // -------------------------------------------------------------------------

    function testGetParamHash_GraceProjectionIncludesHalfStakeSplit() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + LOAN_TERM - 900); // grace-window territory

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(12 ether));

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, 0
        );

        uint48 settleableAt = _settleableAtFor(reportId);
        vm.warp(uint256(settleableAt) + 5);

        bytes32 paramHash = lending.getParamHash(lendingId);

        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;
        uint256 lenderStakePiece = tokenStake / 2;

        vm.prank(lender2);
        lending.lend(lendingId, paramHash, 0, type(uint128).max, 0, 0, false);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.lender, lender2, "lender2 accepted refi using projected hash");

        // After auto-settle's failed-liq-with-grace branch: supplyAmount only includes the borrower-side stake
        // remainder; the original lender already received the lender stake piece from _transferTokens. (The
        // lend() refi branch then zeroes gracePeriod itself, so we observe the grace branch only through its
        // side effects on supplyAmount and the lender's wallet.)
        assertEq(
            loan.supplyAmount,
            SUPPLY_AMOUNT + (tokenStake - lenderStakePiece),
            "supplyAmount += borrower-side stake remainder only"
        );
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBefore + lenderStakePiece,
            "original lender received half stake at auto-settle"
        );
    }

    // -------------------------------------------------------------------------
    // 7. failed liquidation, no grace: full stake to supplyAmount, lender unchanged
    // -------------------------------------------------------------------------

    function testLiqFailed_NoGrace_FullStakeToSupply() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + 1 days); // far from maturity

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(12 ether));

        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;

        uint48 settleableAt = _settleableAtFor(reportId);
        vm.warp(uint256(settleableAt) + 5);

        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertFalse(loan.inLiquidation, "liq cleared");
        assertEq(loan.gracePeriod, 0, "no grace far from maturity");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + tokenStake, "supplyAmount += full tokenStake");
        assertEq(supplyToken.balanceOf(lender), lenderSupplyBefore, "lender supply balance unchanged");
    }

    // -------------------------------------------------------------------------
    // 8. failed liquidation with grace: half stake routes to lender at settle
    // -------------------------------------------------------------------------

    function testLiqFailed_WithGrace_HalfStakeToLender() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + LOAN_TERM - 900); // near maturity

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(12 ether));

        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;
        uint256 lenderStakePiece = tokenStake / 2;

        uint48 settleableAt = _settleableAtFor(reportId);
        vm.warp(uint256(settleableAt) + 5);

        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertFalse(loan.inLiquidation, "liq cleared");
        assertGt(loan.gracePeriod, 0, "grace fired");
        assertEq(
            loan.supplyAmount,
            SUPPLY_AMOUNT + (tokenStake - lenderStakePiece),
            "supplyAmount += borrower-side stake remainder"
        );
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBefore + lenderStakePiece,
            "lender received half stake at settle"
        );
    }

    // -------------------------------------------------------------------------
    // 9. recover near-grace returns full stake to liquidator (no split)
    // -------------------------------------------------------------------------

    function testRecover_NearGrace_ReturnsFullStakeToLiquidator() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + LOAN_TERM - 900); // near maturity

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(12 ether));

        uint48 settleableAt = _settleableAtFor(reportId);
        vm.warp(uint256(settleableAt) + 5);

        // Force callback failure so recover() is the resolution path.
        vm.mockCallRevert(
            address(lending), abi.encodeWithSelector(openLend.onSettle.selector), "callback bricked"
        );
        vm.prank(settler);
        oracle.settle(reportId);
        vm.clearMockedCalls();

        // Snapshot AFTER oracle.settle (which already returned initialLiquidity to currentReporter = liquidator).
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;

        vm.prank(randomCaller);
        lending.recover(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertFalse(loan.inLiquidation, "liq cleared by recover");
        assertEq(
            supplyToken.balanceOf(liquidator),
            liquidatorSupplyBefore + tokenStake,
            "recover sends full stake to liquidator"
        );
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBefore,
            "lender supply unchanged -- recover does not split stake"
        );
        // Grace formula uses settleableAt - liquidationStart = ORACLE_SETTLEMENT_TIME (no dispute).
        assertEq(loan.gracePeriod, 1800 + ORACLE_SETTLEMENT_TIME * 2, "grace from settleable-time formula");
    }

    // -------------------------------------------------------------------------
    // 9b. recover() with an open refi curve sets virtual requestStart
    // -------------------------------------------------------------------------

    function testRecover_OpenRefiCurve_SetsVirtualRequestStart() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + 1 days);

        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(12 ether));

        // Borrower opens a refi mid-liq -- curve open with parked requestStart.
        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, 0
        );
        openLend.LendingArrangement memory mid = lending.getLending(lendingId);
        assertTrue(mid.curveOpen, "curve open after mid-liq refi");
        assertEq(mid.requestStart, 0, "requestStart parked at 0");

        uint48 settleableAt = _settleableAtFor(reportId);

        // Warp well past settleableAt and force a reverting callback so recover() is the resolution path.
        vm.warp(uint256(settleableAt) + 1 hours);
        vm.mockCallRevert(
            address(lending), abi.encodeWithSelector(openLend.onSettle.selector), "callback bricked"
        );
        vm.prank(settler);
        oracle.settle(reportId);
        vm.clearMockedCalls();

        vm.prank(randomCaller);
        lending.recover(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertFalse(loan.inLiquidation, "liq cleared by recover");
        assertTrue(loan.curveOpen, "refi curve survives recover");
        assertEq(loan.requestStart, settleableAt, "requestStart pinned to settleableAt, not recover-time");
        assertLt(loan.requestStart, uint48(block.timestamp), "requestStart strictly earlier than current block");
    }

    // -------------------------------------------------------------------------
    // 10. underwater auto-settle through lend() reverts and rolls back
    // -------------------------------------------------------------------------

    function testLend_UnderwaterAutoSettleRollsBack() public {
        uint256 lendingId = _setupActiveLoan(true);
        vm.warp(block.timestamp + 1 days);

        // Underwater priceRatio (oracleAmount2 = 6 ether on 10 ether of supply -> supply cheap, position under).
        uint256 reportId = _liquidateAt(liquidator, lendingId, _priceRatioFor(6 ether));

        vm.prank(borrower);
        lending.refinance(
            lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, 0
        );

        uint48 settleableAt = _settleableAtFor(reportId);
        vm.warp(uint256(settleableAt) + 5);

        // Snapshot pre-call state so we can verify nothing persisted.
        bool inLiqBefore = lending.getLending(lendingId).inLiquidation;
        bool finishedBefore = lending.getLending(lendingId).finished;
        uint256 reportMappingBefore = lending.lendingToReportId(lendingId);
        (,,,, uint48 settleTsBefore,,) = oracle.reportStatus(reportId);
        assertTrue(inLiqBefore, "in liq pre-call");
        assertEq(settleTsBefore, 0, "oracle not settled pre-call");

        // lend() auto-settles -> underwater -> loan finished -> body reverts on `finished` check -> whole tx unwinds.
        vm.prank(lender2);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "finished"));
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);

        // EVM rollback should leave both openLend and the oracle in their pre-call state.
        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertEq(loanAfter.inLiquidation, inLiqBefore, "still in liq (rolled back)");
        assertEq(loanAfter.finished, finishedBefore, "not finished (rolled back)");
        assertEq(lending.lendingToReportId(lendingId), reportMappingBefore, "mapping intact (rolled back)");
        (,,,, uint48 settleTsAfter,,) = oracle.reportStatus(reportId);
        assertEq(settleTsAfter, settleTsBefore, "oracle report not settled (rolled back)");
    }
}
