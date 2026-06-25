// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "./interfaces/IOpenOracle2.sol";
import {openLend} from "./openLend.sol";

contract openLendParamHashHelper {
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

    function getBeneficiaries(uint256 lendingId, address feeRecipient)
        external
        view
        returns (openLend.Beneficiaries memory b)
    {
        (b.lender, b.liquidator) = lending.lendingBeneficiaries(lendingId, feeRecipient);
    }

    function getParamHash(uint256 lendingId) external view returns (bytes32) {
        openLend.LendingArrangement memory copy = _getLending(lendingId);

        uint256 currentTime = block.timestamp;

        if (copy.inLiquidation) {
            uint256 reportId = lending.lendingToReportId(lendingId);
            if (reportId != 0) {
                IOpenOracle2.OracleGame memory rs = oracle.storedGame(reportId);
                // Mirror finalize: the loan auto-finalizes once its report can no longer be disputed
                // (window taken from the oracle game state), whether or not oracle.settle has run.
                uint256 settleableAt = uint256(rs.reportTimestamp) + rs.settlementTime;
                if (currentTime >= settleableAt) {
                    uint256 tokenStake = uint256(copy.supplyAmount) * copy.stake / 10000;

                    if (copy.curveOpen) {
                        copy.requestStart = uint48(settleableAt);
                    }

                    if (settleableAt > uint256(copy.start) + copy.term - 1800) {
                        copy.gracePeriod = uint48(1800 + (settleableAt - copy.liquidationStart) * 2);
                        uint256 lenderStakePiece = tokenStake / 2;
                        copy.supplyAmount += uint128(tokenStake - lenderStakePiece);
                    } else {
                        copy.supplyAmount += uint128(tokenStake);
                    }

                    copy.inLiquidation = false;
                    copy.liquidationStart = 0;
                    copy.liquidator = address(0);
                }
            }
        }

        copy.supplyAmount = 0;
        copy.principal = 0;
        copy.interestAccrued = 0;
        copy.interestRemainder = 0;
        copy.interestPaid = 0;
        copy.lastTouch = 0;
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
