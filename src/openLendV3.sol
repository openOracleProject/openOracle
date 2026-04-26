// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle} from "./interfaces/IOpenOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
 *         Front-running protection: state-mutating entrypoints accept an optional loose paramHash plus directional bounds
 *         (`expectedMinSupply`, `expectedRepaidDebtMin`, `minLendAmount`/`maxLendAmount`, `worstRatio`, `maxInitialLiquidity`).
 *         The loose hash zeros `supplyAmount` and `repaidDebt` before hashing so that benign top-ups or partial
 *         repayments don't grief the caller; directional bounds defend against adversarial movements that would shift
 *         the caller's economic decision (e.g. an RPC lying about `repaidDebt` could mask an underwater position).
 *
 *         External integration: openOracle (https://docs.openoracle.org) is used for liquidation price discovery.
 */
contract openLend is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IOpenOracle public immutable oracle;
    address public immutable feeReceiverImpl;

    error InvalidInput(string);

    uint256 nextLendingId = 1;

    mapping(uint256 => LendingArrangement) public lendingArrangements;
    mapping(uint256 => mapping(address => Beneficiaries)) public lendingBeneficiaries;
    mapping(uint256 => uint256) public reportIdToLending;
    mapping(address => mapping(address => uint256)) public tempHolding;
    mapping(address => bool) private _oracleApproved;

    constructor(IOpenOracle _oracle) {
        oracle = _oracle;
        feeReceiverImpl = address(new oracleFeeReceiver());
    }

    /// @notice Full state of a single lending arrangement. Stored at `lendingArrangements[lendingId]`.
    /// @dev Field ordering targets a balance between slot packing and readability.
    struct LendingArrangement {
        uint128 supplyAmount; // amount supplied as collateral
        uint128 borrowAmount; // amount borrowed at time of loan origination
        uint128 amountDemanded; // amount demanded by borrower
        uint128 repaidDebt; // amount of debt repaid
        address borrower; // borrower address
        uint48 term; // length of loan in seconds
        uint48 start; // timestamp loan began
        address lender; // lender address
        address liquidator; // liquidator address
        uint48 liquidationStart; // timestamp where the liquidation started
        uint48 gracePeriod; // extra time to repay debt / accept refinance offer if liquidation oracle game runs past maturity
        address supplyToken; // supply token
        uint24 liquidationThreshold; // 8e6 = 80%. when accrued debt > liquidationThreshold * supplyAmount, liquidation is possible
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
        uint48 requestStart; // when latest borrow request or refi request started
        RefiParams refiParams; // parameters for borrower's next refinance
        OracleParams oracleParams; // parameters for oracle game
        InterestRateParams interestRateParams; // interest rate parameters
    }

    /// @notice Parameters for the rising interest rate curve evaluated by `calcRate`.
    /// @dev    Rate at round k is `min(maxRate, startingRate * (growthRate/10000)^k)`.
    ///         Curve is keyed on `requestStart`; resets when borrower opens a refi or when a failed liquidation finishes
    ///         while the curve is open.
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
    }

    /// @notice Parameters governing the openOracle game spawned at liquidation time.
    struct OracleParams {
        uint48 settlementTime; // openOracle settlement window in seconds (bounded [120, 14400]).
        uint24 disputeDelay; // openOracle dispute delay; must be < settlementTime.
        uint24 oracleGameFee; // protocol fee on the oracle game, 1e7 = 100%; routed to a feeRecipient clone.
        uint16 escalationFactor; // escalationHalt = supplyAmount * escalationFactor / 100. Bounded [100, 1000].
        uint16 initialLiquidity; // initial token1 in the oracle report = supplyAmount * initialLiquidity / 100. Bounded [10, 200].
        uint16 multiplier; // openOracle per-round dispute multiplier, e.g. 140 = 1.4x. Bounded [100, 1000].
    }

    /// @notice Snapshot of lender + liquidator at oracle-game time, used for fee-share routing.
    /// @dev    Stored at the moment of `liquidate` so that even if `lending.lender` is later overwritten by a refi,
    ///         `_grabOracleGameFees` still routes that game's fees to the correct parties.
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
        bool allowAnyLiquidator
    );
    event LoanLiquidationUnderway(uint256 indexed lendingId, uint256 reportId, address feeRecipient);
    event DebtRepaid(uint256 indexed lendingId, address indexed payer, uint256 amount, bool fullyRepaid);
    event CollateralToppedOff(uint256 indexed lendingId, address indexed payer, uint256 amount);
    event CollateralClaimedByLender(uint256 indexed lendingId, uint256 supplyTokenClaimed, uint256 borrowTokenClaimed);
    event RefiOpened(
        uint256 indexed lendingId,
        uint128 extraDemanded,
        uint128 supplyPulled,
        uint48 newTerm,
        OracleParams oracleParams,
        InterestRateParams interestRateParams
    );
    event RefiOpenedDuringLiquidation(uint256 indexed lendingId, uint128 extraDemanded, uint128 supplyPulled, uint48 newTerm, OracleParams oracleParams, InterestRateParams interestRateParams);
    event RefiCancelled(uint256 indexed lendingId);
    event LiqFinishedUnderwater(uint256 indexed lendingId);
    event LiqFinishedWithBuffer(uint256 indexed lendingId);
    event LiqUnsuccessful(uint256 indexed lendingId);
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
     *         Until accepted, the borrower may abandon the request via `cancelBorrowRequest` to recover collateral.
     *         Validates all rate, oracle, term, and arithmetic-overflow bounds up front so later state transitions are safe.
     * @param  term Loan duration in seconds, bounded [1800, 1 year]. Measured from the moment a lender calls `lend`.
     * @param  supplyToken Address of the ERC20 supplied as collateral. Must differ from `borrowToken`.
     * @param  borrowToken Address of the ERC20 the borrower wants to borrow.
     * @param  liquidationThreshold Fraction in 1e7 fixed-point (8e6 = 80%). Liquidation becomes possible when
     *                              `borrowValue > liquidationThreshold * supplyAmount`. Bounded [7e6, 1e7].
     * @param  supplyAmount Collateral amount transferred from `msg.sender` into the contract on this call.
     * @param  amountDemanded Borrow amount requested. Pulled from the lender to the borrower at `lend` time.
     * @param  stake Liquidator stake fraction in 10000 fixed-point (100 = 1%). The liquidator wagers
     *               `stake * supplyAmount / 10000` of supplyToken on the liquidation succeeding.
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
        OracleParams memory oracleParams,
        InterestRateParams memory interestRateParams
    ) external nonReentrant returns (uint256 lendingId) {
        uint256 currentTime = uint48(block.timestamp);
        uint48 settlementTime = oracleParams.settlementTime;
        uint16 escalationFactor = oracleParams.escalationFactor;
        uint128 initialLiquidity = oracleParams.initialLiquidity;
        uint16 multiplier = oracleParams.multiplier;
        uint256 escHalt = uint256(supplyAmount) * escalationFactor / 100;

        if (supplyToken == borrowToken) revert InvalidInput("supply == borrow");
        if (liquidationThreshold > 1e7 || liquidationThreshold < 7e6) revert InvalidInput("LT out of bounds");
        if (stake > 10000) revert InvalidInput("stake too high");
        if (amountDemanded == 0) revert InvalidInput("cant borrow 0");
        if (supplyAmount == 0) revert InvalidInput("cant supply 0");
        if (settlementTime < 120 || settlementTime > 60 * 60 * 4) {
            revert InvalidInput("oracle settlementTime out of bounds");
        }
        if (escalationFactor < 100 || escalationFactor > 1000) {
            revert InvalidInput("oracle escalation factor out of bounds");
        }
        if (initialLiquidity < 10 || initialLiquidity > 200) {
            revert InvalidInput("oracle initial liquidity out of bounds");
        }
        if (escalationFactor < initialLiquidity) revert InvalidInput("escalation factor too small");
        if (term < 1800 || term > 60 * 60 * 24 * 365) revert InvalidInput("term out of bounds");
        if (supplyAmount + uint256(supplyAmount) * stake / 10000 > type(uint128).max) {
            revert InvalidInput("supply + stake too high");
        }
        if (escHalt > type(uint128).max) revert InvalidInput("escalation halt too high");

        if (oracleParams.oracleGameFee > 1e6) revert InvalidInput("oracle game fees too high");
        if (multiplier < 100 || multiplier > 1000) revert InvalidInput("oracle game multiplier out of bounds");
        if (oracleParams.disputeDelay >= settlementTime) revert InvalidInput("disputeDelay >= settlementTime");

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
            oracleParams,
            interestRateParams
        );
        return lendingId;
    }

    /**
     * @notice Cancels an unaccepted borrow request and returns the collateral to the borrower.
     * @dev    Reverts if the loan has already been accepted (`active`) or already cancelled. Only callable by the borrower.
     *         Sets `cancelled = true`, which permanently disables every other entrypoint on this `lendingId`.
     * @param  lendingId Unique identifier returned from `requestBorrow`.
     */
    function cancelBorrowRequest(uint256 lendingId) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        uint256 supplyAmount = lending.supplyAmount;

        if (lending.cancelled) revert InvalidInput("lendingId cancelled");
        if (lending.active) revert InvalidInput("lendingId active");
        if (lending.borrower != msg.sender) revert InvalidInput("msg.sender");

        lending.cancelled = true;
        _clearRefiCurve(lending);

        IERC20(lending.supplyToken).safeTransfer(msg.sender, supplyAmount);

        emit BorrowRequestCancelled(msg.sender, lendingId);
    }

    /**
     * @notice Accepts the current rate on the borrow / refi curve. Single entrypoint for both origination and refinance.
     * @dev    On origination: pulls `amountDemanded` of borrowToken from msg.sender, sends it to the borrower, and
     *         marks the loan active.
     *         On refinance: pulls the new principal (`owedAtMaturity - repaidDebt + extraDemanded`) from msg.sender,
     *         pays the previous lender their committed `owedAtMaturity` (using prior rate/term, NOT the new ones),
     *         disburses any `extraDemanded` and `supplyPulled` to the borrower, and resets per-loan state
     *         (repaidDebt, gracePeriod, liquidator scratch fields). The new term is `refiParams.newTerm`, the new
     *         rate is `calcRate` at `block.timestamp`, and `start` is reset to `block.timestamp`.
     *         Lifecycle gates: reverts on `cancelled`, `finished`, `inLiquidation`, or `!curveOpen`. On the refi
     *         branch (`active == true`), also reverts if `currentTime >= start + term + gracePeriod` (post-grace).
     *         Origination has no expiry check (the rate curve can keep ticking indefinitely until accepted).
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  paramHashExpected Optional loose paramHash (zeroes supplyAmount + repaidDebt before hashing). Set to
     *                           bytes32(0) to skip. Defends against an RPC lying about loan parameters.
     * @param  minLendAmount Refi-only floor on the new principal. Set to 0 on origination (ignored).
     * @param  maxLendAmount Refi-only ceiling on the new principal. Set to type(uint128).max on origination (ignored).
     * @param  expectedMinSupply Reverts if `supplyAmount < expectedMinSupply`.
     * @param  minRate Reverts if the computed rate is below this floor. Protects the lender against curve resets (e.g. failed liquidation in `onSettle`) between quote and tx landing.
     * @param  allowAnyLiquidator If true, anyone may later call `liquidate`; the liquidator splits 50/50 with the lender.
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
    ) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;
        address borrower = lending.borrower;
        address borrowToken = lending.borrowToken;
        address supplyToken = lending.supplyToken;
        uint256 rate = calcRate(lending.interestRateParams, lending.requestStart);
        address prevLender = lending.lender;
        uint48 prevTerm = lending.term;
        uint32 prevRate = lending.rate;

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

            //can we just transferFrom lender direct to borrower instead of through contract?
            IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), lending.amountDemanded);
            IERC20(borrowToken).safeTransfer(borrower, lending.amountDemanded);

            emit LoanOriginated(
                lendingId, msg.sender, lending.amountDemanded, rate, uint48(currentTime), prevTerm, allowAnyLiquidator
            );
        } else {
            // refi
            uint256 owedAtMaturity = totalOwedAtMaturity(lending.borrowAmount, prevRate, prevTerm);
            uint128 extraDemanded = lending.refiParams.extraDemanded;
            uint128 supplyPulled = lending.refiParams.supplyPulled;
            uint48 newTerm = lending.refiParams.newTerm;
            uint256 newBorrowAmount = owedAtMaturity - lending.repaidDebt + extraDemanded;

            if (newBorrowAmount < minLendAmount || newBorrowAmount > maxLendAmount) {
                revert InvalidInput("lend amount out of bounds");
            }

            lending.borrowAmount = uint128(newBorrowAmount);
            lending.repaidDebt = 0;
            lending.gracePeriod = 0;
            lending.feeRecipient = address(0);
            lending.liquidator = address(0);
            lending.liquidationStart = 0;
            lending.term = newTerm;
            lending.supplyAmount -= supplyPulled;
            lending.refiParams.extraDemanded = 0;
            lending.refiParams.supplyPulled = 0;
            lending.refiParams.newTerm = 0;

            IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), newBorrowAmount);
            _transferTokens(borrowToken, address(this), prevLender, owedAtMaturity);
            if (extraDemanded > 0) IERC20(borrowToken).safeTransfer(borrower, extraDemanded);
            if (supplyPulled > 0) IERC20(supplyToken).safeTransfer(borrower, supplyPulled);

            emit LoanRefinanced(
                lendingId,
                msg.sender,
                prevLender,
                newBorrowAmount,
                owedAtMaturity,
                rate,
                uint48(currentTime),
                newTerm,
                extraDemanded,
                supplyPulled,
                allowAnyLiquidator
            );
        }
    }

    /**
     * @notice Borrower-only repayment. Pays down debt, reducing liquidation risk.
     * @dev    If `amount >= netTerminalDebt` (= `totalOwedAtMaturity - repaidDebt`), the loan is fully closed:
     *         lender is paid `owedAtMaturity` and borrower receives all collateral. Otherwise `repaidDebt` is
     *         incremented. Reverts during liquidation, after maturity (+ grace), or when finished/cancelled.
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
    ) external nonReentrant {
        if (msg.sender != lendingArrangements[lendingId].borrower) revert InvalidInput("not borrower");
        _repayDebt(lendingId, amount, expectedParamHash, expectedMinSupply, expectedRepaidDebtMin);
    }

    /**
     * @notice Permissionless variant of `repayDebt`: anyone can repay any loan's debt.
     * @dev    Strictly beneficial for the borrower: the third party puts up the borrowToken. Useful for borrowers 
     *         paying through a different EOA. Same gating and parameters as `repayDebt`.
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
    ) external nonReentrant {
        _repayDebt(lendingId, amount, expectedParamHash, expectedMinSupply, expectedRepaidDebtMin);
    }

    /**
     * @notice Borrower-only collateral top-up. Increases `supplyAmount`, reducing liquidation risk.
     * @dev    Reverts during liquidation, after maturity, or when finished/cancelled. Re-checks the
     *         supply + stake and escalationHalt overflow bounds against the post-top-up amount.
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
    ) external nonReentrant {
        if (msg.sender != lendingArrangements[lendingId].borrower) revert InvalidInput("not borrower");
        _topUpCollateral(lendingId, amount, expectedParamHash, expectedMinSupply, expectedRepaidDebtMin);
    }

    /**
     * @notice Permissionless variant of `topUpCollateral`: anyone can add collateral on behalf of any loan.
     * @dev    Strictly beneficial for the borrower: third party puts up the supplyToken. Same gating and
     *         parameters as `topUpCollateral`.
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
    ) external nonReentrant {
        _topUpCollateral(lendingId, amount, expectedParamHash, expectedMinSupply, expectedRepaidDebtMin);
    }

    /**
     * @notice Forfeits unused collateral + any partial repayments to the lender once the loan has expired without
     *         being repaid or refinanced.
     * @dev    Permissionless: anyone can call (the funds always go to the lender). Reverts if still within
     *         `start + term + gracePeriod`. The grace period is non-zero only when a failed liquidation finished
     *         too close to or past maturity.
     * @param  lendingId Unique identifier of the lending arrangement.
     */
    function claimCollateral(uint256 lendingId) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;
        address lender = lending.lender;
        uint128 supplyAmount = lending.supplyAmount;
        uint128 repaidDebt = lending.repaidDebt;

        if (lending.inLiquidation) revert InvalidInput("in liquidation");
        if (lending.finished) revert InvalidInput("arrangement finished");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (currentTime < uint256(lending.start) + lending.term + lending.gracePeriod) {
            revert InvalidInput("not expired");
        }

        lending.finished = true;
        _clearRefiCurve(lending);

        IERC20(lending.supplyToken).safeTransfer(lender, supplyAmount);
        if (repaidDebt > 0) {
            IERC20(lending.borrowToken).safeTransfer(lender, repaidDebt);
        }

        emit CollateralClaimedByLender(lendingId, supplyAmount, repaidDebt);
    }

    /**
     * @notice Borrower opens a refinance: re-opens the rate curve so that any lender can roll the loan, optionally
     *         drawing extra borrow, returning some collateral, or changing the term.
     * @dev    Sets `curveOpen = true` and resets `requestStart = block.timestamp`. The actual roll happens when a
     *         lender calls `lend`, at which point `extraDemanded` is paid out, `supplyPulled` is returned to the
     *         borrower, the previous lender is paid `owedAtMaturity` (computed at the old rate/term), and the new
     *         loan begins fresh with `start = block.timestamp` and term = `newTerm`.
     *         Reverts unless caller is the borrower, the loan is active, and the curve is closed. Explicitly
     *         allowed during `inLiquidation`: opening a refi mid-liq parks the curve so it's ready to be
     *         accepted the moment `onSettle` clears the liquidation flag (lend() blocks while inLiquidation).
     *         The expiry check (`currentTime >= start + term + gracePeriod`) is bypassed when `inLiquidation`,
     *         so a borrower can pre-open a refi past nominal maturity if a liquidation is in flight.
     *         Emits `RefiOpenedDuringLiquidation` when called mid-liq, `RefiOpened` otherwise — indexers should
     *         distinguish so they don't quote a rate against a parked curve.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  extraDemanded Additional borrowToken pulled to the borrower at lend-time (on top of rolling debt).
     * @param  supplyPulled SupplyToken returned to the borrower at lend-time. Must be < current `supplyAmount`.
     * @param  newTerm New term in seconds for the post-refi loan, or 0 to keep the existing term. If non-zero,
     *                 bounded [1800, 1 year]; same range as origination.
     * @param  interestRateParams New curve parameters governing the refi auction.
     * @param  expectedParamHash Optional loose paramHash. Set to bytes32(0) to skip.
     * @param  expectedMinSupply Reverts if `supplyAmount < expectedMinSupply`.
     * @param  expectedRepaidDebtMin Reverts if `repaidDebt < expectedRepaidDebtMin`.
     */
    function refinance(
        uint256 lendingId,
        uint128 extraDemanded,
        uint128 supplyPulled,
        uint48 newTerm,
        InterestRateParams memory interestRateParams,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedRepaidDebtMin
    ) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        RefiParams storage refiParams = lending.refiParams;

        uint256 currentTime = block.timestamp;

        if (msg.sender != lending.borrower) revert InvalidInput("not borrower");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.finished) revert InvalidInput("finished");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (lending.curveOpen) revert InvalidInput("curve is open");
        if (supplyPulled >= lending.supplyAmount) revert InvalidInput("supplyPulled too high");
        _validateInterestRateParams(interestRateParams);
        if (lending.repaidDebt < expectedRepaidDebtMin) revert InvalidInput("repaid debt too low");
        if (lending.supplyAmount < expectedMinSupply) revert InvalidInput("supply too low");
        if (newTerm != 0 && (newTerm < 1800 || newTerm > 60 * 60 * 24 * 365)) revert InvalidInput("term out of bounds");
        if (!lending.inLiquidation && currentTime >= uint256(lending.start) + lending.term + lending.gracePeriod) revert InvalidInput("expired");
        if (expectedParamHash != bytes32(0)) {
            _checkParamsLoose(lending, expectedParamHash);
        }

        refiParams.extraDemanded = extraDemanded;
        refiParams.supplyPulled = supplyPulled;
        refiParams.newTerm = newTerm == 0 ? lending.term : newTerm;
        lending.curveOpen = true;
        lending.requestStart = uint48(currentTime);
        lending.interestRateParams = interestRateParams;

        if (lending.inLiquidation) {
            emit RefiOpenedDuringLiquidation(lendingId, extraDemanded, supplyPulled, refiParams.newTerm, lending.oracleParams, interestRateParams);
        } else {
            emit RefiOpened(lendingId, extraDemanded, supplyPulled, refiParams.newTerm, lending.oracleParams, interestRateParams);
        }
    }

    /**
     * @notice Closes an open refi curve before any lender has accepted. Restores the loan to its pre-refi state.
     * @dev    Reverts unless caller is the borrower and the curve is currently open. Clears all `RefiParams`.
     *         Does not change rate, term, or any other property of the live underlying loan.
     * @param  lendingId Unique identifier of the lending arrangement.
     */
    function cancelRefinance(uint256 lendingId) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        if (msg.sender != lending.borrower) revert InvalidInput("not borrower");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.finished) revert InvalidInput("finished");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (!lending.curveOpen) revert InvalidInput("curve is not open");

        _clearRefiCurve(lending);

        emit RefiCancelled(lendingId);
    }

    /**
     * @notice Initiates a liquidation by spawning an openOracle price report. The liquidator wagers
     *         `stake * supplyAmount / 10000` of supplyToken that the oracle will resolve to an underwater price.
     * @dev    Liquidator transfers (a) `initialLiquidity` of supplyToken as the report's token1 side,
     *         (b) `oracleAmount2 = initialLiquidity * priceRatio / 1e18` of borrowToken as the token2 side, and
     *         (c) the stake. They also pay `1e15` wei as the openOracle settler reward.
     *         While the report is open the loan is `inLiquidation`: the borrower cannot repay or top up.
     *         Resolution happens in `onSettle`:
     *           - If oracle resolves underwater: liquidator recovers stake, gets 50% of any equity buffer; lender
     *             receives remaining collateral plus all `repaidDebt`. Loan finishes.
     *           - If oracle resolves NOT underwater: stake is forfeit to the borrower (added to `supplyAmount`).
     *             Loan continues. If resolution lands within 30 minutes (1800s) of maturity or after it,
     *             `gracePeriod` is set to `1800 + 2 * (currentTime - liquidationStart)`, so the borrower has
     *             time to react.
     *         Permissioning: only `lender` may call unless `allowAnyLiquidator` was set at `lend` time.
     *         Reverts if `gracePeriod != 0` (a prior failed liquidation already granted the borrower a buffer;
     *         the contract refuses to start another oracle game during that window).
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  priceRatio borrowToken-per-supplyToken in 1e18 fixed-point. Used to compute the report's token2 side.
     *                    A misconfigured `priceRatio` is the liquidator's risk to bear (it changes their token2 exposure).
     * @param  maxInitialLiquidity Cap on the report's token1 side, defending against the lender front-running with
     *                             a `topUpCollateral` that would inflate `initialLiquidity`.
     * @param  paramHashExpected Loose paramHash. Required.
     * @param  worstRatio Reverts if `1e18 * netBorrow / supplyAmount < worstRatio`. Defends against a borrower
     *                    repaying just before liquidation in a way that would leave the position too healthy
     *                    relative to the liquidator's expected payout.
     */
    function liquidate(
        uint256 lendingId,
        uint256 priceRatio,
        uint128 maxInitialLiquidity,
        bytes32 paramHashExpected,
        uint256 worstRatio
    ) external payable nonReentrant {
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
     *             the buffer; liquidator gets the other half plus the stake. Lender also receives any `repaidDebt`.
     *           - Not underwater: liquidator's stake is forfeit to the borrower (added to `supplyAmount`). If the
     *             curve is open, `requestStart` is reset to keep the rate auction honest. If resolution lands near
     *             or past maturity, a grace period is granted to the borrower.
     *         Distributes any oracle game protocol fees via `_grabOracleGameFees`.
     * @param  id The openOracle reportId that just settled (used to look up the lendingId).
     */
    function onSettle(uint256 id, uint256, uint256, address, address)
        external
        payable
        nonReentrant
    {
        if (msg.sender != address(oracle)) revert InvalidInput("invalid sender");
        uint256 lendingId = reportIdToLending[id];
        if (lendingId == 0) revert InvalidInput("no lendingId for reportId");

        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;
        uint48 start = lending.start;
        uint48 term = lending.term;
        uint128 repaidDebt = lending.repaidDebt;
        uint128 supplyAmount = lending.supplyAmount;
        address lender = lending.lender;
        address supplyToken = lending.supplyToken;
        address borrowToken = lending.borrowToken;
        address liquidator = lending.liquidator;
        uint256 borrowValue = totalOwedNow(lending.borrowAmount, lending.rate, term, start);

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
        if (liqThresh < borrowValueInSupplyTerms) {
            lending.finished = true;
            _clearRefiCurve(lending);

            _transferTokens(borrowToken, address(this), lender, repaidDebt);

            if (borrowValueInSupplyTerms > supplyAmount) {
                _transferTokens(supplyToken, address(this), lender, supplyAmount);
                _transferTokens(supplyToken, address(this), liquidator, tokenStake);
                emit LiqFinishedUnderwater(lendingId);
            } else {
                uint256 buffer = supplyAmount - borrowValueInSupplyTerms;
                uint256 lenderPiece = buffer / 2;
                uint256 liquidatorPiece = buffer - lenderPiece;

                _transferTokens(supplyToken, address(this), lender, borrowValueInSupplyTerms + lenderPiece);
                _transferTokens(supplyToken, address(this), liquidator, liquidatorPiece + tokenStake);

                emit LiqFinishedWithBuffer(lendingId);
            }
        } else {
            lending.supplyAmount += uint128(tokenStake);

            if (lending.curveOpen) {
                lending.requestStart = uint48(currentTime);
            }

            // grace period around liquidations that end either too close to maturity (30 minutes) or after it
            if (currentTime > uint256(start) + term - 1800) {
                lending.gracePeriod = uint48(1800 + (currentTime - lending.liquidationStart) * 2);
            }

            lending.liquidationStart = 0;

            emit LiqUnsuccessful(lendingId);
        }

        address feeRecipient = lending.feeRecipient;
        if (feeRecipient != address(0)) {
            _grabOracleGameFees(lending, feeRecipient, lendingId);
        }
    }

    /**
     * @notice Permissionless: distribute any protocol fees that have accrued in a feeRecipient clone but haven't
     *         been swept yet.
     * @dev    `onSettle` already calls `_grabOracleGameFees` once per game; this is a backstop. Reverts unless the
     *         feeRecipient's `gameId` matches the lendingId.
     *         Fees split: borrower 50%, lender 25%, liquidator 25%.
     * @param  lendingId Unique identifier of the lending arrangement.
     * @param  feeRecipient Address of the fee receiver clone deployed in `liquidate`.
     */
    function grabOracleGameFeesAny(uint256 lendingId, address feeRecipient) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        if (feeRecipient == address(0)) revert InvalidInput("no fee recipient");
        if (oracleFeeReceiver(feeRecipient).gameId() != lendingId) {
            revert InvalidInput("feeRecipient not for lendingId");
        }
        _grabOracleGameFees(lending, feeRecipient, lendingId);
    }

    /**
     * @notice Withdraws any tokens held for `msg.sender` in the `tempHolding` escrow.
     * @dev    Tokens land in `tempHolding` when a contract-out transfer fails inside `_transferTokens` (e.g. a
     *         blacklisted participant). This entrypoint lets the rightful recipient retry the transfer later.
     *         If the retry also fails, the amount is re-credited to `tempHolding` by the same fallback logic.
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

    // -------------------------------------------------------------------------
    //                              Internal functions
    // -------------------------------------------------------------------------

    /// @dev Shared implementation for `repayDebt` and `repayAnyDebt`. Performs lifecycle gating, paramHash + bounds
    ///      checks, and either fully closes the loan (`amount >= netTerminalDebt`) or accumulates `repaidDebt`.
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
        uint256 owedAtMaturity = totalOwedAtMaturity(borrowAmount, rate, term);
        address lender = lending.lender;
        address borrower = lending.borrower;
        uint256 supplied = lending.supplyAmount;
        uint256 netTerminalDebt = owedAtMaturity - repaid;
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

            IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), netTerminalDebt);
            _transferTokens(borrowToken, address(this), lender, owedAtMaturity);
            IERC20(lending.supplyToken).safeTransfer(borrower, supplied);
            emit DebtRepaid(lendingId, msg.sender, netTerminalDebt, true);
        } else {
            lending.repaidDebt += amount;

            IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);
            emit DebtRepaid(lendingId, msg.sender, amount, false);
        }
    }

    /// @dev Shared implementation for `topUpCollateral` and `topUpCollateralAnyone`. Re-validates supply + stake
    ///      and escalationHalt overflow against the post-add total before mutating state.
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

    /// @dev Verifies that the on-chain `lending` matches `paramHashExpected` after zeroing `supplyAmount` and
    ///      `repaidDebt`. This makes the hash robust to benign top-ups and partial repayments while
    ///      still pinning every other field. Callers pair this with directional bounds (e.g. `expectedMinSupply`,
    ///      `expectedRepaidDebtMin`) to catch adversarial reporting of or movement in the zeroed fields.
    function _checkParamsLoose(LendingArrangement storage lending, bytes32 paramHashExpected) internal view {
        LendingArrangement memory copy = lending;
        copy.supplyAmount = 0;
        copy.repaidDebt = 0;
        if (paramHashExpected != keccak256(abi.encode(copy))) revert InvalidInput("params");
    }

    /// @dev Lazily grants `oracle` infinite allowance on `token` the first time we need to send it through the
    ///      oracle game. Cached in `_oracleApproved` so subsequent calls are no-ops.
    function _ensureOracleApproval(address token) internal {
        if (!_oracleApproved[token]) {
            IERC20(token).forceApprove(address(oracle), type(uint256).max);
            _oracleApproved[token] = true;
        }
    }

    /// @dev Clones `feeReceiverImpl` for this liquidation's fees. The clone routes any oracle game protocol fees
    ///      back to this contract, where `_grabOracleGameFees` splits them across borrower / lender / liquidator.
    function _deployFeeReceiver(uint256 lendingId, address supplyToken, address borrowToken)
        internal
        returns (address feeReceiver)
    {
        feeReceiver = Clones.clone(feeReceiverImpl);
        oracleFeeReceiver(feeReceiver).initialize(
            address(this), uint128(lendingId), address(oracle), supplyToken, borrowToken
        );
    }

    /// @dev Builds the openOracle CreateReportParams struct for a liquidation. Pulled out of `liquidate` to keep
    ///      that function under stack-depth limits and to isolate the field mapping.
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
            callbackGasLimit: 1000000,
            feePercentage: 0,
            multiplier: oracleParams.multiplier,
            timeType: true,
            trackDisputes: false,
            callbackContract: address(this),
            callbackSelector: this.onSettle.selector,
            protocolFeeRecipient: feeRecipient
        });
    }

    /// @dev Pulls any accumulated fees out of the feeRecipient clone (via `collect` then `sweep` for both tokens),
    ///      measures balance deltas in this contract to size the haul, and splits 50/25/25 across borrower/lender/
    ///      liquidator. The lender/liquidator addresses are taken from `lendingBeneficiaries` (snapshotted at
    ///      `liquidate` time).
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
     * @dev Token transfer with a graceful fallback to per-recipient escrow.
     *      For from == address(this): does a low-level `transfer` and treats it as success on either standard
     *      bool-true return or empty return from a contract address. If the call reverts or returns false, the
     *      amount is credited to `tempHolding[to][token]` so the recipient can later pull it via `getTempHolding`.
     *      This prevents a blacklisted recipient from bricking flows that need to pay multiple parties (e.g. the
     *      buffer split in `onSettle`).
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

    /// @dev Sanity-checks `InterestRateParams`. Enforces non-zero fields, `maxRate >= startingRate`, an absolute
    ///      ceiling of 1e10 on `maxRate`, `growthRate > 10000`, and maxRounds <= 100.
    function _validateInterestRateParams(InterestRateParams memory ir) internal pure {
        if (
            ir.maxRate == 0 || ir.startingRate == 0 || ir.growthRate == 0 || ir.maxRounds == 0 || ir.roundLength == 0
                || ir.maxRate < ir.startingRate || ir.maxRate > 1e10 || ir.growthRate <= 10000 || ir.maxRounds > 100
        ) revert InvalidInput("interestRateParams");
    }

    /// @dev Evaluates the rising rate curve at `block.timestamp`. Rounds elapsed = `(now - requestStart) / roundLength`,
    ///      capped at `maxRounds`. Rate at round k = `startingRate * (growthRate/10000)^k`, capped at `maxRate`.
    ///      Loop early-exits once the cap is hit, so worst-case gas is bounded by `maxRounds`.
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

    /// @dev Total debt the borrower owes at maturity = principal + simple interest over the full term.
    ///      The lender is committed to this amount regardless of when the borrower repays or refinances —
    ///      early payoff still pays the maturity-equivalent so the lender's yield is locked in.
    /// @param amount Principal at origination/refi (`borrowAmount`).
    /// @param rate Annualized rate in 1e9 fixed-point.
    /// @param term Loan term in seconds.
    /// @return Principal plus interest accrued over the full term.
    function totalOwedAtMaturity(uint256 amount, uint256 rate, uint256 term) internal pure returns (uint256) {
        uint256 interest;
        uint256 year = 365 * 24 * 60 * 60;
        interest = amount * term * rate / (1e9 * year);
        return amount + interest;
    }

    /// @dev Time-prorated debt for liquidation purposes. Used by `liquidate` and `onSettle` so that an early
    ///      liquidation doesn't charge the borrower for unaccrued interest. Caps elapsed at `term`.
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

    /// @dev Clears any open refi curve + pending refi params. Called from terminal transitions
    ///      (successful liquidation, full repayment, claim) so views don't report a stale open
    ///      curve on a finished loan. `finished` is the actual safety gate; this is hygiene.
    function _clearRefiCurve(LendingArrangement storage lending) internal {
        lending.curveOpen = false;
        lending.refiParams.extraDemanded = 0;
        lending.refiParams.supplyPulled = 0;
        lending.refiParams.newTerm = 0;
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
     * @notice Returns the loose keccak256 hash of a `LendingArrangement` struct (no supplyAmount or repaidDebt), 
     *         suitable for passing to entrypoints that take a `paramHashExpected` argument.
     */
    function getParamHash(uint256 lendingId) external view returns (bytes32) {
        LendingArrangement memory copy = lendingArrangements[lendingId];
        copy.supplyAmount = 0;
        copy.repaidDebt = 0;
        return keccak256(abi.encode(copy));
    }
}


