// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OpenOracleErrors} from "./OpenOracleErrors.sol";
import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";

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
 *
 *      Vanilla ERC20, USDC, and USDT-style return value tokens only. Fee-on-transfer, rebasing tokens etc are explicitly not supported.
 * @author OpenOracle Team
 * @custom:version 0.2.0
 * @custom:documentation https://docs.openoracle.org
 */
contract OpenOracle is OpenOracleErrors {
    using SafeERC20 for IERC20;

    // Constants
    uint256 internal constant PRICE_PRECISION = 1e30;
    uint256 internal constant PERCENTAGE_PRECISION = 1e7;
    uint256 internal constant MULTIPLIER_PRECISION = 100;
    address internal constant ETH_SENTINEL = address(0);
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Permit2 witness: binds the sig to (beneficiary, relayer, swapper, intent).
    bytes32 internal constant WITNESS_TYPEHASH =
        keccak256("Witness(address beneficiary,address relayer,address swapper,bytes32 intent)");
    string internal constant WITNESS_TYPE_STRING =
        "Witness witness)TokenPermissions(address token,uint256 amount)Witness(address beneficiary,address relayer,address swapper,bytes32 intent)";

    uint8 public constant FLAG_TIME_TYPE = 1 << 0; // = 1
    uint8 public constant FLAG_TRACK_DISPUTES = 1 << 1; // = 2
    uint8 public constant FLAG_STORE_ALL = 1 << 2; // = 4
    uint8 public constant FLAG_STORE_PRICE = 1 << 3; // = 8

    bytes4 internal constant CALLBACK_SELECTOR =
        bytes4(keccak256("openOracleCallback(uint256,uint256,uint256,uint256,address,address)"));

    // State variables
    uint256 public nextReportId = 1;

    mapping(uint256 => bytes32) public oracleGame;
    mapping(uint256 => uint256) public finalPrice;
    mapping(address => mapping(address => uint256)) public tokenHolder;
    mapping(uint256 => mapping(uint256 => DisputeRecord)) public disputeHistory;
    mapping(uint256 => OracleGame) public finalizedGame;
    mapping(address => mapping(address => mapping(address => uint256))) public internalAllowance; // owner => spender => token => amount

    struct DisputeRecord {
        uint128 amount1;
        uint128 amount2;
        address tokenToSwap;
        uint48 reportTimestamp;
    }

    struct OracleGame {
        uint128 currentAmount1;
        uint128 currentAmount2; //
        address payable currentReporter;
        uint48 reportTimestamp;
        uint48 settlementTimestamp; //
        address token1;
        uint48 lastReportOppoTime;
        uint48 settlementTime; //
        uint128 escalationHalt; //
        address protocolFeeRecipient;
        uint96 settlerReward; //
        address token2;
        uint24 numReports;
        uint24 disputeDelay;
        uint24 feePercentage;
        uint16 multiplier; //
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

    struct CreateReportParams {
        uint128 escalationHalt; // amount of token1 at which escalation stops but disputes can still happen
        address token1Address; // address of token1 in the oracle report instance
        uint96 settlerReward; // eth paid to settler in wei
        address token2Address; // address of token2 in the oracle report instance
        uint48 settlementTime; // report instance can settle if no disputes within this timeframe
        uint24 disputeDelay; // time disputes must wait after every new report
        uint24 protocolFee; // fee paid to protocolFeeRecipient. 1000 = 0.01%
        uint32 callbackGasLimit; // gas the settlement callback must use
        uint24 feePercentage; // fee paid to previous reporter. 1000 = 0.01%
        uint16 multiplier; // amount by which newAmount1 must increase versus old amount1. 140 = 1.4x. 100 = no escalation.
        address callbackContract; // contract address for settle to call back into (must implement openOracleCallback(uint256 reportId, uint256 currentAmount1, uint256 currentAmount2, uint256 settlementTimestamp, address token1, address token2))
        address protocolFeeRecipient; // address that receives protocol fees
        uint8 flags;
    }

    // Events
    event ReportSubmitted(uint256 indexed reportId);
    event ReportDisputed(uint256 indexed reportId);
    event ReportSettled(uint256 indexed reportId);
    event InternalApproval(address indexed owner, address indexed spender, address indexed token, uint256 amount);

    /**
     * @notice Creates a calldata-mode report instance and submits the initial report in one call.
     * @param params Report creation parameters
     * @param amount2 Choose the amount of token2 that equals amount1 in value
     * @param reporter The address that will receive tokens back when settled or disputed
     * @param tryInternalBalance1 If true, tries to fund token1 from reporter's internal balance before pulling from msg.sender
     * @param tryInternalBalance2 If true, tries to fund token2 from reporter's internal balance before pulling from msg.sender
     * @param timing Optional timing bounds. If timing.blockTimestamp is zero, timing validation is skipped.
     * @return reportId The unique identifier for the created report instance
     */
    function report(
        CreateReportParams calldata params,
        uint128 amount1,
        uint128 amount2,
        address reporter,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        TimingBoundaries calldata timing
    ) external payable returns (uint256 reportId) {
        bool timeType = _hasFlag(params.flags, FLAG_TIME_TYPE);
        uint48 blockNumber = _getBlockNumber();
        uint48 reportTimestamp = timeType ? uint48(block.timestamp) : blockNumber;
        uint48 oppoTime = timeType ? blockNumber : uint48(block.timestamp);
        address token1 = params.token1Address;
        address token2 = params.token2Address;
        address protocolFeeRecipient = params.protocolFeeRecipient;

        if (amount1 == 0) revert InvalidAmount1();
        if (token1 == token2) revert TokensCannotBeSame();
        if (params.settlementTime < params.disputeDelay) revert SettleVsDisputeDelayTiming();
        if (params.feePercentage + params.protocolFee > 1e7) revert FeesTooHigh();
        if (params.multiplier < MULTIPLIER_PRECISION) revert MultiplierTooLow();
        if (timing.blockTimestamp > 0) _validateTiming(timing);
        if (amount2 == 0) revert InvalidAmount2();
        if (reporter == address(0)) revert AddressCannotBeZero();
        if (msg.value > params.settlerReward && token1 != ETH_SENTINEL && token2 != ETH_SENTINEL) {
            revert NeitherTokenIsETH();
        }

        reportId = nextReportId++;
        OracleGame memory oracle;

        oracle.token1 = token1;
        oracle.token2 = token2;
        oracle.feePercentage = params.feePercentage;
        oracle.multiplier = params.multiplier;
        oracle.settlementTime = params.settlementTime;
        oracle.escalationHalt = params.escalationHalt;
        oracle.disputeDelay = params.disputeDelay;
        oracle.protocolFee = params.protocolFee;
        oracle.settlerReward = params.settlerReward;
        oracle.callbackContract = params.callbackContract;
        oracle.callbackGasLimit = params.callbackGasLimit;
        oracle.protocolFeeRecipient = protocolFeeRecipient;
        oracle.currentAmount1 = amount1;
        oracle.currentAmount2 = amount2;
        oracle.currentReporter = payable(reporter);
        oracle.reportTimestamp = reportTimestamp;
        oracle.lastReportOppoTime = oppoTime;
        oracle.flags = params.flags;

        if (_hasFlag(oracle.flags, FLAG_TRACK_DISPUTES)) {
            DisputeRecord storage initialRecord = disputeHistory[reportId][0];
            initialRecord.amount1 = amount1;
            initialRecord.amount2 = amount2;
            initialRecord.reportTimestamp = reportTimestamp;
            oracle.numReports = 1;
        }

        PreimageHelper memory helper = PreimageHelper({
            reportId: reportId,
            creator: msg.sender,
            blockTimestamp: block.timestamp,
            blockNumber: blockNumber
        });

        bytes32 stateHash = _hashOracle(oracle, helper);
        oracleGame[reportId] = stateHash;

        if (params.protocolFee > 0 && protocolFeeRecipient != address(0)) {
            _getDustAmounts(protocolFeeRecipient, token1, token2);
        }

        _getDustAmounts(reporter, token1, token2);

        uint256 ethRequired = params.settlerReward;
        ethRequired += _tryInternalBalanceFull(reporter, token1, amount1, tryInternalBalance1);
        ethRequired += _tryInternalBalanceFull(reporter, token2, amount2, tryInternalBalance2);

        if (msg.value < ethRequired) revert MsgValueTooLow();
        uint256 excess = msg.value - ethRequired;
        if (excess > 0) _credit(reporter, ETH_SENTINEL, excess);

        emit ReportSubmitted(reportId);
    }

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
    ) external payable {
        OracleGame memory oracle;

        oracle = params;
        bytes32 preStateHash = _hashOracle(params, helper);
        if (preStateHash != oracleGame[reportId]) revert InvalidStateHash();

        (uint256 oldAmount1, uint256 oldAmount2) = (oracle.currentAmount1, oracle.currentAmount2);
        address token1 = oracle.token1;
        address token2 = oracle.token2;
        address previousReporter = oracle.currentReporter;
        bool timeType = _hasFlag(oracle.flags, FLAG_TIME_TYPE);
        uint48 blockNumber = _getBlockNumber();
        uint48 currentTime = timeType ? uint48(block.timestamp) : blockNumber;
        uint48 oppoTime = timeType ? blockNumber : uint48(block.timestamp);
        bool isSelfDispute = (disputer == previousReporter && msg.sender == previousReporter);

        {
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

            if (newAmount1 == 0 || newAmount2 == 0) revert AmountsCannotBeZero();
            if (previousReporter == address(0)) revert NoReportToDispute();
            if (currentTime >= prevReportTimestamp + oracle.settlementTime) revert DisputeTooLate();
            if (oracle.settlementTimestamp != 0) revert AlreadySettled();
            if (tokenToSwap != token1 && tokenToSwap != token2) revert InvalidTokenToSwap();
            if (currentTime < prevReportTimestamp + oracle.disputeDelay) revert DisputeTooEarly();
            if (disputer == address(0)) revert AddressCannotBeZero();
            if (timing.blockTimestamp > 0) _validateTiming(timing);
            if (msg.value > 0 && token1 != ETH_SENTINEL && token2 != ETH_SENTINEL) revert NeitherTokenIsETH();
        }

        {
            oracle.currentAmount1 = newAmount1;
            oracle.currentAmount2 = newAmount2;
            oracle.currentReporter = payable(disputer);
            oracle.reportTimestamp = currentTime;
            oracle.lastReportOppoTime = oppoTime;

            if (_hasFlag(oracle.flags, FLAG_TRACK_DISPUTES)) {
                uint24 nextIndex = oracle.numReports;
                DisputeRecord storage record = disputeHistory[reportId][nextIndex];
                record.amount1 = newAmount1;
                record.amount2 = newAmount2;
                record.reportTimestamp = currentTime;
                record.tokenToSwap = tokenToSwap;
                if (nextIndex < type(uint24).max) oracle.numReports = nextIndex + 1;
            }

            bytes32 nextStateHash = _hashOracle(oracle, helper);
            oracleGame[reportId] = nextStateHash;
        }

        _getDustAmounts(disputer, token1, token2);

        uint256 ethRequired = 0;

        if (tokenToSwap == token1) {
            uint256 fee = (oldAmount1 * oracle.feePercentage) / PERCENTAGE_PRECISION;
            uint256 protocolFee = (oldAmount1 * oracle.protocolFee) / PERCENTAGE_PRECISION;
            uint256 netToken2Contribution = newAmount2 >= oldAmount2 ? newAmount2 - oldAmount2 : 0;
            uint256 netToken2Receive = newAmount2 < oldAmount2 ? oldAmount2 - newAmount2 : 0;

            if (protocolFee > 0 && oracle.protocolFeeRecipient != address(0)) { // gas optimization for intentional burn w/o writing to storage
                address pfr = oracle.protocolFeeRecipient;
                uint256 bal = tokenHolder[pfr][token1];
                tokenHolder[pfr][token1] = bal == 0 ? protocolFee + 1 : bal + protocolFee;
            }

            if (netToken2Contribution > 0) {
                ethRequired += _tryInternalBalanceFull(disputer, token2, netToken2Contribution, tryInternalBalance2);
            }

            if (netToken2Receive > 0) {
                tokenHolder[disputer][token2] += netToken2Receive;
            }

            if (isSelfDispute) {
                uint256 token1Contribution = newAmount1 - oldAmount1 + protocolFee;
                ethRequired += _tryInternalBalanceFull(disputer, token1, token1Contribution, tryInternalBalance1);
            } else {
                ethRequired += _tryInternalBalanceFull(
                    disputer, token1, newAmount1 + oldAmount1 + fee + protocolFee, tryInternalBalance1
                );

                tokenHolder[previousReporter][token1] += 2 * oldAmount1 + fee;
            }
        } else if (tokenToSwap == token2) {
            uint256 fee = (oldAmount2 * oracle.feePercentage) / PERCENTAGE_PRECISION;
            uint256 protocolFee = (oldAmount2 * oracle.protocolFee) / PERCENTAGE_PRECISION;
            uint256 netToken1Contribution = newAmount1 > (oldAmount1) ? newAmount1 - oldAmount1 : 0;

            if (protocolFee > 0 && oracle.protocolFeeRecipient != address(0)) {
                address pfr = oracle.protocolFeeRecipient;
                uint256 bal = tokenHolder[pfr][token2];
                tokenHolder[pfr][token2] = bal == 0 ? protocolFee + 1 : bal + protocolFee;
            }

            if (netToken1Contribution > 0) {
                ethRequired += _tryInternalBalanceFull(disputer, token1, netToken1Contribution, tryInternalBalance1);
            }

            if (isSelfDispute) {
                uint256 token2Needed = newAmount2 + protocolFee;

                if (token2Needed >= oldAmount2) {
                    ethRequired +=
                        _tryInternalBalanceFull(disputer, token2, token2Needed - oldAmount2, tryInternalBalance2);
                } else {
                    tokenHolder[disputer][token2] += oldAmount2 - token2Needed;
                }
            } else {
                ethRequired += _tryInternalBalanceFull(
                    disputer, token2, newAmount2 + oldAmount2 + fee + protocolFee, tryInternalBalance2
                );
                tokenHolder[previousReporter][token2] += 2 * oldAmount2 + fee;
            }
        }

        if (msg.value < ethRequired) revert MsgValueTooLow();
        uint256 excess = msg.value - ethRequired;
        if (excess > 0) _credit(disputer, ETH_SENTINEL, excess);

        emit ReportDisputed(reportId);
    }

    /**
     * @notice Settles a report after the settlement time has elapsed
     * @param reportId The unique identifier for the report to settle
     */
    function settle(uint256 reportId, OracleGame calldata params, PreimageHelper calldata helper) external {
        OracleGame memory oracle = params;
        bytes32 preStateHash = _hashOracle(params, helper);
        if (preStateHash != oracleGame[reportId]) revert InvalidStateHash();

        uint256 settlementTimestamp = oracle.settlementTimestamp;
        if (settlementTimestamp != 0) revert AlreadySettled();

        uint256 settlementTime = oracle.settlementTime;
        uint256 reportTimestamp = oracle.reportTimestamp;
        bool timeType = _hasFlag(oracle.flags, FLAG_TIME_TYPE);
        uint256 currentTime = timeType ? block.timestamp : _getBlockNumber();
        uint256 settlerReward = oracle.settlerReward;
        uint128 currentAmount1 = oracle.currentAmount1;
        uint128 currentAmount2 = oracle.currentAmount2;
        address payable currentReporter = oracle.currentReporter;
        address token1 = oracle.token1;
        address token2 = oracle.token2;
        address callbackContract = oracle.callbackContract;
        uint32 callbackGasLimit = oracle.callbackGasLimit;
        address sender = msg.sender;
        bool hasCallback = callbackContract != address(0);
        bool storePrice = _hasFlag(oracle.flags, FLAG_STORE_PRICE);
        uint256 finalRatio;
        if (storePrice) finalRatio = (currentAmount1 * PRICE_PRECISION) / currentAmount2;

        if (currentTime < reportTimestamp + settlementTime) revert SettleTooEarly();
        if (reportTimestamp == 0) revert NoReportYet();

        // write state
        oracle.settlementTimestamp = uint48(currentTime);
        bytes32 nextStateHash = _hashOracle(oracle, helper);
        oracleGame[reportId] = nextStateHash;
        if (storePrice) finalPrice[reportId] = finalRatio;
        if (_hasFlag(oracle.flags, FLAG_STORE_ALL)) finalizedGame[reportId] = oracle;

        // handle flows
        tokenHolder[currentReporter][token1] += currentAmount1;
        tokenHolder[currentReporter][token2] += currentAmount2;
        if (settlerReward > 0) _credit(sender, ETH_SENTINEL, settlerReward);

        if (hasCallback) {
            // Prepare callback data
            bytes memory callbackData =
                abi.encodeWithSelector(CALLBACK_SELECTOR, reportId, currentAmount1, currentAmount2, currentTime, token1, token2);

            // Execute callback with gas limit. Revert if not enough gas supplied to attempt callback fully.
            (bool success,) = callbackContract.call{gas: callbackGasLimit}(callbackData);
            success; // silence unused-variable warning; callback success is intentionally ignored
            if (gasleft() < callbackGasLimit / 63) {
                revert InvalidGasLimit();
            }
        }

        emit ReportSettled(reportId);
    }

    function withdraw(address tokenToGet) external returns (uint256 sent) {
        return _withdraw(tokenToGet, msg.sender);
    }

    function withdrawTo(address tokenToGet, address to) external returns (uint256 sent) {
        return _withdraw(tokenToGet, to);
    }

    /**
     * @notice Withdraws held tokens to `to`, preserving the virtual 1-unit sentinel.
     * @param tokenToGet The token address to withdraw
     * @param to Recipient of the withdrawn tokens
     */
    function _withdraw(address tokenToGet, address to) internal returns (uint256 amount) {
        if (to == address(0)) revert AddressCannotBeZero();
        uint256 balance = tokenHolder[msg.sender][tokenToGet];
        if (balance <= 1) return 0;

        amount = balance - 1;
        tokenHolder[msg.sender][tokenToGet] = 1;
        if (tokenToGet == ETH_SENTINEL) {
            (bool success,) = (to).call{value: amount}("");
            if (!success) {
                revert EthTransferFailed();
            }
        } else {
            _transferTokens(tokenToGet, address(this), to, amount);
        }
    }

    /**
     * @notice Initializes virtual token balance sentinels for a token pair.
     * @dev Does not transfer tokens.
     */
    function dust(address token1, address token2) external {
        _getDustAmounts(msg.sender, token1, token2);
    }

    function deposit(address token, uint128 amount, address beneficiary) external payable {
        if (beneficiary == address(0)) revert AddressCannotBeZero();
        if (token != ETH_SENTINEL && msg.value > 0) revert InvalidMsgValue();
        if (tokenHolder[beneficiary][token] == 0) tokenHolder[beneficiary][token] = 1;
        tokenHolder[beneficiary][token] += amount;

        if (token == ETH_SENTINEL) {
            if (msg.value != amount) revert InvalidMsgValue();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    /**
     * @notice Pulls `amount` of token from `from` via Permit2 (witness-bound) and credits `beneficiary`'s internal balance.
     * @dev Witness binds (beneficiary, relayer = msg.sender, swapper = from, intent). The signer's sig is
     *      only usable when the call is relayed by the intended relayer, credits the intended beneficiary,
     *      attributes to the intended swapper, and matches the intended per-protocol intent hash.
     */
    function depositFromPermit2(
        uint128 amount,
        address beneficiary,
        address from,
        bytes32 intent,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external {
        if (beneficiary == address(0)) revert AddressCannotBeZero();
        if (permit.permitted.amount != amount) revert Permit2AmountMismatch();

        bytes32 witness = keccak256(abi.encode(WITNESS_TYPEHASH, beneficiary, msg.sender, from, intent));

        ISignatureTransfer(PERMIT2).permitWitnessTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
            from,
            witness,
            WITNESS_TYPE_STRING,
            signature
        );

        _credit(beneficiary, permit.permitted.token, amount);
    }

    /**
     * @notice Transfers `amount` of `token` from `from`'s internal balance to `to`'s internal balance.
     * @dev When `from == msg.sender`, no allowance is required. Otherwise, spends from
     *      `from`'s internal allowance to msg.sender. Preserves the 1-unit sentinel on `from`'s slot.
     */
    function internalTransferFrom(address from, address to, address token, uint128 amount) external {
        if (to == address(0)) revert AddressCannotBeZero();
        if (amount == 0) return;

        if (from != msg.sender) {
            uint256 allowed = internalAllowance[from][msg.sender][token];
            if (allowed < amount) revert InsufficientInternalAllowance();
            if (allowed != type(uint256).max) {
                internalAllowance[from][msg.sender][token] = allowed - amount;
            }
        }

        uint256 bal = tokenHolder[from][token];
        if (bal <= amount) revert InsufficientInternalBalance();
        tokenHolder[from][token] = bal - amount;
        _credit(to, token, amount);
    }

    /**
     * @notice Debits caller's internal balance and pushes `amount` of `token` externally to `to`.
     *         On push failure (ETH call revert / ERC20 non-standard return / OOG within 80k gas),
     *         falls back to crediting `to`'s internal balance instead.
     * @dev Caller's slot preserves the 1-unit sentinel.
     */
    function pushOrCredit(address token, address to, uint128 amount) external {
        if (to == address(0)) revert AddressCannotBeZero();
        if (amount == 0) return;
        uint256 bal = tokenHolder[msg.sender][token];
        if (bal <= amount) revert InsufficientInternalBalance();
        tokenHolder[msg.sender][token] = bal - amount;

        if (token == ETH_SENTINEL) {
            (bool ok,) = to.call{value: amount, gas: 50000}("");
            if (!ok) _credit(to, token, amount);
        } else {
            (bool success, bytes memory returndata) =
                token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
            bool ok = success
                && ((returndata.length > 0 && abi.decode(returndata, (bool)))
                    || (returndata.length == 0 && token.code.length > 0));
            if (!ok) _credit(to, token, amount);
        }
    }

    function approveInternal(address spender, address token, uint256 amount) external {
        if (spender == address(0)) revert AddressCannotBeZero();
        internalAllowance[msg.sender][spender][token] = amount;
        emit InternalApproval(msg.sender, spender, token, amount);
    }

    /**
     * @dev Internal function to handle token transfers
     */
    function _transferTokens(address token, address from, address to, uint256 amount)
        internal
    {
        if (amount == 0) return; // Gas optimization: skip zero transfers

        if (from == address(this)) {
            IERC20(token).safeTransfer(to, amount);
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
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
        bytes32 hashedOracle = keccak256(abi.encode(oracle, helper));
        return hashedOracle;
    }

    function _getDustAmounts(address reporter, address token1, address token2) internal {
        _dust(reporter, token1);
        _dust(reporter, token2);
    }

    function _dust(address user, address token) internal {
        if (tokenHolder[user][token] == 0) {
            tokenHolder[user][token] = 1;
        }
    }

    /**
     * @dev Credit assets to a recipient's internal balance, seeding the virtual
     *      sentinel on first credit so withdrawals return the
     *      full credited amount.
     */
    function _credit(address recipient, address token, uint256 amount) internal {
        uint256 bal = tokenHolder[recipient][token];
        tokenHolder[recipient][token] = bal == 0 ? amount + 1 : bal + amount;
    }

    function _tryInternalBalanceFull(address owner, address token, uint256 amount, bool tib)
        internal
        returns (uint256 ethNeeded)
    {
        uint256 fromInternal = 0;

        if (tib) {
            uint256 internalBalance = tokenHolder[owner][token];
            uint256 allowed;

            if (internalBalance > 1) {
                uint256 available = internalBalance - 1;
                fromInternal = available > amount ? amount : available;

                bool isNotOwner = (owner != msg.sender);
                if (isNotOwner) allowed = internalAllowance[owner][msg.sender][token];

                if (isNotOwner) {
                    if (allowed < fromInternal) fromInternal = allowed;
                }

                if (fromInternal > 0) {
                    tokenHolder[owner][token] = internalBalance - fromInternal;
                    if (isNotOwner) {
                        if (allowed != type(uint256).max) {
                            internalAllowance[owner][msg.sender][token] = allowed - fromInternal;
                        }
                    }
                }

            }

        }

        // Strict delegation: if caller asked to fund from `owner`'s internal balance but the
        // available balance + allowance falls short, revert. Prevents callers from accidentally
        // paying out-of-pocket for a delegated dispute/report when the owner can't cover it.
        if (tib && owner != msg.sender && fromInternal < amount) revert InsufficientInternalBalance();

        uint256 fromExternal = amount - fromInternal;

        if (token == ETH_SENTINEL) {
            return fromExternal; // ETH needed from msg.value
        }

        if (fromExternal > 0) {
            _transferTokens(token, msg.sender, address(this), fromExternal);
        }
        return 0; // ERC20 path consumed nothing from msg.value
    }

    /**
     * @dev Gets the current block number (returns L1 block number for L1 deployment)
     */
    function _getBlockNumber() internal view returns (uint48) {
        return uint48(block.number);
    }

    function _hasFlag(uint8 flags, uint8 mask) internal pure returns (bool) {
        return flags & mask != 0;
    }
}
