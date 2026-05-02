// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";

contract FuzzAccountingTest is OpenLendingBaseTest {
    address internal borrower = address(0x1);
    address internal lender1 = address(0x2);
    address internal lender2 = address(0x3);
    address internal topper = address(0x4);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 50 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint256 constant UNRELATED_SUPPLY = 500 ether;
    uint256 constant UNRELATED_BORROW = 1000 ether;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory supplyAccounts = new address[](2);
        supplyAccounts[0] = borrower;
        supplyAccounts[1] = topper;
        _fundSupply(supplyAccounts, 10_000 ether);

        address[] memory borrowAccounts = new address[](3);
        borrowAccounts[0] = borrower;
        borrowAccounts[1] = lender1;
        borrowAccounts[2] = lender2;
        _fundBorrow(borrowAccounts, 10_000 ether);

        _approveLendingBoth(borrower);
        _approveLendingBorrow(lender1);
        _approveLendingBorrow(lender2);
        _approveLendingSupply(topper);

        _seedUnrelated(UNRELATED_SUPPLY, UNRELATED_BORROW);
    }

    function testFuzz_PartialRepayTracksExactAmount(uint96 repayAmountRaw) public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        uint32 rate = lending.getLending(lendingId).rate;
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);
        uint128 repayAmount = uint128(bound(repayAmountRaw, 1, totalOwed - 1));

        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender1);
        uint256 contractBorrowBefore = borrowToken.balanceOf(address(lending));

        vm.prank(borrower);
        lending.repayDebt(lendingId, repayAmount, bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertFalse(loan.finished, "partial repayment should not finish the loan");
        assertEq(
            borrowToken.balanceOf(borrower), borrowerBorrowBefore - repayAmount, "borrower should spend exact amount"
        );
        // Streaming: lender receives the partial directly at repay time
        assertEq(
            borrowToken.balanceOf(lender1),
            lenderBorrowBefore + repayAmount,
            "lender should receive streamed partial repayment immediately"
        );
        // Contract balance does not accumulate repaid debt under streaming
        assertEq(
            borrowToken.balanceOf(address(lending)),
            contractBorrowBefore,
            "contract should NOT hold the repaid amount under streaming"
        );
    }

    function testFuzz_FullRepayAcceptsOversizedInput(uint96 repayAmountRaw) public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        uint32 rate = lending.getLending(lendingId).rate;
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);
        uint128 repayAmount = uint128(bound(repayAmountRaw, totalOwed, totalOwed + 1_000 ether));

        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender1);

        vm.prank(borrower);
        lending.repayDebt(lendingId, repayAmount, bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.finished, "full repayment branch should finish the loan");
        assertEq(
            borrowToken.balanceOf(borrower),
            borrowerBorrowBefore - totalOwed,
            "borrower should only pay terminal debt, not oversized input"
        );
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "borrower should receive collateral back"
        );
        assertEq(borrowToken.balanceOf(lender1), lenderBorrowBefore + totalOwed, "lender should receive terminal debt");
    }

    function testFuzz_TopUpCollateralAnyone_IncreasesSupplyAndBalance(uint96 topUpRaw) public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        uint128 topUpAmount = uint128(bound(topUpRaw, 1, 5_000 ether));

        uint256 topperSupplyBefore = supplyToken.balanceOf(topper);
        uint256 contractSupplyBefore = supplyToken.balanceOf(address(lending));

        vm.prank(topper);
        lending.topUpCollateralAnyone(lendingId, topUpAmount, bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + topUpAmount, "supplyAmount should increase by top-up");
        assertEq(supplyToken.balanceOf(topper), topperSupplyBefore - topUpAmount, "topper should fund the exact amount");
        assertEq(
            supplyToken.balanceOf(address(lending)),
            contractSupplyBefore + topUpAmount,
            "contract should receive the top-up amount"
        );
    }

    /// @dev Refi accept (V3, amort-aware): newPrincipal = principal + max(interestAccrued, commitmentInterest)
    ///      - interestPaid + extraDemanded — read directly from the amort struct rather than the legacy
    ///      "owedAtMaturity - repaidDebt + extra" form, which only matched under full-term commitment.
    function testFuzz_RefiNewBorrowAmountFromAmortState(uint96 extraRaw) public {
        uint256 lendingId = _originateLoan(borrower, lender1, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        uint128 extraDemanded = uint128(bound(extraRaw, 0, 200 ether));

        // Borrower opens refi curve with extraDemanded
        vm.prank(borrower);
        lending.refinance(lendingId, extraDemanded, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        // Snapshot pre-accept amort state
        openLend.LendingArrangement memory pre = lending.getLending(lendingId);
        uint256 interestClaim = pre.interestAccrued > pre.commitmentInterest
            ? uint256(pre.interestAccrued)
            : uint256(pre.commitmentInterest);
        uint128 expectedNewBorrow = uint128(
            uint256(pre.principal) + interestClaim - uint256(pre.interestPaid) + uint256(extraDemanded)
        );

        // Lender2 accepts at the current curve
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 0);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertEq(loan.principal, expectedNewBorrow,
            "post-refi principal = principal + max(accrued, commitInt) - interestPaid + extra");
        assertEq(loan.lender, lender2, "lender2 should be the new lender");
    }

    /// @dev Multi-partial-repay amortization fuzz. Stresses the model along four axes:
    ///        - commitmentFraction (1..1e7): how much of full-term interest is locked in as a floor
    ///        - elapsed time between repays: drives interestAccrued growth
    ///        - partial-repay count (1..5)
    ///        - repay size per round (jittered, always strictly under residual)
    ///      Asserts after each round that:
    ///        - interestPaid <= max(commitmentInterest, interestAccrued) (the lender's interest-claim cap)
    ///        - cumulative borrower outflow == cumulative lender inflow (streamed-payment conservation)
    ///        - contract borrow-token balance is unchanged (no buffer accumulation)
    function testFuzz_AmortMultiPartialRepay(
        uint24 commitmentFractionRaw,
        uint8 partialCountRaw,
        uint96 elapsedSeed,
        uint96 sizeSeed
    ) public {
        uint24 commitmentFraction = uint24(bound(uint256(commitmentFractionRaw), 1, 1e7));
        uint8 partialCount = uint8(bound(uint256(partialCountRaw), 1, 5));

        uint256 lendingId =
            _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, commitmentFraction, 0);
        _lend(lender1, lendingId);

        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender1);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 contractBorrowBefore = borrowToken.balanceOf(address(lending));

        uint256 totalRepaid;
        for (uint256 i = 0; i < partialCount; i++) {
            // jitter elapsed time within a window that keeps us under the term across all rounds
            uint256 maxJump = uint256(LOAN_TERM) / (uint256(partialCount) + 2);
            uint256 jump = bound(uint256(uint96(uint256(elapsedSeed) ^ (i * 7919))), 1 hours, maxJump);
            vm.warp(block.timestamp + jump);

            openLend.LendingArrangement memory pre = lending.getLending(lendingId);
            if (pre.finished) break;

            uint256 claimPre = pre.interestAccrued > pre.commitmentInterest
                ? uint256(pre.interestAccrued)
                : uint256(pre.commitmentInterest);
            uint256 residual = uint256(pre.principal) + claimPre - uint256(pre.interestPaid);
            if (residual <= 1) break;

            uint128 amount = uint128(bound(uint256(uint96(uint256(sizeSeed) ^ (i * 9587))), 1, residual - 1));

            vm.prank(borrower);
            lending.repayDebt(lendingId, amount, bytes32(0), 0, type(uint128).max);
            totalRepaid += amount;

            // Per-round amort invariant: interestPaid never exceeds the lender's interest claim
            openLend.LendingArrangement memory post = lending.getLending(lendingId);
            uint256 claimPost = post.interestAccrued > post.commitmentInterest
                ? uint256(post.interestAccrued)
                : uint256(post.commitmentInterest);
            assertLe(uint256(post.interestPaid), claimPost,
                "interestPaid must stay within max(commitInt, accrued)");
        }

        // Conservation: every wei the borrower paid was streamed through to the lender
        assertEq(
            borrowToken.balanceOf(borrower),
            borrowerBorrowBefore - totalRepaid,
            "borrower outflow == sum of partials"
        );
        assertEq(
            borrowToken.balanceOf(lender1),
            lenderBorrowBefore + totalRepaid,
            "lender inflow == sum of partials (streaming)"
        );
        assertEq(
            borrowToken.balanceOf(address(lending)),
            contractBorrowBefore,
            "contract holds no buffer under streaming"
        );
    }
}
