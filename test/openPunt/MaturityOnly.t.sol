// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LivenessBase.t.sol";

/**
 * @notice Fixed-maturity positions accept their opening game normally but reject every
 *         active-position report before maturity. Close auctions and liquidation heartbeats
 *         remain available before maturity so callers can prepare the first eligible report.
 */
contract MaturityOnlyTest is LivenessBase {
    uint48 internal constant SHORT_GAME = 2; // four seconds at 2,000 ms per block
    uint48 internal constant FIXED_TERM = 1 hours;

    function setUp() public {
        _setUpLiveness();
    }

    function _cfg(bool heartbeat) internal pure returns (LiveCfg memory c) {
        c = _defaultLiveCfg();
        c.settlementTime = SHORT_GAME;
        c.maturityWindow = FIXED_TERM;
        if (heartbeat) {
            c.hbMin = HB_MIN;
            c.hbMax = HB_MAX;
        }
    }

    function _openFixed(bool heartbeat)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p, Matched memory opening)
    {
        LiveCfg memory c = _cfg(heartbeat);
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _liveCfg(c);
        s.maturityOnly = true;

        p = _proposeWith(s, m, swapper);
        opening = _matchSwapWith(p, A2_OPEN, matcher);
        openingReportTs = opening.game.lastReportOppoTime;
        _advanceValid(_secondsForBlocks(c.settlementTime) + 2);
        active = _executeOpening(opening, executor);
        swapId = p.swapId;

        assertTrue(active.active, "opening succeeds normally");
        assertTrue(active.maturityOnly, "fixed-maturity mode survives every opening transition");
        assertLt(vm.getBlockTimestamp(), active.maturity, "position opens before maturity");
    }

    function _warpToMaturity(OpenPuntStorage.MatchedSwap memory active) internal {
        _advanceValid(uint256(active.maturity) - vm.getBlockTimestamp());
        assertEq(vm.getBlockTimestamp(), active.maturity, "exactly at maturity");
    }

    function test_openingAndPreMaturityCloseAuctionRemainAvailable() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,,) = _openFixed(false);

        OpenPuntStorage.CloseDutch memory dutch = _startDefaultAuction(swapId, active);

        assertEq(_storedAuctionHash(swapId, active), keccak256(abi.encode(dutch)), "auction funded before maturity");
        assertTrue(closeRequestBlockIsLive(swapId), "close request is live before maturity");
        assertEq(punt.swapIdToReportId(swapId), 0, "auction does not create an oracle report");
    }

    function test_preMaturityReportRevertsWithoutConsumingTheAuctionOrAllocatingAReport() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openFixed(false);
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        input.expiration = uint48(vm.getBlockTimestamp() + 1 hours);
        OpenPuntStorage.CloseDutch memory dutch = _startAuction(swapId, active, input, false, CLOSE_COMP);
        bytes32 auctionHash = _storedAuctionHash(swapId, active);
        uint256 nextReportId = oracle.nextReportId();
        uint256 reporterA = _spendable(reporter, address(tokenA));
        uint256 reporterB = _spendable(reporter, address(tokenB));

        vm.prank(reporter);
        vm.expectRevert(PuntErrors.MaturityNotReached.selector);
        puntLifecycle.report(
            swapId, keccak256(abi.encode(dutch)), active, p.preimage, _noTiming(), reporter, A1, A2_HEALTHY, 0
        );

        assertEq(punt.swapIdToReportId(swapId), 0, "no report bound");
        assertEq(oracle.nextReportId(), nextReportId, "no oracle id allocated");
        assertEq(_storedAuctionHash(swapId, active), auctionHash, "auction remains claimable");
        assertEq(_spendable(reporter, address(tokenA)), reporterA, "token1 untouched");
        assertEq(_spendable(reporter, address(tokenB)), reporterB, "token2 untouched");

        _warpToMaturity(active);
        Matched memory report = _reportLive(swapId, dutch, active, p.preimage, reporter, 0, A2_HEALTHY);
        assertEq(punt.swapIdToReportId(swapId), report.reportId, "same auction funds the maturity report");
        assertEq(_storedDutchState(swapId), bytes32(0), "auction consumed only after maturity");
    }

    function test_nonMaturityOnlyPositionStillAllowsPreMaturityReports() public {
        LiveCfg memory c = _cfg(false);
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openLive(c);

        Matched memory report = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, 0, A2_HEALTHY);

        assertFalse(active.maturityOnly, "ordinary mode");
        assertEq(punt.swapIdToReportId(swapId), report.reportId, "pre-maturity report accepted");
    }

    function test_reportAtExactMaturityClosesAHealthyPosition() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openFixed(false);
        _warpToMaturity(active);

        Matched memory report = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, 0, A2_HEALTHY);
        _advanceValid(_secondsForBlocks(SHORT_GAME));
        Vm.Log[] memory logs = _executeNow(swapId, report, closeExecutor);

        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "healthy maturity settlement closes");
        assertEq(punt.swaps(swapId), bytes32(0), "terminal");
    }

    function test_maturitySettlementStillCapsProfitAtThePostedMarginPool() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openFixed(false);
        _warpToMaturity(active);

        Matched memory report = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, 0, 10 * A2_OPEN);
        _advanceValid(_secondsForBlocks(SHORT_GAME));
        Vm.Log[] memory logs = _executeNow(swapId, report, closeExecutor);
        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);

        assertEq(owedS, uint256(MARGIN_S) + MARGIN_M, "swapper payout capped at the bilateral pool");
        assertEq(owedM, 0, "matcher cannot owe more than posted margin");
    }

    function test_preMaturityHeartbeatAuthorisesTheMaturityLiquidation() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openFixed(true);
        _advanceValid(uint256(active.maturity) - vm.getBlockTimestamp() - HB_MIN);
        _heartbeat(swapId, active, outsider);
        (, uint48 heartbeatAt) = punt.liquidationHeartbeats(swapId);
        _warpToMaturity(active);

        Matched memory report = _reportLive(swapId, _noDutch(), active, p.preimage, reporter, 0, A2_LIQUIDATES);
        (uint128 boundTo,) = punt.liquidationHeartbeats(swapId);
        assertEq(boundTo, uint128(report.reportId), "pre-maturity heartbeat binds to maturity report");
        assertGe(
            uint256(report.game.lastReportOppoTime) + _secondsForBlocks(SHORT_GAME),
            uint256(heartbeatAt) + HB_MIN,
            "minimum liquidation notice satisfied"
        );

        _advanceValid(_secondsForBlocks(SHORT_GAME));
        Vm.Log[] memory logs = _executeNow(swapId, report, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionLiquidated.selector, swapId), "maturity report liquidates");
        assertEq(punt.swaps(swapId), bytes32(0), "terminal");
    }

    function closeRequestBlockIsLive(uint256 swapId) internal view returns (bool) {
        return punt.closeRequestBlock(swapId) != 0;
    }
}
