// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OpenOracle as Slim} from "../../src/OpenOracleSlim.sol";

// Pre-hash-refactor CreateReportParams shape, kept as a convenience for tests
// written against the old oracle.report() signature. The new oracle.report() takes a full
// OracleGame as calldata; reportRaw() below builds it from this lighter struct + amounts.
library CompatTypes {
    struct CreateReportParams {
        uint128 escalationHalt;
        address token1Address;
        uint96 settlerReward;
        address token2Address;
        uint48 settlementTime;
        uint24 disputeDelay;
        uint24 protocolFee;
        uint32 callbackGasLimit;
        uint24 feePercentage;
        uint16 multiplier;
        address callbackContract;
        address protocolFeeRecipient;
        uint8 flags;
    }

    /// @dev Mirrors the pre-hash-refactor `oracle.report(params, a1, a2, reporter, tib1, tib2, timing)`
    ///      shape so tests can stay readable. Internally builds the OracleGame and calls the new oracle.
    function reportRaw(
        Slim oracle,
        uint256 value,
        CreateReportParams memory params,
        uint128 amount1,
        uint128 amount2,
        address reporter,
        bool tib1,
        bool tib2,
        Slim.TimingBoundaries memory timing
    ) internal returns (uint256 reportId) {
        Slim.OracleGame memory input;
        input.token1 = params.token1Address;
        input.token2 = params.token2Address;
        input.feePercentage = params.feePercentage;
        input.multiplier = params.multiplier;
        input.settlementTime = params.settlementTime;
        input.escalationHalt = params.escalationHalt;
        input.disputeDelay = params.disputeDelay;
        input.protocolFee = params.protocolFee;
        input.settlerReward = params.settlerReward;
        input.callbackContract = params.callbackContract;
        input.callbackGasLimit = params.callbackGasLimit;
        input.protocolFeeRecipient = params.protocolFeeRecipient;
        input.flags = params.flags;
        input.currentAmount1 = amount1;
        input.currentAmount2 = amount2;
        input.currentReporter = reporter;
        return oracle.report{value: value}(input, tib1, tib2, timing);
    }
}
