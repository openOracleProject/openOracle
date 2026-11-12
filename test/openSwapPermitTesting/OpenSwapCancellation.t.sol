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

        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        (IOpenOracle2.OracleGame memory og, IOpenOracle2.PreimageHelper memory ph) =
            _gameAtMatch(swapId, expiration, 2000e18, sPost);

        // Disputes push settlement eligibility past start + maxGameTime
        og = _disputePastMaxGameTime(og, ph, sPost);
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        vm.prank(randomUser);
        swapContract.bailOut(swapId, sPost, og, ph);

        // Swap hash deleted on terminal transition
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-bailOut");

        // Swapper refund via pushOrCredit (external push to EOA)
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "swapper sellToken refunded");

        // Matcher refund of minFulfillLiquidity buyToken via internalTransferFrom (internal balance)
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore + MIN_FULFILL_LIQUIDITY,
            "matcher minFulfillLiquidity refunded"
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
        IOpenOracle2.OracleGame memory og;
        IOpenOracle2.PreimageHelper memory ph;

        vm.prank(randomUser);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.bailOut(swapId, s, og, ph);
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
        IOpenOracle2.OracleGame memory og;
        IOpenOracle2.PreimageHelper memory ph;
        vm.prank(randomUser);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.bailOut(swapId, dummy, og, ph);
    }

    function testBailOut_FailsIfFinished() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        (IOpenOracle2.OracleGame memory og, IOpenOracle2.PreimageHelper memory ph) =
            _gameAtMatch(swapId, expiration, 2000e18, sPost);
        og = _disputePastMaxGameTime(og, ph, sPost);

        swapContract.bailOut(swapId, sPost, og, ph);

        // Swap hash deleted on terminal transition; any subsequent bailOut fails the hash check.
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.bailOut(swapId, sPost, og, ph);
    }

    function testBailOut_NoOpIfLatencyNotReached() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        (IOpenOracle2.OracleGame memory og, IOpenOracle2.PreimageHelper memory ph) =
            _gameAtMatch(swapId, expiration, 2000e18, sPost);

        // No disputes: eligibility is start + settlementTime, far inside maxGameTime
        vm.expectRevert(Errors.CantBailOutYet.selector);
        swapContract.bailOut(swapId, sPost, og, ph);
    }

    function testBailOut_ExactLatencyBoundary() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        (IOpenOracle2.OracleGame memory og, IOpenOracle2.PreimageHelper memory ph) =
            _gameAtMatch(swapId, expiration, 2000e18, sPost);
        // Eligibility == start + maxGameTime: check is `> maxGameTime`, so bailOut reverts.
        og = _disputeToMaxGameTimeBoundary(og, ph, sPost);
        vm.expectRevert(Errors.CantBailOutYet.selector);
        swapContract.bailOut(swapId, sPost, og, ph);

        // Next dispute pushes eligibility past the limit; bailOut succeeds.
        og = _disputeAt(og, ph, uint256(og.reportTimestamp) + og.disputeDelay);
        swapContract.bailOut(swapId, sPost, og, ph);
        assertEq(swapContract.swaps(swapId), bytes32(0), "bailed out past boundary");
    }
}
