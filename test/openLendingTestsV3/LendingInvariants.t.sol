// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "../../src/openLendV3.sol";
import "../../src/OpenOracle.sol";
import "../../src/oracleFeeReceiver.sol";
import "../utils/MockERC20.sol";
import "../utils/MockWETH.sol";

contract LendingInvariantHandler is Test {
    openLend public immutable lending;
    MockERC20 public immutable supplyToken;
    MockERC20 public immutable borrowToken;

    address public immutable borrower = address(0x1001);
    address public immutable lender1 = address(0x1002);
    address public immutable lender2 = address(0x1003);
    address public immutable topper = address(0x1004);

    uint256[] internal lendingIds;

    uint48 internal constant LOAN_TERM = 30 days;
    uint24 internal constant LIQUIDATION_THRESHOLD = 8e6;
    uint16 internal constant STAKE = 100;

    constructor(openLend _lending, MockERC20 _supplyToken, MockERC20 _borrowToken) {
        lending = _lending;
        supplyToken = _supplyToken;
        borrowToken = _borrowToken;
    }

    function prime() external {
        address[4] memory accounts = [borrower, lender1, lender2, topper];

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
        borrowToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }

    function loanCount() external view returns (uint256) {
        return lendingIds.length;
    }

    function getLoanId(uint256 idx) external view returns (uint256) {
        return lendingIds[idx];
    }

    function createLoan(uint96 supplySeed, uint96 borrowSeed, uint96 gasCompSeed, uint24 commitmentSeed) external {
        if (lendingIds.length >= 8) return;

        uint128 supplyAmount = uint128(bound(supplySeed, 10 ether, 5_000 ether));
        uint128 maxBorrow = uint128((uint256(supplyAmount) * 75) / 100);
        if (maxBorrow == 0) return;
        uint128 borrowAmount = uint128(bound(borrowSeed, 1 ether, maxBorrow));
        uint96 gasComp = uint96(bound(gasCompSeed, 0, 0.5 ether));
        uint24 commitmentFraction = uint24(bound(uint256(commitmentSeed), 0, 1e7));

        vm.startPrank(borrower);
        try lending.requestBorrow{value: gasComp}(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            supplyAmount,
            borrowAmount,
            STAKE,
            commitmentFraction,
            gasComp,
            _standardOracleParams(),
            _standardInterestRateParams()
        ) returns (uint256 lendingId) {
            lendingIds.push(lendingId);
        } catch {}
        vm.stopPrank();
    }

    function lendLoan(uint256 loanSeed, bool allowAnyLiquidator) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (loan.cancelled || loan.active || loan.finished || !loan.curveOpen) return;

        address caller = (loanSeed & 1) == 0 ? lender1 : lender2;
        vm.startPrank(caller);
        try lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, allowAnyLiquidator) {} catch {}
        vm.stopPrank();
    }

    function repay(uint256 loanSeed, uint96 repaySeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || loan.inLiquidation) return;

        uint128 totalOwed = _calculateOwedAtMaturity(loan.borrowAmount, loan.rate, loan.term);
        uint128 repaid = loan.repaidDebt;
        if (repaid >= totalOwed) return;
        uint128 maxRepay = totalOwed - repaid;
        uint128 amount = uint128(bound(repaySeed, 1, maxRepay));

        vm.startPrank(borrower);
        try lending.repayDebt(lendingId, amount, bytes32(0), 0, 0) {} catch {}
        vm.stopPrank();
    }

    function topUp(uint256 loanSeed, uint96 topUpSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (loan.finished || loan.cancelled || loan.inLiquidation || !loan.active) return;

        uint128 amount = uint128(bound(topUpSeed, 1, 1_000 ether));

        vm.startPrank(topper);
        try lending.topUpCollateralAnyone(lendingId, amount, bytes32(0), 0, 0) {} catch {}
        vm.stopPrank();
    }

    function openRefi(uint256 loanSeed, uint96 extraSeed, uint96 pullSeed, uint96 gasCompSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || loan.curveOpen || loan.supplyAmount <= 1) return;

        uint128 extraDemanded = uint128(bound(extraSeed, 0, 500 ether));
        uint128 supplyPulled = uint128(bound(pullSeed, 0, loan.supplyAmount - 1));
        uint96 gasComp = uint96(bound(gasCompSeed, 0, 0.5 ether));

        vm.startPrank(borrower);
        try lending.refinance{value: gasComp}(lendingId, extraDemanded, supplyPulled, 0, gasComp, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, 0) {} catch {}
        vm.stopPrank();
    }

    function acceptRefi(uint256 loanSeed, bool allowAnyLiquidator) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (!loan.active || !loan.curveOpen || loan.inLiquidation) return;

        address caller = (loanSeed & 1) == 0 ? lender1 : lender2;
        vm.startPrank(caller);
        try lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, allowAnyLiquidator) {} catch {}
        vm.stopPrank();
    }

    function cancelRefi(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (!loan.active || !loan.curveOpen) return;

        vm.startPrank(borrower);
        try lending.cancelRefinance(lendingId) {} catch {}
        vm.stopPrank();
    }

    function advanceTime(uint32 timeSeed) external {
        uint256 jump = bound(uint256(timeSeed), 0, 7 days);
        vm.warp(block.timestamp + jump);
    }

    function repayAny(uint256 loanSeed, uint96 repaySeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || loan.inLiquidation) return;

        uint128 totalOwed = _calculateOwedAtMaturity(loan.borrowAmount, loan.rate, loan.term);
        uint128 repaid = loan.repaidDebt;
        if (repaid >= totalOwed) return;
        uint128 maxRepay = totalOwed - repaid;
        uint128 amount = uint128(bound(repaySeed, 1, maxRepay));

        // topper acts as the third-party payer
        vm.startPrank(topper);
        try lending.repayAnyDebt(lendingId, amount, bytes32(0), 0, 0) {} catch {}
        vm.stopPrank();
    }

    function claimCollateralAction(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        // Claim is permissionless, so any random caller can attempt it; contract gates internally.
        try lending.claimCollateral(lendingId) {} catch {}
    }

    function _standardOracleParams() internal pure returns (openLend.OracleParams memory) {
        return openLend.OracleParams({
            settlementTime: 300,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 100,
            initialLiquidity: 10,
            multiplier: 200
        });
    }

    function _zeroOracleParams() internal pure returns (openLend.OracleParams memory) {
        return openLend.OracleParams({
            settlementTime: 0,
            disputeDelay: 0,
            oracleGameFee: 0,
            escalationFactor: 0,
            initialLiquidity: 0,
            multiplier: 0
        });
    }

    function _standardInterestRateParams() internal pure returns (openLend.InterestRateParams memory) {
        return openLend.InterestRateParams({
            maxRate: 1e9,
            startingRate: 1e8,
            roundLength: 300,
            growthRate: 10500,
            maxRounds: 100
        });
    }

    function _calculateOwedAtMaturity(uint128 amount, uint32 rate, uint48 term) internal pure returns (uint128) {
        uint256 year = 365 days;
        uint256 interest = (uint256(amount) * uint256(term) * uint256(rate)) / (1e9 * year);
        return uint128(uint256(amount) + interest);
    }
}

