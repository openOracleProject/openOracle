// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "../../src/openLend.sol";
import "../../src/openLendParamHashHelper.sol";
import "../../src/OpenOracleSlim.sol";
import "../../src/oracleFeeReceiver2.sol";
import "../../src/interfaces/IOpenOracle2.sol";
import "../utils/MockERC20.sol";
import "../utils/MockWETH.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @notice Invariant handler that exercises the lend -> liquidate -> finalize path. Bounded action set:
///         createLoan / lendLoan / liquidate / settleOracleOnly / finalizeLatest / advanceTime. No disputes (settle resolves to whatever
///         price the liquidator initially submitted) — keeps the state machine focused on lending lifecycle, not oracle internals.
contract LiquidationInvariantHandler is Test {
    openLend public immutable lending;
    openLendParamHashHelper public immutable lendView;
    OpenOracle public immutable oracle;
    MockERC20 public immutable supplyToken;
    MockERC20 public immutable borrowToken;
    address internal constant ETH = address(0);

    address public immutable borrower = address(0x2001);
    address public immutable lender1 = address(0x2002);
    address public immutable lender2 = address(0x2003);
    address public immutable liquidator = address(0x2004);
    address public immutable settler = address(0x2005);
    address public immutable disputer = address(0x2006);

    uint256[] internal lendingIds;
    mapping(uint256 => uint256) public openReportId; // lendingId -> reportId or 0 if no in-flight
    uint256[] internal seenReportIds;

    uint48 internal constant LOAN_TERM = 30 days;
    uint24 internal constant LIQUIDATION_THRESHOLD = 8e6;
    uint16 internal constant STAKE = 100;

    constructor(
        openLend _lending,
        openLendParamHashHelper _lendView,
        OpenOracle _oracle,
        MockERC20 _supplyToken,
        MockERC20 _borrowToken
    ) {
        lending = _lending;
        lendView = _lendView;
        oracle = _oracle;
        supplyToken = _supplyToken;
        borrowToken = _borrowToken;
    }

    function prime() external {
        address[6] memory accounts = [borrower, lender1, lender2, liquidator, settler, disputer];
        for (uint256 i = 0; i < accounts.length; i++) {
            supplyToken.transfer(accounts[i], 50_000 ether);
            borrowToken.transfer(accounts[i], 50_000 ether);
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

        vm.startPrank(liquidator);
        supplyToken.approve(address(lending), type(uint256).max);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(disputer);
        supplyToken.approve(address(oracle), type(uint256).max);
        borrowToken.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    function loanCount() external view returns (uint256) {
        return lendingIds.length;
    }

    function getLoanId(uint256 idx) external view returns (uint256) {
        return lendingIds[idx];
    }

    function reportCount() external view returns (uint256) {
        return seenReportIds.length;
    }

    function getReportId(uint256 idx) external view returns (uint256) {
        return seenReportIds[idx];
    }

    function createLoan(uint96 supplySeed, uint96 borrowSeed, uint64 maxBaseFeeSeed) external {
        if (lendingIds.length >= 16) return;

        uint128 supplyAmount = uint128(bound(supplySeed, 100 ether, 5_000 ether));
        uint128 maxBorrow = uint128((uint256(supplyAmount) * 70) / 100);
        if (maxBorrow == 0) return;
        uint128 borrowAmount = uint128(bound(borrowSeed, 1 ether, maxBorrow));

        vm.startPrank(borrower);
        try lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            supplyAmount,
            borrowAmount,
            STAKE,
            uint24(1e7),
            0,
            borrower,
            _oracleParams(maxBaseFeeSeed),
            _standardInterestRateParams()
        ) returns (uint256 lendingId) {
            lendingIds.push(lendingId);
        } catch {}
        vm.stopPrank();
    }

    function createNativeSupplyLoan(uint96 supplySeed, uint96 borrowSeed, uint64 maxBaseFeeSeed) external {
        if (lendingIds.length >= 16) return;

        uint128 supplyAmount = uint128(bound(supplySeed, 10 ether, 500 ether));
        uint128 maxBorrow = uint128((uint256(supplyAmount) * 70) / 100);
        if (maxBorrow == 0) return;
        uint128 borrowAmount = uint128(bound(borrowSeed, 1 ether, maxBorrow));

        vm.startPrank(borrower);
        try lending.requestBorrow{value: supplyAmount}(
            LOAN_TERM,
            ETH,
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            supplyAmount,
            borrowAmount,
            STAKE,
            uint24(1e7),
            0,
            borrower,
            _oracleParams(maxBaseFeeSeed),
            _standardInterestRateParams()
        ) returns (uint256 lendingId) {
            lendingIds.push(lendingId);
        } catch {}
        vm.stopPrank();
    }

    function createNativeBorrowLoan(uint96 supplySeed, uint96 borrowSeed, uint64 maxBaseFeeSeed) external {
        if (lendingIds.length >= 16) return;

        uint128 supplyAmount = uint128(bound(supplySeed, 10 ether, 500 ether));
        uint128 maxBorrow = uint128((uint256(supplyAmount) * 70) / 100);
        if (maxBorrow == 0) return;
        uint128 borrowAmount = uint128(bound(borrowSeed, 1 ether, maxBorrow));

        vm.startPrank(borrower);
        try lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            ETH,
            LIQUIDATION_THRESHOLD,
            supplyAmount,
            borrowAmount,
            STAKE,
            uint24(1e7),
            0,
            borrower,
            _oracleParams(maxBaseFeeSeed),
            _standardInterestRateParams()
        ) returns (uint256 lendingId) {
            lendingIds.push(lendingId);
        } catch {}
        vm.stopPrank();
    }

    function lendLoan(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        if (loan.cancelled || loan.active || loan.finished || !loan.curveOpen) return;

        address caller = (loanSeed & 1) == 0 ? lender1 : lender2;
        vm.startPrank(caller);
        if (loan.borrowToken == ETH) {
            try lending.lend{value: loan.principal}(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, caller) {}
            catch {}
        } else {
            try lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, caller) {} catch {}
        }
        vm.stopPrank();
    }

    function liquidateLoan(uint256 loanSeed, uint96 priceSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        if (loan.cancelled || loan.finished || !loan.active || loan.inLiquidation) return;
        if (loan.gracePeriod != 0) return;
        if (block.timestamp > uint256(loan.start) + loan.term) return;

        // priceRatio in 1e18 fixed-point; bound between 0.5e18 and 2e18 for sane oracle states
        uint256 priceRatio = bound(uint256(priceSeed), 5e17, 2e18);
        bytes32 paramHash = lendView.getParamHash(lendingId);
        uint256 initialLiquidity = uint256(loan.supplyAmount) * loan.oracleParams.initialLiquidity / 100;
        uint256 oracleAmount2 = initialLiquidity * priceRatio / 1e18;
        uint256 tokenStake = uint256(loan.supplyAmount) * loan.stake / 10000;
        uint256 msgValue = 1e15 + loan.oracleParams.finalizerReward;
        if (loan.supplyToken == ETH) msgValue += initialLiquidity + tokenStake;
        if (loan.borrowToken == ETH) msgValue += oracleAmount2;

        vm.startPrank(liquidator);
        try lending.liquidate{value: msgValue}(
            lendingId,
            priceRatio,
            type(uint128).max,
            paramHash,
            0,
            1e15, liquidator, loan.oracleParams.finalizerReward, _emptyTiming()
        ) {
            uint256 reportId = oracle.nextReportId() - 1;
            openReportId[lendingId] = reportId;
            seenReportIds.push(reportId);
        } catch {}
        vm.stopPrank();
    }

    function settleLatest(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        uint256 reportId = openReportId[lendingId];
        if (reportId == 0) return;

        // Make sure we're past the settlement window
        vm.warp(block.timestamp + 400);

        vm.startPrank(settler);
        try lending.finalize(lendingId) {
            if (!lendView.getLending(lendingId).inLiquidation) openReportId[lendingId] = 0;
        } catch {}
        vm.stopPrank();
    }

    function disputeOpenReport(uint256 loanSeed, uint96 amount2Seed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        uint256 reportId = openReportId[lendingId];
        if (reportId == 0) return;

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        if (game.settlementTimestamp != 0) return;
        if (block.timestamp >= uint256(game.reportTimestamp) + game.settlementTime) return;

        uint256 readyAt = uint256(game.reportTimestamp) + game.disputeDelay + 1;
        if (block.timestamp < readyAt) vm.warp(readyAt);
        if (block.timestamp >= uint256(game.reportTimestamp) + game.settlementTime) return;

        uint128 newAmount1 = uint128(uint256(game.currentAmount1) * game.multiplier / 100);
        uint128 newAmount2 = uint128(bound(uint256(amount2Seed), 1, uint256(game.currentAmount2) * 2 + 1));
        if (newAmount2 >= game.currentAmount2) newAmount2 = uint128(uint256(game.currentAmount2) / 2 + 1);
        if (newAmount1 == 0 || newAmount2 == 0) return;

        uint256 msgValue;
        if (game.token1 == ETH) {
            uint256 protocolFee = uint256(game.currentAmount1) * game.protocolFee / 1e7;
            msgValue = uint256(newAmount1) + game.currentAmount1 + protocolFee;
        }

        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        vm.startPrank(disputer);
        try IOpenOracle2(address(oracle)).dispute{value: msgValue}(
            reportId,
            game.token1,
            newAmount1,
            newAmount2,
            disputer,
            false,
            false,
            game,
            helper, _emptyTiming()
        ) {} catch {}
        vm.stopPrank();
    }

    function openRefiDuringLiquidation(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || !loan.inLiquidation || loan.curveOpen) return;

        vm.startPrank(borrower);
        try lending.refinance(
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
        ) {} catch {}
        vm.stopPrank();
    }

    function settleOracleOnly(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        uint256 reportId = openReportId[lendingId];
        if (reportId == 0) return;

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        if (game.settlementTimestamp != 0) return;

        uint256 settleableAt = uint256(game.reportTimestamp) + game.settlementTime + 1;
        if (block.timestamp < settleableAt) vm.warp(settleableAt);
        try IOpenOracle2(address(oracle)).settle(reportId, game, _helperFor(reportId)) {} catch {}
    }

    function finalizeLatest(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        uint256 reportId = openReportId[lendingId];
        if (reportId == 0) return;

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        if (game.settlementTimestamp == 0) return;

        try lending.finalize(lendingId) {
            if (!lendView.getLending(lendingId).inLiquidation) openReportId[lendingId] = 0;
        } catch {}
    }

    function grabFeesLatest(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        uint256 reportId = openReportId[lendingId];
        if (reportId == 0 && seenReportIds.length > 0) reportId = seenReportIds[loanSeed % seenReportIds.length];
        if (reportId == 0) return;

        try lending.grabOracleGameFeesAny(lendingId, reportId) {} catch {}
    }

    function repayOrTopUp(uint256 loanSeed, uint96 amountSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        if (!loan.active || loan.finished || loan.cancelled || loan.inLiquidation) return;

        uint128 amount = uint128(bound(amountSeed, 1, 10 ether));
        vm.startPrank(borrower);
        if ((loanSeed & 1) == 0) {
            if (loan.borrowToken == ETH) {
                try lending.repayDebt{value: amount}(lendingId, amount, bytes32(0), 0, type(uint128).max) {}
                catch {}
            } else {
                try lending.repayDebt(lendingId, amount, bytes32(0), 0, type(uint128).max) {} catch {}
            }
        } else {
            if (loan.supplyToken == ETH) {
                try lending.topUpCollateral{value: amount}(lendingId, amount, bytes32(0), 0, type(uint128).max) {}
                catch {}
            } else {
                try lending.topUpCollateral(lendingId, amount, bytes32(0), 0, type(uint128).max) {} catch {}
            }
        }
        vm.stopPrank();
    }

    function advanceTime(uint32 timeSeed) external {
        uint256 jump = bound(uint256(timeSeed), 1 hours, 3 days);
        vm.warp(block.timestamp + jump);
    }

    function advanceBaseFee(uint64 feeSeed) external {
        vm.fee(bound(uint256(feeSeed), 0, 500 gwei));
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
            finalizerReward: 0
        });
    }

    function _oracleParams(uint64 maxBaseFeeSeed) internal pure returns (openLend.OracleParams memory p) {
        p = _standardOracleParams();
        if (maxBaseFeeSeed != 0) {
            p.maxBaseFee = uint48(bound(uint256(maxBaseFeeSeed), 1 gwei, 500 gwei));
            p.finalizerReward = uint64(bound(uint256(maxBaseFeeSeed), 1 wei, 0.01 ether));
        }
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
            finalizerReward: 0
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

    function _emptyTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory timing) {}

    function _helperFor(uint256 reportId) internal view returns (IOpenOracle2.PreimageHelper memory ph) {
        IOpenOracle2.StoredHelper memory sh = IOpenOracle2(address(oracle)).storedHelper(reportId);
        ph.reportId = reportId;
        ph.creator = sh.creator;
        ph.blockTimestamp = sh.blockTimestamp;
        ph.blockNumber = sh.blockNumber;
    }
}

