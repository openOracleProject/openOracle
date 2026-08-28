// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";

/**
 * @notice close() validation on an idle active position (reportId == 0), plus an explicit
 *         coverage of which caller-supplied Dutch fields are required to be zero and
 *         which are silently overwritten.
 */
contract CloseValidationTest is CloseBase {
    function setUp() public {
        _setUpClose();
    }

    // ── harness ─────────────────────────────────────────────────────────

    function _reject(
        uint256 swapId,
        OpenPuntStorage.CloseDutch memory d,
        OpenPuntStorage.MatchedSwap memory active,
        address who,
        uint128 comp,
        bytes4 err,
        string memory what
    ) internal {
        Snap memory before = _snap(swapId, active.collatToken);
        uint256 value = _closeValue(d, active.collatToken, false, comp);

        vm.prank(who);
        vm.expectRevert(err);
        punt.close{value: value}(
            swapId, d, active, false, _emptyPermit2(), comp, _emptyOracleGame(), _emptyOracleHelper()
        );

        _assertUnchanged(before, swapId, active.collatToken, what);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Authorisation and phase
    // ══════════════════════════════════════════════════════════════════

    function test_onlySwapperMayClose() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();

        _reject(swapId, _dutchInput(), active, outsider, CLOSE_COMP, PuntErrors.NotSwapper.selector, "outsider");
        _reject(swapId, _dutchInput(), active, matcher, CLOSE_COMP, PuntErrors.NotSwapper.selector, "matcher");
        _reject(swapId, _dutchInput(), active, reporter, CLOSE_COMP, PuntErrors.NotSwapper.selector, "reporter");

        // and the swapper still can
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);
        assertEq(_storedAuctionHash(swapId, active), keccak256(abi.encode(d)), "swapper opened the auction");
    }

    function test_wrongPositionHashRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();

        OpenPuntStorage.MatchedSwap memory tampered = _copy(active);
        tampered.notional += 1;
        _reject(swapId, _dutchInput(), tampered, swapper, CLOSE_COMP, PuntErrors.WrongHash.selector, "tampered state");
    }

    function test_nonexistentPositionRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        uint256 ghost = swapId + 999;

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.close{value: CLOSE_COMP}(
            ghost, _dutchInput(), active, false, _emptyPermit2(), CLOSE_COMP, _emptyOracleGame(), _emptyOracleHelper()
        );

        assertEq(_storedDutchState(ghost), bytes32(0), "ghost auction slot empty");
        assertTrue(punt.swaps(swapId) != bytes32(0), "real position untouched");
    }

    /// @dev A matched-but-not-yet-opened position is reached naturally and rejects as NotActive.
    function test_preOpeningMatchedPositionRejectsAsNotActive() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _positionCfg(false, false);
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, A2_OPEN, matcher);

        assertFalse(mt.swap.active, "genuinely inactive");
        assertEq(punt.swapIdToReportId(p.swapId), mt.reportId, "sidecar carries the opening report");

        _reject(p.swapId, _dutchInput(), mt.swap, swapper, CLOSE_COMP, PuntErrors.NotActive.selector, "pre-opening");
    }

    function test_secondAuctionRejectedWhileOneIsLive() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _startDefaultAuction(swapId, active);

        _reject(
            swapId, _dutchInput(), active, swapper, CLOSE_COMP, PuntErrors.CloseIntentLive.selector, "second auction"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  Reward-curve parameters
    // ══════════════════════════════════════════════════════════════════

    function test_maxRewardZeroRejectsAtAuctionCreation() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _dutchInput();
        d.maxReward = 0;

        _reject(swapId, d, active, swapper, CLOSE_COMP, PuntErrors.InvalidDutchParams.selector, "maxReward 0");
    }

    function test_startingRewardZeroRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _dutchInput();
        d.startingReward = 0;

        _reject(swapId, d, active, swapper, CLOSE_COMP, PuntErrors.InvalidDutchParams.selector, "startingReward 0");
    }

    function test_maxRewardBelowStartingRewardRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _dutchInput();
        d.maxReward = d.startingReward - 1;

        _reject(
            swapId, d, active, swapper, CLOSE_COMP, PuntErrors.InvalidDutchParams.selector, "maxReward < startingReward"
        );
    }

    function test_maxRewardEqualToStartingRewardAccepted() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _dutchInput();
        d.maxReward = d.startingReward;

        OpenPuntStorage.CloseDutch memory emitted = _startAuction(swapId, active, d, false, CLOSE_COMP);
        assertEq(_storedAuctionHash(swapId, active), keccak256(abi.encode(emitted)), "equality accepted");
    }

    function test_growthRateBoundary() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();

        OpenPuntStorage.CloseDutch memory bad = _dutchInput();
        bad.growthRate = 9_999;
        _reject(swapId, bad, active, swapper, CLOSE_COMP, PuntErrors.InvalidDutchParams.selector, "growthRate 9999");

        OpenPuntStorage.CloseDutch memory ok = _dutchInput();
        ok.growthRate = 10_000;
        OpenPuntStorage.CloseDutch memory emitted = _startAuction(swapId, active, ok, false, CLOSE_COMP);
        assertEq(emitted.growthRate, 10_000, "growthRate 10000 accepted");
    }

    function test_maxRoundsBoundaries() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();

        OpenPuntStorage.CloseDutch memory zero = _dutchInput();
        zero.maxRounds = 0;
        _reject(swapId, zero, active, swapper, CLOSE_COMP, PuntErrors.InvalidDutchParams.selector, "maxRounds 0");

        OpenPuntStorage.CloseDutch memory over = _dutchInput();
        over.maxRounds = 101;
        _reject(swapId, over, active, swapper, CLOSE_COMP, PuntErrors.InvalidDutchParams.selector, "maxRounds 101");

        OpenPuntStorage.CloseDutch memory one = _dutchInput();
        one.maxRounds = 1;
        assertEq(_startAuction(swapId, active, one, false, CLOSE_COMP).maxRounds, 1, "maxRounds 1 accepted");

        // a second position for the upper accepted bound
        (uint256 swapId2, OpenPuntStorage.MatchedSwap memory active2,) = _openIdle();
        OpenPuntStorage.CloseDutch memory hundred = _dutchInput();
        hundred.maxRounds = 100;
        assertEq(_startAuction(swapId2, active2, hundred, false, CLOSE_COMP).maxRounds, 100, "maxRounds 100 accepted");
    }

    function test_roundLengthZeroRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _dutchInput();
        d.roundLength = 0;

        _reject(swapId, d, active, swapper, CLOSE_COMP, PuntErrors.InvalidDutchParams.selector, "roundLength 0");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Expiration window
    // ══════════════════════════════════════════════════════════════════

    function test_expirationOneSecondInThePastRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _dutchInput();
        d.expiration = uint48(vm.getBlockTimestamp() - 1);

        _reject(swapId, d, active, swapper, CLOSE_COMP, PuntErrors.InvalidExpiration.selector, "expiration in the past");
    }

    /// @dev `expiration == block.timestamp` is accepted by close(), but report()'s
    ///      `block.timestamp >= expiration` means it is already expired for reward purposes.
    function test_expirationExactlyNowIsAcceptedButImmediatelyExpired() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _dutchInput();
        d.expiration = uint48(vm.getBlockTimestamp());

        OpenPuntStorage.CloseDutch memory emitted = _startAuction(swapId, active, d, false, CLOSE_COMP);
        assertEq(_storedAuctionHash(swapId, active), keccak256(abi.encode(emitted)), "auction created at the boundary");
        assertEq(emitted.expiration, emitted.start, "expiration equals the auction start");

        // Reporting in the same block consumes the expired auction at zero reward.
        uint256 reporterCollat0 = _spendable(reporter, address(collat));
        uint256 swapperCollat0 = collat.balanceOf(swapper);
        _reportWithDutch(swapId, emitted, active, p.preimage, reporter, 0);

        assertEq(_spendable(reporter, address(collat)), reporterCollat0, "no reward paid");
        assertEq(collat.balanceOf(swapper) - swapperCollat0, DUTCH_MAX, "full maximum returned");
        assertEq(_storedDutchState(swapId), bytes32(0), "expired auction consumed");
    }

    function test_expirationOneHourAheadAcceptedAndBeyondRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();

        OpenPuntStorage.CloseDutch memory ok = _dutchInput();
        ok.expiration = uint48(vm.getBlockTimestamp() + 1 hours);
        OpenPuntStorage.CloseDutch memory emitted = _startAuction(swapId, active, ok, false, CLOSE_COMP);
        assertEq(emitted.expiration, uint48(vm.getBlockTimestamp() + 1 hours), "exactly one hour accepted");

        (uint256 swapId2, OpenPuntStorage.MatchedSwap memory active2,) = _openIdle();
        OpenPuntStorage.CloseDutch memory bad = _dutchInput();
        bad.expiration = uint48(vm.getBlockTimestamp() + 1 hours + 1);
        _reject(
            swapId2,
            bad,
            active2,
            swapper,
            CLOSE_COMP,
            PuntErrors.InvalidExpiration.selector,
            "one hour plus one second"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  Which caller-supplied fields must be zero
    // ══════════════════════════════════════════════════════════════════

    function test_callerSuppliedSwapperAndCollatTokenMustBeZero() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();

        OpenPuntStorage.CloseDutch memory withSwapper = _dutchInput();
        withSwapper.swapper = swapper; // even the correct value is rejected
        _reject(swapId, withSwapper, active, swapper, CLOSE_COMP, PuntErrors.MustBeZero.selector, "swapper preset");

        OpenPuntStorage.CloseDutch memory withToken = _dutchInput();
        withToken.collatToken = address(collat);
        _reject(swapId, withToken, active, swapper, CLOSE_COMP, PuntErrors.MustBeZero.selector, "collatToken preset");
    }

    /// @dev All five contract-overridden fields must arrive zero. Each is rejected on its own,
    ///      including values that would have been overwritten with the identical canonical value.
    function test_everyOverriddenFieldMustBeZero() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();

        OpenPuntStorage.CloseDutch memory withSwapId = _dutchInput();
        withSwapId.swapId = swapId; // even the correct id is rejected
        _reject(swapId, withSwapId, active, swapper, CLOSE_COMP, PuntErrors.MustBeZero.selector, "swapId preset");

        OpenPuntStorage.CloseDutch memory withWrongSwapId = _dutchInput();
        withWrongSwapId.swapId = swapId + 12345;
        _reject(
            swapId, withWrongSwapId, active, swapper, CLOSE_COMP, PuntErrors.MustBeZero.selector, "wrong swapId preset"
        );

        OpenPuntStorage.CloseDutch memory withStart = _dutchInput();
        withStart.start = uint48(vm.getBlockTimestamp()); // even the value about to be stamped
        _reject(swapId, withStart, active, swapper, CLOSE_COMP, PuntErrors.MustBeZero.selector, "start preset");

        OpenPuntStorage.CloseDutch memory withFlag = _dutchInput();
        withFlag.useInternalBalances = true; // contradicts the `false` function argument
        _reject(
            swapId, withFlag, active, swapper, CLOSE_COMP, PuntErrors.MustBeZero.selector, "useInternalBalances preset"
        );
    }

    /// @dev The flag is rejected on its calldata value alone, not on whether it agrees with the
    ///      function argument: `true` is refused even when internal funding is requested.
    function test_useInternalBalancesFlagIsRejectedEvenWhenItAgrees() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();

        OpenPuntStorage.CloseDutch memory d = _dutchInput();
        d.useInternalBalances = true;

        Snap memory before = _snap(swapId, active.collatToken);
        vm.prank(swapper);
        vm.expectRevert(PuntErrors.MustBeZero.selector);
        punt.close{value: 0}(
            swapId, d, active, true, _emptyPermit2(), CLOSE_COMP, _emptyOracleGame(), _emptyOracleHelper()
        );
        _assertUnchanged(before, swapId, active.collatToken, "agreeing flag still rejected");
    }

    /// @dev Clean input still produces exactly the canonical auction, with all five fields
    ///      stamped by the contract.
    function test_cleanInputProducesTheCanonicalAuction() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();

        OpenPuntStorage.CloseDutch memory clean = _dutchInput();
        assertEq(clean.swapper, address(0), "input leaves swapper zero");
        assertEq(clean.collatToken, address(0), "input leaves collatToken zero");
        assertEq(clean.swapId, 0, "input leaves swapId zero");
        assertEq(clean.start, 0, "input leaves start zero");
        assertFalse(clean.useInternalBalances, "input leaves the funding flag zero");

        uint48 startTs = uint48(vm.getBlockTimestamp());
        OpenPuntStorage.CloseDutch memory emitted = _startAuction(swapId, active, clean, false, CLOSE_COMP);

        assertEq(emitted.swapper, swapper, "swapper stamped from the position");
        assertEq(emitted.collatToken, active.collatToken, "collatToken stamped from the position");
        assertEq(emitted.swapId, swapId, "swapId stamped from the call");
        assertEq(emitted.start, startTs, "start stamped with the block timestamp");
        assertFalse(emitted.useInternalBalances, "funding flag stamped from the function argument");

        OpenPuntStorage.CloseDutch memory expected = _canonicalDutch(clean, swapId, active.collatToken, false, startTs);
        assertEq(keccak256(abi.encode(emitted)), keccak256(abi.encode(expected)), "emitted == canonical");
        assertEq(_storedAuctionHash(swapId, active), keccak256(abi.encode(expected)), "stored == canonical");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Successful creation leaves the position itself untouched
    // ══════════════════════════════════════════════════════════════════

    function test_auctionCreationDoesNotDisturbThePosition() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        bytes32 positionHash = punt.swaps(swapId);

        _startDefaultAuction(swapId, active);

        assertEq(punt.swaps(swapId), positionHash, "position hash unchanged by close()");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, CLOSE_COMP, "pending execution comp recorded");
        assertTrue(intent, "close request recorded");
    }
}
