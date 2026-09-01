// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library SwapErrors {
    error TokensCannotBeSame();
    error EthTransferFailed();
    error InvalidMsgValue();
    error ZeroAmount();
    error InvalidExpiration();
    error InvalidFulfillFee();
    error InvalidSlippage();
    error InvalidOracleParams();
    error InvalidFulfillFeeParams();
    error MinOutInconsistent();
    error WrongHash();
    error WrongOracleHash();
    error InvalidID();
    error NotActive();
    error Expired();
    error NotSwapper();
    error NotMatched();
    error CantBailOutYet();
    error NothingToWithdraw();
    error OracleSettlementNotEligible();
    error MustBeZero();
}
