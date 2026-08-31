// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {OpenPuntLifecycle} from "../../src/levered-swaps/OpenPuntLifecycle.sol";
import {openPunt} from "../../src/levered-swaps/OpenPunt.sol";
import {PuntErrors} from "../../src/libraries/PuntErrors.sol";

import {PackedDecoder} from "../utils/PackedDecoder.sol";
import {MintableERC20} from "./util/MintableERC20.sol";
import {RecordingPermit2} from "./util/RecordingPermit2.sol";

/**
 * @notice Shared fixture for the OpenPunt suite.
 *
 * @dev Hard rules obeyed by every helper here:
 *        - no vm.store / vm.mockCall against protocol contracts
 *        - no harnesses exposing internals
 *        - no synthesised hashes, reports, positions, auctions or heartbeats
 *      Every piece of protocol state is produced by a real call to a deployed
 *      contract, and every struct handed back to callers is reconstructed from
 *      the transaction's own logs.
 *
 *      Routed lifecycle calls go through `puntLifecycle`, which is the *core*
 *      address wearing the module's ABI. `lifecycleModule` is the raw module
 *      and is only ever called directly by negative isolation tests.
 */
abstract contract OpenPuntBase is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ── deployed system ─────────────────────────────────────────────────
    OpenOracle internal oracle;
    OpenPuntLifecycle internal lifecycleModule; // raw module (negative tests only)
    openPunt internal punt; // core / fund holder
    OpenPuntLifecycle internal puntLifecycle; // core address, module ABI

    MintableERC20 internal collat;
    MintableERC20 internal tokenA; // oracleToken1
    MintableERC20 internal tokenB; // oracleToken2

    // ── actors ──────────────────────────────────────────────────────────
    address internal swapper = address(0x1001);
    address internal matcher = address(0x1002);
    address internal reporter = address(0x1003);
    address internal executor = address(0x1004); // opening executor
    address internal closeExecutor = address(0x1005); // closing executor
    address internal outsider = address(0x1006);
    address internal adapter = address(0x1007); // funds a match on the matcher's behalf
    address internal settler = address(0x1008); // settles oracle games directly

    // ── canonical position parameters ───────────────────────────────────
    uint128 internal constant INITIAL_MARGIN_SWAPPER = 1000e18;
    uint128 internal constant INITIAL_MARGIN_MATCHER = 1000e18;
    uint128 internal constant MAINTENANCE_MARGIN = 200e18;
    uint128 internal constant NOTIONAL = 10_000e18;

    // fulfillment-fee auction (auctionFunding == false)
    int32 internal constant FEE_AUCTION_START = 10_000; // 0.1% of notional
    int32 internal constant FEE_AUCTION_END = 20_000; // 0.2% of notional
    uint16 internal constant FEE_GROWTH_RATE = 15_000;
    uint16 internal constant FEE_MAX_ROUNDS = 10;
    uint24 internal constant FEE_ROUND_LENGTH = 60;
    int32 internal constant FUNDING_RATE = 0;

    // oracle game
    uint128 internal constant INITIAL_LIQUIDITY = 1e18;
    uint128 internal constant ESCALATION_HALT = 20e18;
    /// @dev OpenPunt creates its oracle games with `flags: 0`, so FLAG_TIME_TYPE is clear and the
    ///      game clock counts blocks: `settlementTime` and
    ///      `disputeDelay` are block counts, and the game's `reportTimestamp` holds a block number
    ///      while `lastReportOppoTime` holds the wall clock.
    ///
    ///      150 blocks at 2,000 ms/block is a 300-second wall-clock settlement window.
    uint48 internal constant SETTLEMENT_BLOCKS = 150;

    /// @dev The same window in wall-clock seconds: SETTLEMENT_BLOCKS * MS_PER_BLOCK / 1000.
    uint256 internal constant SETTLEMENT_SECONDS = 300;
    uint24 internal constant DISPUTE_DELAY = 5; // blocks, must be < SETTLEMENT_BLOCKS
    uint16 internal constant MULTIPLIER = 110;
    uint24 internal constant PROTOCOL_FEE = 0;
    uint128 internal constant AMOUNT2 = 2000e18; // price = 1e18 * 1e30 / 2000e18 = 5e26

    // protections / timing
    uint232 internal constant PRICE_TOLERATED = 5e26;
    uint24 internal constant TOLERANCE_RANGE = 1e6; // 10%
    /// @dev Base cadence: 2,000 ms per block, i.e. one block every two seconds.
    uint16 internal constant MS_PER_BLOCK = 2_000;
    /// @dev propose() requires maxGameTime * 1000 >= settlementDurationMilliseconds * 20, and the
    ///      settlement duration is SETTLEMENT_BLOCKS * MS_PER_BLOCK milliseconds. Derived from
    ///      the seconds form so the relationship survives a change to either constant.
    uint24 internal constant MAX_GAME_TIME = uint24(SETTLEMENT_SECONDS) * 20;
    uint16 internal constant MAX_EXECUTION_LATENCY = 3600;
    uint48 internal constant EXPIRATION_WINDOW = 1 hours; // duration at propose
    uint48 internal constant MATURITY_WINDOW = 7 days;

    // ETH compensations
    uint96 internal constant SETTLER_REWARD = 0.001 ether;
    uint96 internal constant MATCHER_GAS_COMP = 0.001 ether;
    uint96 internal constant OPEN_EXEC_COMP = 0.002 ether;
    uint128 internal constant CLOSE_EXEC_COMP = 0.003 ether; // funded at close()
    uint128 internal constant REPORT_EXEC_COMP = 0.0005 ether; // funded at report()

    // close Dutch auction (collatToken denominated)
    uint128 internal constant DUTCH_MAX_REWARD = 50e18;
    uint128 internal constant DUTCH_STARTING_REWARD = 10e18;
    uint24 internal constant DUTCH_ROUND_LENGTH = 60;
    uint16 internal constant DUTCH_GROWTH_RATE = 15_000;
    uint16 internal constant DUTCH_MAX_ROUNDS = 5;

    /// @dev Settlement eligibility is block-based: the oracle requires
    ///      blockNumber >= reportBlock + settlementTime(blocks). Advancing SETTLEMENT_SECONDS + 2
    ///      wall seconds produces SETTLEMENT_BLOCKS + 1 blocks at the fixture cadence, which clears
    ///      it by exactly one block. Even seconds so blocks land exactly on 1-per-2s.
    uint256 internal constant SETTLE_HOP_SECONDS = SETTLEMENT_SECONDS + 2;

    // ── setup ───────────────────────────────────────────────────────────

    function _deploySystem() internal {
        // `vm.etch` copies runtime code only, so the recorder keeps no constructor state.
        RecordingPermit2 permit2 = new RecordingPermit2();
        vm.etch(PERMIT2, address(permit2).code);

        oracle = new OpenOracle();
        lifecycleModule = new OpenPuntLifecycle(address(oracle));
        punt = new openPunt(address(oracle), address(lifecycleModule));
        puntLifecycle = OpenPuntLifecycle(address(punt));

        collat = new MintableERC20("Collateral", "COLL");
        tokenA = new MintableERC20("OracleTokenA", "OTA");
        tokenB = new MintableERC20("OracleTokenB", "OTB");
    }

    function _fundActors() internal {
        // start on a realistic clock so uint48 timestamps/blocks are non-degenerate
        vm.warp(1_700_000_000);
        vm.roll(20_000_000);

        collat.transfer(swapper, 5000e18);
        collat.transfer(matcher, 5000e18);

        tokenA.transfer(matcher, 100e18);
        tokenB.transfer(matcher, 100_000e18);
        tokenA.transfer(reporter, 100e18);
        tokenB.transfer(reporter, 100_000e18);

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(reporter, 10 ether);
        vm.deal(executor, 1 ether);
        vm.deal(closeExecutor, 1 ether);
        vm.deal(outsider, 1 ether);
        vm.deal(adapter, 10 ether);
        vm.deal(settler, 1 ether);
    }

    /// @dev Mints through the token's own `mint()` so extreme-boundary cases can be funded
    ///      without ever writing a balance slot directly.
    function _mintAndDeposit(MintableERC20 token, address who, uint128 amount) internal {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(token), amount, who);
        vm.stopPrank();
    }

    function _permit2() internal pure returns (RecordingPermit2) {
        return RecordingPermit2(PERMIT2);
    }

    /// @dev Swapper pays collateral in externally, so it only needs a Permit2 approval.
    function _armSwapper() internal {
        vm.prank(swapper);
        collat.approve(PERMIT2, type(uint256).max);
    }

    /// @dev Matcher posts margin + both oracle legs from oracle internal balances.
    function _armMatcher() internal {
        vm.startPrank(matcher);
        collat.approve(address(oracle), type(uint256).max);
        tokenA.approve(address(oracle), type(uint256).max);
        tokenB.approve(address(oracle), type(uint256).max);

        // headroom for tests that open more than one position in a single case
        oracle.deposit(address(collat), 3 * INITIAL_MARGIN_MATCHER, matcher);
        oracle.deposit(address(tokenA), 50e18, matcher);
        oracle.deposit(address(tokenB), 50_000e18, matcher);

        oracle.approveInternal(address(punt), address(collat), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Reporter funds the closing oracle game legs plus its own execution comp.
    function _armReporter() internal {
        vm.startPrank(reporter);
        tokenA.approve(address(oracle), type(uint256).max);
        tokenB.approve(address(oracle), type(uint256).max);

        oracle.deposit(address(tokenA), 50e18, reporter);
        oracle.deposit(address(tokenB), 50_000e18, reporter);
        oracle.deposit{value: 0.01 ether}(address(0), 0.01 ether, reporter);

        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();
    }

    function _setUpAll() internal {
        _deploySystem();
        _fundActors();
        _armSwapper();
        _armMatcher();
        _armReporter();
    }

    // ── canonical struct builders ───────────────────────────────────────

    function _defaultProposedSwap() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s.swapper = address(0); // contract override
        s.collatToken = address(collat);
        s.oracleToken1 = address(tokenA);
        s.oracleToken2 = address(tokenB);
        s.initialMarginSwapper = INITIAL_MARGIN_SWAPPER;
        s.initialMarginMatcher = INITIAL_MARGIN_MATCHER;
        s.maintenanceMarginSwapper = MAINTENANCE_MARGIN;
        s.notional = NOTIONAL;
        s.isLong = true;
        s.fundingRate = FUNDING_RATE;
        s.fulfillmentFee = 0; // auctioned
        s.auctionFunding = false;
        s.priceTolerated = PRICE_TOLERATED;
        s.toleranceRange = TOLERANCE_RANGE;
        s.millisecondsPerBlock = MS_PER_BLOCK;
        s.maxGameTime = MAX_GAME_TIME;
        s.maxExecutionLatency = MAX_EXECUTION_LATENCY;
        s.liquidationHeartbeatMin = 0;
        s.liquidationHeartbeatMax = 0;
        s.expiration = EXPIRATION_WINDOW; // duration; contract override to absolute
        s.maturityWindow = MATURITY_WINDOW;
        s.settlerReward = SETTLER_REWARD;
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.openExecutionComp = OPEN_EXEC_COMP;
        s.useInternalBalances = false;
    }

    /// @dev Per-test dispute delay. Set this before proposing; it flows into the real
    ///      MatcherPreimage that propose() hash-commits, so the value under test is the
    ///      one the position was genuinely created with — never patched in afterwards.
    uint24 internal disputeDelayParam = DISPUTE_DELAY;

    function _defaultMatcherPreimage() internal view returns (OpenPuntStorage.MatcherPreimage memory m) {
        m.initialLiquidity = INITIAL_LIQUIDITY;
        m.escalationHalt = ESCALATION_HALT;
        m.settlementTime = SETTLEMENT_BLOCKS;
        m.disputeDelay = disputeDelayParam;
        m.multiplier = MULTIPLIER;
        m.protocolFee = PROTOCOL_FEE;
        m.auctionStart = FEE_AUCTION_START;
        m.auctionEnd = FEE_AUCTION_END;
        m.roundLength = FEE_ROUND_LENGTH;
        m.maxRounds = FEE_MAX_ROUNDS;
        m.growthRate = FEE_GROWTH_RATE;
        m.startFulfillFeeIncrease = 0; // contract override
    }

    function _defaultCloseDutch() internal view returns (OpenPuntStorage.CloseDutch memory d) {
        d.swapper = address(0); // contract override
        d.collatToken = address(0); // contract override
        d.swapId = 0; // contract override
        d.maxReward = DUTCH_MAX_REWARD;
        d.startingReward = DUTCH_STARTING_REWARD;
        d.roundLength = DUTCH_ROUND_LENGTH;
        d.growthRate = DUTCH_GROWTH_RATE;
        d.maxRounds = DUTCH_MAX_ROUNDS;
        d.start = 0; // contract override
        d.expiration = uint48(vm.getBlockTimestamp() + 30 minutes);
        d.useInternalBalances = false; // contract override
    }

    function _emptyPermit2() internal pure returns (OpenPuntStorage.Permit2Params memory) {
        return OpenPuntStorage.Permit2Params({nonce: 0, deadline: type(uint256).max, signature: bytes("")});
    }

    function _emptyOracleGame() internal pure returns (IOpenOracle2.OracleGame memory game) {}

    function _emptyOracleHelper() internal pure returns (IOpenOracle2.PreimageHelper memory helper) {}

    function _noTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory) {
        return IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
    }

    // ── real-call flow helpers (no state synthesis) ─────────────────────

    struct Proposal {
        uint256 swapId;
        OpenPuntStorage.ProposedSwap swap; // as emitted (post-override)
        OpenPuntStorage.MatcherPreimage preimage; // as emitted (post-override)
    }

    struct Matched {
        uint256 swapId;
        uint256 reportId;
        OpenPuntStorage.MatchedSwap swap; // as emitted
        IOpenOracle2.OracleGame game; // from ReportSubmitted
        IOpenOracle2.PreimageHelper helper; // from ReportSubmitted
    }

    function _propose() internal returns (Proposal memory p) {
        return _proposeWith(_defaultProposedSwap(), _defaultMatcherPreimage(), swapper);
    }

    function _proposeWith(OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m, address from)
        internal
        returns (Proposal memory p)
    {
        vm.recordLogs();
        vm.prank(from);
        p.swapId = punt.propose{value: _correctMsgValue(s)}(s, m, _emptyPermit2());
        (p.swap, p.preimage) = _decodeSwapProposed(vm.getRecordedLogs(), p.swapId);
    }

    function _matchSwap(Proposal memory p) internal returns (Matched memory mt) {
        return _matchSwapWith(p, AMOUNT2, matcher);
    }

    function _matchSwapWith(Proposal memory p, uint128 amount2, address who) internal returns (Matched memory mt) {
        return _matchSwapFrom(p, amount2, who, who);
    }

    /// @dev Adapter-shaped match: `funder` is msg.sender, `designatedMatcher` is the recorded
    ///      counterparty and the oracle game's reporter.
    function _matchSwapFrom(Proposal memory p, uint128 amount2, address funder, address designatedMatcher)
        internal
        returns (Matched memory mt)
    {
        vm.recordLogs();
        vm.prank(funder);
        punt.matchSwap(p.swapId, amount2, p.swap, p.preimage, _noTiming(), designatedMatcher);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        mt.swapId = p.swapId;
        (mt.reportId, mt.swap) = _decodeSwapMatched(logs, p.swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);
    }

    /// @dev Advances exactly one settlement window at the configured block cadence.
    /// @dev Wall-clock seconds corresponding to a block count at the fixture cadence. Tests that
    ///      need to outlast a block-denominated oracle window must convert, because advancing a
    ///      need to outlast a block-denominated window must convert blocks to seconds explicitly.
    function _secondsForBlocks(uint256 blocks) internal pure returns (uint256) {
        return blocks * uint256(MS_PER_BLOCK) / 1000;
    }

    function _advanceToSettlementEligibility() internal {
        _advanceChain(SETTLE_HOP_SECONDS);
    }

    /// @dev Keeps timestamp/block growth consistent with MS_PER_BLOCK (2,000 ms = 1 block / 2s).
    ///
    ///      Tests must read the clock via `vm.getBlockTimestamp()` / `vm.getBlockNumber()`
    ///      rather than `block.timestamp` / `block.number`. Under via-IR the optimizer treats
    ///      TIMESTAMP/NUMBER as transaction-invariant and common-subexpression-eliminates
    ///      repeated reads, which silently ignores an intervening `vm.warp` / `vm.roll`.
    ///      The cheatcode getters are external calls and cannot be folded away.
    function _advanceChain(uint256 secs) internal {
        require(secs % 2 == 0, "OpenPuntBase: hop must be even at 0.5 blocks/s");
        _advanceTimeAndBlocks(secs, secs / 2);
    }

    /// @dev Decoupled clock advance for tests that deliberately break the block cadence.
    function _advanceTimeAndBlocks(uint256 secs, uint256 blocks) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + blocks);
    }

    /// @dev Settles an oracle game directly, outside OpenPunt.
    function _settleDirect(Matched memory mt, address who) internal {
        vm.prank(who);
        IOpenOracle2(address(oracle)).settle(mt.reportId, mt.game, mt.helper);
    }

    /// @dev Opening execution routed through the core. Returns the emitted active position.
    function _executeOpening(Matched memory mt, address who)
        internal
        returns (OpenPuntStorage.MatchedSwap memory opened)
    {
        vm.recordLogs();
        vm.prank(who);
        puntLifecycle.execute(mt.swapId, mt.swap, mt.game, mt.helper, 0);
        opened = _decodeSingleSwapState(vm.getRecordedLogs(), OpenPuntStorage.PositionOpened.selector, mt.swapId);
    }

    /// @dev propose -> matchSwap -> wait -> execute, all through real core calls.
    function _openPosition()
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p)
    {
        p = _propose();
        Matched memory mt = _matchSwap(p);
        _advanceToSettlementEligibility();
        active = _executeOpening(mt, executor);
        swapId = p.swapId;
    }

    function _close(uint256 swapId, OpenPuntStorage.MatchedSwap memory active, uint128 altGasCompExec)
        internal
        returns (OpenPuntStorage.CloseDutch memory emittedDutch)
    {
        OpenPuntStorage.CloseDutch memory d = _defaultCloseDutch();
        vm.recordLogs();
        vm.prank(swapper);
        punt.close{value: altGasCompExec}(
            swapId, d, active, false, _emptyPermit2(), altGasCompExec, _emptyOracleGame(), _emptyOracleHelper(), 0
        );
        emittedDutch = _decodeCloseAuctionStarted(vm.getRecordedLogs(), swapId);
    }

    function _reportOnPosition(
        uint256 swapId,
        OpenPuntStorage.CloseDutch memory d,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.MatcherPreimage memory preimage,
        address who,
        uint128 altGasCompExec
    ) internal returns (Matched memory mt) {
        return _reportOnPositionWithAmount1(swapId, d, active, preimage, who, altGasCompExec, INITIAL_LIQUIDITY);
    }

    /// @dev Same real routed call, with the token1 liquidity supplied by the caller.
    function _reportOnPositionWithAmount1(
        uint256 swapId,
        OpenPuntStorage.CloseDutch memory d,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.MatcherPreimage memory preimage,
        address who,
        uint128 altGasCompExec,
        uint128 amount1
    ) internal returns (Matched memory mt) {
        return _reportOnPositionWithAmounts(swapId, d, active, preimage, who, altGasCompExec, amount1, AMOUNT2);
    }

    /// @dev Fully parameterised routed report: both closing oracle legs supplied by the caller.
    function _reportOnPositionWithAmounts(
        uint256 swapId,
        OpenPuntStorage.CloseDutch memory d,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.MatcherPreimage memory preimage,
        address who,
        uint128 altGasCompExec,
        uint128 amount1,
        uint128 amount2
    ) internal returns (Matched memory mt) {
        bytes32 expectedDutchHash = d.maxReward == 0 ? bytes32(0) : keccak256(abi.encode(d));
        vm.recordLogs();
        vm.prank(who);
        puntLifecycle.report(
            swapId, expectedDutchHash, active, preimage, _noTiming(), who, amount1, amount2, altGasCompExec
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        mt.swapId = swapId;
        mt.swap = _decodeSingleSwapState(logs, OpenPuntStorage.PositionReportStarted.selector, swapId);
        mt.reportId = punt.swapIdToReportId(swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);
        assertEq(mt.game.flags, 1 << 4, "active report stores settlement eligibility");
        assertEq(
            oracle.settlementEligibility(mt.reportId),
            mt.game.reportTimestamp + mt.game.settlementTime,
            "stored eligibility matches the submitted game"
        );
    }

    /// @dev Empty auction sentinel: reporting on a position that has no live close auction.
    function _noDutch() internal pure returns (OpenPuntStorage.CloseDutch memory d) {
        return d;
    }

    function _expectedDutchHash(OpenPuntStorage.CloseDutch memory d) internal pure returns (bytes32) {
        return d.maxReward == 0 ? bytes32(0) : keccak256(abi.encode(d));
    }

    function _storedAuctionRaw(uint256 swapId) internal view returns (OpenPuntStorage.StoredDutch memory a) {
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

    /// @dev Test-only identity for comparing the complete stored auction state.
    function _storedDutchState(uint256 swapId) internal view returns (bytes32) {
        OpenPuntStorage.StoredDutch memory a = _storedAuctionRaw(swapId);
        return a.maxReward == 0 ? bytes32(0) : keccak256(abi.encode(a));
    }

    function _storedAuctionHash(uint256 swapId, OpenPuntStorage.MatchedSwap memory active)
        internal
        view
        returns (bytes32)
    {
        OpenPuntStorage.StoredDutch memory stored = _storedAuctionRaw(swapId);
        if (stored.maxReward == 0) return bytes32(0);

        OpenPuntStorage.CloseDutch memory d;
        d.swapper = active.swapper;
        d.collatToken = active.collatToken;
        d.swapId = swapId;
        d.maxReward = stored.maxReward;
        d.startingReward = stored.startingReward;
        d.roundLength = stored.roundLength;
        d.growthRate = stored.growthRate;
        d.maxRounds = stored.maxRounds;
        d.start = stored.start;
        d.expiration = stored.start + stored.expirationDuration;
        d.useInternalBalances = stored.useInternalBalances;
        return keccak256(abi.encode(d));
    }

    /// @dev Test-only projection of the stored auction compensation and close-request state.
    function _closeState(uint256 swapId) internal view returns (uint128, uint48, bool) {
        OpenPuntStorage.StoredDutch memory a = _storedAuctionRaw(swapId);
        uint48 requestedAt = punt.closeRequestBlock(swapId);
        return (a.executionComp, requestedAt, requestedAt != 0);
    }

    // ── log reconstruction (off-chain participant's view) ───────────────

    function _findLog(Vm.Log[] memory logs, address emitter, bytes32 topic0, uint256 indexedTopic1)
        internal
        pure
        returns (Vm.Log memory)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != topic0) continue;
            if (uint256(logs[i].topics[1]) != indexedTopic1) continue;
            return logs[i];
        }
        revert("OpenPuntBase: log not found");
    }

    /// @dev Boolean lookup for the payload-free bailout events
    ///      (SlippageBailout / ImpliedMillisecondsPerBlockBailout / MaxExecutionLatencyBailout).
    ///      These index `swapId` like every other position event, so it lives in topics[1].
    function _hasBailoutLog(Vm.Log[] memory logs, bytes32 topic0, uint256 swapId) internal view returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(punt)) continue;
            if (logs[i].topics.length < 2 || logs[i].topics[0] != topic0) continue;
            if (uint256(logs[i].topics[1]) == swapId) return true;
        }
        return false;
    }

    function _decodeSwapProposed(Vm.Log[] memory logs, uint256 swapId)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.SwapProposed.selector, swapId);
        assertEq(l.topics.length, 3, "SwapProposed indexes swapId and swapper");
        (s, m) = abi.decode(l.data, (OpenPuntStorage.ProposedSwap, OpenPuntStorage.MatcherPreimage));
        assertEq(address(uint160(uint256(l.topics[2]))), s.swapper, "indexed swapper matches proposal payload");
    }

    function _decodeSwapMatched(Vm.Log[] memory logs, uint256 swapId)
        internal
        view
        returns (uint256 reportId, OpenPuntStorage.MatchedSwap memory s)
    {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.SwapMatched.selector, swapId);
        reportId = uint256(l.topics[2]);
        s = abi.decode(l.data, (OpenPuntStorage.MatchedSwap));
    }

    /// @dev Works for any `(uint256 indexed swapId, ..., MatchedSwap)` event whose only
    ///      non-indexed member is the position struct.
    function _decodeSingleSwapState(Vm.Log[] memory logs, bytes32 topic0, uint256 swapId)
        internal
        view
        returns (OpenPuntStorage.MatchedSwap memory s)
    {
        Vm.Log memory l = _findLog(logs, address(punt), topic0, swapId);
        s = abi.decode(l.data, (OpenPuntStorage.MatchedSwap));
    }

    function _decodeCloseAuctionStarted(Vm.Log[] memory logs, uint256 swapId)
        internal
        view
        returns (OpenPuntStorage.CloseDutch memory d)
    {
        Vm.Log memory l = _findLog(logs, address(punt), OpenPuntStorage.CloseAuctionStarted.selector, swapId);
        (, d,) = abi.decode(l.data, (OpenPuntStorage.MatchedSwap, OpenPuntStorage.CloseDutch, uint128));
    }

    /// @dev Rebuilds the oracle preimage from the raw packed ReportSubmitted payload.
    ///      Offsets live in PackedDecoder and mirror OpenOracleSlim._packMem.
    function _decodeReportSubmitted(Vm.Log[] memory logs, uint256 reportId)
        internal
        view
        returns (IOpenOracle2.OracleGame memory g, IOpenOracle2.PreimageHelper memory h)
    {
        Vm.Log memory l = _findLog(logs, address(oracle), OpenOracle.ReportSubmitted.selector, reportId);
        g = PackedDecoder.decodeOracleGame(l.data);
        h = PackedDecoder.decodeHelperTail(l.data, reportId);
    }

    // ── independent accounting helpers ──────────────────────────────────

    /// @notice Oracle internal balance net of the virtual one-unit sentinel.
    /// @dev Deliberately re-derived here rather than imported from production code.
    function _spendable(address holder, address token) internal view returns (uint256) {
        uint256 raw = oracle.tokenHolder(holder, token);
        return raw == 0 ? 0 : raw - 1;
    }

    // ── proposal accept/reject harness ──────────────────────────────────

    /// @dev msg.value the contract will demand for this configuration. This is calldata
    ///      construction, not an expected economic result.
    function _correctMsgValue(OpenPuntStorage.ProposedSwap memory s) internal pure returns (uint256) {
        uint256 extra = uint256(s.matcherGasComp) + uint256(s.settlerReward) + uint256(s.openExecutionComp);
        bool isEth = s.collatToken == address(0);
        return (isEth && !s.useInternalBalances) ? extra + uint256(s.initialMarginSwapper) : extra;
    }

    function _proposeOk(
        OpenPuntStorage.ProposedSwap memory s,
        OpenPuntStorage.MatcherPreimage memory m,
        string memory what
    ) internal returns (uint256 swapId) {
        uint256 idBefore = punt.nextSwapId();

        vm.recordLogs();
        vm.prank(swapper);
        swapId = punt.propose{value: _correctMsgValue(s)}(s, m, _emptyPermit2());

        assertEq(swapId, idBefore, string.concat(what, ": swapId sequence"));
        assertEq(punt.nextSwapId(), idBefore + 1, string.concat(what, ": nextSwapId advanced"));
        assertTrue(punt.swaps(swapId) != bytes32(0), string.concat(what, ": swap stored"));

        (OpenPuntStorage.ProposedSwap memory es, OpenPuntStorage.MatcherPreimage memory em) =
            _decodeSwapProposed(vm.getRecordedLogs(), swapId);
        assertEq(
            punt.swaps(swapId), keccak256(abi.encode(es, em)), string.concat(what, ": event reconstructs stored hash")
        );
    }

    function _proposeBad(
        OpenPuntStorage.ProposedSwap memory s,
        OpenPuntStorage.MatcherPreimage memory m,
        bytes4 err,
        string memory what
    ) internal {
        _proposeBadWithValue(s, m, err, _correctMsgValue(s), what);
    }

    function _proposeBadWithValue(
        OpenPuntStorage.ProposedSwap memory s,
        OpenPuntStorage.MatcherPreimage memory m,
        bytes4 err,
        uint256 value,
        string memory what
    ) internal {
        uint256 idBefore = punt.nextSwapId();
        uint256 puntEth = address(punt).balance;
        uint256 puntCollatInternal = oracle.tokenHolder(address(punt), s.collatToken);
        uint256 swapperCollat = collat.balanceOf(swapper);
        uint256 swapperEthInternal = oracle.tokenHolder(swapper, address(0));
        uint256 permitCalls = _permit2().callCount();

        vm.prank(swapper);
        vm.expectRevert(err);
        punt.propose{value: value}(s, m, _emptyPermit2());

        assertEq(punt.nextSwapId(), idBefore, string.concat(what, ": nextSwapId unchanged"));
        assertEq(punt.swaps(idBefore), bytes32(0), string.concat(what, ": no stored swap hash"));
        assertEq(address(punt).balance, puntEth, string.concat(what, ": no ETH retained"));
        assertEq(
            oracle.tokenHolder(address(punt), s.collatToken),
            puntCollatInternal,
            string.concat(what, ": no collateral moved")
        );
        assertEq(collat.balanceOf(swapper), swapperCollat, string.concat(what, ": swapper collateral untouched"));
        assertEq(
            oracle.tokenHolder(swapper, address(0)), swapperEthInternal, string.concat(what, ": swapper ETH untouched")
        );
        assertEq(_permit2().callCount(), permitCalls, string.concat(what, ": validation never reached Permit2"));
    }

    // ── deep copies ─────────────────────────────────────────────────────
    //
    // `MatchedSwap memory b = a;` binds a second reference to the same memory struct,
    // so mutating `b` silently mutates `a`. Tests that perturb a decoded struct while
    // keeping the original as a control must copy through an encode/decode round trip.

    function _copy(OpenPuntStorage.MatchedSwap memory s) internal pure returns (OpenPuntStorage.MatchedSwap memory) {
        return abi.decode(abi.encode(s), (OpenPuntStorage.MatchedSwap));
    }

    function _copy(OpenPuntStorage.ProposedSwap memory s) internal pure returns (OpenPuntStorage.ProposedSwap memory) {
        return abi.decode(abi.encode(s), (OpenPuntStorage.ProposedSwap));
    }

    function _copy(OpenPuntStorage.MatcherPreimage memory m)
        internal
        pure
        returns (OpenPuntStorage.MatcherPreimage memory)
    {
        return abi.decode(abi.encode(m), (OpenPuntStorage.MatcherPreimage));
    }

    function _copy(OpenPuntStorage.CloseDutch memory d) internal pure returns (OpenPuntStorage.CloseDutch memory) {
        return abi.decode(abi.encode(d), (OpenPuntStorage.CloseDutch));
    }
}
