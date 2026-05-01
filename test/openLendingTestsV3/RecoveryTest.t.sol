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

    /// @dev Originate with allowAnyLiquidator = true so liquidator can act.
    function _setupLoan() internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, true);
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
            0
        );
        reportId = oracle.nextReportId() - 1;
    }

    /// @dev Forces the oracle's low-level callback into onSettle to revert. Mock matches the bare selector so it
    ///      catches any args the oracle passes. Caller is responsible for clearing mocks afterwards.
    function _forceCallbackRevert() internal {
        vm.mockCallRevert(
            address(lending),
            abi.encodeWithSelector(openLend.onSettle.selector),
            "callback bricked"
        );
    }

    function _settleWithBrokenCallback(uint256 reportId) internal {
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        _forceCallbackRevert();
        vm.prank(settler);
        oracle.settle(reportId);
        vm.clearMockedCalls();
    }

    function _settleNormally(uint256 reportId) internal {
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);
    }

    // -------------------------------------------------------------------------
    // Happy recovery
    // -------------------------------------------------------------------------

    function testRecover_FailedCallbackUnsticksLoan() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidate(lendingId, 8 ether);

        // Loan is in liquidation, mapping populated.
        assertTrue(lending.getLending(lendingId).inLiquidation, "should be in liquidation");
        assertEq(lending.reportIdToLending(reportId), lendingId, "mapping populated by liquidate");

        _settleWithBrokenCallback(reportId);

        // Oracle settled (settlementTimestamp != 0), but openLend is stuck (callback reverted, state rolled back).
        (,,,, uint48 settlementTimestamp,,) = oracle.reportStatus(reportId);
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
        assertEq(loanAfter.feeRecipient, address(0), "feeRecipient cleared");
        assertEq(loanAfter.liquidationStart, 0, "liquidationStart cleared");
        assertEq(lending.reportIdToLending(reportId), 0, "mapping cleared by recover");

        // Stake returned to liquidator (recovery diverges from normal failed-liq policy).
        assertEq(
            supplyToken.balanceOf(liquidator) - liquidatorSupplyBefore,
            tokenStake,
            "stake returned to liquidator"
        );
        assertEq(loanAfter.supplyAmount, SUPPLY_AMOUNT, "supplyAmount unchanged (stake NOT forfeited to borrower)");
        assertTrue(loanAfter.active, "loan still live");
        assertFalse(loanAfter.finished, "loan not finished");
    }

    // -------------------------------------------------------------------------
    // Curve hygiene
    // -------------------------------------------------------------------------

    function testRecover_OpenRefiCurveHasRequestStartReset() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidate(lendingId, 8 ether);

        // Capture settleableAt now (no dispute, so reportTimestamp == liquidationStart).
        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        uint48 settleableAt = reportTs + uint48(ORACLE_SETTLEMENT_TIME);

        // Borrower opens a refi curve mid-liq.
        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, 0);

        // Warp deep into the oracle game so settle/recover lands far past settleableAt.
        vm.warp(block.timestamp + 60 minutes);
        _forceCallbackRevert();
        vm.prank(settler);
        oracle.settle(reportId);
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
        uint256 reportId = _liquidate(lendingId, 8 ether);

        uint48 liqStart = lending.getLending(lendingId).liquidationStart;
        assertGt(liqStart, 0, "liquidationStart populated");

        // Settle inside the near-maturity window so gracePeriod is granted.
        _settleWithBrokenCallback(reportId);

        vm.prank(randomCaller);
        lending.recover(reportId);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        // No dispute, so settleableAt - liqStart = ORACLE_SETTLEMENT_TIME regardless of when settle/recover lands.
        uint256 expectedGrace = 1800 + ORACLE_SETTLEMENT_TIME * 2;
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
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 30 ether, disputer, 8 ether, stateHash);

        address feeRecipient = lending.getLending(lendingId).feeRecipient;
        assertTrue(feeRecipient != address(0), "fee receiver deployed");

        _settleWithBrokenCallback(reportId);

        // Snapshot balances pre-recover.
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);

        vm.prank(randomCaller);
        lending.recover(reportId);

        // Single token1 dispute (oldAmount1 = 10 ether, protocolFee = 100_000 / 1e7 = 1%) → 0.1 ether fee in supply.
        // Split 50/25/25 (borrower / lender / liquidator) via integer division: 0.05 / 0.025 / 0.025.
        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;
        uint256 expectedFee = 10 ether * 100_000 / 1e7;          // 0.1 ether
        uint256 borrowerPiece = expectedFee / 2;                 // 0.05 ether
        uint256 lenderPiece = borrowerPiece / 2;                 // 0.025 ether
        uint256 liquidatorPiece = expectedFee - borrowerPiece - lenderPiece; // 0.025 ether

        assertEq(
            supplyToken.balanceOf(borrower) - borrowerSupplyBefore,
            borrowerPiece,
            "borrower exact supply fee piece"
        );
        assertEq(
            supplyToken.balanceOf(lender) - lenderSupplyBefore,
            lenderPiece,
            "lender exact supply fee piece"
        );
        assertEq(
            supplyToken.balanceOf(liquidator) - liquidatorSupplyBefore,
            tokenStake + liquidatorPiece,
            "liquidator exact stake + supply fee piece"
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
        uint256 firstReportId = _liquidate(lendingId, 12 ether);
        (bytes32 stateHash,,,,,,) = oracle.extraData(firstReportId);

        // Push price even further in borrower's favor so liq fails.
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer);
        oracle.disputeAndSwap(firstReportId, address(supplyToken), 20 ether, 30 ether, disputer, 12 ether, stateHash);

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
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);

        assertEq(lending.reportIdToLending(reportId), lendingId, "mapping populated during liq");

        _settleNormally(reportId);

        assertEq(lending.reportIdToLending(reportId), 0, "mapping cleared by underwater onSettle");
        assertTrue(lending.getLending(lendingId).finished, "loan finished underwater");
    }

    // -------------------------------------------------------------------------
    // Retry story: underwater resolution + failed callback → loan stays live → re-liquidate succeeds
    // -------------------------------------------------------------------------

    /// @dev Pins the explicit retry story documented in `recover`'s natspec: even when the oracle resolved to an
    ///      underwater outcome, recover() commits to the failed-liq treatment unconditionally. The lender is denied
    ///      the underwater payout but the loan remains live, and they can re-liquidate cleanly so long as no
    ///      gracePeriod was granted.
    function testRecover_UnderwaterCallbackFailureRecoverableThenReliquidates() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        // First liquidation: oracle would resolve underwater (single dispute pushes ratio to 20/10 = 2.0,
        // debtInSupplyTerms ~= 140 > supplyAmount 100). But the callback fails.
        uint256 firstReportId = _liquidate(lendingId, 6 ether);
        (bytes32 stateHash,,,,,,) = oracle.extraData(firstReportId);

        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer);
        oracle.disputeAndSwap(firstReportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);

        _settleWithBrokenCallback(firstReportId);

        // Lender is currently denied the underwater payout, but recover keeps the loan live.
        uint256 lenderSupplyBeforeRecover = supplyToken.balanceOf(lender);

        vm.prank(randomCaller);
        lending.recover(firstReportId);

        openLend.LendingArrangement memory loanAfterRecover = lending.getLending(lendingId);
        assertFalse(loanAfterRecover.finished, "loan must NOT be finished - lender denied underwater payout");
        assertFalse(loanAfterRecover.inLiquidation, "inLiquidation cleared");
        assertTrue(loanAfterRecover.active, "loan still active");
        assertEq(loanAfterRecover.gracePeriod, 0, "no gracePeriod (recovered far from maturity)");

        // Lender's supply gain from recovery is exactly their 25% share of the dispute fee, NOT the underwater payout.
        // First-cycle fee = 0.1 ether (1% of 10 ether token1 swap); lender share = 0.025 ether.
        uint256 firstCycleLenderFee = (10 ether * 100_000 / 1e7) / 2 / 2; // 0.025 ether
        assertEq(
            supplyToken.balanceOf(lender) - lenderSupplyBeforeRecover,
            firstCycleLenderFee,
            "lender gain from recovery = fee share only, no underwater payout"
        );

        uint256 lenderSupplyAfterRecover = supplyToken.balanceOf(lender);

        // Re-liquidate. Same lender, same loan. Should succeed because gracePeriod == 0.
        uint256 secondReportId = _liquidate(lendingId, 6 ether);
        assertTrue(secondReportId != firstReportId, "fresh reportId for the retry");
        assertTrue(lending.getLending(lendingId).inLiquidation, "back in liquidation");

        // Run the second cycle to underwater resolution, this time without breaking the callback.
        (bytes32 stateHash2,,,,,,) = oracle.extraData(secondReportId);
        // Read the report's actual reportTimestamp from the oracle to defeat any test-contract block.timestamp hoisting
        // under via_ir. Add disputeDelay+1 from there to satisfy DisputeTooEarly cleanly.
        (,,, uint48 secondReportTimestamp,,,) = oracle.reportStatus(secondReportId);
        vm.warp(uint256(secondReportTimestamp) + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer);
        oracle.disputeAndSwap(secondReportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash2);

        // Read the post-dispute reportTimestamp to set up the settle warp.
        (,,, uint48 secondDisputeTimestamp,,,) = oracle.reportStatus(secondReportId);
        vm.warp(uint256(secondDisputeTimestamp) + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(secondReportId);

        openLend.LendingArrangement memory loanAfterRetry = lending.getLending(lendingId);
        assertTrue(loanAfterRetry.finished, "second cycle finishes the loan underwater");
        assertFalse(loanAfterRetry.inLiquidation, "inLiquidation cleared by successful onSettle");

        // Underwater no-equity branch: lender gets full supplyAmount + their 0.025 ether fee share from the second
        // cycle's dispute. (borrowValueInSupplyTerms ~140 ether > supplyAmount 100 ether → no buffer split.)
        uint256 secondCycleLenderFee = (10 ether * 100_000 / 1e7) / 2 / 2; // 0.025 ether
        assertEq(
            supplyToken.balanceOf(lender) - lenderSupplyAfterRecover,
            uint256(SUPPLY_AMOUNT) + secondCycleLenderFee,
            "lender retry gain = full supply (underwater) + fee share"
        );
        assertEq(lending.reportIdToLending(secondReportId), 0, "second report mapping cleared by onSettle");
    }

    // -------------------------------------------------------------------------
    // Stake-destination policy
    // -------------------------------------------------------------------------

    function testRecover_StakeReturnedToLiquidator() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);

        uint256 reportId = _liquidate(lendingId, 8 ether);
        _settleWithBrokenCallback(reportId);

        uint128 supplyBeforeRecover = lending.getLending(lendingId).supplyAmount;
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;

        vm.prank(randomCaller);
        lending.recover(reportId);

        assertEq(
            lending.getLending(lendingId).supplyAmount,
            supplyBeforeRecover,
            "supplyAmount NOT incremented by stake (vs normal failed liq)"
        );
        assertEq(
            supplyToken.balanceOf(liquidator) - liquidatorSupplyBefore,
            tokenStake,
            "liquidator gets the stake back"
        );
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore,
            "borrower does NOT receive the stake"
        );
    }
}
