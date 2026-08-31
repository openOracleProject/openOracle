// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library PuntErrors {
    error TokensCannotBeSame();
    error EthTransferFailed();
    error InvalidAmount1();
    error AddressCannotBeZero();
    error ContractCannotBeParticipant();
    error AmountsCannotBeZero();
    error InvalidMsgValue();
    error ZeroAmount();
    error InvalidExpiration();
    error InvalidExecutionLatency();
    error InvalidLifecycleModule();
    error InvalidFeeReceiver();
    error InvalidSelector();
    error InvalidLiquidationHeartbeat();
    error LiquidationHeartbeatLive();
    error ForcedTransaction();
    error InvalidFulfillFee();
    error InvalidSlippage();
    error InvalidOracleParams();
    error InvalidFulfillFeeParams();
    error WrongHash();
    error WrongOracleHash();
    error NotActive();
    error Expired();
    error NotSwapper();
    error NotMatched();
    error CantBailOutYet();
    error NothingToWithdraw();
    error OracleSettlementNotEligible();
    error MustBeZero();

    error InvalidMaturity();
    error MaturityNotReached();
    error InvalidMargin();
    error InvalidFundingRate();
    error InvalidReportId();
    error InvalidSettlementLookback();
    error NoOracleGame();
    error OracleGameInProgress();
    error CloseIntentLive();
    error InvalidDutchParams();
}
