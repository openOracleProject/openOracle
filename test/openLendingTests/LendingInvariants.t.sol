// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "../../src/openLend.sol";
import "../../src/OpenOracle.sol";
import "../../src/oracleFeeReceiver.sol";
import "../utils/MockERC20.sol";

contract LendingInvariantHandler is Test {
    openLending public immutable lending;
    MockERC20 public immutable supplyToken;
    MockERC20 public immutable borrowToken;

    address public immutable borrower = address(0x1001);
    address public immutable lender1 = address(0x1002);
    address public immutable lender2 = address(0x1003);
    address public immutable topper = address(0x1004);

    uint256[] internal lendingIds;
    mapping(uint256 => uint256) public lastOfferNumber;
    mapping(uint256 => uint256) public lastRefiOfferNumber;
    mapping(uint256 => uint256) public lastRefiNonce;
    mapping(uint256 => uint256) public acceptedRefiNonce;
    mapping(uint256 => bool) public refiResetObserved;

    uint48 internal constant LOAN_TERM = 30 days;
    uint24 internal constant LIQUIDATION_THRESHOLD = 8e6;
    uint128 internal constant STAKE = 100;
    uint32 internal constant BASE_RATE = 1e8;

    constructor(openLending _lending, MockERC20 _supplyToken, MockERC20 _borrowToken) {
        lending = _lending;
        supplyToken = _supplyToken;
        borrowToken = _borrowToken;
    }

    function prime() external {
        address[] memory accounts = new address[](4);
        accounts[0] = borrower;
        accounts[1] = lender1;
        accounts[2] = lender2;
        accounts[3] = topper;

        for (uint256 i = 0; i < accounts.length; i++) {
            supplyToken.transfer(accounts[i], 100_000 ether);
            borrowToken.transfer(accounts[i], 100_000 ether);
            vm.deal(accounts[i], 100 ether);
        }

        vm.startPrank(borrower);
        supplyToken.approve(address(lending), type(uint256).max);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lender1);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lender2);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(topper);
        supplyToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }

    function loanCount() external view returns (uint256) {
        return lendingIds.length;
    }

    function getLoanId(uint256 idx) external view returns (uint256) {
        return lendingIds[idx];
    }

    function createLoan(uint96 supplySeed, uint96 borrowSeed) external {
        if (lendingIds.length >= 8) return;

        uint128 supplyAmount = uint128(bound(supplySeed, 10 ether, 5_000 ether));
        uint128 maxBorrow = uint128((uint256(supplyAmount) * 75) / 100);
        if (maxBorrow == 0) return;
        uint128 borrowAmount = uint128(bound(borrowSeed, 1 ether, maxBorrow));

        vm.startPrank(borrower);
        try lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 days),
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            supplyAmount,
            borrowAmount,
            STAKE,
            _standardOracleParams()
        ) returns (uint256 lendingId) {
            lendingIds.push(lendingId);
        } catch {}
        vm.stopPrank();
    }

    function offerBorrow(uint256 loanSeed, bool allowAnyLiquidator) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLending.LendingView memory loan = lending.getLending(lendingId);
        if (loan.cancelled || loan.active || loan.finished || block.timestamp > loan.offerExpiration) return;

        vm.startPrank(lender1);
        try lending.offerBorrow(lendingId, uint128(loan.amountDemanded), BASE_RATE, allowAnyLiquidator) returns (
            uint256 offerNumber
        ) {
            lastOfferNumber[lendingId] = offerNumber;
        } catch {}
        vm.stopPrank();
    }

    function acceptBorrow(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        uint256 offerNumber = lastOfferNumber[lendingId];
        if (offerNumber == 0) return;

        vm.startPrank(borrower);
        try lending.acceptOffer(lendingId, offerNumber) {} catch {}
        vm.stopPrank();
    }

    function repay(uint256 loanSeed, uint96 repaySeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLending.LendingView memory loan = lending.getLending(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || loan.inLiquidation) return;

        uint128 totalOwed = _calculateOwedAtMaturity(uint128(loan.borrowAmount), loan.rate, loan.term);
        uint128 repaid = uint128(loan.repaidDebt);
        if (repaid >= totalOwed) return;
        uint128 maxRepay = totalOwed - repaid;
        uint128 amount = uint128(bound(repaySeed, 1, maxRepay));

        vm.startPrank(borrower);
        try lending.repayDebt(lendingId, amount) {} catch {}
        vm.stopPrank();
    }

    function topUp(uint256 loanSeed, uint96 topUpSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLending.LendingView memory loan = lending.getLending(lendingId);
        if (loan.finished || loan.cancelled || loan.inLiquidation || !loan.active) return;

        uint128 amount = uint128(bound(topUpSeed, 1, 1_000 ether));

        vm.startPrank(topper);
        try lending.topUpCollateralAnyone(lendingId, amount) {} catch {}
        vm.stopPrank();
    }

    function setRefiParams(uint256 loanSeed, uint96 extraSeed, uint96 pullSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLending.LendingView memory loan = lending.getLending(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || loan.inLiquidation || loan.supplyAmount <= 1) return;

        uint128 extraDemanded = uint128(bound(extraSeed, 0, 500 ether));
        uint128 supplyPulled = uint128(bound(pullSeed, 0, loan.supplyAmount - 1));

        vm.startPrank(borrower);
        try lending.changeRefiParams(lendingId, extraDemanded, supplyPulled) {} catch {}
        vm.stopPrank();
    }

    function offerRefi(uint256 loanSeed, uint32 rateSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLending.LendingView memory loan = lending.getLending(lendingId);
        openLending.RefiParams memory refiParams = lending.getRefiParams(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || loan.inLiquidation || !refiParams.set) return;

        uint32 rate = uint32(bound(rateSeed, 1, 2e8));
        uint256 minSupplyPostRefi =
            loan.supplyAmount > refiParams.supplyPulled ? loan.supplyAmount - refiParams.supplyPulled : 0;

        vm.startPrank(lender2);
        try lending.offerRefiBorrow(
            lendingId, rate, true, uint128(loan.repaidDebt), refiParams.extraDemanded, minSupplyPostRefi
        ) returns (uint256 refiOfferNumber, uint256 refiNonce) {
            lastRefiOfferNumber[lendingId] = refiOfferNumber;
            lastRefiNonce[lendingId] = refiNonce;
        } catch {}
        vm.stopPrank();
    }

    function acceptRefi(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        uint256 refiOfferNumber = lastRefiOfferNumber[lendingId];
        uint256 refiNonce = lastRefiNonce[lendingId];
        if (refiOfferNumber == 0 || refiNonce == 0) return;

        vm.startPrank(borrower);
        try lending.acceptRefiOffer(lendingId, refiOfferNumber, refiNonce) {
            acceptedRefiNonce[lendingId] = refiNonce;
            openLending.LendingView memory loan = lending.getLending(lendingId);
            openLending.RefiParams memory refiParams = lending.getRefiParams(lendingId);
            refiResetObserved[lendingId] = (
                loan.gracePeriod == 0 && loan.repaidDebt == 0 && loan.liquidator == address(0)
                    && loan.liquidationStart == 0 && !refiParams.set
            );
        } catch {}
        vm.stopPrank();
    }

    function advanceTime(uint32 timeSeed) external {
        uint256 jump = bound(uint256(timeSeed), 0, 7 days);
        vm.warp(block.timestamp + jump);
    }

    function _standardOracleParams() internal pure returns (openLending.OracleParams memory) {
        return openLending.OracleParams(300, 60, 100_000, 100, 10, 200);
    }

    function _calculateOwedAtMaturity(uint128 amount, uint32 rate, uint48 term) internal pure returns (uint128) {
        uint256 year = 365 days;
        uint256 interest = (uint256(amount) * uint256(term) * uint256(rate)) / (1e9 * year);
        return uint128(uint256(amount) + interest);
    }
}

