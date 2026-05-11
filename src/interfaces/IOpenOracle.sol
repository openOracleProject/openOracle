// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IOpenOracle {
    struct disputeRecord {
        uint128 amount1;
        uint128 amount2;
        address tokenToSwap;
        uint48 reportTimestamp;
    }

    struct extraReportData {
        bytes32 stateHash;
        address callbackContract;
        uint32 numReports;
        uint32 callbackGasLimit;
        address protocolFeeRecipient;
        bool trackDisputes;
    }

    struct ReportMeta {
        uint128 exactToken1Report;
        uint128 escalationHalt;
        uint96 fee;
        uint96 settlerReward;
        address token1;
        uint48 settlementTime;
        address token2;
        bool timeType;
        uint24 feePercentage;
        uint24 protocolFee;
        uint16 multiplier;
        uint24 disputeDelay;
    }

    struct ReportStatus {
        uint128 currentAmount1;
        uint128 currentAmount2;
        address payable currentReporter;
        uint48 reportTimestamp;
        uint48 settlementTimestamp;
        address payable initialReporter;
        uint48 lastReportOppoTime;
    }

    struct CreateReportParams {
        uint128 exactToken1Report;
        uint128 escalationHalt;
        uint96 settlerReward;
        address token1Address;
        uint48 settlementTime;
        uint24 disputeDelay;
        uint24 protocolFee;
        address token2Address;
        uint32 callbackGasLimit;
        uint24 feePercentage;
        uint16 multiplier;
        bool timeType;
        bool trackDisputes;
        address callbackContract;
        address protocolFeeRecipient;
    }

    function createReportInstance(CreateReportParams calldata params) external payable returns (uint256 reportId);

    function submitInitialReport(
        uint256 reportId,
        uint128 amount1,
        uint128 amount2,
        bytes32 stateHash
    ) external;

    function submitInitialReport(
        uint256 reportId,
        uint128 amount1,
        uint128 amount2,
        bytes32 stateHash,
        address reporter
    ) external;

    function disputeAndSwap(
        uint256 reportId,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        uint128 amt2Expected,
        bytes32 stateHash
    ) external;

    function disputeAndSwap(
        uint256 reportId,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        address disputer,
        uint128 amt2Expected,
        bytes32 stateHash
    ) external;

    function getProtocolFees(
        address tokenToGet
    ) external;

    function getETHProtocolFees() external returns (uint256);

    function settle(uint256 id) external;

    function getSettlementData(uint256 id) external view returns (uint256 price, uint256 settlementTimestamp);

    function nextReportId() external view returns (uint256);

    function reportMeta(uint256 id) external view returns (ReportMeta memory);

    function reportStatus(uint256 id) external view returns (ReportStatus memory);

    function extraData(uint256 id) external view returns (extraReportData memory);
}
