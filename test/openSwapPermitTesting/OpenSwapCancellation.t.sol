// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";

contract OpenSwapCancellationTest is SlimTestBase {
    address internal randomUser = address(0x5);

    function setUp() public {
        _setUpAll();
        vm.deal(randomUser, 1 ether);
    }

    // ── cancelSwap ─────────────────────────────────────────────────────

    function testCancelSwap_Success() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        (uint256 swapId, uint48 expiration) = _propose();

        // Swapper paid sellToken via Permit2 and ETH via msg.value
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "sellToken sent");
        assertEq(swapper.balance, swapperEthBefore - ethToSend, "ETH sent");

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);

        // Swap hash deleted on terminal transition
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-cancel");

        // sellToken refunded externally via pushOrCredit
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "swapper sellToken refunded");
        // ETH refunded via payEth (gas comps + settler reward)
        assertEq(swapper.balance, swapperEthBefore, "swapper ETH refunded");
        // openSwap internal slot for sellToken back to 1 (sentinel only)
        assertEq(_spendable(address(swapContract), address(sellToken)), 0, "openSwap sellToken drained");
    }

    function testCancelSwap_FailsIfNotSwapper() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(randomUser);
        vm.expectRevert(Errors.NotSwapper.selector);
        swapContract.cancelSwap(swapId, s, m);
    }

    function testCancelSwap_FailsAfterMatch() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        _match(swapId, 2000e18, expiration);

        // Post-match the storage hash is keccak256(Swap-only), not keccak256(Swap, Preimage).
        // Hash check fails before any state guard.
        vm.prank(swapper);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.cancelSwap(swapId, s, m);
    }

    function testCancelSwap_FailsIfAlreadyCancelled() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);

        // After cancel the storage hash changes — same (s, m) input now mismatches.
        vm.prank(swapper);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.cancelSwap(swapId, s, m);
    }

    function testCancelSwap_FailsForNonexistentSwapId() public {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(999, uint48(block.timestamp + 1 hours));
        vm.prank(swapper);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.cancelSwap(999, s, m);
    }

    function testCancelSwap_MatcherCannotCancel() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(matcher);
        vm.expectRevert(Errors.NotSwapper.selector);
        swapContract.cancelSwap(swapId, s, m);
    }

    function testCancelSwap_EmitsEvent() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(swapper);
        vm.expectEmit(false, false, false, true);
        emit openSwapV2.SwapCancelled(swapId);
        swapContract.cancelSwap(swapId, s, m);
    }

    function testCancelSwap_MultipleSwapsCancelIndependently() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        (uint256 swapId1, uint48 expiration1) = _propose();
        (uint256 swapId2,) = _propose();

        (openSwapV2.ProposedSwap memory s1, openSwapV2.MatcherPreimage memory m1) =
            _buildSwapAndPreimage(swapId1, expiration1);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId1, s1, m1);

        // swap1's hash deleted; swap2's hash is unchanged
        assertEq(swapContract.swaps(swapId1), bytes32(0), "swap1 hash deleted post-cancel");

        // Swap1 returned, swap2 still locked
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "swap2 still locked");
        // openSwap's internal balance still holds swap2's sellAmt
        assertEq(_spendable(address(swapContract), address(sellToken)), SELL_AMT, "openSwap still holds swap2");
        // Verify swap2 not affected: should still be cancellable later
        (openSwapV2.ProposedSwap memory s2, openSwapV2.MatcherPreimage memory m2) =
            _buildSwapAndPreimage(swapId2, expiration1);
        vm.prank(swapper);
        swapContract.cancelSwap(swapId2, s2, m2);
    }

    // ── bailOut ─────────────────────────────────────────────────────────

    function testBailOut_SuccessLatencyTimeout() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        // Warp past maxGameTime
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        vm.prank(randomUser);
        swapContract.bailOut(swapId, sPost);

        // Swap hash deleted on terminal transition
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-bailOut");

        // Swapper refund via pushOrCredit (external push to EOA)
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "swapper sellToken refunded");

        // Matcher refund of minFulfillLiquidity buyToken via internalTransferFrom (internal balance)
        // Pre-match buyToken internal was matcherBuyInternalBefore. After match it's
        // matcherBuyInternalBefore - amount2 - MIN_FULFILL_LIQUIDITY (amount2 sits in the oracle game).
        // After bailOut refund, MIN_FULFILL_LIQUIDITY comes back.
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore - 2000e18,
            "matcher buyToken: only amount2 still escrowed in oracle game"
        );

        // openSwap drained of both tokens
        assertEq(_spendable(address(swapContract), address(sellToken)), 0, "openSwap sellToken drained");
        assertEq(_spendable(address(swapContract), address(buyToken)), 0, "openSwap buyToken drained");

        // randomUser (bailOut caller) got executor gas comp
        assertEq(swapContract.tempHolding(randomUser), EXECUTOR_GAS_COMP, "executor reward queued");
    }

    function testBailOut_FailsIfNotMatched() public {
        (uint256 swapId, uint48 expiration) = _propose();
        expiration;
        // Pre-match storage holds keccak(ProposedSwap, Preimage); bailOut hashes MatchedSwap so
        // any MatchedSwap value (zero-init here) will hash-mismatch.
        openSwapV2.MatchedSwap memory s;

        vm.prank(randomUser);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.bailOut(swapId, s);
    }

    function testBailOut_FailsIfCancelled() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);

        // Hash was deleted on cancel, so any bailOut input fails the hash check.
        s;
        openSwapV2.MatchedSwap memory dummy;
        vm.prank(randomUser);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.bailOut(swapId, dummy);
    }

    function testBailOut_FailsIfFinished() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        swapContract.bailOut(swapId, sPost);

        // Swap hash deleted on terminal transition; any subsequent bailOut fails the hash check.
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.bailOut(swapId, sPost);
    }

    function testBailOut_NoOpIfLatencyNotReached() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        // No time elapsed — bailOut should revert
        vm.expectRevert(Errors.CantBailOutYet.selector);
        swapContract.bailOut(swapId, sPost);
    }

    function testBailOut_ExactLatencyBoundary() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        uint256 matchTime = sPost.start;

        // Exactly at matchTime + MAX_GAME_TIME — check is `> maxGameTime`, so this should revert
        vm.warp(matchTime + MAX_GAME_TIME);
        vm.roll(block.number + MAX_GAME_TIME / 2);
        vm.expectRevert(Errors.CantBailOutYet.selector);
        swapContract.bailOut(swapId, sPost);

        // 1 second past boundary — should succeed
        vm.warp(matchTime + MAX_GAME_TIME + 1);
        vm.roll(block.number + 1);
        swapContract.bailOut(swapId, sPost);
    }
}
