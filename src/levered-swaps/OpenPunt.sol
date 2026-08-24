// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";
import {OpenPuntStorage} from "./OpenPuntStorage.sol";
import {OpenPuntLifecycle} from "./OpenPuntLifecycle.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISignatureTransfer} from "../interfaces/ISignatureTransfer.sol";
import {PuntErrors as Errors} from "../libraries/PuntErrors.sol";

/**
 * @title openPunt
 * @notice A user proposes a leveraged swap, someone matches it, and openOracle determines the execution price.
 *         The matcher earns a fee for their service.
 *
 *         In openOracle, a price report is two limit orders, a buy and a sell, at the same price.
 *         The orders are locked until either the settlement block window ends or one is taken.
 *         To take one of the limit orders, you replace them with larger ones at a new price.
 *         When the block window ends without a dispute, the price is settled. Any dispute resets the window.
 *
 *         OpenPunt is intended for L2 deployment. Its block-cadence bailout and recovery logic assumes
 *         regular L2 block production and is not calibrated for Ethereum L1, where missed slots advance
 *         wall-clock time without producing corresponding execution blocks.
 *
 *         Supported token types: vanilla ERC20 and USDT-style tokens that omit a return value on transfer/transferFrom.
 *         Not supported: fee-on-transfer, rebasing, ERC777 / tokens with transfer hooks, or any token whose
 *         balance can change without a corresponding transfer event from this contract. Using unsupported tokens
 *         may cause loss of funds or incorrect fee accounting.
 * @author OpenOracle Team
 * @custom:version 0.2.0
 * @custom:documentation https://docs.openoracle.org/
 */
