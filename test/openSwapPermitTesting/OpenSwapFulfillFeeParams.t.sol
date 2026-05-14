// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";

contract OpenSwapFulfillFeeParamsTest is SlimTestBase {
    openSwapV2.FulfillFeeParams internal _fees;

    function setUp() public {
        _setUpAll();
        // Default loose fee schedule
        _fees = openSwapV2.FulfillFeeParams({
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
    }

    function _defaultFulfillFee() internal view override returns (openSwapV2.FulfillFeeParams memory) {
        return _fees;
    }

    function _setFees(uint24 maxFee, uint24 startingFee, uint24 roundLength, uint16 growthRate, uint16 maxRounds)
        internal
    {
        _fees = openSwapV2.FulfillFeeParams({
            maxFee: maxFee,
            startingFee: startingFee,
            roundLength: roundLength,
            growthRate: growthRate,
            maxRounds: maxRounds
        });
    }

    // ── Validation reverts ─────────────────────────────────────────────

    function testValidation_MaxFeeZero_Reverts() public {
        _setFees(0, STARTING_FEE, ROUND_LENGTH, GROWTH_RATE, MAX_ROUNDS);
        vm.expectRevert();
        _propose();
    }

    function testValidation_StartingFeeZero_Reverts() public {
        _setFees(MAX_FEE, 0, ROUND_LENGTH, GROWTH_RATE, MAX_ROUNDS);
        vm.expectRevert();
        _propose();
    }

    function testValidation_GrowthRateBelow10000_Reverts() public {
        _setFees(MAX_FEE, STARTING_FEE, ROUND_LENGTH, 9999, MAX_ROUNDS);
        vm.expectRevert();
        _propose();
    }

    function testValidation_MaxRoundsZero_Reverts() public {
        _setFees(MAX_FEE, STARTING_FEE, ROUND_LENGTH, GROWTH_RATE, 0);
        vm.expectRevert();
        _propose();
    }

    function testValidation_MaxRoundsAbove100_Reverts() public {
        _setFees(MAX_FEE, STARTING_FEE, ROUND_LENGTH, GROWTH_RATE, 101);
        vm.expectRevert();
        _propose();
    }

    function testValidation_RoundLengthZero_Reverts() public {
        _setFees(MAX_FEE, STARTING_FEE, 0, GROWTH_RATE, MAX_ROUNDS);
        vm.expectRevert();
        _propose();
    }

    function testValidation_MaxFeeLessThanStartingFee_Reverts() public {
        _setFees(5000, STARTING_FEE, ROUND_LENGTH, GROWTH_RATE, MAX_ROUNDS);
        vm.expectRevert();
        _propose();
    }

    function testValidation_MaxFeeAt1e7_Reverts() public {
        _setFees(uint24(1e7), STARTING_FEE, ROUND_LENGTH, GROWTH_RATE, MAX_ROUNDS);
        vm.expectRevert(); // propose validates `maxFee >= 1e7` reverts on first check
        _propose();
    }

    function testValidation_MaxRoundsAt100_Succeeds() public {
        _setFees(MAX_FEE, STARTING_FEE, ROUND_LENGTH, GROWTH_RATE, 100);
        (uint256 swapId,) = _propose();
        assertGt(swapId, 0, "propose succeeded with maxRounds=100");
    }

    // ── Fee escalation behavior ─────────────────────────────────────────

    function testFulfillFee_ImmediateMatchUsesStartingFee() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        assertEq(sPost.fulfillmentFee, STARTING_FEE, "immediate match uses startingFee");
    }

    function testFulfillFee_AfterOneRound_Increases() public {
        (uint256 swapId, uint48 expiration) = _propose();
        // Warp 1 round forward
        vm.warp(block.timestamp + ROUND_LENGTH);
        vm.roll(block.number + 1);
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        // startingFee * growthRate / 10000 = 10000 * 15000 / 10000 = 15000
        uint24 expected = uint24((uint256(STARTING_FEE) * GROWTH_RATE) / 10000);
        if (expected >= MAX_FEE) expected = MAX_FEE;
        assertEq(sPost.fulfillmentFee, expected, "one round elapsed fee");
    }

    function testFulfillFee_CappedAtMaxFee() public {
        // Use a low maxFee so we hit the cap quickly
        _setFees(15000, 10000, ROUND_LENGTH, 15000, 10);
        (uint256 swapId, uint48 expiration) = _propose();
        // Warp many rounds (more than enough to exceed maxFee)
        vm.warp(block.timestamp + ROUND_LENGTH * 5);
        vm.roll(block.number + 5);
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        assertEq(sPost.fulfillmentFee, 15000, "capped at maxFee");
    }

    function testFulfillFee_CappedAtMaxRounds() public {
        _setFees(MAX_FEE, STARTING_FEE, ROUND_LENGTH, GROWTH_RATE, 3);
        (uint256 swapId, uint48 expiration) = _propose();
        // Warp past maxRounds but inside expiration (1 hour)
        vm.warp(block.timestamp + ROUND_LENGTH * 10);
        vm.roll(block.number + 10);
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        // Should be startingFee compounded only 3 times, then capped (or at maxFee, whichever lower)
        uint256 fee = STARTING_FEE;
        for (uint i = 0; i < 3; i++) {
            fee = (fee * GROWTH_RATE) / 10000;
            if (fee >= MAX_FEE) {
                fee = MAX_FEE;
                break;
            }
        }
        assertEq(sPost.fulfillmentFee, fee, "capped at maxRounds compounding");
    }

    function testFulfillFee_PartialRoundNotCounted() public {
        (uint256 swapId, uint48 expiration) = _propose();
        // Warp less than one round
        vm.warp(block.timestamp + ROUND_LENGTH - 1);
        vm.roll(block.number + 1);
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        assertEq(sPost.fulfillmentFee, STARTING_FEE, "partial round still uses startingFee");
    }
}
