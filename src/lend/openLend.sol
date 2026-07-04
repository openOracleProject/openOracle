// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {oracleFeeReceiver} from "./openLendFeeReceiver.sol";
import {LendErrors} from "../libraries/LendErrors.sol";

/**
 * @title openLend
 * @notice Permissionless overcollateralized lending protocol with Dutch auction rate discovery and openOracle liquidations.
 * @dev    Lifecycle:
 *           1. Borrower calls `requestBorrow` to lock collateral and open a rising interest rate curve.
 *           2. Any lender calls `lend` to accept the current rate on the curve, originating the loan.
 *           3. Borrower may `repayDebt` (partial or full), `topUpCollateral`, or `refinance` (re-opens curve for a new lender).
 *           4. Anyone may call `liquidate` once they deem the position sufficiently underwater, which spins up
 *              an openOracle price report. Once the report can no longer be disputed, `finalize` resolves the
 *              liquidation. The lender picks `liquidatorFraction` at lend-time to set how much of any equity
 *              buffer routes to the liquidator vs themselves.
 *           5. After maturity plus any grace period, lender calls `claimCollateral` if the loan was not repaid or refinanced.
 *
 *         Rate discovery: `calcRate` evaluates a piecewise exponential curve (`startingRate * growthRate^rounds`) keyed on
 *         `requestStart`, capped at `maxRate`. Lenders compete by being the first to call `lend` at an acceptable rate.
 *
 *         Uses openOracle (https://docs.openoracle.org) for liquidation price discovery.
 *
 *         Supported tokens: vanilla ERC20 and USDT-style tokens (non-bool return on transfer/transferFrom) only.
 *         Rebasing tokens, fee-on-transfer / tax tokens, and any token whose post-transfer balance does not equal
 *         the requested amount are not supported and will break accounting in the isolated lending arrangement.
 *         Tokens with total supply at or above 6,805,647,338,418,769,269,267,492,148,635,364,229
 *         raw units (2% of `type(uint128).max`) are not supported.
 *
 */
