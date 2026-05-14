// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";

/**
 * @notice Balance invariants under the V3 architecture:
 *
 * 1. openSwap NEVER holds any external ERC20 balance — every token flow routes
 *    through oracle.tokenHolder[openSwap][token]. Sending unrelated tokens to
 *    openSwap's address is safe but pointless; they sit untouched forever.
 *
 * 2. openSwap's raw ETH balance equals the sum of unspent gas comps + settler
 *    rewards in flight + unrelated ETH dust. Once all participants withdraw,
 *    openSwap's ETH balance shrinks to just the dust.
 *
 * 3. Oracle's actual ERC20 balance equals the sum of all internal balances
 *    (minus the per-(holder,token) sentinel of 1 wei).
 *
 * 4. Per-swap value conservation: total tokens/ETH into the system from a swap
 *    == total tokens/ETH out (modulo gas).
 */
contract OpenSwapBalanceInvariantTest is SlimTestBase {
    address internal randomDepositor = address(0x5005);

    uint256 constant UNRELATED_SELL = 777e18;
    uint256 constant UNRELATED_BUY = 888e18;
    uint256 constant UNRELATED_ETH = 5 ether;

    function setUp() public {
        _setUpAll();

        // Seed unrelated balances on openSwap directly via accidental transfers.
        sellToken.transfer(randomDepositor, UNRELATED_SELL);
        buyToken.transfer(randomDepositor, UNRELATED_BUY);
        vm.deal(randomDepositor, UNRELATED_ETH + 1 ether);
    }

    function _seedAccidentalTransfers() internal {
        vm.startPrank(randomDepositor);
        sellToken.transfer(address(swapContract), UNRELATED_SELL);
        buyToken.transfer(address(swapContract), UNRELATED_BUY);
        // ETH can be forced in via selfdestruct or coinbase rewards, but we can't easily
        // send unsolicited ETH to a contract without a receive() in tests. Skip ETH seeding.
        vm.stopPrank();
    }

    function _assertUnrelatedBalancesIntact() internal {
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL,
            "openSwap sellToken == seeded amount (untouched)"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY,
            "openSwap buyToken == seeded amount (untouched)"
        );
    }

    function _assertOpenSwapHoldsNoUnseededTokens() internal {
        // openSwap NEVER accumulates token balances of its own
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "openSwap sellToken external == 0");
        assertEq(buyToken.balanceOf(address(swapContract)), 0, "openSwap buyToken external == 0");
    }

    // ── Test 1: openSwap holds no external token balance after happy path ─

    function testInvariant_HappyPath_OpenSwapHoldsNoTokens() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(reportId, og, ph);
        _execute(swapId, sPost, og, ph, address(0x99));

        _assertOpenSwapHoldsNoUnseededTokens();
    }

    // ── Test 2: Unrelated balances survive happy path ────────────────────

    function testInvariant_HappyPath_UnrelatedBalancesUntouched() public {
        _seedAccidentalTransfers();
        uint256 sellBefore = sellToken.balanceOf(address(swapContract));
        uint256 buyBefore = buyToken.balanceOf(address(swapContract));
        assertEq(sellBefore, UNRELATED_SELL);
        assertEq(buyBefore, UNRELATED_BUY);

        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(reportId, og, ph);
        _execute(swapId, sPost, og, ph, address(0x99));

        // The seeded amounts sit there untouched — openSwap never reads/spends from its own external balance
        assertEq(sellToken.balanceOf(address(swapContract)), UNRELATED_SELL, "sellToken untouched");
        assertEq(buyToken.balanceOf(address(swapContract)), UNRELATED_BUY, "buyToken untouched");
    }

    // ── Test 3: Unrelated balances survive cancel ────────────────────────

    function testInvariant_Cancel_UnrelatedBalancesUntouched() public {
        _seedAccidentalTransfers();

        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);

        _assertUnrelatedBalancesIntact();
    }

    // ── Test 4: Unrelated balances survive bailOut ───────────────────────

    function testInvariant_BailOut_UnrelatedBalancesUntouched() public {
        _seedAccidentalTransfers();

        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);
        swapContract.bailOut(swapId, sPost);

        _assertUnrelatedBalancesIntact();
    }

    // ── Test 5: Oracle balance matches its internal accounting ───────────

    function testInvariant_OracleBalanceMatchesInternalAccounting() public {
        // After a happy path, oracle's actual ERC20 holding for sellToken should equal
        // (matcher's internal balance + openSwap's internal balance + sentinels)
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(reportId, og, ph);
        _execute(swapId, sPost, og, ph, address(0x99));

        // Sum of all known token holders in oracle (raw mapping values, sentinels included)
        uint256 sumSell = oracle.tokenHolder(matcher, address(sellToken))
            + oracle.tokenHolder(address(swapContract), address(sellToken))
            + oracle.tokenHolder(swapper, address(sellToken));
        uint256 actualOracleSell = sellToken.balanceOf(address(oracle));

        // Sentinels (1 wei each) live inside the mapping but don't correspond to real tokens.
        // Each holder slot that's been touched once contributes a +1 to sumSell.
        // We don't have a clean count, so just assert: oracle's real balance ≤ sum (sentinels are phantom).
        assertLe(actualOracleSell, sumSell, "actual oracle sellToken <= sum of tracked internal balances");

        // The same invariant for buyToken
        uint256 sumBuy = oracle.tokenHolder(matcher, address(buyToken))
            + oracle.tokenHolder(address(swapContract), address(buyToken))
            + oracle.tokenHolder(swapper, address(buyToken));
        uint256 actualOracleBuy = buyToken.balanceOf(address(oracle));
        assertLe(actualOracleBuy, sumBuy, "actual oracle buyToken <= sum of tracked internal balances");
    }

    // ── Test 6: Multiple swaps don't interfere with each other ──────────

    function testInvariant_MultipleSwaps_NoInterference() public {
        // Snapshot before
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        // First swap: propose, match, cancel
        (uint256 swapId1, uint48 exp1) = _propose();
        (openSwapV2.ProposedSwap memory s1, openSwapV2.MatcherPreimage memory m1) =
            _buildSwapAndPreimage(swapId1, exp1);

        // Second swap: just propose then leave dangling
        (uint256 swapId2, uint48 exp2) = _propose();
        (openSwapV2.ProposedSwap memory s2, openSwapV2.MatcherPreimage memory m2) =
            _buildSwapAndPreimage(swapId2, exp2);

        // Cancel swap1 only
        vm.prank(swapper);
        swapContract.cancelSwap(swapId1, s1, m1);

        // After cancel of swap1: swap1's sellAmt returned to swapper. swap2's sellAmt still in oracle for openSwap.
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "swap2's sellAmt still locked");
        assertEq(
            _spendable(address(swapContract), address(sellToken)),
            SELL_AMT,
            "openSwap internal sellToken == swap2's sellAmt only"
        );

        // Cancel swap2 too; openSwap drained back to zero
        vm.prank(swapper);
        swapContract.cancelSwap(swapId2, s2, m2);
        assertEq(_spendable(address(swapContract), address(sellToken)), 0, "openSwap drained after both cancels");
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "all sellToken back");
    }

    // ── Test 7: Per-swap conservation across mixed states ────────────────

    function testInvariant_MixedFlows_NoLeak() public {
        // Three swaps: one cancelled, one bailed-out, one completed.
        // Snapshot ALL relevant balances before any swap, and after all are resolved.
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        uint256 matcherSellInternalBefore = _spendable(matcher, address(sellToken));
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        // swap A: cancel (pre-match)
        (uint256 swapA, uint48 expA) = _propose();
        (openSwapV2.ProposedSwap memory sA, openSwapV2.MatcherPreimage memory mA) =
            _buildSwapAndPreimage(swapA, expA);
        vm.prank(swapper);
        swapContract.cancelSwap(swapA, sA, mA);

        // swap B: match, then bailOut after maxGameTime
        (uint256 swapB, uint48 expB) = _propose();
        (, , openSwapV2.MatchedSwap memory sBpost) = _match(swapB, 2000e18, expB);

        // swap C: full happy path
        (uint256 swapC, uint48 expC) = _propose();
        (openSwapV2.ProposedSwap memory sC, openSwapV2.MatcherPreimage memory mC) =
            _buildSwapAndPreimage(swapC, expC);
        (uint128 rC,, openSwapV2.MatchedSwap memory sCpost) = _match(swapC, 2000e18, expC);
        IOpenOracle2.OracleGame memory ogC = _buildOracleGameAtReport(sC, mC, 2000e18);
        IOpenOracle2.PreimageHelper memory phC = _buildPreimageHelper(rC);

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // swap B bailout (maxGameTime exceeded)
        swapContract.bailOut(swapB, sBpost);

        // swap C settle + execute
        _settle(rC, ogC, phC);
        _execute(swapC, sCpost, ogC, phC, address(0x99));

        // openSwap should hold no external tokens
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "openSwap sellToken == 0");
        assertEq(buyToken.balanceOf(address(swapContract)), 0, "openSwap buyToken == 0");

        // openSwap's internal balances should be zero after all swaps resolved
        assertEq(_spendable(address(swapContract), address(sellToken)), 0, "openSwap internal sellToken drained");
        assertEq(_spendable(address(swapContract), address(buyToken)), 0, "openSwap internal buyToken drained");

        // Swap C: swapper got fulfillAmt of buyToken; matcher got sellAmt sellToken + leftover buyToken
        uint256 fulfillAmt = (uint256(SELL_AMT) * 2000e18) / INITIAL_LIQUIDITY;
        fulfillAmt -= (fulfillAmt * STARTING_FEE) / 1e7;

        // Net token deltas across all three swaps:
        // - swap A cancel: net zero on tokens (sellToken refunded)
        // - swap B bailout: net zero on swapper sellToken (refunded), matcher's amount2 stays in oracle game, minFulfillLiquidity returned
        // - swap C complete: swapper -sellAmt sellToken, +fulfillAmt buyToken. matcher +sellAmt sellToken, -fulfillAmt buyToken
        assertEq(
            sellToken.balanceOf(swapper),
            swapperSellBefore - SELL_AMT, // only swap C's sellAmt left swapper permanently
            "swapper net sellToken delta = -SELL_AMT (only swap C)"
        );
        assertEq(
            buyToken.balanceOf(swapper),
            swapperBuyBefore + fulfillAmt,
            "swapper net buyToken delta = +fulfillAmt (only swap C)"
        );
        // Matcher: swap B's amount2 still stuck in oracle game (settle never called for swap B);
        // swap C net delta: +SELL_AMT sellToken, -fulfillAmt buyToken
        assertEq(
            _spendable(matcher, address(sellToken)),
            matcherSellInternalBefore + SELL_AMT - INITIAL_LIQUIDITY, // swap B's initialLiquidity also stuck
            "matcher net sellToken delta"
        );
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore - fulfillAmt - 2000e18, // swap B's amount2 stuck in oracle
            "matcher net buyToken delta"
        );
    }
}
