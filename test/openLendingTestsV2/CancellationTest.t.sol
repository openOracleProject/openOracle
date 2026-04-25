// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "./OpenLendingBase.t.sol";

contract CancellationTest is OpenLendingBaseTest {
    event BorrowRequestCancelled(address indexed borrower, uint256 indexed lendingId);
    event BorrowOfferCancelled(uint256 lendingId);

    address internal borrower = address(0x1);
    address internal lender1 = address(0x2);
    address internal lender2 = address(0x3);
    address internal randomUser = address(0x4);

    // Unrelated funds to verify no skimming
    uint256 constant UNRELATED_SUPPLY = 500e18;
    uint256 constant UNRELATED_BORROW = 1000e18;

    // Loan parameters
    uint128 constant SUPPLY_AMOUNT = 100e18;
    uint128 constant BORROW_AMOUNT = 70e18;
    uint48 constant LOAN_TERM = 30 days;
    uint32 constant INTEREST_RATE = 1e8; // 10%
    uint24 constant LIQUIDATION_THRESHOLD = 8e6; // 80%
    uint128 constant STAKE = 100; // 1%
    uint256 constant OFFER_EXPIRATION = 1 hours;

    function setUp() public {
        _deployCore("Supply", "SUP", "Borrow", "BOR");

        address[] memory supplyAccounts = new address[](1);
        supplyAccounts[0] = borrower;
        _fundSupply(supplyAccounts, 1000e18);

        address[] memory borrowAccounts = new address[](2);
        borrowAccounts[0] = lender1;
        borrowAccounts[1] = lender2;
        _fundBorrow(borrowAccounts, 1000e18);

        _seedUnrelated(UNRELATED_SUPPLY, UNRELATED_BORROW);

        _approveLendingSupply(borrower);
        _approveLendingBorrow(lender1);
        _approveLendingBorrow(lender2);
    }

    // Helper to create a borrow request
    function createBorrowRequest() internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + OFFER_EXPIRATION),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            _standardOracleParams()
        );
    }

    // =========================================================================
    // BORROWER CANCELLATION TESTS
    // =========================================================================

    function testBorrowerCancel_Success() public {
        uint256 lendingId = createBorrowRequest();

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 contractSupplyBefore = supplyToken.balanceOf(address(lending));

        vm.expectEmit(true, true, false, true, address(lending));
        emit BorrowRequestCancelled(borrower, lendingId);
        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        // Borrower gets collateral back
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "Borrower should receive collateral back"
        );

        // Contract balance decreased by exactly SUPPLY_AMOUNT
        assertEq(
            supplyToken.balanceOf(address(lending)),
            contractSupplyBefore - SUPPLY_AMOUNT,
            "Contract should lose exactly SUPPLY_AMOUNT"
        );

        // Unrelated funds untouched
        assertEq(
            supplyToken.balanceOf(address(lending)), UNRELATED_SUPPLY, "Unrelated supply funds should be untouched"
        );
        assertEq(
            borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow funds should be untouched"
        );

        // Verify cancelled state
        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertTrue(loan.cancelled, "Loan should be marked as cancelled");
    }

    function testBorrowerCancel_FailsAfterOfferAccepted() public {
        uint256 lendingId = createBorrowRequest();

        // Lender makes offer
        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Borrower accepts offer
        vm.prank(borrower);
        lending.acceptOffer(lendingId);

        // Borrower tries to cancel - should fail because loan is active
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "lendingId active"));
        lending.cancelBorrowRequest(lendingId);
    }

    function testBorrowerCancel_FailsIfAlreadyCancelled() public {
        uint256 lendingId = createBorrowRequest();

        // First cancel succeeds
        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        // Second cancel fails
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "lendingId cancelled"));
        lending.cancelBorrowRequest(lendingId);
    }

    function testBorrowerCancel_FailsIfNotBorrower() public {
        uint256 lendingId = createBorrowRequest();

        // Random user tries to cancel
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "msg.sender"));
        lending.cancelBorrowRequest(lendingId);

        // Lender tries to cancel
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "msg.sender"));
        lending.cancelBorrowRequest(lendingId);
    }

    // V2: there is only one offer slot. A better-rate offer auto-refunds the previous offeror.
    // cancelBorrowRequest then refunds the standing offer, so all lender funds leave the contract.
    function testBorrowerCancel_WithPendingOffers() public {
        uint256 lendingId = createBorrowRequest();

        uint256 lender1Before = borrowToken.balanceOf(lender1);
        uint256 lender2Before = borrowToken.balanceOf(lender2);

        // Lender1 makes offer
        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Lender2 takes the slot with a strictly better rate; lender1 is auto-refunded.
        vm.prank(lender2);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE - 1e7, true);

        assertEq(borrowToken.balanceOf(lender1), lender1Before, "lender1 auto-refunded by better-rate offer");
        assertEq(borrowToken.balanceOf(lender2), lender2Before - BORROW_AMOUNT, "lender2 deposited");

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        // Borrower cancels — V2 refunds the standing offer to lender2 as part of cancellation.
        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        // Borrower gets collateral back
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "Borrower should receive collateral back"
        );

        // Lender2 was auto-refunded; lender1 was already auto-refunded earlier.
        assertEq(borrowToken.balanceOf(lender2), lender2Before, "lender2 refunded by cancelBorrowRequest");

        // Contract holds only unrelated borrow funds.
        assertEq(
            borrowToken.balanceOf(address(lending)),
            UNRELATED_BORROW,
            "Contract should hold only unrelated borrow tokens"
        );
    }

    // =========================================================================
    // LENDER OFFER CANCELLATION TESTS
    // =========================================================================

    function testLenderCancel_Success() public {
        uint256 lendingId = createBorrowRequest();

        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender1);
        uint256 contractBorrowBefore = borrowToken.balanceOf(address(lending));

        // Wait 60 seconds (exactly when cancel becomes allowed)
        vm.warp(block.timestamp + 60);

        vm.expectEmit(false, false, false, true, address(lending));
        emit BorrowOfferCancelled(lendingId);
        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId);

        // Lender gets funds back
        assertEq(
            borrowToken.balanceOf(lender1),
            lenderBorrowBefore + BORROW_AMOUNT,
            "Lender should receive borrow amount back"
        );

        // Contract balance decreased by exactly BORROW_AMOUNT
        assertEq(
            borrowToken.balanceOf(address(lending)),
            contractBorrowBefore - BORROW_AMOUNT,
            "Contract should lose exactly BORROW_AMOUNT"
        );

        // Unrelated funds untouched
        assertEq(
            supplyToken.balanceOf(address(lending)),
            UNRELATED_SUPPLY + SUPPLY_AMOUNT,
            "Unrelated supply + borrower collateral should be intact"
        );
        assertEq(
            borrowToken.balanceOf(address(lending)), UNRELATED_BORROW, "Unrelated borrow funds should be untouched"
        );

        // Verify offer slot is cleared
        openLending.LendingOffer memory offer = lending.getLendingOffer(lendingId);
        assertEq(offer.lender, address(0), "Offer slot should be cleared");
        assertEq(offer.amount, 0, "Offer amount should be zeroed");
    }

    function testLenderCancel_FailsTooSoon() public {
        uint256 lendingId = createBorrowRequest();

        uint256 offerTime = block.timestamp;

        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Try to cancel immediately (before 60 seconds)
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "cancel too soon"));
        lending.cancelBorrowOffer(lendingId);

        // Try at 59 seconds (should still fail)
        vm.warp(offerTime + 59);
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "cancel too soon"));
        lending.cancelBorrowOffer(lendingId);

        // At exactly 60 seconds should succeed (60 < 60 is false)
        vm.warp(offerTime + 60);
        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId);
    }

    // V2: acceptOffer deletes the offer slot. Active loan blocks any cancel.
    function testLenderCancel_FailsAfterOfferAccepted() public {
        uint256 lendingId = createBorrowRequest();

        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Borrower accepts the offer
        vm.prank(borrower);
        lending.acceptOffer(lendingId);

        // Wait 60 seconds
        vm.warp(block.timestamp + 60);

        // Lender tries to cancel - should fail because loan is active
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "lendingId active"));
        lending.cancelBorrowOffer(lendingId);
    }

    function testLenderCancel_FailsIfAlreadyCancelled() public {
        uint256 lendingId = createBorrowRequest();

        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        vm.warp(block.timestamp + 60);

        // First cancel succeeds
        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId);

        // Second cancel fails - slot is empty
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "no borrow offer"));
        lending.cancelBorrowOffer(lendingId);
    }

    function testLenderCancel_FailsIfNotLender() public {
        uint256 lendingId = createBorrowRequest();

        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        vm.warp(block.timestamp + 60);

        // Random user tries to cancel
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "msg.sender"));
        lending.cancelBorrowOffer(lendingId);

        // Different lender tries to cancel
        vm.prank(lender2);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "msg.sender"));
        lending.cancelBorrowOffer(lendingId);

        // Borrower tries to cancel
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "msg.sender"));
        lending.cancelBorrowOffer(lendingId);
    }

    function testLenderCancel_NonExistentOffer() public {
        uint256 lendingId = createBorrowRequest();

        vm.warp(block.timestamp + 60);

        // No offer ever made; cancel reverts with "no borrow offer".
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "no borrow offer"));
        lending.cancelBorrowOffer(lendingId);
    }

    // =========================================================================
    // MULTIPLE OFFERS SCENARIOS
    // =========================================================================

    // V2: a better-rate offer auto-refunds the previous offeror, so only one offer ever stands.
    function testMultipleOffers_BetterRateReplacesPrevious() public {
        uint256 lendingId = createBorrowRequest();

        uint256 lender1Before = borrowToken.balanceOf(lender1);
        uint256 lender2Before = borrowToken.balanceOf(lender2);

        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Lender2 offers at a strictly better (lower) rate; lender1 must be auto-refunded.
        vm.prank(lender2);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE - 1e7, true);

        assertEq(borrowToken.balanceOf(lender1), lender1Before, "lender1 should be auto-refunded by better-rate offer");
        assertEq(borrowToken.balanceOf(lender2), lender2Before - BORROW_AMOUNT, "lender2 should have deposited");

        // A worse-or-equal-rate offer reverts in V2.
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "must improve rate"));
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // Borrower accepts the standing best offer; slot is cleared and lender2 is now the active lender.
        vm.prank(borrower);
        lending.acceptOffer(lendingId);

        openLending.LendingView memory loan = lending.getLending(lendingId);
        assertEq(loan.lender, lender2, "lender2 should now be the active lender");

        // Slot empty after accept
        openLending.LendingOffer memory slot = lending.getLendingOffer(lendingId);
        assertEq(slot.lender, address(0), "offer slot should be cleared after accept");
    }

    // V2: cancelBorrowRequest auto-refunds the standing offer too.
    function testBorrowerCancel_AutoRefundsStandingOffer() public {
        uint256 lendingId = createBorrowRequest();

        uint256 lenderBefore = borrowToken.balanceOf(lender1);

        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        assertEq(borrowToken.balanceOf(lender1), lenderBefore - BORROW_AMOUNT, "lender deposited");

        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        // Lender was already refunded inside cancelBorrowRequest.
        assertEq(
            borrowToken.balanceOf(lender1),
            lenderBefore,
            "Lender should be auto-refunded by cancelBorrowRequest"
        );

        // Subsequent cancel attempt reverts (cancelled) and the slot is empty.
        vm.warp(block.timestamp + 60);
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "no borrow offer"));
        lending.cancelBorrowOffer(lendingId);
    }

    // =========================================================================
    // EDGE CASES
    // =========================================================================

    function testCannotOfferOnCancelledRequest() public {
        uint256 lendingId = createBorrowRequest();

        // Borrower cancels
        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        // Lender tries to make offer on cancelled request
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "lendingId cancelled"));
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);
    }

    // V2: after cancellation the slot is empty, so the borrower cannot accept (no offer).
    function testCannotAcceptCancelledOffer() public {
        uint256 lendingId = createBorrowRequest();

        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        vm.warp(block.timestamp + 60);

        // Lender cancels offer
        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId);

        // Borrower tries to accept; slot is empty
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "no offer"));
        lending.acceptOffer(lendingId);
    }

    function testExactTimingAt60Seconds() public {
        uint256 lendingId = createBorrowRequest();

        uint256 offerTime = block.timestamp;

        vm.prank(lender1);
        lending.offerBorrow(lendingId, BORROW_AMOUNT, INTEREST_RATE, true);

        // At 59 seconds after offer, should still fail
        vm.warp(offerTime + 59);
        vm.prank(lender1);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "cancel too soon"));
        lending.cancelBorrowOffer(lendingId);

        // At exactly 60 seconds, should succeed (condition is <)
        vm.warp(offerTime + 60);
        vm.prank(lender1);
        lending.cancelBorrowOffer(lendingId);
    }
}
