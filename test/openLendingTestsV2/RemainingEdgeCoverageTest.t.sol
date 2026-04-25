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
    uint32 internal constant INTEREST_RATE = 1e8;
    uint24 internal constant LIQUIDATION_THRESHOLD = 8e6;
    uint128 internal constant STAKE = 100;
    uint128 internal constant INITIAL_LIQUIDITY = SUPPLY_AMOUNT / 10;

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

    function testOnSettle_RevertsForNonOracleCaller() public {
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "invalid sender"));
        lending.onSettle(999, 0, 0, address(supplyToken), address(borrowToken));
    }

    function testOnSettle_RevertsForUnknownReportIdEvenFromOracle() public {
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "no lendingId for reportId"));
        lending.onSettle(999, 0, 0, address(supplyToken), address(borrowToken));
    }

    function testOfferBorrow_AtExactOfferExpiration_Succeeds() public {
        uint48 offerExpiration = uint48(block.timestamp + 1 hours);

        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            LOAN_TERM,
            offerExpiration,
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            _standardOracleParams()
        );

        vm.warp(offerExpiration);

        vm.prank(lender);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, false);

        openLending.LendingOffer memory offer = lending.getLendingOffer(lendingId);
        assertEq(offer.amount, BORROW_AMOUNT, "offer should be accepted exactly at expiration");
    }

    function testRepayDebt_AtExactExpiry_Reverts() public {
        uint256 lendingId = _setupActiveLoan(false);
        openLending.LendingView memory loan = lending.getLending(lendingId);

        vm.warp(loan.start + loan.term + loan.gracePeriod);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "expired"));
        lending.repayDebt(lendingId, 1 ether);
    }

    function testLiquidate_AtExactTerm_Succeeds() public {
        uint256 lendingId = _setupActiveLoan(true);
        openLending.LendingView memory loan = lending.getLending(lendingId);

        vm.warp(loan.start + loan.term);

        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            uint128(loan.supplyAmount),
            uint128(loan.repaidDebt),
            8 ether,
            uint128(loan.borrowAmount),
            loan.start,
            loan.supplyAmount * STAKE / 10000,
            INITIAL_LIQUIDITY
        );

        assertTrue(lending.getLending(lendingId).inLiquidation, "exact-term liquidation should succeed");
    }

    function testClaimCollateral_AtExactGraceBoundary_Succeeds() public {
        uint256 lendingId = _setupActiveLoan(true);
        openLending.LendingView memory loan = lending.getLending(lendingId);

        vm.warp(loan.start + loan.term - 100);

        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            uint128(loan.supplyAmount),
            uint128(loan.repaidDebt),
            20 ether,
            uint128(loan.borrowAmount),
            loan.start,
            loan.supplyAmount * STAKE / 10000,
            INITIAL_LIQUIDITY
        );

        uint256 reportId = oracle.nextReportId() - 1;
        vm.warp(block.timestamp + 301);
        vm.prank(settler);
        oracle.settle(reportId);

        openLending.LendingView memory afterFailedLiquidation = lending.getLending(lendingId);
        assertGt(afterFailedLiquidation.gracePeriod, 0, "failed late liquidation should create grace period");

        vm.warp(loan.start + loan.term + afterFailedLiquidation.gracePeriod);

        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        lending.claimCollateral(lendingId);

        openLending.LendingView memory afterClaim = lending.getLending(lendingId);
        assertTrue(afterClaim.finished, "claim at exact grace boundary should succeed");
        assertEq(
            supplyToken.balanceOf(lender),
            lenderSupplyBefore + afterFailedLiquidation.supplyAmount,
            "lender should receive collateral"
        );
    }

    function testGrabOracleGameFeesAny_SweepsBorrowFeesAndSecondSweepIsNoOp() public {
        uint256 lendingId = _setupActiveLoan(true);
        openLending.LendingView memory loan = lending.getLending(lendingId);

        vm.warp(block.timestamp + 10 days);

        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            uint128(loan.supplyAmount),
            uint128(loan.repaidDebt),
            8 ether,
            uint128(loan.borrowAmount),
            loan.start,
            loan.supplyAmount * STAKE / 10000,
            INITIAL_LIQUIDITY
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

        borrowerBefore = borrowToken.balanceOf(borrower);
        lenderBefore = borrowToken.balanceOf(lender);
        liquidatorBefore = borrowToken.balanceOf(liquidator);

        lending.grabOracleGameFeesAny(lendingId, feeRecipient);

        assertEq(borrowToken.balanceOf(borrower), borrowerBefore, "second sweep should be a no-op for borrower");
        assertEq(borrowToken.balanceOf(lender), lenderBefore, "second sweep should be a no-op for lender");
        assertEq(borrowToken.balanceOf(liquidator), liquidatorBefore, "second sweep should be a no-op for liquidator");
    }

    function testLiquidate_InitializesCloneFeeReceiver() public {
        uint256 lendingId = _setupActiveLoan(true);
        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        assertEq(loanBefore.feeRecipient, address(0), "fee recipient should stay unset before liquidation");

        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            uint128(loanBefore.supplyAmount),
            uint128(loanBefore.repaidDebt),
            8 ether,
            uint128(loanBefore.borrowAmount),
            loanBefore.start,
            loanBefore.supplyAmount * STAKE / 10000,
            INITIAL_LIQUIDITY
        );

        openLending.LendingView memory loanDuring = lending.getLending(lendingId);
        assertTrue(loanDuring.feeRecipient != address(0), "liquidation should deploy a fee receiver");

        oracleFeeReceiver feeReceiver = oracleFeeReceiver(loanDuring.feeRecipient);
        assertEq(feeReceiver.owner(), address(lending), "clone owner mismatch");
        assertEq(feeReceiver.gameId(), lendingId, "clone gameId mismatch");
        assertEq(address(feeReceiver.oracle()), address(oracle), "clone oracle mismatch");
        assertEq(feeReceiver.token1(), address(supplyToken), "clone token1 mismatch");
        assertEq(feeReceiver.token2(), address(borrowToken), "clone token2 mismatch");
    }

    function testAcceptRefiOffer_LeavesFeeRecipientUnsetUntilLiquidation() public {
        uint256 lendingId = _setupActiveLoan(true);
        assertEq(lending.getLending(lendingId).feeRecipient, address(0), "fee recipient should start unset");

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 10 ether, 5 ether);

        vm.prank(lender2);
        uint256 refiNonce =
            lending.offerRefiBorrow(lendingId, 15e7, true, 0, 10 ether, SUPPLY_AMOUNT - 5 ether);

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiNonce);

        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertEq(loan.feeRecipient, address(0), "refi should not eagerly deploy a fee receiver");
    }

    function _setupActiveLoan(bool allowAnyLiquidator) internal returns (uint256 lendingId) {
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

        vm.prank(lender);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, allowAnyLiquidator);

        vm.prank(borrower);
        lending.acceptOffer(lendingId);
    }
}
