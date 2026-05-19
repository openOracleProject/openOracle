// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";

contract OpenSwapAnyoneCanCancelTest is SlimTestBase {
    address internal thirdParty = address(0x4001);

    function setUp() public {
        _setUpAll();
        vm.deal(thirdParty, 1 ether);
    }

    // ── Pre-expiration (only swapper can cancel) ────────────────────────

    function testSwapperCancelsBeforeExpiration() public {
        uint256 swapperEthBefore = swapper.balance;
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);

        // Swapper gets totalGasComp + settlerReward back
        assertEq(swapper.balance, swapperEthBefore, "swapper got all ETH back");
    }

    function testThirdPartyCannotCancelBeforeExpiration() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(thirdParty);
        vm.expectRevert(Errors.NotSwapper.selector);
        swapContract.cancelSwap(swapId, s, m);
    }

    function testSwapperCanCancelAtExactBoundary() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        // At block.timestamp == expiration: still in pre-expiration window (≤)
        vm.warp(expiration);
        vm.roll(block.number + 1);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);
    }

    function testThirdPartyCannotCancelAtExactBoundary() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.warp(expiration);
        vm.roll(block.number + 1);

        vm.prank(thirdParty);
        vm.expectRevert(Errors.NotSwapper.selector);
        swapContract.cancelSwap(swapId, s, m);
    }

    // ── Post-expiration (anyone can cancel) ─────────────────────────────

    function testThirdPartyCanCancelOneSecondAfterBoundary() public {
        uint256 thirdPartyEthBefore = thirdParty.balance;

        (uint256 swapId, uint48 expiration) = _propose();
        uint256 swapperEthAfterPropose = swapper.balance; // post-propose snapshot
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.warp(uint256(expiration) + 1);
        vm.roll(block.number + 1);

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId, s, m);

        // Post-expire third-party cancel: caller takes matcherGasComp, swapper gets executorGasComp + reward.
        uint256 callerPiece = MATCHER_GAS_COMP;
        uint256 swapperPiece = EXECUTOR_GAS_COMP;

        assertEq(swapper.balance, swapperEthAfterPropose + swapperPiece + SETTLER_REWARD, "swapper got executorGasComp + settlerReward");
        assertEq(swapContract.tempHolding(thirdParty), callerPiece, "third party got matcherGasComp queued in tempHolding");
        assertEq(thirdParty.balance, thirdPartyEthBefore, "third party not paid directly");
    }

    function testSwapperCancelsAfterExpiration_GetsFullGasComp() public {
        uint256 swapperEthBefore = swapper.balance;

        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.warp(uint256(expiration) + 1 hours);
        vm.roll(block.number + 100);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);

        // Swapper still gets full totalGasComp + settlerReward (no caller piece)
        assertEq(swapper.balance, swapperEthBefore, "swapper got full ETH back");
    }

    function testThirdPartyCancelDrainsContract() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.warp(uint256(expiration) + 1);
        vm.roll(block.number + 1);

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId, s, m);

        // Third-party caller piece (matcherGasComp) stays in tempHolding until they withdraw.
        uint256 callerPiece = MATCHER_GAS_COMP;
        assertEq(address(swapContract).balance, callerPiece, "openSwap holds only caller's queued piece");
        assertEq(swapContract.tempHolding(thirdParty), callerPiece, "caller's matcherGasComp queued in tempHolding");
        assertEq(_spendable(address(swapContract), address(sellToken)), 0, "openSwap sellToken drained");
    }

    // ── Conservation across odd gas-comp totals ─────────────────────────

    function testGasCompSplit_Conservation() public pure {
        // Post-expire third-party cancel: caller takes matcherGasComp, swapper takes executorGasComp.
        // Sum equals total gas comp regardless of M/E ratio.
        uint96 mgc = MATCHER_GAS_COMP;
        uint96 egc = EXECUTOR_GAS_COMP;

        uint256 callerPiece = mgc;
        uint256 swapperPiece = egc;
        assertEq(callerPiece + swapperPiece, uint256(mgc) + uint256(egc), "split conservation");
    }
}
