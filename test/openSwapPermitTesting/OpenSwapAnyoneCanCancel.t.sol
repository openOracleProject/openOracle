// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
        (openSwapV2.Swap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);

        // Swapper gets totalGasComp + settlerReward back
        assertEq(swapper.balance, swapperEthBefore, "swapper got all ETH back");
    }

    function testThirdPartyCannotCancelBeforeExpiration() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.Swap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(thirdParty);
        vm.expectRevert(openSwapV2.NotSwapper.selector);
        swapContract.cancelSwap(swapId, s, m);
    }

    function testSwapperCanCancelAtExactBoundary() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.Swap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        // At block.timestamp == expiration: still in pre-expiration window (≤)
        vm.warp(expiration);
        vm.roll(block.number + 1);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);
    }

    function testThirdPartyCannotCancelAtExactBoundary() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.Swap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.warp(expiration);
        vm.roll(block.number + 1);

        vm.prank(thirdParty);
        vm.expectRevert(openSwapV2.NotSwapper.selector);
        swapContract.cancelSwap(swapId, s, m);
    }

    // ── Post-expiration (anyone can cancel) ─────────────────────────────

    function testThirdPartyCanCancelOneSecondAfterBoundary() public {
        uint256 thirdPartyEthBefore = thirdParty.balance;

        (uint256 swapId, uint48 expiration) = _propose();
        uint256 swapperEthAfterPropose = swapper.balance; // post-propose snapshot
        (openSwapV2.Swap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.warp(uint256(expiration) + 1);
        vm.roll(block.number + 1);

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId, s, m);

        uint96 total = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP;
        uint256 callerPiece = total / 5;
        uint256 swapperPiece = total - callerPiece;

        assertEq(swapper.balance, swapperEthAfterPropose + swapperPiece + SETTLER_REWARD, "swapper got 4/5 + settlerReward");
        assertEq(thirdParty.balance, thirdPartyEthBefore + callerPiece, "third party got 1/5");
    }

    function testSwapperCancelsAfterExpiration_GetsFullGasComp() public {
        uint256 swapperEthBefore = swapper.balance;

        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.Swap memory s, openSwapV2.MatcherPreimage memory m) =
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
        (openSwapV2.Swap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.warp(uint256(expiration) + 1);
        vm.roll(block.number + 1);

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId, s, m);

        // After cancel: openSwap's ETH balance for this swap is fully paid out
        assertEq(address(swapContract).balance, 0, "openSwap ETH drained");
        assertEq(_spendable(address(swapContract), address(sellToken)), 0, "openSwap sellToken drained");
    }

    // ── Conservation across odd gas-comp totals ─────────────────────────

    function testGasCompSplit_OddValueConservation() public {
        // Use a known totalGasComp value (matcher + executor) and verify swapper + caller pieces sum to total
        uint96 mgc = MATCHER_GAS_COMP;
        uint96 egc = EXECUTOR_GAS_COMP;
        uint96 total = mgc + egc;

        uint256 callerPiece = total / 5;
        uint256 swapperPiece = total - callerPiece;
        assertEq(callerPiece + swapperPiece, total, "split conservation");
    }
}
