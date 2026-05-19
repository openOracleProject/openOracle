// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";

/// @notice openSwap's `tempHolding` is the credit/withdraw store for ETH gas comps.
contract OpenSwapTempHoldingTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    function _matchToProduceMatcherCredit() internal returns (uint256 swapId, openSwapV2.MatchedSwap memory sPost) {
        uint48 expiration;
        (swapId, expiration) = _propose();
        (, , sPost) = _match(swapId, 2000e18, expiration);
    }

    // ── Credits ─────────────────────────────────────────────────────────

    function testTempHolding_MatcherCreditedOnMatch() public {
        _matchToProduceMatcherCredit();
        assertEq(swapContract.tempHolding(matcher), MATCHER_GAS_COMP, "matcher credited");
    }

    function testTempHolding_ExecutorCreditedOnBailout() public {
        (uint256 swapId, openSwapV2.MatchedSwap memory sPost) = _matchToProduceMatcherCredit();
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        address bailer = address(0x9001);
        vm.prank(bailer);
        swapContract.bailOut(swapId, sPost);
        assertEq(swapContract.tempHolding(bailer), EXECUTOR_GAS_COMP, "bailer credited");
    }

    function testTempHolding_MultipleSwapsAccumulate() public {
        _matchToProduceMatcherCredit();
        uint256 first = swapContract.tempHolding(matcher);
        _matchToProduceMatcherCredit();
        uint256 second = swapContract.tempHolding(matcher);
        assertEq(second, first + MATCHER_GAS_COMP, "second credit accumulates");
    }

    // ── Withdraw ────────────────────────────────────────────────────────

    function testWithdraw_SelfWithdrawZeroesBalance() public {
        _matchToProduceMatcherCredit();
        uint256 matcherEthBefore = matcher.balance;

        vm.prank(matcher);
        swapContract.withdraw(matcher, false);

        assertEq(matcher.balance, matcherEthBefore + MATCHER_GAS_COMP, "matcher got ETH externally");
        assertEq(swapContract.tempHolding(matcher), 0, "tempHolding cleared");
    }

    function testWithdraw_LeaveOneKeepsSentinel() public {
        _matchToProduceMatcherCredit();

        vm.prank(matcher);
        swapContract.withdraw(matcher, true);

        // leaveOne=true preserves a 1-wei sentinel
        assertEq(swapContract.tempHolding(matcher), 1, "sentinel preserved");
    }

    function testWithdraw_ThirdPartyCannotDrainToZero() public {
        // Anti-grief: third-party can withdraw on behalf of matcher but can't strip the sentinel.
        _matchToProduceMatcherCredit();
        uint256 matcherEthBefore = matcher.balance;

        // Random caller withdraws for matcher. keepSentinel becomes true regardless of leaveOne flag.
        vm.prank(address(0xCAFE));
        swapContract.withdraw(matcher, false);

        // Matcher received funds minus the 1-wei sentinel
        assertEq(matcher.balance, matcherEthBefore + MATCHER_GAS_COMP - 1, "matcher got -1 wei");
        assertEq(swapContract.tempHolding(matcher), 1, "sentinel preserved by third-party caller");
    }

    function testWithdraw_RevertsOnZero() public {
        // No credit exists
        vm.prank(matcher);
        vm.expectRevert(Errors.NothingToWithdraw.selector);
        swapContract.withdraw(matcher, false);
    }

    function testWithdraw_RevertsOnSentinelOnly() public {
        // First withdraw with leaveOne leaves the 1 sentinel
        _matchToProduceMatcherCredit();
        vm.prank(matcher);
        swapContract.withdraw(matcher, true);

        // Second attempt with leaveOne=true reverts (only the sentinel remains)
        vm.prank(matcher);
        vm.expectRevert(Errors.NothingToWithdraw.selector);
        swapContract.withdraw(matcher, true);
    }

    function testWithdraw_AnyoneCanCallToPushToRecipient() public {
        _matchToProduceMatcherCredit();
        uint256 matcherEthBefore = matcher.balance;

        // Third party pushes matcher's funds to matcher
        vm.prank(address(0xBEEF));
        swapContract.withdraw(matcher, false);

        // Matcher receives funds (minus sentinel since caller != _to)
        assertGt(matcher.balance, matcherEthBefore, "matcher received funds");
    }
}
