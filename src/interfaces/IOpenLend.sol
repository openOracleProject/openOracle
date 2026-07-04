// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "./IOpenOracle2.sol";

/**
 * @title  IOpenLend
 * @notice External interface for the openLend lending protocol (adapter-compatible build).
 * @dev    In this build `requestBorrow` and `lend` take the recorded party (`borrower` / `lender`)
 *         as an explicit address argument rather than using `msg.sender`, so an adapter can act on
 *         behalf of a user. Funding is still pulled from `msg.sender`; all entitlement payouts read
 *         the recorded `borrower`/`lender`. Structs are layout-identical to openLend's so calls and
 *         the `lendingArrangements` getter ABI-decode correctly through this interface.
 */
interface IOpenLend {
    // -------------------------------------------------------------------------
    //                                  Structs
    // -------------------------------------------------------------------------

    struct LendingArrangement {
        uint128 supplyAmount;
        uint128 principal;
        uint128 interestAccrued;
        uint56 interestRemainder;
        uint48 lastTouch;
        uint24 liquidatorFraction;
        uint128 interestPaid;
        uint128 commitmentInterest;
        address borrower;
        uint48 term;
        uint48 start;
        address lender;
        uint96 gasCompensation;
        address liquidator;
        uint48 liquidationStart;
        uint48 gracePeriod;
        address supplyToken;
        uint48 requestStart;
        uint24 liquidationThreshold;
        uint24 commitmentFraction;
        address borrowToken;
        uint32 rate;
        uint16 stake;
        bool cancelled;
        bool active;
        bool inLiquidation;
        bool finished;
        bool curveOpen;
        RefiParams refiParams;
        OracleParams oracleParams;
        InterestRateParams interestRateParams;
    }

    struct InterestRateParams {
        uint32 maxRate;
        uint32 startingRate;
        uint24 roundLength;
        uint16 growthRate;
        uint16 maxRounds;
    }

    struct RefiParams {
        uint128 extraDemanded;
        uint128 supplyPulled;
        uint48 newTerm;
        OracleParams oracleParams;
    }

    struct OracleParams {
        uint48 settlementTime;
        uint24 disputeDelay;
        uint24 oracleGameFee;
        uint16 escalationFactor;
        uint8 initialLiquidity;
        uint16 multiplier;
        uint48 maxBaseFee;
        uint64 finalizerReward;
    }

    // -------------------------------------------------------------------------
    //                                  Events
    // -------------------------------------------------------------------------

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
    //                          Public state (auto-getters)
    // -------------------------------------------------------------------------

    function oracle() external view returns (IOpenOracle2);
    function feeReceiverImpl() external view returns (address);
    function WETH() external view returns (address);
    function nextLendingId() external view returns (uint256);
    function lendingArrangements(uint256 lendingId) external view returns (LendingArrangement memory);
    function lendingToReportId(uint256 lendingId) external view returns (uint256);
    function tempHolding(address user, address token) external view returns (uint256);
    function refiDelegation(uint256 lendingId) external view returns (address);
    function lenderDelegation(uint256 lendingId) external view returns (address);

    // -------------------------------------------------------------------------
    //                              State-changing
    // -------------------------------------------------------------------------

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
    ) external payable returns (uint256 lendingId);

    function setRefiDelegate(uint256 lendingId, address delegate) external;

    function cancelBorrowRequest(uint256 lendingId) external;

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
    ) external payable;

    function setLenderDelegate(uint256 lendingId, address delegate) external;

    function repayDebt(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal,
        bool mustClose
    ) external payable;

    function repayAnyDebt(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal,
        bool mustClose
    ) external payable;

    function topUpCollateral(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal
    ) external payable;

    function topUpCollateralAnyone(
        uint256 lendingId,
        uint128 amount,
        bytes32 expectedParamHash,
        uint128 expectedMinSupply,
        uint128 expectedMaxPrincipal
    ) external payable;

    function claimCollateral(uint256 lendingId) external;

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
    ) external payable;

    function cancelRefinance(uint256 lendingId) external;

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
    ) external payable;

    function finalize(uint256 lendingId) external;

    function getTempHolding(address tokenToGet) external;
}
