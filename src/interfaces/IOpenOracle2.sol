// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISignatureTransfer} from "./ISignatureTransfer.sol";

/**
 * @title IOpenOracle2
 * @notice External interface for the slim OpenOracle (OpenOracleSlim.sol).
 *         Mirrors the public/external surface so consumer contracts can
 *         depend on the interface without importing the full implementation.
 */
interface IOpenOracle2 {
    /* ─── Structs ───────────────────────────────────────────── */

    struct DisputeRecord {
        uint128 amount1;
        uint128 amount2;
        address tokenToSwap;
        uint48 reportTimestamp;
    }

    struct OracleGame {
        uint128 currentAmount1;
        uint128 currentAmount2;
        address currentReporter;
        uint48 reportTimestamp;
        uint48 settlementTimestamp;
        address token1;
        uint48 lastReportOppoTime;
        uint48 settlementTime;
        uint128 escalationHalt;
        address protocolFeeRecipient;
        uint96 settlerReward;
        address token2;
        uint24 numReports;
        uint24 disputeDelay;
        uint24 feePercentage;
        uint16 multiplier;
        address callbackContract;
        uint32 callbackGasLimit;
        uint24 protocolFee;
        uint8 flags;
    }

    struct PreimageHelper {
        uint256 reportId;
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

    /* ─── Events ────────────────────────────────────────────── */

    event ReportSubmitted(uint256 indexed reportId, bytes packed);
    event ReportDisputed(uint256 indexed reportId, bytes packed);
    event ReportSettled(uint256 indexed reportId);
    event InternalApproval(
        address indexed owner,
        address indexed spender,
        address indexed token,
        uint256 amount
    );

    /* ─── State accessors (public mapping/var getters) ──────── */

    function nextReportId() external view returns (uint256);
    function oracleGame(uint256 reportId) external view returns (bytes32);
    function finalPrice(uint256 reportId) external view returns (uint256);
    function tokenHolder(address holder, address token) external view returns (uint256);
    function disputeHistory(uint256 reportId, uint256 index)
        external
        view
        returns (uint128 amount1, uint128 amount2, address tokenToSwap, uint48 reportTimestamp);
    function finalizedGame(uint256 reportId)
        external
        view
        returns (
            uint128 currentAmount1,
            uint128 currentAmount2,
            address currentReporter,
            uint48 reportTimestamp,
            uint48 settlementTimestamp,
            address token1,
            uint48 lastReportOppoTime,
            uint48 settlementTime,
            uint128 escalationHalt,
            address protocolFeeRecipient,
            uint96 settlerReward,
            address token2,
            uint24 numReports,
            uint24 disputeDelay,
            uint24 feePercentage,
            uint16 multiplier,
            address callbackContract,
            uint32 callbackGasLimit,
            uint24 protocolFee,
            uint8 flags
        );
    function internalAllowance(address owner, address spender, address token)
        external
        view
        returns (uint256);

    /* ─── Lifecycle: report → dispute → settle ───────────────── */

    /**
     * @notice Creates a report instance from a caller-supplied OracleGame and submits the initial
     *         report in one call. Contract overrides reportTimestamp / lastReportOppoTime (and
     *         numReports when FLAG_TRACK_DISPUTES is set) before hashing.
     * @param params OracleGame for the new report. Must have reportTimestamp, lastReportOppoTime,
     *               settlementTimestamp, and numReports set to zero — contract enforces.
     * @param tryInternalBalance1 If true, fund token1 from params.currentReporter's internal balance.
     * @param tryInternalBalance2 If true, fund token2 from params.currentReporter's internal balance.
     * @param timing Optional timing bounds. If timing.blockTimestamp is zero, timing validation is skipped.
     * @return reportId The unique identifier for the created report instance
     */
    function report(
        OracleGame calldata params,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        TimingBoundaries calldata timing
    ) external payable returns (uint256 reportId);

    /**
     * @notice Disputes an open report by escalating amount1 according to the multiplier rule.
     *         Caller supplies the current OracleGame + PreimageHelper as calldata; the contract
     *         verifies the hash against stored state.
     */
    function dispute(
        uint256 reportId,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        address disputer,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OracleGame calldata params,
        PreimageHelper calldata helper,
        TimingBoundaries calldata timing
    ) external payable;

    /**
     * @notice Settles a report after settlementTime has elapsed.
     *         Caller supplies the current OracleGame + PreimageHelper as calldata.
     */
    function settle(
        uint256 reportId,
        OracleGame calldata params,
        PreimageHelper calldata helper
    ) external;

    /* ─── Internal balance management ────────────────────────── */

    /**
     * @notice Deposits a token into `beneficiary`'s internal balance.
     *         For ETH (token == address(0)), msg.value must equal `amount`.
     *         For ERC20, pulls `amount` via safeTransferFrom from msg.sender.
     */
    function deposit(address token, uint128 amount, address beneficiary) external payable;

    /**
     * @notice Pulls `amount` of token from `from` via Permit2 (witness-bound) and credits `beneficiary`'s internal balance.
     *         The signature is witness-bound to (beneficiary, msg.sender as relayer, from as swapper, intent).
     */
    function depositFromPermit2(
        uint128 amount,
        address beneficiary,
        address from,
        bytes32 intent,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external;

    /**
     * @notice Transfers `amount` of `token` from `from`'s internal balance to `to`'s internal balance.
     *         When `from == msg.sender`, no allowance is required; otherwise spends `from`'s internal allowance to msg.sender.
     */
    function internalTransferFrom(address from, address to, address token, uint128 amount) external;

    /**
     * @notice Debits caller's internal balance and pushes `amount` of `token` externally to `to`.
     *         Falls back to crediting `to`'s internal balance if the push fails.
     */
    function pushOrCredit(address token, address to, uint128 amount) external;

    /**
     * @notice Sets msg.sender's internal allowance for `spender` to spend `token`.
     */
    function approveInternal(address spender, address token, uint256 amount) external;

    /**
     * @notice Initializes the 1-unit sentinel for msg.sender's tokenHolder slots for both tokens
     *         (one-time pre-warming so future credits/debits pay warm-SSTORE prices).
     */
    function dust(address token1, address token2) external;

    /**
     * @notice Withdraws up to `amount` of `tokenToGet` (capped at available internal balance
     *         minus the 1-unit sentinel) to msg.sender. Returns the amount actually sent.
     */
    function withdraw(address tokenToGet, uint256 amount) external returns (uint256 sent);

    /**
     * @notice Same as `withdraw`, but sends to `to` instead of msg.sender.
     */
    function withdrawTo(address tokenToGet, uint256 amount, address to) external returns (uint256 sent);
}
