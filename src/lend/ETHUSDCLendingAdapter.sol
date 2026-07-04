// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenLend} from "../interfaces/IOpenLend.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract openLendEthUsdcAdapter1 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IOpenLend public immutable openLend;
    address immutable weth;
    address immutable token1;
    address immutable token2;

    mapping(address => bool) private _openLendApproved;
    mapping (address => mapping (uint256 => uint256)) public userToBorrow;
    mapping (address => mapping (uint256 => uint256)) public userToLend;
    mapping (address => uint256) public userBorrowCount;
    mapping (address => uint256) public userLendCount;

    error InvalidParams();

    constructor (address _openLend, address _token1, address _token2) {
        IOpenLend lend = IOpenLend(_openLend);
        openLend = lend;
        weth = lend.WETH();
        token1 = _token1;
        token2 = _token2;
    }

    struct BorrowParams {
        uint48 term;
        address supplyToken;
        address borrowToken;
        uint24 liquidationThreshold;
        uint128 supplyAmount;
        uint128 amountDemanded;
        uint16 stake;
        uint24 commitmentFraction;
        uint96 gasCompensation;
        address borrower;
        IOpenLend.OracleParams oracleParams;
        IOpenLend.InterestRateParams interestRateParams;
    }

    struct LendParams {
        uint256 lendingId;
        bytes32 paramHashExpected;
        uint128 minLendAmount;
        uint128 maxLendAmount;
        uint128 expectedMinSupply;
        uint32 minRate;
        uint24 liquidatorFraction;
        address lender;
    }

    struct RefiAdapterParams {
        uint256 lendingId;
        uint128 extraDemanded;
        uint128 supplyPulled;
        uint48 newTerm;
        uint96 gasCompensation;
        IOpenLend.InterestRateParams interestRateParams;
        IOpenLend.OracleParams oracleParams;
        bytes32 expectedParamHash;
        uint128 expectedMinSupply;
        uint128 expectedMaxPrincipal;
    }

    function refinanceAdapter(RefiAdapterParams calldata params) external payable nonReentrant {
        uint256 lendingId = params.lendingId;
        IOpenLend.LendingArrangement memory lending = openLend.lendingArrangements(lendingId);
        uint256 balBeforeEth = address(this).balance - msg.value;
        uint256 balBeforeFallback = IERC20(weth).balanceOf(address(this));

        _validateGasCompensation(params.gasCompensation);
        _validateSender(lending.borrower);
        if (params.interestRateParams.maxRate != 0) _validateInterestRateParams(params.interestRateParams);
        if (params.oracleParams.settlementTime != 0) _validateOracleParams(params.oracleParams);
        if (params.newTerm != 0) _validateTerm(params.newTerm);
        if (msg.value != params.gasCompensation) revert InvalidParams();
        if (params.expectedParamHash == bytes32(0)) revert InvalidParams();

        openLend.refinance {value: msg.value} (
            lendingId,
            params.extraDemanded,
            params.supplyPulled,
            params.newTerm,
            params.gasCompensation,
            params.interestRateParams,
            params.oracleParams,
            params.expectedParamHash,
            params.expectedMinSupply,
            params.expectedMaxPrincipal
        );

        // refinance carries autoSettle: finalizing a settleable liquidation pays the finalizer bounty
        // to this adapter as msg.sender. Sweep any residual ETH/WETH back to the caller.
        uint256 sweptEth = address(this).balance - balBeforeEth;
        uint256 sweptWeth = IERC20(weth).balanceOf(address(this)) - balBeforeFallback;

        if (sweptWeth > 0) {
            IERC20(weth).safeTransfer(msg.sender, sweptWeth);
        }

        if (sweptEth > 0) {
            (bool ok,) = payable(msg.sender).call{value: sweptEth}("");
            if (!ok) revert InvalidParams();
        }
    }

    function requestBorrowAdapter(BorrowParams calldata params) external payable nonReentrant returns (uint256 lendingId) {

        address supplyToken = params.supplyToken;
        bool isEth = supplyToken == address(0);
        uint256 supplyAmount = params.supplyAmount;
        uint256 gasCompensation = params.gasCompensation;
        uint256 ethRequired = isEth ? supplyAmount + gasCompensation : gasCompensation;
        uint256 ubc = userBorrowCount[msg.sender];

        _validateBorrowParams(params);
        if (msg.value != ethRequired) revert InvalidParams();

        if (!isEth) {
            _pullToken(supplyToken, msg.sender, address(this), supplyAmount);
            _ensureOpenLendApproval(supplyToken);
        }

        lendingId = openLend.requestBorrow {value: ethRequired} (
            params.term,
            params.supplyToken,
            params.borrowToken,
            params.liquidationThreshold,
            params.supplyAmount,
            params.amountDemanded,
            params.stake,
            params.commitmentFraction,
            params.gasCompensation,
            params.borrower,
            address(this),
            params.oracleParams,
            params.interestRateParams
        );

        userToBorrow[msg.sender][ubc] = lendingId;
        userBorrowCount[msg.sender] += 1;

    }

    function lendAdapter(LendParams calldata params, uint128 amount) external payable nonReentrant {
        uint256 lendingId = params.lendingId;
        IOpenLend.LendingArrangement memory lending = openLend.lendingArrangements(lendingId);

        address borrowToken = lending.borrowToken;
        bool isEth = borrowToken == address(0);
        uint256 balBeforeEth = address(this).balance - msg.value;
        uint256 balBeforeFallback = IERC20(weth).balanceOf(address(this));
        bool isRefi = lending.active && lending.curveOpen;
        uint256 ulc = userLendCount[msg.sender];

        uint256 balBeforeToken;
        uint256 refundTokenAmount;

        _validateLendParams(lending, params.lender, isRefi);
        if (params.paramHashExpected == bytes32(0)) revert InvalidParams();
        if (params.liquidatorFraction > 6e6) revert InvalidParams();
        if (!isEth && msg.value > 0) revert InvalidParams();
        if (!lending.active && isEth && (amount != lending.principal || msg.value != amount)) {
            revert InvalidParams();
        }
        if (!lending.active && !isEth && amount != lending.principal) revert InvalidParams();

        userToLend[msg.sender][ulc] = lendingId;
        userLendCount[msg.sender] += 1;

        if (!isEth) {
            balBeforeToken = IERC20(borrowToken).balanceOf(address(this));
            _pullToken(borrowToken, msg.sender, address(this), amount);
            _ensureOpenLendApproval(borrowToken);
        }

        openLend.lend {value: msg.value} (
            params.lendingId,
            params.paramHashExpected,
            params.minLendAmount,
            params.maxLendAmount,
            params.expectedMinSupply,
            params.minRate,
            params.liquidatorFraction,
            params.lender,
            address(this)
        );

        uint256 sweptEth = address(this).balance - balBeforeEth;
        if (!isEth) refundTokenAmount = IERC20(borrowToken).balanceOf(address(this)) - balBeforeToken;

        uint256 sweptWeth;
        if (borrowToken != weth) {
            sweptWeth = IERC20(weth).balanceOf(address(this)) - balBeforeFallback;
        }

        if (refundTokenAmount > 0) {
            IERC20(borrowToken).safeTransfer(msg.sender, refundTokenAmount);
        }

        if (sweptWeth > 0) {
            IERC20(weth).safeTransfer(msg.sender, sweptWeth);
        }

        if (sweptEth > 0) {
            (bool ok,) = payable(msg.sender).call{value: sweptEth}("");
            if (!ok) revert InvalidParams();
        }
    }

    function _validateLendParams(IOpenLend.LendingArrangement memory params, address lender, bool isRefi) internal view {
        uint256 stagedSettlementTime = params.refiParams.oracleParams.settlementTime;
        _tokensMatch(params.supplyToken, params.borrowToken);
        _validateLiqThreshold(params.liquidationThreshold);
        _validateStake(params.stake);
        _validateSender(lender);
        if (isRefi) {
            _validateTerm(params.refiParams.newTerm);
        } else {
            _validateTerm(params.term);
        }

        if (isRefi && stagedSettlementTime != 0) {
            _validateOracleParams(params.refiParams.oracleParams);
        } else {
            _validateOracleParams(params.oracleParams);
        }
        _validateInterestRateParams(params.interestRateParams);
    }

    function _validateBorrowParams(BorrowParams memory params) internal view {
        _tokensMatch(params.supplyToken, params.borrowToken);
        _validateTerm(params.term);
        _validateLiqThreshold(params.liquidationThreshold);
        _validateStake(params.stake);
        _validateGasCompensation(params.gasCompensation);
        _validateSender(params.borrower);
        _validateOracleParams(params.oracleParams);
        _validateInterestRateParams(params.interestRateParams);
    }

    function _validateOracleParams(IOpenLend.OracleParams memory oracleParams) internal pure {

        uint48 settlementTime = oracleParams.settlementTime;
        uint24 disputeDelay = oracleParams.disputeDelay;
        uint24 oracleGameFee = oracleParams.oracleGameFee;
        uint16 escalationFactor = oracleParams.escalationFactor;
        uint8 initialLiquidity = oracleParams.initialLiquidity;
        uint16 multiplier = oracleParams.multiplier;
        uint48 maxBaseFee = oracleParams.maxBaseFee;
        uint64 finalizerReward = oracleParams.finalizerReward;

        if (settlementTime > 1 hours || settlementTime < 10 minutes) revert InvalidParams();
        if (disputeDelay != 60) revert InvalidParams();
        if (oracleGameFee < 25000 || oracleGameFee > 3e5) revert InvalidParams();
        if (escalationFactor < 100 || escalationFactor > 400) revert InvalidParams();
        if (initialLiquidity < 10 || initialLiquidity > 200) revert InvalidParams();
        if (initialLiquidity > escalationFactor) revert InvalidParams();
        if (multiplier < 130 || multiplier > 250) revert InvalidParams();
        if (maxBaseFee != 0) revert InvalidParams();
        if (finalizerReward < 0.0005 ether || finalizerReward > 0.01 ether) revert InvalidParams();

    }

    function _validateInterestRateParams(IOpenLend.InterestRateParams memory interestRateParams) internal pure {
        uint32 maxRate = interestRateParams.maxRate;
        uint32 startingRate = interestRateParams.startingRate;
        uint24 roundLength = interestRateParams.roundLength;
        uint16 growthRate = interestRateParams.growthRate;
        uint16 maxRounds = interestRateParams.maxRounds;

        if (maxRate == 0 || maxRate > 3.5e8 || maxRate < startingRate) revert InvalidParams();
        if (startingRate == 0 || startingRate > 5e7) revert InvalidParams();
        if (roundLength < 12 || roundLength > 5 minutes) revert InvalidParams();
        if (growthRate > 11000 || growthRate < 10100) revert InvalidParams();
        if (maxRounds == 0 || maxRounds > 100) revert InvalidParams();
    }

    function validateParamsLendingIds(
        uint256[] calldata lendingIds,
        bool valOP,
        bool valIP
    ) external view returns (bool[] memory lenderOk, bool[] memory currentOk) {
        lenderOk = new bool[](lendingIds.length);
        currentOk = new bool[](lendingIds.length);

        for (uint256 i; i < lendingIds.length; ++i) {
            try this.validateParamsLendingId(lendingIds[i], valOP, valIP, true) {
                lenderOk[i] = true;
            } catch {}

            try this.validateParamsLendingId(lendingIds[i], valOP, valIP, false) {
                currentOk[i] = true;
            } catch {}
        }
    }

    function validateParamsLendingId(
        uint256 lendingId,
        bool valOP,
        bool valIP,
        bool lenderPerspective
    ) external view {
        IOpenLend.LendingArrangement memory p = openLend.lendingArrangements(lendingId);
        bool isRefi = p.active && p.curveOpen;

        _tokensMatch(p.supplyToken, p.borrowToken);
        _validateLiqThreshold(p.liquidationThreshold);
        _validateStake(p.stake);

        if (lenderPerspective && isRefi) {
            _validateTerm(p.refiParams.newTerm);
            if (valOP) {
                if (p.refiParams.oracleParams.settlementTime != 0) {
                    _validateOracleParams(p.refiParams.oracleParams);
                } else {
                    _validateOracleParams(p.oracleParams);
                }
            }
        } else {
            _validateTerm(p.term);
            if (valOP) _validateOracleParams(p.oracleParams);
        }

        if (valIP) _validateInterestRateParams(p.interestRateParams);
    }

    function _tokensMatch(address _token1, address _token2) internal view {
        if (_token1 == _token2) revert InvalidParams();
        bool notEq = token1 != token2;
        bool token1Matches = (token1 == _token1 || token2 == _token1);
        bool token2Matches = (token1 == _token2 || token2 == _token2);

        if (notEq && token1Matches && token2Matches) return;
        revert InvalidParams();
    }

    function _validateLiqThreshold(uint24 liqT) internal pure {
        if (liqT > 9.25e6  || liqT < 7e6) revert InvalidParams();
    }

    function _validateTerm(uint48 term) internal pure {
        if (term > 30 days || term < 4 hours) revert InvalidParams();
    }

    function _validateStake(uint16 stake) internal pure {
        if (stake > 150 || stake < 10) revert InvalidParams();
    }

    function _validateGasCompensation(uint96 gasComp) internal pure {
        if (gasComp > 0.05 ether) revert InvalidParams();
    }

    function _validateSender(address sender) internal view {
        if (sender != msg.sender) revert InvalidParams();
    }

    /// @dev Grants openLend infinite allowance on the given token the first time it's needed.
    function _ensureOpenLendApproval(address token) internal {
        if (!_openLendApproved[token]) {
            IERC20(token).forceApprove(address(openLend), type(uint256).max);
            _openLendApproved[token] = true;
        }
    }

    /// @dev Pulls ERC20 tokens using SafeERC20. Tokens that revert or return false are rejected.
    function _pullToken(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    function returnBorrows(
        address borrower,
        uint256 ors, // optional range start
        uint256 ore // optional range end
    ) external view returns (uint256[] memory borrows) {
        uint256 count = userBorrowCount[borrower];
        if (ore == 0) ore = count;
        if (ors > ore || ore > count) revert InvalidParams();

        borrows = new uint256[](ore - ors);
        for (uint256 i = ors; i < ore; ++i) {
            borrows[i - ors] = userToBorrow[borrower][i];
        }
    }

    function returnLends(
        address lender,
        uint256 ors, // optional range start
        uint256 ore // optional range end
    ) external view returns (uint256[] memory lends) {
        uint256 count = userLendCount[lender];
        if (ore == 0) ore = count;
        if (ors > ore || ore > count) revert InvalidParams();

        lends = new uint256[](ore - ors);
        for (uint256 i = ors; i < ore; ++i) {
            lends[i - ors] = userToLend[lender][i];
        }
    }

    receive() external payable {}
}
