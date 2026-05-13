// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOpenOracle2} from "./interfaces/IOpenOracle2.sol";
import {oracleFeeReceiver} from "./oracleFeeReceiver.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";

/**
 * @title openSwap
 * @notice A user proposes a swap, someone matches it, and openOracle determines the execution price. 
           The matcher earns a fee for their service.

           Supported token types: vanilla ERC20 and USDT-style tokens that omit a return value on transfer/transferFrom.
           Not supported: fee-on-transfer, rebasing, ERC777 / tokens with transfer hooks, or any token whose
           balance can change without a corresponding transfer event from this contract. Using unsupported tokens
           may cause loss of funds or incorrect fee accounting.

 * @author OpenOracle Team
 * @custom:version 0.2.0
 * @custom:documentation https://docs.openoracle.org/
 */

contract openSwapV2 is ReentrancyGuard {
    IOpenOracle2 public immutable oracle;
    address public immutable feeReceiverImpl;

    error InvalidMsgValue();
    error MsgValueMismatch();
    error SameToken();
    error ZeroAmount();
    error InvalidExpiration();
    error InvalidFulfillFee();
    error InvalidSlippage();
    error InvalidOracleParams();
    error InvalidFulfillFeeParams();
    error MinOutInconsistent();
    error WrongHash();
    error WrongOracleHash();
    error AlreadyMatched();
    error NotActive();
    error Expired();
    error NotSwapper();
    error NotMatched();
    error CantBailOutYet();
    error NothingToWithdraw();
    error EthSendFailed();
    error OracleSettlementNotEligible();

    constructor(address oracle_) {
        oracle = IOpenOracle2(oracle_);
        feeReceiverImpl = address(new oracleFeeReceiver());
    }

    mapping (uint256 => bytes32) public swaps;
    uint256 public nextSwapId = 1;

    mapping (address => uint256) public tempHolding;

    struct Swap {
        uint128 sellAmt; // amount of sellToken the swapper is selling
        uint128 reportId; // oracle game reportId

        uint128 minFulfillLiquidity; // minimum amount of buyToken the matcher must put in the contract
        uint88 settlerReward;
        uint24 maxGameTime;
        uint16 blocksPerSecond;

        address buyToken; // address for token swapper wants
        uint96 matcherGasComp; // swapper pays matcher this amount of wei to call match

        address sellToken; // address for token swapper is selling
        uint48 expiration; // timestamp at which swapper's swap can no longer be matched

        address swapper; // msg.sender of swapper. Non-zero ⇔ swap exists.
        uint96 executorGasComp;

        address matcher; // msg.sender of matcher. Non-zero ⇔ swap is matched.
        uint48 start; // timestamp at which order is matched
        uint24 fulfillmentFee; // 1000 = 0.01%, fee paid to matcher

        address feeRecipient; // contract holding protocol fees from oracle game

        SlippageParams slippageParams;
    }

    struct OracleParams {
        uint128 initialLiquidity; // oracle game initial liquidity in sellToken
        uint128 escalationHalt; // amount of sellToken at which oracle game stops escalating
        uint88 settlerReward; // settler reward in oracle game. settle function executes the swap.
        uint48 settlementTime; // round length of oracle game, in seconds.
        uint24 maxGameTime; // if oracle game takes longer than this many seconds, refund available.
        uint24 disputeDelay; // disputes must wait this many seconds after the last report.
        uint24 protocolFee; // 1000 = 0.01%, percentage levied of each swap in oracle game for protocolFeeRecipient's benefit.
        uint16 multiplier; // oracle game multiplier, 110 = 1.1x
        uint16 blocksPerSecond; // network's blocks per second. 500 means 0.5 blocks per second versus wall clock
    }

    struct SlippageParams {
        uint232 priceTolerated; // user-set reference price for slippage check at settlement. Encoded as oracleAmount1 * 1e30 / oracleAmount2 at the desired price, 
                                // example: WETH (18 dec) / USDC (6 dec) at $4442.99/ETH → priceTolerated ≈ 1e18 * 1e30 / (4442.99 * 1e6) ≈ 2.25e38.
        uint24 toleranceRange; // 100000 = 1%, max slippage against priceTolerated
    }

    struct FulfillFeeParams {
        uint24 maxFee; // 1000 = 0.01%, max fulfillment fee you can pay
        uint24 startingFee; // 1000 = 0.01%, starting fee level
        uint24 roundLength; // round length in seconds
        uint16 growthRate; // 15000 = 1.5x per round
        uint16 maxRounds; // max rounds of increase
    }

    struct Permit2Params {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    /// @dev Oracle-game + fulfill-fee params supplied by the matcher at match time. Hash-bound at propose; openSwap stores only the hash.
    struct MatcherPreimage {
        uint128 initialLiquidity;
        uint128 escalationHalt;
        uint48 settlementTime;
        uint24 disputeDelay;
        uint24 protocolFee;
        uint16 multiplier;
        uint48 startFulfillFeeIncrease;
        uint24 maxFee;
        uint24 startingFee;
        uint24 roundLength;
        uint16 growthRate;
        uint16 maxRounds;
    }

    event SwapCreated(uint256 indexed swapId);
    event SwapCancelled(uint256 swapId);
    event SwapRefunded(uint256 swapId, address indexed swapper, address indexed matcher);
    event SwapExecuted(uint256 swapId);
    event SwapMatched(uint256 indexed swapId, uint128 reportId);
    event FeesTransferred(address indexed swapper, address indexed matcher, address buyToken, address sellToken, uint128 feesBuyToken, uint128 feesSellToken, address feeRecipientContract);
    event SlippageBailout(uint256 swapId);
    event ImpliedBlocksPerSecondBailout(uint256 swapId);

    /**
     * @notice Creates a swap, sending sellAmt of sellToken into the contract.
     * @param sellAmt Amount of sellToken to sell
     * @param sellToken Token address to sell
     * @param minOut Minimum amount of buyToken to receive
     * @param buyToken Token address to buy
     * @param minFulfillLiquidity Matcher must supply this amount of buyToken. Should include a buffer above market price to prevent refunds.
     * @param expiration Number of seconds after this transaction lands in a block when swap can no longer be matched.
     * @param matcherGasComp Gas compensation for matcher
     * @param oracleParams Oracle game parameters: see OracleParams for comments
     * @param slippageParams Slippage parameters: see SlippageParams for comments
     * @param fulfillFeeParams Fulfillment fee parameters: see FulfillFeeParams for comments
     * @param permit2 Permit2 params
     * @return swapId The final settled price
     */
    function propose(uint128 sellAmt, address sellToken, uint128 minOut, address buyToken, uint128 minFulfillLiquidity, uint48 expiration, uint96 matcherGasComp, uint96 executorGasComp, OracleParams calldata oracleParams, SlippageParams calldata slippageParams, FulfillFeeParams calldata fulfillFeeParams, Permit2Params calldata permit2) external payable returns(uint256 swapId) {

        uint256 settlerReward = oracleParams.settlerReward;
        uint256 extraEth = matcherGasComp + settlerReward + executorGasComp;
        bool isEth = sellToken == address(0);

        if (!isEth && msg.value != extraEth) revert InvalidMsgValue();
        if (isEth && msg.value != sellAmt + extraEth) revert MsgValueMismatch();

        if (sellToken == buyToken) revert SameToken();

        if (sellAmt == 0 || minOut == 0 || minFulfillLiquidity == 0) revert ZeroAmount();
        if (expiration == 0 || expiration > 30 days) revert InvalidExpiration();
        if (fulfillFeeParams.maxFee >= 1e7) revert InvalidFulfillFee();

        if (slippageParams.priceTolerated == 0 || slippageParams.toleranceRange == 0 || slippageParams.toleranceRange > 1e7) revert InvalidSlippage();

        if (oracleParams.settlerReward < 100
            || oracleParams.settlementTime == 0 
            || oracleParams.initialLiquidity == 0
            || oracleParams.blocksPerSecond == 0
            || oracleParams.disputeDelay >= oracleParams.settlementTime
            || oracleParams.escalationHalt < oracleParams.initialLiquidity
            || oracleParams.settlementTime > 4 * 60 * 60
            || oracleParams.protocolFee >= 1e7
            || oracleParams.maxGameTime < oracleParams.settlementTime * 20
            || oracleParams.maxGameTime > 604800
            || oracleParams.multiplier < 100
            ) revert InvalidOracleParams();

        if (fulfillFeeParams.maxFee == 0
            || fulfillFeeParams.startingFee == 0
            || fulfillFeeParams.growthRate < 10000
            || fulfillFeeParams.maxRounds == 0
            || fulfillFeeParams.maxRounds > 100
            || fulfillFeeParams.roundLength == 0
            || fulfillFeeParams.maxFee < fulfillFeeParams.startingFee
            || fulfillFeeParams.maxFee > 1e7
            ) revert InvalidFulfillFeeParams();

        uint256 upperPrice = Math.mulDiv(slippageParams.priceTolerated, uint256(1e7) + slippageParams.toleranceRange, 1e7);
        uint256 worstFulfillAmt = Math.mulDiv(sellAmt, 1e30, upperPrice);
        worstFulfillAmt -= Math.mulDiv(worstFulfillAmt, fulfillFeeParams.maxFee, 1e7);
                                                                                                                                                                                                                                        
        if (minOut > worstFulfillAmt) revert MinOutInconsistent();

        swapId = nextSwapId++;
        Swap memory s;

        s.swapper = msg.sender;
        s.sellAmt = sellAmt;
        s.sellToken = sellToken;
        s.buyToken = buyToken;
        s.minFulfillLiquidity =  minFulfillLiquidity;
        s.expiration = uint48(block.timestamp) + expiration;
        s.maxGameTime = oracleParams.maxGameTime;
        s.blocksPerSecond = oracleParams.blocksPerSecond;
        s.settlerReward = oracleParams.settlerReward;
        s.slippageParams = slippageParams;
        s.matcherGasComp = matcherGasComp;
        s.executorGasComp = executorGasComp;

        MatcherPreimage memory m;
        m.initialLiquidity = oracleParams.initialLiquidity;
        m.escalationHalt = oracleParams.escalationHalt;
        m.settlementTime = oracleParams.settlementTime;
        m.disputeDelay = oracleParams.disputeDelay;
        m.protocolFee = oracleParams.protocolFee;
        m.multiplier = oracleParams.multiplier;
        m.startFulfillFeeIncrease = uint48(block.timestamp);
        m.maxFee = fulfillFeeParams.maxFee;
        m.startingFee = fulfillFeeParams.startingFee;
        m.roundLength = fulfillFeeParams.roundLength;
        m.growthRate = fulfillFeeParams.growthRate;
        m.maxRounds = fulfillFeeParams.maxRounds;

        bytes32 swapHash = 
            keccak256(abi.encode(s, m));

        if (isEth) {
            oracle.deposit{value: sellAmt}(address(0), sellAmt, address(this));
        } else {
            // Bind the swapper's Permit2 sig to the full propose intent (minus sellAmt + sellToken
            // which Permit2 already pins via permitted.token + permitted.amount).
            bytes32 intent = keccak256(
                abi.encode(
                    minOut, buyToken, minFulfillLiquidity, expiration,
                    matcherGasComp, executorGasComp,
                    oracleParams, slippageParams, fulfillFeeParams
                )
            );
            oracle.depositFromPermit2(
                sellAmt,
                address(this),
                msg.sender,
                intent,
                ISignatureTransfer.PermitTransferFrom({
                    permitted: ISignatureTransfer.TokenPermissions({
                        token: sellToken,
                        amount: sellAmt
                    }),
                    nonce: permit2.nonce,
                    deadline: permit2.deadline
                }),
                permit2.signature
            );
        }

        swaps[swapId] = swapHash; // CEI inversion: swap becomes live only after funding succeeds.

        emit SwapCreated(swapId);
    }

    /**
     * @notice Matcher matches swap and submits oracle initial report, sending tokens into contract
     * @param swapId Unique identifier of swapping instance
     * @param amount2 Oracle game amount2
    */
    function matchSwap(uint256 swapId, uint128 amount2, Swap calldata _swap, MatcherPreimage calldata preimage, IOpenOracle2.TimingBoundaries calldata timing) external {

        if ((keccak256(abi.encode(_swap, preimage))) != swaps[swapId]) revert WrongHash();
        Swap memory s = _swap;

        address buyToken = s.buyToken;
        address sellToken = s.sellToken;
        uint128 minFulfillLiquidity = s.minFulfillLiquidity;

        // Defensive: hash-shape check above already enforces pre-match state, but these spell it out.
        if (s.matcher != address(0)) revert AlreadyMatched();
        if (s.swapper == address(0)) revert NotActive();
        if (block.timestamp > s.expiration) revert Expired();

        address matcher = msg.sender;
        uint24 fulfillmentFee =
            uint24(calcFee(preimage.maxFee, preimage.startingFee, preimage.growthRate, preimage.maxRounds, preimage.startFulfillFeeIncrease, preimage.roundLength));

        s.matcher = matcher;
        s.start = uint48(block.timestamp);
        s.fulfillmentFee = fulfillmentFee;

        tempHolding[matcher] += s.matcherGasComp;

        if (preimage.protocolFee > 0) {
            address feeReceiver = Clones.clone(feeReceiverImpl);
            s.feeRecipient = feeReceiver;
        }   
        s.reportId = uint128(oracle.nextReportId());
        swaps[swapId] = keccak256(abi.encode(s));
        if (s.feeRecipient != address(0)) {
            oracleFeeReceiver(s.feeRecipient).initialize(uint128(swapId), address(oracle), sellToken, buyToken, s.swapper, matcher);
        }
        oracleGame(s, preimage, timing, amount2, matcher);
        oracle.internalTransferFrom(matcher, address(this), buyToken, minFulfillLiquidity);

        emit SwapMatched(swapId, s.reportId);
    }

    /**
     * @notice Swapper cancels swap, receiving tokens back.
               Must be called prior to match.
               At or before expiration: only the swapper can call.
               After expiration: anyone can call; caller receives 20% of (matcherGasComp + executorGasComp),
               swapper receives the remaining 80% plus the settler reward.
     * @param swapId Unique identifier of swapping instance
    */
    function cancelSwap(uint256 swapId, Swap calldata _swap, MatcherPreimage calldata preimage) external nonReentrant {
        bytes32 passedHash = keccak256(abi.encode(_swap, preimage));
        if (passedHash != swaps[swapId]) revert WrongHash();

        Swap memory s = _swap;

        // Defensive: hash-shape check above already enforces pre-match state.
        if (s.matcher != address(0)) revert AlreadyMatched();
        if (s.swapper == address(0)) revert NotActive();

        address caller;
        uint256 callerPiece;
        uint256 swapperPiece;

        address swapper = s.swapper;
        uint256 totalGasComp = uint256(s.matcherGasComp) + uint256(s.executorGasComp);
        uint88 settlerReward = s.settlerReward;
        address sellToken = s.sellToken;
        uint128 sellAmt = s.sellAmt;

        if (block.timestamp <= s.expiration){
            if (msg.sender != swapper) revert NotSwapper();
            callerPiece = 0;
            swapperPiece = totalGasComp;
        } else {
            if (msg.sender != swapper){
                caller = msg.sender;
                callerPiece = totalGasComp / 5;
                swapperPiece = totalGasComp - callerPiece;
            } else {
                swapperPiece = totalGasComp;
            }
        }

        delete swaps[swapId];

        oracle.pushOrCredit(sellToken, swapper, sellAmt);
        payEth(swapper, swapperPiece + settlerReward);
        if (caller == msg.sender) payEth(caller, callerPiece);

        emit SwapCancelled(swapId);
    }

    function oracleGame(Swap memory s, MatcherPreimage memory o, IOpenOracle2.TimingBoundaries memory timing, uint128 amount2, address matcher) internal returns (uint256 reportId) {

        IOpenOracle2.CreateReportParams memory params = IOpenOracle2.CreateReportParams({
            escalationHalt: o.escalationHalt,
            token1Address: s.sellToken,
            settlerReward: s.settlerReward,
            token2Address: s.buyToken,
            settlementTime: o.settlementTime,
            disputeDelay: o.disputeDelay,
            protocolFee: o.protocolFee,
            callbackGasLimit: 0,
            feePercentage: 0,
            multiplier: o.multiplier,
            callbackContract: address(0),
            protocolFeeRecipient: s.feeRecipient,
            flags: 1
        });

        reportId = oracle.report{value: s.settlerReward} (
            params,
            o.initialLiquidity,
            amount2,
            matcher,
            true,
            true,
            timing
        );

    }

    /**
     * @notice Lets users bail out of a swapId.
               Anyone-can-call. Caller earns executor gas compensation.
               One bail out condition:
                    maxGameTime has passed since oracle game started → swapper and matcher are refunded initial token deposits
     * @param swapId Unique identifier of swapping instance
    */

    function bailOut(uint256 swapId, Swap calldata _swap) external nonReentrant {
        bytes32 passedHash = keccak256(abi.encode(_swap));
        if (passedHash != swaps[swapId]) revert WrongHash();

        Swap memory s = _swap;

        // Defensive: hash-shape check above already enforces post-match state.
        if (s.matcher == address(0)) revert NotMatched();
        if (s.swapper == address(0)) revert NotActive();

        bool isGameTooLong = block.timestamp - s.start > s.maxGameTime;

        if (isGameTooLong) {
            delete swaps[swapId];
            tempHolding[msg.sender] += s.executorGasComp;
            refund(s.sellToken, s.sellAmt, s.swapper, s.buyToken, s.minFulfillLiquidity, s.matcher);
            emit SwapRefunded(swapId, s.swapper, s.matcher);
            return;
        }

        revert CantBailOutYet();

    }

    /// @notice Seeds a 1-wei sentinel on `_to`'s tempHolding slot to warm it for future credits. Caller pays the 1 wei.
    function dust(address _to) external payable {
        if (msg.value != 1) revert InvalidMsgValue();
        tempHolding[_to] += 1;
    }

    /**
     * @notice Withdraws queued ETH gas-comp credits to `_to`. If caller != `_to`, a 1-wei
     *         sentinel is always preserved on `_to`'s slot.
     */
    function withdraw(address _to, bool leaveOne) external nonReentrant {
        uint256 amount = tempHolding[_to];
        bool keepSentinel = leaveOne || msg.sender != _to;

        if (keepSentinel ? amount <= 1 : amount == 0) revert NothingToWithdraw();

        uint256 payout = keepSentinel ? amount - 1 : amount;
        tempHolding[_to] = keepSentinel ? 1 : 0;

        // Unbounded gas — caller is initiating their own retrieval and pays for it.
        (bool ok,) = payable(_to).call{value: payout}("");
        if (!ok) revert EthSendFailed();
    }

    /// @dev Bounded-gas ETH push used during state transitions. On failure, credits
    ///      `_to`'s `tempHolding` slot so the recipient can retrieve via `withdraw`.
    function payEth(address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        (bool ok,) = payable(_to).call{value: _amount, gas: 50000}("");
        if (!ok) tempHolding[_to] += _amount;
    }

    function execute(uint256 swapId, Swap calldata swapState, IOpenOracle2.OracleGame calldata oracleState, IOpenOracle2.PreimageHelper calldata oracleHelper, bool looseTiming) external {
        if (keccak256(abi.encode(swapState)) != swaps[swapId]) revert WrongHash();
        Swap memory s = swapState;

        // Defensive: hash-shape check above already enforces post-match state.
        if (s.matcher == address(0)) revert NotMatched();
        if (s.swapper == address(0)) revert NotActive();

        uint256 reportId = s.reportId;
        bytes32 oracleHash = oracle.oracleGame(reportId);
        bytes32 passedHash = keccak256(abi.encode(oracleState, oracleHelper));
        bool matches = oracleHash == passedHash;

        // loose hash if settle beat you in the same block
        if (!matches && oracleState.settlementTimestamp == 0 && looseTiming) {
            IOpenOracle2.OracleGame memory o = oracleState;
            o.settlementTimestamp = uint48(block.timestamp);
            matches = oracleHash == keccak256(abi.encode(o, oracleHelper));
        }

        // loose hash for block boundaries
        if (!matches && oracleState.settlementTimestamp > 2 && looseTiming) {
            IOpenOracle2.OracleGame memory o = oracleState;
            o.settlementTimestamp -= 2;
            matches = oracleHash == keccak256(abi.encode(o, oracleHelper));
        }

        if (!matches) revert WrongOracleHash();

        if (uint48(block.timestamp) < oracleState.reportTimestamp + oracleState.settlementTime) revert OracleSettlementNotEligible();

        delete swaps[swapId];
        tempHolding[msg.sender] += s.executorGasComp;

        address swapper = s.swapper;
        address matcher = s.matcher;
        address buyToken = s.buyToken;
        address sellToken = s.sellToken;
        address feeRecipient = s.feeRecipient;
        uint128 minFulfillLiquidity = s.minFulfillLiquidity;
        uint128 sellAmt = s.sellAmt;
        uint24 fulfillmentFee = s.fulfillmentFee;
        uint16 blocksPerSecond = s.blocksPerSecond;
        uint128 oracleAmount1 = oracleState.currentAmount1;
        uint128 oracleAmount2 = oracleState.currentAmount2;

        uint256 price = Math.mulDiv(oracleAmount1, 1e30, oracleAmount2);
        uint256 fulfillAmt = Math.mulDiv(sellAmt, oracleAmount2, oracleAmount1);
        fulfillAmt -= Math.mulDiv(fulfillAmt, fulfillmentFee, 1e7);

        bool slippageOk = toleranceCheck(price, s.slippageParams.priceTolerated, s.slippageParams.toleranceRange);
        bool blocksPerSecondOk = impliedBlocksPerSecond(oracleState.reportTimestamp, oracleState.lastReportOppoTime, blocksPerSecond);
        bool slippageBailout = fulfillAmt > minFulfillLiquidity || !slippageOk;
        bool shouldRefund = slippageBailout || !blocksPerSecondOk;

        if (slippageBailout) emit SlippageBailout(swapId);
        if (!blocksPerSecondOk) emit ImpliedBlocksPerSecondBailout(swapId);

        if (shouldRefund) {
            refund(sellToken, sellAmt, swapper, buyToken, minFulfillLiquidity, matcher);
            emit SwapRefunded(swapId, swapper, matcher);
        } else {
            oracle.pushOrCredit(buyToken, swapper, uint128(fulfillAmt));
            oracle.internalTransferFrom(address(this), matcher, buyToken, uint128(minFulfillLiquidity - fulfillAmt));
            oracle.internalTransferFrom(address(this), matcher, sellToken, sellAmt);
            emit SwapExecuted(swapId);
        }

        if (feeRecipient != address(0)) {
            grabOracleGameFees(s);
        }
    }

    function refund(address sellToken, uint128 sellAmt, address swapper, address buyToken, uint128 buyAmt, address matcher) internal {
        oracle.pushOrCredit(sellToken, swapper, sellAmt);
        oracle.internalTransferFrom(address(this), matcher, buyToken, buyAmt);
    }

    function calcFee(uint256 maxFee, uint256 startingFee, uint256 growthRate, uint256 maxRounds, uint256 startFulfillFeeIncrease, uint256 roundLength) internal view returns (uint256) {
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
            unchecked { ++i; }
        }

        return currentFee;
    }

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

    function impliedBlocksPerSecond(uint48 _time, uint48 _timeOppo, uint48 blocksPerSecond) internal view returns (bool) {
        uint48 _timeChangeTrue = uint48(block.timestamp) - _time;
        uint48 _timeChangeBlock = uint48(block.number) - _timeOppo;
        uint48 expectedBlocks = _timeChangeTrue * blocksPerSecond;

        if (
            1000 * _timeChangeBlock > expectedBlocks + 2 * blocksPerSecond
                || 1000 * _timeChangeBlock + 2 * blocksPerSecond < expectedBlocks
        ) {
            return false;
        } else {
            return true;
        }
    }

    function grabOracleGameFees(Swap memory s) internal {
        try oracleFeeReceiver(s.feeRecipient).distribute() returns (uint256 feesSellToken, uint256 feesBuyToken) {
            emit FeesTransferred(s.swapper, s.matcher, s.buyToken, s.sellToken, uint128(feesBuyToken), uint128(feesSellToken), s.feeRecipient);
        } catch {}
    }

}


