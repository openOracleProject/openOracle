// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle} from "./interfaces/IOpenOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {oracleFeeReceiver} from "./oracleFeeReceiver.sol";

/* ------------ openLending v1 ------------ */
// Uses openOracle: https://docs.openoracle.org
// TODO: improve grace period mechanics in context of variable settlement time (300 currently hard coded as part of the input)

contract openLending is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IOpenOracle public immutable oracle;
    address public immutable feeReceiverImpl;

    error InvalidInput(string);

    uint256 nextLendingId = 1;

    mapping(uint256 => LendingArrangement) public lendingArrangements;
    mapping(uint256 => uint256) public reportIdToLending;
    mapping(address => mapping(address => uint256)) public tempHolding;
    mapping(address => bool) private _oracleApproved;

    constructor(IOpenOracle _oracle) {
        oracle = _oracle;
        feeReceiverImpl = address(new oracleFeeReceiver());
    }

    /// @review - this struct could be packed more tightly, but maybe you specifically ordered it like this for better readability
    struct LendingArrangement {
        uint128 supplyAmount; // amount supplied as collateral
        uint128 borrowAmount; // amount borrowed at time of loan origination

        uint128 amountDemanded; // amount demanded by borrower
        uint128 repaidDebt; // amount of debt repaid

        address borrower; // borrower address
        uint48 term; // length of loan in seconds
        uint48 start; // timestamp loan began
        uint24 refiOfferNonce; // unique identification number of refinancing round (one per new loan)

        address lender; // lender address
        uint48 offerNumber; // lender's offer number for original borrow request
        uint48 offerExpiration; // timestamp lenders must submit offers by, for original borrow request. NOTE: IS THIS EVEN NECESSARY?
        uint32 rate; // 1e8 = 10%, annual interest rate
        uint16 stake; // 100 = 1%. stake * supplyAmount is how much liquidator must wager openOracle resolves to liquidation.
        bool allowAnyLiquidator; // lender allows anyone to liquidate the loan, splitting profits 50/50

        address liquidator; // liquidator address
        uint48 liquidationStart; // timestamp where the liquidation started
        uint48 gracePeriod; // extra time to repay debt / accept refinance offer if liquidation oracle game runs past maturity
        bool cancelled; // borrow request cancelled by borrower
        /// @review: active is redundant, we can check if lender != address(0) to determine if offer has been accepted and loan is active. This would save a bit of storage and complexity
        bool active; // offer accepted and loan is live
        bool inLiquidation; // loan is in liquidation (oracle game is running)
        bool finished; // loan has been liquidated or repaid

        address supplyToken; // supply token
        uint24 liquidationThreshold; // 8e6 = 80%. when accrued debt > liquidationThreshold * supplyAmount, liquidation is possible
        uint48 refiOfferNumber; // lender's offer number for refi instance

        address borrowToken; // borrow token
        address feeRecipient; // contract that receives protocol fees from oracle game

        RefiParams refiParams; // parameters for borrower's next refinance
        OracleParams oracleParams; // parameters for oracle game

        mapping(uint256 => LendingOffers) lendingOffers;
        mapping(uint256 => mapping(uint256 => RefiLendingOffers)) refiLendingOffers;
        /// @review - refiNonceAccepted can be removed, we can simply check if the refi offer chosen for a given nonce has been accepted or not. This would save a bit of storage and complexity
        mapping(uint256 => bool) refiNonceAccepted;
        mapping(address => Beneficiaries) feeRecipientToBeneficiaries;
    }

    struct LendingOffers {
        address lender; // lender address of this offer
        uint48 offerTime; // time of offer
        uint32 rate; // 1e8 = 10%, interest rate offered
        bool cancelled; // offer has been cancelled by prospective lender. must wait 60 seconds after offerTime
        bool chosen; // offer has been accepted by borrower
        uint128 amount; // amount offered.
        bool allowAnyLiquidator; // lender allows anyone to liquidate the loan, splitting profits 50/50
    }

    struct RefiLendingOffers {
        uint128 amount; // amount of this refi offer.
        uint128 repaidDebtAtRefiOfferTime; // borrower's repaid debt at refi offer time
        address lender; // lender address of this refi offer
        uint48 refiOfferTime; // time of refi offer by prospective lender
        uint32 rate; // 1e8 = 10%, interest rate offered
        bool cancelled; // refi offer has been cancelled by prospective lender. must wait 60 seconds after refiOfferTime
        bool chosen; // refi offer has been accepted by borrower
        bool allowAnyLiquidator; // lender allows anyone to liquidate the loan, splitting remaining equity 50/50
    }

    struct RefiParams {
        uint128 extraDemanded; // extra borrow demanded by borrower on refi
        uint128 supplyPulled; //  supplyAmount pulled out by borrower on refi
        bool set; // true means RefiParams have been set, borrower can only change params once per term ahead of refi
    }

    struct OracleParams {
        uint48 settlementTime; // settlementTime of oracle game in seconds
        uint24 disputeDelay; // oracle game disputeDelay
        uint24 oracleGameFee; // oracle game fees, routed to feeRecipient beneficiaries, 10000 = 0.1%
        uint16 escalationFactor; // escalationFactor * supplyAmount = escalationHalt in oracle game, 250 => 2.5 * supplyAmount
        uint16 initialLiquidity; // fraction of supplyAmount for oracle game initial liquidity in token1, 10 = 10%.
        uint16 multiplier; // oracle game per-round multiplier, 140 = 1.4x
    }

    struct Beneficiaries {
        address lender;
        // review: borrower could be removed since it never changes for a lending arrangement
        address borrower;
        address liquidator;
    }

    event BorrowRequested(
        address indexed borrower,
        uint256 indexed lendingId,
        address supplyToken,
        address borrowToken,
        uint256 supplyAmount,
        uint24 liquidationThreshold,
        uint256 offerExpiration,
        uint256 stake,
        OracleParams oracleParams
    );
    event BorrowOffered(address indexed lender, uint256 indexed lendingId, uint256 amount, uint32 rate);
    event RefiBorrowOffered(
        address indexed lender, uint256 indexed lendingId, uint32 rate, uint256 refiNonce, uint256 refiOfferNumber
    );
    event BorrowRequestCancelled(address indexed borrower, uint256 indexed lendingId);
    event BorrowOfferCancelled(uint256 lendingId, uint256 offerNumber);
    event RefiBorrowOfferCancelled(uint256 lendingId, uint256 refiOfferNumber, uint256 refiNonce);
    event OfferAccepted(uint256 lendingId, uint256 offerNumber);
    event RefiOfferAccepted(uint256 lendingId, uint256 refiOfferNumber, uint256 refiNonce);
    event LoanLiquidationUnderway(uint256 lendingId, uint256 reportId, address feeRecipient);
    event DebtRepaid(uint256 lendingId, uint256 amount);
    event CollateralToppedOff(uint256 lendingId, uint256 amount);
    event CollateralClaimedByLender(uint256 lendingId, uint256 supplyTokenClaimed, uint256 borrowTokenClaimed);
    event RefiParamsUpdated(uint256 lendingId, uint256 extraBorrowDemanded, uint256 supplyPulled);
    event LiqFinishedUnderwater(uint256 lendingId);
    event LiqFinishedWithBuffer(uint256 lendingId);
    event LiqUnsuccessful(uint256 lendingId);

    /**
     * @notice Requests a borrow and transfers supplyAmount of supplyToken into the contract
     * @param term Length of loan in seconds
     * @param offerExpiration Timestamp lenders must submit offers by
     * @param supplyToken Supplied collateral's token address
     * @param borrowToken Borrowed token's address
     * @param liquidationThreshold 8e6 = 80%. when accrued debt > liquidationThreshold * supplyAmount, liquidation is possible
     * @param supplyAmount Amount supplied as collateral
     * @param amountDemanded Amount to borrow
     * @param stake 100 = 1%. stake * supplyAmount is how much liquidator must wager openOracle resolves to liquidation
     * @param oracleParams Oracle game paramters: settlementTime, escalationFactor, initialLiquidity
     * @return lendingId Unique identification number of lending instance
     */
    function requestBorrow(
        uint48 term,
        uint48 offerExpiration,
        address supplyToken,
        address borrowToken,
        uint24 liquidationThreshold,
        uint128 supplyAmount,
        uint128 amountDemanded,
        uint128 stake,
        OracleParams memory oracleParams
    ) external nonReentrant returns (uint256 lendingId) {
        uint256 currentTime = uint48(block.timestamp);
        uint48 settlementTime = oracleParams.settlementTime;
        uint16 escalationFactor = oracleParams.escalationFactor;
        uint128 initialLiquidity = oracleParams.initialLiquidity;
        uint16 multiplier = oracleParams.multiplier;

        if (offerExpiration > currentTime + 60 * 60 * 24 || offerExpiration <= currentTime) {
            revert InvalidInput("offerExpiration out of bounds");
        }
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
        if (term < 300 || term > 60 * 60 * 24 * 365 * 10) revert InvalidInput("term too low");
        if (uint256(supplyAmount) + uint256(supplyAmount) * stake / 10000 > type(uint128).max) {
            revert InvalidInput("supply + stake too high");
        }

        if (oracleParams.oracleGameFee > 1e6) revert InvalidInput("oracle game fees too high");
        if (multiplier < 100 || multiplier > 1000) revert InvalidInput("oracle game multiplier out of bounds");
        if (oracleParams.disputeDelay >= settlementTime) revert InvalidInput("disputeDelay >= settlementTime");

        uint256 escHalt = uint256(supplyAmount) * oracleParams.escalationFactor / 100;
        if (escHalt > type(uint128).max) revert InvalidInput("escalation halt too high");

        lendingId = nextLendingId++;
        LendingArrangement storage lending = lendingArrangements[lendingId];

        lending.term = term;
        lending.offerExpiration = offerExpiration;
        lending.supplyToken = supplyToken;
        lending.borrowToken = borrowToken;
        lending.supplyAmount = supplyAmount;
        lending.liquidationThreshold = liquidationThreshold;
        lending.amountDemanded = amountDemanded;
        lending.stake = uint16(stake);
        lending.offerNumber = 1;
        lending.refiOfferNumber = 1;
        lending.refiOfferNonce = 1;
        lending.borrower = msg.sender;
        lending.oracleParams = oracleParams;

        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), supplyAmount);

        emit BorrowRequested(
            msg.sender,
            lendingId,
            supplyToken,
            borrowToken,
            supplyAmount,
            liquidationThreshold,
            offerExpiration,
            stake,
            oracleParams
        );
        return lendingId;
    }

    /**
     * @notice Cancels borrow request and returns collateral back to borrower
     * @param lendingId Unique identification number of lending instance
     */
    function cancelBorrowRequest(uint256 lendingId) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        address sender = msg.sender;

        if (lending.cancelled) revert InvalidInput("lendingId cancelled");
        if (lending.active) revert InvalidInput("lendingId active");
        if (lending.borrower != msg.sender) revert InvalidInput("msg.sender");

        lending.cancelled = true;

        IERC20(lending.supplyToken).safeTransfer(sender, lending.supplyAmount);
        emit BorrowRequestCancelled(sender, lendingId);
    }

    /**
     * @notice Offers a loan to borrower and transfers loan amount into the contract
     * @param lendingId Unique identification number of lending instance
     * @param amount Amount borrower requests
     * @param rate Interest rate offered, 1e8 = 10%
     * @param allowAnyLiquidator Allows anyone to liquidate the loan and split remaining equity 50/50 with lender
     * @return offerNumber Unique identification number of loan offer
     */
    function offerBorrow(uint256 lendingId, uint128 amount, uint32 rate, bool allowAnyLiquidator)
        external
        nonReentrant
        returns (uint256 offerNumber)
    {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        offerNumber = lending.offerNumber;
        LendingOffers storage offers = lending.lendingOffers[offerNumber];

        uint48 currentTime = uint48(block.timestamp);
        address sender = msg.sender;
        address borrowToken = lending.borrowToken;
        uint256 owedAtMaturity = totalOwedAtMaturity(amount, rate, lending.term);

        if (lending.cancelled) revert InvalidInput("lendingId cancelled");
        if (lending.active) revert InvalidInput("lendingId active");
        if (lending.finished) revert InvalidInput("lendingId finished");
        if (sender == lending.borrower) revert InvalidInput("lender == borrower");
        if (currentTime > lending.offerExpiration) revert InvalidInput("offer period expired");
        if (amount != lending.amountDemanded) revert InvalidInput("amount wrong");
        if (owedAtMaturity > type(uint128).max) revert InvalidInput("owedAtMaturity too high");

        offers.lender = sender;
        offers.amount = amount;
        offers.rate = rate;
        offers.allowAnyLiquidator = allowAnyLiquidator;
        offers.offerTime = currentTime;

        lending.offerNumber += 1;

        IERC20(borrowToken).safeTransferFrom(sender, address(this), amount);

        emit BorrowOffered(sender, lendingId, amount, rate);

        return offerNumber;
    }

    // todo: maybe prevent lenders from cancelling refi offers if too close to maturity?
    /**
     * @notice Offers a refinancing loan to borrower and transfers net refi amount demanded into the contract
     * @param lendingId Unique identification number of lending instance
     * @param rate Interest rate offered, 1e8 = 10%
     * @param allowAnyLiquidator Allows anyone to liquidate the loan and split remaining equity 50/50 with lender
     * @param repaidDebtExpected Amount borrower has already repaid in the existing loan
     * @param extraDemandedExpected Extra borrow amount borrower has requested on top of existing net loan amount
     * @param minSupplyPostRefi Minimum supplied collateral tolerated post refinancing
     * @return refiOfferNumber Unique identification number of refi loan offer
     * @return refiNonce Unique identification number of refinancing round (one per new loan)
     */
    function offerRefiBorrow(
        uint256 lendingId,
        uint32 rate,
        bool allowAnyLiquidator,
        uint128 repaidDebtExpected,
        uint128 extraDemandedExpected,
        uint256 minSupplyPostRefi
    ) external nonReentrant returns (uint256 refiOfferNumber, uint256 refiNonce) {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        refiNonce = lending.refiOfferNonce;
        refiOfferNumber = lending.refiOfferNumber;
        RefiLendingOffers storage refi = lending.refiLendingOffers[refiNonce][refiOfferNumber];

        address sender = msg.sender;
        uint256 currentTime = block.timestamp;
        uint128 repaidDebt = lending.repaidDebt;
        address borrowToken = lending.borrowToken;
        uint48 term = lending.term;
        uint128 extraDemanded = lending.refiParams.extraDemanded;
        uint128 supplyPulled = lending.refiParams.supplyPulled;
        bool refiParamsSet = lending.refiParams.set;
        uint128 supplyAmount = lending.supplyAmount;

        if (lending.cancelled) revert InvalidInput("lendingId cancelled");
        if (!lending.active) revert InvalidInput("lendingId not active");
        if (lending.finished) revert InvalidInput("lendingId finished");
        if (sender == lending.borrower) revert InvalidInput("lender == borrower");
        if (currentTime >= lending.start + lending.term + lending.gracePeriod) revert InvalidInput("expired");
        if (repaidDebt != repaidDebtExpected) revert InvalidInput("repaid debt mismatch");
        if (extraDemanded != extraDemandedExpected) revert InvalidInput("extra demanded mismatch");
        if (supplyPulled > supplyAmount) revert InvalidInput("supplyPulled too high");
        if (supplyAmount - supplyPulled < minSupplyPostRefi) revert InvalidInput("min supply post refi");
        if (!refiParamsSet) revert InvalidInput("refi params not set");

        uint256 amount = totalOwedAtMaturity(lending.borrowAmount, lending.rate, term);
        if (repaidDebt > amount) revert InvalidInput("repaid debt > owed"); //shouldnt ever happen though

        amount -= repaidDebt;
        amount += extraDemanded;

        if (amount > type(uint128).max) revert InvalidInput("refi amount too large");
        uint256 newOwedAtMaturity = totalOwedAtMaturity(amount, rate, term);
        if (newOwedAtMaturity > type(uint128).max) revert InvalidInput("owedAtMaturity too high");

        lending.refiOfferNumber += 1;

        refi.lender = sender;
        refi.rate = rate;
        refi.amount = uint128(amount);
        refi.allowAnyLiquidator = allowAnyLiquidator;
        refi.repaidDebtAtRefiOfferTime = repaidDebt;
        refi.refiOfferTime = uint48(currentTime);

        IERC20(borrowToken).safeTransferFrom(sender, address(this), amount);

        emit RefiBorrowOffered(sender, lendingId, rate, refiNonce, refiOfferNumber);

        return (refiOfferNumber, refiNonce);
    }

    /**
     * @notice Cancels borrow offer and returns loan amount back to lender
     * @param lendingId Unique identification number of lending instance
     * @param offerNumber Unique identification number of lender's original offer
     */
    function cancelBorrowOffer(uint256 lendingId, uint256 offerNumber) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        LendingOffers storage offer = lending.lendingOffers[offerNumber];

        uint256 amount = offer.amount;
        address lender = offer.lender;
        bool chosen = offer.chosen;
        bool cancelled = offer.cancelled;
        uint256 offerTime = offer.offerTime;
        address borrowToken = lending.borrowToken;

        if (msg.sender != lender) revert InvalidInput("msg.sender");
        if (amount == 0) revert InvalidInput("no borrow offer");
        if (chosen) revert InvalidInput("chosen");
        if (cancelled) revert InvalidInput("cancelled");
        if (block.timestamp < offerTime + 60) revert InvalidInput("cancel too soon");

        offer.amount = 0;
        offer.cancelled = true;

        IERC20(borrowToken).safeTransfer(lender, amount);

        emit BorrowOfferCancelled(lendingId, offerNumber);
    }

    /**
     * @notice Cancels refi offer and returns loan amount back to lender
     * @param lendingId Unique identification number of lending instance
     * @param refiNonce Unique identification number of refinancing round (one per new loan)
     * @param refiOfferNumber Unique identification number of lender's refi offer
     */
    function cancelRefiBorrowOffer(uint256 lendingId, uint256 refiNonce, uint256 refiOfferNumber)
        external
        nonReentrant
    {
        RefiLendingOffers storage refi = lendingArrangements[lendingId].refiLendingOffers[refiNonce][refiOfferNumber];

        uint256 amount = refi.amount;
        address lender = refi.lender;
        bool chosen = refi.chosen;
        bool cancelled = refi.cancelled;
        uint256 refiOfferTime = refi.refiOfferTime;

        address borrowToken = lendingArrangements[lendingId].borrowToken;

        if (msg.sender != lender) revert InvalidInput("msg.sender");
        if (chosen) revert InvalidInput("chosen");
        if (cancelled) revert InvalidInput("cancelled");
        if (block.timestamp < refiOfferTime + 60) revert InvalidInput("cancel too soon");

        refi.amount = 0;
        refi.cancelled = true;

        IERC20(borrowToken).safeTransfer(lender, amount);

        emit RefiBorrowOfferCancelled(lendingId, refiOfferNumber, refiNonce);
    }

    /**
     * @notice Accepts offer for loan and transfers borrowed amount to borrower
     * @param lendingId Unique identification number of lending instance
     * @param offerNumber Unique identification number of lender's original offer
     */
    function acceptOffer(uint256 lendingId, uint256 offerNumber) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        LendingOffers storage offer = lending.lendingOffers[offerNumber];

        uint48 currentTime = uint48(block.timestamp);

        if (lending.cancelled) revert InvalidInput("lendingId cancelled");
        if (lending.active) revert InvalidInput("lendingId active");
        if (lending.finished) revert InvalidInput("lendingId finished");
        if (lending.borrower != msg.sender) revert InvalidInput("msg.sender");
        if (offer.cancelled) revert InvalidInput("offer cancelled");
        if (offer.chosen) revert InvalidInput("offer already chosen");

        uint128 amount = offer.amount;
        if (amount == 0) revert InvalidInput("no offer");
        address borrowToken = lending.borrowToken;

        offer.chosen = true;

        lending.active = true;
        lending.rate = offer.rate;
        lending.lender = offer.lender;
        lending.borrowAmount = amount;
        lending.start = currentTime;
        lending.allowAnyLiquidator = offer.allowAnyLiquidator;

        IERC20(borrowToken).safeTransfer(msg.sender, amount);

        emit OfferAccepted(lendingId, offerNumber);
    }

    /**
     * @notice Accepts refinancing offer, transfers net new borrowed amount to borrower and transfers old loan amount due at maturity to previous lender
     * @param refiOfferNumber Unique identification number of lender's refi offer
     * @param refiNonce Unique identification number of refinancing round (one per new loan)
     */
    function acceptRefiOffer(uint256 lendingId, uint256 refiOfferNumber, uint256 refiNonce) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        RefiLendingOffers storage refi = lending.refiLendingOffers[refiNonce][refiOfferNumber];

        uint256 currentTime = block.timestamp;
        address borrower = lending.borrower;
        uint48 term = lending.term;
        address prevLender = lending.lender;
        uint256 repaidDebt = lending.repaidDebt;
        uint256 owed = totalOwedAtMaturity(lending.borrowAmount, lending.rate, term);
        address borrowToken = lending.borrowToken;
        address supplyToken = lending.supplyToken;
        uint256 extraDemanded;
        uint128 supplyPulled;

        if (lending.cancelled) revert InvalidInput("lendingId cancelled");
        if (!lending.active) revert InvalidInput("lendingId not active");
        if (lending.finished) revert InvalidInput("lendingId finished");
        if (lending.inLiquidation) revert InvalidInput("lendingId in liquidation");
        if (refi.chosen) revert InvalidInput("refi already chosen");
        if (borrower != msg.sender) revert InvalidInput("msg.sender");
        if (lending.refiNonceAccepted[refiNonce]) revert InvalidInput("refi nonce already accepted");
        if (currentTime >= lending.start + term + lending.gracePeriod) revert InvalidInput("expired");
        if (refi.cancelled) revert InvalidInput("refi offer cancelled");
        if (refi.amount == 0) revert InvalidInput("no refi offer");
        if (refi.repaidDebtAtRefiOfferTime != repaidDebt) revert InvalidInput("repaid debt changed");

        if (lending.refiParams.set) {
            extraDemanded = lending.refiParams.extraDemanded;
            supplyPulled = lending.refiParams.supplyPulled;
        } else {
            extraDemanded = 0;
            supplyPulled = 0;
        }

        refi.chosen = true;

        lending.refiNonceAccepted[refiNonce] = true;
        lending.refiOfferNonce += 1;
        lending.refiOfferNumber = 1;
        // A fresh fee receiver is only created if a future liquidation actually needs one.
        lending.feeRecipient = address(0);
        lending.rate = refi.rate;
        lending.lender = refi.lender;
        lending.borrowAmount = refi.amount;
        lending.start = uint48(currentTime);
        lending.allowAnyLiquidator = refi.allowAnyLiquidator;
        lending.gracePeriod = 0;
        lending.repaidDebt = 0;
        lending.liquidator = address(0);
        lending.liquidationStart = 0; //should be fine already from other logic
        lending.supplyAmount -= supplyPulled;

        lending.refiParams.extraDemanded = 0;
        lending.refiParams.supplyPulled = 0;
        lending.refiParams.set = false;

        _transferTokens(borrowToken, address(this), prevLender, owed);

        if (extraDemanded > 0) {
            IERC20(borrowToken).safeTransfer(borrower, extraDemanded);
        }

        if (supplyPulled > 0) {
            IERC20(supplyToken).safeTransfer(borrower, supplyPulled);
        }

        emit RefiOfferAccepted(lendingId, refiOfferNumber, refiNonce);
    }

    // cant be anyone-can-call because of refi invalidation griefing
    /**
     * @notice Repays debt and transfers borrowToken into contract, reducing liquidation risk.
     *            If repaid amount is enough to fully pay back total owed, lender is paid back fully and borrower gets collateral back.
     *            Cannot repay debt during oracle game liquidation.
     *            If liquidation attempt ends too close to maturity, a short grace period is offered to repay debt or accept refinancing offer.
     *            Only borrower can call.
     *            Repaid debt voids prior refi offers.
     * @param lendingId Unique identification number of lending instance
     * @param amount Amount of debt to repay
     */
    function repayDebt(uint256 lendingId, uint128 amount) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];

        uint256 currentTime = block.timestamp;
        address sender = msg.sender;
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
        if (sender != borrower) revert InvalidInput("not borrower");
        if (currentTime >= lending.start + term + lending.gracePeriod) revert InvalidInput("expired");

        if (amount >= netTerminalDebt) {
            lending.finished = true;
            IERC20(borrowToken).safeTransferFrom(sender, address(this), netTerminalDebt);
            _transferTokens(borrowToken, address(this), lender, owedAtMaturity);
            IERC20(lending.supplyToken).safeTransfer(borrower, supplied);
        } else {
            lending.repaidDebt += amount;
            IERC20(borrowToken).safeTransferFrom(sender, address(this), amount);
        }

        emit DebtRepaid(lendingId, amount);
    }

    /**
     * @notice Tops up supplied collateral and transfers supplyToken into contract, reducing liquidation risk.
     *            Cannot top up collateral during oracle game liquidation.
     *            Anyone can call.
     * @param lendingId Unique identification number of lending instance
     * @param amount Amount of collateral to add to lending position
     */
    function topUpCollateralAnyone(uint256 lendingId, uint128 amount) external nonReentrant {
        _topUpCollateral(lendingId, amount);
    }

    /**
     * @notice Tops up supplied collateral and transfers supplyToken into contract, reducing liquidation risk.
     *            Cannot top up collateral during oracle game liquidation.
     *            Only borrower can call.
     * @param lendingId Unique identification number of lending instance
     * @param amount Amount of collateral to add to lending position
     */
    function topUpCollateral(uint256 lendingId, uint128 amount) external nonReentrant {
        if (msg.sender != lendingArrangements[lendingId].borrower) revert InvalidInput("not borrower");
        _topUpCollateral(lendingId, amount);
    }

    function _topUpCollateral(uint256 lendingId, uint128 amount) internal {
        LendingArrangement storage lending = lendingArrangements[lendingId];

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

        lending.supplyAmount += amount;

        IERC20(lending.supplyToken).safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralToppedOff(lendingId, amount);
    }

    /**
     * @notice Lender can claim borrower's supplied collateral and any repaid debt if full loan is not paid back or refinanced at maturity.
     *            Respects extra grace period for borrower under late oracle game liquidation attempts.
     *            Anyone can call.
     * @param lendingId Unique identification number of lending instance
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
        if (currentTime < lending.start + lending.term + lending.gracePeriod) revert InvalidInput("not expired");

        lending.finished = true;

        IERC20(lending.supplyToken).safeTransfer(lender, supplyAmount);
        if (repaidDebt > 0) {
            IERC20(lending.borrowToken).safeTransfer(lender, repaidDebt);
        }
        emit CollateralClaimedByLender(lendingId, supplyAmount, repaidDebt);
    }

    /**
     * @notice Borrower can set refinancing parameters to refinance their loan
     *            Can only be set once per loan, ahead of prospective refi
     * @param lendingId Unique identification number of lending instance
     * @param extraDemanded Extra amount to borrow on refi
     * @param supplyPulled Amount of supply to pull out on refi
     */
    function changeRefiParams(uint256 lendingId, uint128 extraDemanded, uint128 supplyPulled) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        RefiParams storage refiParams = lending.refiParams;

        if (msg.sender != lending.borrower) revert InvalidInput("not borrower");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.finished) revert InvalidInput("finished");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (refiParams.set) revert InvalidInput("params already set");
        if (supplyPulled >= lending.supplyAmount) revert InvalidInput("supplyPulled too high");

        refiParams.extraDemanded = extraDemanded;
        refiParams.supplyPulled = supplyPulled;
        refiParams.set = true;

        emit RefiParamsUpdated(lendingId, extraDemanded, supplyPulled);
    }

    // borrower owes this amount to lender no matter when they pay debt back or refinance
    function totalOwedAtMaturity(uint256 amount, uint256 rate, uint256 term) internal pure returns (uint256) {
        uint256 interest;
        uint256 year = 365 * 24 * 60 * 60;
        interest = amount * term * rate / (1e9 * year);
        return amount + interest;
    }

    // borrower's debt is this number during liquidation
    function totalOwedNow(uint256 amount, uint256 rate, uint256 term, uint256 start) internal view returns (uint256) {
        uint256 currentTime = block.timestamp;
        uint256 interest;
        uint256 year = 365 * 24 * 60 * 60;
        uint256 elapsed = currentTime > start ? currentTime - start : 0;
        if (elapsed > term) elapsed = term;
        interest = amount * elapsed * rate / (1e9 * year);
        return amount + interest;
    }

    function _ensureOracleApproval(address token) internal {
        if (!_oracleApproved[token]) {
            IERC20(token).forceApprove(address(oracle), type(uint256).max);
            _oracleApproved[token] = true;
        }
    }

    /**
     * @notice Liquidator bets the stake % * suppliedAmount that the oracle game will resolve to a price that liquidates the borrower.
     *            Liquidator submits an initial report in the oracle game and transfers tokens to oracle contract.
     *            Borrower cannot pay back debt or top up collateral during liquidation.
     *            If liquidation is unsuccessful, stake is given to borrower.
     *            If liquidation is successful, liquidator gets their stake back and splits remaining equity 50/50 with lender.
     *            Lender receives all remaining collateral after liquidator split.
     *            Message value should be equal to (1e15) wei. Liquidator receives excess over 1e15 back.
     * @param lendingId Unique identification number of lending instance
     * @param expectedCollateral Amount of supplied collateral expected
     * @param expectedRepaidDebt Amount of repaid debt expected
     * @param oracleAmount2 Amount of borrowToken submitted in the oracle game initial report. Must be an amount of borrowToken that is equal in value to expectedInitialLiquidity of supplyToken.
     * @param expectedBorrowAmount Borrow amount expected (borrowAmount in the lendingId)
     * @param expectedLoanStart Timestamp of loan start expected (start in the lendingId)
     * @param expectedStake Amount of supplyToken the liquidator is expected to wager on a successful liquidation
     * @param expectedInitialLiquidity Amount of supplyToken the liquidator expects to submit in the oracle game initial report as token1.
     */
    function liquidate(
        uint256 lendingId,
        uint128 expectedCollateral,
        uint128 expectedRepaidDebt,
        uint128 oracleAmount2,
        uint128 expectedBorrowAmount,
        uint48 expectedLoanStart,
        uint256 expectedStake,
        uint128 expectedInitialLiquidity
    ) external payable nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        OracleParams storage oracleParams = lending.oracleParams;

        uint256 currentTime = block.timestamp;
        uint48 start = lending.start;
        uint128 supplyAmount = lending.supplyAmount;
        address borrowToken = lending.borrowToken;
        address supplyToken = lending.supplyToken;
        address feeRecipient;
        uint256 tokenStake = uint256(supplyAmount) * lending.stake / 10000;
        uint256 initialLiquidity = uint256(supplyAmount) * oracleParams.initialLiquidity / 100;
        uint256 escHalt = uint256(supplyAmount) * oracleParams.escalationFactor / 100;

        if (lending.inLiquidation) revert InvalidInput("in liquidation");
        if (lending.finished) revert InvalidInput("arrangement finished");
        if (!lending.active) revert InvalidInput("not active");
        if (lending.cancelled) revert InvalidInput("cancelled");
        if (!lending.allowAnyLiquidator && msg.sender != lending.lender) revert InvalidInput("wrong liquidator");
        if (supplyAmount != expectedCollateral) revert InvalidInput("expected collateral");
        if (lending.repaidDebt != expectedRepaidDebt) revert InvalidInput("expected repaid debt");
        if (lending.borrowAmount != expectedBorrowAmount) revert InvalidInput("expected borrow amount");
        if (start != expectedLoanStart) revert InvalidInput("expected loan start");
        if (tokenStake != expectedStake) revert InvalidInput("expected stake");
        if (initialLiquidity != expectedInitialLiquidity) revert InvalidInput("initial liquidity expected");
        if (msg.value != 1e15) revert InvalidInput("msg.value != 1e15");
        if (currentTime > start + lending.term) revert InvalidInput("arrangement expired");

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
            lending.feeRecipientToBeneficiaries[feeRecipient].lender = lending.lender;
            lending.feeRecipientToBeneficiaries[feeRecipient].borrower = lending.borrower;
            lending.feeRecipientToBeneficiaries[feeRecipient].liquidator = msg.sender;
        }

        uint256 reportId = oracle.createReportInstance{value: msg.value}(params);

        reportIdToLending[reportId] = lendingId;

        uint256 amount1 = initialLiquidity;

        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), amount1 + tokenStake);
        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), oracleAmount2);

        _ensureOracleApproval(supplyToken);
        _ensureOracleApproval(borrowToken);

        oracle.submitInitialReport(
            reportId, uint128(amount1), oracleAmount2, oracle.extraData(reportId).stateHash, msg.sender
        );

        emit LoanLiquidationUnderway(lendingId, reportId, feeRecipient);
    }

    function _deployFeeReceiver(uint256 lendingId, address supplyToken, address borrowToken)
        internal
        returns (address feeReceiver)
    {
        feeReceiver = Clones.clone(feeReceiverImpl);
        oracleFeeReceiver(feeReceiver).initialize(
            address(this), uint128(lendingId), address(oracle), supplyToken, borrowToken
        );
    }

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

    /* -------- oracle callback -------- */
    function onSettle(uint256 id, uint256, uint256, /* ts   (unused) */ address, address)
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
        uint256 borrowValueInSupplyTerms = (borrowValue * oracleAmount1) / oracleAmount2;
        uint256 liqThresh = uint256(supplyAmount) * lending.liquidationThreshold / 1e7;

        lending.inLiquidation = false;
        if (liqThresh < borrowValueInSupplyTerms) {
            lending.finished = true;
            _transferTokens(lending.borrowToken, address(this), lender, repaidDebt);

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

            // grace period around liquidations that end either too close to maturity (5 minutes) or after it
            if (currentTime > start + term - 300) {
                lending.gracePeriod = 300 + (uint48(currentTime) - lending.liquidationStart) * 2;
            }
            lending.liquidationStart = 0;

            emit LiqUnsuccessful(lendingId);
        }

        address feeRecipient = lending.feeRecipient;
        if (feeRecipient != address(0)) {
            _grabOracleGameFees(lending, feeRecipient);
        }
    }

    /**
     * @notice Anyone can distribute protocol fees from a given feeRecipient contract.
     *            Eventual oracle game callback should always clear these tokens out anyways.
     * @param lendingId Unique identification number of lending instance
     */
    function grabOracleGameFeesAny(uint256 lendingId, address feeRecipient) external nonReentrant {
        LendingArrangement storage lending = lendingArrangements[lendingId];
        if (feeRecipient == address(0)) revert InvalidInput("no fee recipient");
        if (oracleFeeReceiver(feeRecipient).gameId() != lendingId) {
            revert InvalidInput("feeRecipient not for lendingId");
        }
        _grabOracleGameFees(lending, feeRecipient);
    }

    function _grabOracleGameFees(LendingArrangement storage lending, address feeRecipient) internal {
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

        address borrower = lending.feeRecipientToBeneficiaries[feeRecipient].borrower;
        address lender = lending.feeRecipientToBeneficiaries[feeRecipient].lender;
        address liquidator = lending.feeRecipientToBeneficiaries[feeRecipient].liquidator;

        _transferTokens(supplyToken, address(this), borrower, borrowerSupplyFeePiece);
        _transferTokens(supplyToken, address(this), lender, lenderSupplyFeePiece);
        _transferTokens(supplyToken, address(this), liquidator, liquidatorSupplyFeePiece);

        uint256 borrowerBorrowFeePiece = feesBorrow / 2;
        uint256 lenderBorrowFeePiece = borrowerBorrowFeePiece / 2;
        uint256 liquidatorBorrowFeePiece = feesBorrow - borrowerBorrowFeePiece - lenderBorrowFeePiece;

        _transferTokens(borrowToken, address(this), borrower, borrowerBorrowFeePiece);
        _transferTokens(borrowToken, address(this), lender, lenderBorrowFeePiece);
        _transferTokens(borrowToken, address(this), liquidator, liquidatorBorrowFeePiece);
    }

    /**
     * @dev Internal function to handle token transfers.
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

    /**
     * @notice Withdraws temp holdings for a specific token
     * @param tokenToGet The token address to withdraw tokens for
     */
    function getTempHolding(address tokenToGet) external nonReentrant {
        uint256 amount = tempHolding[msg.sender][tokenToGet];
        if (amount > 0) {
            tempHolding[msg.sender][tokenToGet] = 0;
            _transferTokens(tokenToGet, address(this), msg.sender, amount);
        }
    }

    // -------------------------------------------------------------------------
    //                              View functions
    // -------------------------------------------------------------------------

    struct LendingView {
        uint48 term;
        uint256 supplyAmount;
        uint256 borrowAmount;
        uint256 amountDemanded;
        uint256 repaidDebt;
        uint256 stake;
        uint24 liquidationThreshold;
        uint48 offerNumber;
        uint48 refiOfferNumber;
        uint48 offerExpiration;
        uint48 start;
        uint48 gracePeriod;
        uint48 liquidationStart;
        uint32 rate;
        address borrower;
        address lender;
        address liquidator;
        address supplyToken;
        address borrowToken;
        address feeRecipient;
        uint256 refiOfferNonce;
        bool cancelled;
        bool active;
        bool inLiquidation;
        bool finished;
        bool allowAnyLiquidator;
    }

    function getLending(uint256 lendingId) external view returns (LendingView memory) {
        LendingArrangement storage l = lendingArrangements[lendingId];
        return LendingView({
            term: l.term,
            supplyAmount: l.supplyAmount,
            borrowAmount: l.borrowAmount,
            amountDemanded: l.amountDemanded,
            repaidDebt: l.repaidDebt,
            stake: l.stake,
            liquidationThreshold: l.liquidationThreshold,
            offerNumber: l.offerNumber,
            refiOfferNumber: l.refiOfferNumber,
            offerExpiration: l.offerExpiration,
            start: l.start,
            gracePeriod: l.gracePeriod,
            liquidationStart: l.liquidationStart,
            rate: l.rate,
            borrower: l.borrower,
            lender: l.lender,
            liquidator: l.liquidator,
            supplyToken: l.supplyToken,
            borrowToken: l.borrowToken,
            feeRecipient: l.feeRecipient,
            refiOfferNonce: l.refiOfferNonce,
            cancelled: l.cancelled,
            active: l.active,
            inLiquidation: l.inLiquidation,
            finished: l.finished,
            allowAnyLiquidator: l.allowAnyLiquidator
        });
    }

    function getRefiParams(uint256 lendingId) external view returns (RefiParams memory) {
        return lendingArrangements[lendingId].refiParams;
    }

    function getOracleParams(uint256 lendingId) external view returns (OracleParams memory) {
        return lendingArrangements[lendingId].oracleParams;
    }

    function getBeneficiaries(uint256 lendingId, address feeRecipient) external view returns (Beneficiaries memory) {
        return lendingArrangements[lendingId].feeRecipientToBeneficiaries[feeRecipient];
    }

    function getLendingOffer(uint256 lendingId, uint256 offerNumber) external view returns (LendingOffers memory) {
        return lendingArrangements[lendingId].lendingOffers[offerNumber];
    }

    function getRefiLendingOffer(uint256 lendingId, uint256 refiNonce, uint256 refiOfferNumber)
        external
        view
        returns (RefiLendingOffers memory)
    {
        return lendingArrangements[lendingId].refiLendingOffers[refiNonce][refiOfferNumber];
    }

    function getRefiNonceAccepted(uint256 lendingId, uint256 refiNonce) external view returns (bool) {
        return lendingArrangements[lendingId].refiNonceAccepted[refiNonce];
    }
}
