// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";

/**
 * @notice Dutch reward discovery driven by real elapsed time between close() and report().
 *
 * @dev Every expected reward is a literal with its derivation in a comment. No test calls or
 *      reproduces calcFee() as the expected-value oracle. The reward is observed as the
 *      reporter's realised oracle-credit delta, and the externally funded remainder as the
 *      swapper's raw-wallet delta.
 */
contract DutchRewardDiscoveryTest is CloseBase {
    function setUp() public {
        _setUpClose();
    }

    /// @dev Opens a position, starts an auction with `input`, waits `secs`, then reports.
    ///      Returns the reward actually paid and the remainder actually returned.
    function _discover(OpenPuntStorage.CloseDutch memory input, uint256 secs)
        internal
        returns (uint256 reward, uint256 remainder)
    {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();

        // Give every curve the maximum allowed window, measured from the close() call itself,
        // so that reward discovery is never confounded by expiry. Expiry has its own tests.
        input.expiration = uint48(vm.getBlockTimestamp() + 1 hours);

        OpenPuntStorage.CloseDutch memory d = _startAuction(swapId, active, input, false, CLOSE_COMP);

        uint256 reporterCollat0 = _spendable(reporter, address(collat));
        uint256 swapperRaw0 = collat.balanceOf(swapper);

        if (secs > 0) _advanceTimeAndBlocks(secs, secs / 2);
        _reportWithDutch(swapId, d, active, p.preimage, reporter, 0);

        reward = _spendable(reporter, address(collat)) - reporterCollat0;
        remainder = collat.balanceOf(swapper) - swapperRaw0;

        assertEq(reward + remainder, input.maxReward, "reward plus remainder is always the full escrow");
        assertEq(_storedDutchState(swapId), bytes32(0), "claimed auctions are deleted");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Curve C1: 10e18, x1.5 per 60s round, ceiling 100e18, 10 rounds
    // ══════════════════════════════════════════════════════════════════
    //   r0 10e18
    //   r1 10e18   * 15000/10000 = 15e18
    //   r2 15e18   * 15000/10000 = 22.5e18
    //   r3 22.5e18 * 15000/10000 = 33.75e18
    //   r4 33.75e18* 15000/10000 = 50.625e18
    //   r5 50.625e18*15000/10000 = 75.9375e18
    //   r6 75.9375e18*15000/10000 = 113.90625e18 >= ceiling -> 100e18

    function test_immediateReportReceivesStartingReward() public {
        (uint256 reward, uint256 remainder) = _discover(_dutchInput(), 0);
        assertEq(reward, 10e18, "round 0 pays the starting reward");
        assertEq(remainder, 90e18, "the rest returns to the swapper");
    }

    function test_partialRoundStaysAtThePriorReward() public {
        (uint256 r59,) = _discover(_dutchInput(), 58);
        assertEq(r59, 10e18, "58s is still round 0");

        (uint256 r118,) = _discover(_dutchInput(), 118);
        assertEq(r118, 15e18, "118s is still round 1");
    }

    function test_exactRoundBoundariesAdvance() public {
        (uint256 r1,) = _discover(_dutchInput(), 60);
        assertEq(r1, 15e18, "round 1 at exactly 60s");

        (uint256 r2,) = _discover(_dutchInput(), 120);
        assertEq(r2, 22.5e18, "round 2 at exactly 120s");
    }

    function test_geometricSteps() public {
        (uint256 r3,) = _discover(_dutchInput(), 180);
        assertEq(r3, 33.75e18, "round 3");

        (uint256 r4,) = _discover(_dutchInput(), 240);
        assertEq(r4, 50.625e18, "round 4");

        (uint256 r5, uint256 rem5) = _discover(_dutchInput(), 300);
        assertEq(r5, 75.9375e18, "round 5");
        assertEq(rem5, 100e18 - 75.9375e18, "remainder shrinks to match");
    }

    function test_maxRewardCap() public {
        (uint256 r6, uint256 rem6) = _discover(_dutchInput(), 360);
        assertEq(r6, 100e18, "round 6 would exceed the ceiling, so it pays the ceiling");
        assertEq(rem6, 0, "nothing returns to the swapper at the cap");

        (uint256 r9,) = _discover(_dutchInput(), 540);
        assertEq(r9, 100e18, "still pinned at the ceiling later");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Curve C2: floor behaviour on odd wei amounts
    // ══════════════════════════════════════════════════════════════════
    //   start 3, x1.5, ceiling 1000
    //   r1 3*15000/10000  = 4  (4.5 floored)
    //   r2 4*15000/10000  = 6
    //   r3 6*15000/10000  = 9
    //   r4 9*15000/10000  = 13 (13.5 floored)
    //   r5 13*15000/10000 = 19 (19.5 floored)

    function _oddCurve() internal view returns (OpenPuntStorage.CloseDutch memory d) {
        d = _dutchInput();
        d.startingReward = 3;
        d.maxReward = 1000;
    }

    function test_floorBehaviourOnFractionalSteps() public {
        (uint256 r0,) = _discover(_oddCurve(), 0);
        assertEq(r0, 3, "round 0");

        (uint256 r1,) = _discover(_oddCurve(), 60);
        assertEq(r1, 4, "4.5 floors to 4");

        (uint256 r2,) = _discover(_oddCurve(), 120);
        assertEq(r2, 6, "round 2");

        (uint256 r4,) = _discover(_oddCurve(), 240);
        assertEq(r4, 13, "13.5 floors to 13");

        (uint256 r5, uint256 rem5) = _discover(_oddCurve(), 300);
        assertEq(r5, 19, "19.5 floors to 19");
        assertEq(rem5, 1000 - 19, "remainder is the exact complement");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Curve C3: maxRounds reached before maxReward
    // ══════════════════════════════════════════════════════════════════
    //   start 10e18, x1.1, maxRounds 3, ceiling 1000e18
    //   r1 11e18   r2 12.1e18   r3 13.31e18   -> frozen at r3

    function _shortCurve() internal view returns (OpenPuntStorage.CloseDutch memory d) {
        d = _dutchInput();
        d.growthRate = 11_000;
        d.maxRounds = 3;
        d.maxReward = 1000e18;
    }

    function test_maxRoundsCapReachedBeforeMaxReward() public {
        (uint256 r3,) = _discover(_shortCurve(), 180);
        assertEq(r3, 13.31e18, "round 3 value");

        (uint256 r10,) = _discover(_shortCurve(), 600);
        assertEq(r10, 13.31e18, "frozen at maxRounds, far below the ceiling");

        (uint256 r30, uint256 rem30) = _discover(_shortCurve(), 1800);
        assertEq(r30, 13.31e18, "still frozen much later");
        assertEq(rem30, 1000e18 - 13.31e18, "the untouched remainder returns to the swapper");
    }
}
