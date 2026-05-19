// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

/// @notice execute() timing edge cases:
///         1. Execute against a mature-but-unsettled oracle (no oracle.settle called)
///         2. looseTiming branches
///         3. maxGameTime race between bailOut and execute
contract OpenSwapExecuteFlowsTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    // Custom execute that does NOT mutate oracle state — for tests passing the raw post-report state.
    function _executeRaw(
        uint256 swapId,
        openSwapV2.MatchedSwap memory sPost,
        IOpenOracle2.OracleGame memory og,
        IOpenOracle2.PreimageHelper memory ph,
        bool looseTiming,
        address executor
    ) internal {
        vm.prank(executor);
        swapContract.execute(swapId, sPost, og, ph, looseTiming);
    }

    // ── 1. Execute against mature, unsettled oracle ──────────────────────

    function testExecute_MatureButUnsettled_Succeeds() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        // Build oracle state at report — settlementTimestamp == 0
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);
        assertEq(og.settlementTimestamp, 0, "oracle still unsettled");

        // Warp past settlementTime — settle is now eligible, but DO NOT call oracle.settle
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // Sanity: oracle's stored hash still matches our unsettled reconstruction
        assertEq(oracle.oracleGame(reportId), keccak256(abi.encode(og, ph)), "oracle hash unchanged");

        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        _executeRaw(swapId, sPost, og, ph, false, address(0x99));

        // Swap completed without a separate settle transaction (auto-settled inside execute).
        uint256 expectedFulfill = (uint256(SELL_AMT) * 2000e18) / INITIAL_LIQUIDITY;
        expectedFulfill -= (expectedFulfill * STARTING_FEE) / 1e7;
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + expectedFulfill, "swapper got buyToken in unified settle+execute");
    }

    // ── 2a. looseTiming branch 1: caller has stale pre-settle state ──────

    function testExecute_LooseTimingBranch1_SettleBeatExecutor() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        // Build state with settlementTimestamp = 0 (caller's view: not yet settled)
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        // Warp past settle eligibility
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // Settler beats the executor in the same block
        _settle(reportId, og, ph);
        // Oracle's hash now reflects post-settle state (settlementTimestamp = block.timestamp)
        // Our `og` still has settlementTimestamp = 0 — direct match fails.

        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        // Without looseTiming the hash check fails:
        vm.prank(address(0x99));
        vm.expectRevert(Errors.WrongOracleHash.selector);
        swapContract.execute(swapId, sPost, og, ph, false);

        // With looseTiming=true, branch 1 patches settlementTimestamp = block.timestamp and matches
        _executeRaw(swapId, sPost, og, ph, true, address(0x99));

        uint256 expectedFulfill = (uint256(SELL_AMT) * 2000e18) / INITIAL_LIQUIDITY;
        expectedFulfill -= (expectedFulfill * STARTING_FEE) / 1e7;
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + expectedFulfill, "looseTiming rescued execute");
    }

    // ── 2b. looseTiming branch 2: block-boundary settlement timestamp ────

    function testExecute_LooseTimingBranch2_TwoSecondSkew() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // Settler runs at time T → oracle stores settlementTimestamp = T
        uint48 settleTs = uint48(block.timestamp);
        _settle(reportId, og, ph);

        // 2 seconds later, executor's tx lands. They observed oracle.settled and used current
        // block.timestamp as their settlementTimestamp guess. But the oracle's stored ts is `settleTs`,
        // not `settleTs + 2`.
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);

        IOpenOracle2.OracleGame memory ogSkewed = og;
        ogSkewed.settlementTimestamp = uint48(block.timestamp); // executor's local guess

        // Direct match fails — oracle has settleTs, executor passed settleTs+2.
        vm.prank(address(0x99));
        vm.expectRevert(Errors.WrongOracleHash.selector);
        swapContract.execute(swapId, sPost, ogSkewed, ph, false);

        // With looseTiming, branch 2 subtracts 2 → settleTs → matches
        _executeRaw(swapId, sPost, ogSkewed, ph, true, address(0x99));

        assertGt(buyToken.balanceOf(swapper), 0, "swap completed via branch 2");
        settleTs; // silence
    }

    // ── 3a. maxGameTime race: bailOut first, then execute fails ──────────

    function testRace_BailoutThenExecute_ExecuteHashFails() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        // Warp past maxGameTime (also past settlementTime since maxGameTime ≥ 20 * settlementTime)
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // bailOut goes first
        swapContract.bailOut(swapId, sPost);

        // After bailOut, openSwap deleted the stored hash.
        // Executor tries execute against zero storage: hash mismatch.
        vm.prank(address(0x99));
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.execute(swapId, sPost, og, ph, false);
    }

    // ── 3b. maxGameTime race: execute first, then bailOut fails ──────────

    function testRace_ExecuteThenBailout_BailoutHashFails() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // execute goes first — succeeds because mature-unsettled state matches og directly
        _executeRaw(swapId, sPost, og, ph, false, address(0x99));

        // After execute, openSwap deleted the stored hash.
        // bailOut against zero storage: hash mismatch.
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.bailOut(swapId, sPost);
    }

    // ── 4. Reentrancy regression: delete-as-terminal-lock blocks re-execute ──

    /// @notice swapper is a contract that reenters execute() during the ETH push.
    ///         By the time receive() fires, swaps[swapId] has already been deleted,
    ///         so the reentrant execute() call fails on the hash check. Outer flow
    ///         completes once, swapper still receives funds (push or internal credit).
    function testReentrancy_ExecutePushETH_ReentrantExecuteFailsOnZeroHash() public {
        ReentrantSwapper attacker = new ReentrantSwapper(swapContract);

        // Fund the attacker so it can propose: sellToken (ERC20) → ETH
        sellToken.transfer(address(attacker), 10e18);
        vm.deal(address(attacker), 1 ether);
        attacker.approveErc20(address(sellToken), PERMIT2);

        // Matcher needs internal ETH balance to provide buyToken = ETH liquidity
        vm.deal(matcher, 100 ether);
        vm.startPrank(matcher);
        oracle.deposit{value: 10 ether}(address(0), 10 ether, matcher);
        oracle.approveInternal(address(swapContract), address(0), type(uint256).max);
        vm.stopPrank();

        // Propose ERC20→ETH at a price that fits slippage at amount2 = 2e18
        // sellAmt=1e18, amount2=2e18 → price = 1e18*1e30/2e18 = 5e29
        uint128 sellAmt = 1e18;
        uint128 minFulfill = 3 ether;
        uint96 mgc = 0.001 ether;
        uint96 egc = 0.001 ether;
        SwapCompat.SlippageParams memory slip =
            SwapCompat.SlippageParams({priceTolerated: 5e29, toleranceRange: 1e7 - 1});

        proposeTs = uint48(block.timestamp);
        uint256 swapId = attacker.doPropose{value: uint256(mgc) + uint256(egc) + SETTLER_REWARD}(
            sellAmt, address(sellToken), 1, address(0), minFulfill,
            uint48(1 hours), mgc, egc,
            _defaultOracleParams(), slip, _defaultFulfillFee(), _emptyPermit2(), false
        );

        // Rebuild the exact Swap/MatcherPreimage that propose hashed (swapper = attacker)
        openSwapV2.ProposedSwap memory s;
        s.swapper = address(attacker);
        s.sellAmt = sellAmt;
        s.sellToken = address(sellToken);
        s.buyToken = address(0);
        s.minFulfillLiquidity = minFulfill;
        s.expiration = uint48(block.timestamp + 1 hours);
        s.maxGameTime = MAX_GAME_TIME;
        s.blocksPerSecond = 500;
        s.settlerReward = SETTLER_REWARD;
        s.priceTolerated = slip.priceTolerated;
        s.toleranceRange = slip.toleranceRange;
        s.matcherGasComp = mgc;
        s.executorGasComp = egc;
        s.useInternalBalances = false;
        openSwapV2.MatcherPreimage memory m;
        SwapCompat.OracleParams memory op = _defaultOracleParams();
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

        // Match
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        vm.prank(matcher);
        swapContract.matchSwap(swapId, uint128(2 ether), s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));

        openSwapV2.MatchedSwap memory sPost = _postMatchSwap(s, 1, STARTING_FEE, reportTs);

        // Build oracle game state at report-time + helper
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, uint128(2 ether));
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(1);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(1, og, ph);
        og.settlementTimestamp = uint48(block.timestamp); // mirror oracle's settled state

        // Arm the attacker to reenter execute() during its receive()
        bytes memory reentrantCalldata = abi.encodeWithSelector(
            openSwapV2.execute.selector, swapId, sPost, og, ph, false
        );
        attacker.armReentry(reentrantCalldata);

        // Execute — pushes ETH to attacker; attacker's receive() reenters execute()
        vm.prank(address(0x99));
        swapContract.execute(swapId, sPost, og, ph, false);

        // Outer flow completed once: swap hash deleted, attacker got fulfillAmt (push or internal)
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-execute");
        assertTrue(attacker.reentryAttempted(), "attacker's receive() did fire");
        assertTrue(attacker.reentryReverted(), "reentrant execute() reverted (zero-hash lock)");
    }
}