contract openLend is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IOpenOracle2 public immutable oracle;
    address public immutable feeReceiverImpl;
    address public immutable WETH;
    address internal constant ETH_SENTINEL = address(0);
    uint256 internal constant ACCRUAL_DENOM = 1e9 * 365 days;

    uint256 public nextLendingId = 1;
    mapping(uint256 => LendingArrangement) public lendingArrangements;
    /// @dev lendingId → active oracle reportId. Set in liquidate, cleared in finalize.
    mapping(uint256 => uint256) public lendingToReportId;
    mapping(address => mapping(address => uint256)) public tempHolding;
    mapping(address => bool) private _oracleApproved;
    mapping(uint256 => address) public refiDelegation;
    mapping(uint256 => address) public lenderDelegation;

    constructor(IOpenOracle2 _oracle, address _WETH) {
        oracle = _oracle;
        feeReceiverImpl = address(new oracleFeeReceiver(_oracle));
        WETH = _WETH;
    }

    receive() external payable {}

    modifier autoSettle(uint256 lendingId) {
        _finalizeHelper(lendingId);
        _;
    }

    /// @notice Full state of a single lending arrangement. Stored at `lendingArrangements[lendingId]`.
    struct LendingArrangement {
        uint128 supplyAmount; // amount supplied as collateral
        uint128 principal; // outstanding principal balance
        uint128 interestAccrued; // cumulative interest from start to lastTouch
        uint56 interestRemainder; // numerator remainder modulo ACCRUAL_DENOM for fractional interest accrual
        uint48 lastTouch; // time of last interestAccrued update
        uint24 liquidatorFraction; // 1e7 = 100%. how much the liquidator earns of position equity versus the lender.
        uint128 interestPaid; // cumulative payments attributed to interest
        uint128 commitmentInterest; // minimum interest paid by borrower to lender
        address borrower; // borrower address
        uint48 term; // length of loan in seconds
        uint48 start; // timestamp loan began
        address lender; // lender address
        uint96 gasCompensation; // ETH paid to the recorded lender on accept, or refunded to borrower if the curve is cleared before accept
        address liquidator; // liquidator address
        uint48 liquidationStart; // timestamp where the liquidation started
        uint48 gracePeriod; // extra time to repay debt / accept refinance offer if liquidation oracle game runs past maturity
        address supplyToken; // supply token
        uint48 requestStart; // anchor for the rate curve. Set when a borrow request or non-liq refi opens; parked at 0 while a refi is open during a live liquidation, then set to the report's settleable-at time when an unsuccessful liquidation finalizes.
        uint24 liquidationThreshold; // 8e6 = 80%. when residual debt (incl. commitment floor) priced in supplyToken > liquidationThreshold * supplyAmount, liquidation is possible
        uint24 commitmentFraction; // 1e7 = 100% locked yield (full term), 0 = pure prorated; intermediates define a flex window before maturity
        address borrowToken; // borrow token
        uint32 rate; // 1e8 = 10%, annual interest rate
        uint16 stake; // 100 = 1%. stake * supplyAmount is how much the liquidation caller must wager on oracle resolution.
        bool cancelled; // borrow request cancelled by borrower
        bool active; // offer accepted and loan is live
        bool inLiquidation; // loan is in liquidation (oracle game is running)
        bool finished; // loan has been liquidated or repaid
        bool curveOpen; // interest rate curve open
        RefiParams refiParams; // parameters for borrower's next refinance
        OracleParams oracleParams; // parameters for oracle game
        InterestRateParams interestRateParams; // interest rate parameters
    }

    /// @notice Parameters for the rising interest rate curve evaluated by `calcRate`.
    /// @dev    Rate at round k is `min(maxRate, startingRate * (growthRate/10000)^k)`.
    ///         Rates are 1e9-scaled APR; the type caps `maxRate` at ≈4.29e9 (~429% APR).
    ///         Curve is keyed on `requestStart`. `requestStart` is set when a borrow request opens or when a refi
    ///         opens outside liquidation; a refi opened mid-liquidation leaves `requestStart` at zero until an
    ///         unsuccessful liquidation is finalized, at which point it is set to the report's settleable-at time.
    struct InterestRateParams {
        uint32 maxRate; // 1e8 = 10% APR. Hard ceiling on rate. Capped at uint32 max ≈ 4.29e9 (~429% APR).
        uint32 startingRate; // 1e8 = 10% APR. Rate at round 0 (`requestStart`).
        uint24 roundLength; // seconds per round. Larger = slower curve.
        uint16 growthRate; // 10500 = 1.05x per round. Must be > 10000.
        uint16 maxRounds; // hard cap on rounds (also caps loop gas in `calcRate`).
    }

    /// @notice Pending refinance terms set through `refinance`. Applied during `lend` refi branch.
    struct RefiParams {
        uint128 extraDemanded; // additional borrowToken pulled to borrower on refi (on top of rolling the prior debt).
        uint128 supplyPulled; // supplyToken returned to borrower on refi (must be < current supplyAmount).
        uint48 newTerm; // term for the post-refi loan. Borrower may extend or shorten via this field.
        OracleParams oracleParams;
    }

    /// @notice Parameters governing the openOracle game spawned at liquidation time.
    struct OracleParams {
        uint48 settlementTime; // openOracle settlement window in seconds (bounded [120, 14400]).
        uint24 disputeDelay; // openOracle dispute delay; must be < settlementTime.
        uint24 oracleGameFee; // protocol fee on the oracle game, 1e7 = 100%; routed to a feeRecipient clone.
        uint16 escalationFactor; // escalationHalt = supplyAmount * escalationFactor / 100. Bounded [10, 5000].
        uint8 initialLiquidity; // initial token1 in the oracle report = supplyAmount * initialLiquidity / 100. Bounded [5, 250].
        uint16 multiplier; // openOracle per-round dispute multiplier, e.g. 140 = 1.4x. Bounded [100, 1000].
        uint48 maxBaseFee; // maximum base fee, relative to initial liquidity, where a liquidation finalizes against the borrower
        uint64 finalizerReward; // fixed ETH finalizer reward the liquidator attaches at liquidate, paid to whoever finalizes
    }

    event BorrowRequested(
        address indexed borrower,
        uint256 indexed lendingId,
        address supplyToken,
        address borrowToken,
        uint128 supplyAmount,
        uint128 amountDemanded,
        uint48 term,
        uint24 liquidationThreshold,
        uint16 stake,
        uint24 commitmentFraction,
        uint96 gasCompensation,
        OracleParams oracleParams,
        InterestRateParams interestRateParams
    );

    event BorrowRequestCancelled(address indexed borrower, uint256 indexed lendingId);
    event LoanOriginated(
        uint256 indexed lendingId,
        address indexed lender,
        uint256 principal,
        uint256 rate,
        uint48 start,
        uint48 term,
        uint96 gasCompensation,
        uint24 liquidatorFraction
    );
    event LoanRefinanced(
        uint256 indexed lendingId,
        address indexed newLender,
        address indexed prevLender,
        uint256 principal,
        uint256 owedToPrevLender,
        uint256 rate,
        uint48 start,
        uint48 term,
        uint128 extraDemanded,
        uint128 supplyPulled,
        uint96 gasCompensation,
        uint24 liquidatorFraction,
        bool netted
    );
    event LoanLiquidationUnderway(
        uint256 indexed lendingId,
        address indexed lender,
        address indexed liquidator,
        uint256 reportId,
        address feeRecipient,
        address borrower
    );
    event DebtRepaid(uint256 indexed lendingId, address indexed payer, uint256 amount, bool fullyRepaid);
    event CollateralToppedOff(uint256 indexed lendingId, address indexed payer, uint256 amount);
    event CollateralClaimedByLender(uint256 indexed lendingId, uint256 supplyTokenClaimed);
    event RefiOpened(
        uint256 indexed lendingId,
        uint128 extraDemanded,
        uint128 supplyPulled,
        uint48 newTerm,
        uint96 gasCompensation,
        OracleParams oracleParams,
        InterestRateParams interestRateParams
    );
    event RefiOpenedDuringLiquidation(
        uint256 indexed lendingId,
        uint128 extraDemanded,
        uint128 supplyPulled,
        uint48 newTerm,
        uint96 gasCompensation,
        OracleParams oracleParams,
        InterestRateParams interestRateParams
    );
    event RefiCancelled(uint256 indexed lendingId);
    event LiqFinishedUnderwater(uint256 indexed lendingId);
    event LiqFinishedWithBuffer(uint256 indexed lendingId);
    event LiqUnsuccessful(uint256 indexed lendingId);
    event BountyPaid(uint256 indexed lendingId, address indexed finalizer, uint256 bounty);
    event TempHoldingWithdrawn(address indexed user, address indexed token, uint256 amount);
    event RefiDelegateSet(uint256 indexed lendingId, address delegate);
    event LenderDelegateSet(uint256 indexed lendingId, address delegate);

    // -------------------------------------------------------------------------
    //                              External functions
    // -------------------------------------------------------------------------

    /**
     * @notice Opens a new borrow request for `borrower`: locks `supplyAmount` of `supplyToken` and starts a Dutch-auction rate curve.
     * @dev    Funds are pulled from `msg.sender`, while `borrower` is written as the loan borrower. Lenders accept
     *         by calling `lend`; the rate they pay is `calcRate` evaluated at `block.timestamp`. Until accepted,
     *         the borrower may call `cancelBorrowRequest` to recover collateral.
     * @param  term Loan duration in seconds, bounded [1800, 1 year]. Measured from the moment a lender calls `lend`.
     * @param  supplyToken Address of the ERC20 supplied as collateral. Must differ from `borrowToken`.
     * @param  borrowToken Address of the ERC20 the borrower wants to borrow.
     * @param  liquidationThreshold Fraction in 1e7 fixed-point (8e6 = 80%). Liquidation becomes possible when
     *                              `borrowValue > liquidationThreshold * supplyAmount`. Bounded [3e6, 1e7].
     * @param  supplyAmount Collateral amount transferred from `msg.sender` into the contract on this call.
     * @param  amountDemanded Borrow amount requested. Pulled from `msg.sender` to the borrower at `lend` time.
     * @param  stake Liquidator stake fraction in 10000 fixed-point (100 = 1%). The liquidation caller wagers
     *               `stake * supplyAmount / 10000` of supplyToken on the liquidation succeeding.
     * @param  commitmentFraction 1e7 fixed-point. Close-out interest = `max(commitmentFraction × fullInterest / 1e7,
     *                            accruedInterest)`. Immutable for the loan's life.
     * @param  gasCompensation ETH escrowed to pay the lender who accepts this curve. `msg.value` must equal this
     *                         amount, plus `supplyAmount` when `supplyToken` is native ETH. Refunded to the borrower
     *                         if the request is cancelled or the loan terminates with the curve still open.
     * @param  borrower Address recorded as borrower. Collateral is still funded by `msg.sender`.
     * @param  refiDelegate Optional contract authorized to call `refinance` on the borrower's behalf.
     *                      Pass address(0) for none. Changeable/revocable later by the borrower via `setRefiDelegate`.
     * @param  oracleParams Oracle game configuration applied to any future liquidation of this loan.
     * @param  interestRateParams Curve parameters (start, growth, max) for rate discovery.
     * @return lendingId Unique identifier for the new lending arrangement, used by all subsequent calls.
     */
    function requestBorrow(
        uint48 term,
        address supplyToken,
        address borrowToken,
        uint24 liquidationThreshold,
        uint128 supplyAmount,
        uint128 amountDemanded,
        uint16 stake,
        uint24 commitmentFraction,
        uint96 gasCompensation,
        address borrower,
        address refiDelegate,
        OracleParams calldata oracleParams,
        InterestRateParams calldata interestRateParams
    ) external payable nonReentrant returns (uint256 lendingId) {
        uint256 currentTime = uint48(block.timestamp);

        uint256 ethRequired = supplyToken == ETH_SENTINEL ? supplyAmount + gasCompensation : gasCompensation;

        if (borrower == address(0)) revert LendErrors.AddressCannotBeZero();
        if (supplyToken == borrowToken) revert LendErrors.SupplyEqualsBorrow();
        if (liquidationThreshold > 1e7 || liquidationThreshold < 3e6) {
            revert LendErrors.LiquidationThresholdOutOfBounds();
        }
        if (stake > 10000) revert LendErrors.StakeTooHigh();
        if (amountDemanded == 0) revert LendErrors.ZeroAmount();
        if (supplyAmount == 0) revert LendErrors.ZeroAmount();
        if (term < 1800 || term > 60 * 60 * 24 * 365) revert LendErrors.TermOutOfBounds();
        if (supplyAmount + uint256(supplyAmount) * stake / 10000 > type(uint128).max) {
            revert LendErrors.SupplyPlusStakeTooHigh();
        }
        if (msg.value != ethRequired) revert LendErrors.MsgValue();
        if (commitmentFraction > 1e7) revert LendErrors.CommitmentFractionTooHigh();
        if (
            uint256(amountDemanded) * (uint256(1e9) * 365 days + uint256(term) * interestRateParams.maxRate)
                > type(uint128).max * uint256(1e9) * 365 days
        ) {
            revert LendErrors.ResidualOverflow();
        }

        _validateOracleParams(oracleParams, supplyAmount);
        _validateInterestRateParams(interestRateParams);

        lendingId = nextLendingId++;
        LendingArrangement storage lending = lendingArrangements[lendingId];

        lending.term = term;
        lending.supplyToken = supplyToken;
        lending.borrowToken = borrowToken;
        lending.supplyAmount = supplyAmount;
        lending.liquidationThreshold = liquidationThreshold;
        lending.principal = amountDemanded;
        lending.stake = stake;
        lending.borrower = borrower;
        lending.oracleParams = oracleParams;
        lending.requestStart = uint48(currentTime);
        lending.interestRateParams = interestRateParams;
        lending.curveOpen = true;
        lending.commitmentFraction = commitmentFraction;
        lending.gasCompensation = gasCompensation;
        refiDelegation[lendingId] = refiDelegate;
        if (refiDelegate != address(0)) emit RefiDelegateSet(lendingId, refiDelegate);

        if (supplyToken != ETH_SENTINEL) _pullToken(supplyToken, msg.sender, address(this), supplyAmount);

        emit BorrowRequested(
            borrower,
            lendingId,
            supplyToken,
            borrowToken,
            supplyAmount,
            amountDemanded,
            term,
            liquidationThreshold,
            stake,
            commitmentFraction,
            gasCompensation,
            oracleParams,
            interestRateParams
        );
        return lendingId;
    }

    /**
     * @notice Cancels an unaccepted borrow request and returns the collateral to the borrower.
     * @dev    Only the borrower can call, and only before any lender has accepted. Marks the arrangement
     *         cancelled, which permanently disables every other entrypoint on this lendingId.
     * @param  lendingId Unique identifier returned from `requestBorrow`.
     */
    function cancelBorrowRequest(uint256 lendingId) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        address borrower = lending.borrower;

        if (lending.cancelled) revert LendErrors.Cancelled();
        if (lending.finished) revert LendErrors.Finished();
        if (lending.active) revert LendErrors.LendingIdActive();
        if (borrower != msg.sender) revert LendErrors.MsgSender();

        address supplyToken = lending.supplyToken;
        uint128 supplyAmount = lending.supplyAmount;

        lending.cancelled = true;
        _clearRefiCurve(lending);

        _sendGasComp(lending);
        _transferTokens(supplyToken, address(this), borrower, supplyAmount);

        emit BorrowRequestCancelled(borrower, lendingId);
    }

    /**
     * @notice Accepts the current rate on the borrow / refi curve for `lender`.
     * @dev    Funds are pulled from `msg.sender`, while `lender` is written as the loan lender and receives any
     *         gas compensation. Carries the `autoSettle` modifier, so a settleable pending liquidation is resolved before the body
     *         runs; if the resolution is unsuccessful the loan exits liquidation and lend can proceed against
     *         the post-settle state, including any virtual `requestStart` set to the report's settleable-at
     *         time. On origination, `msg.sender` funds the borrower with `amountDemanded` of borrowToken and the
     *         loan goes active. On refinance, `msg.sender` funds the new borrow amount: normally this pays off
     *         the previous lender (the close-out debt at the old rate/term/start, less anything already streamed
     *         back), funds any extra borrow the borrower requested, and returns any pulled collateral. If the
     *         recorded lender is unchanged and the call is made by that lender or its lender delegate, the prior
     *         debt is netted and only any extra borrow must be funded. Per-loan state from the prior round
     *         (interestAccrued, interestPaid, gracePeriod, liquidator scratch fields) is reset, and the new term, rate, and start
     *         are taken from the refi params and the current block. The rate paid is whatever `calcRate`
     *         returns against `requestStart` at the current block. Reverts if the arrangement is cancelled,
     *         finished, still in liquidation after auto-settle, has no open curve, or (on the refi branch) is
     *         past maturity plus grace.
     *
     *         Guard semantics: `expectedMinSupply` is checked against the live collateral balance before this
     *         accept call applies any staged refi collateral pull. It is not a post-refi collateral floor.
     *         `paramHashExpected` is the guard that pins the staged refi terms, including `supplyPulled`.
     *
     *         On refinance, any msg.value above the required amount is refunded to `lender` (the lender of
     *         record), not `msg.sender`. A caller funding a refinance on behalf of a different lender must
     *         send exact value.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  paramHashExpected Loose paramHash over loan configuration and staged refi terms.
     *         Use hash to pin `refiParams.supplyPulled`, `extraDemanded`, new term,
     *         and related params.
     * @param  minLendAmount Refi-only floor on the new principal. Set to 0 on origination (ignored).
     * @param  maxLendAmount Refi-only ceiling on the new principal. Set to type(uint128).max on origination (ignored).
     * @param  expectedMinSupply Reverts if pre-accept `supplyAmount < expectedMinSupply`. On refinance, post-accept
     *         supply can be lower if the borrower staged `supplyPulled > 0`; use `paramHashExpected` to reject an
     *         unexpected collateral pull.
     * @param  minRate Reverts if the computed rate is below this floor. Mandatory: the param hash
     *         does not pin `requestStart`, so this floor is the only guard on the accepted rate.
     * @param  liquidatorFraction Share of any post-settlement equity buffer routed to the liquidator, in 1e7
     *                            fixed-point (0 = lender keeps it all, 1e7 = liquidator keeps it all). Bounded
     *                            [0, 1e7]. Anyone may call `liquidate` regardless of this value; this knob
     *                            only sets the buffer split.
     * @param  lender Address recorded as lender. Borrow funds are still funded by `msg.sender`.
     * @param lenderDelegate Contract address that is allowed to perform netted refinances on your behalf.
     *                       Fully trusted contract. Set to address(0) to skip.
     */
    function lend(
        uint256 lendingId,
        bytes32 paramHashExpected,
        uint128 minLendAmount,
        uint128 maxLendAmount,
        uint128 expectedMinSupply,
        uint32 minRate,
        uint24 liquidatorFraction,
        address lender,
        address lenderDelegate
    ) external payable nonReentrant autoSettle(lendingId) {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 _owedPrev;
        if (lending.active) {
            _touchAmort(lending);
            _owedPrev = _residualDebt(lending);
        }

        uint256 currentTime = block.timestamp;
        address borrower = lending.borrower;
        address borrowToken = lending.borrowToken;
        uint256 rate = calcRate(lending.interestRateParams, lending.requestStart);
        address prevLender = lending.lender;
        uint48 prevTerm = lending.term;
        address prevDelegate = lenderDelegation[lendingId];
        uint256 commitmentFraction = lending.commitmentFraction;
        uint256 gasCompensation = lending.gasCompensation;
        bool isEth = borrowToken == ETH_SENTINEL;
        uint256 ethRequired;

        if (lending.cancelled) revert LendErrors.Cancelled();
        if (lending.finished) revert LendErrors.Finished();
        if (lending.inLiquidation) revert LendErrors.InLiquidation();
        if (!lending.curveOpen) revert LendErrors.CurveIsNotOpen();
        if (lending.supplyAmount < expectedMinSupply) revert LendErrors.MinSupply();
        if (lending.active && currentTime >= uint256(lending.start) + prevTerm + lending.gracePeriod) {
            revert LendErrors.Expired();
        }
        if (rate < minRate) revert LendErrors.MinRate();
        if (liquidatorFraction > 1e7) revert LendErrors.LiquidatorFractionTooHigh();
        if (lender == address(0)) revert LendErrors.AddressCannotBeZero();
        if (!isEth && msg.value > 0) revert LendErrors.MsgValue();

        _checkParamsLoose(lending, paramHashExpected);

        lending.lender = lender;
        lending.rate = uint32(rate);
        lending.start = uint48(currentTime);
        lending.curveOpen = false;
        lending.liquidatorFraction = liquidatorFraction;
        lending.lastTouch = uint48(currentTime);
        lenderDelegation[lendingId] = lenderDelegate;
        if (lenderDelegate != address(0)) emit LenderDelegateSet(lendingId, lenderDelegate);

        if (!lending.active) {
            // origination
            uint256 principal = lending.principal;
            ethRequired = isEth ? principal : 0;
            if (msg.value != ethRequired) revert LendErrors.MsgValue();

            lending.active = true;
            lending.gasCompensation = 0;
            lending.commitmentInterest =
                uint128(principal * prevTerm * commitmentFraction * rate / (1e7 * 1e9 * 365 days));

            _payEth(lender, gasCompensation);
            if (isEth) {
                _payEth(borrower, principal);
            } else {
                _pullToken(borrowToken, msg.sender, borrower, principal);
            }

            emit LoanOriginated(
                lendingId,
                lender,
                principal,
                rate,
                uint48(currentTime),
                prevTerm,
                uint96(gasCompensation),
                liquidatorFraction
            );
        } else {
            // refi

            uint256 stagedSettlementTime = lending.refiParams.oracleParams.settlementTime;
            address supplyToken = lending.supplyToken;
            uint128 extraDemanded = lending.refiParams.extraDemanded;
            uint128 supplyPulled = lending.refiParams.supplyPulled;
            uint48 newTerm = lending.refiParams.newTerm;
            uint256 netTerminalDebtPrev = _owedPrev;
            uint256 newBorrowAmount = netTerminalDebtPrev + extraDemanded;
            bool isNetted = (lender == prevLender && (msg.sender == prevLender || msg.sender == prevDelegate));
            uint256 nettedAmount = isNetted ? netTerminalDebtPrev : 0;
            ethRequired = isEth ? newBorrowAmount - nettedAmount : 0;
            if (msg.value < ethRequired) revert LendErrors.MsgValue();

            if (newBorrowAmount < minLendAmount || newBorrowAmount > maxLendAmount) {
                revert LendErrors.LendAmountOutOfBounds();
            }

            if (stagedSettlementTime != 0) {
                OracleParams memory stagedOracleParams = lending.refiParams.oracleParams;
                uint256 newSupplyAmount = uint256(lending.supplyAmount) - supplyPulled;
                uint256 newEscHalt = newSupplyAmount * stagedOracleParams.escalationFactor / 100;
                if (newEscHalt > type(uint128).max) revert LendErrors.EscalationHaltTooHigh();
                lending.oracleParams = stagedOracleParams;
            }

            if (
                newBorrowAmount * (uint256(1e9) * 365 days + uint256(newTerm) * rate)
                    > type(uint128).max * uint256(1e9) * 365 days
            ) {
                revert LendErrors.ResidualOverflow();
            }

            lending.principal = uint128(newBorrowAmount);
            lending.commitmentInterest =
                uint128(newBorrowAmount * newTerm * commitmentFraction * rate / (1e7 * 1e9 * 365 days));
            lending.gracePeriod = 0;
            lending.liquidator = address(0);
            lending.liquidationStart = 0;
            lending.term = newTerm;
            lending.supplyAmount -= supplyPulled;
            lending.interestAccrued = 0;
            lending.interestRemainder = 0;
            lending.interestPaid = 0;

            lending.gasCompensation = 0;
            _clearRefiCurve(lending);

            _payEth(lender, gasCompensation);

            if (!isEth) {
                _pullToken(borrowToken, msg.sender, address(this), newBorrowAmount - nettedAmount);
            }

            if (!isNetted) _transferTokens(borrowToken, address(this), prevLender, netTerminalDebtPrev);

            if (extraDemanded > 0) _transferTokens(borrowToken, address(this), borrower, extraDemanded);
            if (supplyPulled > 0) _transferTokens(supplyToken, address(this), borrower, supplyPulled);
            if (msg.value > ethRequired) _payEth(lender, msg.value - ethRequired);

            emit LoanRefinanced(
                lendingId,
                lender,
                prevLender,
                newBorrowAmount,
                netTerminalDebtPrev,
                rate,
                uint48(currentTime),
                newTerm,
                extraDemanded,
                supplyPulled,
                uint96(gasCompensation),
                liquidatorFraction,
                isNetted
            );
        }
    }

    /**
     * @notice Borrower-only repayment.
     * @dev    Partial repayments are streamed to the lender, satisfying interest first then reducing principal.
     *         If the payment covers the residual debt, the loan closes and the borrower gets all the collateral
     *         back. When borrowToken is native ETH and `amount` exceeds residual debt, the excess ETH is refunded
     *         to `msg.sender` (the payer). Reverts during a live liquidation, after maturity plus grace, or once
     *         finished or cancelled.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  amount BorrowToken amount to apply against debt. May exceed `netTerminalDebt` (excess is not pulled).
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if `supplyAmount < expectedMinSupply`.
     * @param  expectedMaxPrincipal Reverts if `principal > expectedMaxPrincipal`.
     * @param mustClose Reverts if repayment does not result in the borrower receiving their collateral back (full repay).
     */
    function repayDebt(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal,
        bool mustClose
    ) external payable nonReentrant autoSettle(lendingId) {
        if (msg.sender != lendingArrangements[lendingId].borrower) revert LendErrors.NotBorrower();
        _repayDebt(lendingId, amount, expectedParamHash, expectedMinSupply, expectedMaxPrincipal, mustClose);
    }

    /**
     * @notice Permissionless variant of `repayDebt`: anyone can repay any loan's debt.
     * @dev    Same gating and parameters as `repayDebt`. The third party puts up the borrowToken. If borrowToken
     *         is native ETH and `amount` exceeds residual debt on full repayment, the excess ETH is refunded to
     *         `msg.sender`; collateral still returns to the recorded borrower.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  amount BorrowToken amount to apply against debt.
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if `supplyAmount < expectedMinSupply`.
     * @param  expectedMaxPrincipal Reverts if `principal > expectedMaxPrincipal`.
     * @param mustClose Reverts if repayment does not result in the borrower receiving their collateral back (full repay).
     */
    function repayAnyDebt(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal,
        bool mustClose
    ) external payable nonReentrant autoSettle(lendingId) {
        _repayDebt(lendingId, amount, expectedParamHash, expectedMinSupply, expectedMaxPrincipal, mustClose);
    }

    /**
     * @notice Borrower-only collateral top-up. Pulls additional supplyToken into the contract.
     * @dev    Reverts during liquidation, during a grace period from a failed liquidation, after maturity plus
     *         grace, or once the loan is finished or cancelled.
     *         Re-checks the supply + stake and escalationHalt overflow bounds against the post-top-up amount.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  amount SupplyToken amount to add to collateral.
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if current `supplyAmount < expectedMinSupply`.
     * @param  expectedMaxPrincipal Reverts if `principal > expectedMaxPrincipal`.
     */
    function topUpCollateral(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal
    ) external payable nonReentrant autoSettle(lendingId) {
        if (msg.sender != lendingArrangements[lendingId].borrower) revert LendErrors.NotBorrower();
        _topUpCollateral(lendingId, amount, expectedParamHash, expectedMinSupply, expectedMaxPrincipal);
    }

    /**
     * @notice Permissionless variant of `topUpCollateral`: anyone can add collateral on behalf of any loan.
     * @dev    Same gating and parameters as `topUpCollateral`. The third party puts up the supplyToken.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  amount SupplyToken amount to add to collateral.
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if current `supplyAmount < expectedMinSupply`.
     * @param  expectedMaxPrincipal Reverts if `principal > expectedMaxPrincipal`.
     */
    function topUpCollateralAnyone(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal
    ) external payable nonReentrant autoSettle(lendingId) {
        _topUpCollateral(lendingId, amount, expectedParamHash, expectedMinSupply, expectedMaxPrincipal);
    }

    /**
     * @notice Forfeits the collateral to the lender once the loan has expired without being repaid or
     *         refinanced. Anyone can call; the funds always go to the lender.
     * @dev    Reverts if the loan is still within its term plus grace period, or if it's cancelled, finished,
     *         not active, or in liquidation. The grace period is non-zero only when a failed liquidation
     *         finished too close to or past maturity.
     * @param  lendingId Unique identifier of the lending arrangement.
     */
    function claimCollateral(uint256 lendingId) external nonReentrant autoSettle(lendingId) {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;

        if (lending.inLiquidation) revert LendErrors.InLiquidation();
        if (lending.finished) revert LendErrors.Finished();
        if (!lending.active) revert LendErrors.NotActive();
        if (lending.cancelled) revert LendErrors.Cancelled();
        if (currentTime < uint256(lending.start) + lending.term + lending.gracePeriod) {
            revert LendErrors.NotExpired();
        }

        uint128 supplyAmount = lending.supplyAmount;
        address supplyToken = lending.supplyToken;
        address lender = lending.lender;

        lending.finished = true;
        _clearRefiCurve(lending);

        _sendGasComp(lending);
        _transferTokens(supplyToken, address(this), lender, supplyAmount);

        emit CollateralClaimedByLender(lendingId, supplyAmount);
    }

    /**
     * @notice Borrower opens a refinance: re-opens the rate curve so any lender can roll the loan, optionally
     *         drawing extra borrow, returning some collateral, or changing the term.
     * @dev    Stages the refi parameters and marks the curve open; the actual roll happens when a lender
     *         calls `lend`. Outside liquidation, `requestStart` is set to `block.timestamp` so the curve
     *         starts ticking immediately. During liquidation the curve is parked: `requestStart` is left at
     *         zero and only gets populated later, when an unsuccessful liquidation is finalized and writes the
     *         report's settleable-at time. New oracle params (when supplied) are
     *         validated now and become the loan's oracle config at lend time. Allowed during a live
     *         liquidation; the maturity-plus-grace expiry check is skipped in that case. The borrower or the
     *         current refi delegate can call, only on an active loan with a closed curve. Emits
     *         `RefiOpenedDuringLiquidation` when called mid-liquidation, `RefiOpened` otherwise.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  extraDemanded Additional borrowToken pulled to the borrower at lend-time (on top of rolling debt).
     * @param  supplyPulled SupplyToken returned to the borrower at lend-time. Must be < current `supplyAmount`.
     * @param  newTerm New term in seconds for the post-refi loan, or 0 to keep the existing term. If non-zero,
     *                 bounded [1800, 1 year]; same range as origination.
     * @param  gasCompensation ETH escrowed to pay the lender who accepts the refi. Must equal `msg.value`. Refunded
     *                         to the borrower if the refi is cancelled or the loan terminates with the curve open.
     * @param  interestRateParams New curve parameters governing the refi auction. Pass `maxRate = 0` to keep the
     *                            existing interest-rate config.
     * @param  oracleParams Optional new oracle params for the post-refi loan. Pass `settlementTime = 0` to keep
     *                      the existing config; otherwise validated and applied at lend acceptance.
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if `supplyAmount < expectedMinSupply`.
     * @param  expectedMaxPrincipal Reverts if `principal > expectedMaxPrincipal`.
     */
    function refinance(
        uint256 lendingId,
        uint128 extraDemanded,
        uint128 supplyPulled,
        uint48 newTerm,
        uint96 gasCompensation,
        InterestRateParams calldata interestRateParams,
        OracleParams calldata oracleParams,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal
    ) external payable nonReentrant autoSettle(lendingId) {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        RefiParams storage refiParams = lending.refiParams;
        OracleParams memory eventOP;

        uint256 currentTime = block.timestamp;
        uint256 supplyAmount = lending.supplyAmount;
        bool inLiquidation = lending.inLiquidation;
        uint48 currentTerm = lending.term;
        uint48 finalTerm = newTerm == 0 ? currentTerm : newTerm;

        if (msg.sender != lending.borrower && msg.sender != refiDelegation[lendingId]) revert LendErrors.NotBorrower();
        if (!lending.active) revert LendErrors.NotActive();
        if (lending.finished) revert LendErrors.Finished();
        if (lending.cancelled) revert LendErrors.Cancelled();
        if (lending.curveOpen) revert LendErrors.CurveIsOpen();

        if (supplyPulled >= supplyAmount) revert LendErrors.SupplyPulledTooHigh();
        if (oracleParams.settlementTime != 0) {
            _validateOracleParams(oracleParams, supplyAmount - supplyPulled);
        }
        if (interestRateParams.maxRate != 0) {
            _validateInterestRateParams(interestRateParams);
        }

        if (lending.principal > expectedMaxPrincipal) revert LendErrors.PrincipalTooHigh();
        if (supplyAmount < expectedMinSupply) revert LendErrors.SupplyTooLow();
        if (newTerm != 0 && (newTerm < 1800 || newTerm > 60 * 60 * 24 * 365)) revert LendErrors.TermOutOfBounds();
        if (!inLiquidation && currentTime >= uint256(lending.start) + currentTerm + lending.gracePeriod) {
            revert LendErrors.Expired();
        }
        if (msg.value != gasCompensation) revert LendErrors.MsgValue();
        if (expectedParamHash != bytes32(0)) {
            _checkParamsLoose(lending, expectedParamHash);
        }

        refiParams.extraDemanded = extraDemanded;
        refiParams.supplyPulled = supplyPulled;
        refiParams.newTerm = finalTerm;
        lending.curveOpen = true;
        if (!inLiquidation) {
            lending.requestStart = uint48(currentTime);
        }
        if (interestRateParams.maxRate != 0) lending.interestRateParams = interestRateParams;
        lending.gasCompensation = gasCompensation;

        if (oracleParams.settlementTime != 0) {
            refiParams.oracleParams = oracleParams;
            eventOP = oracleParams;
        } else {
            eventOP = lending.oracleParams;
        }

        if (inLiquidation) {
            emit RefiOpenedDuringLiquidation(
                lendingId, extraDemanded, supplyPulled, finalTerm, gasCompensation, eventOP, lending.interestRateParams
            );
        } else {
            emit RefiOpened(
                lendingId, extraDemanded, supplyPulled, finalTerm, gasCompensation, eventOP, lending.interestRateParams
            );
        }
    }

    /**
     * @notice Closes an open refi curve before any lender has accepted. Restores the loan to its pre-refi state.
     * @dev    Borrower-only. Clears the staged refi params and refunds the staged gasCompensation. The live
     *         underlying loan's rate, term, and start are untouched.
     * @param  lendingId Unique identifier of the lending arrangement.
     */
    function cancelRefinance(uint256 lendingId) external nonReentrant autoSettle(lendingId) {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        if (msg.sender != lending.borrower) revert LendErrors.NotBorrower();
        if (!lending.active) revert LendErrors.NotActive();
        if (lending.finished) revert LendErrors.Finished();
        if (lending.cancelled) revert LendErrors.Cancelled();
        if (!lending.curveOpen) revert LendErrors.CurveIsNotOpen();

        _clearRefiCurve(lending);

        _sendGasComp(lending);

        emit RefiCancelled(lendingId);
    }

    /**
     * @notice Initiates a liquidation by spawning an openOracle price report. The caller wagers
     *         `stake * supplyAmount / 10000` of supplyToken that the oracle will resolve to an underwater price.
     * @dev    Permissionless: anyone may call. `msg.sender` transfers initial liquidity for both sides of
     *         the oracle report (supplyToken as token1, borrowToken as token2 sized by `priceRatio`) plus the
     *         stake, pays `settlerReward` wei as the openOracle settler reward, and escrows the configured
     *         `finalizerReward` for whoever finalizes the liquidation.
     *         While the report is open the loan is in liquidation: the borrower cannot repay or top up.
     *         Resolution happens through `finalize` once the report can no longer be disputed: if the oracle
     *         resolves underwater the liquidator recovers the stake and the equity buffer is split per
     *         `liquidatorFraction` between liquidator and lender; the lender receives the rest of the
     *         collateral. Otherwise the stake is forfeit. If resolution
     *         lands more than 30 minutes before maturity, the full stake is added to supplyAmount (claimable by
     *         the lender on default, or by the borrower on repay/refi). If it lands within the last 30 minutes of the term or after maturity, a grace
     *         period is granted to give the borrower time to react and the stake is split: half to the lender
     *         as compensation for the deferred payoff, the rest added to supplyAmount. Reverts if the loan is
     *         already in liquidation, finished, cancelled, past maturity, or sitting in a grace period left
     *         over from a prior failed liquidation.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  priceRatio borrowToken-per-supplyToken in 1e18 fixed-point. Used to compute the report's token2 side.
     * @param  maxInitialLiquidity Cap on `initialLiquidity` (= `supplyAmount × oracleParams.initialLiquidity / 100`).
     * @param  paramHashExpected Liquidate paramHash, enforced via `_checkParamsLiquidate`. Beyond the
     *                           loose-hash zeroing it also zeroes `refiParams`, `curveOpen`, and
     *                           `gasCompensation`, so borrower refi staging or cancellation cannot
     *                           invalidate a pending liquidate transaction.
     * @param  worstRatio Reverts if `1e18 * netBorrow / supplyAmount < worstRatio`.
     * @param  settlerReward Wei `msg.sender` pays as the openOracle settler reward. Unbounded; caller picks
     *                        based on how much they want to pay third-party oracle settlers.
     * @param  liquidator Address recorded as the liquidator and recipient of liquidator-side payouts.
     * @param  expectedFinalizerReward Expected configured finalizer reward; reverts if the loan's oracle params differ.
     */
    function liquidate(
        uint256 lendingId,
        uint256 priceRatio,
        uint128 maxInitialLiquidity,
        bytes32 paramHashExpected,
        uint256 worstRatio,
        uint96 settlerReward,
        address liquidator,
        uint64 expectedFinalizerReward,
        IOpenOracle2.TimingBoundaries calldata timing
    ) external payable nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        OracleParams storage oracleParams = lending.oracleParams;

        uint256 currentTime = block.timestamp;

        if (lending.inLiquidation) revert LendErrors.InLiquidation();
        if (lending.finished) revert LendErrors.Finished();
        if (!lending.active) revert LendErrors.NotActive();
        if (lending.cancelled) revert LendErrors.Cancelled();
        if (currentTime >= uint256(lending.start) + lending.term) revert LendErrors.Expired();
        if (lending.gracePeriod != 0) revert LendErrors.InGracePeriod();
        _checkParamsLiquidate(lending, paramHashExpected);
        if (liquidator == address(0)) revert LendErrors.AddressCannotBeZero();

        _touchAmort(lending);

        uint128 supplyAmount = lending.supplyAmount;
        address borrowToken = lending.borrowToken;
        address supplyToken = lending.supplyToken;
        uint64 finalizerReward = lending.oracleParams.finalizerReward;
        address feeRecipient;
        uint256 tokenStake = uint256(supplyAmount) * lending.stake / 10000;
        uint256 initialLiquidity = uint256(supplyAmount) * oracleParams.initialLiquidity / 100;
        uint256 oracleAmount2 = Math.mulDiv(initialLiquidity, priceRatio, 1e18);
        uint256 escHalt = uint256(supplyAmount) * oracleParams.escalationFactor / 100;
        uint256 borrowValue = _residualDebt(lending);
        uint256 liqThresh = uint256(supplyAmount) * lending.liquidationThreshold / 1e7;
        uint256 initialBorrowValueInSupplyTerms = Math.mulDiv(borrowValue, initialLiquidity, oracleAmount2);
        uint256 ethRequired = uint256(settlerReward) + finalizerReward;
        uint256 oracleMsgValue = settlerReward;
        address lender = lending.lender;
        bool isEth1;
        bool isEth2;

        if (supplyToken == ETH_SENTINEL) {
            ethRequired += initialLiquidity + tokenStake;
            oracleMsgValue += initialLiquidity;
            isEth1 = true;
        }

        if (borrowToken == ETH_SENTINEL) {
            ethRequired += oracleAmount2;
            oracleMsgValue += oracleAmount2;
            isEth2 = true;
        }

        if (msg.value < ethRequired) revert LendErrors.MsgValue();

        if (borrowValue == 0) revert LendErrors.NoNetBorrow();
        uint256 ratio = Math.mulDiv(1e18, borrowValue, supplyAmount);

        if (expectedFinalizerReward != finalizerReward) revert LendErrors.FinalizerRewardMismatch();
        if (oracleAmount2 > type(uint128).max) revert LendErrors.Amount2TooLarge();
        if (escHalt > type(uint128).max) revert LendErrors.EscalationHaltTooHigh();
        if (tokenStake + supplyAmount > type(uint128).max) revert LendErrors.TokenStakePlusSupplyAmountTooLarge();
        if (ratio < worstRatio) revert LendErrors.PositionTooHealthy();
        if (initialLiquidity > maxInitialLiquidity) revert LendErrors.TooMuchOracleGameInitialLiquidity();

        if (initialBorrowValueInSupplyTerms <= liqThresh) {
            revert LendErrors.InitialReportNotLiquidationEligible();
        }

        lending.requestStart = 0;

        uint256 reportId = oracle.nextReportId();

        lending.inLiquidation = true;
        lending.liquidationStart = uint48(currentTime);
        lending.liquidator = liquidator;

        lendingToReportId[lendingId] = reportId;

        if (oracleParams.oracleGameFee > 0) {
            feeRecipient =
                _deployFeeReceiver(lendingId, reportId, supplyToken, borrowToken, lending.borrower, lender, liquidator);
        }

        if (!isEth1) {
            _pullToken(supplyToken, msg.sender, address(this), initialLiquidity + tokenStake);
            _ensureOracleApproval(supplyToken);
        }
        if (!isEth2) {
            _pullToken(borrowToken, msg.sender, address(this), oracleAmount2);
            _ensureOracleApproval(borrowToken);
        }

        uint256 reportIdGen = _oracleGame(
            oracleParams,
            timing,
            supplyToken,
            borrowToken,
            uint128(initialLiquidity),
            uint128(escHalt),
            feeRecipient,
            settlerReward,
            uint128(oracleAmount2),
            oracleMsgValue,
            liquidator
        );

        if (reportIdGen != reportId) revert LendErrors.ReportIdsDontMatch();

        if (msg.value > ethRequired) {
            _payEth(liquidator, msg.value - ethRequired);
        }

        emit LoanLiquidationUnderway(lendingId, lender, liquidator, reportId, feeRecipient, lending.borrower);
    }

    /**
     * @notice Withdraws any tokens held for the caller in the `tempHolding` escrow.
     * @dev    Tokens land in `tempHolding` whenever an outgoing transfer from the contract fails (for example,
     *         when the recipient is blacklisted by the token). The rightful recipient can retry later through
     *         this entrypoint; if the retry also fails, the amount is re-credited to `tempHolding`.
     * @param  tokenToGet ERC20 to withdraw.
     */
    function getTempHolding(address tokenToGet) external nonReentrant {
        uint256 amount = tempHolding[msg.sender][tokenToGet];
        if (amount > 0) {
            tempHolding[msg.sender][tokenToGet] = 0;
            _transferTokens(tokenToGet, address(this), msg.sender, amount);
            emit TempHoldingWithdrawn(msg.sender, tokenToGet, amount);
        }
    }

    /**
     * @notice Sets or revokes the contract authorized to call `refinance` for this loan alongside the
     *         borrower. Borrower-only. Pass address(0) to revoke.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  delegate Contract to authorize, or address(0) for none.
     */
    function setRefiDelegate(uint256 lendingId, address delegate) external nonReentrant {
        address borrower = lendingArrangements[lendingId].borrower;
        if (borrower != msg.sender) revert LendErrors.MsgSender();
        refiDelegation[lendingId] = delegate;
        emit RefiDelegateSet(lendingId, delegate);
    }

    /**
     * @notice Sets or revokes the contract authorized to net lending into a borrower refinance for this loan
     *         on behalf of a lender. Lender-only. Pass address(0) to revoke.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  delegate Contract to authorize, or address(0) for none.
     */
    function setLenderDelegate(uint256 lendingId, address delegate) external nonReentrant {
        address lender = lendingArrangements[lendingId].lender;
        if (lender != msg.sender) revert LendErrors.MsgSender();
        lenderDelegation[lendingId] = delegate;
        emit LenderDelegateSet(lendingId, delegate);
    }

    // -------------------------------------------------------------------------
    //                              Internal functions
    // -------------------------------------------------------------------------

    /// @dev Shared body of `repayDebt` and `repayAnyDebt`. Either closes the loan or streams the partial to
    ///      the lender and applies it via `_applyAmortPartial`.
    function _repayDebt(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal,
        bool mustClose
    ) internal {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        _touchAmort(lending);

        uint256 currentTime = block.timestamp;
        uint256 term = lending.term;
        uint256 owed = _residualDebt(lending);
        address lender = lending.lender;
        uint256 supplied = lending.supplyAmount;
        address borrowToken = lending.borrowToken;
        bool isEth = borrowToken == ETH_SENTINEL;
        uint256 ethRequired = isEth ? amount : 0;
        bool isFinished = false;

        if (msg.value != ethRequired) revert LendErrors.MsgValue();
        if (lending.inLiquidation) revert LendErrors.InLiquidation();
        if (lending.finished) revert LendErrors.Finished();
        if (!lending.active) revert LendErrors.NotActive();
        if (lending.cancelled) revert LendErrors.Cancelled();
        if (currentTime >= uint256(lending.start) + term + lending.gracePeriod) revert LendErrors.Expired();
        if (lending.principal > expectedMaxPrincipal) revert LendErrors.PrincipalTooHigh();
        if (supplied < expectedMinSupply) revert LendErrors.SupplyTooLow();
        if (amount == 0) revert LendErrors.ZeroAmount();
        if (expectedParamHash != bytes32(0)) {
            _checkParamsLoose(lending, expectedParamHash);
        }

        if (amount >= owed) {
            address supplyToken = lending.supplyToken;
            address borrower = lending.borrower;
            isFinished = true;

            lending.finished = true;
            _clearRefiCurve(lending);

            _sendGasComp(lending);
            if (!isEth) _pullToken(borrowToken, msg.sender, address(this), owed);
            _transferTokens(borrowToken, address(this), lender, owed);
            _transferTokens(supplyToken, address(this), borrower, supplied);
            if (isEth && amount > owed) {
                _payEth(msg.sender, amount - owed); // refund for overpaying eth
            }
            emit DebtRepaid(lendingId, msg.sender, owed, true);
        } else {
            _applyAmortPartial(lending, amount);

            if (!isEth) _pullToken(borrowToken, msg.sender, address(this), amount);
            _transferTokens(borrowToken, address(this), lender, amount);
            emit DebtRepaid(lendingId, msg.sender, amount, false);
        }

        if (!isFinished && mustClose) revert LendErrors.MustClose();
    }

    /// @dev Shared body of `topUpCollateral` and `topUpCollateralAnyone`.
    function _topUpCollateral(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal
    ) internal {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;
        uint256 prevSupplyAmount = lending.supplyAmount;
        uint256 newSupplyAmount = prevSupplyAmount + amount;
        uint256 escHalt = newSupplyAmount * lending.oracleParams.escalationFactor / 100;
        address supplyToken = lending.supplyToken;
        bool isEth = supplyToken == ETH_SENTINEL;
        uint256 ethRequired = isEth ? amount : 0;

        if (msg.value != ethRequired) revert LendErrors.MsgValue();
        if (amount == 0) revert LendErrors.ZeroAmount();
        if (lending.inLiquidation) revert LendErrors.InLiquidation();
        if (lending.finished) revert LendErrors.Finished();
        if (!lending.active) revert LendErrors.NotActive();
        if (lending.cancelled) revert LendErrors.Cancelled();
        if (newSupplyAmount + newSupplyAmount * lending.stake / 10000 > type(uint128).max) {
            revert LendErrors.SupplyPlusStakeTooHigh();
        }
        if (escHalt > type(uint128).max) revert LendErrors.EscalationHaltTooHigh();
        if (currentTime >= uint256(lending.start) + lending.term + lending.gracePeriod) revert LendErrors.Expired();
        if (lending.principal > expectedMaxPrincipal) revert LendErrors.PrincipalTooHigh();
        if (prevSupplyAmount < expectedMinSupply) revert LendErrors.SupplyTooLow();
        if (expectedParamHash != bytes32(0)) {
            _checkParamsLoose(lending, expectedParamHash);
        }
        if (lending.gracePeriod > 0) revert LendErrors.InGracePeriod();

        lending.supplyAmount += amount;

        if (!isEth) _pullToken(supplyToken, msg.sender, address(this), amount);

        emit CollateralToppedOff(lendingId, msg.sender, amount);
    }

    /// @dev Reverts unless the keccak256 of the on-chain arrangement matches the caller-supplied hash,
    ///      after zeroing the volatile and liquidation-lifecycle fields. The hash pins loan
    ///      configuration only: fields that merely gate legality are re-checked live at execution and
    ///      are zeroed here, so a hash computed from a pre-autoSettle read stays valid across the
    ///      settle. The rate implied by requestStart is guarded separately by lend()'s minRate.
    function _checkParamsLoose(LendingArrangement storage lending, bytes32 paramHashExpected) internal pure {
        LendingArrangement memory copy = lending;
        copy.supplyAmount = 0;
        copy.interestAccrued = 0;
        copy.interestRemainder = 0;
        copy.interestPaid = 0;
        copy.principal = 0;
        copy.lastTouch = 0;
        copy.requestStart = 0;
        copy.inLiquidation = false;
        copy.liquidationStart = 0;
        copy.liquidator = address(0);
        copy.gracePeriod = 0;

        if (paramHashExpected != keccak256(abi.encode(copy))) revert LendErrors.Params();
    }

    /// @dev Liquidate variant of `_checkParamsLoose`: additionally zeroes the staged refi / future-auction
    ///      surface (`refiParams`, `curveOpen`, `gasCompensation`, `interestRateParams`).
    function _checkParamsLiquidate(LendingArrangement storage lending, bytes32 paramHashExpected) internal pure {
        LendingArrangement memory copy = lending;
        copy.supplyAmount = 0;
        copy.interestAccrued = 0;
        copy.interestRemainder = 0;
        copy.interestPaid = 0;
        copy.principal = 0;
        copy.lastTouch = 0;
        copy.requestStart = 0;
        copy.inLiquidation = false;
        copy.liquidationStart = 0;
        copy.liquidator = address(0);
        copy.gracePeriod = 0;
        copy.gasCompensation = 0;
        copy.curveOpen = false;
        delete copy.refiParams;
        delete copy.interestRateParams;

        if (paramHashExpected != keccak256(abi.encode(copy))) revert LendErrors.Params();
    }

    /// @dev Grants the oracle infinite allowance on the given token the first time it's needed.
    function _ensureOracleApproval(address token) internal {
        if (!_oracleApproved[token]) {
            IERC20(token).forceApprove(address(oracle), type(uint256).max);
            _oracleApproved[token] = true;
        }
    }

    /// @dev Deploys a per-liquidation fee receiver clone with the liquidation-time snapshot baked into
    ///      its bytecode as immutable args. The oracle pays its protocol fees to the clone, and anyone
    ///      may later call `distribute()` on it to split them across borrower, lender, and liquidator.
    ///      Salt is the oracle's globally-unique, strictly-increasing report id, so re-liquidations of
    ///      the same lendingId always get fresh clones; addresses are deployer-bound and an
    ///      occupied-address deploy reverts.
    function _deployFeeReceiver(
        uint256 lendingId,
        uint256 reportId,
        address supplyToken,
        address borrowToken,
        address borrower,
        address lender,
        address liquidator
    ) internal returns (address feeReceiver) {
        bytes memory args = abi.encodePacked(lendingId, supplyToken, borrowToken, borrower, lender, liquidator);
        feeReceiver = LibClone.cloneDeterministic(feeReceiverImpl, args, bytes32(reportId));
    }

    function _oracleGame(
        OracleParams memory oracleParams,
        IOpenOracle2.TimingBoundaries memory timing,
        address supplyToken,
        address borrowToken,
        uint128 initialLiquidity,
        uint128 escHalt,
        address feeRecipient,
        uint96 settlerReward,
        uint128 amount2,
        uint256 oracleMsgValue,
        address liquidator
    ) internal returns (uint256 reportId) {
        IOpenOracle2.OracleGame memory params = IOpenOracle2.OracleGame({
            currentAmount1: initialLiquidity,
            currentAmount2: amount2,
            currentReporter: liquidator,
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: supplyToken,
            lastReportOppoTime: 0,
            settlementTime: oracleParams.settlementTime,
            escalationHalt: escHalt,
            protocolFeeRecipient: feeRecipient,
            settlerReward: settlerReward,
            token2: borrowToken,
            numReports: 0,
            disputeDelay: oracleParams.disputeDelay,
            feePercentage: 0,
            multiplier: oracleParams.multiplier,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: oracleParams.oracleGameFee,
            flags: 5
        });

        reportId = oracle.report{value: oracleMsgValue}(params, false, false, timing);
    }

    /// @dev Executes liquidation.
    function _executeLiquidation(LendingArrangement storage lending, uint256 id, uint256 lendingId) internal {
        uint48 start = lending.start;
        uint48 term = lending.term;
        uint128 supplyAmount = lending.supplyAmount;
        address lender = lending.lender;
        address supplyToken = lending.supplyToken;
        uint256 borrowValue = _residualDebt(lending);

        IOpenOracle2.OracleGame memory o = oracle.storedGame(id);
        uint256 oracleAmount1 = o.currentAmount1;
        uint256 oracleAmount2 = o.currentAmount2;
        uint256 tokenStake = uint256(supplyAmount) * lending.stake / 10000;
        uint256 borrowValueInSupplyTerms = Math.mulDiv(borrowValue, oracleAmount1, oracleAmount2);
        uint256 liqThresh = uint256(supplyAmount) * lending.liquidationThreshold / 1e7;

        uint48 maxBaseFee = lending.oracleParams.maxBaseFee;
        uint128 initialLiquidity = lending.oracleParams.initialLiquidity;
        uint256 originalAmount1 = uint256(supplyAmount) * initialLiquidity / 100;
        bool baseFeeOk = maxBaseFee == 0 || block.basefee <= Math.mulDiv(maxBaseFee, oracleAmount1, originalAmount1); // optionally shift variance from borrower to lender, reflected in interest rate

        lending.inLiquidation = false;
        lendingToReportId[lendingId] = 0;
        if (liqThresh < borrowValueInSupplyTerms && baseFeeOk) {
            address liquidator = lending.liquidator;

            lending.finished = true;
            _clearRefiCurve(lending);

            if (borrowValueInSupplyTerms > supplyAmount) {
                _sendGasComp(lending);
                _transferTokens(supplyToken, address(this), lender, supplyAmount);
                _transferTokens(supplyToken, address(this), liquidator, tokenStake);

                emit LiqFinishedUnderwater(lendingId);
            } else {
                uint256 buffer = supplyAmount - borrowValueInSupplyTerms;
                uint256 liquidatorPiece = buffer * lending.liquidatorFraction / 1e7;
                uint256 lenderPiece = buffer - liquidatorPiece;

                _sendGasComp(lending);
                _transferTokens(supplyToken, address(this), lender, borrowValueInSupplyTerms + lenderPiece);
                _transferTokens(supplyToken, address(this), liquidator, liquidatorPiece + tokenStake);

                emit LiqFinishedWithBuffer(lendingId);
            }
        } else {
            uint256 settleableAt = o.reportTimestamp + lending.oracleParams.settlementTime;
            uint256 liquidationStart = lending.liquidationStart;

            lending.liquidationStart = 0;
            lending.liquidator = address(0);
            if (lending.curveOpen) {
                lending.requestStart = uint48(settleableAt);
            }

            // Grace period around liquidations that end either too close to maturity (30 minutes) or after it.
            // When grace fires, half the stake routes to the lender.
            if (settleableAt > uint256(start) + term - 1800) {
                lending.gracePeriod = uint48(1800 + (settleableAt - liquidationStart));

                uint256 lenderStakePiece = tokenStake / 2;
                lending.supplyAmount += uint128(tokenStake - lenderStakePiece);
                _transferTokens(supplyToken, address(this), lender, lenderStakePiece);
            } else {
                lending.supplyAmount += uint128(tokenStake);
            }

            emit LiqUnsuccessful(lendingId);
        }
    }

    /// @dev Pulls ERC20 tokens using SafeERC20. Tokens that revert or return false are rejected.
    function _pullToken(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    /**
     * @dev Token transfer with a fallback to per-recipient escrow. Failed outgoing ERC20 transfers are credited
     *      to `tempHolding` so the recipient can pull later.
     */
    function _transferTokens(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return; // Gas optimization: skip zero transfers

        if (from == address(this)) {
            if (token == ETH_SENTINEL) {
                _payEth(to, amount);
            } else {
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

                tempHolding[to][token] += amount;
            }
        } else {
            _pullToken(token, from, to, amount);
        }
    }

    /// @dev Sends ETH to a recipient, with a WETH fallback if the direct send fails (for example, the
    ///      recipient is a contract that rejects ETH or exceeds the 40k gas cap).
    function _payEth(address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        (bool ok,) = payable(_to).call{value: _amount, gas: 40000}("");
        if (!ok) {
            IWETH(WETH).deposit{value: _amount}();
            IERC20(WETH).safeTransfer(_to, _amount);
        }
    }

    /**
     * @notice Finalizes a liquidation once its oracle report can no longer be disputed, paying the
     *         escrowed `finalizerReward` to the caller.
     * @dev    Reads the final price from the oracle's stored game and executes the liquidation. Does not
     *         settle the oracle game; its funds and settler reward are released separately by
     *         `oracle.settle`. Reverts if the loan is not in liquidation or the report is still within
     *         its dispute window. The `autoSettle` modifier reaches the same logic but returns instead
     *         of reverting when those conditions are not met.
     * @param  lendingId Unique identifier of the lending arrangement.
     */
    function finalize(uint256 lendingId) external nonReentrant {
        _finalize(lendingId, true);
    } // direct: revert if not ready

    function _finalizeHelper(uint256 lendingId) internal {
        _finalize(lendingId, false);
    } // modifier: no-op if not ready

    function _finalize(uint256 lendingId, bool strict) internal {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        if (!lending.inLiquidation) {
            if (strict) revert LendErrors.NotInLiquidation();
            return;
        }

        uint256 reportId = lendingToReportId[lendingId];
        IOpenOracle2.OracleGame memory o = oracle.storedGame(reportId);
        if (block.timestamp < uint256(o.reportTimestamp) + o.settlementTime) {
            if (strict) revert LendErrors.ReportStillDisputable();
            return;
        }

        uint64 bounty = lending.oracleParams.finalizerReward;

        _touchAmort(lending);
        _executeLiquidation(lending, reportId, lendingId);
        if (bounty > 0) _payEth(msg.sender, bounty);
        emit BountyPaid(lendingId, msg.sender, bounty);
    }

    /// @dev Validates `InterestRateParams`.
    function _validateInterestRateParams(InterestRateParams calldata ir) internal pure {
        if (
            ir.maxRate == 0 || ir.startingRate == 0 || ir.growthRate == 0 || ir.maxRounds == 0 || ir.roundLength == 0
                || ir.maxRate < ir.startingRate || ir.growthRate <= 10000 || ir.maxRounds > 100
        ) revert LendErrors.InterestRateParams();
    }

    /// @dev Validates `OracleParams`.
    function _validateOracleParams(OracleParams calldata op, uint256 supplyAmount) internal pure {
        uint256 settlementTime = op.settlementTime;
        uint256 escalationFactor = op.escalationFactor;
        uint256 initialLiquidity = op.initialLiquidity;
        uint256 multiplier = op.multiplier;
        uint256 escHalt = uint256(supplyAmount) * escalationFactor / 100;

        if (
            settlementTime < 120 || settlementTime > 60 * 60 * 4 || escalationFactor < 10 || escalationFactor > 5000
                || initialLiquidity < 5 || initialLiquidity > 250 || escalationFactor < initialLiquidity
                || escHalt > type(uint128).max || op.oracleGameFee > 1e6 || multiplier < 100 || multiplier > 1000
                || op.disputeDelay >= settlementTime
        ) revert LendErrors.OracleParams();
    }

    /// @dev Evaluates the rising rate curve at the current block.
    /// @param ir Curve parameters.
    /// @param requestStart Anchor for the curve. Set at `requestBorrow` and reset at `refinance` / failed liquidation.
    /// @return The current rate in 1e9 fixed-point APR (1e8 = 10%).
    function calcRate(InterestRateParams memory ir, uint48 requestStart) internal view returns (uint256) {
        uint256 maxRate = ir.maxRate;
        uint256 startingRate = ir.startingRate;
        uint256 growthRate = ir.growthRate;
        uint256 maxRounds = ir.maxRounds;
        uint256 roundLength = ir.roundLength;
        uint256 currentTime = block.timestamp;
        uint256 timeDelta = currentTime - requestStart;

        timeDelta = timeDelta / roundLength;
        if (timeDelta > maxRounds) {
            timeDelta = maxRounds;
        }

        uint256 currentRate = startingRate;

        for (uint256 i = 0; i < timeDelta; i++) {
            currentRate = (currentRate * growthRate) / 10000;
            if (currentRate >= maxRate) {
                return maxRate;
            }
        }

        return currentRate;
    }

    /// @dev Folds elapsed-since-lastTouch interest into `interestAccrued`. Caps
    ///      accrual at `start + term`. Idempotent within a block.
    function _touchAmort(LendingArrangement storage l) internal {
        uint256 currentTime = block.timestamp;
        uint256 termEnd = uint256(l.start) + l.term;
        uint256 nowCapped = currentTime > termEnd ? termEnd : currentTime;
        uint256 lt = l.lastTouch == 0 ? uint256(l.start) : uint256(l.lastTouch);
        if (nowCapped > lt) {
            uint256 interestRaw = uint256(l.principal) * (nowCapped - lt) * l.rate + l.interestRemainder;
            l.interestAccrued += uint128(interestRaw / ACCRUAL_DENOM);
            l.interestRemainder = uint56(interestRaw % ACCRUAL_DENOM);
            l.lastTouch = uint48(nowCapped);
        }
    }

    /// @dev Allocates a partial payment: interest claim first (up to its
    ///      remaining balance), excess reduces principal. No underflow.
    ///      Caller must `_touchAmort(l)` first.
    function _applyAmortPartial(LendingArrangement storage l, uint128 amount) internal {
        uint256 maxInterestPayment = _interestClaim(l) - uint256(l.interestPaid);
        uint128 payInt = amount > maxInterestPayment ? uint128(maxInterestPayment) : amount;
        l.interestPaid += payInt;
        if (amount > payInt) {
            l.principal -= (amount - payInt);
        }
    }

    /// @dev Closeout balance — what borrower owes right now to fully close.
    ///      Caller must touch first.
    function _residualDebt(LendingArrangement storage l) internal view returns (uint256) {
        return uint256(l.principal) + _interestClaim(l) - uint256(l.interestPaid);
    }

    /// @dev Lender's interest claim at this moment: the larger of accrued
    ///      interest or the commitment floor.
    function _interestClaim(LendingArrangement storage l) internal view returns (uint256) {
        uint256 commitmentInterest = l.commitmentInterest;
        return l.interestAccrued > commitmentInterest ? uint256(l.interestAccrued) : commitmentInterest;
    }

    /// @dev Closes any open refi curve and clears the pending refi params.
    function _clearRefiCurve(LendingArrangement storage lending) internal {
        lending.curveOpen = false;
        lending.refiParams.extraDemanded = 0;
        lending.refiParams.supplyPulled = 0;
        lending.refiParams.newTerm = 0;
        delete lending.refiParams.oracleParams;
    }

    /// @dev Refunds any staged gasCompensation to the borrower and zeros the field.
    function _sendGasComp(LendingArrangement storage lending) internal {
        uint96 gc = lending.gasCompensation;
        if (gc > 0) {
            lending.gasCompensation = 0;
            _payEth(lending.borrower, gc);
        }
    }

}
