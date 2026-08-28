// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";

/// @notice A report always consumes the current auction. A zero expected hash accepts whatever
///         auction is present; a nonzero hash requires that exact auction. Expired auctions pay
///         no reporter reward and return the full maximum to the swapper.
contract DutchResolutionPathsTest is CloseBase {
    uint128 internal constant REPORTER_COMP = 0.0005 ether;

    function setUp() public {
        _setUpClose();
    }

    struct Ctx {
        uint256 swapId;
        OpenPuntStorage.MatchedSwap active;
        OpenPuntStorage.MatcherPreimage preimage;
        OpenPuntStorage.CloseDutch dutch;
        bytes32 dutchHash;
    }

    function _setUpAuction() internal returns (Ctx memory c) {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);

        c.swapId = swapId;
        c.active = active;
        c.preimage = p.preimage;
        c.dutch = d;
        c.dutchHash = keccak256(abi.encode(d));

        assertEq(_storedAuctionHash(swapId, active), c.dutchHash, "auction live");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, CLOSE_COMP, "pending comp escrowed");
        assertTrue(intent, "close request is live");
    }

    /// @dev Shared post-conditions: compensation migrates into the new report in every path.
    function _assertCompMigrated(Ctx memory c, Matched memory mt) internal view {
        (uint128 pending,,) = _closeState(c.swapId);
        assertEq(pending, 0, "pending execution comp zeroed");
        assertEq(
            punt.executionGasComp(mt.reportId),
            uint256(CLOSE_COMP) + REPORTER_COMP,
            "executionGasComp == stored auction compensation + reporter contribution"
        );
        assertEq(punt.swapIdToReportId(c.swapId), mt.reportId, "sidecar points at the new report");
        assertEq(punt.swaps(c.swapId), keccak256(abi.encode(c.active)), "active hash remains stable");
        (,, bool intent) = _closeState(c.swapId);
        assertTrue(intent, "close intent survives the report");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Path 1: claimed before expiry
    // ══════════════════════════════════════════════════════════════════

    function test_claimedPath() public {
        Ctx memory c = _setUpAuction();
        uint256 reporterCollat0 = _spendable(reporter, address(collat));
        uint256 swapperCollat0 = _spendable(swapper, address(collat));
        uint256 swapperRaw0 = collat.balanceOf(swapper);

        _advanceTimeAndBlocks(60, 30); // round 1 -> 15e18
        Matched memory mt = _reportWithDutch(c.swapId, c.dutch, c.active, c.preimage, reporter, REPORTER_COMP);

        assertEq(_storedDutchState(c.swapId), bytes32(0), "dutch hash deleted");
        assertEq(_spendable(reporter, address(collat)) - reporterCollat0, 15e18, "reporter reward");
        assertEq(_spendable(swapper, address(collat)), swapperCollat0, "external route leaves the ledger unchanged");
        assertEq(collat.balanceOf(swapper) - swapperRaw0, 85e18, "swapper remainder pushed externally");
        _assertCompMigrated(c, mt);
    }

    function test_claimedPathRequiresTheExactPreimage() public {
        Ctx memory c = _setUpAuction();

        OpenPuntStorage.CloseDutch memory tampered = _copy(c.dutch);
        tampered.startingReward += 1;

        bytes32 storedBefore = punt.swaps(c.swapId);
        vm.prank(reporter);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.report(
            c.swapId,
            _expectedDutchHash(tampered),
            c.active,
            c.preimage,
            _noTiming(),
            reporter,
            A1,
            A2_OPEN,
            REPORTER_COMP
        );

        assertEq(punt.swaps(c.swapId), storedBefore, "position untouched");
        assertEq(_storedAuctionHash(c.swapId, c.active), c.dutchHash, "auction untouched");
        (uint128 pending,,) = _closeState(c.swapId);
        assertEq(pending, CLOSE_COMP, "pending comp untouched");
    }

    function test_claimedAuctionCannotBeCancelledAfterwards() public {
        Ctx memory c = _setUpAuction();
        _reportWithDutch(c.swapId, c.dutch, c.active, c.preimage, reporter, REPORTER_COMP);

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.OracleGameInProgress.selector);
        puntLifecycle.cancelCloseAuction(c.swapId, c.active);
    }

    function test_zeroExpectedHashClaimsWhateverAuctionIsPresent() public {
        Ctx memory c = _setUpAuction();
        uint256 reporterCollat0 = _spendable(reporter, address(collat));
        uint256 swapperRaw0 = collat.balanceOf(swapper);

        Matched memory mt = _reportWithDutch(c.swapId, _noDutch(), c.active, c.preimage, reporter, REPORTER_COMP);

        assertEq(_storedDutchState(c.swapId), bytes32(0), "auction consumed");
        assertEq(_spendable(reporter, address(collat)) - reporterCollat0, DUTCH_START, "current reward paid");
        assertEq(collat.balanceOf(swapper) - swapperRaw0, DUTCH_MAX - DUTCH_START, "remainder returned");
        _assertCompMigrated(c, mt);
    }

    function test_zeroExpectedHashStillStartsTheReportNormally() public {
        Ctx memory c = _setUpAuction();
        Matched memory mt = _reportWithDutch(c.swapId, _noDutch(), c.active, c.preimage, reporter, REPORTER_COMP);

        assertTrue(mt.reportId != 0, "a real oracle game was created");
        assertEq(mt.game.currentReporter, reporter, "reporter owns it");
        assertEq(
            oracle.oracleGame(mt.reportId),
            keccak256(abi.encode(mt.game, mt.helper)),
            "the oracle game reconstructs from its own log"
        );
        assertTrue(mt.swap.active, "position still active");
    }

    function test_secondReportIsBlockedAfterTheFirstConsumesTheAuction() public {
        Ctx memory c = _setUpAuction();
        Matched memory first = _reportWithDutch(c.swapId, _noDutch(), c.active, c.preimage, reporter, REPORTER_COMP);

        assertEq(_storedDutchState(c.swapId), bytes32(0), "auction consumed once");
        assertTrue(first.reportId != 0, "first report exists");

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.OracleGameInProgress.selector);
        puntLifecycle.report(
            c.swapId, _expectedDutchHash(c.dutch), first.swap, c.preimage, _noTiming(), outsider, A1, A2_OPEN, 0
        );
    }

    function _auctionExpiringIn(uint256 secs) internal returns (Ctx memory c) {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        input.expiration = uint48(vm.getBlockTimestamp() + secs);

        OpenPuntStorage.CloseDutch memory d = _startAuction(swapId, active, input, false, CLOSE_COMP);
        c.swapId = swapId;
        c.active = active;
        c.preimage = p.preimage;
        c.dutch = d;
        c.dutchHash = keccak256(abi.encode(d));
    }

    function test_oneSecondBeforeExpiryStillClaims() public {
        Ctx memory c = _auctionExpiringIn(120);
        uint256 reporterCollat0 = _spendable(reporter, address(collat));

        _advanceTimeAndBlocks(119, 59); // one second before expiry, still round 1
        assertEq(vm.getBlockTimestamp(), uint256(c.dutch.expiration) - 1, "one second before expiry");

        _reportWithDutch(c.swapId, c.dutch, c.active, c.preimage, reporter, REPORTER_COMP);

        assertEq(_spendable(reporter, address(collat)) - reporterCollat0, 15e18, "reward still claimable");
        assertEq(_storedDutchState(c.swapId), bytes32(0), "auction consumed");
    }

    function test_exactlyAtExpiryConsumesAtZeroRewardAndRefundsAll() public {
        Ctx memory c = _auctionExpiringIn(120);
        uint256 reporterCollat0 = _spendable(reporter, address(collat));
        uint256 swapperRaw0 = collat.balanceOf(swapper);

        _advanceTimeAndBlocks(120, 60);
        assertEq(vm.getBlockTimestamp(), c.dutch.expiration, "exactly at expiry");

        Matched memory mt = _reportWithDutch(c.swapId, c.dutch, c.active, c.preimage, reporter, REPORTER_COMP);

        assertEq(_spendable(reporter, address(collat)), reporterCollat0, "no reward at expiry");
        assertEq(collat.balanceOf(swapper) - swapperRaw0, DUTCH_MAX, "full maximum returned");
        assertEq(_storedDutchState(c.swapId), bytes32(0), "auction consumed");
        _assertCompMigrated(c, mt);
    }

    function test_oneSecondAfterExpiryConsumesAtZeroRewardAndRefundsAll() public {
        Ctx memory c = _auctionExpiringIn(120);
        uint256 reporterCollat0 = _spendable(reporter, address(collat));
        uint256 swapperRaw0 = collat.balanceOf(swapper);

        _advanceTimeAndBlocks(121, 60);
        assertEq(vm.getBlockTimestamp(), uint256(c.dutch.expiration) + 1, "one second past expiry");
        Matched memory mt = _reportWithDutch(c.swapId, c.dutch, c.active, c.preimage, reporter, REPORTER_COMP);

        assertEq(_spendable(reporter, address(collat)), reporterCollat0, "no reward after expiry");
        assertEq(collat.balanceOf(swapper) - swapperRaw0, DUTCH_MAX, "full maximum returned");
        assertEq(_storedDutchState(c.swapId), bytes32(0), "auction consumed");
        _assertCompMigrated(c, mt);
    }

    /// @dev Every nonzero CloseDutch must hash to the stored auction before its expiration is
    ///      trusted, so a fabricated "already expired" struct can no longer force-skip a live
    ///      auction. It is rejected outright and nothing moves.
    function test_fabricatedExpiredDutchIsRejectedAndRollsBack() public {
        Ctx memory c = _setUpAuction();
        Snap memory before = _snap(c.swapId, c.active.collatToken);
        uint256 reporterCollat0 = _spendable(reporter, address(collat));
        uint256 nextReportIdBefore = oracle.nextReportId();

        // nothing to do with the real auction: different rewards, and long expired
        OpenPuntStorage.CloseDutch memory fake;
        fake.maxReward = 1;
        fake.startingReward = 1;
        fake.expiration = 1;

        assertTrue(vm.getBlockTimestamp() < c.dutch.expiration, "the real auction is still live");

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.report(
            c.swapId, _expectedDutchHash(fake), c.active, c.preimage, _noTiming(), reporter, A1, A2_OPEN, REPORTER_COMP
        );

        _assertUnchanged(before, c.swapId, c.active.collatToken, "fabricated expired dutch");
        assertEq(oracle.nextReportId(), nextReportIdBefore, "no oracle game created");
        assertEq(_spendable(reporter, address(collat)), reporterCollat0, "no reward moved");

        // and the genuine preimage still claims normally afterwards
        _reportWithDutch(c.swapId, c.dutch, c.active, c.preimage, reporter, REPORTER_COMP);
        assertEq(_spendable(reporter, address(collat)) - reporterCollat0, DUTCH_START, "reward still claimable");
    }

    /// @dev A fabricated unexpired struct is rejected by the same check.
    function test_fabricatedUnexpiredDutchIsRejected() public {
        Ctx memory c = _setUpAuction();

        OpenPuntStorage.CloseDutch memory fake = _copy(c.dutch);
        fake.maxReward = c.dutch.maxReward + 1; // richer, and still unexpired

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.report(
            c.swapId, _expectedDutchHash(fake), c.active, c.preimage, _noTiming(), reporter, A1, A2_OPEN, 0
        );

        assertEq(_storedAuctionHash(c.swapId, c.active), c.dutchHash, "auction untouched");
    }

    /// @dev With no auction, only a zero expected hash is valid.
    function test_nonzeroDutchWithoutAnyAuctionIsRejected() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        assertEq(_storedDutchState(swapId), bytes32(0), "no auction exists");

        OpenPuntStorage.CloseDutch memory invented = _dutchInput();
        invented.maxReward = 1e18;

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.report(
            swapId, _expectedDutchHash(invented), active, p.preimage, _noTiming(), reporter, A1, A2_OPEN, 0
        );

        // the zero sentinel is still the way to report without a preimage
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, 0);
        assertTrue(mt.reportId != 0, "sentinel report succeeds");
        assertEq(_storedDutchState(swapId), bytes32(0), "still no auction");
    }

    /// @dev Expiry gates only the reward: the oracle report proceeds and the intent survives.
    function test_expiryDoesNotBlockTheReportOrEraseIntent() public {
        Ctx memory c = _auctionExpiringIn(120);
        _advanceTimeAndBlocks(200, 100);

        Matched memory mt = _reportWithDutch(c.swapId, c.dutch, c.active, c.preimage, reporter, REPORTER_COMP);

        assertTrue(mt.reportId != 0, "a real oracle game was still created");
        assertTrue(mt.swap.active, "position still active");
        (,, bool intent) = _closeState(c.swapId);
        assertTrue(intent, "close intent survives expiry");

        // and the position closes on execution because the intent is set
        Vm.Log[] memory logs = _executeReport(c.swapId, mt, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, c.swapId), "closed on intent");
    }
}
