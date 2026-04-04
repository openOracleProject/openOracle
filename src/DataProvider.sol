// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle} from "./interfaces/IOpenOracle.sol";

contract openOracleDataProviderV3 {
    /* ─── immutables & constants ────────────────────────────── */
    IOpenOracle public immutable oracle;
    uint256 constant PRICE_PRECISION = 1e18;

    /* ─── constructor ──────────────────────────────────────── */
    constructor(address oracleAddress) {
        require(oracleAddress != address(0), "oracle 0");
        oracle = IOpenOracle(oracleAddress);
    }

    struct botStruct {
        //reportId
        uint256 reportId;
        //reportMeta
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
        //reportStatus
        uint128 currentAmount1;
        uint128 currentAmount2;
        uint256 price;
        address payable currentReporter;
        uint48 reportTimestamp;
        uint48 settlementTimestamp;
        address payable initialReporter;
        uint48 lastReportOppoTime;
        //extraData
        bytes32 stateHash;
        address callbackContract;
        uint32 numReports;
        uint32 callbackGasLimit;
        bytes4 callbackSelector;
        bool trackDisputes;
        address protocolFeeRecipient;
    }

    function _buildBotStruct(uint256 reportId) internal view returns (botStruct memory) {
        IOpenOracle.ReportMeta memory _reportMeta = oracle.reportMeta(reportId);
        IOpenOracle.ReportStatus memory _reportStatus = oracle.reportStatus(reportId);
        IOpenOracle.extraReportData memory _reportExtra = oracle.extraData(reportId);

        uint256 price = _reportStatus.currentAmount2 > 0
            ? (_reportStatus.currentAmount1 * PRICE_PRECISION) / _reportStatus.currentAmount2
            : 0;

        return botStruct(
            reportId,
            _reportMeta.exactToken1Report,
            _reportMeta.escalationHalt,
            _reportMeta.fee,
            _reportMeta.settlerReward,
            _reportMeta.token1,
            _reportMeta.settlementTime,
            _reportMeta.token2,
            _reportMeta.timeType,
            _reportMeta.feePercentage,
            _reportMeta.protocolFee,
            _reportMeta.multiplier,
            _reportMeta.disputeDelay,
            _reportStatus.currentAmount1,
            _reportStatus.currentAmount2,
            price,
            _reportStatus.currentReporter,
            _reportStatus.reportTimestamp,
            _reportStatus.settlementTimestamp,
            _reportStatus.initialReporter,
            _reportStatus.lastReportOppoTime,
            _reportExtra.stateHash,
            _reportExtra.callbackContract,
            _reportExtra.numReports,
            _reportExtra.callbackGasLimit,
            _reportExtra.callbackSelector,
            _reportExtra.trackDisputes,
            _reportExtra.protocolFeeRecipient
        );
    }

    function getData(uint256 reportId) external view returns (botStruct[] memory) {
        botStruct[] memory data = new botStruct[](1);
        data[0] = _buildBotStruct(reportId);
        return data;
    }

    function getData(uint256 startId, uint256 endId) external view returns (botStruct[] memory) {
        botStruct[] memory data = new botStruct[](endId - startId);
        for (uint256 i = 0; i < (endId - startId); i++) {
            data[i] = _buildBotStruct(startId + i);
        }
        return data;
    }

    function getData(uint256[] calldata reportIds) external view returns (botStruct[] memory) {
        botStruct[] memory data = new botStruct[](reportIds.length);
        for (uint256 i = 0; i < reportIds.length; i++) {
            data[i] = _buildBotStruct(reportIds[i]);
        }
        return data;
    }
}
