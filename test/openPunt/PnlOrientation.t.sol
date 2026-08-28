// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ActivePositionBase.t.sol";

/// @notice Pins the two selectable reciprocal PnL orientations against independently calculated payouts.
contract PnlOrientationTest is ActivePositionBase {
    uint128 internal constant A2_UP_FIFTY_PERCENT = 15_000e18;
    uint128 internal constant LARGE_SWAPPER_MARGIN = 10_000e18;
    uint128 internal constant LARGE_MATCHER_MARGIN = 10_000e18;

    function setUp() public {
        _setUpAccounting();
    }

    function _orientationConfig(bool token1PerToken2, bool profitsOnRatioIncrease)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _cfgZeroFee(0);
        s.initialMarginSwapper = LARGE_SWAPPER_MARGIN;
        s.initialMarginMatcher = LARGE_MATCHER_MARGIN;
        s.maintenanceMarginSwapper = 1;
        s.maturityWindow = MATURITY_SHORT;
        s.isLong = profitsOnRatioIncrease;
        s.pnlUsesToken1PerToken2 = token1PerToken2;
    }

    function _terminalPayout(OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
        internal
        returns (OpenPuntStorage.MatchedSwap memory active, uint256 owedSwapper, uint256 owedMatcher)
    {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory opened, Proposal memory p) = _openAccounting(s, m);
        active = opened;
        (Vm.Log[] memory logs,) = _reportAndExecute(swapId, opened, p.preimage, A2_UP_FIFTY_PERCENT, ELAPSED_STD);
        (owedSwapper, owedMatcher) = _readPositionClosed(logs, swapId);
    }

    function test_token2PerToken1PreservesTheConvexCollateralPayoff() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _orientationConfig(false, true);

        (OpenPuntStorage.MatchedSwap memory active, uint256 owedS, uint256 owedM) = _terminalPayout(s, m);

        assertFalse(active.pnlUsesToken1PerToken2, "matched position preserves the selected ratio");
        assertEq(owedS, 15_000e18, "10,000 notional earns 5,000 when token2/token1 rises 50%");
        assertEq(owedM, 5_000e18, "matcher pays exactly the convex gain");
    }

    function test_token1PerToken2ProducesTheStandardInversePayoff() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _orientationConfig(true, false);

        (OpenPuntStorage.MatchedSwap memory active, uint256 owedS, uint256 owedM) = _terminalPayout(s, m);

        uint256 inverseGain = uint256(NOTIONAL_ACC) * 5_000e18 / 15_000e18;
        assertTrue(active.pnlUsesToken1PerToken2, "matched position preserves the selected ratio");
        assertEq(owedS, uint256(LARGE_SWAPPER_MARGIN) + inverseGain, "inverse gain uses the closing-price denominator");
        assertEq(owedM, uint256(LARGE_MATCHER_MARGIN) - inverseGain, "matcher pays exactly the inverse gain");
    }

    function test_token1PerToken2DirectionIsIndependentFromOrientation() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _orientationConfig(true, true);

        (, uint256 owedS, uint256 owedM) = _terminalPayout(s, m);

        uint256 inverseLoss = uint256(NOTIONAL_ACC) * 5_000e18 / 15_000e18;
        assertEq(
            owedS, uint256(LARGE_SWAPPER_MARGIN) - inverseLoss, "ratio-increase direction loses when the ratio falls"
        );
        assertEq(owedM, uint256(LARGE_MATCHER_MARGIN) + inverseLoss, "matcher receives the reciprocal loss");
    }
}
