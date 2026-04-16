// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOpenOracle} from "./interfaces/IOpenOracle.sol";
import {IWETH} from "./interfaces/IWETH.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn);
}

contract disputeHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error EthTransferFailed();
    error ActionSafetyFailure(string);

    /* ─── immutables & constants ────────────────────────────── */
    IOpenOracle public immutable oracle;
    address public immutable WETH;
    ISwapRouter02 public immutable router;

    /* ─── constructor ──────────────────────────────────────── */
    constructor(address oracleAddress, address WETHaddress, address uniRouter) {
        require(oracleAddress != address(0), "oracle 0");
        oracle = IOpenOracle(oracleAddress);
        WETH = WETHaddress;
        router = ISwapRouter02(uniRouter);
    }

    struct oracleParams {
        uint128 escalationHalt;
        uint96 fee;
        uint96 settlerReward;
        address token1;
        uint48 settlementTime;
        address token2;
        bool timeType;
        uint24 feePercentage;
        uint24 protocolFee;
        uint16 multiplier;
        uint24 disputeDelay;//reportMeta end
        uint128 currentAmount1;
        uint128 currentAmount2;//reportStatus end
        uint32 callbackGasLimit;
        address protocolFeeRecipient;
        bool trackDisputes; //extraData end
    }

    // converts adversarial RPC into just a revert on-chain
    function validate(uint256 reportId, oracleParams calldata p) internal view returns (bool) {
        IOpenOracle.ReportMeta memory meta = oracle.reportMeta(reportId);
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        IOpenOracle.extraReportData memory extra = oracle.extraData(reportId);

        //basic callbackGasLimit and settlement time checks
        if (meta.timeType && meta.settlementTime > 86400) return false;
        if (!meta.timeType && meta.settlementTime > 43200) return false;
        if (extra.callbackGasLimit > 1500000) return false;

        if (p.escalationHalt != meta.escalationHalt) return false;
        if (p.fee != meta.fee) return false;
        if (p.settlerReward != meta.settlerReward) return false;
        if (p.token1 != meta.token1) return false;
        if (p.settlementTime != meta.settlementTime) return false;
        if (p.token2 != meta.token2) return false;
        if (p.timeType != meta.timeType) return false;
        if (p.feePercentage != meta.feePercentage) return false;
        if (p.protocolFee != meta.protocolFee) return false;
        if (p.multiplier != meta.multiplier) return false;
        if (p.disputeDelay != meta.disputeDelay) return false;

        if (p.currentAmount1 != status.currentAmount1) return false;
        if (p.currentAmount2 != status.currentAmount2) return false;

        if (p.callbackGasLimit != extra.callbackGasLimit) return false;
        if (p.protocolFeeRecipient != extra.protocolFeeRecipient) return false;
        if (p.trackDisputes != extra.trackDisputes) return false;

        return true;

    }

    struct DisputeData {
        uint256 reportId;
        address tokenToSwap;
        uint128 newAmount1;
        uint128 newAmount2;
        uint128 amt2Expected;
        bytes32 stateHash;
    }

    /**
     * @notice Submits one dispute with reportId validation checks. 
               Supports token1 = WETH games via wrapping msg.value. Returns ETH to user.
               Supports one-click disputes and handles token gathering to fund missing leg automatically
     * @param dispute Dispute data from struct DisputeData
     * @param p Oracle parameter data from struct oracleParams
     * @param batchAmount1 Amount of oracle game token1 the batcher can draw from to attempt the dispute
     * @param batchAmount2 Amount of oracle game token2 the batcher can draw from to attempt the dispute
     * @param timestamp Current block.timestamp
     * @param blockNumber Current block number
     * @param timestampBound Transaction will revert if it lands +/- this number of seconds outside passed timestamp
     * @param blockNumber Transaction will revert if it lands +/- this number of blocks outside passed blockNumber
     * @param maxSwapInput Slippage protection for Uniswap v3 swaps.
     */
    function disputeReportSafe(
        DisputeData calldata dispute,
        oracleParams calldata p,
        uint256 batchAmount1,
        uint256 batchAmount2,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 timestampBound,
        uint256 blockNumberBound,
        uint256 maxSwapInput
    ) external nonReentrant payable {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) revert ActionSafetyFailure("timestamp");
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) revert ActionSafetyFailure("block number");
        if (!validate(dispute.reportId, p)) revert ActionSafetyFailure("params dont match");

        //only support token1 = WETH to reduce complexity
        if (msg.value > 0 && p.token1 != WETH) revert ActionSafetyFailure("no WETH in oracle game");
        if (p.token2 == WETH) revert ActionSafetyFailure("no WETH as token2");

        _disputeReports(dispute, batchAmount1, batchAmount2, maxSwapInput);
    }

    function _disputeReports(DisputeData calldata dispute, uint256 batchAmount1, uint256 batchAmount2, uint256 maxSwapInput) internal {
        address sender = msg.sender;
        uint256 startBal1;
        uint256 startBal2;

        uint256 requiredToken1;
        uint256 requiredToken2;

        uint256 reportId = dispute.reportId;
        IOpenOracle.ReportMeta memory meta = oracle.reportMeta(reportId);
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);

        // Get token addresses
        address token1 = meta.token1;
        address token2 = meta.token2;

        startBal1 = IERC20(token1).balanceOf(address(this));
        startBal2 = IERC20(token2).balanceOf(address(this));

        // Transfer tokens to batcher
        IERC20(token1).safeTransferFrom(sender, address(this), batchAmount1);
        IERC20(token2).safeTransferFrom(sender, address(this), batchAmount2);

        if (msg.value > 0) {
            IWETH(WETH).deposit{value: msg.value}();
        }

        // Gather current report information
        uint256 currAmt1 = status.currentAmount1;
        uint256 currAmt2 = status.currentAmount2;
        uint256 protoFee = meta.protocolFee;
        uint256 swapFee = meta.feePercentage;

        if (dispute.tokenToSwap == token1) {
            requiredToken1 = dispute.newAmount1 + currAmt1 + protoFee * currAmt1 / 1e7 + swapFee * currAmt1 / 1e7;
            if (dispute.newAmount2 < currAmt2){
                requiredToken2 = 0;
            } else {
                requiredToken2 = dispute.newAmount2 - currAmt2;
            }
        }

        if (dispute.tokenToSwap == token2) {
            requiredToken1 = dispute.newAmount1 - currAmt1;
            requiredToken2 = dispute.newAmount2 + currAmt2 + protoFee * currAmt2 / 1e7 + swapFee * currAmt2 / 1e7;
        }

        uint256 available1 = batchAmount1 + (token1 == WETH ? msg.value : 0);
        uint256 available2 = batchAmount2;

        uint256 shortfall1 = requiredToken1 > available1 ? requiredToken1 - available1 : 0;
        uint256 shortfall2 = requiredToken2 > available2 ? requiredToken2 - available2 : 0;
        uint256 surplus1 = available1 > requiredToken1 ? available1 - requiredToken1 : 0;
        uint256 surplus2 = available2 > requiredToken2 ? available2 - requiredToken2 : 0;

        if (shortfall1 > 0 && shortfall2 > 0) revert ActionSafetyFailure("insufficient total value");
        if (shortfall1 > 0 && surplus2 == 0) revert ActionSafetyFailure("need token2");
        if (shortfall2 > 0 && surplus1 == 0) revert ActionSafetyFailure("need token1");

        if (shortfall1 > 0) {
            if (surplus2 < maxSwapInput) revert ActionSafetyFailure("surplus not enough");
            IERC20(token2).forceApprove(address(router), maxSwapInput);
            router.exactOutputSingle(
                ISwapRouter02.ExactOutputSingleParams({
                    tokenIn: token2,
                    tokenOut: token1,
                    fee: 500,
                    recipient: address(this),
                    amountOut: shortfall1,
                    amountInMaximum: maxSwapInput,
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(token2).forceApprove(address(router), 0);
        } else if (shortfall2 > 0) {
            if (surplus1 < maxSwapInput) revert ActionSafetyFailure("surplus not enough");
            IERC20(token1).forceApprove(address(router), maxSwapInput);
            router.exactOutputSingle(
                ISwapRouter02.ExactOutputSingleParams({
                    tokenIn: token1,
                    tokenOut: token2,
                    fee: 500,
                    recipient: address(this),
                    amountOut: shortfall2,
                    amountInMaximum: maxSwapInput,
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(token1).forceApprove(address(router), 0);
        }

        // Approve oracle
        IERC20(token1).safeIncreaseAllowance(address(oracle), requiredToken1);
        IERC20(token2).safeIncreaseAllowance(address(oracle), requiredToken2);

        oracle.disputeAndSwap(
            dispute.reportId,
            dispute.tokenToSwap,
            dispute.newAmount1,
            dispute.newAmount2,
            sender,
            dispute.amt2Expected,
            dispute.stateHash
        );

        uint256 remaining1 = IERC20(token1).balanceOf(address(this)) - startBal1;
        uint256 remaining2 = IERC20(token2).balanceOf(address(this)) - startBal2;

        if (token1 == WETH && remaining1 > 0){
            IWETH(WETH).withdraw(remaining1);
            (bool ok,) = payable(msg.sender).call{value: remaining1, gas: 40000}("");
            if (!ok) {
                revert EthTransferFailed();
            }
        } else if (remaining1 > 0) {
            IERC20(token1).safeTransfer(sender, remaining1);
        } 

        if (remaining2 > 0) IERC20(token2).safeTransfer(sender, remaining2);

        IERC20(token1).forceApprove(address(oracle), 0);
        IERC20(token2).forceApprove(address(oracle), 0);
    }

    /**
     * @notice Submits one dispute with reportId validation checks. Must have exact tokens.
               Wraps ETH for user and returns as WETH.
               Supports both WETH == token1 and WETH == token2.
     * @param dispute Dispute data from struct DisputeData
     * @param p Oracle parameter data from struct oracleParams
     * @param batchAmount1 Amount of oracle game token1 the batcher can draw from to attempt the dispute
     * @param batchAmount2 Amount of oracle game token2 the batcher can draw from to attempt the dispute
     * @param timestamp Current block.timestamp
     * @param blockNumber Current block number
     * @param timestampBound Transaction will revert if it lands +/- this number of seconds outside passed timestamp
     * @param blockNumber Transaction will revert if it lands +/- this number of blocks outside passed blockNumber
     */
    function disputeReportExactTokens(
        DisputeData calldata dispute,
        oracleParams calldata p,
        uint256 batchAmount1,
        uint256 batchAmount2,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 timestampBound,
        uint256 blockNumberBound
    ) external nonReentrant payable {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) revert ActionSafetyFailure("timestamp");
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) revert ActionSafetyFailure("block number");
        if (!validate(dispute.reportId, p)) revert ActionSafetyFailure("params dont match");
        if (msg.value > 0 && p.token1 != WETH && p.token2 != WETH) revert ActionSafetyFailure("no WETH in oracle game");

        _disputeReportsExact(dispute, batchAmount1, batchAmount2);
    }

    function _disputeReportsExact(DisputeData calldata dispute, uint256 batchAmount1, uint256 batchAmount2) internal {
        address sender = msg.sender;
        uint256 startBal1;
        uint256 startBal2;

        uint256 reportId = dispute.reportId;
        IOpenOracle.ReportMeta memory meta = oracle.reportMeta(reportId);

        // Get token addresses
        address token1 = meta.token1;
        address token2 = meta.token2;

        startBal1 = IERC20(token1).balanceOf(address(this));
        startBal2 = IERC20(token2).balanceOf(address(this));

        // Transfer tokens to batcher
        IERC20(token1).safeTransferFrom(sender, address(this), batchAmount1);
        IERC20(token2).safeTransferFrom(sender, address(this), batchAmount2);

        uint256 extra1 = 0;
        uint256 extra2 = 0;

        if (msg.value > 0) {
            IWETH(WETH).deposit{value: msg.value}();
            if (meta.token1 == WETH) extra1 = msg.value;
            if (meta.token2 == WETH) extra2 = msg.value;
        }

        // Approve oracle
        IERC20(token1).safeIncreaseAllowance(address(oracle), batchAmount1 + extra1);
        IERC20(token2).safeIncreaseAllowance(address(oracle), batchAmount2 + extra2);

        oracle.disputeAndSwap(
            dispute.reportId,
            dispute.tokenToSwap,
            dispute.newAmount1,
            dispute.newAmount2,
            sender,
            dispute.amt2Expected,
            dispute.stateHash
        );

        uint256 remaining1 = IERC20(token1).balanceOf(address(this)) - startBal1;
        uint256 remaining2 = IERC20(token2).balanceOf(address(this)) - startBal2;

        if (remaining1 > 0) IERC20(token1).safeTransfer(sender, remaining1);
        if (remaining2 > 0) IERC20(token2).safeTransfer(sender, remaining2);

        IERC20(token1).forceApprove(address(oracle), 0);
        IERC20(token2).forceApprove(address(oracle), 0);
    }

    /* -- accept ETH rewards ------------------------------------------------- */
    receive() external payable {}
}
