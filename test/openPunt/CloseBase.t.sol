// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ActivePositionBase.t.sol";

/**
 * @notice Shared fixture for the close() / report() / cancelCloseAuction() state machine.
 *
 * @dev Positions here are deliberately boring economically — flat price, zero funding, zero
 *      fulfillment fee — so that every assertion is about state transitions, reward ownership,
 *      compensation routing and ordering rather than accounting. The accounting matrix lives
 *      in ActivePositionAccounting / ActivePositionCaps.
 *
 *      Every active position is reached through the real lifecycle
 *      propose -> matchSwap -> settlement eligibility -> execute, and every struct handed to a
 *      later call is decoded from the emitting transaction's own logs.
 */
abstract contract CloseBase is ActivePositionBase {
    // Dutch curve C1: 10e18 x1.5 per 60s round, ceiling 100e18, 10 rounds.
    //   r0 10e18  r1 15e18  r2 22.5e18  r3 33.75e18  r4 50.625e18  r5 75.9375e18
    //   r6 113.90625e18 >= ceiling -> 100e18
    uint128 internal constant DUTCH_START = 10e18;
    uint128 internal constant DUTCH_MAX = 100e18;
    uint16 internal constant DUTCH_GROWTH = 15_000;
    uint16 internal constant DUTCH_ROUNDS = 10;
    uint24 internal constant DUTCH_ROUND_LEN = 60;

    uint128 internal constant CLOSE_COMP = 0.003 ether;

    function _setUpClose() internal {
        _setUpAccounting();
        // the swapper funds Dutch rewards and ETH-collateral positions from here
        collat.mint(swapper, 1_000_000e18);
        vm.deal(swapper, 100_000 ether);
        vm.deal(matcher, 100_000 ether);
        vm.deal(reporter, 100 ether);
        vm.deal(adapter, 100 ether);

        // swapper's internal ledgers, for internally funded auctions and positions
        vm.startPrank(swapper);
        collat.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(collat), 100_000e18, swapper);
        oracle.deposit{value: 20_000 ether}(address(0), 20_000e18, swapper);
        oracle.approveInternal(address(punt), address(collat), type(uint256).max);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();

        // matcher needs internal ETH when the collateral token is ETH
        vm.startPrank(matcher);
        oracle.deposit{value: 20_000 ether}(address(0), 20_000e18, matcher);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();
    }

    // ── position shapes ─────────────────────────────────────────────────

    /// @dev Flat, fee-free, funding-free position. `ethCollat` / `internalPos` select the
    ///      position funding mode, which also governs the terminal payout route.
    function _positionCfg(bool ethCollat, bool internalPos)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_LONG; // pre-maturity, so only an intent can close it
        if (ethCollat) s.collatToken = address(0);
        s.useInternalBalances = internalPos;
    }

    /// @dev Active ERC20-collateral position, externally funded, with no live report.
    function _openIdle()
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _positionCfg(false, false);
        (swapId, active, p) = _openAccounting(s, m);
        assertEq(punt.swapIdToReportId(swapId), 0, "fixture: idle position");
        assertTrue(active.active, "fixture: active position");
    }

    // ── Dutch structs ───────────────────────────────────────────────────

    /// @dev Caller-side Dutch input: only the fields a caller is meant to choose.
    function _dutchInput() internal view returns (OpenPuntStorage.CloseDutch memory d) {
        d.maxReward = DUTCH_MAX;
        d.startingReward = DUTCH_START;
        d.growthRate = DUTCH_GROWTH;
        d.maxRounds = DUTCH_ROUNDS;
        d.roundLength = DUTCH_ROUND_LEN;
        d.expiration = uint48(vm.getBlockTimestamp() + 30 minutes);
        // swapper / collatToken / swapId / start / useInternalBalances deliberately left zero
    }

    /// @dev The canonical struct the contract builds from `input`, applying every override.
    ///      Written out here rather than read back from the contract.
    function _canonicalDutch(
        OpenPuntStorage.CloseDutch memory input,
        uint256 swapId,
        address collatToken,
        bool auctionUsesInternal,
        uint48 startTs
    ) internal view returns (OpenPuntStorage.CloseDutch memory d) {
        d = _copy(input);
        d.swapper = swapper;
        d.collatToken = collatToken;
        d.swapId = swapId;
        d.useInternalBalances = auctionUsesInternal;
        d.start = startTs;
    }

    // ── close() drivers ─────────────────────────────────────────────────

    function _closeValue(OpenPuntStorage.CloseDutch memory d, address collatToken, bool auctionInternal, uint128 comp)
        internal
        pure
        returns (uint256)
    {
        if (auctionInternal) return 0;
        return collatToken == address(0) ? uint256(comp) + d.maxReward : uint256(comp);
    }

    /// @dev Opens a real close auction and returns the emitted (canonical) Dutch struct.
    function _startAuction(
        uint256 swapId,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.CloseDutch memory input,
        bool auctionInternal,
        uint128 comp
    ) internal returns (OpenPuntStorage.CloseDutch memory emitted) {
        uint256 value = _closeValue(input, active.collatToken, auctionInternal, comp);

        vm.recordLogs();
        vm.prank(swapper);
        punt.close{value: value}(
            swapId, input, active, auctionInternal, _emptyPermit2(), comp, _emptyOracleGame(), _emptyOracleHelper()
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.CloseAuctionStarted.selector, swapId);
        (OpenPuntStorage.MatchedSwap memory checkpoint,,) =
            abi.decode(l.data, (OpenPuntStorage.MatchedSwap, OpenPuntStorage.CloseDutch, uint128));
        assertEq(
            keccak256(abi.encode(checkpoint)), keccak256(abi.encode(active)), "close event refreshes active preimage"
        );
        emitted = _decodeCloseAuctionStarted(logs, swapId);
    }

    /// @dev The standard fixture auction: ERC20 collateral, externally funded.
    function _startDefaultAuction(uint256 swapId, OpenPuntStorage.MatchedSwap memory active)
        internal
        returns (OpenPuntStorage.CloseDutch memory emitted)
    {
        return _startAuction(swapId, active, _dutchInput(), false, CLOSE_COMP);
    }

    // ── report() drivers ────────────────────────────────────────────────

    /// @dev Real routed report carrying an explicit Dutch preimage (or the zero sentinel).
    function _reportWithDutch(
        uint256 swapId,
        OpenPuntStorage.CloseDutch memory d,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.MatcherPreimage memory preimage,
        address who,
        uint128 comp
    ) internal returns (Matched memory mt) {
        return _reportOnPositionWithAmounts(swapId, d, active, preimage, who, comp, A1, A2_OPEN);
    }

    function _executeReport(uint256 swapId, Matched memory mt, address who) internal returns (Vm.Log[] memory logs) {
        _advanceToSettlementEligibility();
        vm.recordLogs();
        vm.prank(who);
        puntLifecycle.execute(swapId, mt.swap, mt.game, mt.helper, false);
        logs = vm.getRecordedLogs();
    }

    // ── snapshots ───────────────────────────────────────────────────────

    struct Snap {
        bytes32 positionHash;
        bytes32 dutchHash;
        uint128 pendingComp;
        uint48 intentDeadlineBlock;
        bool intent;
        uint256 puntEth;
        uint256 puntCollatInt;
        uint256 puntEthInt;
        uint256 swapperCollatExt;
        uint256 swapperCollatInt;
        uint256 swapperEth;
        uint256 swapperEthInt;
        uint256 permitCalls;
    }

    function _storedAuction(uint256 swapId) internal view returns (OpenPuntStorage.StoredDutch memory a) {
        (
            a.maxReward,
            a.startingReward,
            a.executionComp,
            a.start,
            a.roundLength,
            a.expirationDuration,
            a.growthRate,
            a.maxRounds,
            a.useInternalBalances
        ) = punt.closeAuctions(swapId);
    }

    function _snap(uint256 swapId, address collatToken) internal view returns (Snap memory s) {
        OpenPuntStorage.StoredDutch memory auction = _storedAuction(swapId);
        s.positionHash = punt.swaps(swapId);
        s.dutchHash = _storedDutchState(swapId);
        s.pendingComp = auction.executionComp;
        s.intentDeadlineBlock = punt.closeRequestBlock(swapId);
        s.intent = s.intentDeadlineBlock != 0;
        s.puntEth = address(punt).balance;
        s.puntCollatInt = oracle.tokenHolder(address(punt), collatToken);
        s.puntEthInt = oracle.tokenHolder(address(punt), address(0));
        s.swapperCollatExt = collat.balanceOf(swapper);
        s.swapperCollatInt = oracle.tokenHolder(swapper, address(collat));
        s.swapperEth = swapper.balance;
        s.swapperEthInt = oracle.tokenHolder(swapper, address(0));
        s.permitCalls = _permit2().callCount();
    }

    function _assertUnchanged(Snap memory before, uint256 swapId, address collatToken, string memory what)
        internal
        view
    {
        OpenPuntStorage.StoredDutch memory auction = _storedAuction(swapId);
        uint128 pending = auction.executionComp;
        uint48 deadlineBlock = punt.closeRequestBlock(swapId);
        bool intent = deadlineBlock != 0;
        assertEq(punt.swaps(swapId), before.positionHash, string.concat(what, ": position hash"));
        assertEq(_storedDutchState(swapId), before.dutchHash, string.concat(what, ": dutch state"));
        assertEq(pending, before.pendingComp, string.concat(what, ": pending comp"));
        assertEq(deadlineBlock, before.intentDeadlineBlock, string.concat(what, ": intent deadline block"));
        assertEq(intent, before.intent, string.concat(what, ": close intent"));
        assertEq(address(punt).balance, before.puntEth, string.concat(what, ": core raw ETH"));
        assertEq(
            oracle.tokenHolder(address(punt), collatToken), before.puntCollatInt, string.concat(what, ": core collat")
        );
        assertEq(
            oracle.tokenHolder(address(punt), address(0)), before.puntEthInt, string.concat(what, ": core internal ETH")
        );
        assertEq(collat.balanceOf(swapper), before.swapperCollatExt, string.concat(what, ": swapper external collat"));
        assertEq(
            oracle.tokenHolder(swapper, address(collat)),
            before.swapperCollatInt,
            string.concat(what, ": swapper internal collat")
        );
        assertEq(swapper.balance, before.swapperEth, string.concat(what, ": swapper raw ETH"));
        assertEq(
            oracle.tokenHolder(swapper, address(0)), before.swapperEthInt, string.concat(what, ": swapper internal ETH")
        );
        assertEq(_permit2().callCount(), before.permitCalls, string.concat(what, ": Permit2 untouched"));
    }

    // ── event readers ───────────────────────────────────────────────────

    function _readCloseAuctionStarted(Vm.Log[] memory logs, uint256 swapId)
        internal
        view
        returns (OpenPuntStorage.CloseDutch memory d, uint128 comp, bytes32 dutchHashTopic)
    {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.CloseAuctionStarted.selector, swapId);
        dutchHashTopic = l.topics[2];
        (, d, comp) = abi.decode(l.data, (OpenPuntStorage.MatchedSwap, OpenPuntStorage.CloseDutch, uint128));
    }

    function _readCloseIntentSet(Vm.Log[] memory logs, uint256 swapId)
        internal
        view
        returns (uint256 reportIdTopic, uint128 compAdded)
    {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.CloseIntentSet.selector, swapId);
        reportIdTopic = uint256(l.topics[2]);
        compAdded = abi.decode(l.data, (uint128));
    }
}
