// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @title OracleDisputeHelper
 * @notice Sources one or both missing oracle legs through a caller-selected router and submits
 *         an OpenOracle dispute atomically. The caller supplies all capital and is recorded as
 *         the new oracle reporter. The oracle preimage is authenticated before sourcing funds.
 *
 *         The caller selects a router implementing execute(bytes,bytes[],uint256) and supplies
 *         its commands and inputs. When routing is needed, the helper transfers exactly
 *         maxSwapInput to that router and grants neither the router nor Permit2 any allowance.
 *         Both oracle legs must be fully funded without using balances that predated the call;
 *         insufficient funding reverts the entire transaction.
 *
 *         Required outputs must be delivered to this helper. Unused route input and intermediate
 *         tokens may be sent directly to the caller. Only the oracle tokens and route input token
 *         are tracked for refunds; other assets sent to this helper are not recoverable through it.
 *         ERC20 route inputs must have conventional transfer behavior; fee-on-transfer and rebasing
 *         tokens are unsupported.
 */
contract OracleDisputeHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address internal constant ETH = address(0);
    uint256 internal constant PERCENTAGE_PRECISION = 1e7;

    uint8 internal constant FLAG_FEES_ONLY_AT_HALT = 1 << 5; // = 32

    error AddressCannotBeZero();
    error TokensCannotBeSame();
    error InvalidMsgValue();
    error InvalidMaximumSwapInput();
    error InsufficientRouterOutput();
    error BalanceBelowSnapshot();
    error EthTransferFailed();
    error WrongHash();
    error InternalWithdrawalShortfall();

    IOpenOracle2 public immutable oracle;

    struct DisputeData {
        uint256 reportId;
        uint128 newAmount1;
        uint128 newAmount2;
    }

    struct FundingState {
        uint256 startBalance1;
        uint256 startBalance2;
        uint256 requiredToken1;
        uint256 requiredToken2;
    }

    constructor(address oracleAddress) {
        if (oracleAddress == address(0)) {
            revert AddressCannotBeZero();
        }
        oracle = IOpenOracle2(oracleAddress);
    }

    /**
     * @notice Disputes a report, using a caller-selected router and opaque routing plan to source
     *         one or both missing oracle legs from a caller-selected input token.
     * @dev `suppliedAmount1` and `suppliedAmount2` are total funding budgets for each oracle token.
     *      When `tryInternalBalances` is true, the helper first uses as much of each budget as it
     *      can from msg.sender's approved OpenOracle balance, then pulls only the remainder
     *      externally. The same behavior applies to maxSwapInput when routeInputToken is a third
     *      asset. Internally sourced funds are withdrawn to this helper before routing, so the
     *      final oracle dispute continues to use external delegated funding.
     *
     *      `routeInputToken` may be either oracle token, a third ERC20, or address(0) for ETH.
     *      When it is an oracle token, maxSwapInput must fit within that token's supplied surplus.
     *      When it is a third token, maxSwapInput is its total route budget.
     *      The router plan must use router-held funds and return the required outputs to this
     *      contract. Unused input may be sent directly to msg.sender or returned here for refund.
     *
     *      msg.value must cover the externally sourced ETH. Excess ETH is accepted and refunded
     *      only when ETH is one of the oracle tokens or routeInputToken; otherwise msg.value must
     *      be zero. Refunds preserve preexisting balances and return only the remaining increase.
     *
     *      Only token1, token2, and routeInputToken are balance-tracked and refunded. Any other
     *      token sent to this contract by the route is not recoverable through this helper. Route
     *      intermediates should be sent directly to msg.sender rather than left in this helper.
     * @param routerChoice Router used if supplied funding is insufficient.
     *        Must implement execute(bytes,bytes[],uint256); ignored when no routing is needed.
     */
    function disputeWithRoute(
        DisputeData calldata dispute,
        IOpenOracle2.OracleGame calldata game,
        IOpenOracle2.PreimageHelper calldata helper,
        IOpenOracle2.TimingBoundaries calldata timing,
        uint256 suppliedAmount1,
        uint256 suppliedAmount2,
        bool tryInternalBalances,
        address routeInputToken,
        uint256 maxSwapInput,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline,
        address routerChoice
    ) external payable nonReentrant {
        bool separateRouteInput = routeInputToken != game.token1 && routeInputToken != game.token2;
        uint256 routeInputStartBalance;

        if (
            keccak256(abi.encode(game, helper))
                != oracle.oracleGame(dispute.reportId)
        ) revert WrongHash();
        if (separateRouteInput) routeInputStartBalance = _startingBalance(routeInputToken);

        // only applies to oracle game tokens
        (FundingState memory funding, uint256 expectedValue) =
            _snapshotAndPull(game, dispute, suppliedAmount1, suppliedAmount2, tryInternalBalances);

        // Adds maxSwapInput only when the route input is a third asset. If it is token1 or
        // token2, its routing budget is already included in that token's supplied amount.
        if (separateRouteInput) {
            expectedValue += _sourceDeclaredAmount(routeInputToken, maxSwapInput, tryInternalBalances);
        }

        bool ethTracked =
            game.token1 == ETH
            || game.token2 == ETH
            || routeInputToken == ETH;

        if (
            msg.value < expectedValue
            || (msg.value != 0 && !ethTracked)
        ) revert InvalidMsgValue();

        uint256 shortfall1 = funding.requiredToken1 > suppliedAmount1 ? funding.requiredToken1 - suppliedAmount1 : 0;
        uint256 shortfall2 = funding.requiredToken2 > suppliedAmount2 ? funding.requiredToken2 - suppliedAmount2 : 0;

        if (shortfall1 > 0 || shortfall2 > 0) {
            uint256 availableRouteInput;
            if (routeInputToken == game.token1) {
                availableRouteInput =
                    suppliedAmount1 > funding.requiredToken1 ? suppliedAmount1 - funding.requiredToken1 : 0;
            } else if (routeInputToken == game.token2) {
                availableRouteInput =
                    suppliedAmount2 > funding.requiredToken2 ? suppliedAmount2 - funding.requiredToken2 : 0;
            } else {
                availableRouteInput = maxSwapInput;
            }

            _executeRoute(routeInputToken, availableRouteInput, maxSwapInput, commands, inputs, deadline, routerChoice);
        }

        _assertFullyFunded(game, funding);
        _disputeAndRefund(dispute, game, helper, timing, funding);
        if (separateRouteInput) _refundDelta(routeInputToken, routeInputStartBalance);
    }

    function _snapshotAndPull(
        IOpenOracle2.OracleGame calldata game,
        DisputeData calldata dispute,
        uint256 suppliedAmount1,
        uint256 suppliedAmount2,
        bool tryInternalBalances
    ) internal returns (FundingState memory funding, uint256 expectedValue) {
        address token1 = game.token1;
        address token2 = game.token2;
        if (token1 == token2) revert TokensCannotBeSame();

        // balance from before the call
        funding.startBalance1 = _startingBalance(token1);
        funding.startBalance2 = _startingBalance(token2);

        // funding in each token needed for the oracle game
        (funding.requiredToken1, funding.requiredToken2) = _requiredFunding(game, dispute);

        expectedValue += _sourceDeclaredAmount(token1, suppliedAmount1, tryInternalBalances);
        expectedValue += _sourceDeclaredAmount(token2, suppliedAmount2, tryInternalBalances);
    }

    /**
     * @dev Uses up to `declaredAmount` from msg.sender's spendable internal balance and allowance,
     *      withdraws that portion to this helper, then pulls the remainder externally. Returns the
     *      amount of native ETH that must be supplied through msg.value.
     */
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

    /**
     * @dev The helper is the oracle caller while msg.sender is the recorded disputer, so the
     *      oracle always takes its delegated-dispute (non-self-dispute) funding path.
     *      With FLAG_FEES_ONLY_AT_HALT set, reporter and protocol fees are charged only when
     *      currentAmount1 is already at or above escalationHalt before this dispute.
     */
    function _requiredFunding(IOpenOracle2.OracleGame calldata game, DisputeData calldata dispute)
        internal
        pure
        returns (uint256 requiredToken1, uint256 requiredToken2)
    {
        uint256 oldAmount1 = game.currentAmount1;
        uint256 oldAmount2 = game.currentAmount2;
        uint256 newAmount1 = dispute.newAmount1;
        uint256 newAmount2 = dispute.newAmount2;

        // charges fees only if halt-only fees is off OR it's on and oldAmount1 is in range of charging fees to next dispute
        bool chargeFees =
            (game.flags & FLAG_FEES_ONLY_AT_HALT) == 0
            || oldAmount1 >= game.escalationHalt;

        bool swapToken2 = newAmount2 * oldAmount1 > oldAmount2 * newAmount1;

        if (!swapToken2) {
            uint256 fee = oldAmount1 * game.feePercentage / PERCENTAGE_PRECISION;
            uint256 protocolFee = oldAmount1 * game.protocolFee / PERCENTAGE_PRECISION;
            if (!chargeFees) (fee, protocolFee) = (0, 0);

            requiredToken1 = newAmount1 + oldAmount1 + fee + protocolFee;
            requiredToken2 = newAmount2 >= oldAmount2 ? newAmount2 - oldAmount2 : 0;
        } else {
            uint256 fee = oldAmount2 * game.feePercentage / PERCENTAGE_PRECISION;
            uint256 protocolFee = oldAmount2 * game.protocolFee / PERCENTAGE_PRECISION;
            if (!chargeFees) (fee, protocolFee) = (0, 0);

            requiredToken1 = newAmount1 > oldAmount1 ? newAmount1 - oldAmount1 : 0;
            requiredToken2 = newAmount2 + oldAmount2 + fee + protocolFee;
        }
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
        IUniversalRouter router = IUniversalRouter(routerChoice);

        if (tokenIn == ETH) {
            router.execute{value: maxSwapInput}(commands, inputs, deadline);
        } else {
            IERC20(tokenIn).safeTransfer(address(router), maxSwapInput);
            router.execute(commands, inputs, deadline);
        }
    }

    function _assertFullyFunded(IOpenOracle2.OracleGame calldata game, FundingState memory funding) internal view {
        if (
            _balanceOf(game.token1) < funding.startBalance1 + funding.requiredToken1
                || _balanceOf(game.token2) < funding.startBalance2 + funding.requiredToken2
        ) {
            revert InsufficientRouterOutput();
        }
    }

    function _disputeAndRefund(
        DisputeData calldata dispute,
        IOpenOracle2.OracleGame calldata game,
        IOpenOracle2.PreimageHelper calldata helper,
        IOpenOracle2.TimingBoundaries calldata timing,
        FundingState memory funding
    ) internal {
        address token1 = game.token1;
        address token2 = game.token2;

        _ensureOracleApproval(token1, funding.requiredToken1);
        _ensureOracleApproval(token2, funding.requiredToken2);

        uint256 ethRequired;
        if (token1 == ETH) ethRequired = funding.requiredToken1;
        if (token2 == ETH) ethRequired = funding.requiredToken2;

        oracle.dispute{value: ethRequired}(
            dispute.reportId, dispute.newAmount1, dispute.newAmount2, msg.sender, false, false, game, helper, timing
        );

        _refundDelta(token1, funding.startBalance1);
        _refundDelta(token2, funding.startBalance2);
    }

    /// @dev Grants the immutable oracle infinite allowance only when the current allowance is insufficient.
    function _ensureOracleApproval(address token, uint256 required) internal {
        if (token != ETH && required > 0 && IERC20(token).allowance(address(this), address(oracle)) < required) {
            IERC20(token).forceApprove(address(oracle), type(uint256).max);
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