contract LendingInvariantsTest is StdInvariant, Test {
    openLending internal lending;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken;
    MockERC20 internal borrowToken;
    LendingInvariantHandler internal handler;

    function setUp() public {
        oracle = new OpenOracle();
        lending = new openLending(IOpenOracle(address(oracle)));
        supplyToken = new MockERC20("Supply Token", "SUP");
        borrowToken = new MockERC20("Borrow Token", "BOR");

        handler = new LendingInvariantHandler(lending, supplyToken, borrowToken);
        supplyToken.transfer(address(handler), 400_000 ether);
        borrowToken.transfer(address(handler), 400_000 ether);
        handler.prime();
        targetContract(address(handler));
    }

    function invariant_finishedImpliesNotInLiquidation() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLending.LendingView memory loan = lending.getLending(lendingId);
            if (loan.finished) {
                assertFalse(loan.inLiquidation, "finished loan cannot remain in liquidation");
            }
        }
    }

    function invariant_repaidDebtNeverExceedsTerminalDebt() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLending.LendingView memory loan = lending.getLending(lendingId);
            if (loan.borrowAmount == 0 || loan.rate == 0 || loan.term == 0) continue;
            uint256 terminalDebt = uint256(uint128(loan.borrowAmount))
                + (uint256(uint128(loan.borrowAmount)) * uint256(loan.term) * uint256(loan.rate)) / (1e9 * 365 days);
            assertLe(loan.repaidDebt, terminalDebt, "repaidDebt cannot exceed terminal debt");
        }
    }

    function invariant_openLoansBackedByContractSupply() public view {
        uint256 count = handler.loanCount();
        uint256 requiredSupply;
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLending.LendingView memory loan = lending.getLending(lendingId);
            if (!loan.cancelled && !loan.finished) {
                requiredSupply += loan.supplyAmount;
                if (loan.inLiquidation) {
                    requiredSupply += (loan.supplyAmount * loan.stake) / 10000;
                }
            }
        }
        assertEq(
            supplyToken.balanceOf(address(lending)),
            requiredSupply,
            "contract supply balance should exactly match stored collateral bookkeeping"
        );
    }

    function invariant_refiCountersStayInitialized() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLending.LendingView memory loan = lending.getLending(lendingId);
            assertGe(loan.offerNumber, 1, "offerNumber should stay initialized");
            assertGe(loan.refiOfferNumber, 1, "refiOfferNumber should stay initialized");
            assertGe(loan.refiOfferNonce, 1, "refiOfferNonce should stay initialized");
            assertGt(loan.supplyAmount, 0, "supplyAmount should remain positive for created loans");
        }
    }

    function invariant_feeReceiverCloneStateMatchesLoan() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLending.LendingView memory loan = lending.getLending(lendingId);
            if (loan.feeRecipient == address(0)) continue;

            oracleFeeReceiver feeReceiver = oracleFeeReceiver(loan.feeRecipient);
            assertEq(feeReceiver.owner(), address(lending), "fee receiver owner mismatch");
            assertEq(feeReceiver.gameId(), lendingId, "fee receiver gameId mismatch");
            assertEq(address(feeReceiver.oracle()), address(oracle), "fee receiver oracle mismatch");
            assertEq(feeReceiver.token1(), loan.supplyToken, "fee receiver token1 mismatch");
            assertEq(feeReceiver.token2(), loan.borrowToken, "fee receiver token2 mismatch");
        }
    }

    function invariant_currentRefiNonceRemainsUnacceptedAndAcceptedNonceSticks() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLending.LendingView memory loan = lending.getLending(lendingId);
            assertFalse(
                lending.getRefiNonceAccepted(lendingId, loan.refiOfferNonce),
                "current refi nonce should not already be marked accepted"
            );

            uint256 acceptedNonce = handler.acceptedRefiNonce(lendingId);
            if (acceptedNonce != 0) {
                assertTrue(
                    lending.getRefiNonceAccepted(lendingId, acceptedNonce),
                    "accepted refi nonce should remain marked accepted"
                );
                assertLt(acceptedNonce, loan.refiOfferNonce, "accepted nonce should trail the current nonce");
            }
        }
    }

    function invariant_successfulRefiResetsExpectedFields() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            if (handler.acceptedRefiNonce(lendingId) != 0) {
                assertTrue(handler.refiResetObserved(lendingId), "successful refi should reset expected fields");
            }
        }
    }
}
