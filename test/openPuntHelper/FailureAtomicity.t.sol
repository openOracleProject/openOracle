// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenPuntHelperBase, IV2FactoryMin, IERC20Min} from "./OpenPuntHelperBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice Late failures must unwind everything, including work already done by the router and the
 *         oracle.
 *
 * @dev The helper pulls the caller's assets, draws on their internal ledger,
 *      pushes capital to the router, executes an arbitrary plan, deposits into OpenOracle and
 *      grants OpenPunt an allowance before OpenPunt validates the position. Every failure must
 *      therefore unwind the entire transaction.
 *
 *      Snapshots cover caller wallets, caller internal balances and allowances, designated-party balances and
 *      allowances, the helper's external and internal balances, pool reserves, the OpenPunt swap
 *      hash, and the oracle's report-ID allocation. A partial effect anywhere is a real loss,
 *      because the caller's capital was consumed for nothing.
 *
 *      Report-ID allocation is included because `nextReportId` advancing on a failed call
 *      would be an invisible leak that no balance check would catch.
 */
contract FailureAtomicityTest is OpenPuntHelperBase {
    struct Snap {
        uint256 callerA;
        uint256 callerB;
        uint256 callerCollat;
        uint256 callerC;
        uint256 callerEth;
        uint256 callerIntA;
        uint256 callerIntC;
        uint256 callerAllowA;
        uint256 callerAllowC;
        uint256 partyIntA;
        uint256 partyAllowA;
        uint256 helperA;
        uint256 helperB;
        uint256 helperC;
        uint256 helperEth;
        uint256 helperIntA;
        uint256 helperPuntAllowA;
        uint256 poolCA;
        uint256 poolCB;
        uint256 nextReportId;
        bytes32 swapHash;
        // Position-level state touched by the report path.
        bytes32 auctionState;
        bool closeIntent;
        uint48 closeRequestBlock;
        uint128 pendingComp;
        uint128 execGasComp;
        uint128 liveExecGasComp;
        uint128 heartbeatReportId;
        uint48 heartbeatTimestamp;
        uint256 reporterIntA;
        uint256 reporterAllowA;
        uint256 reporterIntB;
        uint256 reporterAllowB;
    }

    function setUp() public override {
        super.setUp();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));
    }

    function _snap(uint256 swapId) internal view returns (Snap memory s) {
        s.callerA = tokenA.balanceOf(funder);
        s.callerB = tokenB.balanceOf(funder);
        s.callerCollat = collat.balanceOf(funder);
        s.callerC = tokenC.balanceOf(funder);
        s.callerEth = funder.balance;
        s.callerIntA = oracle.tokenHolder(funder, address(tokenA));
        s.callerIntC = oracle.tokenHolder(funder, address(tokenC));
        s.callerAllowA = oracle.internalAllowance(funder, address(helper), address(tokenA));
        s.callerAllowC = oracle.internalAllowance(funder, address(helper), address(tokenC));
        s.partyIntA = oracle.tokenHolder(designatedMatcher, address(tokenA));
        s.partyAllowA = oracle.internalAllowance(designatedMatcher, address(punt), address(tokenA));
        s.helperA = tokenA.balanceOf(address(helper));
        s.helperB = tokenB.balanceOf(address(helper));
        s.helperC = tokenC.balanceOf(address(helper));
        s.helperEth = address(helper).balance;
        s.helperIntA = oracle.tokenHolder(address(helper), address(tokenA));
        s.helperPuntAllowA = oracle.internalAllowance(address(helper), address(punt), address(tokenA));
        // The route swaps tokenC into both tokenA and tokenB, so both pools must be reconciled.
        s.poolCA = tokenC.balanceOf(IV2FactoryMin(v2Factory).getPair(address(tokenC), address(tokenA)));
        s.poolCB = tokenC.balanceOf(IV2FactoryMin(v2Factory).getPair(address(tokenC), address(tokenB)));
        s.nextReportId = oracle.nextReportId();
        s.swapHash = punt.swaps(swapId);
        s.auctionState = _storedDutchState(swapId);
        (s.pendingComp, s.closeRequestBlock, s.closeIntent) = _closeState(swapId);
        // The failed call would allocate nextReportId, so that report's compensation slot is snapshotted.
        s.execGasComp = punt.executionGasComp(oracle.nextReportId());
        s.liveExecGasComp = punt.executionGasComp(_liveReportId);
        (s.heartbeatReportId, s.heartbeatTimestamp) = _heartbeat(swapId);
        // Token1 moves before the tested failure. These fields track the reporter separately from the matcher.
        s.reporterIntA = oracle.tokenHolder(designatedReporter, address(tokenA));
        s.reporterAllowA = oracle.internalAllowance(designatedReporter, address(punt), address(tokenA));
        s.reporterIntB = oracle.tokenHolder(designatedReporter, address(tokenB));
        s.reporterAllowB = oracle.internalAllowance(designatedReporter, address(punt), address(tokenB));
    }

    uint256 internal _liveReportId;

    function _heartbeat(uint256 swapId) internal view returns (uint128 id, uint48 ts) {
        (id, ts) = punt.liquidationHeartbeats(swapId);
    }

    function _assertRestored(uint256 swapId, Snap memory b) internal view {
        Snap memory a = _snap(swapId);
        assertEq(a.callerA, b.callerA, "caller token1 wallet");
        assertEq(a.callerB, b.callerB, "caller token2 wallet");
        assertEq(a.callerCollat, b.callerCollat, "caller collateral wallet");
        assertEq(a.callerC, b.callerC, "caller route-token wallet");
        assertEq(a.callerEth, b.callerEth, "caller ETH");
        assertEq(a.callerIntA, b.callerIntA, "caller internal token1");
        assertEq(a.callerIntC, b.callerIntC, "caller internal route token");
        assertEq(a.callerAllowA, b.callerAllowA, "caller internal allowance token1");
        assertEq(a.callerAllowC, b.callerAllowC, "caller internal allowance route token");
        assertEq(a.partyIntA, b.partyIntA, "designated party internal balance");
        assertEq(a.partyAllowA, b.partyAllowA, "designated party allowance to OpenPunt");
        assertEq(a.helperA, b.helperA, "helper token1");
        assertEq(a.helperB, b.helperB, "helper token2");
        assertEq(a.helperC, b.helperC, "helper route token");
        assertEq(a.helperEth, b.helperEth, "helper ETH");
        assertEq(a.helperIntA, b.helperIntA, "helper internal token1");
        assertEq(a.helperPuntAllowA, b.helperPuntAllowA, "helper allowance to OpenPunt");
        assertEq(a.poolCA, b.poolCA, "tokenC/tokenA pool reserves -- the route survived");
        assertEq(a.poolCB, b.poolCB, "tokenC/tokenB pool reserves -- the route survived");
        assertEq(a.nextReportId, b.nextReportId, "a report id was allocated by a failed call");
        assertEq(a.swapHash, b.swapHash, "the swap hash moved");
        assertEq(a.auctionState, b.auctionState, "the stored auction moved");
        assertEq(a.closeIntent, b.closeIntent, "close intent moved");
        assertEq(a.closeRequestBlock, b.closeRequestBlock, "the close-request block moved");
        assertEq(a.pendingComp, b.pendingComp, "stored auction compensation moved");
        assertEq(a.execGasComp, b.execGasComp, "compensation was escrowed against the prospective report id");
        assertEq(a.liveExecGasComp, b.liveExecGasComp, "compensation on the live report id moved");
        assertEq(a.heartbeatReportId, b.heartbeatReportId, "heartbeat report id moved");
        assertEq(a.heartbeatTimestamp, b.heartbeatTimestamp, "heartbeat timestamp moved");
        assertEq(a.reporterIntA, b.reporterIntA, "designated reporter internal token1 -- the leg that moved");
        assertEq(a.reporterAllowA, b.reporterAllowA, "designated reporter token1 allowance -- the leg that moved");
        assertEq(a.reporterIntB, b.reporterIntB, "designated reporter internal token2");
        assertEq(a.reporterAllowB, b.reporterAllowB, "designated reporter token2 allowance");
    }

    // ────────────────────────────────────────────────────────────────────
    //  failures at every stage
    // ────────────────────────────────────────────────────────────────────

    /// @dev Opaque calldata is forwarded to the router. If the plan fails to fund the helper, the
    ///      final assertion reverts and restores every prior pull and internal draw.
    function test_anUnproductiveOpaqueRouteRestoresEverything() public {
        Proposal memory p = _propose();
        _armInternal();
        Snap memory b = _snap(p.swapId);

        bytes[] memory junk = new bytes[](1);
        junk[0] = abi.encode(address(tokenC), address(helper), uint256(0));

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InsufficientRouterOutput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(
                0, AMOUNT2, INITIAL_MARGIN_MATCHER, true, address(tokenC), 5000e18, abi.encodePacked(CMD_TRANSFER), junk
            ),
            router
        );

        _assertRestored(p.swapId, b);
    }

    /// @dev Router under-delivery: the swap really executed against the pool, and must be undone.
    function test_routerUnderDeliveryRestoresEverythingIncludingPoolReserves() public {
        Proposal memory p = _propose();
        _armInternal();
        Snap memory b = _snap(p.swapId);

        (bytes memory c, bytes[] memory i) = _v2ExactIn(address(tokenC), address(tokenA), 1e12, 1);
        (c, i) = _withSweep(c, i, address(tokenC));

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InsufficientRouterOutput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, true, address(tokenC), 1e12, c, i),
            router
        );

        _assertRestored(p.swapId, b);
    }

    /// @dev Wrong msg.value fails after the pulls and internal draws have already happened.
    function test_aWrongMsgValueRestoresEverything() public {
        Proposal memory p = _propose();
        _armInternal();
        Snap memory b = _snap(p.swapId);

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMsgValue.selector);
        helper.matchWithRoute{value: 1 wei}(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true),
            router
        );

        _assertRestored(p.swapId, b);
    }

    /// @dev A missing designated-party approval fails inside OpenPunt,
    ///      after the route, the oracle deposits and the OpenPunt allowance grant.
    function test_aMissingDesignatedApprovalRestoresEverything() public {
        Proposal memory p = _propose();
        _armInternal();

        address unapproved = address(0x4001);
        Snap memory b = _snap(p.swapId);

        uint256 maxIn = 6000e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(cj, ij, address(tokenC));

        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("InsufficientInternalBalance()")));
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            unapproved,
            _routeFunding(0, 0, INITIAL_MARGIN_MATCHER, true, address(tokenC), maxIn, cmds, ins),
            router
        );

        _assertRestored(p.swapId, b);
    }

    /// @dev A stale proposal hash fails in the helper before sourcing or routing. Empty router
    ///      calldata would instead reach the funding assertion if this fail-fast check disappeared.
    function test_anInvalidProposalHashRestoresEverything() public {
        Proposal memory p = _propose();
        _armInternal();
        Snap memory b = _snap(p.swapId);

        OpenPuntStorage.ProposedSwap memory tampered = p.swap;
        tampered.notional = tampered.notional + 1;

        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("WrongHash()")));
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            tampered,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, true, address(tokenC), 1e18, bytes(""), new bytes[](0)),
            router
        );

        _assertRestored(p.swapId, b);
    }

    /// @dev A stale matcher preimage is likewise rejected before an otherwise-unproductive route.
    function test_anInvalidMatcherPreimageRestoresEverything() public {
        Proposal memory p = _propose();
        _armInternal();
        Snap memory b = _snap(p.swapId);

        OpenPuntStorage.MatcherPreimage memory tampered = p.preimage;
        tampered.initialLiquidity = tampered.initialLiquidity + 1;

        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("WrongHash()")));
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            tampered,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, true, address(tokenC), 1e18, bytes(""), new bytes[](0)),
            router
        );

        _assertRestored(p.swapId, b);
    }

    /// @dev An expired proposal.
    function test_anExpiredProposalRestoresEverything() public {
        Proposal memory p = _propose();
        _armInternal();
        _advanceChain(EXPIRATION_WINDOW + 2);
        Snap memory b = _snap(p.swapId);

        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("Expired()")));
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true),
            router
        );

        _assertRestored(p.swapId, b);
    }

    /// @dev Partial approval: token1 granted, token2 omitted. `matchSwap` pushes both legs to the
    ///      matcher and then funds the oracle game, so the failure lands after the first delegated
    ///      leg has already moved. The first leg's transfer must unwind with everything else.
    function test_aPartiallyApprovedMatcherFailsAfterTheFirstLegAndUnwinds() public {
        Proposal memory p = _propose();
        _armInternal();

        address party = address(0x4003);
        _approveToPunt(party, address(tokenA)); // token1 only -- token2 deliberately omitted

        Snap memory b = _snap(p.swapId);

        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("InsufficientInternalBalance()")));
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            party,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true),
            router
        );

        _assertRestored(p.swapId, b);
        // The half-completed delegated leg must leave no trace on the designated party.
        assertEq(oracle.tokenHolder(party, address(tokenA)), 0, "the first leg survived on the matcher");
        assertEq(
            oracle.internalAllowance(party, address(punt), address(tokenA)),
            type(uint256).max,
            "the token1 allowance was consumed by a reverted match"
        );
    }

    // ────────────────────────────────────────────────────────────────────
    //  reportWithRoute, with a live Dutch auction and a real route
    // ────────────────────────────────────────────────────────────────────

    /// @dev A live close auction, a genuine route, and a reporter approved for token1 but not token2
    ///      place the failure after the route executes, oracle deposits land, OpenPunt is approved, and the first
    ///      delegated leg moved. Everything above is reconciled, including the Dutch auction state
    ///      and the pending execution compensation.
    ///
    ///      A zero allowance on an oracle leg surfaces as `InsufficientInternalBalance()`, because
    ///      strict delegation clamps `fromInternal` to the allowance and then fails the
    ///      `fromInternal < amount` check. Execution compensation is funded directly by the helper
    ///      and does not consume the designated reporter's ETH allowance.
    function test_aPartiallyApprovedReporterUnwindsAfterRouteAndFirstLeg() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openWithLiveDutch();

        _armInternal();
        _approveToPunt(designatedReporter, address(tokenA)); // token1 only

        Snap memory b = _snap(sid);
        // Each field must be nonzero so the rollback assertions cannot pass vacuously.
        assertTrue(b.auctionState != bytes32(0), "precondition: a live Dutch auction");
        assertTrue(b.heartbeatTimestamp != 0, "precondition: a recorded heartbeat");
        // After the opening executes, the report sidecar is cleared, so `close()` takes the
        // auction branch and stores its compensation with the auction rather than against a report
        // id. That is the field that must be non-zero here.
        assertTrue(b.pendingComp != 0, "precondition: compensation escrowed on the close auction");
        assertTrue(b.reporterAllowA != 0, "precondition: the reporter's token1 allowance is granted");

        uint256 maxIn = 6000e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(cj, ij, address(tokenC));

        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("InsufficientInternalBalance()")));
        helper.reportWithRoute{value: REPORT_EXEC_COMP}(
            sid,
            _expectedDutchHash(_dutch),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _routeFunding(0, 0, REPORT_EXEC_COMP, true, address(tokenC), maxIn, cmds, ins),
            router
        );

        _assertRestored(sid, b);
    }

    /// @dev Granting the missing token2 approval and retrying the same routed call succeeds — the
    ///      identical payload that failed above, route and all, not a simpler no-route substitute.
    function test_theSameRoutedReportSucceedsAfterTheMissingApproval() public {
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openWithLiveDutch();

        _armInternal();
        _approveToPunt(designatedReporter, address(tokenA));

        uint256 reportIdBefore = oracle.nextReportId();

        uint256 maxIn = 6000e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(cj, ij, address(tokenC));

        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("InsufficientInternalBalance()")));
        helper.reportWithRoute{value: REPORT_EXEC_COMP}(
            sid,
            _expectedDutchHash(_dutch),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _routeFunding(0, 0, REPORT_EXEC_COMP, true, address(tokenC), maxIn, cmds, ins),
            router
        );

        assertEq(oracle.nextReportId(), reportIdBefore, "a report id leaked on the failed attempt");

        _approveToPunt(designatedReporter, address(tokenB));

        vm.recordLogs();
        vm.prank(funder);
        helper.reportWithRoute{value: REPORT_EXEC_COMP}(
            sid,
            _expectedDutchHash(_dutch),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _routeFunding(0, 0, REPORT_EXEC_COMP, true, address(tokenC), maxIn, cmds, ins),
            router
        );

        OpenPuntStorage.MatchedSwap memory rep =
            _decodeSingleSwapState(vm.getRecordedLogs(), OpenPuntStorage.PositionReportStarted.selector, sid);

        assertEq(punt.swapIdToReportId(sid), reportIdBefore, "the retry should take the id the failure did not consume");
        assertEq(punt.swaps(sid), keccak256(abi.encode(live)), "the retry must preserve the active hash");
        // `close()` already escrowed CLOSE_EXEC_COMP against this position, and the report adds its
        // own on top, so the report id carries the sum. The helper funded only the report's share.
        assertEq(
            punt.executionGasComp(reportIdBefore),
            uint256(CLOSE_EXEC_COMP) + REPORT_EXEC_COMP,
            "the compensation must accumulate the close and report shares"
        );
    }

    // ────────────────────────────────────────────────────────────────────
    //  retryability
    // ────────────────────────────────────────────────────────────────────

    /// @dev After a late failure, the identical call succeeds once the missing approval is granted.
    ///      Nothing — report id, allowance, hash, or funding — was consumed by the failed attempt.
    function test_theSameCallSucceedsAfterALateFailure() public {
        Proposal memory p = _propose();
        _armInternal();

        address party = address(0x4002);
        uint256 reportIdBefore = oracle.nextReportId();

        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("InsufficientInternalBalance()")));
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            party,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true),
            router
        );

        assertEq(oracle.nextReportId(), reportIdBefore, "a report id leaked on the failed attempt");

        _approveMatcherLegs(party, address(tokenA), address(tokenB));

        vm.recordLogs();
        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            party,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, true),
            router
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 reportId, OpenPuntStorage.MatchedSwap memory s) = _decodeSwapMatched(logs, p.swapId);

        assertEq(s.matcher, party, "the retry must record the designated party");
        assertEq(reportId, reportIdBefore, "the retry should take the report id the failure did not consume");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(s)), "the retry must store the emitted state");
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    /// @dev Real internal balances and finite allowances on the caller, so the rollback assertions
    ///      cover the internal ledger and not merely wallets.
    OpenPuntStorage.CloseDutch internal _dutch;

    /// @dev Creates a live position with a close auction and a genuine liquidation heartbeat.
    ///
    ///      Heartbeat mode is off in the default proposal (`liquidationHeartbeatMax == 0`), so it is
    ///      enabled here and an actual unbound heartbeat is recorded through the real permissionless
    ///      entry point. Without that, the heartbeat rollback assertions would compare (0, 0) to
    ///      (0, 0) and prove nothing.
    function _openWithLiveDutch()
        internal
        returns (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre)
    {
        OpenPuntStorage.ProposedSwap memory ps = _defaultProposedSwap();
        // propose() requires min >= 30s, max <= 5 minutes, and max > min.
        ps.liquidationHeartbeatMin = 60;
        ps.liquidationHeartbeatMax = 300;

        Proposal memory p = _proposeWith(ps, _defaultMatcherPreimage(), swapper);
        pre = p.preimage;
        Matched memory mt = _matchSwap(p);
        _advanceToSettlementEligibility();
        live = _executeOpening(mt, executor);
        sid = p.swapId;
        // Snapshot the compensation slot the attempted report would allocate.
        _liveReportId = oracle.nextReportId();

        // A real heartbeat. `liquidationHeartbeat` refuses a zero gas price, so one is set.
        vm.txGasPrice(1 gwei);
        vm.prank(outsider);
        punt.liquidationHeartbeat(sid, live);

        _dutch = _close(sid, live, CLOSE_EXEC_COMP);
        // `close()` on a position with no live report starts a future auction without rewriting the
        // stored MatchedSwap, so `live` is still current.
        live = _currentState(sid, live);
    }

    /// @dev `close()` rewrites the stored swap, so the caller needs the post-close struct. It is
    ///      recovered from the emitted auction event rather than reconstructed by hand.
    function _currentState(uint256 sid, OpenPuntStorage.MatchedSwap memory prior)
        internal
        view
        returns (OpenPuntStorage.MatchedSwap memory)
    {
        OpenPuntStorage.MatchedSwap memory s = prior;
        if (punt.swaps(sid) == keccak256(abi.encode(s))) return s;
        revert("OpenPuntHelperBase: post-close state not reconstructed");
    }

    function _armInternal() internal {
        _depositInternal(funder, address(tokenA), 5e18);
        _approveInternalToHelper(funder, address(tokenA), 4e18);
        _depositInternal(funder, address(tokenC), 3000e18);
        _approveInternalToHelper(funder, address(tokenC), 2000e18);
    }
}
