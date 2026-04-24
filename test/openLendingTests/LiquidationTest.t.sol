// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";

contract LiquidationTest is OpenLendingBaseTest {
    event LoanLiquidationUnderway(uint256 lendingId, uint256 reportId, address feeRecipient);
    event LiqFinishedWithBuffer(uint256 lendingId);
    event LiqUnsuccessful(uint256 lendingId);

    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal liquidator = address(0x3); // public liquidator (not lender)
    address internal disputer1 = address(0x4);
    address internal disputer2 = address(0x5);
    address internal settler = address(0x6);

    // Unrelated funds to verify no skimming
    uint256 constant UNRELATED_SUPPLY = 500 ether;
    uint256 constant UNRELATED_BORROW = 1000 ether;

    // Loan parameters
    uint128 constant SUPPLY_AMOUNT = 100 ether; // 100 tokens collateral
    uint128 constant BORROW_AMOUNT = 70 ether; // 70 tokens borrowed (70% LTV - close to liquidation)
    uint48 constant LOAN_TERM = 30 days; // 30 day loan
    uint32 constant INTEREST_RATE = 1e8; // 10% annual
    uint24 constant LIQUIDATION_THRESHOLD = 8e6; // 80%
    uint128 constant STAKE = 100; // 1% stake for liquidator

    // Oracle parameters (from liquidate function)
    uint128 constant ORACLE_EXACT_TOKEN1 = SUPPLY_AMOUNT / 10; // 10 ether
    uint256 constant ORACLE_SETTLEMENT_TIME = 300;
    uint256 constant ORACLE_DISPUTE_DELAY = 60;
    uint24 constant ORACLE_PROTOCOL_FEE = 100000; // 1%
    uint16 constant ORACLE_MULTIPLIER = 200; // 2x

    // Liquidation expected params
    uint256 constant EXPECTED_STAKE = SUPPLY_AMOUNT * STAKE / 10000; // 1 ether
    uint128 constant EXPECTED_INITIAL_LIQUIDITY = ORACLE_EXACT_TOKEN1; // 10 ether

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

    // -------------------------------------------------------------------------
    // Helper: Setup a loan ready for liquidation
    // -------------------------------------------------------------------------
    function setupLoanForLiquidation() internal returns (uint256 lendingId) {
        // Borrower requests borrow
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            _standardOracleParams()
        );

        // Lender offers with allowAnyLiquidator = true
        vm.prank(lender);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Borrower accepts
        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);

        return lendingId;
    }

    // -------------------------------------------------------------------------
    // Helper: Calculate total owed at a given time
    // -------------------------------------------------------------------------
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
    // Test 1: Liquidation succeeds with equity remaining
    // Price shows debt > 80% of collateral but < 100%
    // Liquidator and lender split remaining equity 50/50
    // -------------------------------------------------------------------------
    function testLiquidation_SuccessWithEquityRemaining() public {
        uint256 lendingId = setupLoanForLiquidation();

        // Fast forward some time to accrue interest
        vm.warp(block.timestamp + 10 days);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000; // 1% of 100 = 1 ether

        // Track balances before liquidation
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        // Liquidator initiates liquidation
        // oracleAmount2 should represent a price where debt > 80% of collateral
        // Debt is ~70.19 ether borrowToken (70 + ~10 days interest at 10% annual)
        // For liquidation: debt_in_supply_terms > 80 ether (80% of 100)
        // Using oracleAmount2 = 8 ether (10 supply = 8 borrow ratio)
        uint256 oracleAmount2 = 8 ether;
        vm.expectEmit(false, false, false, false, address(lending));
        emit LoanLiquidationUnderway(0, 0, address(0));
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            uint128(oracleAmount2),
            BORROW_AMOUNT,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        // Verify loan is in liquidation
        openLending.LendingView memory loanDuring = lending.getLending(lendingId);
        assertTrue(loanDuring.inLiquidation, "Loan should be in liquidation");
        assertEq(loanDuring.liquidator, liquidator, "Liquidator should be set");
        assertTrue(loanDuring.feeRecipient != address(0), "fee receiver should be created at liquidation");

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        // Dispute 1: generates protocol fee on 10 ether supplyToken (1% = 0.1 ether)
        vm.warp(block.timestamp + 120);
        vm.prank(disputer1);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 12 ether, disputer1, 8 ether, stateHash);

        // Dispute 2: generates protocol fee on 20 ether supplyToken (1% = 0.2 ether)
        // Final ratio: 40/32 = 1.25 supply per borrow
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);
        vm.prank(disputer2);
        oracle.disputeAndSwap(reportId, address(supplyToken), 40 ether, 32 ether, disputer2, 12 ether, stateHash);

        // Settle
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.expectEmit(false, false, false, true, address(lending));
        emit LiqFinishedWithBuffer(lendingId);
        vm.prank(settler);
        oracle.settle(reportId);

        // Verify loan finished
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished after liquidation");

        // Calculate expected collateral distribution
        // Final oracle: 40 supply = 32 borrow => 1.25 supply per borrow
        uint256 debtNow = calculateOwedNow(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM, loanBefore.start);
        uint256 debtInSupplyTerms = (debtNow * 40 ether) / 32 ether;

        // Verify liquidation threshold breached but has equity
        uint256 liqThresh = SUPPLY_AMOUNT * LIQUIDATION_THRESHOLD / 1e7;
        assertTrue(debtInSupplyTerms > liqThresh, "Should have breached liquidation threshold");
        assertTrue(debtInSupplyTerms < SUPPLY_AMOUNT, "Should have equity remaining");

        // Equity split: buffer / 2 to each, liquidator gets remainder for odd amounts
        uint256 buffer = SUPPLY_AMOUNT - debtInSupplyTerms;
        uint256 lenderPiece = buffer / 2;
        uint256 liquidatorPiece = buffer - lenderPiece;

        // Protocol fees from disputes (1% of swapped token amounts)
        // Dispute 1: 1% of 10 ether = 0.1 ether
        // Dispute 2: 1% of 20 ether = 0.2 ether
        // Total: 0.3 ether supplyToken
        uint256 protocolFeeRate = ORACLE_PROTOCOL_FEE;
        uint256 totalSupplyFees = (10 ether * protocolFeeRate / 1e7) + (20 ether * protocolFeeRate / 1e7);

        // Fee distribution: 50% borrower, 25% lender, 25% liquidator
        uint256 borrowerFeeShare = totalSupplyFees / 2;
        uint256 lenderFeeShare = borrowerFeeShare / 2;
        uint256 liquidatorFeeShare = totalSupplyFees - borrowerFeeShare - lenderFeeShare;

        // Expected gains from lending contract (not including oracle gains/losses)
        uint256 expectedLenderCollateralGain = debtInSupplyTerms + lenderPiece;
        // Actual balance changes
        uint256 lenderSupplyGain = supplyToken.balanceOf(lender) - lenderSupplyBefore;
        uint256 borrowerSupplyGain = supplyToken.balanceOf(borrower) - borrowerSupplyBefore;

        // Liquidator's supply token flow:
        // 1. Spent: ORACLE_EXACT_TOKEN1 (10 ether) to oracle + tokenStake (1 ether) to lending = 11 ether
        // 2. Received when disputed: 2 * oldAmount1 + swapFee = 2 * 10 + ~0 = 20 ether
        // 3. Received from lending: liquidatorPiece + tokenStake + liquidatorFeeShare
        uint256 liquidatorSupplyAfter = supplyToken.balanceOf(liquidator);
        uint256 liquidatorSpent = ORACLE_EXACT_TOKEN1 + tokenStake;
        uint256 liquidatorReceivedFromDispute = 2 * ORACLE_EXACT_TOKEN1;
        uint256 liquidatorReceivedFromLending = liquidatorPiece + tokenStake + liquidatorFeeShare;

        // Assert lender got correct collateral share + fee share
        assertEq(lenderSupplyGain, expectedLenderCollateralGain + lenderFeeShare, "Lender supply gain incorrect");

        // Assert borrower got their fee share (50%)
        assertEq(borrowerSupplyGain, borrowerFeeShare, "Borrower fee share incorrect");

        // Assert liquidator net change is correct
        // Net = -spent + receivedFromDispute + receivedFromLending
        int256 liquidatorNetChange = int256(liquidatorSupplyAfter) - int256(liquidatorSupplyBefore);
        int256 expectedLiquidatorNet =
            int256(liquidatorReceivedFromDispute + liquidatorReceivedFromLending) - int256(liquidatorSpent);
        assertEq(liquidatorNetChange, expectedLiquidatorNet, "Liquidator net supply change incorrect");

        // Verify unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply should be untouched");
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow should be untouched");
    }

    // -------------------------------------------------------------------------
    // Test 2: Liquidation succeeds with NO equity remaining (underwater)
    // Debt in supply terms > collateral
    // Lender gets all collateral, liquidator just gets stake back
    // -------------------------------------------------------------------------
    function testLiquidation_SuccessNoEquityRemaining() public {
        uint256 lendingId = setupLoanForLiquidation();

        vm.warp(block.timestamp + 10 days);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;

        // Track all balances before
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        // Set price so debt > 100% of collateral (underwater)
        // Debt ~70.19 borrow. Final ratio 20/10 = 2.0 => debt = 70.19 * 2 = 140.38 supply (underwater)
        uint256 oracleAmount2 = 6 ether;

        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            uint128(oracleAmount2),
            BORROW_AMOUNT,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        // One dispute: generates protocol fee on 10 ether supplyToken (1% = 0.1 ether)
        // Final ratio: 20/10 = 2.0 supply per borrow (underwater)
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);

        vm.prank(disputer1);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 10 ether, disputer1, 6 ether, stateHash);

        // Settle
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        // Verify
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished");

        // Verify underwater: debt in supply terms > collateral
        uint256 debtNow = calculateOwedNow(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM, loanBefore.start);
        uint256 debtInSupplyTerms = (debtNow * 20 ether) / 10 ether;
        assertTrue(debtInSupplyTerms > SUPPLY_AMOUNT, "Should be underwater");

        // Protocol fees from dispute: 1% of 10 ether = 0.1 ether
        uint256 protocolFeeRate = ORACLE_PROTOCOL_FEE;
        uint256 totalSupplyFees = 10 ether * protocolFeeRate / 1e7;

        // Fee distribution: 50% borrower, 25% lender, 25% liquidator
        uint256 borrowerFeeShare = totalSupplyFees / 2;
        uint256 lenderFeeShare = borrowerFeeShare / 2;
        uint256 liquidatorFeeShare = totalSupplyFees - borrowerFeeShare - lenderFeeShare;

        // When underwater: lender gets all collateral, liquidator just gets stake back
        // Plus their respective fee shares

        // Actual balance changes
        uint256 lenderSupplyGain = supplyToken.balanceOf(lender) - lenderSupplyBefore;
        uint256 borrowerSupplyGain = supplyToken.balanceOf(borrower) - borrowerSupplyBefore;
        uint256 liquidatorSupplyAfter = supplyToken.balanceOf(liquidator);

        // Liquidator's supply token flow:
        // 1. Spent: ORACLE_EXACT_TOKEN1 (10 ether) + tokenStake (1 ether) = 11 ether
        // 2. Received when disputed: 2 * 10 + swapFee = 20 ether
        // 3. Received from lending: tokenStake + liquidatorFeeShare
        uint256 liquidatorSpent = ORACLE_EXACT_TOKEN1 + tokenStake;
        uint256 liquidatorReceivedFromDispute = 2 * ORACLE_EXACT_TOKEN1;
        uint256 liquidatorReceivedFromLending = tokenStake + liquidatorFeeShare;

        // Assert lender got all collateral + 25% fee share
        assertEq(lenderSupplyGain, SUPPLY_AMOUNT + lenderFeeShare, "Lender should get all collateral + 25% fee share");

        // Assert borrower got their fee share (50%)
        assertEq(borrowerSupplyGain, borrowerFeeShare, "Borrower fee share incorrect");

        // Assert liquidator net change is correct
        int256 liquidatorNetChange = int256(liquidatorSupplyAfter) - int256(liquidatorSupplyBefore);
        int256 expectedLiquidatorNet =
            int256(liquidatorReceivedFromDispute + liquidatorReceivedFromLending) - int256(liquidatorSpent);
        assertEq(liquidatorNetChange, expectedLiquidatorNet, "Liquidator net supply change incorrect");

        // Unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY);
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW);
    }

    // -------------------------------------------------------------------------
    // Test 3: Liquidation FAILS - price doesn't breach threshold
    // Debt in supply terms < 80% of collateral
    // Borrower keeps loan, gets liquidator's stake as bonus
    // -------------------------------------------------------------------------
    function testLiquidation_FailsPriceDoesntLiquidate() public {
        uint256 lendingId = setupLoanForLiquidation();

        vm.warp(block.timestamp + 10 days);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000; // 1 ether

        // Set price so debt < 80% of collateral (safe)
        // Debt ~70.19 borrow. For debt_in_supply < 80:
        // 70.19 * (10/X) < 80 => X > 8.77
        // Use oracleAmount2 = 12 ether (makes debt = 70.19 * 10/12 = 58.5 supply terms < 80)
        uint256 oracleAmount2 = 12 ether;
        vm.expectEmit(false, false, false, false, address(lending));
        emit LoanLiquidationUnderway(0, 0, address(0));
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            uint128(oracleAmount2),
            BORROW_AMOUNT,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        // Dispute to a price that still doesn't liquidate but is different enough
        // Initial: 10 supply = 12 borrow. New price must be outside fee boundary.
        // Let's make it even more favorable: 20 supply = 30 borrow (lower price in supply terms)
        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);

        vm.prank(disputer1);
        oracle.disputeAndSwap(
            reportId,
            address(supplyToken),
            20 ether,
            30 ether, // More favorable for borrower (20 supply = 30 borrow)
            disputer1,
            12 ether,
            stateHash
        );

        // Settle
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.expectEmit(false, false, false, true, address(lending));
        emit LiqUnsuccessful(lendingId);
        vm.prank(settler);
        oracle.settle(reportId);

        // Verify loan NOT finished - just out of liquidation
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertFalse(loanAfter.finished, "Loan should NOT be finished - liquidation failed");
        assertFalse(loanAfter.inLiquidation, "Should no longer be in liquidation");
        assertTrue(loanAfter.active, "Loan should still be active");

        // Borrower's collateral should have INCREASED by liquidator's stake
        assertEq(loanAfter.supplyAmount, SUPPLY_AMOUNT + tokenStake, "Borrower should gain liquidator stake");

        // Unrelated funds untouched - but contract now holds extra tokenStake added to borrower's collateral
        assertEq(
            supplyToken.balanceOf(address(lending)),
            UNRELATED_SUPPLY + SUPPLY_AMOUNT + tokenStake,
            "Contract should have unrelated + new collateral"
        );
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW);
    }

    // -------------------------------------------------------------------------
    // Test 4: Verify protocol fee distribution from oracle game
    // Tests fees in BOTH supply and borrow tokens
    // -------------------------------------------------------------------------
    function testLiquidation_ProtocolFeeDistribution() public {
        uint256 lendingId = setupLoanForLiquidation();

        vm.warp(block.timestamp + 10 days);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;

        // Track all balances before
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);
        uint256 liquidatorSupplyBefore = supplyToken.balanceOf(liquidator);
        uint256 liquidatorBorrowBefore = borrowToken.balanceOf(liquidator);

        uint256 oracleAmount2 = 8 ether;

        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            uint128(oracleAmount2),
            BORROW_AMOUNT,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        vm.warp(block.timestamp + 120);

        // Dispute 1: swapping supplyToken
        // Generates 1% of 10 ether = 0.1 ether supplyToken fee
        vm.prank(disputer1);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 12 ether, disputer1, 8 ether, stateHash);

        vm.warp(block.timestamp + ORACLE_DISPUTE_DELAY + 1);

        // Dispute 2: swapping borrowToken
        // Generates 1% of 12 ether = 0.12 ether borrowToken fee
        // Final ratio: 40/20 = 2.0 (underwater)
        vm.prank(disputer2);
        oracle.disputeAndSwap(reportId, address(borrowToken), 40 ether, 20 ether, disputer2, 12 ether, stateHash);

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        // Verify loan finished and underwater
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.finished, "Loan should be finished");

        uint256 debtNow = calculateOwedNow(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM, loanBefore.start);
        uint256 debtInSupplyTerms = (debtNow * 40 ether) / 20 ether;
        assertTrue(debtInSupplyTerms > SUPPLY_AMOUNT, "Should be underwater");

        // Calculate exact protocol fees
        uint256 protocolFeeRate = ORACLE_PROTOCOL_FEE;
        uint256 supplyFees = 10 ether * protocolFeeRate / 1e7; // 0.1 ether from dispute 1
        uint256 borrowFees = 12 ether * protocolFeeRate / 1e7; // 0.12 ether from dispute 2

        // Fee distribution: 50% borrower, 25% lender, 25% liquidator
        uint256 borrowerSupplyFeeShare = supplyFees / 2;
        uint256 lenderSupplyFeeShare = borrowerSupplyFeeShare / 2;
        uint256 liquidatorSupplyFeeShare = supplyFees - borrowerSupplyFeeShare - lenderSupplyFeeShare;

        uint256 borrowerBorrowFeeShare = borrowFees / 2;
        uint256 lenderBorrowFeeShare = borrowerBorrowFeeShare / 2;
        uint256 liquidatorBorrowFeeShare = borrowFees - borrowerBorrowFeeShare - lenderBorrowFeeShare;

        // Actual balance changes
        uint256 borrowerSupplyGain = supplyToken.balanceOf(borrower) - borrowerSupplyBefore;
        uint256 borrowerBorrowGain = borrowToken.balanceOf(borrower) - borrowerBorrowBefore;
        uint256 lenderSupplyGain = supplyToken.balanceOf(lender) - lenderSupplyBefore;
        uint256 lenderBorrowGain = borrowToken.balanceOf(lender) - lenderBorrowBefore;

        // Underwater: lender gets all collateral + 25% supply fee share
        assertEq(lenderSupplyGain, SUPPLY_AMOUNT + lenderSupplyFeeShare, "Lender supply gain incorrect");
        assertEq(lenderBorrowGain, lenderBorrowFeeShare, "Lender borrow fee share incorrect");

        // Borrower gets 50% of both fee types
        assertEq(borrowerSupplyGain, borrowerSupplyFeeShare, "Borrower supply fee share incorrect");
        assertEq(borrowerBorrowGain, borrowerBorrowFeeShare, "Borrower borrow fee share incorrect");

        // Liquidator's supply token flow:
        // 1. Spent: 10 ether (oracle) + 1 ether (stake) = 11 ether
        // 2. Received when disputed: 2 * 10 + swapFee = 20 ether
        // 3. From lending: tokenStake + liquidatorSupplyFeeShare
        uint256 liquidatorSupplyAfter = supplyToken.balanceOf(liquidator);
        uint256 liquidatorSpent = ORACLE_EXACT_TOKEN1 + tokenStake;
        uint256 liquidatorReceivedFromDispute = 2 * ORACLE_EXACT_TOKEN1;
        uint256 liquidatorReceivedFromLending = tokenStake + liquidatorSupplyFeeShare;

        int256 liquidatorSupplyNet = int256(liquidatorSupplyAfter) - int256(liquidatorSupplyBefore);
        int256 expectedLiquidatorSupplyNet =
            int256(liquidatorReceivedFromDispute + liquidatorReceivedFromLending) - int256(liquidatorSpent);
        assertEq(liquidatorSupplyNet, expectedLiquidatorSupplyNet, "Liquidator supply net incorrect");

        // Liquidator borrow: only spent oracleAmount2 (8 ether), no borrow token back from oracle when supplyToken swapped
        // Gets liquidatorBorrowFeeShare from lending
        uint256 liquidatorBorrowAfter = borrowToken.balanceOf(liquidator);
        int256 liquidatorBorrowNet = int256(liquidatorBorrowAfter) - int256(liquidatorBorrowBefore);
        int256 expectedLiquidatorBorrowNet = int256(liquidatorBorrowFeeShare) - int256(oracleAmount2);
        assertEq(liquidatorBorrowNet, expectedLiquidatorBorrowNet, "Liquidator borrow net incorrect");

        // Unrelated funds untouched
        assertEq(supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY);
        assertEq(borrowToken.balanceOf(address(lending)), UNRELATED_BORROW);
    }

    // -------------------------------------------------------------------------
    // Test 5: Only lender can liquidate if allowAnyLiquidator is false
    // -------------------------------------------------------------------------
    function testLiquidation_OnlyLenderIfNotPublic() public {
        // Setup loan with allowAnyLiquidator = false
        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            _standardOracleParams()
        );

        // Lender offers with allowAnyLiquidator = FALSE
        vm.prank(lender);
        uint256 offerNumber = lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, false);

        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);

        vm.warp(block.timestamp + 10 days);

        openLending.LendingView memory loan = lending.getLending(lendingId);

        // Non-lender tries to liquidate - should fail
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "wrong liquidator"));
        lending.liquidate{value: 1e15}(
            lendingId, SUPPLY_AMOUNT, 0, 8 ether, BORROW_AMOUNT, loan.start, EXPECTED_STAKE, EXPECTED_INITIAL_LIQUIDITY
        );

        // Lender can liquidate
        vm.prank(lender);
        lending.liquidate{value: 1e15}(
            lendingId, SUPPLY_AMOUNT, 0, 8 ether, BORROW_AMOUNT, loan.start, EXPECTED_STAKE, EXPECTED_INITIAL_LIQUIDITY
        );

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.inLiquidation, "Lender should be able to start liquidation");
        assertEq(loanAfter.liquidator, lender, "Liquidator should be lender");
    }

    // -------------------------------------------------------------------------
    // Test 6: Cannot liquidate expired loan
    // -------------------------------------------------------------------------
    function testLiquidation_CannotLiquidateExpired() public {
        uint256 lendingId = setupLoanForLiquidation();

        // Fast forward past expiration
        vm.warp(block.timestamp + LOAN_TERM + 1);

        openLending.LendingView memory loan = lending.getLending(lendingId);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "arrangement expired"));
        lending.liquidate{value: 1e15}(
            lendingId, SUPPLY_AMOUNT, 0, 8 ether, BORROW_AMOUNT, loan.start, EXPECTED_STAKE, EXPECTED_INITIAL_LIQUIDITY
        );
    }

    // -------------------------------------------------------------------------
    // Test 7: Cannot repay or topup during liquidation
    // -------------------------------------------------------------------------
    function testLiquidation_CannotRepayOrTopupDuringLiquidation() public {
        uint256 lendingId = setupLoanForLiquidation();

        vm.warp(block.timestamp + 10 days);

        openLending.LendingView memory loan = lending.getLending(lendingId);

        // Start liquidation
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId, SUPPLY_AMOUNT, 0, 8 ether, BORROW_AMOUNT, loan.start, EXPECTED_STAKE, EXPECTED_INITIAL_LIQUIDITY
        );

        // Try to repay - should fail
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "in liquidation"));
        lending.repayDebt(lendingId, 10 ether);

        // Try to topup - should fail
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "in liquidation"));
        lending.topUpCollateral(lendingId, 10 ether);
    }

    // -------------------------------------------------------------------------
    // Test 8: Grace period after failed liquidation near maturity
    // -------------------------------------------------------------------------
    function testLiquidation_GracePeriodAfterFailedLiquidationNearMaturity() public {
        uint256 lendingId = setupLoanForLiquidation();

        // Fast forward to near maturity (within 5 minutes)
        vm.warp(block.timestamp + LOAN_TERM - 200);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        // Liquidate with price that won't liquidate
        uint256 oracleAmount2 = 12 ether; // Safe price

        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            uint128(oracleAmount2),
            BORROW_AMOUNT,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;

        // Wait and settle (no disputes, just settle at safe price)
        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        // Check grace period was set
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertFalse(loanAfter.finished, "Loan should not be finished");
        assertGt(loanAfter.gracePeriod, 0, "Grace period should be set for near-maturity liquidation failure");

        // Borrower should now be able to repay even past original maturity
        vm.warp(block.timestamp + 100); // Past original maturity but within grace

        uint256 totalOwed = calculateOwedNow(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM, loanBefore.start);

        // This should succeed due to grace period
        vm.prank(borrower);
        lending.repayDebt(lendingId, uint128(totalOwed + 1 ether)); // Pay a bit extra to cover full debt

        openLending.LendingView memory loanFinal = lending.getLending(lendingId);
        assertTrue(loanFinal.finished, "Borrower should be able to repay during grace period");
    }

    // -------------------------------------------------------------------------
    // Test: Liquidation runs PAST maturity - grace period = 300 + 2x duration
    // -------------------------------------------------------------------------
    function testGracePeriod_LiquidationRunsPastMaturity() public {
        uint256 lendingId = setupLoanForLiquidation();

        // Fast forward to 1 day before maturity
        vm.warp(block.timestamp + LOAN_TERM - 1 days);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        // Start liquidation with safe price (won't liquidate)
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether, // Safe price
            BORROW_AMOUNT,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        // Get the liquidationStart that the contract stored
        openLending.LendingView memory loanDuring = lending.getLending(lendingId);
        uint256 liquidationStartTimestamp = loanDuring.liquidationStart;

        uint256 reportId = oracle.nextReportId() - 1;

        // Warp PAST maturity before settling (maturity is in 1 day, we wait 2 days)
        vm.warp(block.timestamp + 2 days);

        // Record the exact timestamp when settlement/callback happens
        uint256 settlementTimestamp = block.timestamp;

        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);

        assertFalse(loanAfter.finished, "Loan should not be finished");
        assertFalse(loanAfter.inLiquidation, "Should not be in liquidation");

        // Verify exact grace period calculation matches contract formula:
        // gracePeriod = 300 + (block.timestamp - liquidationStart) * 2
        uint256 liquidationDuration = settlementTimestamp - liquidationStartTimestamp;
        uint256 expectedGracePeriod = 300 + liquidationDuration * 2;

        // Sanity check our inputs
        assertEq(liquidationDuration, 2 days, "Liquidation should have run for 2 days");
        assertEq(expectedGracePeriod, 300 + 172800 * 2, "Expected grace = 300 + 2*172800 = 345900");

        // The actual assertion
        assertEq(loanAfter.gracePeriod, expectedGracePeriod, "Grace period must equal 300 + 2x liquidation duration");
    }

    // -------------------------------------------------------------------------
    // Test: Lender CANNOT claim during grace period
    // -------------------------------------------------------------------------
    function testGracePeriod_LenderCannotClaimDuringGrace() public {
        uint256 lendingId = setupLoanForLiquidation();

        // Fast forward to near maturity
        vm.warp(block.timestamp + LOAN_TERM - 200);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        // Failed liquidation grants grace period
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether, // Safe price
            BORROW_AMOUNT,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        // Grace period should be set
        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertGt(loanAfter.gracePeriod, 0, "Grace period should be set");

        // Warp to past original maturity but within grace
        vm.warp(loanAfter.start + loanAfter.term + 100);

        // Lender tries to claim - should fail
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "not expired"));
        lending.claimCollateral(lendingId);
    }

    // -------------------------------------------------------------------------
    // Test: After grace period expires, lender CAN claim
    // -------------------------------------------------------------------------
    function testGracePeriod_LenderCanClaimAfterGraceExpires() public {
        uint256 lendingId = setupLoanForLiquidation();

        // Fast forward to near maturity
        vm.warp(block.timestamp + LOAN_TERM - 200);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        // Failed liquidation grants grace period
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether, // Safe price
            BORROW_AMOUNT,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);
        assertGt(loanAfter.gracePeriod, 0, "Grace period should be set");

        // Warp to AFTER grace period expires
        vm.warp(loanAfter.start + loanAfter.term + loanAfter.gracePeriod + 1);

        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);

        // Lender claims - should succeed
        vm.prank(lender);
        lending.claimCollateral(lendingId);

        // Lender should get the collateral (supplyAmount increased by liquidator stake)
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBefore + SUPPLY_AMOUNT + tokenStake,
            "Lender should receive collateral after grace expires"
        );
    }

    // -------------------------------------------------------------------------
    // Test: Borrower can repay during grace period (past original maturity)
    // -------------------------------------------------------------------------
    function testGracePeriod_BorrowerCanRepayDuringGrace() public {
        uint256 lendingId = setupLoanForLiquidation();

        // Fast forward to near maturity
        vm.warp(block.timestamp + LOAN_TERM - 200);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        // Failed liquidation grants grace period
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether, // Safe price
            BORROW_AMOUNT,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);

        // Warp to past original maturity but within grace
        uint256 timeInGrace = loanAfter.start + loanAfter.term + (loanAfter.gracePeriod / 2);
        vm.warp(timeInGrace);

        // Borrower repays
        uint256 totalOwed = calculateOwedNow(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM, loanAfter.start);

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;

        vm.prank(borrower);
        lending.repayDebt(lendingId, uint128(totalOwed + 1e18));

        // Borrower gets their collateral back (original + liquidator stake since liquidation failed)
        openLending.LendingView memory loanFinal = lending.getLending(lendingId);
        assertTrue(loanFinal.finished, "Loan should be finished after repay");
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT + tokenStake,
            "Borrower should get collateral + liquidator stake back"
        );
    }

    // -------------------------------------------------------------------------
    // Test: Cannot start new liquidation past maturity but within grace
    // -------------------------------------------------------------------------
    function testGracePeriod_CannotLiquidateDuringGrace() public {
        uint256 lendingId = setupLoanForLiquidation();

        // Fast forward to near maturity
        vm.warp(block.timestamp + LOAN_TERM - 200);

        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        // Failed liquidation grants grace period
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            SUPPLY_AMOUNT,
            0,
            12 ether, // Safe price
            BORROW_AMOUNT,
            loanBefore.start,
            EXPECTED_STAKE,
            EXPECTED_INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;

        vm.warp(block.timestamp + ORACLE_SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory loanAfter = lending.getLending(lendingId);

        // Warp to past original maturity but within grace
        vm.warp(loanAfter.start + loanAfter.term + 100);

        // After failed liquidation, supplyAmount increased by liquidator's stake
        uint256 tokenStake = SUPPLY_AMOUNT * STAKE / 10000;
        uint256 newSupplyAmount = SUPPLY_AMOUNT + tokenStake;

        // Expected params based on new supply amount
        uint256 newExpectedStake = newSupplyAmount * STAKE / 10000;
        uint256 newExpectedInitialLiquidity = newSupplyAmount / 10;

        // Try to liquidate again - should fail because past maturity
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "arrangement expired"));
        lending.liquidate{value: 1e15}(
            lendingId,
            uint128(newSupplyAmount), // Updated supply amount after failed liquidation
            0,
            8 ether,
            BORROW_AMOUNT,
            loanAfter.start,
            newExpectedStake,
            uint128(newExpectedInitialLiquidity)
        );
    }
}
