// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";
import {PuntErrors as Errors} from "../libraries/PuntErrors.sol";

abstract contract OpenPuntStorage is ReentrancyGuard {
    IOpenOracle2 public immutable oracle;

    /// @dev Binds the OpenOracle instance shared by the core and lifecycle module.
    /// @param oracle_ OpenOracle contract used for custody, reports, and settlement.
    constructor(address oracle_) {
        oracle = IOpenOracle2(oracle_);
    }

    struct PositionControl {
        uint128 reportIdPlusOne; // one means idle; values above one encode the live report id plus one
        uint48 closeRequestBlock; // zero means no close request; otherwise the block in which close() registered it
    }

    struct StoredDutch {
        // slot 1
        uint128 maxReward;
        uint128 startingReward;
        // slot 2
        uint128 executionComp;
        uint48 start;
        uint24 roundLength;
        uint16 expirationDuration;
        uint16 growthRate;
        uint8 maxRounds;
        bool useInternalBalances;
    }

    struct LiquidationHeartbeat {
        uint128 reportId; // report bound to this heartbeat; zero while preserved for a future report
        uint48 timestamp; // original wall-clock notice time; preserved across an unauthorized liquidation
    }

    mapping(uint256 => bytes32) public swaps;
    mapping(uint256 swapId => StoredDutch) public closeAuctions;
    mapping(uint256 reportId => uint128 amount) public executionGasComp;
    mapping(uint256 swapId => LiquidationHeartbeat) public liquidationHeartbeats;
    uint256 public nextSwapId = 1;

    mapping(address => uint256) public tempHolding;
    mapping(uint256 swapId => PositionControl) private _positionControl;

    /// @notice Returns the live OpenOracle report for a swap, or zero while no report is live.
    function swapIdToReportId(uint256 swapId) public view returns (uint256) {
        uint256 reportIdPlusOne = _positionControl[swapId].reportIdPlusOne;
        return reportIdPlusOne > 1 ? reportIdPlusOne - 1 : 0;
    }

    /// @notice Returns the block in which the current close request was registered, or zero if none exists.
    function closeRequestBlock(uint256 swapId) public view returns (uint48) {
        return _positionControl[swapId].closeRequestBlock;
    }

    /// @dev Records a live report while keeping the storage slot nonzero across reusable outcomes.
    function _setReportId(uint256 swapId, uint256 reportId) internal {
        if (reportId >= type(uint128).max) revert Errors.InvalidReportId();
        _positionControl[swapId].reportIdPlusOne = uint128(reportId + 1);
    }

    /// @dev Marks an existing swap as having no live report without zeroing its report-state slot.
    function _clearReportId(uint256 swapId) internal {
        _positionControl[swapId].reportIdPlusOne = 1;
    }

    /// @dev Removes report state when the swap terminates.
    function _deleteReportId(uint256 swapId) internal {
        delete _positionControl[swapId];
    }

    function _setCloseRequest(uint256 swapId) internal {
        _positionControl[swapId].closeRequestBlock = _getBlockNumber();
    }

    function _clearCloseRequest(uint256 swapId) internal {
        _positionControl[swapId].closeRequestBlock = 0;
    }

    struct MatchedSwap {
        // Parties and assets
        address swapper; // account that proposed the position; nonzero means the swap exists
        address matcher; // position counterparty and reporter for the opening oracle game
        address collatToken; // collateral token for the leveraged swap
        address oracleToken1; // token1 used in every oracle game for the position
        address oracleToken2; // token2 used in every oracle game for the position
        // Margin and position economics
        uint128 initialMarginSwapper; // swapper collateral; reduced by the opening fee when activated
        uint128 initialMarginMatcher; // amount of collatToken the matcher must post to match
        uint128 maintenanceMarginSwapper; // swapper equity below this amount is liquidatable
        uint128 notional; // position notional denominated in collatToken
        bool swapperIsLong; // true when swapper profits from oracleToken2/oracleToken1 increasing
        uint24 fulfillmentFee; // 1e7 = 100%; opening and closing fee paid to matcher
        int32 fundingRate; // 1e7 = 100% annual; positive means swapper pays matcher
        // Oracle game state and commitments
        uint128 oracleAmount1; // token1 amount establishing the opening execution price
        uint128 oracleAmount2; // token2 amount establishing the opening execution price
        address feeRecipient; // contract holding protocol fees from oracle game
        bytes32 matcherPreimageHash; // commitment to immutable oracle and auction parameters
        // Price and timing protections
        uint232 priceTolerated; // expected oracleAmount1/oracleAmount2 ratio scaled by 1e30
        uint24 toleranceRange; // 1e7 = 100%; maximum opening-price deviation
        uint16 millisecondsPerBlock; // expected block interval in milliseconds; 2000 means one block per two seconds
        uint24 maxGameTime; // maximum opening-game duration before the parties can be refunded
        uint16 maxExecutionLatency; // 0 disables; otherwise max seconds from settlement eligibility to execution
        uint16 liquidationHeartbeatMin; // seconds of notice required by settlement eligibility before liquidation
        uint16 liquidationHeartbeatMax; // seconds in which a report may bind; not an execution deadline; zero with min zero disables
        // Lifecycle state
        uint48 start; // match timestamp before activation; opening settlement-eligibility time afterward
        uint48 maturity; // absolute timestamp after which any healthy report closes the position
        uint48 maturityWindow; // duration added to opening settlement eligibility to establish maturity
        bool active; // true after the opening oracle game successfully executes
        // Funding and execution compensation
        uint96 openExecutionComp; // ETH paid to opening executor; zero after opening execution
        bool useInternalBalances; // true routes swapper collateral and refunds through oracle balances
    }

    struct ProposedSwap {
        // Parties and assets
        address swapper; // override; must be zero and is set to msg.sender
        address collatToken; // collateral token for both parties and all position accounting
        address oracleToken1; // token1 used in every oracle game for the position
        address oracleToken2; // token2 used in every oracle game for the position
        // Margin and position economics
        uint128 initialMarginSwapper; // collatToken posted by the swapper
        uint128 initialMarginMatcher; // amount of collatToken the matcher must put in the contract
        uint128 maintenanceMarginSwapper; // swapper equity below this amount is liquidatable
        uint128 notional; // position notional denominated in collatToken
        bool isLong; // true when swapper profits from oracleToken2/oracleToken1 increasing
        int32 fundingRate; // 1e7 = 100% annual; fixed when fulfillment fee is auctioned
        uint24 fulfillmentFee; // 1e7 = 100%; fixed when funding is auctioned
        bool auctionFunding; // true auctions funding; false auctions fulfillment fee
        // Price protection
        uint232 priceTolerated; // expected oracleAmount1/oracleAmount2 ratio scaled by 1e30
        uint24 toleranceRange; // 1e7 = 100%; maximum opening-price deviation
        // Oracle and timing protections
        uint16 millisecondsPerBlock; // expected block interval in milliseconds; 2000 means one block per two seconds
        uint24 maxGameTime; // maximum opening-game duration before bailout
        uint16 maxExecutionLatency; // 0 disables; otherwise must be between 1 minute and 1 hour
        uint16 liquidationHeartbeatMin; // seconds of notice required by settlement eligibility; zero with max zero disables
        uint16 liquidationHeartbeatMax; // seconds in which a report may bind; an existing binding does not expire
        // Lifecycle configuration
        uint48 expiration; // duration at input; converted to an absolute timestamp
        uint48 maturityWindow; // duration from opening settlement eligibility until maturity
        // Funding and execution compensation
        uint96 settlerReward; // ETH reward offered to the opening oracle settler
        uint96 matcherGasComp; // swapper pays matcher this amount of wei to call match
        uint96 openExecutionComp; // ETH reward offered to the opening OpenPunt executor
        bool useInternalBalances; // true funds swapper collateral from oracle internal balance
    }

    struct CloseDutch {
        // Position binding
        address swapper; // override; set by close() from the matched swap
        address collatToken; // override; set by close() from the matched swap
        uint256 swapId; // override; set by close() to the position identifier
        // Reward curve
        uint128 maxReward; // max amount of collatToken you can pay as a reporting reward
        uint128 startingReward; // starting amount of collatToken as the reporting reward
        uint24 roundLength; // round length in seconds
        uint16 growthRate; // 15000 = 1.5x per round
        uint16 maxRounds; // max rounds of increase
        // Timing and funding
        uint48 start; // override; close() sets the auction's absolute start timestamp
        uint48 expiration; // absolute timestamp after which a report consumes the auction at zero reward
        bool useInternalBalances; // override; selects internal-balance or external refund delivery
    }

    function _materializeDutch(uint256 swapId, MatchedSwap memory s, StoredDutch memory stored)
        internal
        pure
        returns (CloseDutch memory d)
    {
        d = CloseDutch({
            swapper: s.swapper,
            collatToken: s.collatToken,
            swapId: swapId,
            maxReward: stored.maxReward,
            startingReward: stored.startingReward,
            roundLength: stored.roundLength,
            growthRate: stored.growthRate,
            maxRounds: stored.maxRounds,
            start: stored.start,
            expiration: stored.start + stored.expirationDuration,
            useInternalBalances: stored.useInternalBalances
        });
    }

    struct Permit2Params {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    /// @dev Oracle game + fulfillment fee params supplied by the matcher at match time.
    ///      Hash-bound at propose; openPunt stores only the hash. OpenPunt creates its oracle games
    ///      in block-number mode, so `settlementTime` and `disputeDelay` are block counts, not seconds.
    struct MatcherPreimage {
        // Oracle game configuration
        uint128 initialLiquidity; // initial and minimum token1 liquidity for position reports
        uint128 escalationHalt; // token1 amount at which dispute growth changes to one unit per round
        uint48 settlementTime; // blocks without a dispute required for settlement
        uint24 disputeDelay; // blocks after each report before its orders become disputable
        uint16 multiplier; // dispute token1 growth multiplier; 100 = 1x
        uint24 protocolFee; // 1e7 = 100%; portion of each dispute paid to feeRecipient
        // Funding-rate or fulfillment-fee auction
        int32 auctionStart; // initial funding rate or fulfillment fee, depending on auctionFunding
        int32 auctionEnd; // terminal funding rate or maximum fulfillment fee
        uint24 roundLength; // seconds per auction step
        uint16 maxRounds; // number of linear funding steps or geometric fee steps
        uint16 growthRate; // 10000 = 1x; used only by geometric fee discovery
        uint48 startFulfillFeeIncrease; // override; must be zero and is set to proposal timestamp
    }

    event SwapCancelled(uint256 indexed swapId, ProposedSwap swapState, MatcherPreimage matcherPreimage);
    event SwapRefunded(uint256 indexed swapId, address indexed swapper, address indexed matcher, MatchedSwap swapState);
    event SlippageBailout(uint256 indexed swapId);
    event ImpliedMillisecondsPerBlockBailout(uint256 indexed swapId);
    event MaxExecutionLatencyBailout(uint256 indexed swapId);
    event LiquidationHeartbeatSet(uint256 indexed swapId, uint128 indexed reportId, uint48 timestamp);
    event LiquidationHeartbeatBailout(uint256 indexed swapId, uint128 indexed reportId);
    event SwapProposed(uint256 indexed swapId, ProposedSwap swapState, MatcherPreimage matcherPreimage);
    event SwapMatched(uint256 indexed swapId, uint256 indexed reportId, MatchedSwap swapState);
    event PositionReportStarted(
        uint256 indexed swapId, uint256 indexed reportId, address indexed reporter, MatchedSwap swapState
    );
    event CloseIntentSet(uint256 indexed swapId, uint256 indexed currentReportId, uint128 executionCompAdded);
    event CloseAuctionStarted(
        uint256 indexed swapId, bytes32 indexed dutchHash, CloseDutch dutch, uint128 executionComp
    );
    event CloseAuctionCancelled(
        uint256 indexed swapId, bytes32 indexed dutchHash, CloseDutch dutch, uint128 executionCompRefunded
    );
    event CloseIntentCancelled(uint256 indexed swapId);
    event OpeningBailedOut(uint256 indexed swapId, MatchedSwap swapState);
    event PositionOpeningFailed(uint256 indexed swapId, uint256 indexed reportId, MatchedSwap swapState);
    event PositionOpened(uint256 indexed swapId, MatchedSwap swapState);
    event PositionReportBailedOut(uint256 indexed swapId, uint256 indexed reportId, MatchedSwap swapState);
    event LiquidationFailed(uint256 indexed swapId, uint256 indexed reportId, MatchedSwap swapState);
    event PositionLiquidated(uint256 indexed swapId, uint256 indexed reportId, MatchedSwap finalState);
    event PositionClosed(
        uint256 indexed swapId,
        uint256 indexed reportId,
        MatchedSwap finalState,
        uint256 owedToSwapper,
        uint256 owedToMatcher
    );

    /// @dev Returns the chain-specific block clock used by OpenPunt and its block-mode oracle games.
    ///      Override this single integration point on chains whose protocol block number differs
    ///      from the EVM `block.number` value.
    /// @return Current protocol block number, narrowed to the oracle's uint48 representation.
    function _getBlockNumber() internal view returns (uint48) {
        return uint48(block.number);
    }
}
