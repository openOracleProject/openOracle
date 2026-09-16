// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";
import {openPunt} from "./OpenPunt.sol";
import {OpenPuntLifecycle} from "./OpenPuntLifecycle.sol";
import {OpenPuntStorage} from "./OpenPuntStorage.sol";

interface IOpenPuntUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @title OpenPuntHelper
 * @notice Sources the assets needed to match or report on an OpenPunt position through a
 *         caller-selected router, deposits the exact requirements into OpenOracle, and
 *         completes the requested OpenPunt action atomically.
 *
 *         The caller supplies all capital and chooses the matcher or reporter recorded by
 *         OpenPunt. Funding obligations are aggregated by token. Preexisting helper balances
 *         are preserved and do not count toward the caller's required funding.
 *         Funding supplied through this helper is irrevocably attributed to the caller-selected
 *         matcher or reporter; the helper does not require that account to equal msg.sender.
 *
 *         The caller selects a router implementing execute(bytes,bytes[],uint256) and supplies
 *         its commands and inputs. The helper transfers at most maxSwapInput to that router
 *         and grants neither the router nor Permit2 any allowance. Required outputs must be
 *         delivered to this helper; insufficient funding reverts the entire transaction.
 *
 *         Unused route input and intermediate tokens may be sent directly to the caller.
 *         The helper refunds increases in its balances of the required assets and route input
 *         token. Other assets sent to the helper are not recoverable through this contract.
 *         Contract callers must accept native ETH refunds; rejecting a refund reverts the call.
 *         Fee-on-transfer and rebasing route-input tokens are unsupported.
 */
