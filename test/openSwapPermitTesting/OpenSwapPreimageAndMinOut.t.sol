// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";

/// @notice MatcherPreimage tampering tests + minOut validation at propose.
contract OpenSwapPreimageAndMinOutTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    function _tryMatchWithTamperedPreimage(
        function(openSwapV2.MatcherPreimage memory) internal pure returns (openSwapV2.MatcherPreimage memory) tamperFn
    ) internal {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        m = tamperFn(m);
        vm.prank(matcher);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }

    function _tamperInitialLiquidity(openSwapV2.MatcherPreimage memory m)
        internal pure returns (openSwapV2.MatcherPreimage memory)
    { m.initialLiquidity = m.initialLiquidity + 1; return m; }

    function _tamperProtocolFee(openSwapV2.MatcherPreimage memory m)
        internal pure returns (openSwapV2.MatcherPreimage memory)
    { m.protocolFee = m.protocolFee + 1; return m; }

    function _tamperStartFulfillFeeIncrease(openSwapV2.MatcherPreimage memory m)
        internal pure returns (openSwapV2.MatcherPreimage memory)
    { m.startFulfillFeeIncrease = m.startFulfillFeeIncrease + 1; return m; }

    function _tamperMaxFee(openSwapV2.MatcherPreimage memory m)
        internal pure returns (openSwapV2.MatcherPreimage memory)
    { m.maxFee = m.maxFee + 1; return m; }

    function _tamperMultiplier(openSwapV2.MatcherPreimage memory m)
        internal pure returns (openSwapV2.MatcherPreimage memory)
    { m.multiplier = m.multiplier + 1; return m; }

    function _tamperEscalationHalt(openSwapV2.MatcherPreimage memory m)
        internal pure returns (openSwapV2.MatcherPreimage memory)
    { m.escalationHalt = m.escalationHalt + 1; return m; }

    // ── MatcherPreimage tampering ──────────────────────────────────────

    function testPreimage_WrongInitialLiquidity_Reverts() public {
        _tryMatchWithTamperedPreimage(_tamperInitialLiquidity);
    }
    function testPreimage_WrongProtocolFee_Reverts() public {
        _tryMatchWithTamperedPreimage(_tamperProtocolFee);
    }
    function testPreimage_WrongStartFulfillFeeIncrease_Reverts() public {
        _tryMatchWithTamperedPreimage(_tamperStartFulfillFeeIncrease);
    }
    function testPreimage_WrongMaxFee_Reverts() public {
        _tryMatchWithTamperedPreimage(_tamperMaxFee);
    }
    function testPreimage_WrongMultiplier_Reverts() public {
        _tryMatchWithTamperedPreimage(_tamperMultiplier);
    }
    function testPreimage_WrongEscalationHalt_Reverts() public {
        _tryMatchWithTamperedPreimage(_tamperEscalationHalt);
    }

    function testPreimage_Correct_Succeeds() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        assertTrue(sPost.matcher != address(0), "match succeeded with correct preimage");
    }

    function testPreimage_AfterWarp_MustUseProposeTime() public {
        // proposeTs is captured at _propose; tampering it (e.g. using current block.timestamp) fails
        (uint256 swapId, uint48 expiration) = _propose();
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 1);

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        m.startFulfillFeeIncrease = uint48(block.timestamp); // wrong — should be the propose timestamp

        vm.prank(matcher);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }

    // ── minOut validation at propose ────────────────────────────────────

    function _proposeWithMinOut(uint128 minOut) internal returns (uint256) {
        proposeTs = uint48(block.timestamp);
        vm.prank(swapper);
        return SwapCompat.proposeRaw(swapContract, MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD, 
            SELL_AMT, address(sellToken), minOut, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            _defaultOracleParams(), _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), false
        );
    }

    function testMinOutValidation_ExceedsWorstCase_Reverts() public {
        // minOut larger than worstFulfillAmt
        vm.expectRevert(Errors.MinOutInconsistent.selector);
        _proposeWithMinOut(type(uint128).max);
    }

    function testMinOutValidation_TinyValue_Succeeds() public {
        uint256 swapId = _proposeWithMinOut(1);
        assertGt(swapId, 0, "tiny minOut OK");
    }

    function testMinOutValidation_ZeroReverts() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        _proposeWithMinOut(0);
    }
}