contract LiquidationInvariantsTest is StdInvariant, Test {
    openLend internal lending;
    openLendParamHashHelper internal lendView;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken;
    MockERC20 internal borrowToken;
    LiquidationInvariantHandler internal handler;

    function setUp() public {
        oracle = new OpenOracle();
        MockWETH weth = new MockWETH();
        lending = new openLend(IOpenOracle2(address(oracle)), address(weth));
        lendView = new openLendParamHashHelper(lending, IOpenOracle2(address(oracle)));
        supplyToken = new MockERC20("Supply Token", "SUP");
        borrowToken = new MockERC20("Borrow Token", "BOR");

        handler = new LiquidationInvariantHandler(lending, lendView, oracle, supplyToken, borrowToken);
        supplyToken.transfer(address(handler), 300_000 ether);
        borrowToken.transfer(address(handler), 300_000 ether);
        handler.prime();
        targetContract(address(handler));
    }

    /// @notice After settlement the loan must NOT remain in `inLiquidation`.
    function invariant_settlementClearsInLiquidation() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
            if (handler.openReportId(lendingId) == 0) {
                // No in-flight liq tracked for this loan → must not be inLiquidation
                assertFalse(loan.inLiquidation, "no tracked report but inLiquidation == true");
            }
        }
    }

    /// @notice A finished loan must not have an in-flight oracle report tracked.
    function invariant_finishedHasNoOpenReport() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
            if (loan.finished) {
                assertEq(handler.openReportId(lendingId), 0, "finished loan should have no tracked report");
            }
        }
    }

    /// @notice Once openLend has cleared a report mapping, its fee receiver should not retain sweepable fees.
    function invariant_clearedReportsHaveNoSweepableFeeReceiverBalance() public view {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (lending.reportIdToLending(reportId) != 0) continue;

            address predicted = Clones.predictDeterministicAddress(
                lending.feeReceiverImpl(), bytes32(reportId), address(lending)
            );
            if (predicted.code.length == 0) continue;

            oracleFeeReceiver feeReceiver = oracleFeeReceiver(predicted);
            assertLe(oracle.tokenHolder(predicted, feeReceiver.token1()), 1, "cleared fee receiver token1 dust only");
            assertLe(oracle.tokenHolder(predicted, feeReceiver.token2()), 1, "cleared fee receiver token2 dust only");
        }
    }

    /// @notice The contract's supply balance always covers active-loan supplyAmounts plus in-flight liquidator stakes.
    ///         Native ETH accounting also covers any finalizer rewards escrowed for in-flight liquidations.
    function invariant_contractSupplyCoversActiveLoansAndStakes() public view {
        uint256 count = handler.loanCount();
        uint256 requiredErc20;
        uint256 requiredNative;
        uint256 requiredFinalizerRewards;
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
            if (!loan.cancelled && !loan.finished) {
                uint256 required = loan.supplyAmount;
                if (loan.inLiquidation) {
                    required += (uint256(loan.supplyAmount) * loan.stake) / 10000;
                    requiredFinalizerRewards += loan.oracleParams.finalizerReward;
                }
                if (loan.supplyToken == address(0)) {
                    requiredNative += required;
                } else {
                    requiredErc20 += required;
                }
            }
        }
        assertEq(
            supplyToken.balanceOf(address(lending)),
            requiredErc20,
            "contract supplyToken balance should reconcile to active loans + in-flight stakes"
        );
        assertGe(
            address(lending).balance,
            requiredNative + requiredFinalizerRewards,
            "contract ETH balance should cover native collateral, stakes, and finalizer rewards"
        );
    }

    /// @notice Amortization-state invariant for loans driven through the liquidation handler:
    ///         interestPaid is bounded by the lender's interest claim (`max(commitmentInterest, interestAccrued)`)
    ///         and lastTouch never advances past `start + term`. Note: `principal + interestAccrued` is NOT a lower
    ///         bound on `interestPaid` — borrowers can prepay into the floor surplus, which is why
    ///         `_liquidationOwed` clamps explicitly at 0.
    function invariant_amortStateConsistent() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
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
}
