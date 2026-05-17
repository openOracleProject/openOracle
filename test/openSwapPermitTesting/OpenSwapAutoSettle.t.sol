// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

/// @notice execute() can auto-settle when the oracle game has passed settlementTime
///         but settle() has not yet been called. Locks in the unified-settle
///         optimization (saves the separate settle tx).
contract OpenSwapAutoSettleTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    // 12) execute auto-settles when oracle not yet settled
    function testAutoSettle_ExecuteSettlesAndCompletes() public {
        (uint256 swapId, uint48 expiration) = _propose();
        uint128 amount2 = 2000e18;
        (uint128 reportId, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, amount2, expiration);

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, amount2);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        // Past settlementTime but settle() not called — og.settlementTimestamp stays 0.
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        bytes32 oracleHashBefore = oracle.oracleGame(reportId);
        assertEq(oracleHashBefore, keccak256(abi.encode(og, ph)), "oracle still unsettled pre-execute");

        uint256 executorSettlerInternalBefore = _spendable(address(0x7001), address(0));

        vm.prank(address(0x7001));
        swapContract.execute(swapId, sPost, og, ph, false);

        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-execute");
        assertEq(swapContract.tempHolding(address(0x7001)), EXECUTOR_GAS_COMP, "executor gas comp queued");
        // executor also collects settlerReward (transferred internally)
        assertEq(
            _spendable(address(0x7001), address(0)),
            executorSettlerInternalBefore + SETTLER_REWARD,
            "executor received settler reward internally"
        );
        // Oracle state moved: settlementTimestamp written. The new hash must match a reconstruction with current ts.
        IOpenOracle2.OracleGame memory settled = og;
        settled.settlementTimestamp = uint48(block.timestamp);
        assertEq(oracle.oracleGame(reportId), keccak256(abi.encode(settled, ph)), "oracle hash now reflects settle");
    }

    // 13) Already-settled execute: executor gets executor gas comp, no duplicate settler reward
    function testAutoSettle_AlreadySettled_NoDuplicateReward() public {
        (uint256 swapId, uint48 expiration) = _propose();
        uint128 amount2 = 2000e18;
        (uint128 reportId, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, amount2, expiration);

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, amount2);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // settler claims the reward via direct settle()
        _settle(reportId, og, ph);
        uint256 settlerRewardCredited = _spendable(settler, address(0));
        assertEq(settlerRewardCredited, SETTLER_REWARD, "settler got reward");

        address executor = address(0x7002);
        uint256 executorSettlerInternalBefore = _spendable(executor, address(0));
        _execute(swapId, sPost, og, ph, executor);

        assertEq(swapContract.tempHolding(executor), EXECUTOR_GAS_COMP, "executor gas comp");
        assertEq(
            _spendable(executor, address(0)),
            executorSettlerInternalBefore,
            "executor did NOT receive settler reward (already paid to settler)"
        );
    }

    // 14) Zero settler reward end-to-end
    function testAutoSettle_ZeroSettlerReward() public {
        // Override oracle params: settlerReward = 0
        proposeTs = uint48(block.timestamp);
        proposeUseInternal = false;

        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.settlerReward = 0;

        uint256 ethToSend = uint256(MATCHER_GAS_COMP) + uint256(EXECUTOR_GAS_COMP); // no settler reward
        vm.prank(swapper);
        uint256 swapId = SwapCompat.proposeRaw(swapContract, ethToSend, 
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            op, _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), false
        );

        // Build matching pre-image (mirror _buildSwapAndPreimage but with custom settlerReward=0).
        uint48 expiration = uint48(block.timestamp + 1 hours);
        openSwapV2.ProposedSwap memory s;
        s.swapper = swapper;
        s.sellAmt = SELL_AMT;
        s.sellToken = address(sellToken);
        s.buyToken = address(buyToken);
        s.minFulfillLiquidity = MIN_FULFILL_LIQUIDITY;
        s.expiration = expiration;
        s.maxGameTime = MAX_GAME_TIME;
        s.blocksPerSecond = 500;
        s.settlerReward = 0;
        SwapCompat.SlippageParams memory slip = _defaultSlippage();
        s.priceTolerated = slip.priceTolerated;
        s.toleranceRange = slip.toleranceRange;
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.executorGasComp = EXECUTOR_GAS_COMP;
        s.useInternalBalances = false;

        openSwapV2.MatcherPreimage memory m;
        m.initialLiquidity = op.initialLiquidity;
        m.escalationHalt = op.escalationHalt;
        m.settlementTime = op.settlementTime;
        m.disputeDelay = op.disputeDelay;
        m.protocolFee = op.protocolFee;
        m.multiplier = op.multiplier;
        m.startFulfillFeeIncrease = proposeTs;
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();
        m.maxFee = ff.maxFee;
        m.startingFee = ff.startingFee;
        m.roundLength = ff.roundLength;
        m.growthRate = ff.growthRate;
        m.maxRounds = ff.maxRounds;

        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        uint128 reportId = uint128(oracle.nextReportId());

        vm.prank(matcher);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));

        openSwapV2.MatchedSwap memory sPost = _postMatchSwap(s, reportId, _calcFulfillFee(), reportTs);

        IOpenOracle2.OracleGame memory og = IOpenOracle2.OracleGame({
            currentAmount1: m.initialLiquidity, currentAmount2: 2000e18,
            currentReporter: payable(matcher), reportTimestamp: reportTs,
            settlementTimestamp: 0, token1: address(sellToken), lastReportOppoTime: reportBn,
            settlementTime: m.settlementTime, escalationHalt: m.escalationHalt,
            protocolFeeRecipient: address(0), settlerReward: 0, token2: address(buyToken),
            numReports: 0, disputeDelay: m.disputeDelay, feePercentage: 0,
            multiplier: m.multiplier, callbackContract: address(0), callbackGasLimit: 0,
            protocolFee: m.protocolFee, flags: 1
        });
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        address executor = address(0x7003);
        uint256 executorInternalBefore = _spendable(executor, address(0));

        vm.prank(executor);
        swapContract.execute(swapId, sPost, og, ph, false);

        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted");
        assertEq(swapContract.tempHolding(executor), EXECUTOR_GAS_COMP, "executor gas comp queued");
        assertEq(_spendable(executor, address(0)), executorInternalBefore, "no settler reward credited (it was 0)");
    }
}
