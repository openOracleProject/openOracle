// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";
import {oracleFeeReceiver} from "./oracleFeeReceiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISignatureTransfer} from "../interfaces/ISignatureTransfer.sol";
import {SwapErrors as Errors} from "../libraries/SwapErrors.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/**
 * @title openSwap
 * @notice A user proposes a swap, someone matches it, and openOracle determines the execution price.
 *         The matcher earns a fee for their service and submits the initial openOracle report.
 *
 *         In openOracle, a price report is two limit orders, a buy and a sell, at the same price.
 *         The orders are locked until either the timer runs out or one is taken.
 *         To take one of the limit orders, you replace them with larger ones at a new price.
 *         When the timer runs out without a dispute, the price is settled. Any disputes reset the timer.
 *
 *         Supported token types: vanilla ERC20 and USDT-style tokens that omit a return value on transfer/transferFrom.
 *         Not supported: fee-on-transfer, rebasing, ERC777 / tokens with transfer hooks, tokens whose
 *         transfer/transferFrom returns anything other than nothing or an ABI-encoded bool, or any token whose
 *         balance held by openOracle can change without a transfer to or from openOracle. Using unsupported
 *         tokens may cause loss or lockup of funds, or incorrect fee accounting.
 * @author OpenOracle Team
 * @custom:version 0.2.0
 * @custom:documentation https://docs.openoracle.org/
 */