contract OpenPuntHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address internal constant ETH = address(0);

    error AddressCannotBeZero();
    error TokensCannotBeSame();
    error InvalidMsgValue();
    error InvalidMaximumSwapInput();
    error HelperCannotBeParticipant();
    error WrongHash();
    error OracleGameInProgress();
    error InternalWithdrawalShortfall();
    error InsufficientRouterOutput();
    error BalanceBelowSnapshot();
    error EthTransferFailed();

    openPunt public immutable punt;
    IOpenOracle2 public immutable oracle;

    /**
     * @dev suppliedAmount3 means matcher collateral in matchWithRoute and native execution
     *      compensation in reportWithRoute. If inputToken is one of the required assets,
     *      maxSwapInput must fit inside that asset's supplied surplus. Otherwise maxSwapInput
     *      is pulled as a separate route-input asset. When tryInternalBalances is true, each
     *      declared funding amount uses the caller's approved OpenOracle balance first and pulls
     *      only the remainder externally.
     *      In reportWithRoute, include any ETH routing budget in suppliedAmount3 in addition to
     *      execution compensation, even when executionComp is zero.
     *
     *      Before use, the caller grants this helper ERC20 approvals for externally sourced tokens.
     *      When tryInternalBalances is true, the caller also grants this helper OpenOracle internal
     *      allowances. The selected matcher or reporter grants OpenPunt internal allowances for
     *      both oracle legs.
     */
    struct RouteFunding {
        uint256 suppliedAmount1;
        uint256 suppliedAmount2;
        uint256 suppliedAmount3;
        bool tryInternalBalances;
        address inputToken;
        uint256 maxSwapInput;
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }

    struct AssetFunding {
        address token;
        uint256 required;
        uint256 supplied;
        uint256 startBalance;
    }

    struct FundingState {
        AssetFunding[3] assets;
        uint8 assetCount;
        bool separateRouteInput;
        uint256 routeInputStartBalance;
    }

    constructor(address openPuntAddress) {
        if (openPuntAddress == address(0)) {
            revert AddressCannotBeZero();
        }

        punt = openPunt(openPuntAddress);
        oracle = openPunt(openPuntAddress).oracle();
    }

    /**
     * @notice Sources the opening oracle legs and matcher collateral, then matches a proposed swap.
     * @dev The helper is msg.sender to OpenPunt and therefore acts as matcherFunder. `matcher`
     *      remains the recorded position counterparty and opening reporter. It must have granted
     *      OpenPunt the internal OpenOracle allowances needed to consume both oracle legs.
     * @param routerChoice Router used if supplied funding is insufficient.
     *        Must implement execute(bytes,bytes[],uint256); ignored when no routing is needed.
     */
    function matchWithRoute(
        uint256 swapId,
        uint128 amount2,
        OpenPuntStorage.ProposedSwap calldata swapState,
        OpenPuntStorage.MatcherPreimage calldata preimage,
        IOpenOracle2.TimingBoundaries calldata timing,
        address matcher,
        RouteFunding calldata route,
        address routerChoice
    ) external payable nonReentrant {
        if (swapState.oracleToken1 == swapState.oracleToken2) revert TokensCannotBeSame();
        if (matcher == address(this)) revert HelperCannotBeParticipant();
        if (keccak256(abi.encode(swapState, preimage)) != punt.swaps(swapId)) revert WrongHash();

        FundingState memory funding;
        _addAsset(funding, swapState.oracleToken1, preimage.initialLiquidity, route.suppliedAmount1);
        _addAsset(funding, swapState.oracleToken2, amount2, route.suppliedAmount2);
        _addAsset(funding, swapState.collatToken, swapState.initialMarginMatcher, route.suppliedAmount3);

        _sourceAndDeposit(funding, route, routerChoice);
        punt.matchSwap(swapId, amount2, swapState, preimage, timing, matcher);
        _refundFunding(funding, route.inputToken);
    }

    /**
     * @notice Sources both oracle legs and native execution compensation, then reports on an
     *         active OpenPunt position.
     * @dev The helper is msg.sender to OpenPunt and therefore acts as reporterFunder. `reporter`
     *      remains the oracle reporter and must have granted OpenPunt the internal OpenOracle
     *      allowances needed to consume both oracle legs. The helper funds the execution compensation
     *      directly from its own approved OpenOracle balance.
     * @param routerChoice Router used if supplied funding is insufficient.
     *        Must implement execute(bytes,bytes[],uint256); ignored when no routing is needed.
     */
    function reportWithRoute(
        uint256 swapId,
        bytes32 expectedDutchHash,
        OpenPuntStorage.MatchedSwap calldata swapState,
        OpenPuntStorage.MatcherPreimage calldata preimage,
        IOpenOracle2.TimingBoundaries calldata timing,
        address reporter,
        uint128 amount1,
        uint128 amount2,
        uint128 executionComp,
        RouteFunding calldata route,
        address routerChoice
    ) external payable nonReentrant {
        if (swapState.oracleToken1 == swapState.oracleToken2) revert TokensCannotBeSame();
        if (reporter == address(this)) revert HelperCannotBeParticipant();
        if (punt.swapIdToReportId(swapId) != 0) revert OracleGameInProgress();
        if (
            keccak256(abi.encode(swapState)) != punt.swaps(swapId)
                || keccak256(abi.encode(preimage)) != swapState.matcherPreimageHash
        ) revert WrongHash();

        FundingState memory funding;
        _addAsset(funding, swapState.oracleToken1, amount1, route.suppliedAmount1);
        _addAsset(funding, swapState.oracleToken2, amount2, route.suppliedAmount2);
        _addAsset(funding, ETH, executionComp, route.suppliedAmount3);

        _sourceAndDeposit(funding, route, routerChoice);
        OpenPuntLifecycle(address(punt)).report(
            swapId, expectedDutchHash, swapState, preimage, timing, reporter, amount1, amount2, executionComp
        );
        _refundFunding(funding, route.inputToken);
    }

    function _sourceAndDeposit(FundingState memory funding, RouteFunding calldata route, address routerChoice) internal {
        uint256 expectedValue;
        uint256 assetCount = funding.assetCount;

        for (uint256 i; i < assetCount; ++i) {
            AssetFunding memory asset = funding.assets[i];
            funding.assets[i].startBalance = _startingBalance(asset.token);
        }

        funding.separateRouteInput = !_containsToken(funding, route.inputToken);
        if (funding.separateRouteInput) {
            funding.routeInputStartBalance = _startingBalance(route.inputToken);
        }

        for (uint256 i; i < assetCount; ++i) {
            AssetFunding memory asset = funding.assets[i];
            expectedValue += _sourceDeclaredAmount(asset.token, asset.supplied, route.tryInternalBalances);
        }

        if (funding.separateRouteInput) {
            expectedValue += _sourceDeclaredAmount(route.inputToken, route.maxSwapInput, route.tryInternalBalances);
        }

        bool ethTracked =
            _containsToken(funding, ETH) || (funding.separateRouteInput && route.inputToken == ETH);
        if (msg.value < expectedValue || (msg.value != 0 && !ethTracked)) revert InvalidMsgValue();

        if (_hasShortfall(funding)) {
            uint256 availableRouteInput =
                funding.separateRouteInput ? route.maxSwapInput : _suppliedSurplus(funding, route.inputToken);

            _executeRoute(
                route.inputToken, availableRouteInput, route.maxSwapInput, route.commands, route.inputs, route.deadline, routerChoice
            );
        }

        _assertFullyFunded(funding);

        for (uint256 i; i < assetCount; ++i) {
            AssetFunding memory asset = funding.assets[i];
            _depositIntoOracle(asset.token, asset.required);
            _ensurePuntInternalApproval(asset.token, asset.required);
        }
    }

    function _sourceDeclaredAmount(address token, uint256 declaredAmount, bool tryInternalBalances)
        internal
        returns (uint256 nativeValueRequired)
    {
        if (declaredAmount == 0) return 0;

        uint256 internalAmount;
        if (tryInternalBalances) {
            uint256 balance = oracle.tokenHolder(msg.sender, token);
            uint256 spendable = balance > 1 ? balance - 1 : 0;
            uint256 allowed = oracle.internalAllowance(msg.sender, address(this), token);

            internalAmount = declaredAmount;
            if (internalAmount > spendable) internalAmount = spendable;
            if (internalAmount > allowed) internalAmount = allowed;

            if (internalAmount > 0) {
                if (internalAmount > type(uint128).max) revert InvalidMaximumSwapInput();
                oracle.internalTransferFrom(msg.sender, address(this), token, uint128(internalAmount));
                uint256 withdrawn = oracle.withdrawTo(token, internalAmount, address(this));
                if (withdrawn != internalAmount) revert InternalWithdrawalShortfall();
            }
        }

        uint256 externalAmount = declaredAmount - internalAmount;
        if (token == ETH) return externalAmount;

        if (externalAmount > 0) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), externalAmount);
        }
        return 0;
    }

    function _addAsset(FundingState memory funding, address token, uint256 required, uint256 supplied) internal pure {
        uint256 assetCount = funding.assetCount;
        for (uint256 i; i < assetCount; ++i) {
            if (funding.assets[i].token == token) {
                funding.assets[i].required += required;
                funding.assets[i].supplied += supplied;
                return;
            }
        }

        funding.assets[assetCount] =
            AssetFunding({token: token, required: required, supplied: supplied, startBalance: 0});
        funding.assetCount = uint8(assetCount + 1);
    }

    function _containsToken(FundingState memory funding, address token) internal pure returns (bool) {
        uint256 assetCount = funding.assetCount;
        for (uint256 i; i < assetCount; ++i) {
            if (funding.assets[i].token == token) return true;
        }
        return false;
    }

    function _hasShortfall(FundingState memory funding) internal pure returns (bool) {
        uint256 assetCount = funding.assetCount;
        for (uint256 i; i < assetCount; ++i) {
            AssetFunding memory asset = funding.assets[i];
            if (asset.required > asset.supplied) return true;
        }
        return false;
    }

    function _suppliedSurplus(FundingState memory funding, address token) internal pure returns (uint256) {
        uint256 assetCount = funding.assetCount;
        for (uint256 i; i < assetCount; ++i) {
            AssetFunding memory asset = funding.assets[i];
            if (asset.token == token) {
                return asset.supplied > asset.required ? asset.supplied - asset.required : 0;
            }
        }
        return 0;
    }

    function _executeRoute(
        address tokenIn,
        uint256 surplus,
        uint256 maxSwapInput,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline,
        address routerChoice
    ) internal {
        if (maxSwapInput == 0 || maxSwapInput > surplus) revert InvalidMaximumSwapInput();

        IOpenPuntUniversalRouter router = IOpenPuntUniversalRouter(routerChoice);
        if (tokenIn == ETH) {
            router.execute{value: maxSwapInput}(commands, inputs, deadline);
        } else {
            IERC20(tokenIn).safeTransfer(address(router), maxSwapInput);
            router.execute(commands, inputs, deadline);
        }
    }

    function _assertFullyFunded(FundingState memory funding) internal view {
        uint256 assetCount = funding.assetCount;
        for (uint256 i; i < assetCount; ++i) {
            AssetFunding memory asset = funding.assets[i];
            if (_balanceOf(asset.token) < asset.startBalance + asset.required) {
                revert InsufficientRouterOutput();
            }
        }
    }

    function _depositIntoOracle(address token, uint256 amount) internal {
        if (amount == 0) return;
        if (amount > type(uint128).max) revert InvalidMaximumSwapInput();
        _ensureOracleApproval(token, amount);

        uint128 depositAmount = uint128(amount);
        if (token == ETH) {
            oracle.deposit{value: depositAmount}(token, depositAmount, address(this));
        } else {
            oracle.deposit(token, depositAmount, address(this));
        }
    }

    function _ensureOracleApproval(address token, uint256 required) internal {
        if (token != ETH && required > 0 && IERC20(token).allowance(address(this), address(oracle)) < required) {
            IERC20(token).forceApprove(address(oracle), type(uint256).max);
        }
    }

    function _ensurePuntInternalApproval(address token, uint256 required) internal {
        if (required == 0) return;

        uint256 current = oracle.internalAllowance(address(this), address(punt), token);
        if (current >= required) return;
        if (current != 0) oracle.approveInternal(address(punt), token, 0);
        oracle.approveInternal(address(punt), token, type(uint256).max);
    }

    function _refundFunding(FundingState memory funding, address routeInputToken) internal {
        uint256 assetCount = funding.assetCount;
        for (uint256 i; i < assetCount; ++i) {
            AssetFunding memory asset = funding.assets[i];
            _refundDelta(asset.token, asset.startBalance);
        }

        if (funding.separateRouteInput) {
            _refundDelta(routeInputToken, funding.routeInputStartBalance);
        }
    }

    function _startingBalance(address token) internal view returns (uint256 balance) {
        balance = _balanceOf(token);
        if (token == ETH) balance -= msg.value;
    }

    function _balanceOf(address token) internal view returns (uint256) {
        return token == ETH ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _refundDelta(address token, uint256 startingBalance) internal {
        uint256 currentBalance = _balanceOf(token);
        if (currentBalance < startingBalance) revert BalanceBelowSnapshot();

        uint256 refund = currentBalance - startingBalance;
        if (refund == 0) return;

        if (token == ETH) {
            (bool success,) = payable(msg.sender).call{value: refund}("");
            if (!success) revert EthTransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, refund);
        }
    }

    receive() external payable {}
}
