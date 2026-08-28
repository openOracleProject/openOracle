// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice Both auction modes, driven by real elapsed time between propose() and matchSwap().
 *
 * @dev Every expected value below is written out as a literal and derived by hand in the
 *      accompanying comment. No test calls a copy of `calcFee()` or `calcLinearRate()`.
 *      Each case is an independent real proposal whose auction clock starts at its own
 *      propose timestamp, so the elapsed rounds are exactly the warp applied afterwards.
 */
contract AuctionDiscoveryTest is OpenPuntBase {
    uint24 internal constant ROUND = 60;

    function setUp() public {
        _setUpAll();
        collat.mint(swapper, 1_000_000e18);
        _mintAndDeposit(collat, matcher, 1_000_000e18);
        _mintAndDeposit(tokenA, matcher, 10_000e18);
        _mintAndDeposit(tokenB, matcher, 10_000_000e18);
        vm.deal(swapper, 100 ether);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Fulfillment-fee auction (auctionFunding == false)
    // ══════════════════════════════════════════════════════════════════

    /// @dev Geometric ladder: start 10_000, x1.5 per round, ceiling 100_000.
    ///      r0 10000
    ///      r1 10000*15000/10000                     = 15000
    ///      r2 15000*15000/10000                     = 22500
    ///      r3 22500*15000/10000                     = 33750
    ///      r4 33750*15000/10000                     = 50625
    ///      r5 50625*15000/10000 = 75937.5 -> floor  = 75937
    ///      r6 75937*15000/10000 = 113905 >= ceiling -> 100000
    function _feeLadderSwap() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap();
        s.auctionFunding = false;
        s.fulfillmentFee = 0; // discovered
        s.fundingRate = 0;
    }

    function _feeLadderPreimage() internal view returns (OpenPuntStorage.MatcherPreimage memory m) {
        m = _defaultMatcherPreimage();
        m.auctionStart = 10_000;
        m.auctionEnd = 100_000; // fee ceiling: 10_000e18 * 100_000 / 1e7 = 100e18 < 800e18 buffer
        m.growthRate = 15_000;
        m.maxRounds = 10;
        m.roundLength = ROUND;
    }

    function _discoverFee(OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m, uint256 secs)
        internal
        returns (OpenPuntStorage.MatchedSwap memory matched)
    {
        Proposal memory p = _proposeWith(s, m, swapper);
        if (secs > 0) _advanceChain(secs);
        Matched memory mt = _matchSwap(p);
        matched = mt.swap;
    }

    function test_feeAuction_immediateMatchUsesAuctionStart() public {
        OpenPuntStorage.MatchedSwap memory s = _discoverFee(_feeLadderSwap(), _feeLadderPreimage(), 0);
        assertEq(s.fulfillmentFee, 10_000, "r0 == auctionStart");
    }

    function test_feeAuction_partialRoundDoesNotAdvance() public {
        OpenPuntStorage.MatchedSwap memory a = _discoverFee(_feeLadderSwap(), _feeLadderPreimage(), 58);
        assertEq(a.fulfillmentFee, 10_000, "58s is still round 0");

        // 60s is the first full round; 118s is still round 1
        OpenPuntStorage.MatchedSwap memory b = _discoverFee(_feeLadderSwap(), _feeLadderPreimage(), 60);
        assertEq(b.fulfillmentFee, 15_000, "60s is round 1");

        OpenPuntStorage.MatchedSwap memory c = _discoverFee(_feeLadderSwap(), _feeLadderPreimage(), 118);
        assertEq(c.fulfillmentFee, 15_000, "118s is still round 1");
    }

    function test_feeAuction_geometricLadderAndCeilingCap() public {
        uint24[7] memory expected = [
            uint24(10_000),
            uint24(15_000),
            uint24(22_500),
            uint24(33_750),
            uint24(50_625),
            uint24(75_937),
            uint24(100_000)
        ];

        for (uint256 round = 0; round < expected.length; round++) {
            OpenPuntStorage.MatchedSwap memory s = _discoverFee(_feeLadderSwap(), _feeLadderPreimage(), round * ROUND);
            assertEq(s.fulfillmentFee, expected[round], "geometric ladder step");
        }

        // beyond the ceiling round it stays pinned at auctionEnd
        OpenPuntStorage.MatchedSwap memory late = _discoverFee(_feeLadderSwap(), _feeLadderPreimage(), 9 * ROUND);
        assertEq(late.fulfillmentFee, 100_000, "pinned at auctionEnd");
    }

    /// @dev Separate ladder that hits maxRounds before the ceiling.
    ///      start 10_000, x1.1 per round, maxRounds 3, ceiling 100_000.
    ///      r1 10000*11000/10000 = 11000
    ///      r2 11000*11000/10000 = 12100
    ///      r3 12100*11000/10000 = 13310   <- capped here, never reaches 100000
    function test_feeAuction_maxRoundsCap() public {
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();
        m.auctionStart = 10_000;
        m.auctionEnd = 100_000;
        m.growthRate = 11_000;
        m.maxRounds = 3;
        m.roundLength = ROUND;

        assertEq(_discoverFee(_feeLadderSwap(), m, 3 * ROUND).fulfillmentFee, 13_310, "round 3 value");
        assertEq(_discoverFee(_feeLadderSwap(), m, 10 * ROUND).fulfillmentFee, 13_310, "capped at maxRounds");
        assertEq(_discoverFee(_feeLadderSwap(), m, 50 * ROUND).fulfillmentFee, 13_310, "still capped much later");
    }

    function test_feeAuction_fixedFundingRateSurvives() public {
        int32[3] memory rates = [int32(-800_000), int32(0), int32(800_000)];

        for (uint256 i = 0; i < rates.length; i++) {
            OpenPuntStorage.ProposedSwap memory s = _feeLadderSwap();
            s.fundingRate = rates[i];
            OpenPuntStorage.MatchedSwap memory matched = _discoverFee(s, _feeLadderPreimage(), 2 * ROUND);

            assertEq(matched.fundingRate, rates[i], "fixed funding rate carried verbatim");
            assertEq(matched.fulfillmentFee, 22_500, "fee still discovered at round 2");
        }
    }

    // ── fee-auction validation ──────────────────────────────────────────

    function test_feeAuction_validation() public {
        OpenPuntStorage.MatcherPreimage memory m = _feeLadderPreimage();
        m.auctionStart = 0;
        _proposeBad(_feeLadderSwap(), m, PuntErrors.InvalidFulfillFee.selector, "auctionStart 0");

        m = _feeLadderPreimage();
        m.auctionStart = -1;
        _proposeBad(_feeLadderSwap(), m, PuntErrors.InvalidFulfillFee.selector, "auctionStart negative");

        m = _feeLadderPreimage();
        m.auctionStart = 1;
        _proposeOk(_feeLadderSwap(), m, "auctionStart 1");

        m = _feeLadderPreimage();
        m.auctionEnd = m.auctionStart - 1;
        _proposeBad(_feeLadderSwap(), m, PuntErrors.InvalidFulfillFee.selector, "auctionEnd below auctionStart");

        m = _feeLadderPreimage();
        m.auctionEnd = m.auctionStart; // equality is allowed
        _proposeOk(_feeLadderSwap(), m, "auctionEnd == auctionStart");

        m = _feeLadderPreimage();
        m.growthRate = 9_999;
        _proposeBad(_feeLadderSwap(), m, PuntErrors.InvalidFulfillFee.selector, "growthRate 9999");

        m = _feeLadderPreimage();
        m.growthRate = 10_000;
        _proposeOk(_feeLadderSwap(), m, "growthRate 10000");
    }

    /// @dev auctionEnd must stay strictly below 1e7. At 1e7-1 the fee ceiling is almost the
    ///      whole notional, so the notional is shrunk to keep it under the buffer.
    function test_feeAuction_auctionEndCeiling() public {
        OpenPuntStorage.ProposedSwap memory s = _feeLadderSwap();
        s.notional = 1e7; // fee ceiling == auctionEnd in absolute units
        s.initialMarginSwapper = 20_000_000;
        s.maintenanceMarginSwapper = 0; // buffer 20_000_000
        s.initialMarginMatcher = 1;

        OpenPuntStorage.MatcherPreimage memory m = _feeLadderPreimage();
        m.auctionStart = 1;
        m.auctionEnd = 1e7 - 1;
        _proposeOk(s, m, "auctionEnd 1e7 - 1");

        m.auctionEnd = 1e7;
        _proposeBad(s, m, PuntErrors.InvalidFulfillFee.selector, "auctionEnd 1e7");
    }

    /// @dev The maximum opening fee must leave swapper margin strictly above maintenance.
    function test_feeAuction_openingBufferBoundaryIsStrict() public {
        OpenPuntStorage.MatcherPreimage memory m = _feeLadderPreimage();
        m.auctionStart = 1000;
        m.auctionEnd = 1000; // ceiling: 1e7 * 1000 / 1e7 = 1000 exactly
        m.growthRate = 10_000;

        OpenPuntStorage.ProposedSwap memory ok = _feeLadderSwap();
        ok.notional = 1e7;
        ok.initialMarginMatcher = 1;
        ok.initialMarginSwapper = 2001;
        ok.maintenanceMarginSwapper = 1000; // buffer 1001 > the 1000-unit opening fee
        _proposeOk(ok, m, "buffer one unit above the opening fee");

        OpenPuntStorage.ProposedSwap memory bad = _feeLadderSwap();
        bad.notional = 1e7;
        bad.initialMarginMatcher = 1;
        bad.initialMarginSwapper = 2000;
        bad.maintenanceMarginSwapper = 1000; // buffer 1000 == the 1000-unit opening fee
        _proposeBad(bad, m, PuntErrors.InvalidFulfillFee.selector, "buffer equal to the opening fee");
    }

    function test_feeAuction_fixedFundingRateBounds() public {
        OpenPuntStorage.ProposedSwap memory s = _feeLadderSwap();
        s.fundingRate = -100_000_000;
        _proposeOk(s, _feeLadderPreimage(), "funding rate at -1e8");

        s = _feeLadderSwap();
        s.fundingRate = 100_000_000;
        _proposeOk(s, _feeLadderPreimage(), "funding rate at +1e8");

        s = _feeLadderSwap();
        s.fundingRate = -100_000_001;
        _proposeBad(s, _feeLadderPreimage(), PuntErrors.InvalidFundingRate.selector, "funding rate below -1e8");

        s = _feeLadderSwap();
        s.fundingRate = 100_000_001;
        _proposeBad(s, _feeLadderPreimage(), PuntErrors.InvalidFundingRate.selector, "funding rate above +1e8");
    }

    function test_feeAuction_fixedFulfillmentFeeMustBeZero() public {
        OpenPuntStorage.ProposedSwap memory s = _feeLadderSwap();
        s.fulfillmentFee = 1;
        _proposeBad(s, _feeLadderPreimage(), PuntErrors.MustBeZero.selector, "fulfillmentFee must be discovered");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Funding-rate auction (auctionFunding == true)
    // ══════════════════════════════════════════════════════════════════

    /// @dev Signed linear ramp from -8% to +8% over 8 rounds.
    ///      distance = 800_000 - (-800_000) = 1_600_000; step = distance/maxRounds = 200_000
    ///      r0 -800_000   r1 -600_000   r2 -400_000   r3 -200_000   r4 0
    ///      r5 +200_000   r6 +400_000   r7 +600_000   r8 +800_000 (terminal early-return)
    function _fundingSwap() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap();
        s.auctionFunding = true;
        s.fundingRate = 0; // discovered
        s.fulfillmentFee = 10_000; // fixed: 10_000e18 * 10_000 / 1e7 = 10e18 < 800e18 buffer
    }

    function _fundingPreimage() internal view returns (OpenPuntStorage.MatcherPreimage memory m) {
        m = _defaultMatcherPreimage();
        m.auctionStart = -800_000;
        m.auctionEnd = 800_000;
        m.maxRounds = 8;
        m.roundLength = ROUND;
    }

    function _discoverFunding(uint256 secs) internal returns (OpenPuntStorage.MatchedSwap memory) {
        return _discoverFee(_fundingSwap(), _fundingPreimage(), secs);
    }

    function test_fundingAuction_immediateMatchReturnsNegativeStart() public {
        assertEq(_discoverFunding(0).fundingRate, -800_000, "r0 == auctionStart");
    }

    function test_fundingAuction_partialRoundDoesNotAdvance() public {
        assertEq(_discoverFunding(58).fundingRate, -800_000, "58s is still round 0");
        assertEq(_discoverFunding(118).fundingRate, -600_000, "118s is still round 1");
    }

    function test_fundingAuction_linearRampIncludingZeroCrossing() public {
        int32[9] memory expected = [
            int32(-800_000),
            int32(-600_000),
            int32(-400_000),
            int32(-200_000),
            int32(0),
            int32(200_000),
            int32(400_000),
            int32(600_000),
            int32(800_000)
        ];

        for (uint256 round = 0; round < expected.length; round++) {
            assertEq(_discoverFunding(round * ROUND).fundingRate, expected[round], "linear ramp step");
        }
    }

    function test_fundingAuction_cappedBeyondMaxRounds() public {
        assertEq(_discoverFunding(8 * ROUND).fundingRate, 800_000, "terminal round");
        assertEq(_discoverFunding(20 * ROUND).fundingRate, 800_000, "capped well beyond maxRounds");
        assertEq(_discoverFunding(50 * ROUND).fundingRate, 800_000, "still capped");
    }

    function test_fundingAuction_fixedFulfillmentFeeSurvives() public {
        OpenPuntStorage.MatchedSwap memory matched = _discoverFunding(3 * ROUND);
        assertEq(matched.fulfillmentFee, 10_000, "fixed fulfillment fee carried verbatim");
        assertEq(matched.fundingRate, -200_000, "funding still discovered at round 3");
    }

    // ── funding-auction validation ──────────────────────────────────────

    function test_fundingAuction_rateBounds() public {
        OpenPuntStorage.MatcherPreimage memory m = _fundingPreimage();
        m.auctionStart = -100_000_000;
        m.auctionEnd = 100_000_000;
        _proposeOk(_fundingSwap(), m, "start -1e8 / end +1e8");

        m = _fundingPreimage();
        m.auctionStart = -100_000_001;
        _proposeBad(_fundingSwap(), m, PuntErrors.InvalidFundingRate.selector, "start below -1e8");

        m = _fundingPreimage();
        m.auctionEnd = 100_000_001;
        _proposeBad(_fundingSwap(), m, PuntErrors.InvalidFundingRate.selector, "end above +1e8");
    }

    function test_fundingAuction_startMustBeBelowEnd() public {
        OpenPuntStorage.MatcherPreimage memory m = _fundingPreimage();
        m.auctionStart = 100;
        m.auctionEnd = 100;
        _proposeBad(_fundingSwap(), m, PuntErrors.InvalidFundingRate.selector, "start == end");

        m = _fundingPreimage();
        m.auctionStart = 200;
        m.auctionEnd = 100;
        _proposeBad(_fundingSwap(), m, PuntErrors.InvalidFundingRate.selector, "start > end");

        m = _fundingPreimage();
        m.auctionStart = 99;
        m.auctionEnd = 100;
        _proposeOk(_fundingSwap(), m, "start one below end");
    }

    function test_fundingAuction_fixedFeeBounds() public {
        OpenPuntStorage.ProposedSwap memory s = _fundingSwap();
        s.fulfillmentFee = 1e7;
        _proposeBad(s, _fundingPreimage(), PuntErrors.InvalidFulfillFee.selector, "fixed fee 1e7");

        // 1e7 - 1 clears the range check but must still fit under the buffer
        s = _fundingSwap();
        s.notional = 1e7;
        s.initialMarginSwapper = 20_000_000;
        s.maintenanceMarginSwapper = 0;
        s.initialMarginMatcher = 1;
        s.fulfillmentFee = 1e7 - 1;
        _proposeOk(s, _fundingPreimage(), "fixed fee 1e7 - 1 under a large buffer");
    }

    /// @dev Same one-fee boundary as the fee auction, applied to the fixed opening fee.
    function test_fundingAuction_openingBufferBoundaryIsStrict() public {
        OpenPuntStorage.ProposedSwap memory ok = _fundingSwap();
        ok.notional = 1e7;
        ok.fulfillmentFee = 1000; // fee amount: 1e7 * 1000 / 1e7 = 1000 exactly
        ok.initialMarginMatcher = 1;
        ok.initialMarginSwapper = 2001;
        ok.maintenanceMarginSwapper = 1000; // buffer 1001 > the 1000-unit opening fee
        _proposeOk(ok, _fundingPreimage(), "buffer one unit above the opening fee");

        OpenPuntStorage.ProposedSwap memory bad = _fundingSwap();
        bad.notional = 1e7;
        bad.fulfillmentFee = 1000;
        bad.initialMarginMatcher = 1;
        bad.initialMarginSwapper = 2000;
        bad.maintenanceMarginSwapper = 1000; // buffer 1000 == the 1000-unit opening fee
        _proposeBad(bad, _fundingPreimage(), PuntErrors.InvalidFulfillFee.selector, "buffer equal to the opening fee");
    }

    function test_fundingAuction_fixedFundingRateMustBeZero() public {
        OpenPuntStorage.ProposedSwap memory s = _fundingSwap();
        s.fundingRate = 1;
        _proposeBad(s, _fundingPreimage(), PuntErrors.MustBeZero.selector, "fundingRate must be discovered");
    }
}