contract openSwapV2 is ReentrancyGuard {
    IOpenOracle2 public immutable oracle;
    address public immutable feeReceiverImpl;

    constructor(address oracle_) {
        oracle = IOpenOracle2(oracle_);
        feeReceiverImpl = address(new oracleFeeReceiver(IOpenOracle2(oracle_)));
    }

    mapping(uint256 => bytes32) public swaps;
    uint256 public nextSwapId = 1;

    uint256 constant public MAX_SETTLEMENT_TIME = 60480; // 3.36 hours at 0.2 second blocks
    uint256 constant public MIN_SETTLEMENT_TIME = 2; // >= 2 blocks always leaves at least 1 block to dispute
    uint256 constant public MAX_MULTIPLIER = 200; // 2x multiplier maximum on oracle game
    uint256 constant public MIN_GAME_TIME_MULTIPLE = 50; // maxGameTime must be at least 50× settlementTime.
    uint256 constant public MAX_GAME_TIME = MAX_SETTLEMENT_TIME * MIN_GAME_TIME_MULTIPLE;
    uint256 constant public MAX_FEE_ROUNDS = 250; // fulfillment fee can grow geometrically for up to 250 rounds
    uint256 constant public MAX_EXPIRATION = 30 days; // swap expiration cannot be more than 30 days
    uint256 constant public ETH_SEND_GAS = 50000; // cap on gas receiving account can spend in the payEth() transfer

    mapping(address => uint256) public tempHolding;

    struct MatchedSwap {
        uint128 sellAmt; // amount of sellToken the swapper is selling
        uint128 minFulfillLiquidity; // minimum amount of buyToken the matcher must put in the contract
        uint24 maxGameTime; // if oracle game does not become settleable within this many blocks after match, both parties are eligible for refund
        address buyToken; // address for token swapper wants
        address sellToken; // address for token swapper is selling
        address swapper; // msg.sender of swapper. Non-zero ⇔ swap exists.
        uint96 executorGasComp; // wei paid to caller of execute()
        bool useInternalBalances; // swapper's option to use internal oracle balances to fund the swap
        uint128 reportId; // oracle game reportId
        address matcher;
        uint48 start; // block number at which order is matched
        uint24 fulfillmentFee; // 1000 = 0.01%, fee paid to matcher
        address feeRecipient; // contract holding protocol fees from oracle game
        uint232 priceTolerated;  // example: WETH (18 dec) / USDC (6 dec) at $4442.99/ETH → priceTolerated ≈ 1e18 * 1e30 / (4442.99 * 1e6) ≈ 2.25e38.
        uint24 toleranceRange; // 100000 = 1%, max slippage against priceTolerated
    }

    struct ProposedSwap {
        uint128 sellAmt;
        uint128 minFulfillLiquidity; // minimum amount of buyToken the matcher must put in the contract
        uint96 settlerReward; // reward paid to openOracle settler. often 0 since execute() can also settle
        uint24 maxGameTime; // in blocks
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

    struct Permit2Params {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    /// @dev Oracle game + fulfillment fee params supplied by the matcher at match time.
    ///      Hash-bound at propose; openSwap stores only the hash.
    struct MatcherPreimage {
        uint128 initialLiquidity; // starting oracle game size in token1 terms
        uint128 escalationHalt; // point after which disputes can continue but sizes no longer grow geometrically
        uint48 settlementTime; // per-round oracle timer, in blocks
        uint24 disputeDelay; // delay into per-round oracle timer after which disputes are allowed
        uint24 protocolFee; // proportional cost to dispute in the oracle game, 1000 = 0.01%
        uint16 multiplier; // amount oracle game escalates each round, 140 = 1.4x
        uint48 startFulfillFeeIncrease; // override; expected = 0; contract sets to block.number before hashing
        uint24 maxFee; // 1000 = 0.01%, max fulfillment fee you can pay
        uint24 startingFee; // 1000 = 0.01%, starting fee level
        uint24 roundLength; // round length in blocks
        uint16 growthRate; // 15000 = 1.5x per round
        uint16 maxRounds; // max rounds of increase
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
    event SlippageBailout(uint256 swapId);
    event MaxGameTimeBailout(uint256 swapId);

    /**
     * @notice Creates a swap, routing sellAmt of sellToken into openOracle's internal accounting
     *         for openSwap (via Permit2, oracle.deposit, or oracle.internalTransferFrom).
     * @dev Only the swap hash is stored on-chain. All future callers (matchSwap, cancelSwap, execute,
     *      bailOut) must supply the exact ProposedSwap / MatcherPreimage / MatchedSwap that
     *      reconstructs the current swap hash; off-chain indexing is the caller's responsibility.
     * @param s ProposedSwap parameters; s.swapper is set to msg.sender and s.expiration is converted to an absolute timestamp by the contract
     * @param m MatcherPreimage parameters; m.startFulfillFeeIncrease is set to block.number by the contract
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
        if (expiration == 0 || expiration > MAX_EXPIRATION) revert Errors.InvalidExpiration();
        if (m.maxFee >= 1e7) revert Errors.InvalidFulfillFee();

        if (
            s.priceTolerated == 0 || s.toleranceRange == 0
                || s.toleranceRange > 1e7
        ) revert Errors.InvalidSlippage();

        if (
            m.settlementTime < MIN_SETTLEMENT_TIME || m.initialLiquidity == 0
                || m.disputeDelay >= m.settlementTime || m.escalationHalt < m.initialLiquidity
                || m.settlementTime > MAX_SETTLEMENT_TIME || m.protocolFee >= 1e7
                || s.maxGameTime < m.settlementTime * MIN_GAME_TIME_MULTIPLE
                || s.maxGameTime > MAX_GAME_TIME || m.multiplier < 100 || m.multiplier > MAX_MULTIPLIER
        ) revert Errors.InvalidOracleParams();

        if (
            m.maxFee == 0 || m.startingFee == 0 || m.growthRate < 10000 || m.maxRounds == 0
                || m.maxRounds > MAX_FEE_ROUNDS || m.roundLength == 0 || m.maxFee < m.startingFee
        ) revert Errors.InvalidFulfillFeeParams();

        if (s.swapper != address(0) || m.startFulfillFeeIncrease != 0) revert Errors.MustBeZero();

        uint256 upperPrice =
            Math.mulDiv(s.priceTolerated, uint256(1e7) + s.toleranceRange, 1e7);
        uint256 worstFulfillAmt = Math.mulDiv(sellAmt, 1e30, upperPrice + 1);
        worstFulfillAmt -= Math.mulDiv(worstFulfillAmt, m.maxFee, 1e7);

        if (minOut > worstFulfillAmt) revert Errors.MinOutInconsistent();

        swapId = nextSwapId++;

        // Two hashes share one buffer. swapHash layout matches abi.encode(ProposedSwap, MatcherPreimage):
        //   0x000..0x1A0 ProposedSwap (13 slots) · 0x1A0..0x320 MatcherPreimage (12 slots)
        // permitIntent temporarily appends minOut at 0x320 and hashes 0x340 bytes.
        // Overrides (slot N at N*0x20): 0x0E0 s.swapper←caller · 0x140 s.expiration←absolute · 0x260 m.startFulfillFeeIncrease←block
        // permitIntent skips the expiration and startFulfillFeeIncrease overrides so the user signs runtime-independent inputs.
        uint256 absoluteExpiration = uint256(block.timestamp) + uint256(s.expiration);
        bytes32 swapHash;
        bytes32 permitIntent;
        uint256 stagedMem;
        assembly ("memory-safe") {
            let mem := mload(0x40)
            calldatacopy(mem, s, 0x1A0)
            calldatacopy(add(mem, 0x1A0), m, 0x180)
            mstore(add(mem, 0xE0), caller()) // swapper override

            if needsPermit2 {
                mstore(add(mem, 0x320), minOut)
                permitIntent := keccak256(mem, 0x340)
            }

            // swapHash with full overrides
            mstore(add(mem, 0x140), absoluteExpiration) // expiration → absolute
            mstore(add(mem, 0x260), number()) // startFulfillFeeIncrease
            swapHash := keccak256(mem, 0x320)
            stagedMem := mem
            mstore(0x40, add(mem, 0x340))
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
            calldatacopy(stagedMem, _swap, 0x1a0)
            calldatacopy(add(stagedMem, 0x1a0), preimage, 0x180)
            passedHash := keccak256(stagedMem, 0x320)
            mstore(0x40, add(stagedMem, 0x320))
        }

        if (passedHash != swaps[swapId]) revert Errors.WrongHash();

        MatchedSwap memory s;

        s.sellAmt = _swap.sellAmt;
        s.minFulfillLiquidity = _swap.minFulfillLiquidity;
        s.maxGameTime = _swap.maxGameTime;
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
        s.start = uint48(block.number);
        s.fulfillmentFee = fulfillmentFee;

        if (matcherGasComp > 0) tempHolding[matcher] += matcherGasComp;

        if (preimage.protocolFee > 0) {
            s.feeRecipient = _predictFeeReceiver(swapId, sellToken, buyToken, s.swapper, matcher);
        }
        uint128 currentId = uint128(oracle.nextReportId());
        s.reportId = currentId;

        uint256 matchedMem;
        bytes32 matchedHash;
        assembly ("memory-safe") {
            matchedMem := s
            matchedHash := keccak256(matchedMem, 0x1e0)
        }
        swaps[swapId] = matchedHash;

        uint256 returnedId = oracleGame(s, preimage, timing, amount2, matcher, settlerReward);
        if (returnedId != currentId) revert Errors.InvalidID();

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
            if (swapperPiece + settlerReward > 0) tempHolding[swapper] += swapperPiece + settlerReward;
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
            flags: 32 // fees only at halt. block number mode for oracle timer.
        });

        reportId = oracle.report{value: settlerReward}(params, true, true, timing);
    }

    /**
     * @notice Lets users bail out of a swapId.
     *            Anyone-can-call. Caller earns executor gas compensation.
     *            One bail out condition:
     *                 last report block + settlementTime − match block > maxGameTime  → swapper and matcher are refunded initial token deposits
     * @param swapId Unique identifier of swapping instance
     * @param _swap MatchedSwap committed at matchSwap
     * @param oracleState Oracle game state matching the stored oracle hash
     * @param oracleHelper Oracle preimage helper matching the stored oracle hash
     */
    function bailOut(uint256 swapId, MatchedSwap calldata _swap, IOpenOracle2.OracleGame calldata oracleState, IOpenOracle2.PreimageHelper calldata oracleHelper) external nonReentrant {
        bytes32 passedHash = keccak256(abi.encode(_swap));
        if (passedHash != swaps[swapId]) revert Errors.WrongHash();

        MatchedSwap memory s = _swap;

        if (keccak256(abi.encode(oracleState, oracleHelper)) != oracle.oracleGame(s.reportId)) {
            revert Errors.WrongOracleHash();
        }

        if (s.matcher == address(0)) revert Errors.NotMatched();
        if (s.swapper == address(0)) revert Errors.NotActive();

        uint256 elapsed = oracleState.settlementTime + uint256(oracleState.reportTimestamp) - s.start;
        bool isGameTooLong = elapsed > s.maxGameTime;

        if (isGameTooLong) {
            delete swaps[swapId];
            if (s.executorGasComp > 0) tempHolding[msg.sender] += s.executorGasComp;
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
        bool ok;
        assembly ("memory-safe") {
            ok := call(ETH_SEND_GAS, _to, _amount, 0, 0, 0, 0)
        }
        if (!ok) tempHolding[_to] += _amount;
    }

    /**
     * @notice Settles the oracle report if not already settled, then delivers buyToken to
     *         swapper and sellToken to matcher (or refunds on slippage bailout / oracle game too long).
     * @param swapId Unique identifier of swapping instance
     * @param swapState MatchedSwap committed at matchSwap
     * @param oracleState Oracle game state matching the stored oracle hash
     * @param oracleHelper Oracle preimage helper matching the stored oracle hash
     * @param settlementSearchDepth Number of candidate settlement blocks to try, beginning
     *                              with the current block; zero disables stale-settlement recovery.
     */
    function execute(
        uint256 swapId,
        MatchedSwap calldata swapState,
        IOpenOracle2.OracleGame calldata oracleState,
        IOpenOracle2.PreimageHelper calldata oracleHelper,
        uint8 settlementSearchDepth
    ) external {
        MatchedSwap memory s;
        bytes32 passedSwapHash;

        assembly ("memory-safe") {
            let mem := mload(0x40)
            calldatacopy(mem, swapState, 0x1e0)
            passedSwapHash := keccak256(mem, 0x1e0)
            s := mem
            mstore(0x40, add(mem, 0x1e0))
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

        // Recover when settlement changed only settlementTimestamp after the caller built its preimage.
        if (!matches && oracleState.settlementTimestamp == 0 && settlementSearchDepth != 0) {
            uint256 currentBlock = block.number;
            for (uint256 i; i < settlementSearchDepth; ++i) {
                uint256 candidate = currentBlock - i;
                assembly ("memory-safe") {
                    mstore(add(oracleMem, 0x80), candidate) // OracleGame word 4 = settlementTimestamp
                    passedHash := keccak256(oracleMem, 0x300)
                }
                if (passedHash == oracleHash) {
                    matches = true;
                    alreadySettled = true;
                    break;
                }
            }
        }

        if (!matches) revert Errors.WrongOracleHash();

        if (uint48(block.number) < oracleState.reportTimestamp + oracleState.settlementTime) {
            revert Errors.OracleSettlementNotEligible();
        }

        delete swaps[swapId];
        uint96 executorGasComp = s.executorGasComp;
        uint96 settlerReward = oracleState.settlerReward;

        if (executorGasComp > 0) tempHolding[msg.sender] += executorGasComp;

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
        uint128 minFulfillLiquidity = s.minFulfillLiquidity;
        uint128 sellAmt = s.sellAmt;
        uint24 fulfillmentFee = s.fulfillmentFee;
        uint128 oracleAmount1 = oracleState.currentAmount1;
        uint128 oracleAmount2 = oracleState.currentAmount2;

        uint256 price = Math.mulDiv(oracleAmount1, 1e30, oracleAmount2);
        uint256 fulfillAmt = Math.mulDiv(sellAmt, oracleAmount2, oracleAmount1);
        fulfillAmt -= Math.mulDiv(fulfillAmt, fulfillmentFee, 1e7);

        bool slippageOk = toleranceCheck(price, s.priceTolerated, s.toleranceRange);
        bool slippageBailout = fulfillAmt > minFulfillLiquidity || !slippageOk;
        bool maxGameTimePassed =
            oracleState.settlementTime + uint256(oracleState.reportTimestamp) - s.start > s.maxGameTime;

        bool shouldRefund = slippageBailout || maxGameTimePassed;

        if (slippageBailout) emit SlippageBailout(swapId);
        if (maxGameTimePassed) emit MaxGameTimeBailout(swapId);

        if (shouldRefund) {
            refund(sellToken, sellAmt, swapper, buyToken, minFulfillLiquidity, matcher, s.useInternalBalances);
            emit SwapRefunded(swapId, swapper, matcher);
        } else {
            oracle.internalTransferFrom(address(this), matcher, sellToken, sellAmt);
            oracle.internalTransferFrom(address(this), matcher, buyToken, uint128(minFulfillLiquidity - fulfillAmt));
            if (s.useInternalBalances) {
                oracle.internalTransferFrom(address(this), swapper, buyToken, uint128(fulfillAmt));
            } else {
                oracle.pushOrCredit(buyToken, swapper, uint128(fulfillAmt));
            }
            emit SwapExecuted(swapId);
        }
    }

    /**
     * @notice Deploys a swap's fee receiver if needed, then distributes its accrued oracle fees.
     * @dev CREATE2 binds the receiver address to all five immutable arguments.
     *              Deployment is permissionless and may occur before fees accrue; an empty distribution
     *              is a no-op.
     * @param swapId Swap identifier used as the deterministic deployment salt.
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

        (fees1, fees2) = oracleFeeReceiver(feeReceiver).distribute();
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
        oracle.internalTransferFrom(address(this), matcher, buyToken, buyAmt);
        if (useInternalBalances) {
            oracle.internalTransferFrom(address(this), swapper, sellToken, sellAmt);
        } else {
            oracle.pushOrCredit(sellToken, swapper, sellAmt);
        }
    }

    function calcFee(
        uint256 maxFee,
        uint256 startingFee,
        uint256 growthRate,
        uint256 maxRounds,
        uint256 startFulfillFeeIncrease,
        uint256 roundLength
    ) internal view returns (uint256) {
        uint256 timeDelta = block.number - startFulfillFeeIncrease;

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

    /// @dev Predicts the swap's counterfactual fee receiver. The clone is deployed lazily by
    ///      `deployAndDistributeFeeReceiver`; distributing an empty receiver is a no-op.
    function _predictFeeReceiver(
        uint256 swapId,
        address token1,
        address token2,
        address swapper,
        address matcher
    ) internal view returns (address) {
        bytes memory args = abi.encodePacked(swapId, token1, token2, swapper, matcher);
        return LibClone.predictDeterministicAddress(feeReceiverImpl, args, bytes32(swapId), address(this));
    }

    /**
     * @dev Packs committed OpenSwap preimages in place for raw-log event emission.
     *      kind == 1: input is abi.encode(ProposedSwap, MatcherPreimage), 0x320 bytes.
     *                 output is 235 raw bytes.
     *      kind == 2: input is abi.encode(MatchedSwap), 0x1e0 bytes.
     *                 output is 205 raw bytes.
     */
    function _packMem(uint256 mem, uint8 kind) internal pure returns (uint256 packedLen) {
        assembly ("memory-safe") {
            switch kind
            case 1 {
                // ProposedSwap (13 slots -> 170 bytes)
                mstore(mem,             shl(128, mload(mem)))                 // sellAmt              (W=16)
                mstore(add(mem,  16),   shl(128, mload(add(mem, 0x20))))      // minFulfillLiquidity  (W=16)
                mstore(add(mem,  32),   shl(160, mload(add(mem, 0x40))))      // settlerReward        (W=12)
                mstore(add(mem,  44),   shl(232, mload(add(mem, 0x60))))      // maxGameTime          (W=3)
                mstore(add(mem,  47),   shl( 96, mload(add(mem, 0x80))))      // buyToken             (W=20)
                mstore(add(mem,  67),   shl(160, mload(add(mem, 0xa0))))      // matcherGasComp       (W=12)
                mstore(add(mem,  79),   shl( 96, mload(add(mem, 0xc0))))      // sellToken            (W=20)
                mstore(add(mem,  99),   shl( 96, mload(add(mem, 0xe0))))      // swapper              (W=20)
                mstore(add(mem, 119),   shl(160, mload(add(mem, 0x100))))     // executorGasComp      (W=12)
                mstore8(add(mem, 131),  byte(31, mload(add(mem, 0x120))))     // useInternalBalances  (W=1)
                mstore(add(mem, 132),   shl(208, mload(add(mem, 0x140))))     // expiration           (W=6)
                mstore(add(mem, 138),   shl( 24, mload(add(mem, 0x160))))     // priceTolerated       (W=29)
                mstore(add(mem, 167),   shl(232, mload(add(mem, 0x180))))     // toleranceRange       (W=3)

                // MatcherPreimage starts at source 0x1a0 (12 slots -> 65 bytes)
                mstore(add(mem, 170),   shl(128, mload(add(mem, 0x1a0))))     // initialLiquidity     (W=16)
                mstore(add(mem, 186),   shl(128, mload(add(mem, 0x1c0))))     // escalationHalt       (W=16)
                mstore(add(mem, 202),   shl(208, mload(add(mem, 0x1e0))))     // settlementTime       (W=6)
                mstore(add(mem, 208),   shl(232, mload(add(mem, 0x200))))     // disputeDelay         (W=3)
                mstore(add(mem, 211),   shl(232, mload(add(mem, 0x220))))     // protocolFee          (W=3)
                mstore(add(mem, 214),   shl(240, mload(add(mem, 0x240))))     // multiplier           (W=2)
                mstore(add(mem, 216),   shl(208, mload(add(mem, 0x260))))     // startFulfillFeeIncrease (W=6)
                mstore(add(mem, 222),   shl(232, mload(add(mem, 0x280))))     // maxFee               (W=3)
                mstore(add(mem, 225),   shl(232, mload(add(mem, 0x2a0))))     // startingFee          (W=3)
                mstore(add(mem, 228),   shl(232, mload(add(mem, 0x2c0))))     // roundLength          (W=3)
                mstore(add(mem, 231),   shl(240, mload(add(mem, 0x2e0))))     // growthRate           (W=2)
                mstore(add(mem, 233),   shl(240, mload(add(mem, 0x300))))     // maxRounds            (W=2)

                packedLen := 235
            }
            case 2 {
                // MatchedSwap (15 slots -> 205 bytes)
                mstore(mem,             shl(128, mload(mem)))                 // sellAmt              (W=16)
                mstore(add(mem,  16),   shl(128, mload(add(mem, 0x20))))      // minFulfillLiquidity  (W=16)
                mstore(add(mem,  32),   shl(232, mload(add(mem, 0x40))))      // maxGameTime          (W=3)
                mstore(add(mem,  35),   shl( 96, mload(add(mem, 0x60))))      // buyToken             (W=20)
                mstore(add(mem,  55),   shl( 96, mload(add(mem, 0x80))))      // sellToken            (W=20)
                mstore(add(mem,  75),   shl( 96, mload(add(mem, 0xa0))))      // swapper              (W=20)
                mstore(add(mem,  95),   shl(160, mload(add(mem, 0xc0))))      // executorGasComp      (W=12)
                mstore8(add(mem, 107),  byte(31, mload(add(mem, 0xe0))))      // useInternalBalances  (W=1)
                mstore(add(mem, 108),   shl(128, mload(add(mem, 0x100))))     // reportId             (W=16)
                mstore(add(mem, 124),   shl( 96, mload(add(mem, 0x120))))     // matcher              (W=20)
                mstore(add(mem, 144),   shl(208, mload(add(mem, 0x140))))     // start                (W=6)
                mstore(add(mem, 150),   shl(232, mload(add(mem, 0x160))))     // fulfillmentFee       (W=3)
                mstore(add(mem, 153),   shl( 96, mload(add(mem, 0x180))))     // feeRecipient         (W=20)
                mstore(add(mem, 173),   shl( 24, mload(add(mem, 0x1a0))))     // priceTolerated       (W=29)
                mstore(add(mem, 202),   shl(232, mload(add(mem, 0x1c0))))     // toleranceRange       (W=3)

                packedLen := 205
            }
        }
    }
}
