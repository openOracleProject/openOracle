// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";
import {openLend} from "./openLend.sol";
import {oracleFeeReceiver} from "./openLendFeeReceiver.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract openLendDataProvider {
    uint256 internal constant ACCRUAL_DENOM = 1e9 * 365 days;

    openLend public immutable lending;
    IOpenOracle2 public immutable oracle;

    constructor(openLend _lending, IOpenOracle2 _oracle) {
        lending = _lending;
        oracle = _oracle;
    }

    function getLending(uint256 lendingId) external view returns (openLend.LendingArrangement memory) {
        return _getLending(lendingId);
    }

    function getLending(uint256[] calldata lendingIds)
        external
        view
        returns (openLend.LendingArrangement[] memory lendings)
    {
        lendings = new openLend.LendingArrangement[](lendingIds.length);
        for (uint256 i; i < lendingIds.length; ++i) {
            lendings[i] = _getLending(lendingIds[i]);
        }
    }

    function getLending(uint256 startId, uint256 count)
        external
        view
        returns (openLend.LendingArrangement[] memory lendings)
    {
        lendings = new openLend.LendingArrangement[](count);
        for (uint256 i; i < count; ++i) {
            lendings[i] = _getLending(startId + i);
        }
    }

    function getRefiParams(uint256 lendingId) external view returns (openLend.RefiParams memory) {
        openLend.LendingArrangement memory l = _getLending(lendingId);
        return l.refiParams;
    }

    function getOracleParams(uint256 lendingId) external view returns (openLend.OracleParams memory) {
        openLend.LendingArrangement memory l = _getLending(lendingId);
        return l.oracleParams;
    }

    function getRateParams(uint256 lendingId) external view returns (openLend.InterestRateParams memory) {
        openLend.LendingArrangement memory l = _getLending(lendingId);
        return l.interestRateParams;
    }

    struct Beneficiaries {
        address borrower;
        address lender;
        address liquidator;
    }

    function getBeneficiaries(uint256 lendingId, address feeRecipient) external view returns (Beneficiaries memory b) {
        oracleFeeReceiver receiver = oracleFeeReceiver(feeRecipient);
        if (receiver.lendingId() != lendingId) return b;
        b.borrower = receiver.borrower();
        b.lender = receiver.lender();
        b.liquidator = receiver.liquidator();
    }

    /// Active oracle game per lendingId in one call: reportIds[i] is the loan's live report
    /// (lendingToReportId, 0 when not in liquidation) and games[i] its storedGame (zeroed when none).
    function getOracleGames(uint256[] calldata lendingIds)
        external
        view
        returns (uint256[] memory reportIds, IOpenOracle2.OracleGame[] memory games)
    {
        reportIds = new uint256[](lendingIds.length);
        games = new IOpenOracle2.OracleGame[](lendingIds.length);
        for (uint256 i; i < lendingIds.length; ++i) {
            uint256 reportId = lending.lendingToReportId(lendingIds[i]);
            reportIds[i] = reportId;
            if (reportId != 0) games[i] = oracle.storedGame(reportId);
        }
    }

    /// Raw storedGame batch keyed by reportId, for callers that already hold report ids.
    function getStoredGames(uint256[] calldata reportIds)
        external
        view
        returns (IOpenOracle2.OracleGame[] memory games)
    {
        games = new IOpenOracle2.OracleGame[](reportIds.length);
        for (uint256 i; i < reportIds.length; ++i) {
            games[i] = oracle.storedGame(reportIds[i]);
        }
    }

    /// Delegation state per lendingId in one call: the borrower's refi delegate and the current
    /// lender's netting delegate (address(0) when unset).
    function getDelegates(uint256[] calldata lendingIds)
        external
        view
        returns (address[] memory refiDelegates, address[] memory lenderDelegates)
    {
        refiDelegates = new address[](lendingIds.length);
        lenderDelegates = new address[](lendingIds.length);
        for (uint256 i; i < lendingIds.length; ++i) {
            refiDelegates[i] = lending.refiDelegation(lendingIds[i]);
            lenderDelegates[i] = lending.lenderDelegation(lendingIds[i]);
        }
    }

    struct FeeReceiverState {
        address feeReceiver;
        uint256 reportId;
        bool deployed;
        uint256 fees1Pending; // spendable token1 fees on the clone, sentinel excluded
        uint256 fees2Pending;
    }

    /// Fee receiver for a loan's live liquidation, with pending fee balances. Zeroed when the loan is
    /// not in liquidation; `deployed` is false when no clone exists (oracleGameFee == 0). Clone args
    /// are rebuilt from current storage, which a live liquidation freezes; for past liquidations use
    /// predictFeeReceiverWithArgs with the LoanLiquidationUnderway snapshot.
    function getFeeReceiver(uint256 lendingId) public view returns (FeeReceiverState memory s) {
        uint256 reportId = lending.lendingToReportId(lendingId);
        if (reportId == 0) return s;
        openLend.LendingArrangement memory l = _getLending(lendingId);
        bytes memory args =
            abi.encodePacked(lendingId, l.supplyToken, l.borrowToken, l.borrower, l.lender, l.liquidator);
        address predicted =
            LibClone.predictDeterministicAddress(lending.feeReceiverImpl(), args, bytes32(reportId), address(lending));
        s.feeReceiver = predicted;
        s.reportId = reportId;
        s.deployed = predicted.code.length > 0;
        if (s.deployed) {
            uint256 bal1 = oracle.tokenHolder(predicted, l.supplyToken);
            uint256 bal2 = oracle.tokenHolder(predicted, l.borrowToken);
            s.fees1Pending = bal1 > 1 ? bal1 - 1 : 0;
            s.fees2Pending = bal2 > 1 ? bal2 - 1 : 0;
        }
    }

    function getFeeReceivers(uint256[] calldata lendingIds)
        external
        view
        returns (FeeReceiverState[] memory states)
    {
        states = new FeeReceiverState[](lendingIds.length);
        for (uint256 i; i < lendingIds.length; ++i) {
            states[i] = getFeeReceiver(lendingIds[i]);
        }
    }

    /// CREATE2 math for callers holding a historical snapshot (from LoanLiquidationUnderway).
    function predictFeeReceiverWithArgs(
        uint256 reportId,
        uint256 lendingId,
        address token1,
        address token2,
        address borrower,
        address lender_,
        address liquidator
    ) external view returns (address) {
        bytes memory args = abi.encodePacked(lendingId, token1, token2, borrower, lender_, liquidator);
        return
            LibClone.predictDeterministicAddress(lending.feeReceiverImpl(), args, bytes32(reportId), address(lending));
    }

    enum FinalizeOutcome {
        None, // not in liquidation
        Pending, // report still disputable; autoSettle is a no-op
        Restore, // finalize would fail the liquidation and restore the loan
        Liquidate // finalize would liquidate
    }

    struct FinalizeState {
        FinalizeOutcome outcome;
        uint256 settleableAt;
        uint48 projectedGracePeriod; // grace a Restore would set; 0 when none
    }

    /// Mirrors _finalize/_executeLiquidation's decision at the current block, including the basefee gate.
    function getFinalizeState(uint256[] calldata lendingIds) external view returns (FinalizeState[] memory states) {
        states = new FinalizeState[](lendingIds.length);
        for (uint256 i; i < lendingIds.length; ++i) {
            uint256 lendingId = lendingIds[i];
            openLend.LendingArrangement memory l = _getLending(lendingId);
            if (!l.inLiquidation) continue;
            uint256 reportId = lending.lendingToReportId(lendingId);
            if (reportId == 0) {
                states[i].outcome = FinalizeOutcome.Pending;
                continue;
            }
            IOpenOracle2.OracleGame memory game = oracle.storedGame(reportId);
            uint256 settleableAt = uint256(game.reportTimestamp) + game.settlementTime;
            states[i].settleableAt = settleableAt;
            if (block.timestamp < settleableAt) {
                states[i].outcome = FinalizeOutcome.Pending;
                continue;
            }
            uint256 borrowValueInSupplyTerms = Math.mulDiv(_amountOwed(l), game.currentAmount1, game.currentAmount2);
            uint256 liqThresh = uint256(l.supplyAmount) * l.liquidationThreshold / 1e7;
            uint256 originalAmount1 = uint256(l.supplyAmount) * l.oracleParams.initialLiquidity / 100;
            bool baseFeeOk = l.oracleParams.maxBaseFee == 0
                || block.basefee <= Math.mulDiv(l.oracleParams.maxBaseFee, game.currentAmount1, originalAmount1);
            if (liqThresh < borrowValueInSupplyTerms && baseFeeOk) {
                states[i].outcome = FinalizeOutcome.Liquidate;
            } else {
                states[i].outcome = FinalizeOutcome.Restore;
                if (settleableAt > uint256(l.start) + l.term - 1800) {
                    states[i].projectedGracePeriod = uint48(1800 + (settleableAt - l.liquidationStart));
                }
            }
        }
    }

    /// Live closeout debt per loan; 0 for loans that are not active or already finished.
    function getAmountOwed(uint256[] calldata lendingIds) external view returns (uint256[] memory owed) {
        owed = new uint256[](lendingIds.length);
        for (uint256 i; i < lendingIds.length; ++i) {
            openLend.LendingArrangement memory l = _getLending(lendingIds[i]);
            if (!l.active || l.finished) continue;
            owed[i] = _amountOwed(l);
        }
    }

    function _amountOwed(openLend.LendingArrangement memory l) internal view returns (uint256) {
        uint256 termEnd = uint256(l.start) + l.term;
        uint256 nowCapped = block.timestamp > termEnd ? termEnd : block.timestamp;
        uint256 lastTouch = l.lastTouch == 0 ? uint256(l.start) : uint256(l.lastTouch);
        uint256 accrued = l.interestAccrued;
        if (nowCapped > lastTouch) {
            accrued += (uint256(l.principal) * (nowCapped - lastTouch) * l.rate + l.interestRemainder) / ACCRUAL_DENOM;
        }
        uint256 claim = accrued > l.commitmentInterest ? accrued : l.commitmentInterest;
        return uint256(l.principal) + claim - l.interestPaid;
    }

    // debugging helper only, do not use this to calculate the param hash in an integration, rather, calculate using each individual value in the state.
    function getParamHash(uint256 lendingId) external view returns (bytes32) {
        openLend.LendingArrangement memory copy = _getLending(lendingId);

        copy.supplyAmount = 0;
        copy.principal = 0;
        copy.interestAccrued = 0;
        copy.interestRemainder = 0;
        copy.interestPaid = 0;
        copy.lastTouch = 0;
        copy.requestStart = 0;
        copy.inLiquidation = false;
        copy.liquidationStart = 0;
        copy.liquidator = address(0);
        copy.gracePeriod = 0;
        return keccak256(abi.encode(copy));
    }

    // debugging helper only, same caveat as getParamHash. Matches _checkParamsLiquidate: the loose
    // zeroing plus refiParams, curveOpen, gasCompensation, and interestRateParams.
    function getLiquidateParamHash(uint256 lendingId) external view returns (bytes32) {
        openLend.LendingArrangement memory copy = _getLending(lendingId);

        copy.supplyAmount = 0;
        copy.principal = 0;
        copy.interestAccrued = 0;
        copy.interestRemainder = 0;
        copy.interestPaid = 0;
        copy.lastTouch = 0;
        copy.requestStart = 0;
        copy.inLiquidation = false;
        copy.liquidationStart = 0;
        copy.liquidator = address(0);
        copy.gracePeriod = 0;
        copy.gasCompensation = 0;
        copy.curveOpen = false;
        delete copy.refiParams;
        delete copy.interestRateParams;
        return keccak256(abi.encode(copy));
    }

    function _getLending(uint256 lendingId) internal view returns (openLend.LendingArrangement memory l) {
        (
            l.supplyAmount,
            l.principal,
            l.interestAccrued,
            l.interestRemainder,
            l.lastTouch,
            l.liquidatorFraction,
            l.interestPaid,
            l.commitmentInterest,
            l.borrower,
            l.term,
            l.start,
            l.lender,
            l.gasCompensation,
            l.liquidator,
            l.liquidationStart,
            l.gracePeriod,
            l.supplyToken,
            l.requestStart,
            l.liquidationThreshold,
            l.commitmentFraction,
            l.borrowToken,
            l.rate,
            l.stake,
            l.cancelled,
            l.active,
            l.inLiquidation,
            l.finished,
            l.curveOpen,
            l.refiParams,
            l.oracleParams,
            l.interestRateParams
        ) = lending.lendingArrangements(lendingId);
    }
}
