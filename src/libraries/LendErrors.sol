// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library LendErrors {
    error SupplyEqualsBorrow();
    error AddressCannotBeZero();
    error LiquidationThresholdOutOfBounds();
    error StakeTooHigh();
    error TermOutOfBounds();
    error SupplyPlusStakeTooHigh();
    error MsgValue();
    error CommitmentFractionTooHigh();
    error ResidualOverflow();

    error Cancelled();
    error Finished();
    error LendingIdActive();
    error NotActive();
    error NotBorrower();
    error InvalidSender();
    error MsgSender();
    error InLiquidation();
    error NotInLiquidation();
    error InGracePeriod();
    error Expired();
    error NotExpired();

    error CurveIsOpen();
    error CurveIsNotOpen();
    error LiquidatorFractionTooHigh();
    error MinRate();
    error MinSupply();
    error SupplyTooLow();
    error PrincipalTooHigh();
    error LendAmountOutOfBounds();
    error SupplyPulledTooHigh();

    error Amount2TooLarge();
    error EscalationHaltTooHigh();
    error TokenStakePlusSupplyAmountTooLarge();
    error PositionTooHealthy();
    error TooMuchOracleGameInitialLiquidity();
    error InitialReportNotLiquidationEligible();
    error SettlerRewardTooLow();
    error FinalizerRewardMismatch();
    error NoNetBorrow();
    error ReportIdsDontMatch();
    error WrongReportId();
    error NoLendingIdForReportId();
    error ReportStillDisputable();

    error NoFeeReceiver();
    error FeeRecipientNotForLendingId();
    error InterestRateParams();
    error OracleParams();
    error Params();

    error ZeroAmount();
}
