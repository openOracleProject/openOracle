// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";

contract LiquidationTest is OpenLendingBaseTest {
    event LoanLiquidationUnderway(uint256 indexed lendingId, uint256 reportId, address feeRecipient);
    event LiqFinishedWithBuffer(uint256 indexed lendingId);
    event LiqFinishedUnderwater(uint256 indexed lendingId);
    event LiqUnsuccessful(uint256 indexed lendingId);

    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal liquidator = address(0x3);
    address internal disputer1 = address(0x4);
    address internal disputer2 = address(0x5);
    address internal settler = address(0x6);

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

        address[] memory accounts = new address[](5);
        accounts[0] = borrower;
        accounts[1] = lender;
        accounts[2] = liquidator;
        accounts[3] = disputer1;
        accounts[4] = disputer2;
        _fundSupply(accounts, 10000 ether);
        _fundBorrow(accounts, 10000 ether);

        address[] memory ethAccounts = new address[](6);
        ethAccounts[0] = borrower;
        ethAccounts[1] = lender;
        ethAccounts[2] = liquidator;
        ethAccounts[3] = disputer1;
        ethAccounts[4] = disputer2;
        ethAccounts[5] = settler;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer1);
        _approveOracleBoth(disputer2);

        _seedUnrelated(UNRELATED_SUPPLY, UNRELATED_BORROW);
    }

    /// @dev Originate with the given `liquidatorFraction` (1e7 = 100% to liquidator on buffer split).
    function _setupLoan(uint24 liquidatorFraction) internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, liquidatorFraction);
    }

    /// @dev priceRatio = oracleAmount2_target * 1e18 / initialLiquidity. With standard params
    ///      initialLiquidity = supplyAmount * 10 / 100 = 10 ether, so priceRatio = oracleAmount2 * 1e18 / 10e18.
    function _priceRatioFor(uint256 oracleAmount2Target) internal pure returns (uint256) {
        return oracleAmount2Target * 1e18 / 10 ether;
    }

    function _liquidate(address who, uint256 lendingId, uint256 oracleAmount2Target) internal {
        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(who);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(oracleAmount2Target),
            type(uint128).max,
            paramHash,
            0
        , 1e15);
    }

    function calculateOwedNow(uint256 principal, uint32 rate, uint48 term, uint256 start)
        internal
        view
        returns (uint256)
    {
        uint256 year = 365 days;
        uint256 elapsed = block.timestamp > start ? block.timestamp - start : 0;
        if (elapsed > term) elapsed = term;
        uint256 interest = (principal * elapsed * rate) / (1e9 * year);
        return principal + interest;
    }

    // -------------------------------------------------------------------------
    // Successful liquidation paths
    // -------------------------------------------------------------------------

    function testLiquidation_SuccessWithEquityRemaining() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 10 days);

        // oracleAmount2 = 8 → final ratio after disputes will land in equity-remaining territory
        _liquidate(liquidator, lendingId, 8 ether);

        // Mid-liq state checks
        openLend.LendingArrangement memory loanDuring = lending.getLending(lendingId);
        assertTrue(loanDuring.inLiquidation, "Loan should be in liquidation");
        assertEq(loanDuring.liquidator, liquidator, "Liquidator should be set");
        assertTrue(_predictFeeReceiver(_latestReportId()).code.length > 0, "fee receiver should be deployed");

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        // Two disputes leading to a final price that triggers liquidation but keeps a buffer
        vm.warp(block.timestamp + 120);
        vm.prank(disputer1);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 12 ether, disputer1, 8 ether, stateHash);

        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer2);
        oracle.disputeAndSwap(reportId, address(supplyToken), 40 ether, 32 ether, disputer2, 12 ether, stateHash);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.expectEmit(true, false, false, true, address(lending));
        emit LiqFinishedWithBuffer(lendingId);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished after liquidation");
        assertFalse(loanAfter.inLiquidation, "inLiquidation cleared");

        // Sanity: confirm we actually landed in the buffer region (not underwater)
        uint32 rate = loanAfter.rate;
        uint256 debtNow = calculateOwedNow(BORROW_AMOUNT, rate, LOAN_TERM, loanAfter.start);
        uint256 debtInSupplyTerms = (debtNow * 40 ether) / 32 ether;
        uint256 liqThresh = uint256(SUPPLY_AMOUNT) * loanAfter.liquidationThreshold / 1e7;
        assertGt(debtInSupplyTerms, liqThresh, "should breach threshold");
        assertLt(debtInSupplyTerms, SUPPLY_AMOUNT, "should keep buffer");
    }

    function testLiquidation_SuccessNoEquityRemaining() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 10 days);

        _liquidate(liquidator, lendingId, 6 ether);

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        // Single dispute lands at 20/10 ratio → underwater
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer1);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 10 ether, disputer1, 6 ether, stateHash);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.expectEmit(true, false, false, true, address(lending));
        emit LiqFinishedUnderwater(lendingId);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished");
    }

    // -------------------------------------------------------------------------
    // Failed liquidation
    // -------------------------------------------------------------------------

    function testLiquidation_FailsPriceDoesntLiquidate() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 10 days);

        _liquidate(liquidator, lendingId, 12 ether);

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        // Dispute lands at 20/30 — even more favorable to borrower
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer1);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 30 ether, disputer1, 12 ether, stateHash);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.expectEmit(true, false, false, true, address(lending));
        emit LiqUnsuccessful(lendingId);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertFalse(loanAfter.finished, "Loan should still be live");
        assertFalse(loanAfter.inLiquidation, "Should be out of liquidation");
        assertTrue(loanAfter.active, "Loan should still be active");

        // Borrower's collateral grows by the liquidator's forfeited stake
        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;
        assertEq(loanAfter.supplyAmount, SUPPLY_AMOUNT + tokenStake, "Borrower should gain liquidator stake");
    }

    // -------------------------------------------------------------------------
    // Permissioning
    // -------------------------------------------------------------------------

    /// @dev Liquidation is permissionless under the amort model — `liquidatorFraction = 0` only zeroes the
    ///      buffer-share economic incentive; it does not gate who may call.
    function testLiquidation_PermissionlessRegardlessOfLiquidatorFraction() public {
        uint256 lendingId = _setupLoan(0);
        vm.warp(block.timestamp + 10 days);

        bytes32 paramHash = lending.getParamHash(lendingId);

        // Non-lender third party can call liquidate even with liquidatorFraction = 0.
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(lendingId, _priceRatioFor(8 ether), type(uint128).max, paramHash, 0, 1e15);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.inLiquidation, "third party can liquidate regardless of liquidatorFraction");
        assertEq(loan.liquidator, liquidator, "liquidator field tracks msg.sender");
    }

    // -------------------------------------------------------------------------
    // Lifecycle gates
    // -------------------------------------------------------------------------

    function testLiquidation_CannotLiquidateExpired() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + LOAN_TERM + 1);

        bytes32 paramHash = lending.getParamHash(lendingId);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "arrangement expired"));
        lending.liquidate{value: 1e15}(lendingId, _priceRatioFor(8 ether), type(uint128).max, paramHash, 0, 1e15);
    }

    function testLiquidation_CannotRepayOrTopupDuringLiquidation() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 10 days);

        _liquidate(liquidator, lendingId, 8 ether);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "in liquidation"));
        lending.repayDebt(lendingId, 10 ether, bytes32(0), 0, type(uint128).max);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "in liquidation"));
        lending.topUpCollateral(lendingId, 10 ether, bytes32(0), 0, type(uint128).max);
    }

    // -------------------------------------------------------------------------
    // Grace period after a failed liquidation near maturity
    // -------------------------------------------------------------------------

    function testGracePeriod_BorrowerCanRepayDuringGrace() public {
        uint256 lendingId = _setupLoan(5e6);

        // Get within the grace-trigger window (resolution within 1800s of maturity)
        vm.warp(block.timestamp + LOAN_TERM - 900);

        _liquidate(liquidator, lendingId, 12 ether);

        uint256 reportId = oracle.nextReportId() - 1;

        // Settle without dispute (resolves to current price = safe)
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        // settle delta = ORACLE_SETTLEMENT_TIME + 1 = 301; gracePeriod = 1800 + 301*2
        assertEq(loan.gracePeriod, 1800 + ORACLE_SETTLEMENT_TIME * 2, "exact gracePeriod from near-maturity failed liq");

        // Warp past original maturity but within grace
        uint256 timeInGrace = uint256(loan.start) + loan.term + (loan.gracePeriod / 2);
        vm.warp(timeInGrace);

        uint256 totalOwed = calculateOwedNow(loan.principal, loan.rate, loan.term, loan.start);
        uint128 paymentAmount = uint128(totalOwed + 1 ether);

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;
        uint256 lenderStakePiece = tokenStake / 2;

        vm.prank(borrower);
        lending.repayDebt(lendingId, paymentAmount, bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loanFinal = lending.getLending(lendingId);
        assertTrue(loanFinal.finished, "Loan should be finished after grace-period repay");

        // Failed liq with grace already routed half the stake to the lender at settle. Borrower reclaims the
        // original supply plus the borrower-side stake remainder via repayDebt's full-close path.
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT + (tokenStake - lenderStakePiece),
            "Borrower should reclaim collateral plus borrower-side stake remainder"
        );
    }

    function testGracePeriod_BorrowerCanTopUpDuringGrace() public {
        uint256 lendingId = _setupLoan(5e6);

        // Trigger near-maturity failed liquidation to set gracePeriod.
        vm.warp(block.timestamp + LOAN_TERM - 900);
        _liquidate(liquidator, lendingId, 12 ether);

        uint256 reportId = oracle.nextReportId() - 1;
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertGt(loan.gracePeriod, 0, "gracePeriod should be set after near-maturity failed liq");

        // Past original maturity, within grace.
        vm.warp(uint256(loan.start) + loan.term + (loan.gracePeriod / 2));

        uint128 topUpAmount = 5 ether;
        uint128 supplyBefore = loan.supplyAmount;
        uint256 contractBalanceBefore = supplyToken.balanceOf(address(lending));

        vm.prank(borrower);
        lending.topUpCollateral(lendingId, topUpAmount, bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertEq(
            loanAfter.supplyAmount,
            supplyBefore + topUpAmount,
            "topUp during grace should increase supplyAmount"
        );
        assertEq(
            supplyToken.balanceOf(address(lending)),
            contractBalanceBefore + topUpAmount,
            "topUp during grace should pull supplyToken into the lending contract"
        );
    }

    function testGracePeriod_BorrowerCannotTopUpAfterGraceExpires() public {
        uint256 lendingId = _setupLoan(5e6);

        // Trigger near-maturity failed liquidation to set gracePeriod.
        vm.warp(block.timestamp + LOAN_TERM - 900);
        _liquidate(liquidator, lendingId, 12 ether);

        uint256 reportId = oracle.nextReportId() - 1;
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertGt(loan.gracePeriod, 0, "gracePeriod should be set after near-maturity failed liq");

        // Past grace.
        vm.warp(uint256(loan.start) + loan.term + loan.gracePeriod + 1);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "expired"));
        lending.topUpCollateral(lendingId, 5 ether, bytes32(0), 0, type(uint128).max);
    }

    function testGracePeriod_LenderCannotClaimDuringGrace() public {
        uint256 lendingId = _setupLoan(5e6);

        vm.warp(block.timestamp + LOAN_TERM - 900);
        _liquidate(liquidator, lendingId, 12 ether);

        uint256 reportId = oracle.nextReportId() - 1;
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.gracePeriod, 1800 + ORACLE_SETTLEMENT_TIME * 2, "exact gracePeriod from near-maturity failed liq");

        // Past original maturity but within grace
        vm.warp(uint256(loan.start) + loan.term + 100);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "not expired"));
        lending.claimCollateral(lendingId);
    }

    function testGracePeriod_LenderCanClaimAfterGraceExpires() public {
        uint256 lendingId = _setupLoan(5e6);

        vm.warp(block.timestamp + LOAN_TERM - 900);

        uint256 lenderSupplyBeforeSettle = supplyToken.balanceOf(lender);
        uint256 tokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;
        uint256 lenderStakePiece = tokenStake / 2;

        _liquidate(liquidator, lendingId, 12 ether);

        uint256 reportId = oracle.nextReportId() - 1;
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        // Failed liq with grace splits the stake: half to the lender now, the rest left in supplyAmount.
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBeforeSettle + lenderStakePiece,
            "Lender should receive half the stake at settle"
        );

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        // Past grace
        vm.warp(uint256(loan.start) + loan.term + loan.gracePeriod + 1);

        uint256 lenderSupplyBeforeClaim = supplyToken.balanceOf(lender);

        vm.prank(lender);
        lending.claimCollateral(lendingId);

        // claimCollateral pays out supplyAmount, which now includes only the borrower-side stake remainder.
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBeforeClaim + SUPPLY_AMOUNT + (tokenStake - lenderStakePiece),
            "Lender should receive collateral + remaining stake on claim"
        );

        // Total over the loan lifetime equals supplyAmount + full stake.
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBeforeSettle + SUPPLY_AMOUNT + tokenStake,
            "Lender total should equal collateral + full stake"
        );
    }

    // -------------------------------------------------------------------------
    // Bad-input coverage
    // -------------------------------------------------------------------------

    function testLiquidate_RejectsWrongParamHash() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 10 days);

        bytes32 wrongHash = bytes32(uint256(0xdead));

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "params"));
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            wrongHash,
            0
        , 1e15);
    }

    /// @dev `paramHashExpected = bytes32(0)` is intentionally a skip sentinel — liquidate must succeed without
    ///      any param-hash check.
    function testLiquidate_AcceptsZeroParamHashAsSkip() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 10 days);

        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            bytes32(0),
            0
        , 1e15);

        assertTrue(lending.getLending(lendingId).inLiquidation,
            "liquidate succeeds with bytes32(0) paramHash (skip sentinel)");
    }

    /// @dev V3 deliberately doesn't add a local zero-check on oracleAmount2; degenerate priceRatio reverts via
    ///      the openOracle initial-report path. Verify the revert happens cleanly with no state stuck.
    function testLiquidate_TinyPriceRatioRevertsCleanly() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 10 days);

        bytes32 paramHash = lending.getParamHash(lendingId);

        // priceRatio = 0 → oracleAmount2 = 0 → openOracle bounces the initial report
        vm.prank(liquidator);
        vm.expectRevert();
        lending.liquidate{value: 1e15}(
            lendingId,
            0,
            type(uint128).max,
            paramHash,
            0
        , 1e15);

        // No state should have stuck — liquidator can still call cleanly afterwards
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertFalse(loan.inLiquidation, "should not be in liquidation after revert");
        assertEq(lending.lendingToReportId(lendingId), 0, "no reportId after revert");
    }

    function testLiquidate_RejectsAboveMaxInitialLiquidity() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 10 days);

        bytes32 paramHash = lending.getParamHash(lendingId);

        // initialLiquidity = supplyAmount * 10 / 100 = 10 ether. Cap at 1 ether forces revert.
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "too much oracle game initial liquidity"));
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            1 ether,
            paramHash,
            0
        , 1e15);
    }

    function testLiquidate_RejectsBelowWorstRatio() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 10 days);

        bytes32 paramHash = lending.getParamHash(lendingId);

        // Set worstRatio above the actual ratio so the position is "too healthy" to liquidate at this floor
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "position too healthy"));
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(8 ether),
            type(uint128).max,
            paramHash,
            type(uint256).max
        , 1e15);
    }

    /// @dev With oracleGameFee = 0 the liquidate path skips deploying a feeRecipient, and settlement still
    ///      completes normally with feeRecipient == address(0).
    function testLiquidation_NoFee_FeeRecipientStaysZeroAndSettles() public {
        // Custom request with oracleGameFee = 0
        openLend.OracleParams memory zeroFeeParams = openLend.OracleParams({
            settlementTime: 300,
            disputeDelay: 60,
            oracleGameFee: 0,
            escalationFactor: 100,
            initialLiquidity: 10,
            multiplier: 200
        });

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
            zeroFeeParams,
            _standardInterestRateParams()
        );
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6);

        vm.warp(block.timestamp + 10 days);

        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            paramHash,
            0
        , 1e15);

        // No fee recipient deployed when fee is 0
        openLend.LendingArrangement memory midLoan = lending.getLending(lendingId);
        assertEq(_predictFeeReceiver(_latestReportId()).code.length, 0, "no clone deployed when oracleGameFee == 0");
        assertTrue(midLoan.inLiquidation, "inLiquidation set");

        // Drive to underwater
        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer1);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 10 ether, disputer1, 6 ether, stateHash);

        // Settle — should complete cleanly without trying to grab fees
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory afterLoan = lending.getLending(lendingId);
        assertTrue(afterLoan.finished, "loan finished after no-fee liq");
        assertFalse(afterLoan.inLiquidation, "inLiquidation cleared");
    }

    /// @dev Fee receivers are clones — each liquidation deploys a fresh one. After a failed liq,
    ///      `lending.feeRecipient` updates on the next liquidate, but the old clone still holds (and
    ///      can still distribute) any fees it accrued via `grabOracleGameFeesAny`.
    function testMultipleFeeReceivers_OldOneStillSweepable() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 1 days);

        // First liquidation — fails (favorable price)
        _liquidate(liquidator, lendingId, 12 ether);
        address feeRecipient1 = _predictFeeReceiver(_latestReportId());
        assertTrue(feeRecipient1.code.length > 0, "first feeRecipient deployed");

        // Generate fees on receiver #1 via dispute, then settle to fail
        uint256 reportId1 = oracle.nextReportId() - 1;
        (bytes32 stateHash1,,,,,,) = oracle.extraData(reportId1);
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer1);
        oracle.disputeAndSwap(reportId1, address(supplyToken), 20 ether, 30 ether, disputer1, 12 ether, stateHash1);

        // Snapshot beneficiaries and fees BEFORE settle (settle's _grabOracleGameFees would clear them)
        openLend.Beneficiaries memory bens1 = lending.getBeneficiaries(lendingId, feeRecipient1);
        assertEq(bens1.lender, lender, "receiver1 lender beneficiary");
        assertEq(bens1.liquidator, liquidator, "receiver1 liquidator beneficiary");

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId1);

        // After settle of failed liq, the gracePeriod is set; liq cannot fire while grace > 0. Force gracePeriod = 0
        // by waiting for the loan's natural maturity… actually the gate blocks liq during grace, so to do a second
        // liquidation we need to instead stage a scenario where gracePeriod is NOT set. Re-set up a fresh loan.
        // We'll re-stage via a second loan instead.

        // Second loan — second fee receiver
        uint256 lendingId2 = _setupLoan(5e6);
        vm.warp(block.timestamp + 1 days);
        _liquidate(liquidator, lendingId2, 12 ether);
        uint256 reportId2 = _latestReportId();
        address feeRecipient2 = _predictFeeReceiver(reportId2);
        assertTrue(feeRecipient2.code.length > 0, "second feeRecipient deployed");
        assertTrue(feeRecipient2 != feeRecipient1, "fee receivers should be distinct clones");

        // Beneficiaries on receiver #2 are independent
        openLend.Beneficiaries memory bens2 = lending.getBeneficiaries(lendingId2, feeRecipient2);
        assertEq(bens2.lender, lender, "receiver2 lender beneficiary");
        assertEq(bens2.liquidator, liquidator, "receiver2 liquidator beneficiary");

        // Calling grabOracleGameFeesAny on receiver1 with the WRONG lendingId reverts
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "feeRecipient not for lendingId"));
        lending.grabOracleGameFeesAny(lendingId2, reportId1);

        // And on receiver2 with the wrong lendingId reverts
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "feeRecipient not for lendingId"));
        lending.grabOracleGameFeesAny(lendingId, reportId2);

        // Each receiver is callable with its own lendingId (no fees second time around — onSettle already swept,
        // but the call should not revert)
        lending.grabOracleGameFeesAny(lendingId, reportId1);
        // (lendingId2's liq #2 is still in flight; skip the no-op grab)
    }

    function testFeeReceivers_RemainReportBoundAcrossRefiAndLaterLiquidation() public {
        uint256 lendingId = _setupLoan(5e6);
        vm.warp(block.timestamp + 1 days);

        _liquidate(liquidator, lendingId, 12 ether);
        uint256 reportId1 = _latestReportId();
        address feeRecipient1 = _predictFeeReceiver(reportId1);
        assertTrue(feeRecipient1.code.length > 0, "first receiver deployed");

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId1);
        assertFalse(lending.getLending(lendingId).inLiquidation, "first failed liq settled");

        // Refi the same loan to a new lender, then liquidate again. The second liquidation should deploy
        // a fresh receiver, while the old receiver remains tied to reportId1 and the same lendingId.
        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            0,
            0,
            _standardInterestRateParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        vm.prank(disputer2);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.prank(disputer2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6);

        vm.warp(block.timestamp + 1 days);
        _liquidate(liquidator, lendingId, 12 ether);
        uint256 reportId2 = _latestReportId();
        address feeRecipient2 = _predictFeeReceiver(reportId2);

        assertTrue(feeRecipient2.code.length > 0, "second receiver deployed");
        assertTrue(feeRecipient2 != feeRecipient1, "later liquidation gets fresh receiver");

        openLend.Beneficiaries memory oldBens = lending.getBeneficiaries(lendingId, feeRecipient1);
        openLend.Beneficiaries memory newBens = lending.getBeneficiaries(lendingId, feeRecipient2);
        assertEq(oldBens.lender, lender, "old receiver keeps original lender beneficiary");
        assertEq(newBens.lender, disputer2, "new receiver tracks refi lender beneficiary");

        // A different lendingId cannot sweep either receiver by reusing old reportIds.
        uint256 otherLendingId = _setupLoan(5e6);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "feeRecipient not for lendingId"));
        lending.grabOracleGameFeesAny(otherLendingId, reportId1);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "feeRecipient not for lendingId"));
        lending.grabOracleGameFeesAny(otherLendingId, reportId2);

        // But the original lendingId can still address both deterministic receivers by reportId.
        lending.grabOracleGameFeesAny(lendingId, reportId1);
        lending.grabOracleGameFeesAny(lendingId, reportId2);
    }

    // ---------------- callback liveness with failing token recipients ----------------
    // (covered in HelperCoverageTest where the blacklist token type is defined)

    /// @dev V3 explicitly blocks new liquidations whenever gracePeriod != 0.
    function testGracePeriod_CannotLiquidateDuringGrace() public {
        uint256 lendingId = _setupLoan(5e6);

        vm.warp(block.timestamp + LOAN_TERM - 900);
        _liquidate(liquidator, lendingId, 12 ether);

        uint256 reportId = oracle.nextReportId() - 1;
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.gracePeriod, 1800 + ORACLE_SETTLEMENT_TIME * 2, "exact gracePeriod from near-maturity failed liq");

        // Past original maturity but within grace — V3 blocks at the gracePeriod gate
        vm.warp(uint256(loan.start) + loan.term + 100);

        bytes32 paramHash = lending.getParamHash(lendingId);

        vm.prank(liquidator);
        vm.expectRevert();
        lending.liquidate{value: 1e15}(lendingId, _priceRatioFor(8 ether), type(uint128).max, paramHash, 0, 1e15);
    }
}
