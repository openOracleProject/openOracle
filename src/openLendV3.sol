// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle} from "./interfaces/IOpenOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {oracleFeeReceiver} from "./oracleFeeReceiver.sol";

/**
 * @title openLend
 * @notice Permissionless overcollateralized lending protocol with Dutch auction rate discovery and openOracle liquidations.
 * @dev    Lifecycle:
 *           1. Borrower calls `requestBorrow` to lock collateral and open a rising interest rate curve.
 *           2. Any lender calls `lend` to accept the current rate on the curve, originating the loan.
 *           3. Borrower may `repayDebt` (partial or full), `topUpCollateral`, or `refinance` (re-opens curve for a new lender).
 *           4. Lender (or anyone, if `allowAnyLiquidator`) may call `liquidate` once they deem the position is sufficiently underwater,
 *              which spins up an openOracle price report. The oracle callback `onSettle` finalizes the liquidation.
 *           5. At maturity, lender calls `claimCollateral` if the loan was not repaid or refinanced.
 *
 *         Rate discovery: `calcRate` evaluates a piecewise exponential curve (`startingRate * growthRate^rounds`) keyed on
 *         `requestStart`, capped at `maxRate`. Lenders compete by being the first to call `lend` at an acceptable rate.
 *
 *         Uses openOracle (https://docs.openoracle.org) for liquidation price discovery.
 *
 *         Supported tokens: vanilla ERC20 and USDT-style tokens (non-bool return on transfer/transferFrom) only.
 *         Rebasing tokens, fee-on-transfer / tax tokens, and any token whose post-transfer balance does not equal
 *         the requested amount are not supported and will break accounting in the isolated lending arrangement.
 *
 */
