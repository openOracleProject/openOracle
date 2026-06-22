// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "../../src/openLend.sol";
import "../../src/OpenOracleSlim.sol";
import "../../src/oracleFeeReceiver2.sol";
import "../utils/MockERC20.sol";
import "../utils/MockWETH.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract InvariantBlacklistableERC20 is MockERC20 {
    mapping(address => bool) public blacklisted;

    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {}

    function blacklist(address account) external {
        blacklisted[account] = true;
    }

    function unblacklist(address account) external {
        blacklisted[account] = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[msg.sender], "Blacklisted sender");
        require(!blacklisted[to], "Blacklisted recipient");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[from], "Blacklisted sender");
        require(!blacklisted[to], "Blacklisted recipient");
        return super.transferFrom(from, to, amount);
    }
}

contract LendingInvariantHandler is Test {
    openLend public immutable lending;
    InvariantBlacklistableERC20 public immutable supplyToken;
    MockERC20 public immutable borrowToken;

    address internal constant ETH = address(0);

    address public immutable borrower = address(0x1001);
    address public immutable lender1 = address(0x1002);
    address public immutable lender2 = address(0x1003);
    address public immutable topper = address(0x1004);

    uint256[] internal lendingIds;

    uint48 internal constant LOAN_TERM = 30 days;
    uint24 internal constant LIQUIDATION_THRESHOLD = 8e6;
    uint16 internal constant STAKE = 100;

    constructor(openLend _lending, InvariantBlacklistableERC20 _supplyToken, MockERC20 _borrowToken) {
        lending = _lending;
        supplyToken = _supplyToken;
        borrowToken = _borrowToken;
    }

    function prime() external {
        address[4] memory accounts = [borrower, lender1, lender2, topper];

        for (uint256 i = 0; i < accounts.length; i++) {
            supplyToken.transfer(accounts[i], 100_000 ether);
            borrowToken.transfer(accounts[i], 100_000 ether);
            vm.deal(accounts[i], 1_000_000 ether);
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

    function createNativeSupplyLoan(uint96 supplySeed, uint96 borrowSeed, uint96 gasCompSeed, uint24 commitmentSeed)
        external
    {
        if (lendingIds.length >= 8) return;

        uint128 supplyAmount = uint128(bound(supplySeed, 10 ether, 5_000 ether));
        uint128 maxBorrow = uint128((uint256(supplyAmount) * 75) / 100);
        if (maxBorrow == 0) return;
        uint128 borrowAmount = uint128(bound(borrowSeed, 1 ether, maxBorrow));
        uint96 gasComp = uint96(bound(gasCompSeed, 0, 0.5 ether));
        uint24 commitmentFraction = uint24(bound(uint256(commitmentSeed), 0, 1e7));

        vm.startPrank(borrower);
        try lending.requestBorrow{value: uint256(supplyAmount) + gasComp}(
            LOAN_TERM,
            ETH,
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

    function createNativeBorrowLoan(uint96 supplySeed, uint96 borrowSeed, uint96 gasCompSeed, uint24 commitmentSeed)
        external
    {
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
            ETH,
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

    function lendLoan(uint256 loanSeed, uint24 liquidatorFraction) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (loan.cancelled || loan.active || loan.finished || !loan.curveOpen) return;

        address caller = (loanSeed & 1) == 0 ? lender1 : lender2;
        vm.startPrank(caller);
        if (loan.borrowToken == ETH) {
            try lending.lend{value: loan.principal}(
                lendingId, bytes32(0), 0, type(uint128).max, 0, 0, liquidatorFraction
            ) {} catch {}
        } else {
            try lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, liquidatorFraction) {} catch {}
        }
        vm.stopPrank();
    }

    function repay(uint256 loanSeed, uint96 repaySeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || loan.inLiquidation) return;

        uint128 totalOwed = _calculateOwedAtMaturity(loan.principal, loan.rate, loan.term);
        uint128 repaid = 0; // .repaidDebt removed under amort
        if (repaid >= totalOwed) return;
        uint128 maxRepay = totalOwed - repaid;
        uint128 amount = uint128(bound(repaySeed, 1, maxRepay));

        vm.startPrank(borrower);
        if (loan.borrowToken == ETH) {
            try lending.repayDebt{value: amount}(lendingId, amount, bytes32(0), 0, type(uint128).max) {} catch {}
        } else {
            try lending.repayDebt(lendingId, amount, bytes32(0), 0, type(uint128).max) {} catch {}
        }
        vm.stopPrank();
    }

    function topUp(uint256 loanSeed, uint96 topUpSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (loan.finished || loan.cancelled || loan.inLiquidation || !loan.active) return;

        uint128 amount = uint128(bound(topUpSeed, 1, 1_000 ether));

        vm.startPrank(topper);
        if (loan.supplyToken == ETH) {
            try lending.topUpCollateralAnyone{value: amount}(lendingId, amount, bytes32(0), 0, type(uint128).max) {}
            catch {}
        } else {
            try lending.topUpCollateralAnyone(lendingId, amount, bytes32(0), 0, type(uint128).max) {} catch {}
        }
        vm.stopPrank();
    }

    function openRefi(uint256 loanSeed, uint96 extraSeed, uint96 pullSeed, uint96 gasCompSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || loan.curveOpen || loan.supplyAmount <= 1) return;
        if (loan.borrowToken == ETH) return;

        uint128 extraDemanded = uint128(bound(extraSeed, 0, 500 ether));
        uint128 supplyPulled = uint128(bound(pullSeed, 0, loan.supplyAmount - 1));
        uint96 gasComp = uint96(bound(gasCompSeed, 0, 0.5 ether));

        vm.startPrank(borrower);
        try lending.refinance{value: gasComp}(lendingId, extraDemanded, supplyPulled, 0, gasComp, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max) {} catch {}
        vm.stopPrank();
    }

    function acceptRefi(uint256 loanSeed, uint24 liquidatorFraction) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (!loan.active || !loan.curveOpen || loan.inLiquidation) return;
        if (loan.borrowToken == ETH) return;

        address caller = (loanSeed & 1) == 0 ? lender1 : lender2;
        vm.startPrank(caller);
        try lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, liquidatorFraction) {} catch {}
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

        uint128 totalOwed = _calculateOwedAtMaturity(loan.principal, loan.rate, loan.term);
        uint128 repaid = 0; // .repaidDebt removed under amort
        if (repaid >= totalOwed) return;
        uint128 maxRepay = totalOwed - repaid;
        uint128 amount = uint128(bound(repaySeed, 1, maxRepay));

        // topper acts as the third-party payer
        vm.startPrank(topper);
        if (loan.borrowToken == ETH) {
            try lending.repayAnyDebt{value: amount}(lendingId, amount, bytes32(0), 0, type(uint128).max) {} catch {}
        } else {
            try lending.repayAnyDebt(lendingId, amount, bytes32(0), 0, type(uint128).max) {} catch {}
        }
        vm.stopPrank();
    }

    function claimCollateralAction(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        // Claim is permissionless, so any random caller can attempt it; contract gates internally.
        try lending.claimCollateral(lendingId) {} catch {}
    }

    function claimCollateralToTempHolding(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || loan.inLiquidation) return;
        if (loan.supplyToken != address(supplyToken)) return;

        uint256 expiry = uint256(loan.start) + loan.term + loan.gracePeriod;
        if (block.timestamp < expiry) vm.warp(expiry);

        supplyToken.blacklist(loan.lender);
        try lending.claimCollateral(lendingId) {} catch {}
    }

    function withdrawEscrowedSupply(uint256 actorSeed) external {
        address[4] memory accounts = [borrower, lender1, lender2, topper];
        address account = accounts[actorSeed % accounts.length];
        supplyToken.unblacklist(account);

        vm.prank(account);
        try lending.getTempHolding(address(supplyToken)) {} catch {}
    }

    function _standardOracleParams() internal pure returns (openLend.OracleParams memory) {
        return openLend.OracleParams({
            settlementTime: 300,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 100,
            initialLiquidity: 10,
            multiplier: 200,
            maxBaseFee: 0,
            minSettlerReward: 0
        });
    }

    function _zeroOracleParams() internal pure returns (openLend.OracleParams memory) {
        return openLend.OracleParams({
            settlementTime: 0,
            disputeDelay: 0,
            oracleGameFee: 0,
            escalationFactor: 0,
            initialLiquidity: 0,
            multiplier: 0,
            maxBaseFee: 0,
            minSettlerReward: 0
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
    InvariantBlacklistableERC20 internal supplyToken;
    MockERC20 internal borrowToken;
    LendingInvariantHandler internal handler;

    /// @dev Total borrow-token supply held across the handler's known actor set + the lending contract,
    ///      captured immediately after setUp. Conservation: ERC20 transfers cannot mint or burn, so the
    ///      sum across this closed set must remain constant for all subsequent operations.
    uint256 internal initialBorrowTotal;

    function setUp() public {
        oracle = new OpenOracle();
        MockWETH weth = new MockWETH();
        lending = new openLend(IOpenOracle2(address(oracle)), address(weth));
        supplyToken = new InvariantBlacklistableERC20("Supply Token", "SUP");
        borrowToken = new MockERC20("Borrow Token", "BOR");

        handler = new LendingInvariantHandler(lending, supplyToken, borrowToken);
        supplyToken.transfer(address(handler), 400_000 ether);
        borrowToken.transfer(address(handler), 400_000 ether);
        handler.prime();
        targetContract(address(handler));

        initialBorrowTotal = _borrowTotalAcrossActors();
    }

    function _borrowTotalAcrossActors() internal view returns (uint256) {
        return borrowToken.balanceOf(handler.borrower())
            + borrowToken.balanceOf(handler.lender1())
            + borrowToken.balanceOf(handler.lender2())
            + borrowToken.balanceOf(handler.topper())
            + borrowToken.balanceOf(address(lending))
            + borrowToken.balanceOf(address(handler));
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

    /// @notice Amortization invariant: payments toward the lender's interest claim never exceed the claim
    ///         (`max(commitmentInterest, interestAccrued)`), and `lastTouch` never advances past the loan's
    ///         maturity (touch caps accrual at `start + term`). Note: `principal + interestAccrued` is NOT
    ///         a lower bound on `interestPaid` — a borrower can prepay into the floor surplus, which is why
    ///         `_liquidationOwed` clamps explicitly at 0.
    function invariant_amortStateConsistent() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            if (loan.principal == 0 && loan.commitmentInterest == 0) continue;

            uint256 interestClaim = loan.interestAccrued > loan.commitmentInterest
                ? uint256(loan.interestAccrued)
                : uint256(loan.commitmentInterest);
            assertLe(uint256(loan.interestPaid), interestClaim,
                "interestPaid <= max(commitmentInterest, interestAccrued)");

            if (loan.start != 0 && loan.term != 0) {
                uint256 termEnd = uint256(loan.start) + uint256(loan.term);
                assertLe(uint256(loan.lastTouch), termEnd, "lastTouch never exceeds start + term");
            }
        }
    }

    /// @notice Borrow-token conservation: the handler exercises a closed actor set (borrower, lenders, topper,
    ///         the lending contract, and the handler itself). ERC20 transfers cannot mint or burn, so the
    ///         total balance across this set must equal whatever it was at setUp time. Streamed partial
    ///         repayments, refi fundings, and third-party `repayAnyDebt` flows must all preserve this sum.
    function invariant_borrowTokenConservation() public view {
        assertEq(
            _borrowTotalAcrossActors(),
            initialBorrowTotal,
            "borrow-token total across actor set must be conserved"
        );
    }

    function _supplyTempHoldingAcrossActors() internal view returns (uint256) {
        return lending.tempHolding(handler.borrower(), address(supplyToken))
            + lending.tempHolding(handler.lender1(), address(supplyToken))
            + lending.tempHolding(handler.lender2(), address(supplyToken))
            + lending.tempHolding(handler.topper(), address(supplyToken));
    }

    /// @notice Contract supply balance must back all live loans, any in-flight liquidator stakes,
    ///         and any supply-token payouts escrowed in tempHolding after a failed recipient transfer.
    function invariant_openLoansBackedByContractSupply() public view {
        uint256 count = handler.loanCount();
        uint256 requiredErc20Supply;
        uint256 requiredNativeSupply;
        uint256 stagedGasComp;
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            stagedGasComp += loan.gasCompensation;
            if (!loan.cancelled && !loan.finished) {
                uint256 backedSupply = loan.supplyAmount;
                if (loan.inLiquidation) {
                    backedSupply += (uint256(loan.supplyAmount) * loan.stake) / 10000;
                }
                if (loan.supplyToken == address(0)) {
                    requiredNativeSupply += backedSupply;
                } else {
                    requiredErc20Supply += backedSupply;
                }
            }
        }
        requiredErc20Supply += _supplyTempHoldingAcrossActors();

        assertEq(
            supplyToken.balanceOf(address(lending)),
            requiredErc20Supply,
            "contract ERC20 supply balance should exactly match stored collateral bookkeeping"
        );
        assertGe(
            address(lending).balance,
            requiredNativeSupply + stagedGasComp,
            "contract ETH balance should cover native collateral and staged gasComp"
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
            uint256 reportId = lending.lendingToReportId(lendingId);
            if (reportId == 0) continue;

            address predicted = Clones.predictDeterministicAddress(
                lending.feeReceiverImpl(), bytes32(reportId), address(lending)
            );
            if (predicted.code.length == 0) continue;

            assertEq(oracleFeeReceiver(predicted).gameId(), lendingId, "fee receiver gameId mismatch");
        }
    }
}
