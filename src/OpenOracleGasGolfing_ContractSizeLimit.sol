// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OpenOracleErrors} from "./OpenOracleErrors.sol";

/**
 * @title OpenOracle
 * @notice A trust-free price oracle that uses an escalating auction mechanism
 * @dev This contract enables price discovery through economic incentives where
 *      expiration serves as evidence of a good price with appropriate parameters.
 *      Participants are responsible for validating report instance parameters before participation
 *      and unsafe parameter sets including but not limited to settlementTime too high and callbackGasLimit too high
 *      will result in lost funds.
 *
 *      Internal token balances use a virtual 1-unit sentinel. The sentinel is an accounting marker,
 *      not a required token deposit, and is excluded from withdrawable/spendable balances.
 * @author OpenOracle Team
 * @custom:version 0.1.6
 * @custom:documentation https://docs.openoracle.org
 */
contract OpenOracle is OpenOracleErrors {
    using SafeERC20 for IERC20;

    // Constants
    uint256 internal constant PRICE_PRECISION = 1e18;
    uint256 internal constant PERCENTAGE_PRECISION = 1e7;
    uint256 internal constant MULTIPLIER_PRECISION = 100;

    // State variables
    uint256 public nextReportId = 1;

    mapping(uint256 => OracleGame) public oracleGame;
    mapping(address => mapping(address => uint256)) public tokenHolder;
    mapping(address => uint256) public ethHolder;
    mapping(uint256 => mapping(uint256 => DisputeRecord)) public disputeHistory;
    mapping(bytes32 => bool) internal dustedPair;
    mapping(address => mapping(address => mapping(address => uint256))) public internalAllowance; // owner => spender => token => amount

    struct DisputeRecord {
        uint128 amount1;
        uint128 amount2;
        address tokenToSwap;
        uint48 reportTimestamp;
    }

    struct OracleGame {
        bytes32 stateHash;
        uint128 currentAmount1;
        uint128 currentAmount2;
        address payable currentReporter;
        uint48 reportTimestamp;
        uint48 settlementTimestamp;
        address payable initialReporter;
        uint48 lastReportOppoTime; // status
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
        uint24 disputeDelay; // meta
        address callbackContract;
        uint32 numReports;
        uint32 callbackGasLimit;
        bytes4 callbackSelector;
        address protocolFeeRecipient;
        bool trackDisputes; // extra data
    }

    struct PreimageHelper {
        uint256 reportId;
        bool isStorageMode;
        address creator;
        uint256 blockTimestamp;
        uint256 blockNumber;
    }

    struct TimingBoundaries {
        uint256 blockNumber;
        uint256 blockNumberBound;
        uint256 blockTimestamp;
        uint256 blockTimestampBound;
    }

    struct CreateReportParams {
        uint128 exactToken1Report; // initial oracle liquidity in token1
        uint128 escalationHalt; // amount of token1 at which escalation stops but disputes can still happen
        uint96 settlerReward; // eth paid to settler in wei
        address token1Address; // address of token1 in the oracle report instance
        uint48 settlementTime; // report instance can settle if no disputes within this timeframe
        uint24 disputeDelay; // time disputes must wait after every new report
        uint24 protocolFee; // fee paid to protocolFeeRecipient. 1000 = 0.01%
        address token2Address; // address of token2 in the oracle report instance
        uint32 callbackGasLimit; // gas the settlement callback must use
        uint24 feePercentage; // fee paid to previous reporter. 1000 = 0.01%
        uint16 multiplier; // amount by which newAmount1 must increase versus old amount1. 140 = 1.4x
        bool timeType; // true for block timestamp, false for block number
        bool trackDisputes; // true keeps a readable dispute history for smart contracts
        address callbackContract; // contract address for settle to call back into
        bytes4 callbackSelector; // method in the callbackContract you want called.
        address protocolFeeRecipient; // address that receives protocol fees
    }

    // Events
    event InitialReportSubmitted(
        uint256 indexed reportId, address indexed reporter, uint128 amount1, uint128 amount2, uint48 reportTimestamp
    );

    event ReportDisputed(
        uint256 indexed reportId,
        address indexed disputer,
        address indexed tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        uint48 reportTimestamp
    );

    event ReportInstanceCreated(uint256 indexed reportId, OracleGame gameParams, PreimageHelper helper);
    event InitialReportSubmittedHeavy(uint256 indexed reportId, OracleGame gameParams, PreimageHelper helper);
    event ReportDisputedHeavy(uint256 indexed reportId, OracleGame gameParams, PreimageHelper helper);
    event ReportSettled(uint256 indexed reportId);
    event ReportSettledHeavy(uint256 indexed reportId, OracleGame gameParams, PreimageHelper helper);
    event InternalApproval(address indexed owner, address indexed spender, address indexed token, uint256 amount);

    /**
     * @notice Creates a new report instance for price discovery.
     * @param params Report creation parameters
     * @param isStorageMode If true, stores full oracle state on-chain. If false, stores only the state hash and requires calldata preimages.
     * @dev Initial reporter reward is msg.value in wei minus settlerReward
     * @return reportId The unique identifier for the created report instance
     */
    function createReportInstance(CreateReportParams calldata params, bool isStorageMode)
        external
        payable
        returns (uint256 reportId)
    {
        reportId = _createReportInstance(params, isStorageMode);
    }
    /**
     * @dev Internal create helper. `isStorageMode=true` stores full oracle state; `false` stores only the state hash.
     * @param params Report creation parameters:
     *   - token1Address: Address of the first token
     *   - token2Address: Address of the second token
     *   - exactToken1Report: Exact amount of token1 required for the initial report.
     *   - feePercentage: Fee in thousandths of basis points (3000 = 0.03%)
     *   - multiplier: Dispute amount1 multiplier in percentage points (110 = 1.1x). newAmount1 = oldAmount1 * multipier / 100
     *   - settlementTime: Time before report can be settled
     *   - escalationHalt: Threshold at which multiplier disappears and newAmount1 = oldAmount1 + 1
     *   - disputeDelay: Delay in time before disputes are allowed
     *   - protocolFee: Protocol fee in thousandths of basis points (3000 = 0.03%)
     *   - settlerReward: Reward for settling the report in wei
     *   - timeType: If true: time in seconds, if false: blocks
     *   - callbackContract: Settle calls back into this address
     *   - callbackSelector: Settle callback uses this method
     *   - trackDisputes: Optional dispute tracking for smart contracts
     *   - callbackGasLimit: How much gas the callback must use. Must be safely < block gas limit or funds will be stuck
     *   - protocolFeeRecipient: Address that receives accrued protocol fees
     * @dev Initial reporter reward is msg.value in wei minus settlerReward
     * @return reportId The unique identifier for the created report instance
     */

    function _createReportInstance(CreateReportParams calldata params, bool isStorageMode)
        internal
        returns (uint256 reportId)
    {
        if (params.exactToken1Report == 0) revert ExactToken1CannotBeZero();
        if (params.token1Address == params.token2Address) revert TokensCannotBeSame();
        if (params.settlementTime < params.disputeDelay) revert SettleVsDisputeDelayTiming();
        if (msg.value < params.settlerReward) revert MsgValueTooLow();
        if (params.feePercentage + params.protocolFee > 1e7) revert FeesTooHigh();
        if (params.multiplier < MULTIPLIER_PRECISION) revert MultiplierTooLow();

        reportId = nextReportId++;
        OracleGame memory oracle = oracleGame[reportId];

        uint256 blockNumber = _getBlockNumber();

        uint96 reporterFee;
        if (msg.value > params.settlerReward) {
            if (msg.value > type(uint96).max) revert MsgValueTooHigh();
            reporterFee = uint96(msg.value) - params.settlerReward;
        }

        oracle.token1 = params.token1Address;
        oracle.token2 = params.token2Address;
        oracle.exactToken1Report = params.exactToken1Report;
        oracle.feePercentage = params.feePercentage;
        oracle.multiplier = params.multiplier;
        oracle.settlementTime = params.settlementTime;
        oracle.fee = reporterFee;
        oracle.escalationHalt = params.escalationHalt;
        oracle.disputeDelay = params.disputeDelay;
        oracle.protocolFee = params.protocolFee;
        oracle.settlerReward = params.settlerReward;
        oracle.timeType = params.timeType;
        oracle.callbackContract = params.callbackContract;
        oracle.callbackSelector = params.callbackSelector;
        oracle.trackDisputes = params.trackDisputes;
        oracle.callbackGasLimit = params.callbackGasLimit;
        oracle.protocolFeeRecipient = params.protocolFeeRecipient;

        PreimageHelper memory helper = PreimageHelper({
            reportId: reportId,
            isStorageMode: isStorageMode,
            creator: msg.sender,
            blockTimestamp: block.timestamp,
            blockNumber: blockNumber
        });

        bytes32 stateHash = _hashOracle(oracle, helper);
        oracle.stateHash = stateHash;

        if (isStorageMode) {
            oracleGame[reportId] = oracle;
        } else {
            oracleGame[reportId].stateHash = stateHash;
        }

        emit ReportInstanceCreated(reportId, oracle, helper);

        return reportId;
    }

    /**
     * @notice Submits the initial price report with a custom reporter address. Amounts use smallest unit for a given ERC-20.
     * @param reportId The unique identifier for the report
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Choose the amount of token2 that equals amount1 in value
     * @param reporter The address that will receive tokens back when settled or disputed
     * @param tryInternalBalance1 If true, tries to fund token1 from reporter's internal balance before pulling from msg.sender
     * @param tryInternalBalance2 If true, tries to fund token2 from reporter's internal balance before pulling from msg.sender
     * @dev Funds are returned to reporter. If msg.sender is not reporter, internal spends require reporter approval.
     * @dev This overload enables contracts to submit reports on behalf of users
     */
    function submitInitialReport(
        uint256 reportId,
        uint128 amount1,
        uint128 amount2,
        bytes32 stateHash,
        address reporter,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        TimingBoundaries calldata timing
    ) external {
        bool isStorageMode = _isStorageMode(reportId);
        if (!isStorageMode) revert InvalidMode();
        OracleGame memory empty;
        PreimageHelper memory empty2;

        _submitInitialReport(
            reportId,
            amount1,
            amount2,
            stateHash,
            reporter,
            isStorageMode,
            tryInternalBalance1,
            tryInternalBalance2,
            empty,
            empty2,
            timing
        );
    }

    function submitInitialReportCalldata(
        uint256 reportId,
        uint128 amount1,
        uint128 amount2,
        bytes32 stateHash,
        address reporter,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OracleGame calldata oracleGameData,
        PreimageHelper calldata preimageHelper,
        TimingBoundaries calldata timing
    ) external {
        bool isStorageMode = _isStorageMode(reportId);
        if (isStorageMode) revert InvalidMode();
        _submitInitialReport(
            reportId,
            amount1,
            amount2,
            stateHash,
            reporter,
            isStorageMode,
            tryInternalBalance1,
            tryInternalBalance2,
            oracleGameData,
            preimageHelper,
            timing
        );
    }

    function _submitInitialReport(
        uint256 reportId,
        uint128 amount1,
        uint128 amount2,
        bytes32 stateHash,
        address reporter,
        bool isStorageMode,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OracleGame memory params,
        PreimageHelper memory helper,
        TimingBoundaries memory timing
    ) internal {
        OracleGame memory oracle;

        if (isStorageMode) {
            oracle = oracleGame[reportId];
        } else {
            oracle = params;
            bytes32 preStateHash = _hashOracle(params, helper);
            if (preStateHash != oracleGame[reportId].stateHash) revert InvalidStateHash();
        }

        if (oracle.currentReporter != address(0)) {
            revert ReportAlreadySubmitted();
        }

        bool trackDisputes = oracle.trackDisputes;
        bool timeType = oracle.timeType;
        uint48 reportTimestamp = timeType ? uint48(block.timestamp) : _getBlockNumber();
        address token1 = oracle.token1;
        address token2 = oracle.token2;
        uint48 oppoTime = timeType ? _getBlockNumber() : uint48(block.timestamp);

        if (timing.blockTimestamp > 0) _validateTiming(timing);
        if (reportId >= nextReportId) revert InvalidReportId();
        if (amount1 != oracle.exactToken1Report) revert InvalidAmount1();
        if (amount2 == 0) revert InvalidAmount2();
        if (oracle.stateHash != stateHash) revert InvalidStateHash();
        if (reporter == address(0)) revert AddressCannotBeZero();

        oracle.currentAmount1 = amount1;
        oracle.currentAmount2 = amount2;
        oracle.currentReporter = payable(reporter);
        oracle.initialReporter = payable(reporter);
        oracle.reportTimestamp = reportTimestamp;
        oracle.lastReportOppoTime = oppoTime;

        if (trackDisputes) {
            DisputeRecord storage initialRecord = disputeHistory[reportId][0];
            initialRecord.amount1 = amount1;
            initialRecord.amount2 = amount2;
            initialRecord.reportTimestamp = reportTimestamp;
            oracle.numReports = 1;

            if (isStorageMode) {
                oracleGame[reportId].numReports = 1;
            }
        }

        if (isStorageMode) {
            // Storage mode keeps the original stateHash for legacy behavior;
            // only the mutated fields are persisted.
            OracleGame storage oracleStorage = oracleGame[reportId];
            oracleStorage.currentAmount1 = amount1;
            oracleStorage.currentAmount2 = amount2;
            oracleStorage.currentReporter = payable(reporter);
            oracleStorage.initialReporter = payable(reporter);
            oracleStorage.reportTimestamp = reportTimestamp;
            oracleStorage.lastReportOppoTime = oppoTime;
        } else {
            // Calldata mode rolls the stored stateHash forward to commit to the new state.
            bytes32 nextStateHash = _hashOracle(oracle, helper);
            oracle.stateHash = nextStateHash;
            oracleGame[reportId].stateHash = nextStateHash;
        }

        _getDustAmounts(reporter, token1, token2);
        _tryInternalBalanceFull(reporter, token1, amount1, tryInternalBalance1);
        _tryInternalBalanceFull(reporter, token2, amount2, tryInternalBalance2);

        if (isStorageMode) {
            emit InitialReportSubmitted(reportId, reporter, amount1, amount2, reportTimestamp);
        } else {
            emit InitialReportSubmittedHeavy(reportId, oracle, helper);
        }
    }

    /**
     * @notice Creates a storage-mode report instance and submits the initial report in one call.
     * @param params Report creation parameters
     * @param isStorageMode Must be true for this storage-mode entrypoint
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Choose the amount of token2 that equals amount1 in value
     * @param reporter The address that will receive tokens back when settled or disputed
     * @param tryInternalBalance1 If true, tries to fund token1 from reporter's internal balance before pulling from msg.sender
     * @param tryInternalBalance2 If true, tries to fund token2 from reporter's internal balance before pulling from msg.sender
     * @param timing Optional timing bounds. If timing.blockTimestamp is zero, timing validation is skipped.
     * @return reportId The unique identifier for the created report instance
     */
    function createAndReport(
        CreateReportParams calldata params,
        bool isStorageMode,
        uint128 amount1,
        uint128 amount2,
        address reporter,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        TimingBoundaries calldata timing
    ) external payable returns (uint256 reportId) {
        reportId = _createReportInstance(params, isStorageMode);
        if (!isStorageMode) revert InvalidMode();
        bytes32 createdStateHash = oracleGame[reportId].stateHash;
        OracleGame memory empty;
        PreimageHelper memory empty2;

        _submitInitialReport(
            reportId,
            amount1,
            amount2,
            createdStateHash,
            reporter,
            isStorageMode,
            tryInternalBalance1,
            tryInternalBalance2,
            empty,
            empty2,
            timing
        );
    }

    /**
     * @notice Creates a calldata-mode report instance and submits the initial report in one call.
     * @param params Report creation parameters
     * @param isStorageMode Must be false for this calldata-mode entrypoint
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Choose the amount of token2 that equals amount1 in value
     * @param reporter The address that will receive tokens back when settled or disputed
     * @param tryInternalBalance1 If true, tries to fund token1 from reporter's internal balance before pulling from msg.sender
     * @param tryInternalBalance2 If true, tries to fund token2 from reporter's internal balance before pulling from msg.sender
     * @param oracleGameData Full oracle state preimage for calldata mode
     * @param preimageHelper Helper preimage. reportId, blockTimestamp, and blockNumber are overwritten after creation.
     * @param timing Optional timing bounds. If timing.blockTimestamp is zero, timing validation is skipped.
     * @return reportId The unique identifier for the created report instance
     */
    function createAndReportCalldata(
        CreateReportParams calldata params,
        bool isStorageMode,
        uint128 amount1,
        uint128 amount2,
        address reporter,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OracleGame calldata oracleGameData,
        PreimageHelper calldata preimageHelper,
        TimingBoundaries calldata timing
    ) external payable returns (uint256 reportId) {
        reportId = _createReportInstance(params, isStorageMode);
        if (isStorageMode) revert InvalidMode();
        bytes32 createdStateHash = oracleGame[reportId].stateHash;
        OracleGame memory oracle = oracleGameData;
        oracle.stateHash = createdStateHash;
        PreimageHelper memory helper = preimageHelper;
        helper.reportId = reportId;
        helper.blockTimestamp = block.timestamp;
        helper.blockNumber = _getBlockNumber();

        _submitInitialReport(
            reportId,
            amount1,
            amount2,
            createdStateHash,
            reporter,
            isStorageMode,
            tryInternalBalance1,
            tryInternalBalance2,
            oracle,
            helper,
            timing
        );
    }

    /**
     * @notice Disputes an existing report with a custom disputer address. Amounts use smallest unit for a given ERC-20.
     * @param reportId The unique identifier for the report instance to dispute
     * @param tokenToSwap Token being swapped (token1 or token2). Disputer should choose token whose amount is lower valued
     * @param newAmount1 New amount of token1 after the dispute. Must respect contract escalation rules
     * @param newAmount2 New amount of token2 after the dispute. Choose the amount of token2 that equals newAmount1 in value
     * @param disputer The address that will receive tokens back when settled or disputed
     * @param amt2Expected currentAmount2 of the report instance you are disputing (not newAmount2)
     * @param stateHash state hash of the report instance you are disputing
     * @param tryInternalBalance1 If true, tries to fund token1 from disputer's internal balance before pulling from msg.sender
     * @param tryInternalBalance2 If true, tries to fund token2 from disputer's internal balance before pulling from msg.sender
     * @dev Funds are returned to disputer. If msg.sender is not disputer, internal spends require disputer approval.
     * @dev This overload enables contracts to submit disputes on behalf of users
     */
    function disputeAndSwap(
        uint256 reportId,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        address disputer,
        uint128 amt2Expected,
        bytes32 stateHash,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        TimingBoundaries calldata timing
    ) external {
        bool isStorageMode = _isStorageMode(reportId);
        if (!isStorageMode) revert InvalidMode();
        OracleGame memory empty;
        PreimageHelper memory empty2;
        _disputeAndSwap(
            reportId,
            tokenToSwap,
            newAmount1,
            newAmount2,
            disputer,
            amt2Expected,
            stateHash,
            isStorageMode,
            tryInternalBalance1,
            tryInternalBalance2,
            empty,
            empty2,
            timing
        );
    }

    function disputeAndSwapCalldata(
        uint256 reportId,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        address disputer,
        uint128 amt2Expected,
        bytes32 stateHash,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OracleGame calldata oracleGameData,
        PreimageHelper calldata preimageHelper,
        TimingBoundaries calldata timing
    ) external {
        bool isStorageMode = _isStorageMode(reportId);
        if (isStorageMode) revert InvalidMode();
        _disputeAndSwap(
            reportId,
            tokenToSwap,
            newAmount1,
            newAmount2,
            disputer,
            amt2Expected,
            stateHash,
            isStorageMode,
            tryInternalBalance1,
            tryInternalBalance2,
            oracleGameData,
            preimageHelper,
            timing
        );
    }

    function _disputeAndSwap(
        uint256 reportId,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        address disputer,
        uint128 amt2Expected,
        bytes32 stateHash,
        bool isStorageMode,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OracleGame memory params,
        PreimageHelper memory helper,
        TimingBoundaries calldata timing
    ) internal {
        OracleGame memory oracle;

        if (isStorageMode) {
            oracle = oracleGame[reportId];
        } else {
            oracle = params;
            bytes32 preStateHash = _hashOracle(params, helper);
            if (preStateHash != oracleGame[reportId].stateHash) revert InvalidStateHash();
        }

        (uint256 oldAmount1, uint256 oldAmount2) = (oracle.currentAmount1, oracle.currentAmount2);
        address token1 = oracle.token1;
        address token2 = oracle.token2;
        address previousReporter = oracle.currentReporter;
        bool timeType = oracle.timeType;
        uint48 currentTime = timeType ? uint48(block.timestamp) : _getBlockNumber();
        uint48 oppoTime = timeType ? _getBlockNumber() : uint48(block.timestamp);
        {
            uint256 feeSum = uint256(oracle.feePercentage) + uint256(oracle.protocolFee);
            uint48 prevReportTimestamp = oracle.reportTimestamp;
            uint256 escalationHalt = oracle.escalationHalt;
            uint256 expectedAmount1;
            if (escalationHalt > oldAmount1) {
                expectedAmount1 = (oldAmount1 * oracle.multiplier) / MULTIPLIER_PRECISION;
                if (expectedAmount1 > escalationHalt) {
                    expectedAmount1 = escalationHalt;
                }
            } else {
                expectedAmount1 = oldAmount1 + 1;
            }

            if (newAmount1 != expectedAmount1) {
                if (escalationHalt <= oldAmount1) {
                    revert EscalationHalted();
                } else {
                    revert InvalidAmount1();
                }
            }

            if (reportId >= nextReportId) revert InvalidReportId();
            if (newAmount1 == 0 || newAmount2 == 0) revert AmountsCannotBeZero();
            if (previousReporter == address(0)) revert NoReportToDispute();
            if (currentTime > prevReportTimestamp + oracle.settlementTime) revert DisputeTooLate();
            if (oracle.settlementTimestamp != 0) revert AlreadySettled();
            if (tokenToSwap != token1 && tokenToSwap != token2) revert InvalidTokenToSwap();
            if (currentTime < prevReportTimestamp + oracle.disputeDelay) revert DisputeTooEarly();
            if (feeSum > 0) _checkFeeBoundary(oldAmount1, oldAmount2, newAmount1, newAmount2, feeSum);
            if (oldAmount2 != amt2Expected) revert InvalidAmount2Expected();
            if (stateHash != oracle.stateHash) revert InvalidStateHash();
            if (disputer == address(0)) revert AddressCannotBeZero();
            if (timing.blockTimestamp > 0) _validateTiming(timing);
        }
        // Update report state after the dispute and swap
        {
            oracle.currentAmount1 = newAmount1;
            oracle.currentAmount2 = newAmount2;
            oracle.currentReporter = payable(disputer);
            oracle.reportTimestamp = currentTime;
            oracle.lastReportOppoTime = oppoTime;

            if (oracle.trackDisputes) {
                uint32 nextIndex = oracle.numReports;
                DisputeRecord storage record = disputeHistory[reportId][nextIndex];
                record.amount1 = newAmount1;
                record.amount2 = newAmount2;
                record.reportTimestamp = currentTime;
                record.tokenToSwap = tokenToSwap;
                oracle.numReports = nextIndex + 1;

                if (isStorageMode) {
                    oracleGame[reportId].numReports = nextIndex + 1;
                }
            }

            if (isStorageMode) {
                // Storage mode keeps the original stateHash for legacy behavior;
                // only the mutated fields are persisted.
                OracleGame storage oracleStorage = oracleGame[reportId];
                oracleStorage.currentAmount1 = newAmount1;
                oracleStorage.currentAmount2 = newAmount2;
                oracleStorage.currentReporter = payable(disputer);
                oracleStorage.reportTimestamp = currentTime;
                oracleStorage.lastReportOppoTime = oppoTime;
            } else {
                // Calldata mode rolls the stored stateHash forward to commit to the new state.
                bytes32 nextStateHash = _hashOracle(oracle, helper);
                oracle.stateHash = nextStateHash;
                oracleGame[reportId].stateHash = nextStateHash;
            }
        }

        bool isSelfDispute = (disputer == previousReporter && msg.sender == previousReporter);
        _getDustAmounts(disputer, token1, token2);
        if (tokenToSwap == token1) {
            uint256 fee = (oldAmount1 * oracle.feePercentage) / PERCENTAGE_PRECISION;
            uint256 protocolFee = (oldAmount1 * oracle.protocolFee) / PERCENTAGE_PRECISION;
            uint256 netToken2Contribution = newAmount2 >= oldAmount2 ? newAmount2 - oldAmount2 : 0;
            uint256 netToken2Receive = newAmount2 < oldAmount2 ? oldAmount2 - newAmount2 : 0;

            if (protocolFee > 0) {
                if (tokenHolder[oracle.protocolFeeRecipient][token1] == 0) {
                    tokenHolder[oracle.protocolFeeRecipient][token1] = 1;
                }
                tokenHolder[oracle.protocolFeeRecipient][token1] += protocolFee;
            }

            if (netToken2Contribution > 0) {
                _tryInternalBalanceFull(disputer, token2, netToken2Contribution, tryInternalBalance2);
            }

            if (netToken2Receive > 0) {
                tokenHolder[disputer][token2] += netToken2Receive;
            }

            if (isSelfDispute) {
                uint256 token1Contribution = newAmount1 - oldAmount1 + protocolFee;
                _tryInternalBalanceFull(disputer, token1, token1Contribution, tryInternalBalance1);
            } else {
                _tryInternalBalanceFull(
                    disputer, token1, newAmount1 + oldAmount1 + fee + protocolFee, tryInternalBalance1
                );

                tokenHolder[previousReporter][token1] += 2 * oldAmount1 + fee;
            }
        } else if (tokenToSwap == token2) {
            uint256 fee = (oldAmount2 * oracle.feePercentage) / PERCENTAGE_PRECISION;
            uint256 protocolFee = (oldAmount2 * oracle.protocolFee) / PERCENTAGE_PRECISION;
            uint256 netToken1Contribution = newAmount1 > (oldAmount1) ? newAmount1 - oldAmount1 : 0;

            if (protocolFee > 0) {
                if (tokenHolder[oracle.protocolFeeRecipient][token2] == 0) {
                    tokenHolder[oracle.protocolFeeRecipient][token2] = 1;
                }
                tokenHolder[oracle.protocolFeeRecipient][token2] += protocolFee;
            }

            if (netToken1Contribution > 0) {
                _tryInternalBalanceFull(disputer, token1, netToken1Contribution, tryInternalBalance1);
            }

            if (isSelfDispute) {
                uint256 token2Needed = newAmount2 + protocolFee;

                if (token2Needed >= oldAmount2) {
                    _tryInternalBalanceFull(disputer, token2, token2Needed - oldAmount2, tryInternalBalance2);
                } else {
                    tokenHolder[disputer][token2] += oldAmount2 - token2Needed;
                }
            } else {
                _tryInternalBalanceFull(
                    disputer, token2, newAmount2 + oldAmount2 + fee + protocolFee, tryInternalBalance2
                );
                tokenHolder[previousReporter][token2] += 2 * oldAmount2 + fee;
            }
        }

        if (isStorageMode) {
            emit ReportDisputed(reportId, disputer, tokenToSwap, newAmount1, newAmount2, currentTime);
        } else {
            emit ReportDisputedHeavy(reportId, oracle, helper);
        }
    }

    function settle(uint256 reportId) external {
        bool isStorageMode = _isStorageMode(reportId);
        if (!isStorageMode) revert InvalidMode();
        OracleGame memory empty;
        PreimageHelper memory empty2;
        _settle(reportId, empty, empty2, isStorageMode);
    }

    function settleCalldata(uint256 reportId, OracleGame calldata oracleGameData, PreimageHelper calldata helper)
        external
    {
        bool isStorageMode = _isStorageMode(reportId);
        if (isStorageMode) revert InvalidMode();
        _settle(reportId, oracleGameData, helper, isStorageMode);
    }

    /**
     * @notice Settles a report after the settlement time has elapsed
     * @param reportId The unique identifier for the report to settle
     */
    function _settle(uint256 reportId, OracleGame memory params, PreimageHelper memory helper, bool isStorageMode)
        internal
    {
        OracleGame memory oracle;

        if (isStorageMode) {
            oracle = oracleGame[reportId];
        } else {
            oracle = params;
            bytes32 preStateHash = _hashOracle(params, helper);
            if (preStateHash != oracleGame[reportId].stateHash) revert InvalidStateHash();
        }

        uint256 settlementTimestamp = oracle.settlementTimestamp;
        if (settlementTimestamp != 0) revert AlreadySettled();

        uint256 settlementTime = oracle.settlementTime;
        uint256 reportTimestamp = oracle.reportTimestamp;
        bool timeType = oracle.timeType;
        uint256 currentTime = timeType ? block.timestamp : _getBlockNumber();
        uint256 settlerReward = oracle.settlerReward;
        uint256 reporterReward = oracle.fee;
        uint128 currentAmount1 = oracle.currentAmount1;
        uint128 currentAmount2 = oracle.currentAmount2;
        address payable currentReporter = oracle.currentReporter;
        address token1 = oracle.token1;
        address token2 = oracle.token2;
        address callbackContract = oracle.callbackContract;
        bytes4 callbackSelector = oracle.callbackSelector;
        uint32 callbackGasLimit = oracle.callbackGasLimit;
        address payable initialReporter = oracle.initialReporter;
        address sender = msg.sender;

        if (currentTime < reportTimestamp + settlementTime) revert SettleTooEarly();
        if (reportTimestamp == 0) revert NoReportYet();

        oracle.settlementTimestamp = uint48(currentTime);

        if (isStorageMode) {
            oracleGame[reportId].settlementTimestamp = uint48(currentTime);
        } else {
            bytes32 nextStateHash = _hashOracle(oracle, helper);
            oracle.stateHash = nextStateHash;
            oracleGame[reportId].stateHash = nextStateHash;
        }

        tokenHolder[currentReporter][token1] += currentAmount1;
        tokenHolder[currentReporter][token2] += currentAmount2;
        if (reporterReward > 0) _creditEth(initialReporter, reporterReward);
        if (settlerReward > 0) _creditEth(sender, settlerReward);

        if (callbackContract != address(0) && callbackSelector != bytes4(0)) {
            // Prepare callback data
            bytes memory callbackData = abi.encodeWithSelector(
                callbackSelector,
                reportId,
                (currentAmount1 * PRICE_PRECISION) / currentAmount2,
                currentTime,
                token1,
                token2
            );

            // Execute callback with gas limit. Revert if not enough gas supplied to attempt callback fully.
            (bool success,) = callbackContract.call{gas: callbackGasLimit}(callbackData);
            success; // silence unused-variable warning; callback success is intentionally ignored
            if (gasleft() < callbackGasLimit / 63) {
                revert InvalidGasLimit();
            }
        }

        if (isStorageMode) {
            emit ReportSettled(reportId);
        } else {
            emit ReportSettledHeavy(reportId, oracle, helper);
        }
    }

    /**
     * @notice Withdraws held tokens while preserving the virtual 1-unit sentinel.
     * @param tokenToGet The token address to withdraw fees for
     */
    function getHeldTokens(address tokenToGet) external {
        uint256 balance = tokenHolder[msg.sender][tokenToGet];
        if (balance <= 1) return;

        uint256 amount = balance - 1;
        tokenHolder[msg.sender][tokenToGet] = 1;
        _transferTokens(tokenToGet, address(this), msg.sender, amount);
    }

    /**
     * @notice Withdraws accumulated protocol fees in ETH
     */
    function getHeldEth() external returns (uint256) {
        uint256 amount = ethHolder[msg.sender];
        if (amount > 1) {
            ethHolder[msg.sender] = 1;
            (bool success,) = payable(msg.sender).call{value: amount - 1}("");
            if (!success) revert EthTransferFailed();
            return amount - 1;
        }
        return 0;
    }

    /**
     * @notice Initializes virtual token balance sentinels for a token pair.
     * @dev Does not transfer tokens.
     */
    function dust(address token1, address token2) external {
        _getDustAmounts(msg.sender, token1, token2);
    }

    function depositTokens(address token, uint128 amount) external {
        if (tokenHolder[msg.sender][token] == 0) tokenHolder[msg.sender][token] = 1;
        tokenHolder[msg.sender][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function depositETH() external payable {
        _creditEth(msg.sender, msg.value);
    }

    function depositTokensAny(address token, uint128 amount, address beneficiary) external {
        if (beneficiary == address(0)) revert AddressCannotBeZero();
        if (tokenHolder[beneficiary][token] == 0) tokenHolder[beneficiary][token] = 1;
        tokenHolder[beneficiary][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function depositETHAny(address beneficiary) external payable {
        if (beneficiary == address(0)) revert AddressCannotBeZero();
        _creditEth(beneficiary, msg.value);
    }

    function approveInternal(address spender, address token, uint256 amount) external {
        if (spender == address(0)) revert AddressCannotBeZero();
        internalAllowance[msg.sender][spender][token] = amount;
        emit InternalApproval(msg.sender, spender, token, amount);
    }

    /**
     * @dev Internal function to handle token transfers
     */
    function _transferTokens(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return; // Gas optimization: skip zero transfers

        if (from == address(this)) {
            (bool success, bytes memory returndata) =
                token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));

            if (
                success
                    && (
                        (returndata.length > 0 && abi.decode(returndata, (bool)))
                            || (returndata.length == 0 && address(token).code.length > 0)
                    )
            ) {
                return;
            }

            tokenHolder[to][token] += amount;
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    function _checkFeeBoundary(
        uint256 oldAmount1,
        uint256 oldAmount2,
        uint256 newAmount1,
        uint256 newAmount2,
        uint256 feeSum
    ) internal pure {
        uint256 oldPrice = (oldAmount1 * PRICE_PRECISION) / oldAmount2;
        uint256 feeBoundary = (oldPrice * feeSum) / PERCENTAGE_PRECISION;
        uint256 lowerBoundary = (oldPrice * PERCENTAGE_PRECISION) / (PERCENTAGE_PRECISION + feeSum);
        uint256 upperBoundary = oldPrice + feeBoundary;
        uint256 newPrice = (newAmount1 * PRICE_PRECISION) / newAmount2;

        if (newPrice >= lowerBoundary && newPrice <= upperBoundary) {
            revert NewPriceInsideFeeBoundary();
        }
    }

    function _isStorageMode(uint256 reportId) internal view returns (bool) {
        return oracleGame[reportId].exactToken1Report != 0;
    }

    function _validateTiming(TimingBoundaries memory timing) internal view {
        uint256 timestamp = timing.blockTimestamp;
        uint256 timestampBound = timing.blockTimestampBound;
        uint256 blockNumber = timing.blockNumber;
        uint256 blockNumberBound = timing.blockNumberBound;
        uint256 currentBlockNumber = _getBlockNumber();
        if (block.timestamp + timestampBound < timestamp || block.timestamp > timestamp + timestampBound) {
            revert InvalidTiming();
        }
        if (currentBlockNumber + blockNumberBound < blockNumber || currentBlockNumber > blockNumber + blockNumberBound)
        {
            revert InvalidTiming();
        }
    }

    function _hashOracle(OracleGame memory oracle, PreimageHelper memory helper) internal pure returns (bytes32) {
        bytes32 oldStateHash = oracle.stateHash;
        oracle.stateHash = bytes32(0);
        bytes32 hashedOracle = keccak256(abi.encode(oracle, helper));
        oracle.stateHash = oldStateHash;
        return hashedOracle;
    }

    function _dust(address user, address token) internal returns (bool firstTimeDust) {
        if (tokenHolder[user][token] == 0) {
            tokenHolder[user][token] = 1;
            firstTimeDust = true;
        }
    }

    function _getDustAmounts(address reporter, address token1, address token2) internal {
        bytes32 dustKey = keccak256(abi.encode(reporter, token1, token2));
        // one SLOAD for future pair reads after sentinel initialization
        if (!dustedPair[dustKey]) {
            _dust(reporter, token1);
            _dust(reporter, token2);
            dustedPair[dustKey] = true;
        }
    }

    /**
     * @dev Credit ETH to a recipient's internal balance, seeding the virtual
     *      sentinel on first credit so withdrawals via `getHeldEth` return the
     *      full credited amount with no real-wei forfeit.
     */
    function _creditEth(address recipient, uint256 amount) internal {
        if (ethHolder[recipient] == 0) ethHolder[recipient] = 1;
        ethHolder[recipient] += amount;
    }

    /**
     * @dev Tries to use internal balances to report
     */
    function _tryInternalBalanceFull(address reporter, address token, uint256 amount, bool tryInternalBalance)
        internal
    {
        if (tryInternalBalance) {
            _tryInternalBalance(reporter, token, amount);
        } else {
            _transferTokens(token, msg.sender, address(this), uint256(amount));
        }
    }

    function _tryInternalBalance(address owner, address token, uint256 amount) internal {
        uint256 internalBalance = tokenHolder[owner][token];
        if (internalBalance > 1 && amount <= internalBalance - 1) {
            if (owner == msg.sender) {
                tokenHolder[owner][token] = internalBalance - amount;
                return;
            }

            uint256 allowed = internalAllowance[owner][msg.sender][token];
            if (allowed >= amount) {
                if (allowed != type(uint256).max) {
                    internalAllowance[owner][msg.sender][token] = allowed - amount;
                }

                tokenHolder[owner][token] = internalBalance - amount;
                return;
            }
        }

        _transferTokens(token, msg.sender, address(this), amount);
    }

    /**
     * @dev Gets the current block number (returns L1 block number for L1 deployment)
     */
    function _getBlockNumber() internal view returns (uint48) {
        return uint48(block.number);
    }
}