contract openLend is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IOpenOracle public immutable oracle;
    address public immutable feeReceiverImpl;
    address public immutable WETH;

    error InvalidInput(string);

    uint256 nextLendingId = 1;
    /// @dev 1 = unlocked, 2 = held by `busyLock`.
    uint256 private _busyStatus;

    mapping(uint256 => LendingArrangement) public lendingArrangements;
    mapping(uint256 => mapping(address => Beneficiaries)) public lendingBeneficiaries;
    /// @dev oracle reportId → lendingId. Set in liquidate, cleared in onSettle and recover.
    mapping(uint256 => uint256) public reportIdToLending;
    /// @dev lendingId → active oracle reportId. Set in liquidate, cleared in onSettle and recover.
    mapping(uint256 => uint256) public lendingToReportId;
    mapping(address => mapping(address => uint256)) public tempHolding;
    mapping(address => bool) private _oracleApproved;

    constructor(IOpenOracle _oracle, address _WETH) {
        oracle = _oracle;
        feeReceiverImpl = address(new oracleFeeReceiver());
        WETH = _WETH;
        _busyStatus = 1;
    }

    receive() external payable {}

    modifier notBusy() {
        if (_busyStatus == 2) revert InvalidInput("busy");
        _;
    }

    modifier busyLock() {
        if (_busyStatus == 2) revert InvalidInput("busy");
        _busyStatus = 2;
        _;
        _busyStatus = 1;
    }

    modifier autoSettle(uint256 lendingId) {
        _settleHelper(lendingId);
        _;
    }

    /// @notice Full state of a single lending arrangement. Stored at `lendingArrangements[lendingId]`.
    struct LendingArrangement {
        uint128 supplyAmount; // amount supplied as collateral
        uint128 borrowAmount; // amount borrowed at time of loan origination
        uint128 amountDemanded; // amount demanded by borrower
        uint128 repaidDebt; // cumulative debt streamed to the lender (already in their wallet); pure accounting credit
        address borrower; // borrower address
        uint48 term; // length of loan in seconds
        uint48 start; // timestamp loan began
        address lender; // lender address
        uint96 gasCompensation; // ETH paid to whichever lender accepts the open curve via lend()
        address liquidator; // liquidator address
        uint48 liquidationStart; // timestamp where the liquidation started
        uint48 gracePeriod; // extra time to repay debt / accept refinance offer if liquidation oracle game runs past maturity
        address supplyToken; // supply token
        uint24 liquidationThreshold; // 8e6 = 80%. when accrued debt > liquidationThreshold * supplyAmount, liquidation is possible
        uint24 commitmentFraction; // 1e7 = 100% locked yield (full term), 0 = pure prorated; intermediates define a flex window before maturity
        address borrowToken; // borrow token
        uint32 rate; // 1e8 = 10%, annual interest rate
        uint16 stake; // 100 = 1%. stake * supplyAmount is how much liquidator must wager openOracle resolves to liquidation.
        bool allowAnyLiquidator; // lender allows anyone to liquidate the loan, splitting profits 50/50
        bool cancelled; // borrow request cancelled by borrower
        bool active; // offer accepted and loan is live
        bool inLiquidation; // loan is in liquidation (oracle game is running)
        bool finished; // loan has been liquidated or repaid
        bool curveOpen; // interest rate curve open
        address feeRecipient; // contract that receives protocol fees from oracle game
        uint48 requestStart; // anchor for the rate curve. Set when a borrow request or non-liq refi opens; parked at 0 while a refi is open during a live liquidation, then set to the report's settleable-at time when an unsuccessful liquidation settles.
        RefiParams refiParams; // parameters for borrower's next refinance
        OracleParams oracleParams; // parameters for oracle game
        InterestRateParams interestRateParams; // interest rate parameters
    }

    /// @notice Parameters for the rising interest rate curve evaluated by `calcRate`.
    /// @dev    Rate at round k is `min(maxRate, startingRate * (growthRate/10000)^k)`.
    ///         Curve is keyed on `requestStart`. `requestStart` is set when a borrow request opens or when a refi
    ///         opens outside liquidation; a refi opened mid-liquidation leaves `requestStart` at zero until the
    ///         liquidation settles unsuccessfully, at which point `onSettle` (or `recover`) sets it to the
    ///         report's settleable-at time.
    struct InterestRateParams {
        uint32 maxRate; // 1e8 = 10% APR cap. Hard ceiling on rate.
        uint32 startingRate; // 1e8 = 10% APR. Rate at round 0 (`requestStart`).
        uint24 roundLength; // seconds per round. Larger = slower curve.
        uint16 growthRate; // 10500 = 1.05x per round. Must be > 10000.
        uint16 maxRounds; // hard cap on rounds (also caps loop gas in `calcRate`).
    }

    /// @notice Pending refinance terms set by the borrower in `refinance`. Applied during `lend` refi branch.
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
        uint16 escalationFactor; // escalationHalt = supplyAmount * escalationFactor / 100. Bounded [10, 1000].
        uint16 initialLiquidity; // initial token1 in the oracle report = supplyAmount * initialLiquidity / 100. Bounded [10, 200].
        uint16 multiplier; // openOracle per-round dispute multiplier, e.g. 140 = 1.4x. Bounded [100, 1000].
    }

    /// @notice Snapshot of lender + liquidator at liquidate time, used for oracle game fee routing.
    struct Beneficiaries {
        address lender;
        address liquidator;
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
        uint256 borrowAmount,
        uint256 rate,
        uint48 start,
        uint48 term,
        uint96 gasCompensation,
        bool allowAnyLiquidator
    );
    event LoanRefinanced(
        uint256 indexed lendingId,
        address indexed newLender,
        address indexed prevLender,
        uint256 newBorrowAmount,
        uint256 owedToPrevLender,
        uint256 rate,
        uint48 start,
        uint48 term,
        uint128 extraDemanded,
        uint128 supplyPulled,
        uint96 gasCompensation,
        bool allowAnyLiquidator
    );
    event LoanLiquidationUnderway(uint256 indexed lendingId, uint256 reportId, address feeRecipient);
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
    event RefiOpenedDuringLiquidation(uint256 indexed lendingId, uint128 extraDemanded, uint128 supplyPulled, uint48 newTerm, uint96 gasCompensation, OracleParams oracleParams, InterestRateParams interestRateParams);
    event RefiCancelled(uint256 indexed lendingId);
    event LiqFinishedUnderwater(uint256 indexed lendingId);
    event LiqFinishedWithBuffer(uint256 indexed lendingId);
    event LiqUnsuccessful(uint256 indexed lendingId);
    event Recovery(uint256 indexed lendingId);
    event OracleGameFeesGrabbed(
        uint256 indexed lendingId, address indexed feeRecipient, uint256 feesSupply, uint256 feesBorrow
    );
    event TempHoldingWithdrawn(address indexed user, address indexed token, uint256 amount);

    // -------------------------------------------------------------------------
    //                              External functions
    // -------------------------------------------------------------------------

    /**
     * @notice Opens a new borrow request: locks `supplyAmount` of `supplyToken` and starts a Dutch-auction rate curve.
     * @dev    Lenders accept by calling `lend`; the rate they pay is `calcRate` evaluated at `block.timestamp`.
     *         Until accepted, the borrower may call `cancelBorrowRequest` to recover collateral.
     * @param  term Loan duration in seconds, bounded [1800, 1 year]. Measured from the moment a lender calls `lend`.
     * @param  supplyToken Address of the ERC20 supplied as collateral. Must differ from `borrowToken`.
     * @param  borrowToken Address of the ERC20 the borrower wants to borrow.
     * @param  liquidationThreshold Fraction in 1e7 fixed-point (8e6 = 80%). Liquidation becomes possible when
     *                              `borrowValue > liquidationThreshold * supplyAmount`. Bounded [7e6, 1e7].
     * @param  supplyAmount Collateral amount transferred from `msg.sender` into the contract on this call.
     * @param  amountDemanded Borrow amount requested. Pulled from the lender to the borrower at `lend` time.
     * @param  stake Liquidator stake fraction in 10000 fixed-point (100 = 1%). The liquidator wagers
     *               `stake * supplyAmount / 10000` of supplyToken on the liquidation succeeding.
     * @param  commitmentFraction 1e7 fixed-point. Close-out interest = `max(commitmentFraction × fullInterest / 1e7,
     *                            accruedInterest)`. Immutable for the loan's life.
     * @param  gasCompensation ETH escrowed to pay the lender who calls `lend` on this curve. Must equal `msg.value`.
     *                         Refunded to the borrower if the request is cancelled or the loan terminates with the
     *                         curve still open.
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
        OracleParams memory oracleParams,
        InterestRateParams memory interestRateParams
    ) external payable nonReentrant notBusy returns (uint256 lendingId) {
        uint256 currentTime = uint48(block.timestamp);

        if (supplyToken == borrowToken) revert InvalidInput("supply == borrow");
        if (liquidationThreshold > 1e7 || liquidationThreshold < 7e6) revert InvalidInput("LT out of bounds");
        if (stake > 10000) revert InvalidInput("stake too high");
        if (amountDemanded == 0) revert InvalidInput("cant borrow 0");
        if (supplyAmount == 0) revert InvalidInput("cant supply 0");
        if (term < 1800 || term > 60 * 60 * 24 * 365) revert InvalidInput("term out of bounds");
        if (supplyAmount + uint256(supplyAmount) * stake / 10000 > type(uint128).max) {
            revert InvalidInput("supply + stake too high");
        }
        if (msg.value != gasCompensation) revert InvalidInput("msg.value should be gasComp");
        if (commitmentFraction > 1e7) revert InvalidInput("commitment fraction too high");

        _validateOracleParams(oracleParams, supplyAmount);
        _validateInterestRateParams(interestRateParams);

        lendingId = nextLendingId++;
        LendingArrangement storage lending = lendingArrangements[lendingId];

        lending.term = term;
        lending.supplyToken = supplyToken;
        lending.borrowToken = borrowToken;
        lending.supplyAmount = supplyAmount;
        lending.liquidationThreshold = liquidationThreshold;
        lending.amountDemanded = amountDemanded;
        lending.stake = stake;
        lending.borrower = msg.sender;
        lending.oracleParams = oracleParams;
        lending.requestStart = uint48(currentTime);
        lending.interestRateParams = interestRateParams;
        lending.curveOpen = true;
        lending.commitmentFraction = commitmentFraction;
        lending.gasCompensation = gasCompensation;

        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), supplyAmount);

        emit BorrowRequested(
            msg.sender,
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
    function cancelBorrowRequest(uint256 lendingId) external nonReentrant notBusy {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        uint256 supplyAmount = lending.supplyAmount;

        if (lending.cancelled) revert InvalidInput("lendingId cancelled");
        if (lending.finished) revert InvalidInput("finished");
        if (lending.active) revert InvalidInput("lendingId active");
        if (lending.borrower != msg.sender) revert InvalidInput("msg.sender");

        lending.cancelled = true;
        _clearRefiCurve(lending);

        _sendGasComp(lending);
        IERC20(lending.supplyToken).safeTransfer(msg.sender, supplyAmount);

        emit BorrowRequestCancelled(msg.sender, lendingId);
    }

    /**
     * @notice Accepts the current rate on the borrow / refi curve. Single entrypoint for both origination and refinance.
     * @dev    Carries the `autoSettle` modifier, so a settleable pending liquidation is resolved before the body
     *         runs; if the resolution is unsuccessful the loan exits liquidation and lend can proceed against
     *         the post-settle state, including any virtual `requestStart` set to the report's settleable-at
     *         time. On origination, the lender funds the borrower with `amountDemanded` of borrowToken and the
     *         loan goes active. On refinance, the new lender pays off the previous lender (the close-out debt
     *         at the old rate/term/start, less anything already streamed back), funds any extra borrow the
     *         borrower requested, and returns any pulled collateral; per-loan state from the prior round
     *         (repaidDebt, gracePeriod, liquidator scratch fields) is reset, and the new term, rate, and start
     *         are taken from the refi params and the current block. The rate paid is whatever `calcRate`
     *         returns against `requestStart` at the current block. Reverts if the arrangement is cancelled,
     *         finished, still in liquidation after auto-settle, has no open curve, or (on the refi branch) is
     *         past maturity plus grace.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  paramHashExpected Optional loose paramHash (zeroes supplyAmount + repaidDebt before hashing). Set to
     *                           bytes32(0) to skip.
     * @param  minLendAmount Refi-only floor on the new principal. Set to 0 on origination (ignored).
     * @param  maxLendAmount Refi-only ceiling on the new principal. Set to type(uint128).max on origination (ignored).
     * @param  expectedMinSupply Reverts if `supplyAmount < expectedMinSupply`.
     * @param  minRate Reverts if the computed rate is below this floor.
     * @param  allowAnyLiquidator If true, anyone may later call `liquidate`; the liquidator splits equity 50/50 with the lender.
     *                            If false, only the lender may liquidate.
     */
    function lend(
        uint256 lendingId,
        bytes32 paramHashExpected,
        uint128 minLendAmount,
        uint128 maxLendAmount,
        uint128 expectedMinSupply,
        uint32 minRate,
        bool allowAnyLiquidator
    ) external nonReentrant notBusy autoSettle(lendingId) {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;
        address borrower = lending.borrower;
        address borrowToken = lending.borrowToken;
        address supplyToken = lending.supplyToken;
        uint256 rate = calcRate(lending.interestRateParams, lending.requestStart);
        address prevLender = lending.lender;
        uint48 prevTerm = lending.term;
        uint32 prevRate = lending.rate;
        uint48 prevStart = lending.start;
        uint256 borrowAmount = lending.borrowAmount;
        uint256 gasCompensation = lending.gasCompensation;

        if (lending.cancelled) revert InvalidInput("cancelled");
        if (lending.finished) revert InvalidInput("finished");
        if (lending.inLiquidation) revert InvalidInput("in liquidation");
        if (!lending.curveOpen) revert InvalidInput("no curve");
        if (lending.supplyAmount < expectedMinSupply) revert InvalidInput("min supply");
        if (lending.active && currentTime >= uint256(lending.start) + prevTerm + lending.gracePeriod) revert InvalidInput("expired");
        if (rate < minRate) revert InvalidInput("min rate");

        if (paramHashExpected != bytes32(0)) {
            _checkParamsLoose(lending, paramHashExpected);
        }

        lending.lender = msg.sender;
        lending.rate = uint32(rate);
        lending.start = uint48(currentTime);
        lending.curveOpen = false;
        lending.allowAnyLiquidator = allowAnyLiquidator;

        if (!lending.active) {
            // origination
            lending.active = true;
            lending.borrowAmount = lending.amountDemanded;
            lending.gasCompensation = 0;

            _payEth(msg.sender, gasCompensation);
            IERC20(borrowToken).safeTransferFrom(msg.sender, borrower, lending.amountDemanded);

            emit LoanOriginated(
                lendingId, msg.sender, lending.amountDemanded, rate, uint48(currentTime), prevTerm, uint96(gasCompensation), allowAnyLiquidator
            );
        } else {
            // refi
            OracleParams memory stagedOracleParams = lending.refiParams.oracleParams;
            uint256 owed = totalOwedClose(borrowAmount, prevRate, prevTerm, prevStart, lending.commitmentFraction);
            uint128 prevRepaidDebt = lending.repaidDebt;
            uint128 extraDemanded = lending.refiParams.extraDemanded;
            uint128 supplyPulled = lending.refiParams.supplyPulled;
            uint48 newTerm = lending.refiParams.newTerm;
            uint256 netTerminalDebtPrev = owed - prevRepaidDebt;
            uint256 newBorrowAmount = netTerminalDebtPrev + extraDemanded;

            if (newBorrowAmount < minLendAmount || newBorrowAmount > maxLendAmount) {
                revert InvalidInput("lend amount out of bounds");
            }

            if (stagedOracleParams.settlementTime != 0) {
                uint256 newSupplyAmount = uint256(lending.supplyAmount) - supplyPulled;
                uint256 newEscHalt =
                    newSupplyAmount * stagedOracleParams.escalationFactor / 100;
                if (newEscHalt > type(uint128).max) revert InvalidInput("new esc halt too high");
                lending.oracleParams = stagedOracleParams;
            }

            lending.borrowAmount = uint128(newBorrowAmount);
            lending.repaidDebt = 0;
            lending.gracePeriod = 0;
            lending.feeRecipient = address(0);
            lending.liquidator = address(0);
            lending.liquidationStart = 0;
            lending.term = newTerm;
            lending.supplyAmount -= supplyPulled;

            lending.gasCompensation = 0;
            _clearRefiCurve(lending);

            _payEth(msg.sender, gasCompensation);
            IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), newBorrowAmount);
            _transferTokens(borrowToken, address(this), prevLender, netTerminalDebtPrev);
            if (extraDemanded > 0) IERC20(borrowToken).safeTransfer(borrower, extraDemanded);
            if (supplyPulled > 0) IERC20(supplyToken).safeTransfer(borrower, supplyPulled);

            emit LoanRefinanced(
                lendingId,
                msg.sender,
                prevLender,
                newBorrowAmount,
                netTerminalDebtPrev,
                rate,
                uint48(currentTime),
                newTerm,
                extraDemanded,
                supplyPulled,
                uint96(gasCompensation),
                allowAnyLiquidator
            );
        }
    }

    /**
     * @notice Borrower-only repayment.
     * @dev    Partial repayments are streamed straight to the lender and credited against `repaidDebt`. If the
     *         payment covers the full remaining close-out debt (computed from the loan's commitmentFraction),
     *         the lender is paid that remainder and the borrower gets all the collateral back. Reverts during
     *         a live liquidation, after maturity plus grace, or once the loan is finished or cancelled.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  amount BorrowToken amount to apply against debt. May exceed `netTerminalDebt` (excess is not pulled).
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if `supplyAmount < expectedMinSupply`.
     * @param  expectedRepaidDebtMin Reverts if `repaidDebt < expectedRepaidDebtMin`.
     */
    function repayDebt(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedRepaidDebtMin
    ) external nonReentrant notBusy autoSettle(lendingId) {
        if (msg.sender != lendingArrangements[lendingId].borrower) revert InvalidInput("not borrower");
        _repayDebt(lendingId, amount, expectedParamHash, expectedMinSupply, expectedRepaidDebtMin);
    }

    /**
     * @notice Permissionless variant of `repayDebt`: anyone can repay any loan's debt.
     * @dev    Same gating and parameters as `repayDebt`. The third party puts up the borrowToken.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  amount BorrowToken amount to apply against debt.
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if `supplyAmount < expectedMinSupply`.
     * @param  expectedRepaidDebtMin Reverts if `repaidDebt < expectedRepaidDebtMin`.
     */
    function repayAnyDebt(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedRepaidDebtMin
    ) external nonReentrant notBusy autoSettle(lendingId) {
        _repayDebt(lendingId, amount, expectedParamHash, expectedMinSupply, expectedRepaidDebtMin);
    }

    /**
     * @notice Borrower-only collateral top-up. Pulls additional supplyToken into the contract.
     * @dev    Reverts during liquidation, after maturity, or once the loan is finished or cancelled.
     *         Re-checks the supply + stake and escalationHalt overflow bounds against the post-top-up amount.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  amount SupplyToken amount to add to collateral.
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if current `supplyAmount < expectedMinSupply`.
     * @param  expectedRepaidDebtMin Reverts if `repaidDebt < expectedRepaidDebtMin`.
     */
    function topUpCollateral(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedRepaidDebtMin
    ) external nonReentrant notBusy autoSettle(lendingId) {
        if (msg.sender != lendingArrangements[lendingId].borrower) revert InvalidInput("not borrower");
        _topUpCollateral(lendingId, amount, expectedParamHash, expectedMinSupply, expectedRepaidDebtMin);
    }

    /**
     * @notice Permissionless variant of `topUpCollateral`: anyone can add collateral on behalf of any loan.
     * @dev    Same gating and parameters as `topUpCollateral`. The third party puts up the supplyToken.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  amount SupplyToken amount to add to collateral.
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if current `supplyAmount < expectedMinSupply`.
     * @param  expectedRepaidDebtMin Reverts if `repaidDebt < expectedRepaidDebtMin`.
     */
    function topUpCollateralAnyone(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedRepaidDebtMin
    ) external nonReentrant notBusy autoSettle(lendingId) {
        _topUpCollateral(lendingId, amount, expectedParamHash, expectedMinSupply, expectedRepaidDebtMin);
    }

    /**
     * @notice Forfeits the collateral to the lender once the loan has expired without being repaid or
     *         refinanced. Anyone can call; the funds always go to the lender.
     * @dev    Reverts if the loan is still within its term plus grace period, or if it's cancelled, finished,
     *         not active, or in liquidation. The grace period is non-zero only when a failed liquidation
     *         finished too close to or past maturity.
     * @param  lendingId Unique identifier of the lending arrangement.
     */
    function claimCollateral(uint256 lendingId) external nonReentrant notBusy {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;
        address lender = lending.lender;
        uint128 supplyAmount = lending.supplyAmount;

        if (lending.inLiquidation) revert InvalidInput("in liquidation");
        if (lending.finished) revert InvalidInput("arrangement finished");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (currentTime < uint256(lending.start) + lending.term + lending.gracePeriod) {
            revert InvalidInput("not expired");
        }

        lending.finished = true;
        _clearRefiCurve(lending);

        _sendGasComp(lending);
        IERC20(lending.supplyToken).safeTransfer(lender, supplyAmount);

        emit CollateralClaimedByLender(lendingId, supplyAmount);
    }

    /**
     * @notice Borrower opens a refinance: re-opens the rate curve so any lender can roll the loan, optionally
     *         drawing extra borrow, returning some collateral, or changing the term.
     * @dev    Stages the refi parameters and marks the curve open; the actual roll happens when a lender
     *         calls `lend`. Outside liquidation, `requestStart` is set to `block.timestamp` so the curve
     *         starts ticking immediately. During liquidation the curve is parked: `requestStart` is left at
     *         zero and only gets populated later, when an unsuccessful liquidation settles and `onSettle`
     *         (or `recover`) writes the report's settleable-at time. New oracle params (when supplied) are
     *         validated now and become the loan's oracle config at lend time. Allowed during a live
     *         liquidation; the maturity-plus-grace expiry check is skipped in that case. Only the borrower
     *         can call, only on an active loan with a closed curve. Emits `RefiOpenedDuringLiquidation` when
     *         called mid-liquidation, `RefiOpened` otherwise.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  extraDemanded Additional borrowToken pulled to the borrower at lend-time (on top of rolling debt).
     * @param  supplyPulled SupplyToken returned to the borrower at lend-time. Must be < current `supplyAmount`.
     * @param  newTerm New term in seconds for the post-refi loan, or 0 to keep the existing term. If non-zero,
     *                 bounded [1800, 1 year]; same range as origination.
     * @param  gasCompensation ETH escrowed to pay the lender who accepts the refi. Must equal `msg.value`. Refunded
     *                         to the borrower if the refi is cancelled or the loan terminates with the curve open.
     * @param  interestRateParams New curve parameters governing the refi auction.
     * @param  oracleParams Optional new oracle params for the post-refi loan. Pass `settlementTime = 0` to keep
     *                      the existing config; otherwise validated and applied at lend acceptance.
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if `supplyAmount < expectedMinSupply`.
     * @param  expectedRepaidDebtMin Reverts if `repaidDebt < expectedRepaidDebtMin`.
     */
    function refinance(
        uint256 lendingId,
        uint128 extraDemanded,
        uint128 supplyPulled,
        uint48 newTerm,
        uint96 gasCompensation,
        InterestRateParams memory interestRateParams,
        OracleParams memory oracleParams,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedRepaidDebtMin
    ) external payable nonReentrant notBusy autoSettle(lendingId) {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        RefiParams storage refiParams = lending.refiParams;

        uint256 currentTime = block.timestamp;
        uint256 supplyAmount = lending.supplyAmount;

        if (msg.sender != lending.borrower) revert InvalidInput("not borrower");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.finished) revert InvalidInput("finished");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (lending.curveOpen) revert InvalidInput("curve is open");

        if (supplyPulled >= supplyAmount) revert InvalidInput("supplyPulled too high");
        if (oracleParams.settlementTime != 0) {
            _validateOracleParams(oracleParams, supplyAmount - supplyPulled);
        }
        _validateInterestRateParams(interestRateParams);

        if (lending.repaidDebt < expectedRepaidDebtMin) revert InvalidInput("repaid debt too low");
        if (lending.supplyAmount < expectedMinSupply) revert InvalidInput("supply too low");
        if (newTerm != 0 && (newTerm < 1800 || newTerm > 60 * 60 * 24 * 365)) revert InvalidInput("term out of bounds");
        if (!lending.inLiquidation && currentTime >= uint256(lending.start) + lending.term + lending.gracePeriod) revert InvalidInput("expired");
        if (msg.value != gasCompensation) revert InvalidInput("msg.value should be gasComp");
        if (expectedParamHash != bytes32(0)) {
            _checkParamsLoose(lending, expectedParamHash);
        }

        refiParams.extraDemanded = extraDemanded;
        refiParams.supplyPulled = supplyPulled;
        refiParams.newTerm = newTerm == 0 ? lending.term : newTerm;
        lending.curveOpen = true;
        if (!lending.inLiquidation) {
            lending.requestStart = uint48(currentTime);
        }
        lending.interestRateParams = interestRateParams;
        lending.gasCompensation = gasCompensation;
        if (oracleParams.settlementTime != 0) refiParams.oracleParams = oracleParams;

        OracleParams memory oracleParamsMem = oracleParams.settlementTime != 0 ? oracleParams : lending.oracleParams;

        if (lending.inLiquidation) {
            emit RefiOpenedDuringLiquidation(lendingId, extraDemanded, supplyPulled, refiParams.newTerm, gasCompensation, oracleParamsMem, interestRateParams);
        } else {
            emit RefiOpened(lendingId, extraDemanded, supplyPulled, refiParams.newTerm, gasCompensation, oracleParamsMem, interestRateParams);
        }
    }

    /**
     * @notice Closes an open refi curve before any lender has accepted. Restores the loan to its pre-refi state.
     * @dev    Borrower-only. Clears the staged refi params and refunds the staged gasCompensation. The live
     *         underlying loan's rate, term, and start are untouched.
     * @param  lendingId Unique identifier of the lending arrangement.
     */
    function cancelRefinance(uint256 lendingId) external nonReentrant notBusy autoSettle(lendingId) {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        if (msg.sender != lending.borrower) revert InvalidInput("not borrower");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.finished) revert InvalidInput("finished");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (!lending.curveOpen) revert InvalidInput("curve is not open");

        _clearRefiCurve(lending);

        _sendGasComp(lending);

        emit RefiCancelled(lendingId);
    }

    /**
     * @notice Initiates a liquidation by spawning an openOracle price report. The liquidator wagers
     *         `stake * supplyAmount / 10000` of supplyToken that the oracle will resolve to an underwater price.
     * @dev    The liquidator transfers initial liquidity for both sides of the oracle report (supplyToken as
     *         token1, borrowToken as token2 sized by `priceRatio`) plus the stake, and pays `1e15` wei as the
     *         openOracle settler reward. While the report is open the loan is in liquidation: the borrower
     *         cannot repay or top up. Resolution happens in `onSettle`: if the oracle resolves underwater the
     *         liquidator recovers the stake plus half of any equity buffer and the lender receives the rest of
     *         the collateral; otherwise the stake is forfeit. If resolution lands more than 30 minutes before
     *         maturity, the full stake goes to the borrower (added to supplyAmount). If it lands within the
     *         last 30 minutes of the term or after maturity, a grace period is granted to give the borrower
     *         time to react and the stake is split: half to the lender as compensation for the deferred
     *         payoff, the rest added to supplyAmount. Only the lender can call unless `allowAnyLiquidator`
     *         was set at lend time. Reverts if the loan is already in liquidation, finished, cancelled, past
     *         maturity, or sitting in a grace period left over from a prior failed liquidation.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  priceRatio borrowToken-per-supplyToken in 1e18 fixed-point. Used to compute the report's token2 side.
     * @param  maxInitialLiquidity Cap on `initialLiquidity` (= `supplyAmount × oracleParams.initialLiquidity / 100`).
     * @param  paramHashExpected Loose paramHash. Required.
     * @param  worstRatio Reverts if `1e18 * netBorrow / supplyAmount < worstRatio`.
     */
    function liquidate(
        uint256 lendingId,
        uint256 priceRatio,
        uint128 maxInitialLiquidity,
        bytes32 paramHashExpected,
        uint256 worstRatio
    ) external payable nonReentrant notBusy {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        OracleParams storage oracleParams = lending.oracleParams;

        uint256 currentTime = block.timestamp;
        uint48 start = lending.start;
        uint128 supplyAmount = lending.supplyAmount;
        address borrowToken = lending.borrowToken;
        address supplyToken = lending.supplyToken;
        uint128 repaidDebt = lending.repaidDebt;
        address feeRecipient;
        uint256 tokenStake = uint256(supplyAmount) * lending.stake / 10000;
        uint256 initialLiquidity = uint256(supplyAmount) * oracleParams.initialLiquidity / 100;
        uint256 oracleAmount2 = initialLiquidity * priceRatio / 1e18;
        uint256 escHalt = uint256(supplyAmount) * oracleParams.escalationFactor / 100;
        uint256 borrowValue = totalOwedNow(lending.borrowAmount, lending.rate, lending.term, start);

        if (borrowValue <= repaidDebt) revert InvalidInput("no net borrow");
        borrowValue -= repaidDebt;
        uint256 ratio = Math.mulDiv(1e18, borrowValue, supplyAmount);

        if (lending.inLiquidation) revert InvalidInput("in liquidation");
        if (lending.finished) revert InvalidInput("arrangement finished");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (!lending.allowAnyLiquidator && msg.sender != lending.lender) revert InvalidInput("wrong liquidator");
        if (msg.value != 1e15) revert InvalidInput("msg.value != 1e15");
        if (currentTime > uint256(start) + lending.term) revert InvalidInput("arrangement expired");
        if (lending.gracePeriod != 0) revert InvalidInput("in grace period");
        if (oracleAmount2 > type(uint128).max) revert InvalidInput("amount2 too large");
        if (escHalt > type(uint128).max) revert InvalidInput("escHalt too large");
        if (tokenStake + supplyAmount > type(uint128).max) revert InvalidInput("tokenStake + supplyAmount too large");
        if (ratio < worstRatio) revert InvalidInput("position too healthy");
        if (initialLiquidity > maxInitialLiquidity) revert InvalidInput("too much oracle game initial liquidity");
        _checkParamsLoose(lending, paramHashExpected);

        lending.requestStart = 0;

        if (oracleParams.oracleGameFee > 0) {
            feeRecipient = _deployFeeReceiver(lendingId, supplyToken, borrowToken);
            lending.feeRecipient = feeRecipient;
        }

        IOpenOracle.CreateReportParams memory params = _buildLiquidationReportParams(
            oracleParams, supplyToken, borrowToken, uint128(initialLiquidity), uint128(escHalt), feeRecipient
        );

        lending.inLiquidation = true;
        lending.liquidationStart = uint48(currentTime);
        lending.liquidator = msg.sender;

        if (feeRecipient != address(0)) {
            lendingBeneficiaries[lendingId][feeRecipient].lender = lending.lender;
            lendingBeneficiaries[lendingId][feeRecipient].liquidator = msg.sender;
        }

        uint256 reportId = oracle.createReportInstance{value: msg.value}(params);

        reportIdToLending[reportId] = lendingId;
        lendingToReportId[lendingId] = reportId;

        uint256 amount1 = initialLiquidity;

        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), amount1 + tokenStake);
        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), oracleAmount2);

        _ensureOracleApproval(supplyToken);
        _ensureOracleApproval(borrowToken);

        oracle.submitInitialReport(
            reportId, uint128(amount1), uint128(oracleAmount2), oracle.extraData(reportId).stateHash, msg.sender
        );

        emit LoanLiquidationUnderway(lendingId, reportId, feeRecipient);
    }

    /**
     * @notice openOracle settlement callback. Finalizes a pending liquidation based on the resolved price.
     * @dev    Only callable by the configured `oracle` contract. Branches on whether the resolved price puts the
     *         loan underwater (`borrowValueInSupplyTerms > liqThresh`):
     *           - Underwater: marks the loan finished. If equity is fully consumed, lender gets all collateral and
     *             liquidator gets just the stake. If a buffer remains, lender gets borrowValueInSupplyTerms + half
     *             the buffer; liquidator gets the other half plus the stake. (Any prior partial repayments are
     *             already in the lender's wallet from streaming, not paid out here.)
     *           - Not underwater: liquidator's stake is forfeit. If the curve is open, `requestStart` is reset
     *             to the moment the report became settleable to keep the rate auction honest. If resolution
     *             lands within the last 30 minutes of the term or after maturity, a grace period is granted
     *             to the borrower and the stake is split — half routed to the lender as compensation for the
     *             deferred payoff, the rest added to `supplyAmount`. Otherwise the full stake goes to
     *             `supplyAmount`.
     *         Distributes any oracle game protocol fees via `_grabOracleGameFees`.
     * @param  id The openOracle reportId that just settled (used to look up the lendingId).
     */
    function onSettle(uint256 id, uint256, uint256, address, address)
        external
        payable
        busyLock
    {
        if (msg.sender != address(oracle)) revert InvalidInput("invalid sender");
        uint256 lendingId = reportIdToLending[id];
        if (lendingId == 0) revert InvalidInput("no lendingId for reportId");

        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint48 start = lending.start;
        uint48 term = lending.term;
        uint128 repaidDebt = lending.repaidDebt;
        uint128 supplyAmount = lending.supplyAmount;
        address lender = lending.lender;
        address supplyToken = lending.supplyToken;
        address borrowToken = lending.borrowToken;
        address liquidator = lending.liquidator;
        uint256 borrowValue = totalOwedNow(lending.borrowAmount, lending.rate, term, start);
        address feeRecipient = lending.feeRecipient;

        if (borrowValue > repaidDebt) {
            borrowValue -= repaidDebt;
        } else {
            borrowValue = 0;
        }

        IOpenOracle.ReportStatus memory rs = oracle.reportStatus(id);
        uint256 oracleAmount1 = rs.currentAmount1;
        uint256 oracleAmount2 = rs.currentAmount2;
        uint256 tokenStake = uint256(supplyAmount) * lending.stake / 10000;
        uint256 borrowValueInSupplyTerms = Math.mulDiv(borrowValue, oracleAmount1, oracleAmount2);
        uint256 liqThresh = uint256(supplyAmount) * lending.liquidationThreshold / 1e7;

        lending.inLiquidation = false;
        reportIdToLending[id] = 0;
        lendingToReportId[lendingId] = 0;
        if (liqThresh < borrowValueInSupplyTerms) {
            lending.finished = true;
            _clearRefiCurve(lending);

            if (borrowValueInSupplyTerms > supplyAmount) {
                _sendGasComp(lending);
                _transferTokens(supplyToken, address(this), lender, supplyAmount);
                _transferTokens(supplyToken, address(this), liquidator, tokenStake);

                emit LiqFinishedUnderwater(lendingId);
            } else {
                uint256 buffer = supplyAmount - borrowValueInSupplyTerms;
                uint256 lenderPiece = buffer / 2;
                uint256 liquidatorPiece = buffer - lenderPiece;

                _sendGasComp(lending);
                _transferTokens(supplyToken, address(this), lender, borrowValueInSupplyTerms + lenderPiece);
                _transferTokens(supplyToken, address(this), liquidator, liquidatorPiece + tokenStake);

                emit LiqFinishedWithBuffer(lendingId);
            }
        } else {

            uint256 settleableAt = oracle.reportStatus(id).reportTimestamp + oracle.reportMeta(id).settlementTime;

            if (lending.curveOpen) {
                lending.requestStart = uint48(settleableAt);
            }

            // grace period around liquidations that end either too close to maturity (30 minutes) or after it.
            // When grace fires, half the stake routes to the lender.
            if (settleableAt > uint256(start) + term - 1800) {
                lending.gracePeriod = uint48(1800 + (settleableAt - lending.liquidationStart) * 2);

                uint256 lenderStakePiece = tokenStake / 2;
                lending.supplyAmount += uint128(tokenStake - lenderStakePiece);
                _transferTokens(supplyToken, address(this), lender, lenderStakePiece);
            } else {
                lending.supplyAmount += uint128(tokenStake);
            }

            lending.liquidationStart = 0;
            lending.liquidator = address(0);
            lending.feeRecipient = address(0);

            emit LiqUnsuccessful(lendingId);
        }

        if (feeRecipient != address(0)) {
            _grabOracleGameFees(lending, feeRecipient, lendingId);
        }
    }

    /**
     * @notice Permissionless resolver for a liquidation whose oracle settlement callback reverted.
     * @dev    OpenOracle's `settle` invokes the callback through a low-level call and does not revert on
     *         failure, so a reverting `onSettle` leaves the report settled on the oracle side while the loan
     *         remains stuck in liquidation. This function unwinds that stuck state, treating the outcome as an
     *         unsuccessful liquidation regardless of what the oracle actually resolved to: the liquidator gets
     *         their full stake back, any open refi curve has its rate-curve clock reset, a grace period is
     *         granted on the same near-maturity rule as a normal failed liquidation, any accumulated
     *         oracle-game protocol fees are distributed, and the lender keeps the loan to either re-liquidate
     *         or ride to maturity and call `claimCollateral`. Unlike `onSettle`'s failed-liq branch, this path
     *         does not split the stake when grace fires — recovery is treated as "callback failed, undo cleanly,"
     *         not as a liquidation outcome that should compensate the lender for delay.
     * @param  reportId The openOracle reportId whose settlement callback failed. Indexers can find this in the
     *                  `LoanLiquidationUnderway(lendingId, reportId, feeRecipient)` event emitted at `liquidate` time.
     */
    function recover(uint256 reportId) external nonReentrant busyLock {
        uint256 lendingId = reportIdToLending[reportId];
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 tokenStake = uint256(lending.supplyAmount) * lending.stake / 10000;
        address liquidator = lending.liquidator;
        address feeRecipient = lending.feeRecipient;
        uint256 settleableAt = oracle.reportStatus(reportId).reportTimestamp + oracle.reportMeta(reportId).settlementTime;

        if (lendingId == 0) revert InvalidInput("no lendingId for reportId");
        if (lending.finished) revert InvalidInput("finished");
        if (!lending.inLiquidation) revert InvalidInput("not in liquidation");
        if (oracle.reportStatus(reportId).settlementTimestamp == 0) revert InvalidInput("no oracle settlement");

        if (settleableAt > uint256(lending.start) + lending.term - 1800) {
            lending.gracePeriod = uint48(1800 + (settleableAt - lending.liquidationStart) * 2);
        }

        if (lending.curveOpen) {
            lending.requestStart = uint48(settleableAt);
        }

        lending.inLiquidation = false;
        lending.liquidationStart = 0;
        reportIdToLending[reportId] = 0;
        lendingToReportId[lendingId] = 0;
        lending.liquidator = address(0);
        lending.feeRecipient = address(0);

        _transferTokens(lending.supplyToken, address(this), liquidator, tokenStake);
    
        if (feeRecipient != address(0)) {
            _grabOracleGameFees(lending, feeRecipient, lendingId);
        }

        emit Recovery(lendingId);

    }

    /**
     * @notice Distributes any protocol fees that have accrued in a feeRecipient clone but haven't been swept.
     *         Permissionless backstop in case `onSettle`'s sweep missed something.
     * @dev    Splits the swept fees 50% to the borrower, 25% to the lender, 25% to the liquidator. Reverts if
     *         the feeRecipient was not the one deployed for this lendingId.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  feeRecipient Address of the fee receiver clone deployed in `liquidate`.
     */
    function grabOracleGameFeesAny(uint256 lendingId, address feeRecipient) external nonReentrant busyLock {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        if (feeRecipient == address(0)) revert InvalidInput("no fee recipient");
        if (oracleFeeReceiver(feeRecipient).gameId() != lendingId) {
            revert InvalidInput("feeRecipient not for lendingId");
        }
        _grabOracleGameFees(lending, feeRecipient, lendingId);
    }

    /**
     * @notice Permissionless settler for the oracle report tied to a loan. No-op if no report is pending,
     *         the report isn't yet eligible to settle, or the report has already been settled. On success,
     *         forwards the oracle's settler reward to msg.sender.
     * @dev    Useful when the post-settle state would cause an autoSettle entrypoint's body to revert and
     *         unwind the settle along with it (an underwater resolution finishes the loan, which then makes
     *         `repayDebt` and friends revert on the finished check). Since this entrypoint has no body after
     *         the settle, the settlement always persists once the oracle accepts it.
     * @param  lendingId Unique identifier of the lending arrangement.
     */
    function settleLiquidation(uint256 lendingId) external nonReentrant notBusy {
        _settleHelper(lendingId);
    }

    /**
     * @notice Withdraws any tokens held for the caller in the `tempHolding` escrow.
     * @dev    Tokens land in `tempHolding` whenever an outgoing transfer from the contract fails (for example,
     *         when the recipient is blacklisted by the token). The rightful recipient can retry later through
     *         this entrypoint; if the retry also fails, the amount is re-credited to `tempHolding`.
     * @param  tokenToGet ERC20 to withdraw.
     */
    function getTempHolding(address tokenToGet) external nonReentrant notBusy {
        uint256 amount = tempHolding[msg.sender][tokenToGet];
        if (amount > 0) {
            tempHolding[msg.sender][tokenToGet] = 0;
            _transferTokens(tokenToGet, address(this), msg.sender, amount);
            emit TempHoldingWithdrawn(msg.sender, tokenToGet, amount);
        }
    }

    // -------------------------------------------------------------------------
    //                              Internal functions
    // -------------------------------------------------------------------------

    /// @dev Shared body of `repayDebt` and `repayAnyDebt`. Either closes the loan (when the payment covers the
    ///      remaining close-out debt) or streams the partial to the lender and credits it against `repaidDebt`.
    function _repayDebt(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedRepaidDebtMin
    ) internal {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;
        uint256 borrowAmount = lending.borrowAmount;
        uint256 rate = lending.rate;
        uint256 term = lending.term;
        uint256 repaid = lending.repaidDebt;
        uint256 owed = totalOwedClose(borrowAmount, rate, term, lending.start, lending.commitmentFraction);
        address lender = lending.lender;
        address borrower = lending.borrower;
        uint256 supplied = lending.supplyAmount;
        uint256 netTerminalDebt = owed - repaid;
        address borrowToken = lending.borrowToken;

        if (lending.inLiquidation) revert InvalidInput("in liquidation");
        if (lending.finished) revert InvalidInput("arrangement finished");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (currentTime >= lending.start + term + lending.gracePeriod) revert InvalidInput("expired");
        if (repaid < expectedRepaidDebtMin) revert InvalidInput("repaid debt too low");
        if (supplied < expectedMinSupply) revert InvalidInput("supply too low");
        if (expectedParamHash != bytes32(0)) {
            _checkParamsLoose(lending, expectedParamHash);
        }

        if (amount >= netTerminalDebt) {
            lending.finished = true;
            _clearRefiCurve(lending);

            _sendGasComp(lending);
            IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), netTerminalDebt);
            _transferTokens(borrowToken, address(this), lender, netTerminalDebt);
            IERC20(lending.supplyToken).safeTransfer(borrower, supplied);
            emit DebtRepaid(lendingId, msg.sender, netTerminalDebt, true);
        } else {
            lending.repaidDebt += amount;

            IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);
            _transferTokens(borrowToken, address(this), lender, amount);
            emit DebtRepaid(lendingId, msg.sender, amount, false);
        }
    }

    /// @dev Shared body of `topUpCollateral` and `topUpCollateralAnyone`. Re-checks the supply + stake and
    ///      escalationHalt overflow bounds against the post-top-up total before pulling the collateral in.
    function _topUpCollateral(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedRepaidDebtMin
    ) internal {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;
        uint256 supplyAmount = uint256(lending.supplyAmount) + amount;
        uint256 escHalt = supplyAmount * lending.oracleParams.escalationFactor / 100;

        if (lending.inLiquidation) revert InvalidInput("in liquidation");
        if (lending.finished) revert InvalidInput("arrangement finished");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (supplyAmount + supplyAmount * lending.stake / 10000 > type(uint128).max) {
            revert InvalidInput("supply amount + stake");
        }
        if (escHalt > type(uint128).max) revert InvalidInput("escalation halt too high");
        if (currentTime >= uint256(lending.start) + lending.term) revert InvalidInput("expired");
        if (lending.repaidDebt < expectedRepaidDebtMin) revert InvalidInput("repaid debt too low");
        if (lending.supplyAmount < expectedMinSupply) revert InvalidInput("supply too low");
        if (expectedParamHash != bytes32(0)) {
            _checkParamsLoose(lending, expectedParamHash);
        }

        lending.supplyAmount += amount;

        IERC20(lending.supplyToken).safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralToppedOff(lendingId, msg.sender, amount);
    }

    /// @dev Reverts unless the keccak256 of the on-chain arrangement (with `supplyAmount` and `repaidDebt`
    ///      zeroed in the preimage) matches the caller-supplied hash.
    function _checkParamsLoose(LendingArrangement storage lending, bytes32 paramHashExpected) internal view {
        LendingArrangement memory copy = lending;
        copy.supplyAmount = 0;
        copy.repaidDebt = 0;
        if (paramHashExpected != keccak256(abi.encode(copy))) revert InvalidInput("params");
    }

    /// @dev Grants the oracle infinite allowance on the given token the first time it's needed. Subsequent
    ///      calls are no-ops.
    function _ensureOracleApproval(address token) internal {
        if (!_oracleApproved[token]) {
            IERC20(token).forceApprove(address(oracle), type(uint256).max);
            _oracleApproved[token] = true;
        }
    }

    /// @dev Deploys a per-liquidation fee receiver clone. The oracle pays its protocol fees to the clone, and
    ///      this contract later sweeps them and distributes them across borrower, lender, and liquidator.
    function _deployFeeReceiver(uint256 lendingId, address supplyToken, address borrowToken)
        internal
        returns (address feeReceiver)
    {
        feeReceiver = Clones.clone(feeReceiverImpl);
        oracleFeeReceiver(feeReceiver).initialize(
            address(this), uint128(lendingId), address(oracle), supplyToken, borrowToken
        );
    }

    /// @dev Builds the openOracle CreateReportParams struct used when spawning a liquidation report.
    function _buildLiquidationReportParams(
        OracleParams storage oracleParams,
        address supplyToken,
        address borrowToken,
        uint128 initialLiquidity,
        uint128 escHalt,
        address feeRecipient
    ) internal view returns (IOpenOracle.CreateReportParams memory params) {
        params = IOpenOracle.CreateReportParams({
            exactToken1Report: initialLiquidity,
            escalationHalt: escHalt,
            settlerReward: 1e15,
            token1Address: supplyToken,
            settlementTime: oracleParams.settlementTime,
            disputeDelay: oracleParams.disputeDelay,
            protocolFee: oracleParams.oracleGameFee,
            token2Address: borrowToken,
            callbackGasLimit: 2000000,
            feePercentage: 0,
            multiplier: oracleParams.multiplier,
            timeType: true,
            trackDisputes: false,
            callbackContract: address(this),
            callbackSelector: this.onSettle.selector,
            protocolFeeRecipient: feeRecipient
        });
    }

    /// @dev Sweeps any accumulated fees out of the feeRecipient clone (in both supply and borrow tokens) and
    ///      splits the haul 50% to the borrower, 25% to the lender, and 25% to the liquidator.
    function _grabOracleGameFees(LendingArrangement storage lending, address feeRecipient, uint256 lendingId)
        internal
    {
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(feeRecipient);

        address supplyToken = lending.supplyToken;
        address borrowToken = lending.borrowToken;

        try feeReceiver.collect() {} catch {}

        uint256 supplyBalanceStart = IERC20(supplyToken).balanceOf(address(this));
        try feeReceiver.sweep(supplyToken) {} catch {}
        uint256 supplyBalanceEnd = IERC20(supplyToken).balanceOf(address(this));
        uint256 feesSupply = supplyBalanceEnd > supplyBalanceStart ? supplyBalanceEnd - supplyBalanceStart : 0;

        uint256 borrowBalanceStart = IERC20(borrowToken).balanceOf(address(this));
        try feeReceiver.sweep(borrowToken) {} catch {}
        uint256 borrowBalanceEnd = IERC20(borrowToken).balanceOf(address(this));
        uint256 feesBorrow = borrowBalanceEnd > borrowBalanceStart ? borrowBalanceEnd - borrowBalanceStart : 0;

        uint256 borrowerSupplyFeePiece = feesSupply / 2;
        uint256 lenderSupplyFeePiece = borrowerSupplyFeePiece / 2;
        uint256 liquidatorSupplyFeePiece = feesSupply - borrowerSupplyFeePiece - lenderSupplyFeePiece;

        address borrower = lending.borrower;
        address lender = lendingBeneficiaries[lendingId][feeRecipient].lender;
        address liquidator = lendingBeneficiaries[lendingId][feeRecipient].liquidator;

        _transferTokens(supplyToken, address(this), borrower, borrowerSupplyFeePiece);
        _transferTokens(supplyToken, address(this), lender, lenderSupplyFeePiece);
        _transferTokens(supplyToken, address(this), liquidator, liquidatorSupplyFeePiece);

        uint256 borrowerBorrowFeePiece = feesBorrow / 2;
        uint256 lenderBorrowFeePiece = borrowerBorrowFeePiece / 2;
        uint256 liquidatorBorrowFeePiece = feesBorrow - borrowerBorrowFeePiece - lenderBorrowFeePiece;

        _transferTokens(borrowToken, address(this), borrower, borrowerBorrowFeePiece);
        _transferTokens(borrowToken, address(this), lender, lenderBorrowFeePiece);
        _transferTokens(borrowToken, address(this), liquidator, liquidatorBorrowFeePiece);

        emit OracleGameFeesGrabbed(lendingId, feeRecipient, feesSupply, feesBorrow);
    }

    /**
     * @dev Token transfer with a fallback to per-recipient escrow. When sending from this contract, treats
     *      both standard bool-true returns and bare empty returns from a contract token as success; on any
     *      other outcome the amount is credited to `tempHolding` so the recipient can pull it later via
     *      `getTempHolding`. Transfers from a third-party use the standard SafeERC20 path with no fallback.
     */
    function _transferTokens(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return; // Gas optimization: skip zero transfers

        if (from == address(this)) {
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
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
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

    /// @dev Settles the oracle report tied to this loan if one is pending and eligible, then forwards the
    ///      settler reward to msg.sender. No-op when the loan is not in liquidation, when no report is
    ///      pending, when the report is not yet eligible to settle, or when it has already been settled.
    ///      Wrapped in try/catch so a reverting `oracle.settle` callback doesn't bubble out of this helper —
    ///      the calling entrypoint's body still runs (and may itself revert and roll back the whole tx,
    ///      including any settle effects). If the callback is the thing that reverted, the loan can be
    ///      resolved via `recover()`.
    function _settleHelper(uint256 lendingId) internal {
        if (!lendingArrangements[lendingId].inLiquidation) return;

        uint256 reportId = lendingToReportId[lendingId];
        uint256 currentTime = block.timestamp;
        if (reportId == 0) return;

        IOpenOracle.ReportStatus memory rs = oracle.reportStatus(reportId);
        if (rs.reportTimestamp == 0) return;
        if (rs.settlementTimestamp != 0) return;

        IOpenOracle.ReportMeta memory meta = oracle.reportMeta(reportId);
        if (currentTime < uint256(rs.reportTimestamp) + meta.settlementTime) return;

        bool settled;
        try oracle.settle(reportId) {
            settled = true;
        } catch {}

        if (settled && meta.settlerReward > 0) {
            _payEth(msg.sender, meta.settlerReward);
        }
    }

    /// @dev Validates `InterestRateParams`. All fields must be non-zero, the max rate must be at least the
    ///      starting rate and at most 1e10, the growth rate must exceed 10000 (i.e. strictly rising), and
    ///      maxRounds is capped at 100.
    function _validateInterestRateParams(InterestRateParams memory ir) internal pure {
        if (
            ir.maxRate == 0 || ir.startingRate == 0 || ir.growthRate == 0 || ir.maxRounds == 0 || ir.roundLength == 0
                || ir.maxRate < ir.startingRate || ir.maxRate > 1e10 || ir.growthRate <= 10000 || ir.maxRounds > 100
        ) revert InvalidInput("interestRateParams");
    }

    function _validateOracleParams(OracleParams memory op, uint256 supplyAmount) internal pure {
        uint256 settlementTime = op.settlementTime;
        uint256 escalationFactor = op.escalationFactor;
        uint256 initialLiquidity = op.initialLiquidity;
        uint256 multiplier = op.multiplier;
        uint256 escHalt = uint256(supplyAmount) * escalationFactor / 100;

        if (
            settlementTime < 120 || settlementTime > 60 * 60 * 4 || escalationFactor < 10 || escalationFactor > 1000
                || initialLiquidity < 10 || initialLiquidity > 200 || escalationFactor < initialLiquidity 
                || escHalt > type(uint128).max || op.oracleGameFee > 1e6 || multiplier < 100 || multiplier > 1000
                || op.disputeDelay >= settlementTime
        ) revert InvalidInput("oracleParams");
    }

    /// @dev Evaluates the rising rate curve at the current block. The number of elapsed rounds is the time
    ///      since `requestStart` divided by `roundLength`, capped at `maxRounds`; the rate compounds by
    ///      `growthRate / 10000` each round and is capped at `maxRate`.
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

    /// @dev Returns principal plus prorated interest accrued from `start` until now, with elapsed time capped
    ///      at the loan's term so post-maturity interest does not keep accruing.
    /// @param amount Principal at origination/refi.
    /// @param rate Annualized rate in 1e9 fixed-point.
    /// @param term Loan term in seconds.
    /// @param start Loan start timestamp.
    /// @return Principal plus interest accrued from `start` until `min(now, start + term)`.
    function totalOwedNow(uint256 amount, uint256 rate, uint256 term, uint256 start) internal view returns (uint256) {
        uint256 currentTime = block.timestamp;
        uint256 interest;
        uint256 year = 365 * 24 * 60 * 60;
        uint256 elapsed = currentTime > start ? currentTime - start : 0;
        if (elapsed > term) elapsed = term;
        interest = amount * elapsed * rate / (1e9 * year);
        return amount + interest;
    }

    function totalOwedClose(uint256 amount, uint256 rate, uint256 term, uint256 start, uint256 commitmentFraction)
        internal view returns (uint256)
    {
        uint256 currentTime = block.timestamp;
        uint256 elapsed = currentTime > start ? currentTime - start : 0;
        if (elapsed > term) elapsed = term;
        uint256 commitWindow = term * commitmentFraction / 1e7;
        uint256 effectiveElapsed = elapsed < commitWindow ? commitWindow : elapsed;
        uint256 year = 365 * 24 * 60 * 60;
        uint256 interest = amount * effectiveElapsed * rate / (1e9 * year);
        return amount + interest;
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


    // -------------------------------------------------------------------------
    //                              View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the full `LendingArrangement` (including nested params) for a given lendingId.
    function getLending(uint256 lendingId) external view returns (LendingArrangement memory) {
        return lendingArrangements[lendingId];
    }

    /// @notice Returns just the pending `RefiParams` for a given lendingId.
    function getRefiParams(uint256 lendingId) external view returns (RefiParams memory) {
        return lendingArrangements[lendingId].refiParams;
    }

    /// @notice Returns just the `OracleParams` for a given lendingId.
    function getOracleParams(uint256 lendingId) external view returns (OracleParams memory) {
        return lendingArrangements[lendingId].oracleParams;
    }

    /// @notice Returns just the `InterestRateParams` for a given lendingId.
    function getRateParams(uint256 lendingId) external view returns (InterestRateParams memory) {
        return lendingArrangements[lendingId].interestRateParams;
    }

    /// @notice Returns the snapshotted lender + liquidator addresses for an oracle-game fee recipient.
    function getBeneficiaries(uint256 lendingId, address feeRecipient) external view returns (Beneficiaries memory) {
        return lendingBeneficiaries[lendingId][feeRecipient];
    }

    /**
     * @notice Returns the loose paramHash for an arrangement: the keccak256 of the struct with `supplyAmount`
     *         and `repaidDebt` zeroed in the preimage. Pass this to entrypoints that accept a `paramHashExpected`.
     * @dev    This helper does not classify whether the settleable report would succeed or fail liquidation.
     *         It returns the failed-liq executable projection used by successful autoSettle action paths. If
     *         actual settlement finishes the loan, autoSettle entrypoints revert on `finished` before checking
     *         the hash.
     */
    function getParamHash(uint256 lendingId) external view returns (bytes32) {
        LendingArrangement memory copy = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;

        if (copy.inLiquidation) {
            uint256 reportId = lendingToReportId[lendingId];
            if (reportId != 0) {
                IOpenOracle.ReportStatus memory rs = oracle.reportStatus(reportId);
                if (rs.settlementTimestamp == 0) {
                    uint256 settleableAt = uint256(rs.reportTimestamp) + oracle.reportMeta(reportId).settlementTime;
                    if (currentTime >= settleableAt) {
                        // Mirrors onSettle's failed-liq branch on the memory copy.
                        uint256 tokenStake = uint256(copy.supplyAmount) * copy.stake / 10000;

                        if (copy.curveOpen) {
                            copy.requestStart = uint48(settleableAt);
                        }

                        if (settleableAt > uint256(copy.start) + copy.term - 1800) {
                            copy.gracePeriod = uint48(1800 + (settleableAt - copy.liquidationStart) * 2);
                            uint256 lenderStakePiece = tokenStake / 2;
                            copy.supplyAmount += uint128(tokenStake - lenderStakePiece);
                        } else {
                            copy.supplyAmount += uint128(tokenStake);
                        }

                        copy.inLiquidation = false;
                        copy.liquidationStart = 0;
                        copy.liquidator = address(0);
                        copy.feeRecipient = address(0);
                    }
                }
            }
        }

        copy.supplyAmount = 0;
        copy.repaidDebt = 0;
        return keccak256(abi.encode(copy));
    }
}
