// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {openSwapV2} from "../../src/OpenSwapSlim.sol";

// Pre-hash-refactor convenience layer for openSwap tests. The new openSwap.propose() takes
// (ProposedSwap, MatcherPreimage, Permit2Params, minOut); the original took 13 flat args
// (sellAmt, sellToken, ..., OracleParams, SlippageParams, FulfillFeeParams, Permit2Params,
// useInternalBalances). Tests stay readable by going through proposeRaw().
library SwapCompat {
    // OracleParams as it existed before the hash refactor (still useful as a grouping
    // container for the oracle-game-related propose params).
    struct OracleParams {
        uint128 initialLiquidity;
        uint128 escalationHalt;
        uint96 settlerReward;
        uint48 settlementTime;
        uint24 maxGameTime;
        uint24 disputeDelay;
        uint24 protocolFee;
        uint16 multiplier;
        uint16 blocksPerSecond;
    }

    /// @dev Translates the pre-hash-refactor 13-arg propose shape into the new
    ///      (ProposedSwap, MatcherPreimage, Permit2Params, minOut) call. Caller-supplied
    ///      override slots (s.swapper, m.startFulfillFeeIncrease) are zero — contract overrides
    ///      them before hashing. s.expiration is the offset (contract overrides to absolute).
    function proposeRaw(
        openSwapV2 swapContract,
        uint256 value,
        uint128 sellAmt,
        address sellToken,
        uint128 minOut,
        address buyToken,
        uint128 minFulfillLiquidity,
        uint48 expirationOffset,
        uint96 matcherGasComp,
        uint96 executorGasComp,
        OracleParams memory op,
        openSwapV2.SlippageParams memory slip,
        openSwapV2.FulfillFeeParams memory ff,
        openSwapV2.Permit2Params memory permit2,
        bool useInternalBalances
    ) internal returns (uint256 swapId) {
        openSwapV2.ProposedSwap memory s;
        s.sellAmt = sellAmt;
        s.minFulfillLiquidity = minFulfillLiquidity;
        s.settlerReward = op.settlerReward;
        s.maxGameTime = op.maxGameTime;
        s.blocksPerSecond = op.blocksPerSecond;
        s.buyToken = buyToken;
        s.matcherGasComp = matcherGasComp;
        s.sellToken = sellToken;
        // s.swapper = 0 (contract overrides to msg.sender)
        s.executorGasComp = executorGasComp;
        s.useInternalBalances = useInternalBalances;
        s.expiration = expirationOffset;
        s.slippageParams = slip;

        openSwapV2.MatcherPreimage memory m;
        m.initialLiquidity = op.initialLiquidity;
        m.escalationHalt = op.escalationHalt;
        m.settlementTime = op.settlementTime;
        m.disputeDelay = op.disputeDelay;
        m.protocolFee = op.protocolFee;
        m.multiplier = op.multiplier;
        // m.startFulfillFeeIncrease = 0 (contract overrides to block.timestamp)
        m.maxFee = ff.maxFee;
        m.startingFee = ff.startingFee;
        m.roundLength = ff.roundLength;
        m.growthRate = ff.growthRate;
        m.maxRounds = ff.maxRounds;

        return swapContract.propose{value: value}(s, m, permit2, minOut);
    }
}
