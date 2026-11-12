// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

/// @notice execute() timing edge cases:
///         1. Execute against a mature-but-unsettled oracle (no oracle.settle called)
///         2. settlementSearchDepth recovery
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
        uint8 settlementSearchDepth,
        address executor
    ) internal {
        vm.prank(executor);
        swapContract.execute(swapId, sPost, og, ph, settlementSearchDepth);
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

        // Roll past settlementTime — settle is now eligible, but DO NOT call oracle.settle
        vm.roll(block.number + SETTLEMENT_TIME + 1);
        vm.warp(block.timestamp + (SETTLEMENT_TIME + 1) / 5);

        // Sanity: oracle's stored hash still matches our unsettled reconstruction
        assertEq(oracle.oracleGame(reportId), keccak256(abi.encode(og, ph)), "oracle hash unchanged");

        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        _executeRaw(swapId, sPost, og, ph, 0, address(0x99));

        // Swap completed without a separate settle transaction (auto-settled inside execute).
        uint256 expectedFulfill = (uint256(SELL_AMT) * 2000e18) / INITIAL_LIQUIDITY;
        expectedFulfill -= (expectedFulfill * STARTING_FEE) / 1e7;
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + expectedFulfill, "swapper got buyToken in unified settle+execute");
    }

    // ── 2a. settlementSearchDepth: settle beat the executor in the same block ──

    function testExecute_SearchDepth_SettleSameBlock() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        // Build state with settlementTimestamp = 0 (caller's view: not yet settled)
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        // Roll past settle eligibility
        vm.roll(block.number + SETTLEMENT_TIME + 1);
        vm.warp(block.timestamp + (SETTLEMENT_TIME + 1) / 5);

        // Settler beats the executor in the same block
        _settle(reportId, og, ph);
        // Oracle's hash now reflects post-settle state (settlementTimestamp = block.number)
        // Our `og` still has settlementTimestamp = 0 — direct match fails.

        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        // Depth 0 disables recovery, so the hash check fails:
        vm.prank(address(0x99));
        vm.expectRevert(Errors.WrongOracleHash.selector);
        swapContract.execute(swapId, sPost, og, ph, 0);

        // Depth 1 tries the current block and matches
        _executeRaw(swapId, sPost, og, ph, 1, address(0x99));

        uint256 expectedFulfill = (uint256(SELL_AMT) * 2000e18) / INITIAL_LIQUIDITY;
        expectedFulfill -= (expectedFulfill * STARTING_FEE) / 1e7;
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + expectedFulfill, "search depth rescued execute");
    }

    // ── 2b. settlementSearchDepth: settle landed blocks before the executor ──

    function testExecute_SearchDepth_SettleEarlierBlock() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.roll(block.number + SETTLEMENT_TIME + 1);
        vm.warp(block.timestamp + (SETTLEMENT_TIME + 1) / 5);

        // Settler runs at block B → oracle stores settlementTimestamp = B
        _settle(reportId, og, ph);

        // The executor's tx lands 3 blocks later, still built from the unsettled state.
        vm.roll(block.number + 3);

        // Depth 3 tries B+3, B+2, B+1 — one short of the settle block.
        vm.prank(address(0x99));
        vm.expectRevert(Errors.WrongOracleHash.selector);
        swapContract.execute(swapId, sPost, og, ph, 3);

        // Depth 4 reaches B and matches
        _executeRaw(swapId, sPost, og, ph, 4, address(0x99));

        assertGt(buyToken.balanceOf(swapper), 0, "swap completed via search depth");
    }

    // ── 2c. settlementSearchDepth only recovers a zero settlementTimestamp ──

    function testExecute_SearchDepth_WrongNonzeroGuessNotRecovered() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.roll(block.number + SETTLEMENT_TIME + 1);
        vm.warp(block.timestamp + (SETTLEMENT_TIME + 1) / 5);
        _settle(reportId, og, ph);
        vm.roll(block.number + 1);

        IOpenOracle2.OracleGame memory ogGuessed = og;
        ogGuessed.settlementTimestamp = uint48(block.number); // executor's wrong guess

        vm.prank(address(0x99));
        vm.expectRevert(Errors.WrongOracleHash.selector);
        swapContract.execute(swapId, sPost, ogGuessed, ph, type(uint8).max);
    }

    // ── 3a. maxGameTime race: bailOut first, then execute fails ──────────

    function _matchedGame()
        internal
        returns (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        )
    {
        uint48 expiration;
        (swapId, expiration) = _propose();
        (, , sPost) = _match(swapId, 2000e18, expiration);
        (og, ph) = _gameAtMatch(swapId, expiration, 2000e18, sPost);
    }

    /// @dev Rolls to the game's eligibility block and settles it. Returns the settled game.
    function _settleLive(IOpenOracle2.OracleGame memory og, IOpenOracle2.PreimageHelper memory ph)
        internal
        returns (IOpenOracle2.OracleGame memory)
    {
        uint256 settleBlock = uint256(og.reportTimestamp) + og.settlementTime;
        vm.roll(settleBlock);
        _settle(uint128(ph.reportId), og, ph);
        og.settlementTimestamp = uint48(settleBlock);
        return og;
    }

    function testRace_BailoutThenExecute_ExecuteHashFails() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _matchedGame();
        og = _disputePastMaxGameTime(og, ph, sPost);

        // bailOut goes first
        swapContract.bailOut(swapId, sPost, og, ph);

        // After bailOut, openSwap deleted the stored hash.
        // Executor tries execute against zero storage: hash mismatch.
        vm.roll(uint256(og.reportTimestamp) + og.settlementTime);
        vm.prank(address(0x99));
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.execute(swapId, sPost, og, ph, 0);
    }

    // ── 3b. maxGameTime race: execute first, then bailOut fails ──────────

    function testRace_ExecuteThenBailout_BailoutHashFails() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _matchedGame();
        og = _disputePastMaxGameTime(og, ph, sPost);

        // execute goes first. The game ran past maxGameTime, so execute itself refunds the swap.
        vm.roll(uint256(og.reportTimestamp) + og.settlementTime);
        _executeRaw(swapId, sPost, og, ph, 0, address(0x99));
        og.settlementTimestamp = uint48(block.number);

        // After execute, openSwap deleted the stored hash.
        // bailOut against zero storage: hash mismatch.
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.bailOut(swapId, sPost, og, ph);
    }

    function testExecute_AtExactMaxGameTime_ExecutesNormally() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _matchedGame();
        og = _disputeToMaxGameTimeBoundary(og, ph, sPost);
        og = _settleLive(og, ph);
        assertEq(block.number, uint256(sPost.start) + sPost.maxGameTime, "settled at start + maxGameTime");

        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        vm.expectEmit(false, false, false, true, address(swapContract));
        emit openSwapV2.SwapExecuted(swapId);
        _executeRaw(swapId, sPost, og, ph, 0, address(0x99));

        assertGt(buyToken.balanceOf(swapper), swapperBuyBefore, "strict boundary still executes");
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap terminal");
    }

    function testExecute_AfterMaxGameTime_RefundsInsteadOfSwapping() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _matchedGame();
        og = _disputePastMaxGameTime(og, ph, sPost);
        og = _settleLive(og, ph);

        vm.expectEmit(false, false, false, true, address(swapContract));
        emit openSwapV2.MaxGameTimeBailout(swapId);
        vm.expectEmit(false, true, true, true, address(swapContract));
        emit openSwapV2.SwapRefunded(swapId, swapper, matcher);
        _executeRaw(swapId, sPost, og, ph, 0, address(0x99));

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "swapper sell token refunded");
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore, "swapper receives no fill");
        assertEq(swapContract.tempHolding(address(0x99)), EXECUTOR_GAS_COMP, "executor still compensated");
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap terminal");
    }

    function testExecute_SettledBeforeDeadlineButCalledAfterDeadline_ExecutesNormally() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _matchedGame();
        og = _settleLive(og, ph);

        // A late execute does not change the outcome: only the game's timeline counts.
        vm.roll(uint256(sPost.start) + sPost.maxGameTime * 2);

        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        vm.expectEmit(false, false, false, true, address(swapContract));
        emit openSwapV2.SwapExecuted(swapId);
        _executeRaw(swapId, sPost, og, ph, 0, address(0x99));

        assertGt(buyToken.balanceOf(swapper), swapperBuyBefore, "late execution still fills");
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap terminal");
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

        proposeBn = uint48(block.number);
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
        m.startFulfillFeeIncrease = proposeBn;
        SwapCompat.FulfillFeeParams memory ff = _defaultFulfillFee();
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

        openSwapV2.MatchedSwap memory sPost = _postMatchSwap(s, 1, STARTING_FEE, reportBn);

        // Build oracle game state at report-time + helper
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, uint128(2 ether));
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(1);

        vm.roll(block.number + SETTLEMENT_TIME + 1);
        vm.warp(block.timestamp + (SETTLEMENT_TIME + 1) / 5);
        _settle(1, og, ph);
        og.settlementTimestamp = uint48(block.number); // mirror oracle's settled state

        // Arm the attacker to reenter execute() during its receive()
        bytes memory reentrantCalldata = abi.encodeWithSelector(
            openSwapV2.execute.selector, swapId, sPost, og, ph, uint8(0)
        );
        attacker.armReentry(reentrantCalldata);

        // Execute — pushes ETH to attacker; attacker's receive() reenters execute()
        vm.prank(address(0x99));
        swapContract.execute(swapId, sPost, og, ph, 0);

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
        SwapCompat.FulfillFeeParams calldata ff, openSwapV2.Permit2Params calldata pp, bool useInternalBalances
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
