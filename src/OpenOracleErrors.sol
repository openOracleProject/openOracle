// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

abstract contract OpenOracleErrors {
    error TokensCannotBeSame();
    error NoReportToDispute();
    error EthTransferFailed();
    error InvalidAmount1();
    error InvalidAmount2();
    error InvalidStateHash();
    error InvalidGasLimit();
    error SettleTooEarly();
    error AlreadySettled();
    error ExactToken1CannotBeZero();
    error SettleVsDisputeDelayTiming();
    error MsgValueTooLow();
    error MsgValueTooHigh();
    error FeesTooHigh();
    error MultiplierTooLow();
    error ReportAlreadySubmitted();
    error InvalidReportId();
    error AddressCannotBeZero();
    error InvalidAmount2Expected();
    error InvalidTokenToSwap();
    error NoReportYet();
    error EscalationHalted();
    error AmountsCannotBeZero();
    error DisputeTooLate();
    error DisputeTooEarly();
    error NewPriceInsideFeeBoundary();
    error ReportNotSettled();
    error InvalidMode();
    error InvalidTiming();
    error Permit2AmountMismatch();
    error InsufficientInternalBalance();
    error InsufficientInternalAllowance();
    error NeitherTokenIsETH();
    error InvalidMsgValue();
    error TimestampsMustBeZero();
    error NumReportsMustBeZero();
}
