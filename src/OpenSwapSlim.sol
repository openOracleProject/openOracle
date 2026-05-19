// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOpenOracle2} from "./interfaces/IOpenOracle2.sol";
import {oracleFeeReceiver} from "./oracleFeeReceiver.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";
import {Errors} from "./libraries/Errors.sol";

/**
 * @title openSwap
 * @notice A user proposes a swap, someone matches it, and openOracle determines the execution price.
 *         The matcher earns a fee for their service.
 *
 *         In openOracle, a price report is two limit orders, a buy and a sell, at the same price.
 *         The orders are locked until either the timer runs out or one is taken.
 *         To take one of the limit orders, you replace them with larger ones at a new price.
 *         When the timer runs out without a dispute, the price is settled. Any disputes reset the timer.
 *
 *         Supported token types: vanilla ERC20 and USDT-style tokens that omit a return value on transfer/transferFrom.
 *         Not supported: fee-on-transfer, rebasing, ERC777 / tokens with transfer hooks, or any token whose
 *         balance can change without a corresponding transfer event from this contract. Using unsupported tokens
 *         may cause loss of funds or incorrect fee accounting.
 * @author OpenOracle Team
 * @custom:version 0.2.0
 * @custom:documentation https://docs.openoracle.org/
 */
contract openSwapV2 is ReentrancyGuard {
    IOpenOracle2 public immutable oracle;
    address public immutable feeReceiverImpl;

    constructor(address oracle_) {
        oracle = IOpenOracle2(oracle_);
        feeReceiverImpl = address(new oracleFeeReceiver());
    }

    mapping(uint256 => bytes32) public swaps;
    uint256 public nextSwapId = 1;

    mapping(address => uint256) public tempHolding;

    struct MatchedSwap {
        uint128 sellAmt; // amount of sellToken the swapper is selling
        uint128 minFulfillLiquidity; // minimum amount of buyToken the matcher must put in the contract
        uint24 maxGameTime; // if oracle game does not finalize this much time after match, both parties are eligible for refund
        uint16 blocksPerSecond; // 500 = 2 seconds per block on Base
        address buyToken; // address for token swapper wants
        address sellToken; // address for token swapper is selling
        address swapper; // msg.sender of swapper. Non-zero ⇔ swap exists.
        uint96 executorGasComp; // wei paid to caller of execute()
        bool useInternalBalances; // swapper's option to use internal oracle balances to fund the swap
        uint128 reportId; // oracle game reportId
        address matcher;
        uint48 start; // timestamp at which order is matched
        uint24 fulfillmentFee; // 1000 = 0.01%, fee paid to matcher
        address feeRecipient; // contract holding protocol fees from oracle game
        uint232 priceTolerated;  // example: WETH (18 dec) / USDC (6 dec) at $4442.99/ETH → priceTolerated ≈ 1e18 * 1e30 / (4442.99 * 1e6) ≈ 2.25e38.
        uint24 toleranceRange; // 100000 = 1%, max slippage against priceTolerated
    }

    struct ProposedSwap {
        uint128 sellAmt;
        uint128 minFulfillLiquidity; // minimum amount of buyToken the matcher must put in the contract
        uint96 settlerReward; // reward paid to openOracle settler. often 0 since execute() can also settle
        uint24 maxGameTime;
        uint16 blocksPerSecond;
        address buyToken;
        uint96 matcherGasComp; // swapper pays matcher this amount of wei to call match
        address sellToken;
        address swapper; // override; expected = address(0); contract sets to msg.sender before hashing
        uint96 executorGasComp;
        bool useInternalBalances;
        uint48 expiration; // swapper passes a time offset but is stored in swapHash as an absolute timestamp expiry
        uint232 priceTolerated;  // example: WETH (18 dec) / USDC (6 dec) at $4442.99/ETH → priceTolerated ≈ 1e18 * 1e30 / (4442.99 * 1e6) ≈ 2.25e38.
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

    /// @dev Oracle game + fulfillment fee params supplied by the matcher at match time.
    ///      Hash-bound at propose; openSwap stores only the hash.
    struct MatcherPreimage {
        uint128 initialLiquidity;
        uint128 escalationHalt;
        uint48 settlementTime;
        uint24 disputeDelay;
        uint24 protocolFee;
        uint16 multiplier;
        uint48 startFulfillFeeIncrease; // override; expected = 0; contract sets to block.timestamp before hashing
        uint24 maxFee;
        uint24 startingFee;
        uint24 roundLength;
        uint16 growthRate;
        uint16 maxRounds;
    }

    bytes32 private constant SWAP_CREATED_SIG =
        keccak256("SwapCreated(uint256,address,bytes)");
    bytes32 private constant SWAP_MATCHED_SIG =
        keccak256("SwapMatched(uint256,bytes)");

    // Emitted via raw log opcodes. `packed` is raw bytes from _packMem,
    // not ABI-encoded dynamic bytes.
    event SwapCreated(uint256 indexed swapId, address indexed swapper, bytes packed);
    event SwapCancelled(uint256 swapId);
    event SwapRefunded(uint256 swapId, address indexed swapper, address indexed matcher);
    event SwapExecuted(uint256 swapId);
    event SwapMatched(uint256 indexed swapId, bytes packed);
    event FeesTransferred(
        address indexed swapper,
        address indexed matcher,
        address buyToken,
        address sellToken,
        uint128 feesBuyToken,
        uint128 feesSellToken,
        address feeRecipientContract
    );
    event SlippageBailout(uint256 swapId);
    event ImpliedBlocksPerSecondBailout(uint256 swapId);

    /**
     * @notice Creates a swap, routing sellAmt of sellToken into openOracle's internal accounting
     *         for openSwap (via Permit2, oracle.deposit, or oracle.internalTransferFrom).
     * @dev Only the swap hash is stored on-chain. All future callers (matchSwap, cancelSwap, execute,
     *      bailOut) must supply the exact ProposedSwap / MatcherPreimage / MatchedSwap that
     *      reconstructs the current swap hash; off-chain indexing is the caller's responsibility.
     * @param s ProposedSwap parameters; s.swapper is set to msg.sender and s.expiration is converted to an absolute timestamp by the contract
     * @param m MatcherPreimage parameters; m.startFulfillFeeIncrease is set to block.timestamp by the contract
     * @param permit2 Permit2 nonce / deadline / signature, used when sellToken is ERC20 and useInternalBalances is false
     * @param minOut Minimum buyToken amount the swapper accepts at settlement
     * @return swapId Sequence number assigned to the new swap
     */
    function propose(
        ProposedSwap calldata s,
        MatcherPreimage calldata m,
        Permit2Params calldata permit2,
        uint128 minOut
    ) external payable returns (uint256 swapId) {
        uint256 settlerReward = s.settlerReward;
        uint256 extraEth = s.matcherGasComp + settlerReward + s.executorGasComp;
        address sellToken = s.sellToken;
        address buyToken = s.buyToken;
        uint128 sellAmt = s.sellAmt;
        uint48 expiration = s.expiration;
        bool useInternalBalances = s.useInternalBalances;
        bool isEth = sellToken == address(0);
        bool needsPermit2 = !useInternalBalances && !isEth;
        uint256 expected = (isEth && !useInternalBalances) ? sellAmt + extraEth : extraEth;

        if (msg.value != expected) revert Errors.InvalidMsgValue();

        if (sellToken == buyToken) revert Errors.TokensCannotBeSame();
        if (sellAmt == 0 || minOut == 0 || s.minFulfillLiquidity == 0) revert Errors.ZeroAmount();
        if (expiration == 0 || expiration > 30 days) revert Errors.InvalidExpiration();
        if (m.maxFee >= 1e7) revert Errors.InvalidFulfillFee();

        if (
            s.priceTolerated == 0 || s.toleranceRange == 0
                || s.toleranceRange > 1e7
        ) revert Errors.InvalidSlippage();

        if (
            m.settlementTime == 0 || m.initialLiquidity == 0 || s.blocksPerSecond == 0
                || m.disputeDelay >= m.settlementTime || m.escalationHalt < m.initialLiquidity
                || m.settlementTime > 4 * 60 * 60 || m.protocolFee >= 1e7 || s.maxGameTime < m.settlementTime * 20
                || s.maxGameTime > 604800 || m.multiplier < 100
        ) revert Errors.InvalidOracleParams();

        if (
            m.maxFee == 0 || m.startingFee == 0 || m.growthRate < 10000 || m.maxRounds == 0 || m.maxRounds > 100
                || m.roundLength == 0 || m.maxFee < m.startingFee || m.maxFee > 1e7
        ) revert Errors.InvalidFulfillFeeParams();

        if (s.swapper != address(0) || m.startFulfillFeeIncrease != 0) revert Errors.MustBeZero();

        uint256 upperPrice =
            Math.mulDiv(s.priceTolerated, uint256(1e7) + s.toleranceRange, 1e7);
        uint256 worstFulfillAmt = Math.mulDiv(sellAmt, 1e30, upperPrice);
        worstFulfillAmt -= Math.mulDiv(worstFulfillAmt, m.maxFee, 1e7);

        if (minOut > worstFulfillAmt) revert Errors.MinOutInconsistent();

        swapId = nextSwapId++;

        // Two hashes share one buffer. swapHash layout matches abi.encode(ProposedSwap, MatcherPreimage):
        //   0x000..0x1C0 ProposedSwap (14 slots) · 0x1C0..0x340 MatcherPreimage (12 slots)
        // permitIntent temporarily appends minOut at 0x340 and hashes 0x360 bytes.
        // Overrides (slot N at N*0x20): 0x100 s.swapper←caller · 0x160 s.expiration←absolute · 0x280 m.startFulfillFeeIncrease←ts
        // permitIntent skips the timestamp overrides so the user signs runtime-independent inputs.
        uint256 absoluteExpiration = uint256(block.timestamp) + uint256(s.expiration);
        bytes32 swapHash;
        bytes32 permitIntent;
        uint256 stagedMem;
        assembly ("memory-safe") {
            let mem := mload(0x40)
            calldatacopy(mem, s, 0x1C0)
            calldatacopy(add(mem, 0x1C0), m, 0x180)
            mstore(add(mem, 0x100), caller()) // swapper override

            if needsPermit2 {
                mstore(add(mem, 0x340), minOut)
                permitIntent := keccak256(mem, 0x360)
            }

            // swapHash with full overrides
            mstore(add(mem, 0x160), absoluteExpiration) // expiration → absolute
            mstore(add(mem, 0x280), timestamp()) // startFulfillFeeIncrease
            swapHash := keccak256(mem, 0x340)
            stagedMem := mem
            mstore(0x40, add(mem, 0x360))
        }

        if (useInternalBalances) {
            oracle.internalTransferFrom(msg.sender, address(this), sellToken, sellAmt);
        } else {
            if (isEth) {
                oracle.deposit{value: sellAmt}(address(0), sellAmt, address(this));
            } else {
                oracle.depositFromPermit2(
                    sellAmt,
                    address(this),
                    msg.sender,
                    permitIntent,
                    ISignatureTransfer.PermitTransferFrom({
                        permitted: ISignatureTransfer.TokenPermissions({token: sellToken, amount: sellAmt}),
                        nonce: permit2.nonce,
                        deadline: permit2.deadline
                    }),
                    permit2.signature
                );
            }
        }

        swaps[swapId] = swapHash; // CEI inversion: swap becomes live only after funding succeeds.

        uint256 packedLen = _packMem(stagedMem, 1);
        bytes32 sig = SWAP_CREATED_SIG;
        assembly ("memory-safe") {
            log3(stagedMem, packedLen, sig, swapId, caller())
        }
    }

    /**
     * @notice Matcher matches swap and submits oracle initial report, sending tokens into contract
     * @param swapId Unique identifier of swapping instance
     * @param amount2 Oracle game amount2
     * @param _swap ProposedSwap committed at propose
     * @param preimage MatcherPreimage committed at propose
     * @param timing Oracle timing bounds
     */
    function matchSwap(
        uint256 swapId,
        uint128 amount2,
        ProposedSwap calldata _swap,
        MatcherPreimage calldata preimage,
        IOpenOracle2.TimingBoundaries calldata timing
    ) external {
        bytes32 passedHash;
        uint256 stagedMem;

        assembly ("memory-safe") {
            stagedMem := mload(0x40)
            calldatacopy(stagedMem, _swap, 0x1c0)
            calldatacopy(add(stagedMem, 0x1c0), preimage, 0x180)
            passedHash := keccak256(stagedMem, 0x340)
            mstore(0x40, add(stagedMem, 0x340))
        }

        if (passedHash != swaps[swapId]) revert Errors.WrongHash();

        MatchedSwap memory s;

        s.sellAmt = _swap.sellAmt;
        s.minFulfillLiquidity = _swap.minFulfillLiquidity;
        s.maxGameTime = _swap.maxGameTime;
        s.blocksPerSecond = _swap.blocksPerSecond;
        s.buyToken = _swap.buyToken;
        s.sellToken = _swap.sellToken;
        s.swapper = _swap.swapper;
        s.executorGasComp = _swap.executorGasComp;
        s.useInternalBalances = _swap.useInternalBalances;
        s.priceTolerated = _swap.priceTolerated;
        s.toleranceRange = _swap.toleranceRange;

        address buyToken = s.buyToken;
        address sellToken = s.sellToken;
        uint128 minFulfillLiquidity = s.minFulfillLiquidity;
        uint96 matcherGasComp = _swap.matcherGasComp;
        uint96 settlerReward = _swap.settlerReward;

        if (s.swapper == address(0)) revert Errors.NotActive();
        if (block.timestamp > _swap.expiration) revert Errors.Expired();

        address matcher = msg.sender;
        uint24 fulfillmentFee = uint24(
            calcFee(
                preimage.maxFee,
                preimage.startingFee,
                preimage.growthRate,
                preimage.maxRounds,
                preimage.startFulfillFeeIncrease,
                preimage.roundLength
            )
        );

        s.matcher = matcher;
        s.start = uint48(block.timestamp);
        s.fulfillmentFee = fulfillmentFee;

        tempHolding[matcher] += matcherGasComp;

        if (preimage.protocolFee > 0) {
            address feeReceiver = Clones.clone(feeReceiverImpl);
            s.feeRecipient = feeReceiver;
        }
        s.reportId = uint128(oracle.nextReportId());

        uint256 matchedMem;
        bytes32 matchedHash;
        assembly ("memory-safe") {
            matchedMem := s
            matchedHash := keccak256(matchedMem, 0x200)
        }
        swaps[swapId] = matchedHash;

        if (s.feeRecipient != address(0)) {
            oracleFeeReceiver(s.feeRecipient).initialize(
                uint128(swapId), address(oracle), sellToken, buyToken, s.swapper, matcher
            );
        }
        oracleGame(s, preimage, timing, amount2, matcher, settlerReward);
        oracle.internalTransferFrom(matcher, address(this), buyToken, minFulfillLiquidity);

        uint256 packedLen = _packMem(matchedMem, 2);
        bytes32 sig = SWAP_MATCHED_SIG;
        assembly ("memory-safe") {
            log2(matchedMem, packedLen, sig, swapId)
        }

    }

    /**
     * @notice Swapper cancels swap, receiving tokens back. Must be called prior to match.
     *         At or before expiration: only the swapper can call.
     *         After expiration: anyone can call; caller receives matcherGasComp,
     *         swapper receives executorGasComp + settlerReward.
     * @param swapId Unique identifier of swapping instance
     * @param _swap ProposedSwap committed at propose
     * @param preimage MatcherPreimage committed at propose
     */
    function cancelSwap(uint256 swapId, ProposedSwap calldata _swap, MatcherPreimage calldata preimage)
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
        uint256 totalGasComp = uint256(s.matcherGasComp) + uint256(s.executorGasComp);
        uint96 settlerReward = s.settlerReward;
        address sellToken = s.sellToken;
        uint128 sellAmt = s.sellAmt;

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
            oracle.internalTransferFrom(address(this), swapper, sellToken, sellAmt);
        } else {
            oracle.pushOrCredit(sellToken, swapper, sellAmt);
            payEth(swapper, swapperPiece + settlerReward);
        }

        emit SwapCancelled(swapId);
    }

    function oracleGame(
        MatchedSwap memory s,
        MatcherPreimage memory o,
        IOpenOracle2.TimingBoundaries memory timing,
        uint128 amount2,
        address matcher,
        uint96 settlerReward
    ) internal returns (uint256 reportId) {
        IOpenOracle2.OracleGame memory params = IOpenOracle2.OracleGame({
            currentAmount1: o.initialLiquidity,
            currentAmount2: amount2,
            currentReporter: matcher,
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: s.sellToken,
            lastReportOppoTime: 0,
            settlementTime: o.settlementTime,
            escalationHalt: o.escalationHalt,
            protocolFeeRecipient: s.feeRecipient,
            settlerReward: settlerReward,
            token2: s.buyToken,
            numReports: 0,
            disputeDelay: o.disputeDelay,
            feePercentage: 0,
            multiplier: o.multiplier,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: o.protocolFee,
            flags: 1
        });

        reportId = oracle.report{value: settlerReward}(params, true, true, timing);
    }

    /**
     * @notice Lets users bail out of a swapId.
     *            Anyone-can-call. Caller earns executor gas compensation.
     *            One bail out condition:
     *                 maxGameTime has passed since oracle game started → swapper and matcher are refunded initial token deposits
     * @param swapId Unique identifier of swapping instance
     * @param _swap MatchedSwap committed at matchSwap
     */
    function bailOut(uint256 swapId, MatchedSwap calldata _swap) external nonReentrant {
        bytes32 passedHash = keccak256(abi.encode(_swap));
        if (passedHash != swaps[swapId]) revert Errors.WrongHash();

        MatchedSwap memory s = _swap;

        if (s.matcher == address(0)) revert Errors.NotMatched();
        if (s.swapper == address(0)) revert Errors.NotActive();

        bool isGameTooLong = block.timestamp - s.start > s.maxGameTime;

        if (isGameTooLong) {
            delete swaps[swapId];
            tempHolding[msg.sender] += s.executorGasComp;
            refund(
                s.sellToken, s.sellAmt, s.swapper, s.buyToken, s.minFulfillLiquidity, s.matcher, s.useInternalBalances
            );
            emit SwapRefunded(swapId, s.swapper, s.matcher);
            return;
        }

        revert Errors.CantBailOutYet();
    }

    /// @notice Seeds a 1-wei sentinel on `_to`'s tempHolding slot to warm it for future credits. Caller pays the 1 wei.
    /// @param _to Address whose tempHolding slot to seed
    function dust(address _to) external payable {
        if (msg.value != 1) revert Errors.InvalidMsgValue();
        tempHolding[_to] += 1;
    }

    /**
     * @notice Withdraws queued ETH gas-comp credits to `_to`. If caller != `_to`, a 1-wei
     *         sentinel is always preserved on `_to`'s slot.
     * @param _to Recipient of the withdrawn ETH
     * @param leaveOne If true, preserve the 1-wei sentinel on `_to`'s slot even when caller == `_to`
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

    /// @dev Bounded-gas ETH push used during state transitions. On failure, credits
    ///      `_to`'s `tempHolding` slot so the recipient can retrieve via `withdraw`.
    function payEth(address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        (bool ok,) = payable(_to).call{value: _amount, gas: 50000}("");
        if (!ok) tempHolding[_to] += _amount;
    }

    /**
     * @notice Settles the oracle report if not already settled, then delivers buyToken to
     *         swapper and sellToken to matcher (or refunds on slippage/blocksPerSecond bailout).
     * @param swapId Unique identifier of swapping instance
     * @param swapState MatchedSwap committed at matchSwap
     * @param oracleState Oracle game state matching the stored oracle hash
     * @param oracleHelper Oracle preimage helper matching the stored oracle hash
     * @param looseTiming If true, accept oracleState that's off by one block from the stored hash
     */
    function execute(
        uint256 swapId,
        MatchedSwap calldata swapState,
        IOpenOracle2.OracleGame calldata oracleState,
        IOpenOracle2.PreimageHelper calldata oracleHelper,
        bool looseTiming
    ) external {
        MatchedSwap memory s;
        bytes32 passedSwapHash;

        assembly ("memory-safe") {
            let mem := mload(0x40)
            calldatacopy(mem, swapState, 0x200)
            passedSwapHash := keccak256(mem, 0x200)
            s := mem
            mstore(0x40, add(mem, 0x200))
        }

        if (passedSwapHash != swaps[swapId]) revert Errors.WrongHash();

        if (s.matcher == address(0)) revert Errors.NotMatched();
        if (s.swapper == address(0)) revert Errors.NotActive();

        uint256 reportId = s.reportId;
        bytes32 oracleHash = oracle.oracleGame(reportId);

        bytes32 passedHash;
        uint256 oracleMem;

        assembly ("memory-safe") {
            oracleMem := mload(0x40)
            calldatacopy(oracleMem, oracleState, 0x280)
            calldatacopy(add(oracleMem, 0x280), oracleHelper, 0x80)
            passedHash := keccak256(oracleMem, 0x300)
            mstore(0x40, add(oracleMem, 0x300))
        }

        bool matches = oracleHash == passedHash;
        bool alreadySettled;

        // loose hash if settle beat you in the same block
        if (!matches && oracleState.settlementTimestamp == 0 && looseTiming) {
            assembly ("memory-safe") {
                mstore(add(oracleMem, 0x80), timestamp())
                passedHash := keccak256(oracleMem, 0x300)
            }
            matches = oracleHash == passedHash;
            alreadySettled = true;
        }

        // loose hash for block boundaries
        if (!matches && oracleState.settlementTimestamp > 2 && looseTiming) {
            assembly ("memory-safe") {
                mstore(add(oracleMem, 0x80), sub(timestamp(), 2))
                passedHash := keccak256(oracleMem, 0x300)
            }
            matches = oracleHash == passedHash;
            alreadySettled = true;
        }

        if (!matches) revert Errors.WrongOracleHash();

        if (uint48(block.timestamp) < oracleState.reportTimestamp + oracleState.settlementTime) {
            revert Errors.OracleSettlementNotEligible();
        }

        delete swaps[swapId];
        uint96 executorGasComp = s.executorGasComp;
        uint96 settlerReward = oracleState.settlerReward;

        tempHolding[msg.sender] += executorGasComp;

        if (oracleState.settlementTimestamp == 0 && !alreadySettled) {
            oracle.settle(reportId, oracleState, oracleHelper);
            if (settlerReward > 0) {
                oracle.internalTransferFrom(address(this), msg.sender, address(0), settlerReward); // forward reward to executor
            }
        }

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

        bool slippageOk = toleranceCheck(price, s.priceTolerated, s.toleranceRange);
        bool blocksPerSecondOk =
            impliedBlocksPerSecond(oracleState.reportTimestamp, oracleState.lastReportOppoTime, blocksPerSecond);
        bool slippageBailout = fulfillAmt > minFulfillLiquidity || !slippageOk;
        bool shouldRefund = slippageBailout || !blocksPerSecondOk;

        if (slippageBailout) emit SlippageBailout(swapId);
        if (!blocksPerSecondOk) emit ImpliedBlocksPerSecondBailout(swapId);

        if (shouldRefund) {
            refund(sellToken, sellAmt, swapper, buyToken, minFulfillLiquidity, matcher, s.useInternalBalances);
            emit SwapRefunded(swapId, swapper, matcher);
        } else {
            oracle.internalTransferFrom(address(this), matcher, sellToken, sellAmt);
            if (s.useInternalBalances) {
                oracle.internalTransferFrom(address(this), swapper, buyToken, uint128(fulfillAmt));
                oracle.internalTransferFrom(address(this), matcher, buyToken, uint128(minFulfillLiquidity - fulfillAmt));
            } else {
                oracle.pushOrCredit(buyToken, swapper, uint128(fulfillAmt));
                oracle.internalTransferFrom(address(this), matcher, buyToken, uint128(minFulfillLiquidity - fulfillAmt));
            }
            emit SwapExecuted(swapId);
        }

        if (feeRecipient != address(0)) {
            grabOracleGameFees(s);
        }
    }

    function refund(
        address sellToken,
        uint128 sellAmt,
        address swapper,
        address buyToken,
        uint128 buyAmt,
        address matcher,
        bool useInternalBalances
    ) internal {
        if (useInternalBalances) {
            oracle.internalTransferFrom(address(this), swapper, sellToken, sellAmt);
        } else {
            oracle.pushOrCredit(sellToken, swapper, sellAmt);
        }
        oracle.internalTransferFrom(address(this), matcher, buyToken, buyAmt);
    }

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

    function impliedBlocksPerSecond(uint48 _time, uint48 _timeOppo, uint48 blocksPerSecond)
        internal
        view
        returns (bool)
    {
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

    function grabOracleGameFees(MatchedSwap memory s) internal {
        try oracleFeeReceiver(s.feeRecipient).distribute() returns (uint256 feesSellToken, uint256 feesBuyToken) {
            emit FeesTransferred(
                s.swapper,
                s.matcher,
                s.buyToken,
                s.sellToken,
                uint128(feesBuyToken),
                uint128(feesSellToken),
                s.feeRecipient
            );
        } catch {}
    }

    /**
     * @dev Packs committed OpenSwap preimages in place for raw-log event emission.
     *      kind == 1: input is abi.encode(ProposedSwap, MatcherPreimage), 0x340 bytes.
     *                 output is 237 raw bytes.
     *      kind == 2: input is abi.encode(MatchedSwap), 0x200 bytes.
     *                 output is 207 raw bytes.
     */
    function _packMem(uint256 mem, uint8 kind) internal pure returns (uint256 packedLen) {
        assembly ("memory-safe") {
            switch kind
            case 1 {
                // ProposedSwap (14 slots -> 172 bytes)
                mstore(mem,             shl(128, mload(mem)))                 // sellAmt              (W=16)
                mstore(add(mem,  16),   shl(128, mload(add(mem, 0x20))))      // minFulfillLiquidity  (W=16)
                mstore(add(mem,  32),   shl(160, mload(add(mem, 0x40))))      // settlerReward        (W=12)
                mstore(add(mem,  44),   shl(232, mload(add(mem, 0x60))))      // maxGameTime          (W=3)
                mstore(add(mem,  47),   shl(240, mload(add(mem, 0x80))))      // blocksPerSecond      (W=2)
                mstore(add(mem,  49),   shl( 96, mload(add(mem, 0xa0))))      // buyToken             (W=20)
                mstore(add(mem,  69),   shl(160, mload(add(mem, 0xc0))))      // matcherGasComp       (W=12)
                mstore(add(mem,  81),   shl( 96, mload(add(mem, 0xe0))))      // sellToken            (W=20)
                mstore(add(mem, 101),   shl( 96, mload(add(mem, 0x100))))     // swapper              (W=20)
                mstore(add(mem, 121),   shl(160, mload(add(mem, 0x120))))     // executorGasComp      (W=12)
                mstore8(add(mem, 133),  byte(31, mload(add(mem, 0x140))))     // useInternalBalances  (W=1)
                mstore(add(mem, 134),   shl(208, mload(add(mem, 0x160))))     // expiration           (W=6)
                mstore(add(mem, 140),   shl( 24, mload(add(mem, 0x180))))     // priceTolerated       (W=29)
                mstore(add(mem, 169),   shl(232, mload(add(mem, 0x1a0))))     // toleranceRange       (W=3)

                // MatcherPreimage starts at source 0x1c0 (12 slots -> 65 bytes)
                mstore(add(mem, 172),   shl(128, mload(add(mem, 0x1c0))))     // initialLiquidity     (W=16)
                mstore(add(mem, 188),   shl(128, mload(add(mem, 0x1e0))))     // escalationHalt       (W=16)
                mstore(add(mem, 204),   shl(208, mload(add(mem, 0x200))))     // settlementTime       (W=6)
                mstore(add(mem, 210),   shl(232, mload(add(mem, 0x220))))     // disputeDelay         (W=3)
                mstore(add(mem, 213),   shl(232, mload(add(mem, 0x240))))     // protocolFee          (W=3)
                mstore(add(mem, 216),   shl(240, mload(add(mem, 0x260))))     // multiplier           (W=2)
                mstore(add(mem, 218),   shl(208, mload(add(mem, 0x280))))     // startFulfillFeeIncrease (W=6)
                mstore(add(mem, 224),   shl(232, mload(add(mem, 0x2a0))))     // maxFee               (W=3)
                mstore(add(mem, 227),   shl(232, mload(add(mem, 0x2c0))))     // startingFee          (W=3)
                mstore(add(mem, 230),   shl(232, mload(add(mem, 0x2e0))))     // roundLength          (W=3)
                mstore(add(mem, 233),   shl(240, mload(add(mem, 0x300))))     // growthRate           (W=2)
                mstore(add(mem, 235),   shl(240, mload(add(mem, 0x320))))     // maxRounds            (W=2)

                packedLen := 237
            }
            case 2 {
                // MatchedSwap (16 slots -> 207 bytes)
                mstore(mem,             shl(128, mload(mem)))                 // sellAmt              (W=16)
                mstore(add(mem,  16),   shl(128, mload(add(mem, 0x20))))      // minFulfillLiquidity  (W=16)
                mstore(add(mem,  32),   shl(232, mload(add(mem, 0x40))))      // maxGameTime          (W=3)
                mstore(add(mem,  35),   shl(240, mload(add(mem, 0x60))))      // blocksPerSecond      (W=2)
                mstore(add(mem,  37),   shl( 96, mload(add(mem, 0x80))))      // buyToken             (W=20)
                mstore(add(mem,  57),   shl( 96, mload(add(mem, 0xa0))))      // sellToken            (W=20)
                mstore(add(mem,  77),   shl( 96, mload(add(mem, 0xc0))))      // swapper              (W=20)
                mstore(add(mem,  97),   shl(160, mload(add(mem, 0xe0))))      // executorGasComp      (W=12)
                mstore8(add(mem, 109),  byte(31, mload(add(mem, 0x100))))     // useInternalBalances  (W=1)
                mstore(add(mem, 110),   shl(128, mload(add(mem, 0x120))))     // reportId             (W=16)
                mstore(add(mem, 126),   shl( 96, mload(add(mem, 0x140))))     // matcher              (W=20)
                mstore(add(mem, 146),   shl(208, mload(add(mem, 0x160))))     // start                (W=6)
                mstore(add(mem, 152),   shl(232, mload(add(mem, 0x180))))     // fulfillmentFee       (W=3)
                mstore(add(mem, 155),   shl( 96, mload(add(mem, 0x1a0))))     // feeRecipient         (W=20)
                mstore(add(mem, 175),   shl( 24, mload(add(mem, 0x1c0))))     // priceTolerated       (W=29)
                mstore(add(mem, 204),   shl(232, mload(add(mem, 0x1e0))))     // toleranceRange       (W=3)

                packedLen := 207
            }
        }
    }
}