contract LendingInvariantsTest is StdInvariant, Test {
    openLend internal lending;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken;
    MockERC20 internal borrowToken;
    LendingInvariantHandler internal handler;

    function setUp() public {
        oracle = new OpenOracle();
        MockWETH weth = new MockWETH();
        lending = new openLend(IOpenOracle(address(oracle)), address(weth));
        supplyToken = new MockERC20("Supply Token", "SUP");
        borrowToken = new MockERC20("Borrow Token", "BOR");

        handler = new LendingInvariantHandler(lending, supplyToken, borrowToken);
        supplyToken.transfer(address(handler), 400_000 ether);
        borrowToken.transfer(address(handler), 400_000 ether);
        handler.prime();
        targetContract(address(handler));
    }

    /// @notice A finished loan must not still be in liquidation.
    function invariant_finishedImpliesNotInLiquidation() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            if (loan.finished) {
                assertFalse(loan.inLiquidation, "finished loan cannot remain in liquidation");
            }
        }
    }

    /// @notice repaidDebt should never exceed the maturity-equivalent terminal debt of the loan.
    function invariant_repaidDebtNeverExceedsTerminalDebt() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            if (loan.borrowAmount == 0 || loan.rate == 0 || loan.term == 0) continue;
            uint256 terminalDebt = uint256(loan.borrowAmount)
                + (uint256(loan.borrowAmount) * uint256(loan.term) * uint256(loan.rate)) / (1e9 * 365 days);
            assertLe(loan.repaidDebt, terminalDebt, "repaidDebt cannot exceed terminal debt");
        }
    }

    /// @notice Contract supply balance must back all live loans plus any in-flight liquidator stakes.
    function invariant_openLoansBackedByContractSupply() public view {
        uint256 count = handler.loanCount();
        uint256 requiredSupply;
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            if (!loan.cancelled && !loan.finished) {
                requiredSupply += loan.supplyAmount;
                if (loan.inLiquidation) {
                    requiredSupply += (uint256(loan.supplyAmount) * loan.stake) / 10000;
                }
            }
        }
        assertEq(
            supplyToken.balanceOf(address(lending)),
            requiredSupply,
            "contract supply balance should exactly match stored collateral bookkeeping"
        );
    }

    /// @notice Contract ETH balance must back all currently-staged gasComp escrows.
    ///         Catches accounting bugs where gasComp is set in storage without msg.value, or refunded twice, etc.
    function invariant_ethBalanceBacksStagedGasComp() public view {
        uint256 count = handler.loanCount();
        uint256 stagedGasComp;
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            stagedGasComp += lending.getLending(lendingId).gasCompensation;
        }
        assertGe(
            address(lending).balance,
            stagedGasComp,
            "contract ETH balance must cover sum of staged gasComp"
        );
    }

    /// @notice Created loans should always have positive supplyAmount (zero supplyAmount is rejected at request).
    function invariant_supplyAmountStaysPositiveForCreated() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            // After full repayment / liquidation the supplyAmount stays as last-snapshot; we only check pre-finish.
            if (loan.cancelled || loan.finished) continue;
            assertGt(loan.supplyAmount, 0, "active loan should have positive supplyAmount");
        }
    }

    /// @notice An open refi curve implies the loan is still active and not finished/cancelled.
    function invariant_curveOpenImpliesLive() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            if (loan.curveOpen) {
                assertFalse(loan.finished, "curveOpen requires not finished");
                assertFalse(loan.cancelled, "curveOpen requires not cancelled");
            }
        }
    }

    /// @notice Fee-receiver clones should always own-by lending and report their lendingId correctly.
    function invariant_feeReceiverCloneStateMatchesLoan() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            if (loan.feeRecipient == address(0)) continue;

            oracleFeeReceiver feeReceiver = oracleFeeReceiver(loan.feeRecipient);
            assertEq(feeReceiver.gameId(), lendingId, "fee receiver gameId mismatch");
        }
    }
}
