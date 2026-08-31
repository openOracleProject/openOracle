// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";
import {PuntErrors as Errors} from "../libraries/PuntErrors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {OpenPuntFeeReceiver} from "./OpenPuntFeeReceiver.sol";
import {OpenPuntStorage} from "./OpenPuntStorage.sol";

contract OpenPuntLifecycle is OpenPuntStorage {
    uint8 internal constant MAX_SETTLEMENT_TIMESTAMP_SEARCH_DEPTH = 200;

    address public immutable feeReceiverImpl;

    struct DutchResolution {
        uint128 inheritedExecutionComp;
        uint128 leftover;
        bool useInternalBalances;
    }

    /// @dev Deploys the shared fee-receiver implementation and binds this module to OpenOracle.
    /// @param oracle_ OpenOracle contract used by the core and lifecycle module.
    constructor(address oracle_) OpenPuntStorage(oracle_) {
        feeReceiverImpl = address(new OpenPuntFeeReceiver(IOpenOracle2(oracle_)));
    }

    /**
     * @notice Starts a new oracle report for an active position.
     * @dev The designated `reporter` must approve OpenPunt in OpenOracle for both oracle-token
     *      amounts. The caller funds the ETH execution compensation directly. If `msg.sender != reporter`,
     *      the caller must also approve the oracle-token amounts transferred to the reporter. A reporter
     *      claiming a Dutch auction should use `timing` bounds that prevent inclusion at or after the
     *      auction expiration, when the report would be submitted without claiming the auction reward.
     * @param swapId Position identifier.
     * @param expectedDutchHash Exact current auction hash required by the reporter, or zero to accept
     *                          and claim whatever auction is present.
     * @param swapState Current active MatchedSwap preimage committed in swaps[swapId].
     * @param preimage MatcherPreimage committed when the position was proposed.
     * @param timing OpenOracle timing bounds for the new report, accounting for any Dutch-expiration deadline.
     * @param reporter Account recorded as reporter; may differ from msg.sender, which supplies funding.
     * @param amount1 Token1 liquidity supplied to the report.
     * @param amount2 Token2 liquidity supplied to the report.
     * @param altGasCompExec ETH-denominated compensation contributed for this report's executor.
     */
    function report(
        uint256 swapId,
        bytes32 expectedDutchHash,
        MatchedSwap calldata swapState,
        MatcherPreimage calldata preimage,
        IOpenOracle2.TimingBoundaries calldata timing,
        address reporter,
        uint128 amount1,
        uint128 amount2,
        uint128 altGasCompExec
    ) external {
        MatchedSwap memory s = swapState;
        bytes32 passedSwapHash = keccak256(abi.encode(s));
        bytes32 passedMatcherPreimage = keccak256(abi.encode(preimage));
        if (passedSwapHash != swaps[swapId]) revert Errors.WrongHash();
        if (passedMatcherPreimage != s.matcherPreimageHash) revert Errors.WrongHash();
        if (amount1 == 0 || amount2 == 0) revert Errors.AmountsCannotBeZero();
        if (reporter == address(0)) revert Errors.AddressCannotBeZero();
        if (reporter == address(this)) revert Errors.ContractCannotBeParticipant();
        if (swapIdToReportId(swapId) != 0) revert Errors.OracleGameInProgress();
        if (!s.active) revert Errors.NotActive();
        if (s.maturityOnly && block.timestamp < s.maturity) revert Errors.MaturityNotReached();

        // since openOracle already allows atomic looped escalation when disputeDelay is 0,
        // and larger starting amounts may be useful sometimes, we allow the game to start larger in this case
        uint128 minAmount1 = preimage.initialLiquidity;
        uint128 escalationHalt = preimage.escalationHalt;
        uint128 reportCeiling = 10 * uint256(minAmount1) > escalationHalt ? escalationHalt : 10 * minAmount1;
        if (amount1 > reportCeiling || amount1 < minAmount1) revert Errors.InvalidAmount1();
        if (amount1 > minAmount1 && preimage.disputeDelay != 0) revert Errors.InvalidAmount1();

        address swapper = s.swapper;
        address collatToken = s.collatToken;
        address reporterFunder = msg.sender;
        address oracleToken1 = s.oracleToken1;
        address oracleToken2 = s.oracleToken2;

        // try to earn swapper's dutch auction if desired, then
        // record execution compensation, dutch leftover, and internal balance preference in memory
        DutchResolution memory dutchResolution = _consumeDutch(swapId, s, expectedDutchHash, reporter, collatToken);

        uint128 reportId = uint128(oracle.nextReportId());
        _setReportId(swapId, reportId);

        LiquidationHeartbeat storage heartbeatState = liquidationHeartbeats[swapId];
        if (
            heartbeatState.timestamp != 0 && heartbeatState.reportId == 0
                && block.timestamp <= uint256(heartbeatState.timestamp) + s.liquidationHeartbeatMax
        ) heartbeatState.reportId = reportId;

        // the caller can include execution gas compensation for this report if desired
        // also include swapper's paid execution gas compensation if it exists
        _addExecutionGasComp(reportId, altGasCompExec);
        _addExecutionGasComp(reportId, dutchResolution.inheritedExecutionComp);

        // adapters transfer the oracle amounts to the designated reporter so OpenOracle can spend from
        // the reporter's approved balances; execution compensation moves directly from caller to OpenPunt
        if (reporterFunder != reporter) {
            oracle.internalTransferFrom(reporterFunder, reporter, oracleToken1, amount1);
            oracle.internalTransferFrom(reporterFunder, reporter, oracleToken2, amount2);
        }

        oracle.internalTransferFrom(reporterFunder, address(this), address(0), altGasCompExec);
        uint256 createdReportId = oracleGame(s, preimage, timing, amount2, reporter, 0, amount1);
        if (createdReportId != reportId) revert Errors.InvalidReportId(); // sanity check
        emit PositionReportStarted(swapId, reportId, reporter, s);

        if (dutchResolution.leftover > 0) {
            if (dutchResolution.useInternalBalances) {
                oracle.internalTransferFrom(address(this), swapper, collatToken, dutchResolution.leftover);
            } else {
                oracle.pushOrCredit(collatToken, swapper, dutchResolution.leftover);
            }
        }
    }

    function _consumeDutch(
        uint256 swapId,
        MatchedSwap memory s,
        bytes32 expectedDutchHash,
        address reporter,
        address collatToken
    ) internal returns (DutchResolution memory resolution) {
        StoredDutch memory stored = closeAuctions[swapId];
        if (stored.maxReward == 0) {
            if (expectedDutchHash != bytes32(0)) revert Errors.WrongHash();
            return resolution;
        }

        CloseDutch memory dutch = _materializeDutch(swapId, s, stored);
        if (expectedDutchHash != bytes32(0) && expectedDutchHash != keccak256(abi.encode(dutch))) {
            revert Errors.WrongHash();
        }

        delete closeAuctions[swapId];
        resolution.inheritedExecutionComp = stored.executionComp;
        resolution.useInternalBalances = stored.useInternalBalances;

        uint128 reward;
        if (block.timestamp < dutch.expiration) {
            reward = uint128(
                calcFee(
                    dutch.maxReward,
                    dutch.startingReward,
                    dutch.growthRate,
                    dutch.maxRounds,
                    dutch.start,
                    dutch.roundLength
                )
            );
        }
        resolution.leftover = dutch.maxReward - reward;
        if (reward != 0) oracle.internalTransferFrom(address(this), reporter, collatToken, reward);
    }

    /**
     * @notice Settles the oracle report if needed, then opens or refunds a proposed position, or
     *         evaluates an active position for liquidation, close, or a reusable failed report.
     * @dev Permissionless. Active-position outcomes are determined at settlement eligibility, not
     *      transaction time. Liquidation has priority over close intent and maturity. Cadence or
     *      latency failures refund an opening or reset an active position rather than resolving it.
     * @param swapId Position identifier.
     * @param swapState Current MatchedSwap preimage committed in swaps[swapId].
     * @param oracleState Oracle game state matching the stored oracle hash; in OpenPunt's
     *                    block-number mode, reportTimestamp and settlementTime are measured in blocks,
     *                    while lastReportOppoTime supplies the report's wall-clock timestamp
     * @param oracleHelper Oracle preimage helper matching the stored oracle hash.
     * @param settlementTimestampSearchDepth Number of candidate settlement blocks to try, beginning
     *                                       with the current block; zero disables stale-settlement recovery.
     */
    function execute(
        uint256 swapId,
        MatchedSwap calldata swapState,
        IOpenOracle2.OracleGame calldata oracleState,
        IOpenOracle2.PreimageHelper calldata oracleHelper,
        uint8 settlementTimestampSearchDepth
    ) external payable {
        MatchedSwap memory s = swapState;
        bytes32 passedSwapHash = keccak256(abi.encode(s));
        if (passedSwapHash != swaps[swapId]) revert Errors.WrongHash();

        if (s.matcher == address(0)) revert Errors.NotMatched();
        if (s.swapper == address(0)) revert Errors.NotActive();
        uint256 reportId = swapIdToReportId(swapId);
        if (reportId == 0) revert Errors.NoOracleGame();
        if (oracleHelper.reportId != reportId) revert Errors.InvalidReportId();
        bytes32 oracleHash = oracle.oracleGame(reportId);
        if (settlementTimestampSearchDepth > MAX_SETTLEMENT_TIMESTAMP_SEARCH_DEPTH) {
            revert Errors.InvalidSettlementLookback();
        }

        IOpenOracle2.OracleGame memory oracleStateMem = oracleState;
        IOpenOracle2.PreimageHelper memory oracleHelperMem = oracleHelper;
        bytes32 passedHash = keccak256(abi.encode(oracleStateMem, oracleHelperMem));

        bool matches = oracleHash == passedHash;
        bool alreadySettled;
        bool active = s.active;

        // Recover when settlement changed only settlementTimestamp after the caller built its preimage.
        // Encode once, mutate that single word, and hash the same buffer for every candidate block.
        if (!matches && oracleStateMem.settlementTimestamp == 0 && settlementTimestampSearchDepth != 0) {
            bytes memory encodedOracleState = abi.encode(oracleStateMem, oracleHelperMem);
            uint256 currentBlock = _getBlockNumber();
            uint256 attempts = settlementTimestampSearchDepth;
            for (uint256 i; i < attempts; ++i) {
                uint256 candidate = currentBlock - i;
                bytes32 candidateHash;
                assembly ("memory-safe") {
                    // ABI word 4 of OracleGame is settlementTimestamp. `bytes` begins with its length.
                    mstore(add(encodedOracleState, 0xa0), candidate)
                    candidateHash := keccak256(add(encodedOracleState, 0x20), mload(encodedOracleState))
                }
                if (candidateHash == oracleHash) {
                    oracleStateMem.settlementTimestamp = uint48(candidate);
                    matches = true;
                    alreadySettled = true;
                    break;
                }
            }
        }

        if (!matches) revert Errors.WrongOracleHash();

        if (_getBlockNumber() < oracleState.reportTimestamp + oracleState.settlementTime) {
            revert Errors.OracleSettlementNotEligible();
        }

        uint48 requestedCloseAt = closeRequestBlock(swapId);

        // if the swapper's close request was too late, it doesn't apply to this oracle game
        bool closeRequestApplies = requestedCloseAt != 0
            && uint256(requestedCloseAt) < uint256(oracleState.reportTimestamp) + oracleState.settlementTime;

        uint96 openExecutionComp = s.openExecutionComp;
        s.openExecutionComp = 0;
        uint96 settlerReward = oracleState.settlerReward;
        uint128 altGasCompExec = executionGasComp[reportId];
        tempHolding[msg.sender] += openExecutionComp;

        if (altGasCompExec > 0) {
            executionGasComp[reportId] = 0;
            oracle.internalTransferFrom(address(this), msg.sender, address(0), altGasCompExec);
        }

        if (oracleState.settlementTimestamp == 0 && !alreadySettled) {
            // oracle.settle is an external call, but all oracle games created by openPunt
            // have no callback, so there should be no reentrancy risk for this call
            oracle.settle(reportId, oracleState, oracleHelper);
            if (settlerReward > 0) {
                oracle.internalTransferFrom(address(this), msg.sender, address(0), settlerReward); // forward reward to executor
            }
        }

        address swapper = s.swapper;
        address matcher = s.matcher;
        address collatToken = s.collatToken;
        uint128 initialMarginMatcher = s.initialMarginMatcher;
        uint128 initialMarginSwapper = s.initialMarginSwapper;
        uint24 fulfillmentFee = s.fulfillmentFee;
        uint16 millisecondsPerBlock = s.millisecondsPerBlock;
        uint128 oracleAmount1 = oracleState.currentAmount1;
        uint128 oracleAmount2 = oracleState.currentAmount2;
        bool useInternalBalances = s.useInternalBalances;

        // derive a synthetic wall-clock eligibility timestamp from the expected block cadence
        uint48 syntheticSettlementDurationSeconds =
            uint48(uint256(oracleState.settlementTime) * millisecondsPerBlock / 1000);
        uint48 syntheticEligibilityTimestamp = oracleState.lastReportOppoTime + syntheticSettlementDurationSeconds;

        // validates slippage only for position opening
        uint256 price = Math.mulDiv(oracleAmount1, 1e30, oracleAmount2);
        bool slippageOk = toleranceCheck(price, s.priceTolerated, s.toleranceRange);

        // if cadence changes cause active position execution bailouts (e.g. for close or liquidation),
        // can recover after a week post-maturity
        uint256 cadenceRecoveryStart = uint256(s.maturity) + 1 weeks;

        // true if past recovery start and the oracle game's last report was inside the recovery window
        bool cadenceRecovery =
            active && block.timestamp >= cadenceRecoveryStart && oracleState.lastReportOppoTime >= cadenceRecoveryStart;

        // check if the realized blocks per second were within tolerance since last oracle report.
        // override output if in cadenceRecovery
        bool blockCadenceOk = cadenceRecovery
            || impliedMillisecondsPerBlock(
                oracleState.lastReportOppoTime, oracleState.reportTimestamp, millisecondsPerBlock
            );

        // as long as we are not in recovery mode, if execution is too late reject the oracle game
        bool executionTooLate = !cadenceRecovery && s.maxExecutionLatency != 0
            && block.timestamp > uint256(syntheticEligibilityTimestamp) + s.maxExecutionLatency;

        bool slippageBailoutForOpen = !slippageOk && !active;
        bool openingGameTimedOut = !active && block.timestamp > uint256(s.start) + s.maxGameTime;
        // decide if position-opening oracle games should bail out and refund
        bool shouldRefundOnOpen = openingGameTimedOut || slippageBailoutForOpen || !blockCadenceOk || executionTooLate;

        // decide if close or liquidation oracle games should bail out:
        bool shouldBailoutCloseOrLiq = !blockCadenceOk || executionTooLate;

        // position being opened
        if (!active) {
            if (shouldRefundOnOpen) {
                // delete position and refund if position was being opened and it bails out
                delete swaps[swapId];
                _deleteReportId(swapId);
                refund(collatToken, initialMarginSwapper, swapper, initialMarginMatcher, matcher, s.useInternalBalances);
                if (openingGameTimedOut) emit OpeningBailedOut(swapId);
                if (slippageBailoutForOpen) emit SlippageBailout(swapId);
                if (!blockCadenceOk) emit ImpliedMillisecondsPerBlockBailout(swapId);
                if (executionTooLate) emit MaxExecutionLatencyBailout(swapId);
                emit PositionOpeningFailed(swapId, reportId);
                emit SwapRefunded(swapId, swapper, matcher);
            } else {
                // open position normally
                uint256 openFee = Math.mulDiv(s.notional, fulfillmentFee, 1e7);
                s.initialMarginSwapper -= uint128(openFee);
                s.active = true;
                s.oracleAmount1 = oracleAmount1;
                s.oracleAmount2 = oracleAmount2;
                s.maturity = syntheticEligibilityTimestamp + s.maturityWindow;
                s.start = syntheticEligibilityTimestamp;
                _clearReportId(swapId);
                swaps[swapId] = keccak256(abi.encode(s));
                oracle.internalTransferFrom(address(this), matcher, collatToken, uint128(openFee));
                emit PositionOpened(swapId, s);
            }
        } else {
            // position is already open: oracle reports can either close, liquidate,
            // or fail to liquidate if position is healthy and no close request applies

            // record current heartbeat info
            LiquidationHeartbeat memory heartbeatState = liquidationHeartbeats[swapId];
            delete liquidationHeartbeats[swapId];

            if (shouldBailoutCloseOrLiq) {
                // sets swapper's close request block to 0
                if (closeRequestApplies) _clearCloseRequest(swapId);

                // removes oracle game id associated with this swapId
                _clearReportId(swapId);

                if (!blockCadenceOk) emit ImpliedMillisecondsPerBlockBailout(swapId);
                if (executionTooLate) emit MaxExecutionLatencyBailout(swapId);
                emit PositionReportBailedOut(swapId, reportId);
            } else {
                // position is already active and the oracle game doesn't trigger bailout conditions

                // Amounts in s are the opening oracle amounts; locals are the closing amounts.
                // These are the two cross-products needed for either reciprocal PnL orientation.
                uint256 token2PerToken1CurrentCross = uint256(oracleAmount2) * s.oracleAmount1;
                uint256 token2PerToken1OpeningCross = uint256(s.oracleAmount2) * oracleAmount1;

                uint256 currentCross =
                    s.pnlUsesToken1PerToken2 ? token2PerToken1OpeningCross : token2PerToken1CurrentCross;
                uint256 openingCross =
                    s.pnlUsesToken1PerToken2 ? token2PerToken1CurrentCross : token2PerToken1OpeningCross;

                bool ratioIncreased = currentCross >= openingCross;
                uint256 priceDelta = ratioIncreased ? currentCross - openingCross : openingCross - currentCross;
                bool swapperProfits = ratioIncreased == s.swapperIsLong;
                uint256 syntheticTimeElapsed = uint256(syntheticEligibilityTimestamp) - s.start;
                int256 signedRate = int256(s.fundingRate);
                uint256 absoluteRate = signedRate < 0 ? uint256(-signedRate) : uint256(signedRate);
                uint256 fundingMagnitude = Math.mulDiv(s.notional, absoluteRate * syntheticTimeElapsed, 1e7 * 365 days);

                uint256 marginSum = uint256(initialMarginMatcher) + initialMarginSwapper;
                uint256 pnlCap = marginSum + fundingMagnitude + 1;
                uint256 pricePnl = mulDivCapped(s.notional, priceDelta, openingCross, pnlCap);

                bool intendedClose = closeRequestApplies;
                bool maturityPassed = syntheticEligibilityTimestamp >= s.maturity;

                int256 netChange = swapperProfits ? int256(pricePnl) : -int256(pricePnl);

                if (signedRate > 0) {
                    // swapper pays matcher
                    netChange -= int256(fundingMagnitude);
                } else if (signedRate < 0) {
                    // matcher pays swapper
                    netChange += int256(fundingMagnitude);
                }

                int256 swapperEquity = int256(uint256(initialMarginSwapper)) + netChange;

                // does this oracle price imply the swapper is in liquidation range
                bool isLiq = swapperEquity < int256(uint256(s.maintenanceMarginSwapper));

                // is a liquidation authorized
                // Require both synthetic eligibility and real elapsed time to satisfy the notice.
                uint256 heartbeatClock = Math.min(uint256(syntheticEligibilityTimestamp), block.timestamp);
                bool liquidationAuthorized = s.liquidationHeartbeatMax == 0
                    || (
                        heartbeatState.reportId == reportId
                            && heartbeatClock >= uint256(heartbeatState.timestamp) + s.liquidationHeartbeatMin
                    );

                if (isLiq && !liquidationAuthorized) {
                    // if swapper is liquidatable but liquidation is not authorized

                    // set the swapper's close request block to 0
                    if (closeRequestApplies) _clearCloseRequest(swapId);

                    // releases the report binding while preserving the original heartbeat timestamp
                    liquidationHeartbeats[swapId] =
                        LiquidationHeartbeat({reportId: 0, timestamp: heartbeatState.timestamp});

                    // removes oracle game id associated with this swapId
                    _clearReportId(swapId);

                    emit LiquidationHeartbeatBailout(swapId, uint128(reportId));
                    emit PositionReportBailedOut(swapId, reportId);
                } else if (isLiq) {
                    // if liquidatable AND liquidation is authorized

                    // end position
                    delete swaps[swapId];
                    _deleteReportId(swapId);
                    _returnAuction(swapId, s);

                    // matcher gets all the collateral
                    oracle.internalTransferFrom(address(this), matcher, collatToken, uint128(marginSum));
                    emit PositionLiquidated(swapId, reportId, marginSum);
                } else if (intendedClose || maturityPassed) {
                    // if either maturity passed or the swapper wanted to close

                    // close position
                    delete swaps[swapId];
                    _deleteReportId(swapId);
                    _returnAuction(swapId, s);
                    uint256 owedToSwapper;

                    // clamp swapper's final payout to existing margin
                    if (swapperEquity <= 0) {
                        owedToSwapper = 0;
                    } else {
                        owedToSwapper = uint256(swapperEquity);
                        if (owedToSwapper > marginSum) owedToSwapper = marginSum;
                    }

                    uint256 owedToMatcher = marginSum - owedToSwapper;

                    oracle.internalTransferFrom(address(this), matcher, collatToken, uint128(owedToMatcher));
                    if (useInternalBalances) {
                        oracle.internalTransferFrom(address(this), swapper, collatToken, uint128(owedToSwapper));
                    } else {
                        oracle.pushOrCredit(collatToken, swapper, uint128(owedToSwapper));
                    }
                    emit PositionClosed(swapId, reportId, owedToSwapper, owedToMatcher);
                } else {
                    // effectively a liquidation failure: the report passed cadence and latency checks,
                    // position is healthy, no applicable close request exists, and
                    // maturity has not passed.
                    _clearReportId(swapId);
                    emit LiquidationFailed(swapId, reportId);
                }
            }
        }
    }

    /**
     * @notice Cancels a close request while no report is live and returns any unclaimed auction funding.
     * @dev A live report blocks cancellation so the swapper cannot revoke intent after observing its price.
     *      This function is called through the OpenPunt core fallback and executes against core storage.
     * @param swapId Position identifier.
     * @param swapState Current active MatchedSwap preimage committed in swaps[swapId].
     */
    function cancelCloseAuction(uint256 swapId, MatchedSwap calldata swapState) external {
        MatchedSwap memory s = swapState;
        if (keccak256(abi.encode(s)) != swaps[swapId]) revert Errors.WrongHash();
        if (msg.sender != s.swapper) revert Errors.NotSwapper();
        if (!s.active) revert Errors.NotActive();
        if (swapIdToReportId(swapId) != 0) revert Errors.OracleGameInProgress();
        if (closeRequestBlock(swapId) == 0) revert Errors.NothingToWithdraw();

        StoredDutch memory stored = closeAuctions[swapId];
        _clearCloseRequest(swapId);

        if (stored.maxReward != 0) {
            _returnAuction(swapId, s);
        }

        emit CloseIntentCancelled(swapId);
    }

    /**
     * @notice Deploys a position's fee receiver if needed, then distributes its accrued oracle fees.
     * @dev CREATE2 binds the receiver address to all five immutable arguments. Incorrect arguments
     *      therefore deploy a distinct empty receiver and cannot redirect fees committed to the genuine
     *      receiver. Deployment is permissionless and may occur before fees accrue; an empty distribution
     *      is a no-op.
     * @param swapId Position identifier used as the deterministic deployment salt.
     * @param token1 First oracle token encoded into the receiver.
     * @param token2 Second oracle token encoded into the receiver.
     * @param swapper Swapper encoded into the receiver and used for its token split.
     * @param matcher Matcher encoded into the receiver and used for its token split.
     * @return feeReceiver Deployed or previously deployed receiver address.
     * @return fees1 Amount of token1 distributed in this call.
     * @return fees2 Amount of token2 distributed in this call.
     */
    function deployAndDistributeFeeReceiver(
        uint256 swapId,
        address token1,
        address token2,
        address swapper,
        address matcher
    ) external nonReentrant returns (address feeReceiver, uint256 fees1, uint256 fees2) {
        bytes memory args = abi.encodePacked(swapId, token1, token2, swapper, matcher);
        feeReceiver = LibClone.predictDeterministicAddress(feeReceiverImpl, args, bytes32(swapId), address(this));

        if (feeReceiver.code.length == 0) {
            feeReceiver = LibClone.cloneDeterministic(feeReceiverImpl, args, bytes32(swapId));
        }

        (fees1, fees2) = OpenPuntFeeReceiver(feeReceiver).distribute();
    }

    /// @dev Creates active-position games in block-number mode with settlement-eligibility storage
    ///      enabled. The preimage's settlementTime and disputeDelay therefore represent block counts.
    /// @param s Active position supplying tokens and fee-recipient context.
    /// @param o Committed oracle-game parameters.
    /// @param timing OpenOracle timing bounds.
    /// @param amount2 Token2 liquidity supplied to the report.
    /// @param matcher Designated reporter.
    /// @param settlerReward ETH-denominated reward forwarded to OpenOracle.
    /// @param customAmount1 Optional token1 liquidity override; zero selects o.initialLiquidity.
    /// @return reportId Newly allocated OpenOracle report identifier.
    function oracleGame(
        MatchedSwap memory s,
        MatcherPreimage memory o,
        IOpenOracle2.TimingBoundaries memory timing,
        uint128 amount2,
        address matcher,
        uint96 settlerReward,
        uint128 customAmount1
    ) internal returns (uint256 reportId) {
        IOpenOracle2.OracleGame memory params = IOpenOracle2.OracleGame({
            currentAmount1: customAmount1 > 0 ? customAmount1 : o.initialLiquidity,
            currentAmount2: amount2,
            currentReporter: matcher,
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: s.oracleToken1,
            lastReportOppoTime: 0,
            settlementTime: o.settlementTime,
            escalationHalt: o.escalationHalt,
            protocolFeeRecipient: s.feeRecipient,
            settlerReward: settlerReward,
            token2: s.oracleToken2,
            numReports: 0,
            disputeDelay: o.disputeDelay,
            feePercentage: 0,
            multiplier: o.multiplier,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: o.protocolFee,
            flags: 1 << 4
        });

        reportId = oracle.report{value: settlerReward}(params, true, true, timing);
    }

    /// @dev Adds ETH-denominated executor compensation to an existing report allocation.
    function _addExecutionGasComp(uint256 reportId, uint128 altGasCompExec) internal {
        executionGasComp[reportId] += altGasCompExec;
    }

    /// @dev Returns opening margins after a failed opening report. The swapper's delivery channel
    ///      follows useInternalBalances; matcher collateral always returns internally.
    function refund(
        address collatToken,
        uint128 initialMarginSwapper,
        address swapper,
        uint128 initialMarginMatcher,
        address matcher,
        bool useInternalBalances
    ) internal {
        if (useInternalBalances) {
            oracle.internalTransferFrom(address(this), swapper, collatToken, initialMarginSwapper);
        } else {
            oracle.pushOrCredit(collatToken, swapper, initialMarginSwapper);
        }
        oracle.internalTransferFrom(address(this), matcher, collatToken, initialMarginMatcher);
    }

    /// @dev Returns the current geometrically increasing Dutch reward, capped at maxFee.
    function calcFee(
        uint256 maxFee,
        uint256 startingFee,
        uint256 growthRate,
        uint256 maxRounds,
        uint256 startFulfillFeeIncrease,
        uint256 roundLength
    ) internal view returns (uint256) {
        uint256 timeDelta = block.timestamp - startFulfillFeeIncrease;

        timeDelta = timeDelta / roundLength;
        if (timeDelta > maxRounds) {
            timeDelta = maxRounds;
        }

        uint256 currentFee = startingFee;

        for (uint256 i = 0; i < timeDelta;) {
            currentFee = (currentFee * growthRate) / 10000;
            if (currentFee >= maxFee) {
                return maxFee;
            }
            unchecked {
                ++i;
            }
        }

        return currentFee;
    }

    /// @dev Tests whether price lies inside the multiplicatively symmetric opening tolerance band.
    function toleranceCheck(uint256 price, uint256 priceTolerated, uint24 toleranceRange)
        internal
        pure
        returns (bool)
    {
        uint256 tr = uint256(toleranceRange);
        uint256 upper = Math.mulDiv(priceTolerated, 1e7 + tr, 1e7);
        uint256 lower = Math.mulDiv(priceTolerated, 1e7, 1e7 + tr);

        return price >= lower && price <= upper;
    }

    /// @dev Checks the elapsed wall-clock milliseconds against elapsed block count. In block mode,
    ///      `reportTimestamp` here is the report's wall-clock `lastReportOppoTime`, while
    ///      `reportBlockNumber` is the oracle game's `reportTimestamp`.
    /// @return True when the two elapsed clocks differ by no more than two seconds.
    function impliedMillisecondsPerBlock(uint48 reportTimestamp, uint48 reportBlockNumber, uint16 millisecondsPerBlock)
        internal
        view
        returns (bool)
    {
        uint256 elapsedMilliseconds = (uint256(uint48(block.timestamp)) - reportTimestamp) * 1000;
        uint256 expectedMilliseconds = (uint256(_getBlockNumber()) - reportBlockNumber) * millisecondsPerBlock;

        return expectedMilliseconds <= elapsedMilliseconds + 2000 && elapsedMilliseconds <= expectedMilliseconds + 2000;
    }

    /// @dev Computes x * y / denominator without overflowing intermediate cross-products and caps the result.
    /// @return The floor-divided product, limited to cap.
    function mulDivCapped(uint256 x, uint256 y, uint256 denominator, uint256 cap) internal pure returns (uint256) {
        if (x == 0 || y == 0 || cap == 0) return 0;

        uint256 quotient = y / denominator;
        uint256 remainder = y % denominator;

        if (quotient > cap / x) return cap;

        uint256 whole = quotient * x;
        if (whole >= cap) return cap;

        uint256 fractional = Math.mulDiv(x, remainder, denominator);

        return fractional >= cap - whole ? cap : whole + fractional;
    }
}