/// @notice Helper contract that reenters openSwap.execute() via its receive() hook
///         when ETH is pushed to it. Used to verify delete-as-terminal-lock.
contract ReentrantSwapper {
    openSwapV2 immutable sc;
    bytes private _reentrantCalldata;
    bool public reentryAttempted;
    bool public reentryReverted;

    constructor(openSwapV2 _sc) { sc = _sc; }

    function approveErc20(address token, address spender) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "approve failed");
    }

    function doPropose(
        uint128 sellAmt, address sellToken, uint128 minOut, address buyToken, uint128 minFulfillLiquidity,
        uint48 expiration, uint96 matcherGasComp, uint96 executorGasComp,
        SwapCompat.OracleParams calldata op, SwapCompat.SlippageParams calldata slip,
        openSwapV2.FulfillFeeParams calldata ff, openSwapV2.Permit2Params calldata pp, bool useInternalBalances
    ) external payable returns (uint256) {
        return SwapCompat.proposeRaw(
            sc, msg.value,
            sellAmt, sellToken, minOut, buyToken, minFulfillLiquidity,
            expiration, matcherGasComp, executorGasComp, op, slip, ff, pp, useInternalBalances
        );
    }

    function armReentry(bytes calldata cd) external { _reentrantCalldata = cd; }

    receive() external payable {
        if (_reentrantCalldata.length > 0 && !reentryAttempted) {
            reentryAttempted = true;
            (bool ok,) = address(sc).call(_reentrantCalldata);
            if (!ok) reentryReverted = true;
        }
    }
}