contract openPunt is OpenPuntStorage {
    address public immutable feeReceiverImpl;
    address public immutable lifecycleModule;

    /// @dev Binds the core to a lifecycle module using the same oracle and a deployed fee-receiver implementation.
    /// @param oracle_ OpenOracle contract used for custody, reports, and settlement.
    /// @param lifecycleModule_ Module delegatecalled for report, execute, and fee-receiver operations.
    constructor(address oracle_, address lifecycleModule_) OpenPuntStorage(oracle_) {
        OpenPuntLifecycle module = OpenPuntLifecycle(lifecycleModule_);
        if (lifecycleModule_.code.length == 0 || address(module.oracle()) != oracle_) {
            revert Errors.InvalidLifecycleModule();
        }
        address feeReceiverImpl_ = module.feeReceiverImpl();
        if (feeReceiverImpl_.code.length == 0) revert Errors.InvalidLifecycleModule();
        feeReceiverImpl = feeReceiverImpl_;
        lifecycleModule = lifecycleModule_;
    }

    /// @notice Routes supported lifecycle calls to the immutable module.
    /// @dev Executes by delegatecall against the core's storage and bubbles returndata unchanged.
    ///      Every selector outside report, execute, and deployAndDistributeFeeReceiver is rejected.
    fallback() external {
        if (
            msg.sig != OpenPuntLifecycle.report.selector && msg.sig != OpenPuntLifecycle.execute.selector
                && msg.sig != OpenPuntLifecycle.deployAndDistributeFeeReceiver.selector
        ) {
            revert Errors.InvalidSelector();
        }

        address module = lifecycleModule;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let inputSize := calldatasize()
            calldatacopy(ptr, 0, inputSize)

            let success := delegatecall(gas(), module, ptr, inputSize, 0, 0)

            let outputSize := returndatasize()
            returndatacopy(ptr, 0, outputSize)
            if iszero(success) { revert(ptr, outputSize) }
            return(ptr, outputSize)
        }
    }

    // -------------------------------------------------------------------------
    // External lifecycle
    // -------------------------------------------------------------------------

    /**
     * @notice Proposes a leveraged position and escrows the swapper's collateral through OpenOracle.
     * @dev Only the swap hash is stored on-chain. All future callers (matchSwap, cancelSwap, execute,
     *      bailOut) must supply the exact ProposedSwap / MatcherPreimage / MatchedSwap that
     *      reconstructs the current swap hash; off-chain indexing is the caller's responsibility.
     * @param s ProposedSwap parameters; s.swapper is set to msg.sender and s.expiration is converted to an absolute timestamp by the contract
     * @param m MatcherPreimage parameters; settlementTime and disputeDelay are block counts, and
     *          startFulfillFeeIncrease is set to block.timestamp by the contract
     * @param permit2 Permit2 nonce / deadline / signature, used when collatToken is ERC20 and useInternalBalances is false
     * @return swapId Sequence number assigned to the new swap
     */
    function propose(ProposedSwap calldata s, MatcherPreimage calldata m, Permit2Params calldata permit2)
        external
        payable
        returns (uint256 swapId)
    {
        uint256 extraEth = s.matcherGasComp + uint256(s.settlerReward) + s.openExecutionComp;
        address collatToken = s.collatToken;
        uint128 initialMarginSwapper = s.initialMarginSwapper;
        uint128 maintenanceMarginSwapper = s.maintenanceMarginSwapper;
        uint24 fulfillmentFee = s.fulfillmentFee;
        uint48 expiration = s.expiration;
        bool useInternalBalances = s.useInternalBalances;
        bool isEth = collatToken == address(0);
        bool needsPermit2 = !useInternalBalances && !isEth;
        uint256 expected = (isEth && !useInternalBalances) ? initialMarginSwapper + extraEth : extraEth;

        if (maintenanceMarginSwapper >= initialMarginSwapper) revert Errors.InvalidMargin();
        if (uint256(initialMarginSwapper) + uint256(s.initialMarginMatcher) > type(uint128).max) {
            revert Errors.InvalidMargin();
        }
        uint128 startingBuffer = initialMarginSwapper - maintenanceMarginSwapper;

        if (msg.value != expected) revert Errors.InvalidMsgValue();
        if (s.oracleToken1 == s.oracleToken2) revert Errors.TokensCannotBeSame();
        if (initialMarginSwapper == 0 || s.initialMarginMatcher == 0 || s.notional == 0) revert Errors.ZeroAmount();
        if (expiration == 0 || expiration > 30 days) revert Errors.InvalidExpiration();
        if (s.maturityWindow == 0 || s.maturityWindow > 30 days) revert Errors.InvalidMaturity();
        if (s.maxExecutionLatency != 0 && (s.maxExecutionLatency < 1 minutes || s.maxExecutionLatency > 1 hours)) {
            revert Errors.InvalidExecutionLatency();
        }
        bool heartbeatDisabled = s.liquidationHeartbeatMin == 0 && s.liquidationHeartbeatMax == 0;
        if (
            !heartbeatDisabled
                && (
                    s.liquidationHeartbeatMin < 30 seconds || s.liquidationHeartbeatMax > 5 minutes
                        || s.liquidationHeartbeatMax <= s.liquidationHeartbeatMin
                )
        ) revert Errors.InvalidLiquidationHeartbeat();

        if (s.priceTolerated == 0 || s.toleranceRange == 0 || s.toleranceRange > 1e7) revert Errors.InvalidSlippage();

        uint256 settlementDurationMilliseconds = uint256(m.settlementTime) * s.millisecondsPerBlock;
        if (
            m.settlementTime == 0 || m.initialLiquidity == 0 || s.millisecondsPerBlock == 0
                || m.disputeDelay >= m.settlementTime || m.escalationHalt < m.initialLiquidity
                || settlementDurationMilliseconds > 4 hours * 1000 || m.protocolFee >= 1e7
                || uint256(s.maxGameTime) * 1000 < settlementDurationMilliseconds * 20 || s.maxGameTime > 604800
                || m.multiplier < 100
        ) revert Errors.InvalidOracleParams();

        // auction mode
        int32 maxAbsFunding = 100_000_000; // 1,000% annualized

        if (
            m.maxRounds == 0 || m.maxRounds > 200 // 200 should be gas-ok
                || m.roundLength == 0
        ) revert Errors.InvalidFulfillFeeParams();

        if (s.auctionFunding) {
            if (m.auctionStart < -maxAbsFunding || m.auctionEnd > maxAbsFunding || m.auctionStart >= m.auctionEnd) {
                revert Errors.InvalidFundingRate();
            }
            uint256 maximumFeeAmount = Math.mulDiv(s.notional, s.fulfillmentFee, 1e7);
            if (s.fulfillmentFee >= 1e7 || 2 * maximumFeeAmount >= startingBuffer) {
                revert Errors.InvalidFulfillFee();
            }
            if (s.fundingRate != 0) revert Errors.MustBeZero();
        } else {
            if (m.auctionStart <= 0 || m.auctionEnd < m.auctionStart || m.auctionEnd >= 1e7 || m.growthRate < 10000) {
                revert Errors.InvalidFulfillFee();
            }
            uint256 maximumFeeAmount = Math.mulDiv(s.notional, uint256(int256(m.auctionEnd)), 1e7);
            if (2 * maximumFeeAmount >= startingBuffer) revert Errors.InvalidFulfillFee();
            if (s.fundingRate < -maxAbsFunding || s.fundingRate > maxAbsFunding) revert Errors.InvalidFundingRate();
            if (s.fulfillmentFee != 0) revert Errors.MustBeZero();
        }

        if (s.swapper != address(0) || m.startFulfillFeeIncrease != 0) revert Errors.MustBeZero();

        swapId = nextSwapId++;

        ProposedSwap memory swap = s;
        MatcherPreimage memory mp = m;

        swap.swapper = msg.sender;
        bytes32 permitIntent;
        if (needsPermit2) permitIntent = keccak256(abi.encode(swap, mp));

        swap.expiration = uint48(uint256(block.timestamp) + uint256(expiration));
        mp.startFulfillFeeIncrease = uint48(block.timestamp);
        bytes32 swapHash = keccak256(abi.encode(swap, mp));

        if (useInternalBalances) {
            oracle.internalTransferFrom(msg.sender, address(this), collatToken, initialMarginSwapper);
        } else {
            if (isEth) {
                oracle.deposit{value: initialMarginSwapper}(address(0), initialMarginSwapper, address(this));
            } else {
                oracle.depositFromPermit2(
                    initialMarginSwapper,
                    address(this),
                    msg.sender,
                    permitIntent,
                    ISignatureTransfer.PermitTransferFrom({
                        permitted: ISignatureTransfer.TokenPermissions({token: collatToken, amount: initialMarginSwapper}),
                        nonce: permit2.nonce,
                        deadline: permit2.deadline
                    }),
                    permit2.signature
                );
            }
        }

        swaps[swapId] = swapHash; // CEI inversion: swap becomes live only after funding succeeds.
        emit SwapProposed(swapId, swap, mp);
    }

    /**
     * @notice Matches a proposal, escrows the matcher's collateral, and starts the opening oracle report.
     * @dev The designated `matcher` must approve OpenPunt in OpenOracle for both oracle-token
     *      amounts because OpenPunt creates the opening game from the matcher's internal balance.
     *      `msg.sender` is the matcher funder and must approve OpenPunt for the matcher collateral
     *      and, when distinct from `matcher`, for both oracle-token amounts transferred to it.
     * @param swapId Position identifier returned by propose.
     * @param amount2 Token2 liquidity supplied to the opening oracle game.
     * @param _swap ProposedSwap preimage committed by propose.
     * @param preimage MatcherPreimage committed by propose; settlementTime and disputeDelay are block counts.
     * @param timing OpenOracle timing bounds for the opening report.
     * @param matcher Account recorded as counterparty and opening reporter; may differ from msg.sender.
     */
    function matchSwap(
        uint256 swapId,
        uint128 amount2,
        ProposedSwap calldata _swap,
        MatcherPreimage calldata preimage,
        IOpenOracle2.TimingBoundaries calldata timing,
        address matcher
    ) external {
        bytes32 passedHash = keccak256(abi.encode(_swap, preimage));
        if (passedHash != swaps[swapId]) revert Errors.WrongHash();

        MatchedSwap memory s;

        s.initialMarginSwapper = _swap.initialMarginSwapper;
        s.initialMarginMatcher = _swap.initialMarginMatcher;
        s.maintenanceMarginSwapper = _swap.maintenanceMarginSwapper;
        s.maturityWindow = _swap.maturityWindow;
        s.notional = _swap.notional;
        s.maxGameTime = _swap.maxGameTime;
        s.maxExecutionLatency = _swap.maxExecutionLatency;
        s.liquidationHeartbeatMin = _swap.liquidationHeartbeatMin;
        s.liquidationHeartbeatMax = _swap.liquidationHeartbeatMax;
        s.millisecondsPerBlock = _swap.millisecondsPerBlock;
        s.oracleToken2 = _swap.oracleToken2;
        s.oracleToken1 = _swap.oracleToken1;
        s.swapper = _swap.swapper;
        s.openExecutionComp = _swap.openExecutionComp;
        s.useInternalBalances = _swap.useInternalBalances;
        s.priceTolerated = _swap.priceTolerated;
        s.toleranceRange = _swap.toleranceRange;
        s.collatToken = _swap.collatToken;
        s.swapperIsLong = _swap.isLong;
        s.matcherPreimageHash = keccak256(abi.encode(preimage));

        address oracleToken2 = s.oracleToken2;
        address oracleToken1 = s.oracleToken1;
        address collatToken = s.collatToken;
        uint128 initialMarginMatcher = s.initialMarginMatcher;
        uint96 matcherGasComp = _swap.matcherGasComp;
        uint96 settlerReward = _swap.settlerReward;

        if (s.swapper == address(0)) revert Errors.NotActive();
        if (matcher == address(0)) revert Errors.AddressCannotBeZero();
        if (matcher == address(this)) revert Errors.ContractCannotBeParticipant();
        if (block.timestamp > _swap.expiration) revert Errors.Expired();

        address matcherFunder = msg.sender;
        if (_swap.auctionFunding) {
            s.fulfillmentFee = _swap.fulfillmentFee;

            s.fundingRate = calcLinearRate(
                preimage.auctionStart,
                preimage.auctionEnd,
                preimage.startFulfillFeeIncrease,
                preimage.roundLength,
                preimage.maxRounds
            );
        } else {
            s.fulfillmentFee = uint24(
                calcFee(
                    uint256(int256(preimage.auctionEnd)),
                    uint256(int256(preimage.auctionStart)),
                    preimage.growthRate,
                    preimage.maxRounds,
                    preimage.startFulfillFeeIncrease,
                    preimage.roundLength
                )
            );

            s.fundingRate = _swap.fundingRate;
        }

        s.matcher = matcher;
        s.start = uint48(block.timestamp);

        tempHolding[matcher] += matcherGasComp;

        if (preimage.protocolFee > 0) s.feeRecipient = _predictFeeReceiver(swapId, s);
        uint128 reportId = uint128(oracle.nextReportId());

        _setReportId(swapId, reportId);
        swaps[swapId] = keccak256(abi.encode(s));

        if (matcherFunder != matcher) {
            oracle.internalTransferFrom(matcherFunder, matcher, oracleToken1, preimage.initialLiquidity);
            oracle.internalTransferFrom(matcherFunder, matcher, oracleToken2, amount2);
        }

        uint256 createdReportId = oracleGame(s, preimage, timing, amount2, matcher, settlerReward, 0);
        if (createdReportId != reportId) revert Errors.InvalidReportId(); // sanity check
        oracle.internalTransferFrom(matcherFunder, address(this), collatToken, initialMarginMatcher);
        emit SwapMatched(swapId, reportId, s);
    }

    /**
     * @notice Records permissionless wall-clock notice for a possible liquidation.
     * @dev `liquidationHeartbeatMax` limits when this heartbeat may bind to a report; it is not an
     *      execution deadline. Once bound within that window, the heartbeat remains bound until the
     *      report executes. `maxExecutionLatency` separately limits stale report execution.
     * @param swapId Position identifier.
     * @param swapState Current MatchedSwap preimage committed in swaps[swapId].
     */
    function liquidationHeartbeat(uint256 swapId, MatchedSwap calldata swapState) external {
        if (tx.gasprice == 0) revert Errors.ForcedTransaction();
        if (keccak256(abi.encode(swapState)) != swaps[swapId]) revert Errors.WrongHash();
        if (!swapState.active) revert Errors.NotActive();
        if (swapState.liquidationHeartbeatMax == 0) revert Errors.InvalidLiquidationHeartbeat();

        LiquidationHeartbeat memory current = liquidationHeartbeats[swapId];
        uint128 reportId = uint128(swapIdToReportId(swapId));
        bool boundToCurrentReport = current.reportId != 0 && current.reportId == reportId;
        bool unboundWindowLive = current.timestamp != 0 && current.reportId == 0
            && block.timestamp <= uint256(current.timestamp) + swapState.liquidationHeartbeatMax;
        if (boundToCurrentReport || unboundWindowLive) revert Errors.LiquidationHeartbeatLive();

        uint48 timestamp = uint48(block.timestamp);
        liquidationHeartbeats[swapId] = LiquidationHeartbeat({reportId: reportId, timestamp: timestamp});
        emit LiquidationHeartbeatSet(swapId, reportId, timestamp);
    }

    /**
     * @notice Registers a close request and funds the compensation offered to the report executor.
     * @dev With a live report, records the request block and funds only that report's execution
     *      compensation. With no live report, also creates and funds the supplied Dutch auction.
     *      The caller always supplies Dutch terms so report-state changes cannot invalidate close calldata.
     * @param swapId Position identifier.
     * @param dutch Close-reward auction parameters. Override fields must be zero if no report is live.
     * @param swapState Current active MatchedSwap preimage committed in swaps[swapId].
     * @param useInternalBalances Whether this call funds its reward and ETH compensation from OpenOracle balances.
     * @param permit2 Permit2 authorization used for an externally funded ERC20 Dutch reward.
     * @param altGasCompExec ETH-denominated compensation offered to the relevant report executor.
     */
    function close(
        uint256 swapId,
        CloseDutch calldata dutch,
        MatchedSwap calldata swapState,
        bool useInternalBalances,
        Permit2Params calldata permit2,
        uint128 altGasCompExec
    ) external payable {
        MatchedSwap memory s = swapState;
        bytes32 passedSwapHash = keccak256(abi.encode(swapState));
        uint128 maxReward = dutch.maxReward;
        address collatToken = s.collatToken;
        bool isEth = collatToken == address(0);
        uint128 ethToReserve = altGasCompExec + (isEth ? maxReward : 0);

        if (passedSwapHash != swaps[swapId]) revert Errors.WrongHash();
        if (msg.sender != s.swapper) revert Errors.NotSwapper();
        if (!s.active) revert Errors.NotActive();
        if (closeRequestBlock(swapId) != 0) revert Errors.CloseIntentLive();

        uint256 reportId = swapIdToReportId(swapId);
        if (reportId != 0) {
            // A live report needs no Dutch reward. execute() decides whether this request preceded
            // that report's final settlement eligibility; otherwise it remains for a future report.
            uint256 expected = useInternalBalances ? 0 : ethToReserve;
            if (msg.value != expected) revert Errors.InvalidMsgValue();

            _setCloseRequest(swapId);
            _addExecutionGasComp(reportId, altGasCompExec);

            if (useInternalBalances) {
                oracle.internalTransferFrom(msg.sender, address(this), address(0), altGasCompExec);
            } else {
                // Deposit the caller's full race-safe ETH amount, then return the unused Dutch
                // maximum when collateral is ETH and a live report made the auction unnecessary.
                oracle.deposit{value: ethToReserve}(address(0), ethToReserve, address(this));
                if (isEth && maxReward != 0) oracle.pushOrCredit(address(0), s.swapper, maxReward);
            }

            emit CloseIntentSet(swapId, reportId, altGasCompExec);
            return;
        }

        CloseDutch memory d = dutch;
        uint128 expectedMsgValue = useInternalBalances ? 0 : ethToReserve;
        bool needsPermit2 = !isEth && !useInternalBalances;

        if (msg.value != expectedMsgValue) revert Errors.InvalidMsgValue();
        if (
            d.swapper != address(0) || d.collatToken != address(0) || d.useInternalBalances || d.start != 0
                || d.swapId != 0
        ) revert Errors.MustBeZero();
        // expiration sanity checks:
        if (d.expiration < block.timestamp || d.expiration > block.timestamp + 1 hours) {
            revert Errors.InvalidExpiration();
        }
        // reward curve sanity checks:
        if (
            maxReward == 0 || d.startingReward == 0 || d.growthRate < 10000 || d.maxRounds == 0 || d.maxRounds > 100 // 100 is ok for geometric growth
                || d.roundLength == 0 || maxReward < d.startingReward
        ) revert Errors.InvalidDutchParams();

        // overwrite fields:
        d.swapper = s.swapper;
        d.collatToken = collatToken;
        d.useInternalBalances = useInternalBalances;
        d.swapId = swapId;

        // start is volatile so zero it for permit intent, then overwrite after:
        d.start = 0;
        bytes32 permitIntent;
        if (needsPermit2) permitIntent = keccak256(abi.encode(d));
        d.start = uint48(block.timestamp);
        bytes32 dutchHash = keccak256(abi.encode(d));

        if (useInternalBalances) {
            oracle.internalTransferFrom(msg.sender, address(this), address(0), ethToReserve);
            if (!isEth) oracle.internalTransferFrom(msg.sender, address(this), collatToken, maxReward);
        } else {
            oracle.deposit{value: ethToReserve}(address(0), ethToReserve, address(this));
            if (!isEth) {
                // a hook token can re-enter here:
                oracle.depositFromPermit2(
                    maxReward,
                    address(this),
                    msg.sender,
                    permitIntent,
                    ISignatureTransfer.PermitTransferFrom({
                        permitted: ISignatureTransfer.TokenPermissions({token: collatToken, amount: maxReward}),
                        nonce: permit2.nonce,
                        deadline: permit2.deadline
                    }),
                    permit2.signature
                );
            }
        }

        // CEI inversion: the auction becomes live only after funding succeeds
        // If reentrancy changed this position's report, close request, or auction, revert atomically.
        if (
            swaps[swapId] != passedSwapHash || swapIdToReportId(swapId) != 0 || closeRequestBlock(swapId) != 0
                || closeAuctions[swapId].maxReward != 0
        ) revert Errors.WrongHash();

        closeAuctions[swapId] = StoredDutch({
            maxReward: maxReward,
            startingReward: d.startingReward,
            executionComp: altGasCompExec,
            start: d.start,
            roundLength: d.roundLength,
            expirationDuration: uint16(d.expiration - d.start),
            growthRate: d.growthRate,
            maxRounds: uint8(d.maxRounds),
            useInternalBalances: useInternalBalances
        });
        _setCloseRequest(swapId);

        emit CloseAuctionStarted(swapId, dutchHash, d, altGasCompExec);
    }

    /**
     * @notice Cancels a close request while no report is live and returns any unclaimed auction funding.
     * @dev A live report blocks cancellation so the swapper cannot revoke intent after observing its price.
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
        delete closeAuctions[swapId];
        _clearCloseRequest(swapId);

        if (stored.maxReward != 0) {
            CloseDutch memory d = _materializeDutch(swapId, s, stored);
            bytes32 dutchHash = keccak256(abi.encode(d));
            bool collatIsEth = s.collatToken == address(0);
            uint128 expectedEth = stored.executionComp + (collatIsEth ? stored.maxReward : 0);

            if (stored.useInternalBalances) {
                oracle.internalTransferFrom(address(this), s.swapper, address(0), expectedEth);
                if (!collatIsEth) {
                    oracle.internalTransferFrom(address(this), s.swapper, s.collatToken, stored.maxReward);
                }
            } else {
                oracle.pushOrCredit(address(0), s.swapper, expectedEth);
                if (!collatIsEth) oracle.pushOrCredit(s.collatToken, s.swapper, stored.maxReward);
            }

            emit CloseAuctionCancelled(swapId, dutchHash, d, stored.executionComp);
        }

        emit CloseIntentCancelled(swapId);
    }

    /**
     * @notice Cancels an unmatched proposal and returns the swapper's collateral and unused compensation.
     * @dev Through expiration only the swapper may cancel. After expiration anyone may cancel and
     *      earn matcherGasComp; the remaining compensation and settler reward belong to the swapper.
     * @param swapId Position identifier.
     * @param _swap ProposedSwap preimage committed by propose.
     * @param preimage MatcherPreimage committed by propose.
     */
    function cancelSwapOpen(uint256 swapId, ProposedSwap calldata _swap, MatcherPreimage calldata preimage)
        external
        nonReentrant
    {
        bytes32 passedHash = keccak256(abi.encode(_swap, preimage));
        if (passedHash != swaps[swapId]) revert Errors.WrongHash();
        ProposedSwap memory s = _swap;

        if (s.swapper == address(0)) revert Errors.NotActive();

        address caller;
        uint256 callerPiece;
        uint256 swapperPiece;

        address swapper = s.swapper;
        uint256 totalGasComp = uint256(s.matcherGasComp) + uint256(s.openExecutionComp);
        uint96 settlerReward = s.settlerReward;
        address collatToken = s.collatToken;
        uint128 initialMarginSwapper = s.initialMarginSwapper;

        if (block.timestamp <= s.expiration) {
            if (msg.sender != swapper) revert Errors.NotSwapper();
            callerPiece = 0;
            swapperPiece = totalGasComp;
        } else {
            if (msg.sender != swapper) {
                caller = msg.sender;
                callerPiece = s.matcherGasComp;
                swapperPiece = totalGasComp - callerPiece;
            } else {
                swapperPiece = totalGasComp;
            }
        }

        delete swaps[swapId];

        if (s.useInternalBalances) {
            tempHolding[swapper] += swapperPiece + settlerReward;
        }
        if (caller == msg.sender && callerPiece > 0) tempHolding[caller] += callerPiece;

        if (s.useInternalBalances) {
            oracle.internalTransferFrom(address(this), swapper, collatToken, initialMarginSwapper);
        } else {
            oracle.pushOrCredit(collatToken, swapper, initialMarginSwapper);
            payEth(swapper, swapperPiece + settlerReward);
        }

        emit SwapCancelled(swapId, s, preimage);
    }

    /**
     * @notice Refunds both parties when an opening oracle game exceeds maxGameTime.
     * @dev Permissionless and limited to matched positions that have not opened. The caller earns
     *      openExecutionComp; the swapper's settler reward remains attached to the oracle game.
     * @param swapId Position identifier.
     * @param _swap Current pre-opening MatchedSwap preimage committed in swaps[swapId].
     */
    function bailOut(uint256 swapId, MatchedSwap calldata _swap) external nonReentrant {
        bytes32 passedHash = keccak256(abi.encode(_swap));
        if (passedHash != swaps[swapId]) revert Errors.WrongHash();

        MatchedSwap memory s = _swap;

        if (s.matcher == address(0)) revert Errors.NotMatched();
        if (s.swapper == address(0)) revert Errors.NotActive();
        if (s.active || swapIdToReportId(swapId) == 0) revert Errors.CantBailOutYet();

        bool isGameTooLong = block.timestamp - s.start > s.maxGameTime;

        if (isGameTooLong) {
            delete swaps[swapId];
            _deleteReportId(swapId);
            tempHolding[msg.sender] += s.openExecutionComp;
            refund(
                s.collatToken,
                s.initialMarginSwapper,
                s.swapper,
                s.initialMarginMatcher,
                s.matcher,
                s.useInternalBalances
            );
            emit OpeningBailedOut(swapId, s);
            emit SwapRefunded(swapId, s.swapper, s.matcher, s);
            return;
        }

        revert Errors.CantBailOutYet();
    }

    // -------------------------------------------------------------------------
    // External balance utilities
    // -------------------------------------------------------------------------

    /// @notice Seeds a one-wei sentinel in an account's queued ETH balance.
    /// @dev The caller supplies the sentinel. This avoids a first-credit zero-to-nonzero storage write.
    /// @param _to Account whose tempHolding slot is seeded.
    function dust(address _to) external payable {
        if (msg.value != 1) revert Errors.InvalidMsgValue();
        tempHolding[_to] += 1;
    }

    /**
     * @notice Withdraws queued ETH gas-comp credits to `_to`. If caller != `_to`, a 1-wei
     *         sentinel is always preserved on `_to`'s slot.
     * @dev The ETH call forwards all remaining gas and reverts atomically if the recipient rejects payment.
     * @param _to Recipient of the withdrawn ETH.
     * @param leaveOne If true, preserve the one-wei sentinel even when msg.sender equals _to.
     */
    function withdraw(address _to, bool leaveOne) external nonReentrant {
        uint256 amount = tempHolding[_to];
        bool keepSentinel = leaveOne || msg.sender != _to;

        if (keepSentinel ? amount <= 1 : amount == 0) revert Errors.NothingToWithdraw();

        uint256 payout = keepSentinel ? amount - 1 : amount;
        tempHolding[_to] = keepSentinel ? 1 : 0;

        (bool ok,) = payable(_to).call{value: payout}("");
        if (!ok) revert Errors.EthTransferFailed();
    }

    // -------------------------------------------------------------------------
    // Internal oracle integration
    // -------------------------------------------------------------------------

    /// @dev Predicts the position's counterfactual fee receiver. The clone is deployed lazily by
    ///      `OpenPuntLifecycle.deployAndDistributeFeeReceiver`, but deployment is not conditional on
    ///      fees having accrued; distributing an empty receiver is a no-op.
    /// @param swapId Position identifier used as the deterministic deployment salt.
    /// @param s Matched position supplying the receiver's tokens and parties.
    /// @return Predicted receiver address deployed by the OpenPunt core.
    function _predictFeeReceiver(uint256 swapId, MatchedSwap memory s) internal view returns (address) {
        bytes memory args = abi.encodePacked(swapId, s.oracleToken1, s.oracleToken2, s.swapper, s.matcher);
        return LibClone.predictDeterministicAddress(feeReceiverImpl, args, bytes32(swapId), address(this));
    }

    /// @dev Creates the opening oracle game in block-number mode (`flags == 0`); the preimage's
    ///      settlementTime and disputeDelay therefore represent block counts.
    /// @param s Matched position supplying tokens, fee recipient, and reporter context.
    /// @param o Committed oracle-game parameters.
    /// @param timing OpenOracle timing bounds.
    /// @param amount2 Token2 liquidity supplied to the report.
    /// @param matcher Designated opening reporter.
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
            flags: 0
        });

        reportId = oracle.report{value: settlerReward}(params, true, true, timing);
    }

    // -------------------------------------------------------------------------
    // Internal accounting and transfers
    // -------------------------------------------------------------------------

    /// @dev Adds ETH-denominated executor compensation to an existing report allocation.
    /// @param reportId OpenOracle report receiving the compensation.
    /// @param altGasCompExec Amount added to the report allocation.
    function _addExecutionGasComp(uint256 reportId, uint128 altGasCompExec) internal {
        executionGasComp[reportId] += altGasCompExec;
    }

    /// @dev Bounded-gas ETH push used during state transitions. On failure, credits
    ///      `_to`'s `tempHolding` slot so the recipient can retrieve via `withdraw`.
    /// @param _to Recipient of the ETH payment or fallback credit.
    /// @param _amount Amount of wei to deliver.
    function payEth(address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        (bool ok,) = payable(_to).call{value: _amount, gas: 50000}("");
        if (!ok) tempHolding[_to] += _amount;
    }

    /// @dev Returns opening margins after a failed or timed-out opening game. The swapper's delivery
    ///      channel follows useInternalBalances; matcher collateral always returns internally.
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

    // -------------------------------------------------------------------------
    // Internal auction and validation math
    // -------------------------------------------------------------------------

    /// @dev Returns the current linearly interpolated funding rate, capped at the terminal round.
    /// @return Current funding rate, where 1e7 represents 100% annualized.
    function calcLinearRate(
        int32 startingRate,
        int32 endingRate,
        uint48 auctionStart,
        uint24 roundLength,
        uint16 maxRounds
    ) internal view returns (int32) {
        uint256 elapsedRounds = (block.timestamp - auctionStart) / roundLength;

        if (elapsedRounds >= maxRounds) return endingRate;

        int256 distance = int256(endingRate) - int256(startingRate);

        int256 currentRate = int256(startingRate) + distance * int256(elapsedRounds) / int256(uint256(maxRounds));

        return int32(currentRate);
    }

    /// @dev Returns the current geometrically increasing fee, capped at maxFee.
    /// @return Current fee, using the caller-supplied fee scale.
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
}
