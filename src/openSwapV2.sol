// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IOpenOracle} from "./interfaces/IOpenOracle.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {oracleFeeReceiver} from "./oracleFeeReceiver.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

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

contract openSwapV2Permit is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IOpenOracle public immutable oracle;
    address public immutable feeReceiverImpl;
    address public immutable WETH = 0x4200000000000000000000000000000000000006;

    error InvalidInput(string);

    constructor(address oracle_) {
        oracle = IOpenOracle(oracle_);
        feeReceiverImpl = address(new oracleFeeReceiver());
    }

    mapping(address => bool) private _oracleApproved;                                                                                                                                                   

    mapping (uint256 => Swap) public swaps;
    uint256 public nextSwapId = 1;

    mapping (uint256 => uint256) public reportIdToSwapId;
    mapping (address => mapping(address => uint256)) public tempHolding;

    struct Swap {
        uint128 sellAmt; // amount of sellToken the swapper is selling //NOHASH
        uint128 reportId; // oracle game reportId //NOHASH

        uint128 minFulfillLiquidity; // minimum amount of buyToken the matcher must put in the contract //NOHASH
        uint88 settlerReward;
        uint24 maxGameTime;
        uint16 blocksPerSecond;

        address buyToken; // address for token swapper wants //NOHASH
        uint96 gasCompensation; // swapper pays matcher this amount of wei to call match

        address sellToken; // address for token swapper is selling //NOHASH
        uint48 expiration; // timestamp at which swapper's swap can no longer be matched
        bool active; // true means swap created //NOHASH
        bool finished; // true means swap finished //NOHASH
        bool cancelled; // true means swap cancelled by swapper //NOHASH

        address swapper; // msg.sender of swapper //NOHASH

        address matcher; // msg.sender of matcher //NOHASH
        uint48 start; // timestamp at which order is matched //NOHASH
        uint24 fulfillmentFee; // 1000 = 0.01%, fee paid to matcher //NOHASH
        bool matched; // true means swap matched by matcher //NOHASH

        address feeRecipient; // contract holding protocol fees from oracle game //NOHASH

        bytes32 oracleAndFeeParamHash;
        SlippageParams slippageParams;
    }

    struct OracleParams {
        uint128 initialLiquidity; // oracle game initial liquidity in sellToken
        uint128 escalationHalt; // amount of sellToken at which oracle game stops escalating
        uint88 settlerReward; // settler reward in oracle game. settle function executes the swap. //NOHASH
        uint48 settlementTime; // round length of oracle game. if timeType true, in seconds, if false, blocks
        uint24 maxGameTime; // if oracle game takes longer than this time in seconds, refund available. does not respect timeType, i.e., is ALWAYS in seconds //NOHASH
        uint24 disputeDelay; // disputes must wait this long after the last report to fire in the oracle game. if timeType true, in seconds, if false, blocks
        uint24 protocolFee; // 1000 = 0.01%, percentage levied of each swap in oracle game for protocolFeeRecipient's benefit.
        uint16 multiplier; // oracle game multiplier, 110 = 1.1x
        uint16 blocksPerSecond; // network's blocks per second. 500 means 0.5 blocks per second versus wall clock //NOHASH
        bool timeType; // true means oracle game is played in seconds, false for blocks
    }

    struct SlippageParams {
        uint232 priceTolerated; // one of two max slippage inputs. current price at time of swap, formatted as priceTolerated = 225073570923495617630012810 implies (1e30 / priceTolerated) = $4442.99 for WETH/USDC trading (sellToken WETH or ETH and buyToken USDC)
                                //should match oracle game price calculation (respecting PRICE_PRECISION semantics)
        uint24 toleranceRange; // 100000 = 1%, max slippage against priceTolerated
    }

    struct FulfillFeeParams {
        uint24 maxFee; // 1000 = 0.01%, max fulfillment fee you can pay
        uint24 startingFee; // 1000 = 0.01%, starting fee level
        uint24 roundLength; // round length in seconds
        uint16 growthRate; // 15000 = 1.5x per round
        uint16 maxRounds; // max rounds of increase
    }

    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // idea is matcher will pass this, and swapper will only store bytes32 hash for the hash of these things.
    struct MatcherPreimage {
        uint128 initialLiquidity;
        uint128 escalationHalt;
        uint48 settlementTime;
        uint24 disputeDelay;
        uint24 protocolFee;
        uint16 multiplier;
        bool timeType; // end oracle params
        uint48 startFulfillFeeIncrease;
        uint24 maxFee;
        uint24 startingFee;
        uint24 roundLength;
        uint16 growthRate;
        uint16 maxRounds; // end fulfill fee params
    }

    event SwapCreated(uint256 indexed swapId, address indexed swapper, uint128 sellAmt, address sellToken, address buyToken, uint128 minFulfillLiquidity, uint48 expiration, uint232 priceTolerated, uint24 toleranceRange, FulfillFeeParams fulfillFeeParams, OracleParams oracleParams, uint96 gasCompensation);
    event SwapCancelled(uint256 swapId);
    event SingleFee(uint256 swapId, uint24 fulfillmentFee);
    event SwapRefunded(uint256 swapId, address indexed swapper, address indexed matcher);
    event SwapExecuted(address indexed swapper, address indexed matcher, uint256 swapId, uint128 sellTokenAmt, uint128 buyTokenAmt);
    event SwapMatched(uint256 swapId, uint24 fulfillmentFee, address indexed matcher, uint256 reportId, address indexed swapper);
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
     * @param gasCompensation Gas compensation for matcher
     * @param oracleParams Oracle game parameters: see OracleParams for comments
     * @param slippageParams Slippage parameters: see SlippageParams for comments
     * @param fulfillFeeParams Fulfillment fee parameters: see FulfillFeeParams for comments
     * @param permit Permit params for ERC20Permit
     * @return swapId The final settled price
     */
    function swap(uint128 sellAmt, address sellToken, uint128 minOut, address buyToken, uint128 minFulfillLiquidity, uint48 expiration, uint96 gasCompensation, OracleParams memory oracleParams, SlippageParams memory slippageParams, FulfillFeeParams memory fulfillFeeParams, PermitParams memory permit) external payable nonReentrant returns(uint256 swapId) {

        if (permit.deadline != 0){
            try IERC20Permit(sellToken).permit(
                msg.sender,
                address(this),
                permit.value,
                permit.deadline,
                permit.v,
                permit.r,
                permit.s
            ) {} catch {}
        }

        uint256 settlerReward = oracleParams.settlerReward;
        uint256 extraEth;

        extraEth = gasCompensation + settlerReward;

        if (sellToken != address(0) && msg.value != extraEth) revert InvalidInput("msg.value wrong");
        if (sellToken == address(0) && msg.value != sellAmt + extraEth) revert InvalidInput("msg.value vs sellAmt mismatch");

        if (sellToken == buyToken) revert InvalidInput("sellToken = buyToken");
        if (sellToken == WETH && buyToken == address(0) || sellToken == address(0) && buyToken == WETH) revert InvalidInput("sellToken = buyToken");

        if (sellAmt == 0 || minOut == 0 || minFulfillLiquidity == 0) revert InvalidInput("zero amounts");
        if (fulfillFeeParams.maxFee >= 1e7) revert InvalidInput("fulfillmentFee");

        if (slippageParams.priceTolerated == 0 || slippageParams.toleranceRange == 0 || slippageParams.toleranceRange > 1e7) revert InvalidInput("slippage");

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
            ) revert InvalidInput("oracleParams");

        if (fulfillFeeParams.maxFee == 0
            || fulfillFeeParams.startingFee == 0
            || fulfillFeeParams.growthRate == 0
            || fulfillFeeParams.maxRounds == 0
            || fulfillFeeParams.maxRounds > 100
            || fulfillFeeParams.roundLength == 0
            || fulfillFeeParams.maxFee < fulfillFeeParams.startingFee
            || fulfillFeeParams.maxFee > 1e7
            ) revert InvalidInput("fulfillFeeParams");

        uint256 upperPrice = (slippageParams.priceTolerated * (uint256(1e7) + slippageParams.toleranceRange)) / 1e7;                                                                                                                                                            
        uint256 worstFulfillAmt = (sellAmt * 1e18) / upperPrice;                                                                                                                                                                         
        worstFulfillAmt -= worstFulfillAmt * fulfillFeeParams.maxFee / 1e7;                                                                                                                                                                               
                                                                                                                                                                                                                                        
        if (minOut > worstFulfillAmt) revert InvalidInput("minOut inconsistent");

        swapId = nextSwapId++;
        Swap storage s = swaps[swapId];

        s.swapper = msg.sender;
        s.sellAmt = sellAmt;
        s.sellToken = sellToken;
        s.buyToken = buyToken;
        s.minFulfillLiquidity =  minFulfillLiquidity;
        s.expiration = uint48(block.timestamp) + expiration;
        s.active = true;
        s.maxGameTime = oracleParams.maxGameTime;
        s.blocksPerSecond = oracleParams.blocksPerSecond;
        s.settlerReward = oracleParams.settlerReward;
        s.slippageParams = slippageParams;
        s.gasCompensation = gasCompensation;

        s.oracleAndFeeParamHash = 
            keccak256(abi.encode(oracleParams.initialLiquidity,
                                 oracleParams.escalationHalt,
                                 oracleParams.settlementTime,
                                 oracleParams.disputeDelay,
                                 oracleParams.protocolFee,
                                 oracleParams.multiplier,
                                 oracleParams.timeType,
                                 uint48(block.timestamp),
                                 fulfillFeeParams.maxFee,
                                 fulfillFeeParams.startingFee,
                                 fulfillFeeParams.roundLength,
                                 fulfillFeeParams.growthRate,
                                 fulfillFeeParams.maxRounds));

        if (sellToken != address(0)) {
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmt);
        }

        emit SwapCreated(swapId, s.swapper, sellAmt, sellToken, buyToken, minFulfillLiquidity, s.expiration, slippageParams.priceTolerated, slippageParams.toleranceRange, fulfillFeeParams, oracleParams, gasCompensation);

    }

    /**
     * @notice Matcher matches swap and submits oracle initial report, sending tokens into contract
     * @param swapId Unique identifier of swapping instance
     * @param amount2 Oracle game amount2
     * @param paramHashExpected Hash of Swap struct expected. Helps protect against adversarial RPCs
                                Checks against keccak256(abi.encode(swaps[swapId]))
    */
    function matchSwap(uint256 swapId, uint128 amount2, bytes32 paramHashExpected, MatcherPreimage memory preimage) external payable nonReentrant {
        Swap storage s = swaps[swapId];

        //caching
        address buyToken = s.buyToken;
        address sellToken = s.sellToken;
        bool buyTokenIsEth = buyToken == address(0);
        bool sellTokenIsEth = sellToken == address(0);
        address buyTokenOracleFormat = buyTokenIsEth ? WETH : buyToken;
        address sellTokenOracleFormat = sellTokenIsEth ? WETH : sellToken;
        uint128 minFulfillLiquidity = s.minFulfillLiquidity;
        uint128 initialLiquidity = preimage.initialLiquidity;

        if (!buyTokenIsEth && msg.value != 0) revert InvalidInput("msg.value must be 0");
        if (buyTokenIsEth && msg.value != minFulfillLiquidity) revert InvalidInput("msg.value");

        if (s.cancelled) revert InvalidInput("swap cancelled");
        if (s.matched) revert InvalidInput("swap matched");
        if (!s.active) revert InvalidInput("swap not active");
        if (s.finished) revert InvalidInput("finished");
        if (block.timestamp > s.expiration) revert InvalidInput("expired");

        if (paramHashExpected != keccak256(abi.encode(s))) revert InvalidInput("params");
        if (s.oracleAndFeeParamHash != keccak256(abi.encode(preimage))) revert InvalidInput("preimage params");

        address matcher = msg.sender;
        uint24 fulfillmentFee =
            uint24(calcFee(preimage.maxFee, preimage.startingFee, preimage.growthRate, preimage.maxRounds, preimage.startFulfillFeeIncrease, preimage.roundLength));

        s.matched = true;
        s.matcher = matcher;
        s.start = uint48(block.timestamp);
        s.fulfillmentFee = fulfillmentFee;

        payEth(matcher, s.gasCompensation);

        uint256 buyTokenTransferAmt = buyTokenIsEth ? amount2 : minFulfillLiquidity + amount2;
        IERC20(buyTokenOracleFormat).safeTransferFrom(matcher, address(this), buyTokenTransferAmt);
        IERC20(sellTokenOracleFormat).safeTransferFrom(matcher, address(this), initialLiquidity);

        if (preimage.protocolFee > 0) {
            address feeReceiver = Clones.clone(feeReceiverImpl);
            oracleFeeReceiver(feeReceiver).initialize(address(this), uint128(swapId), address(oracle), sellTokenOracleFormat, buyTokenOracleFormat);
            s.feeRecipient = feeReceiver;
        }

        uint256 reportId = oracleGame(s, preimage);

        _ensureOracleApproval(buyTokenOracleFormat);
        _ensureOracleApproval(sellTokenOracleFormat);

        oracle.submitInitialReport(
            reportId,
            initialLiquidity,
            amount2,
            oracle.extraData(reportId).stateHash,
            matcher
        );

        s.reportId = uint128(reportId);
        reportIdToSwapId[reportId] = swapId;

        emit SwapMatched(swapId, fulfillmentFee, matcher, reportId, s.swapper);

    }

    /**
     * @notice Swapper cancels swap, receiving tokens back.
               Must be called prior to match.
               Allows anyone to call 30 seconds after swap expiration, pays them 20% of gas compensation.
     * @param swapId Unique identifier of swapping instance
    */
    function cancelSwap(uint256 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];

        if (s.matched) revert InvalidInput("already matched");
        if (!s.active) revert InvalidInput("not active");
        if (s.cancelled) revert InvalidInput("cancelled");
        if (s.finished) revert InvalidInput("finished");

        address caller;
        uint256 callerPiece;
        uint256 swapperPiece;

        //caching
        address swapper = s.swapper;
        uint96 gasCompensation = s.gasCompensation;
        uint88 settlerReward = s.settlerReward;
        address sellToken = s.sellToken;
        uint128 sellAmt = s.sellAmt;

        if (block.timestamp <= s.expiration + 30){
            if (msg.sender != swapper) revert InvalidInput("not swapper");
            callerPiece = 0;
            swapperPiece = gasCompensation;
        } else {
            if (msg.sender != swapper){
                caller = msg.sender;
                callerPiece = gasCompensation / 5;
                swapperPiece = gasCompensation - callerPiece;
            } else {
                swapperPiece = gasCompensation;
            }
        }

        s.cancelled = true;
        if (sellToken != address(0)) {
            _transferTokens(sellToken, address(this), swapper, sellAmt);
            payEth(swapper, swapperPiece + settlerReward);
            if (caller == msg.sender) payEth(caller, callerPiece);
        } else {
            payEth(swapper, sellAmt + swapperPiece + settlerReward);
            if (caller == msg.sender) payEth(caller, callerPiece);
        }

        emit SwapCancelled(swapId);
    }

    function oracleGame(Swap storage s, MatcherPreimage memory o) internal returns (uint256 reportId) {
        address sellTokenOracleFormat = s.sellToken == address(0) ? WETH : s.sellToken;
        address buyTokenOracleFormat = s.buyToken == address(0) ? WETH : s.buyToken;

        IOpenOracle.CreateReportParams memory params = IOpenOracle.CreateReportParams({
            exactToken1Report: o.initialLiquidity,
            escalationHalt: o.escalationHalt,
            settlerReward: s.settlerReward,
            token1Address: sellTokenOracleFormat,
            settlementTime: o.settlementTime,
            disputeDelay: o.disputeDelay,
            protocolFee: o.protocolFee,
            token2Address: buyTokenOracleFormat,
            callbackGasLimit: 1000000,
            feePercentage: 0,
            multiplier: o.multiplier,
            timeType: o.timeType,
            trackDisputes: false,
            callbackContract: address(this),
            callbackSelector: this.onSettle.selector,
            protocolFeeRecipient: s.feeRecipient
        });

        /* ------------ create report instance ------------ */
        reportId = oracle.createReportInstance{value: s.settlerReward}(params);
        return reportId;

    }

    /* -------- oracle callback -------- */
    function onSettle(uint256 id, uint256, uint256, address, address)
        external
        payable
    {
        if (msg.sender != address(oracle)) revert InvalidInput("invalid sender");
        uint256 swapId = reportIdToSwapId[id];
        Swap storage s = swaps[swapId];
        if (id != s.reportId) revert InvalidInput("wrong reportId");
        if (s.finished) revert InvalidInput("finished");

        _executeSwap(id, swapId, s);

    }

    /**
     * @notice Lets users bail out of a swapId.
               Anyone-can-call.
               Two bail out conditions:
                    1. reportId distributed but swapId not finished
                    2. maxGameTime has passed since oracle game started 
               In 1, swap is executed using final oracle price
               In 2, swapper and matcher are refunded initial token deposits
     * @param swapId Unique identifier of swapping instance
    */
    function bailOut(uint256 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];
        uint256 id = s.reportId;

        if (s.finished) revert InvalidInput("finished");
        if (!s.active) revert InvalidInput("not active");
        if (!s.matched) revert InvalidInput("not matched");
        if (s.cancelled) revert InvalidInput("cancelled");
        if (s.reportId == 0) revert InvalidInput("doesnt exist");

        IOpenOracle.ReportStatus memory rs = oracle.reportStatus(id);

        bool isGameTooLong = block.timestamp - s.start > s.maxGameTime;

        if (rs.settlementTimestamp != 0) {
            _executeSwap(id, swapId, s);
            return;
        }

        if (isGameTooLong) {
            s.finished = true;
            refund(s.sellToken, s.sellAmt, s.swapper, s.buyToken, s.minFulfillLiquidity, s.matcher);
            emit SwapRefunded(swapId, s.swapper, s.matcher);
            return;
        }

        revert InvalidInput("can't bail out yet");

    }

    /**
     * @notice Anyone can distribute protocol fees from a given feeRecipient contract.
               Eventual oracle game callback should always clear these tokens out anyways.
     * @param swapId Unique identification number of swapping instance
     */
    function grabOracleGameFeesAny(uint256 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];
        address feeRecipient = s.feeRecipient;
        if (s.feeRecipient == address(0)) revert InvalidInput("no fee recipient");
        if (oracleFeeReceiver(feeRecipient).gameId() != swapId) revert InvalidInput("feeRecipient not for swapId");
        if (!s.matched) revert InvalidInput("not matched");

        grabOracleGameFees(s);
    }

    /**
     * @notice Withdraws temp holdings for a specific token
     * @param tokenToGet The token address to withdraw tokens for
     */
    function getTempHolding(address tokenToGet, address _to) external nonReentrant {
        uint256 amount = tempHolding[_to][tokenToGet];
        if (amount > 0) {
            tempHolding[_to][tokenToGet] = 0;
            _transferTokens(tokenToGet, address(this), _to, amount);
        }
    }

    function payEth(address _to, uint256 _amount) internal {
        (bool ok,) = payable(_to).call{value: _amount, gas: 40000}("");
        if (!ok) {
            IWETH(WETH).deposit{value: _amount}();
            IERC20(WETH).safeTransfer(_to, _amount);
        }
    }

    function _executeSwap(uint256 id, uint256 swapId, Swap storage s) internal {

        s.finished = true;

        //caching
        address swapper = s.swapper;
        address matcher = s.matcher;
        address buyToken = s.buyToken;
        address sellToken = s.sellToken;
        address feeRecipient = s.feeRecipient;
        uint128 minFulfillLiquidity = s.minFulfillLiquidity;
        uint128 sellAmt = s.sellAmt;
        SlippageParams memory sp = s.slippageParams;

        IOpenOracle.ReportStatus memory rs = oracle.reportStatus(id);
        if (rs.settlementTimestamp == 0) revert InvalidInput("not settled");
        bool timeType = oracle.reportMeta(id).timeType;

        uint256 oracleAmount1 = rs.currentAmount1;
        uint256 oracleAmount2 = rs.currentAmount2;
        uint256 price = oracleAmount1 * 1e18 / oracleAmount2;
        uint256 fulfillAmt = (sellAmt * oracleAmount2) / oracleAmount1;
        fulfillAmt -= fulfillAmt * s.fulfillmentFee / 1e7;

        bool slippageOk = toleranceCheck(price, sp.priceTolerated, sp.toleranceRange);
        bool blocksPerSecondOk = impliedBlocksPerSecond(timeType, rs.reportTimestamp, rs.lastReportOppoTime, s.blocksPerSecond);
        bool slippageBailout = fulfillAmt > minFulfillLiquidity || !slippageOk;
        bool shouldRefund = slippageBailout || !blocksPerSecondOk;

        if (slippageBailout) emit SlippageBailout(swapId);
        if (!blocksPerSecondOk) emit ImpliedBlocksPerSecondBailout(swapId);

        if (shouldRefund) {
            refund(sellToken, sellAmt, swapper, buyToken, minFulfillLiquidity, matcher);
            emit SwapRefunded(swapId, swapper, matcher);
        } else {
            //complete swap
            if (buyToken != address(0)){
                _transferTokens(buyToken, address(this), swapper, fulfillAmt);
                _transferTokens(buyToken, address(this), matcher, minFulfillLiquidity - fulfillAmt);
                if (sellToken != address(0)) {
                    _transferTokens(sellToken, address(this), matcher, sellAmt);
                } else {
                    payEth(matcher, sellAmt);
                }
            } else {
                payEth(swapper, fulfillAmt);
                payEth(matcher, minFulfillLiquidity - fulfillAmt);
                _transferTokens(sellToken, address(this), matcher, sellAmt);
            }

            emit SwapExecuted(swapper, matcher, swapId, sellAmt, uint128(fulfillAmt));

        }

        if (feeRecipient != address(0)) {
            grabOracleGameFees(s);
        }
    }

    /**
     * @dev Internal function to handle token transfers.                
     */
    function _transferTokens(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return; // Gas optimization: skip zero transfers

        if (from == address(this)) {

            (bool success, bytes memory returndata) = token.call(
                    abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
                );

            if (success && ((returndata.length > 0 && abi.decode(returndata, (bool))) || 
                (returndata.length == 0 && address(token).code.length > 0))) {
               return;
            }

            tempHolding[to][token] += amount;

        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    function refund(address sellToken, uint256 sellAmt, address swapper, address buyToken, uint256 buyAmt, address matcher) internal {
        if (sellToken != address(0)){
            _transferTokens(sellToken, address(this), swapper, sellAmt);
            if (buyToken != address(0)){
                _transferTokens(buyToken, address(this), matcher, buyAmt);
            } else {
                payEth(matcher, buyAmt);
            }
        } else {
            payEth(swapper, sellAmt);
            _transferTokens(buyToken, address(this), matcher, buyAmt);
        }

    }

    function calcFee(uint256 maxFee, uint256 startingFee, uint256 growthRate, uint256 maxRounds, uint256 startFulfillFeeIncrease, uint256 roundLength) internal view returns (uint256) {
        uint256 timeDelta = block.timestamp - startFulfillFeeIncrease;
        
        timeDelta = timeDelta / roundLength;
        if (timeDelta > maxRounds) {
            timeDelta = maxRounds;
        }

        uint256 currentFee = startingFee;

        for (uint256 i = 0; i < timeDelta; i++) {
            currentFee = (currentFee * growthRate) / 10000;
            if (currentFee >= maxFee) {
                return maxFee;
            }
        }
        
        return currentFee;
    }

    function toleranceCheck(uint256 price, uint256 priceTolerated, uint24 toleranceRange)
        internal
        pure
        returns (bool)
    {
        uint256 tr = uint256(toleranceRange);
        uint256 upper = (priceTolerated * (1e7 + tr)) / 1e7;
        uint256 lower = (priceTolerated * 1e7) / (1e7 + tr);

        return price >= lower && price <= upper;

    }

    function impliedBlocksPerSecond(bool timeType, uint48 _time, uint48 _timeOppo, uint48 blocksPerSecond) internal view returns (bool) {
        uint48 _timeChangeTrue;
        uint48 _timeChangeBlock;
        uint48 expectedBlocks;
        uint48 _blocksPerSecond = blocksPerSecond;

        if (timeType) {
            _timeChangeTrue = uint48(block.timestamp) - _time;
            _timeChangeBlock = uint48(block.number) - _timeOppo;
        } else {
            _timeChangeTrue = uint48(block.timestamp) - _timeOppo;
            _timeChangeBlock = uint48(block.number) - _time;
        }

        expectedBlocks = _timeChangeTrue * _blocksPerSecond;

        if (
            1000 * _timeChangeBlock > expectedBlocks + 2 * _blocksPerSecond
                || 1000 * _timeChangeBlock + 2 * _blocksPerSecond < expectedBlocks
        ) {
            return false;
        } else {
            return true;
        }
    }

    function grabOracleGameFees(Swap storage s) internal {
        address feeRecipient = s.feeRecipient;
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(feeRecipient);
        address sellToken = s.sellToken == address(0) ? WETH : s.sellToken;
        address buyToken = s.buyToken == address(0) ? WETH : s.buyToken;
        address swapper = s.swapper;
        address matcher = s.matcher;

        try feeReceiver.collect() {} catch{}

        uint256 feesSellToken;
        try feeReceiver.sweep(sellToken) returns (uint256 swept) {
            feesSellToken = swept;
        } catch {}

        uint256 feesBuyToken;
        try feeReceiver.sweep(buyToken) returns (uint256 swept) {
            feesBuyToken = swept;
        } catch {}

        uint256 swapperSellFeePiece = feesSellToken / 2;
        uint256 matcherSellFeePiece = feesSellToken - swapperSellFeePiece;

        _transferTokens(sellToken, address(this), swapper, swapperSellFeePiece);
        _transferTokens(sellToken, address(this), matcher, matcherSellFeePiece);

        uint256 swapperBuyFeePiece = feesBuyToken / 2;
        uint256 matcherBuyFeePiece = feesBuyToken - swapperBuyFeePiece;

        _transferTokens(buyToken, address(this), swapper, swapperBuyFeePiece);
        _transferTokens(buyToken, address(this), matcher, matcherBuyFeePiece);

        emit FeesTransferred(swapper, matcher, buyToken, sellToken, uint128(feesBuyToken), uint128(feesSellToken), feeRecipient);

    }

    function _ensureOracleApproval(address token) internal {                                                                                                                                            
        if (!_oracleApproved[token]) {                                                                                                                                                                  
            IERC20(token).forceApprove(address(oracle), type(uint256).max);                                                                                                                                  
            _oracleApproved[token] = true;                                                                                                                                                              
        }                                                                                                                                                                                               
    }

    /* -------- VIEW FUNCTIONS -------- */

    /**
     * @notice Returns the full Swap struct for a given swapId
     * @param swapId Unique identifier of swapping instance
     */
    function getSwap(uint256 swapId) external view returns (Swap memory) {
        return swaps[swapId];
    }

    /**
     * @notice Returns slippage parameters for a given swapId
     * @param swapId Unique identifier of swapping instance
     */
    function getSlippageParams(uint256 swapId) external view returns (SlippageParams memory) {
        return swaps[swapId].slippageParams;
    }

    /**
     * @notice Returns the current fulfillment fee for a given swapId based on time elapsed
     * @dev Returns 0 if swap is already matched, otherwise calculates current fee
     * @param swapId Unique identifier of swapping instance
     */
    function getCurrentFulfillmentFee(uint256 swapId, MatcherPreimage memory preimage) external view returns (uint256) {
        Swap storage s = swaps[swapId];

        if (s.matched || s.oracleAndFeeParamHash != keccak256(abi.encode(preimage))) {
            return 0;
        }

        return calcFee(preimage.maxFee, preimage.startingFee, preimage.growthRate, preimage.maxRounds, preimage.startFulfillFeeIncrease, preimage.roundLength);
    }

    /**
     * @notice Returns the keccak256 hash of a Swap struct for optional matcher verification
     * @dev Risky if trusting an RPC - a malicious RPC can return false data. Use your own node or construct yourself with expected parameters for protection.
     * @param swapId Unique identifier of swapping instance
     */
    function getSwapHash(uint256 swapId) external view returns (bytes32) {
        return keccak256(abi.encode(swaps[swapId]));
    }

}

