// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";

contract RecoveryTest is OpenLendingBaseTest {
    event Recovery(uint256 indexed lendingId);
    event LiqUnsuccessful(uint256 indexed lendingId);

    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal liquidator = address(0x3);
    address internal disputer = address(0x4);
    address internal settler = address(0x5);
    address internal randomCaller = address(0x6);

    uint256 constant UNRELATED_SUPPLY = 500 ether;
    uint256 constant UNRELATED_BORROW = 1000 ether;

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 70 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint16 constant STAKE = 100;

    uint256 constant ORACLE_SETTLEMENT_TIME = 300;
    uint256 constant ORACLE_DISPUTE_DELAY = 60;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accounts = new address[](4);
        accounts[0] = borrower;
        accounts[1] = lender;
        accounts[2] = liquidator;
        accounts[3] = disputer;
        _fundSupply(accounts, 10000 ether);
        _fundBorrow(accounts, 10000 ether);

        address[] memory ethAccounts = new address[](6);
        ethAccounts[0] = borrower;
        ethAccounts[1] = lender;
        ethAccounts[2] = liquidator;
        ethAccounts[3] = disputer;
        ethAccounts[4] = settler;
        ethAccounts[5] = randomCaller;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);

        _seedUnrelated(UNRELATED_SUPPLY, UNRELATED_BORROW);
    }

    /// @dev Originate with liquidatorFraction = true so liquidator can act.
    function _setupLoan() internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6);
    }

    function _priceRatioFor(uint256 oracleAmount2Target) internal pure returns (uint256) {
        return oracleAmount2Target * 1e18 / 10 ether;
    }

    function _liquidate(uint256 lendingId, uint256 oracleAmount2Target) internal returns (uint256 reportId) {
        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(oracleAmount2Target),
            type(uint128).max,
            paramHash,
             0,
            1e15,
            _emptyTiming()
        );
        reportId = oracle.nextReportId() - 1;
    }

    /// @dev Forces the oracle's low-level callback into onSettle to revert. Mock matches the bare selector so it
    ///      catches any args the oracle passes. Caller is responsible for clearing mocks afterwards.
    function _forceCallbackRevert() internal {
        vm.mockCallRevert(
            address(lending),
            abi.encodeWithSelector(openLend.openOracleCallback.selector),
            "callback bricked"
        );
    }

    function _settleWithBrokenCallback(uint256 reportId) internal {
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        _forceCallbackRevert();
        vm.prank(settler);
        _settleOracle(reportId);
        vm.clearMockedCalls();
    }

    function _settleNormally(uint256 reportId) internal {
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(reportId);
    }

    // -------------------------------------------------------------------------
    // Happy recovery
    // -------------------------------------------------------------------------

    function testRecover_FailedCallbackUnsticksLoan() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        // Loan is in liquidation, mapping populated.
        assertTrue(lending.getLending(lendingId).inLiquidation, "should be in liquidation");
        assertEq(lending.reportIdToLending(reportId), lendingId, "mapping populated by liquidate");

        _settleWithBrokenCallback(reportId);

        // Oracle settled (settlementTimestamp != 0), but openLend is stuck (callback reverted, state rolled back).
        (,,,, uint48 settlementTimestamp,,) = _reportStatus(reportId);
        assertGt(settlementTimestamp, 0, "oracle thinks report is settled");
        assertTrue(lending.getLending(lendingId).inLiquidation, "openLend stuck in liquidation");
        assertEq(lending.reportIdToLending(reportId), lendingId, "mapping not cleared since onSettle reverted");

        // Anyone can call recover.
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;

        vm.expectEmit(true, false, false, true, address(lending));
        emit Recovery(lendingId);
        vm.prank(randomCaller);
        lending.recover(reportId);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertFalse(loanAfter.inLiquidation, "inLiquidation cleared");
        assertEq(loanAfter.liquidator, address(0), "liquidator cleared");
        assertEq(loanAfter.liquidationStart, 0, "liquidationStart cleared");
        assertEq(lending.reportIdToLending(reportId), 0, "mapping cleared by recover");

        // Recover now follows the same failed-liq branch as onSettle: no-grace stake is added to supplyAmount.
        assertEq(
            supplyToken.balanceOf(liquidator) - liquidatorSupplyBefore,
            0,
            "liquidator does not recover stake on failed-liq recover"
        );
        assertEq(loanAfter.supplyAmount, SUPPLY_AMOUNT + tokenStake, "supplyAmount includes forfeited stake");
        assertTrue(loanAfter.active, "loan still live");
        assertFalse(loanAfter.finished, "loan not finished");
    }

    // -------------------------------------------------------------------------
    // Curve hygiene
    // -------------------------------------------------------------------------

    function testRecover_OpenRefiCurveHasRequestStartReset() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        uint48 settleableAt = reportTs + uint48(ORACLE_SETTLEMENT_TIME);

        // Borrower opens a refi curve mid-liq.
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        // Warp deep into the oracle game so settle/recover lands far past settleableAt.
        vm.warp(block.timestamp + 60 minutes);
        _forceCallbackRevert();
        vm.prank(settler);
        _settleOracle(reportId);
        vm.clearMockedCalls();

        vm.prank(randomCaller);
        lending.recover(reportId);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.curveOpen, "curve still open");
        assertEq(loanAfter.requestStart, settleableAt, "requestStart pinned to settleableAt, not recover-time");
    }

    // -------------------------------------------------------------------------
    // Grace period
    // -------------------------------------------------------------------------

    function testRecover_NearMaturityGrantsGracePeriod() public {
        uint256 lendingId = _setupLoan();

        // Liquidate well before maturity.
        vm.warp(block.timestamp + LOAN_TERM - 1500);
        uint256 reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        uint48 liqStart = lending.getLending(lendingId).liquidationStart;
        assertGt(liqStart, 0, "liquidationStart populated");

        // Settle inside the near-maturity window so gracePeriod is granted.
        _settleWithBrokenCallback(reportId);

        vm.prank(randomCaller);
        lending.recover(reportId);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        uint256 expectedGrace = _failedLiqGracePeriod(reportId, liqStart);
        assertEq(loanAfter.gracePeriod, expectedGrace, "gracePeriod follows the same near-maturity rule");
        assertGt(loanAfter.gracePeriod, 1800, "delta term should be non-zero");
    }

    function testRecover_FarFromMaturityNoGracePeriod() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 1 days);

        uint256 reportId = _liquidate(lendingId, 8 ether);
        _settleWithBrokenCallback(reportId);

        vm.prank(randomCaller);
        lending.recover(reportId);

        assertEq(lending.getLending(lendingId).gracePeriod, 0, "no gracePeriod far from maturity");
    }

    // -------------------------------------------------------------------------
    // Fee sweep
    // -------------------------------------------------------------------------

    function testRecover_AccruedFeesAreSwept() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidate(lendingId, 8 ether);

        // Need a feeRecipient and accrued fees: dispute once so the swap charges protocolFee.
        bytes32 stateHash = bytes32(0);
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 30 ether, disputer, 8 ether, stateHash);

        address feeRecipient = _predictFeeReceiver(reportId);
        assertTrue(feeRecipient.code.length > 0, "fee receiver deployed");

        _settleWithBrokenCallback(reportId);

        uint256 borrowerSupplyBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(supplyToken));
        uint256 lenderSupplyBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(supplyToken));
        uint256 liquidatorSupplyBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(supplyToken));

        vm.prank(randomCaller);
        lending.recover(reportId);

        // Single token1 dispute (oldAmount1 = 10 ether, protocolFee = 100_000 / 1e7 = 1%) → 0.1 ether fee in supply.
        // Split 50/25/25 (borrower / lender / liquidator) via integer division: 0.05 / 0.025 / 0.025.
        uint256 expectedFee = 10 ether * 100_000 / 1e7;          // 0.1 ether
        uint256 borrowerPiece = expectedFee / 2;                 // 0.05 ether
        uint256 lenderPiece = borrowerPiece / 2;                 // 0.025 ether
        uint256 liquidatorPiece = expectedFee - borrowerPiece - lenderPiece; // 0.025 ether

        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(borrower, address(supplyToken)) - borrowerSupplyBefore,
            borrowerPiece + (borrowerSupplyBefore == 0 ? 1 : 0),
            "borrower exact supply fee piece"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(lender, address(supplyToken)) - lenderSupplyBefore,
            lenderPiece + (lenderSupplyBefore == 0 ? 1 : 0),
            "lender exact supply fee piece"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(supplyToken)) - liquidatorSupplyBefore,
            liquidatorPiece + (liquidatorSupplyBefore == 0 ? 1 : 0),
            "liquidator exact supply fee piece"
        );
    }

    // -------------------------------------------------------------------------
    // Reverts
    // -------------------------------------------------------------------------

    function testRecover_RevertsWhenReportIdMapsToNoLending() public {
        // No liquidate has ever been called, so reportIdToLending[42] = 0.
        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "no lendingId for reportId"));
        lending.recover(42);
    }

    function testRecover_RevertsBeforeOracleSettles() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidate(lendingId, 8 ether);

        // Don't warp / settle — report is still live.
        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "no oracle settlement"));
        lending.recover(reportId);
    }

    function testRecover_RevertsAfterAlreadyRecovered() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidate(lendingId, 8 ether);
        _settleWithBrokenCallback(reportId);

        vm.prank(randomCaller);
        lending.recover(reportId);

        // Second call: reportIdToLending[reportId] was cleared, so the first gate trips first.
        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "no lendingId for reportId"));
        lending.recover(reportId);
    }

    /// @dev If onSettle ran successfully, reportIdToLending was cleared inside it. A later recover() with that
    ///      stale reportId must revert — even though the oracle still reports it as settled.
    function testRecover_RevertsForStaleReportIdAfterSuccessfulPriorCycle() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        // Cycle 1: failed liquidation that runs onSettle normally. No callback failure.
        uint256 firstReportId = _liquidate(lendingId, 6 ether);
        bytes32 stateHash = bytes32(0);

        // Push price even further in borrower's favor so liq fails.
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        _disputeAndSwap(firstReportId, address(supplyToken), 20 ether, 30 ether, disputer, 12 ether, stateHash);

        _settleNormally(firstReportId);

        // onSettle succeeded → mapping cleared.
        assertEq(lending.reportIdToLending(firstReportId), 0, "mapping cleared by successful onSettle");
        assertFalse(lending.getLending(lendingId).inLiquidation, "loan back to active");

        // Try recover with stale reportId → reverts.
        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "no lendingId for reportId"));
        lending.recover(firstReportId);

        // And just to be thorough: even though the loan is currently NOT in liquidation, the reportId gate trips
        // first. The "not in liquidation" gate is structurally redundant but cheap.
    }

    /// @dev Independent assertion of the same invariant: a normal successful onSettle clears reportIdToLending.
    function testNormalSettlement_ClearsReportIdToLending() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidate(lendingId, 6 ether);

        // Single dispute → underwater settlement.
        bytes32 stateHash = bytes32(0);
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);

        assertEq(lending.reportIdToLending(reportId), lendingId, "mapping populated during liq");

        _settleNormally(reportId);

        assertEq(lending.reportIdToLending(reportId), 0, "mapping cleared by underwater onSettle");
        assertTrue(lending.getLending(lendingId).finished, "loan finished underwater");
    }

    // -------------------------------------------------------------------------
    // Underwater recovery
    // -------------------------------------------------------------------------

    /// @dev Underwater callback failure is recovered by executing the same underwater liquidation outcome.
    function testRecover_UnderwaterCallbackFailureExecutesLiquidationOutcome() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        // First liquidation: oracle would resolve underwater (single dispute pushes ratio to 20/10 = 2.0,
        // debtInSupplyTerms ~= 140 > supplyAmount 100). But the callback fails.
        uint256 firstReportId = _liquidate(lendingId, 6 ether);
        bytes32 stateHash = bytes32(0);

        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        _disputeAndSwap(firstReportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);

        _settleWithBrokenCallback(firstReportId);

        uint256 lenderSupplyBeforeRecover = supplyToken.balanceOf(lender);

        vm.prank(randomCaller);
        lending.recover(firstReportId);

        openLend.LendingArrangement memory loanAfterRecover = lending.getLending(lendingId);
        assertTrue(loanAfterRecover.finished, "loan finishes underwater via recover");
        assertFalse(loanAfterRecover.inLiquidation, "inLiquidation cleared");
        assertEq(lending.reportIdToLending(firstReportId), 0, "report mapping cleared");
        assertEq(lending.lendingToReportId(lendingId), 0, "reverse mapping cleared");

        // Underwater no-equity branch: lender gets collateral externally; fee share is oracle-internal.
        uint256 firstCycleLenderFee = (10 ether * 100_000 / 1e7) / 2 / 2; // 0.025 ether
        assertEq(
            supplyToken.balanceOf(lender) - lenderSupplyBeforeRecover,
            uint256(SUPPLY_AMOUNT),
            "lender gain from recovery = underwater payout"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(lender, address(supplyToken)),
            firstCycleLenderFee + 1,
            "lender fee share credited internally"
        );
    }

    function testRecover_UnderwaterOutcomeMatchesNormalOnSettleAccounting() public {
        uint256 normalLendingId = _setupLoan();
        uint256 recoverLendingId = _setupLoan();

        vm.warp(block.timestamp + 10 days);
        uint256 normalReportId = _liquidate(normalLendingId, 6 ether);
        uint256 recoverReportId = _liquidate(recoverLendingId, 6 ether);

        (,,, uint48 normalReportTs,,,) = _reportStatus(normalReportId);
        (,,, uint48 recoverReportTs,,,) = _reportStatus(recoverReportId);
        assertEq(normalReportTs, recoverReportTs, "reports share timestamp");

        uint256 borrowerBeforeNormal = supplyToken.balanceOf(borrower);
        uint256 lenderBeforeNormal = supplyToken.balanceOf(lender);
        uint256 liquidatorBeforeNormal = supplyToken.balanceOf(liquidator);

        vm.warp(uint256(normalReportTs) + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        _settleOracle(normalReportId);

        uint256 borrowerNormalDelta = supplyToken.balanceOf(borrower) - borrowerBeforeNormal;
        uint256 lenderNormalDelta = supplyToken.balanceOf(lender) - lenderBeforeNormal;
        uint256 liquidatorNormalDelta = supplyToken.balanceOf(liquidator) - liquidatorBeforeNormal;

        uint256 borrowerBeforeRecover = supplyToken.balanceOf(borrower);
        uint256 lenderBeforeRecover = supplyToken.balanceOf(lender);
        uint256 liquidatorBeforeRecover = supplyToken.balanceOf(liquidator);

        _forceCallbackRevert();
        vm.prank(settler);
        _settleOracle(recoverReportId);
        vm.clearMockedCalls();

        vm.prank(randomCaller);
        lending.recover(recoverReportId);

        assertEq(
            supplyToken.balanceOf(borrower) - borrowerBeforeRecover,
            borrowerNormalDelta,
            "borrower supply delta matches normal settle"
        );
        assertEq(
            supplyToken.balanceOf(lender) - lenderBeforeRecover,
            lenderNormalDelta,
            "lender supply delta matches normal settle"
        );
        assertEq(
            supplyToken.balanceOf(liquidator) - liquidatorBeforeRecover,
            liquidatorNormalDelta,
            "liquidator supply delta matches normal settle"
        );

        openLend.LendingArrangement memory normalLoan = lending.getLending(normalLendingId);
        openLend.LendingArrangement memory recoveredLoan = lending.getLending(recoverLendingId);
        assertTrue(normalLoan.finished, "normal loan finished");
        assertTrue(recoveredLoan.finished, "recovered loan finished");
        assertFalse(normalLoan.inLiquidation, "normal inLiquidation cleared");
        assertFalse(recoveredLoan.inLiquidation, "recover inLiquidation cleared");
        assertEq(lending.reportIdToLending(normalReportId), 0, "normal report mapping cleared");
        assertEq(lending.reportIdToLending(recoverReportId), 0, "recover report mapping cleared");
    }

    // -------------------------------------------------------------------------
    // Stake-destination policy
    // -------------------------------------------------------------------------

    function testRecover_FailedLiqStakeAddedToSupplyAmount() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);
        _settleWithBrokenCallback(reportId);

        uint128 supplyBeforeRecover = lending.getLending(lendingId).supplyAmount;
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;

        vm.prank(randomCaller);
        lending.recover(reportId);

        assertEq(
            lending.getLending(lendingId).supplyAmount,
            supplyBeforeRecover + tokenStake,
            "supplyAmount increments by failed-liq stake"
        );
        assertEq(
            supplyToken.balanceOf(liquidator) - liquidatorSupplyBefore,
            0,
            "liquidator does not get failed-liq stake back"
        );
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore,
            "borrower does NOT receive the stake"
        );
    }
}
