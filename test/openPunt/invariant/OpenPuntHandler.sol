// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {openPunt} from "../../../src/levered-swaps/OpenPunt.sol";
import {OpenPuntLifecycle} from "../../../src/levered-swaps/OpenPuntLifecycle.sol";
import {OpenPuntStorage} from "../../../src/levered-swaps/OpenPuntStorage.sol";
import {OpenOracle} from "../../../src/OpenOracleSlim.sol";
import {IOpenOracle2} from "../../../src/interfaces/IOpenOracle2.sol";
import {MintableERC20} from "../util/MintableERC20.sol";
import {PackedDecoder} from "../../utils/PackedDecoder.sol";

/**
 * @notice Randomized driver for OpenPunt, with an independently maintained shadow model.
 *
 * @dev Every state is reached through a genuine protocol call. There is no `vm.store`,
 *      no `vm.mockCall`, no fabricated oracle game and no synthesized position hash. After each
 *      successful transition the handler decodes emitted structs and stores those decoded
 *      values as the next call's inputs, so the model is fed by the protocol's own events rather
 *      than by locally invented structs.
 *
 *      A reverted action must leave the shadow model completely untouched: every action wraps its
 *      protocol call in try/catch and only mutates the model on the success path.
 *
 *      The campaign uses one canonical ERC20 collateral and ERC20 oracle legs. Deterministic tests
 *      covers the full ETH / internal / external / no-return matrix, and multiplying the stateful
 *      campaign across asset modes would add sequence length without adding reachable states.
 *
 *      The fulfillment fee is fixed at zero throughout, so the margin pool a position owns is
 *      exactly the two posted margins. This is a fixture simplification, not a protocol assumption:
 *      the protocol: it keeps the conservation model exact without cloning `calcFee` or the PnL
 *      arithmetic, which the deterministic suite already pins.
 */
contract OpenPuntHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ── system ──────────────────────────────────────────────────────────
    openPunt public immutable punt;
    OpenPuntLifecycle public immutable puntLifecycle;
    OpenOracle public immutable oracle;
    MintableERC20 public immutable collat;
    MintableERC20 public immutable tokenA;
    MintableERC20 public immutable tokenB;

    address public immutable swapper;
    address public immutable matcher;
    address public immutable reporter;
    address public immutable executor;
    address public immutable outsider;
    address public immutable settler;

    // ── fixture constants, mirroring the deterministic suite ────────────
    uint128 internal constant MARGIN_S = 1000e18;
    uint128 internal constant MARGIN_M = 1000e18;
    uint128 internal constant MAINT = 200e18;
    uint128 internal constant NOTIONAL = 1000e18;
    uint128 internal constant A1 = 1e18;
    uint128 internal constant A2_OPEN = 2000e18;
    uint232 internal constant PRICE_TOLERATED = 5e26;
    uint16 internal constant MS_PER_BLOCK = 2_000; // one block per two seconds
    uint48 internal constant SETTLE_BLOCKS = 2; // 4 wall-clock seconds
    uint256 internal constant SETTLE_SECONDS = 4;
    uint24 internal constant MAX_GAME_TIME = 6000;
    /// @dev 30 days is the protocol maximum. The campaign advances the clock aggressively, and a
    ///      one-hour window expires long before most sequences reach a match, which silently
    ///      starves every downstream phase. Outsider cancellation after expiry is still reachable
    ///      via the dedicated long-hop clock action.
    uint48 internal constant EXPIRATION_WINDOW = 30 days;
    uint96 internal constant SETTLER_REWARD = 0.001 ether;
    uint96 internal constant MATCHER_GAS_COMP = 0.001 ether;
    uint96 internal constant OPEN_EXEC_COMP = 0.002 ether;
    uint128 internal constant REPORT_COMP = 0.0005 ether;
    uint128 internal constant CLOSE_COMP = 0.003 ether;
    uint16 internal constant HB_MIN = 30;
    uint16 internal constant HB_MAX = 300;
    uint128 internal constant DUTCH_MAX = 50e18;
    uint128 internal constant DUTCH_START = 10e18;

    // ── phases ──────────────────────────────────────────────────────────
    enum Phase {
        None,
        Proposed,
        OpeningReport,
        ActiveIdle,
        ActiveCloseAuction,
        ActiveReport,
        Finalized
    }

    /// @dev absent / live / consumed / cancelled
    enum DutchStatus {
        Absent,
        Live,
        Consumed,
        Cancelled
    }

    struct Pos {
        Phase phase;
        OpenPuntStorage.ProposedSwap proposed;
        OpenPuntStorage.MatcherPreimage preimage;
        OpenPuntStorage.MatchedSwap matched;
        uint256 reportId;
        IOpenOracle2.OracleGame game;
        IOpenOracle2.PreimageHelper helper;
        bool settledDirectly;
        bool closeIntent; // true while a close request is registered
        uint48 closeRequestBlock;
        OpenPuntStorage.CloseDutch dutch;
        bytes32 dutchHash;
        DutchStatus dutchStatus;
        uint128 pendingComp; // funded, still in the stored auction
        uint128 assignedComp; // funded, migrated to the current report
        uint128 hbReportId;
        uint48 hbTimestamp;
        bool hbPreserved; // survived an unauthorized liquidation
        uint256 marginPool; // collateral the core owes this position
        uint128 dutchHeld; // collateral the core holds for this position's auction
        uint256 owedToSwapper;
        uint256 owedToMatcher;
        uint256 preTerminalPool;
        bool paidOut;
    }

    uint256[] public ids;
    mapping(uint256 => Pos) internal pos;

    /// @dev The core's modeled collateral obligation: margins plus Dutch rewards it still holds.
    uint256 public expectedCollat;

    // ── independent per-actor collateral book ───────────────────────────
    //
    // The matcher only ever touches collateral through margins and terminal payouts, so its net
    // movement is exactly reconcilable on its own. The swapper and reporter share the Dutch
    // reward — production splits it with `calcFee`, which the model must not clone — so those two
    // are reconciled jointly. `_actorCollat` counts both raw collateral and oracle credit, because
    // an externally funded auction returns its claimed remainder through push-or-credit while an
    // internally funded auction returns it directly to the oracle ledger.
    mapping(address => uint256) public collatBaseline;
    int256 public modelMatcherCollat;
    int256 public modelSwapperPlusReporterCollat;
    bool public baselinesTaken;

    // ── independent ETH books ───────────────────────────────────────────
    /// @dev Modeled `tempHolding` obligation per claimant, never read back from the contract.
    mapping(address => uint256) public modelTemp;
    /// @dev Raw ETH a proposed/opening position still reserves and owes to nobody yet.
    uint256 public reservedRawEth;

    /// @dev `totalOk` immediately after seeding, used to distinguish randomized work from setup.
    uint256 public seedOkBaseline;

    function snapshotBaselines(address[6] memory actors) external {
        require(!baselinesTaken, "baselines already taken");
        for (uint256 i = 0; i < actors.length; i++) {
            collatBaseline[actors[i]] = _actorCollat(actors[i]);
        }
        baselinesTaken = true;
    }

    function markSeedComplete() external {
        seedOkBaseline = totalOk;
    }

    /// @dev An actor's collateral across both places it can sit, which is one ledger's worth of
    ///      value in two forms rather than two different ledgers.
    function _actorCollat(address who) internal view returns (uint256) {
        uint256 internalBal = oracle.tokenHolder(who, address(collat));
        if (internalBal > 0) internalBal -= 1; // the oracle's per-slot sentinel
        return collat.balanceOf(who) + internalBal;
    }

    function actorCollat(address who) external view returns (uint256) {
        return _actorCollat(who);
    }

    // ── counters ────────────────────────────────────────────────────────
    mapping(bytes32 => uint256) public ok;
    mapping(bytes32 => uint256) public rejected;
    uint256 public totalOk;
    uint256 public totalRejected;

    /// @dev Last rejection payload, so a deterministic reachability test can report why an action
    ///      was refused instead of leaving it silently uncounted.
    bytes public lastRevertData;

    /**
     * @dev Model-versus-production disagreements, recorded rather than reverted.
     *
     *      A `require` inside a handler action is not a usable assertion: it reverts the handler
     *      call, and with `fail_on_revert = false` Foundry simply discards that call. A model check
     *      written that way is silently unenforced. These counters are asserted by an invariant
     *      instead, where a nonzero value fails the campaign.
     */
    uint256 public modelViolations;
    string public lastViolation;

    function _violation(bool condition, string memory what) internal {
        if (!condition) {
            modelViolations++;
            lastViolation = what;
        }
    }

    function _hit(string memory name) internal {
        ok[keccak256(bytes(name))]++;
        totalOk++;
    }

    function _miss(string memory name) internal {
        rejected[keccak256(bytes(name))]++;
        totalRejected++;
    }

    function count(string memory name) external view returns (uint256) {
        return ok[keccak256(bytes(name))];
    }

    function rejectedCount(string memory name) external view returns (uint256) {
        return rejected[keccak256(bytes(name))];
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function get(uint256 swapId) external view returns (Pos memory) {
        return pos[swapId];
    }

    function phaseOf(uint256 swapId) external view returns (Phase) {
        return pos[swapId].phase;
    }

    constructor(
        openPunt punt_,
        OpenOracle oracle_,
        MintableERC20 collat_,
        MintableERC20 tokenA_,
        MintableERC20 tokenB_,
        address[6] memory actors
    ) {
        punt = punt_;
        puntLifecycle = OpenPuntLifecycle(address(punt_));
        oracle = oracle_;
        collat = collat_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        swapper = actors[0];
        matcher = actors[1];
        reporter = actors[2];
        executor = actors[3];
        outsider = actors[4];
        settler = actors[5];
    }

    // ══════════════════════════════════════════════════════════════════
    //  Struct builders — the only locally constructed values, and only for
    //  arguments a caller genuinely chooses at propose time
    // ══════════════════════════════════════════════════════════════════

    function _swapCfg(bool heartbeatOn, uint16 latency)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        s.collatToken = address(collat);
        s.oracleToken1 = address(tokenA);
        s.oracleToken2 = address(tokenB);
        s.initialMarginSwapper = MARGIN_S;
        s.initialMarginMatcher = MARGIN_M;
        s.maintenanceMarginSwapper = MAINT;
        s.notional = NOTIONAL;
        s.isLong = true;
        s.auctionFunding = true; // funding auctioned, fulfillment fee fixed at zero
        s.fulfillmentFee = 0;
        s.fundingRate = 0;
        s.priceTolerated = PRICE_TOLERATED;
        s.toleranceRange = 1e6;
        s.millisecondsPerBlock = MS_PER_BLOCK;
        s.maxGameTime = MAX_GAME_TIME;
        s.maxExecutionLatency = latency;
        s.liquidationHeartbeatMin = heartbeatOn ? HB_MIN : 0;
        s.liquidationHeartbeatMax = heartbeatOn ? HB_MAX : 0;
        s.expiration = EXPIRATION_WINDOW;
        s.maturityWindow = 7 days;
        s.settlerReward = SETTLER_REWARD;
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.openExecutionComp = OPEN_EXEC_COMP;

        m.initialLiquidity = A1;
        m.escalationHalt = 100 * uint128(A1);
        m.settlementTime = SETTLE_BLOCKS;
        m.disputeDelay = 1;
        m.multiplier = 110;
        m.protocolFee = 0;
        m.auctionStart = 0;
        m.auctionEnd = 1;
        m.roundLength = 60;
        m.maxRounds = 5;
        m.growthRate = 15_000;
    }

    function _dutchInput() internal view returns (OpenPuntStorage.CloseDutch memory d) {
        d.maxReward = DUTCH_MAX;
        d.startingReward = DUTCH_START;
        d.roundLength = 60;
        d.growthRate = 15_000;
        d.maxRounds = 5;
        // close() caps the Dutch expiration at one hour. 55 minutes keeps the auction claimable
        // for most of that window: the campaigns advance the clock aggressively, and a short
        // window means almost every report arrives after expiry and force-skips instead of
        // claiming, which starves the claim branch.
        d.expiration = uint48(block.timestamp + 55 minutes);
    }

    function _noDutch() internal pure returns (OpenPuntStorage.CloseDutch memory d) {}

    function _noTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory) {
        return IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
    }

    function _emptyPermit() internal pure returns (OpenPuntStorage.Permit2Params memory p) {}

    // ══════════════════════════════════════════════════════════════════
    //  Event decoding — the model is fed by the protocol's own events
    // ══════════════════════════════════════════════════════════════════

    function _find(Vm.Log[] memory logs, bytes32 topic0, uint256 swapId) internal view returns (bool, Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(punt)) continue;
            if (logs[i].topics.length < 2 || logs[i].topics[0] != topic0) continue;
            if (uint256(logs[i].topics[1]) == swapId) return (true, logs[i]);
        }
        Vm.Log memory empty;
        return (false, empty);
    }

    function _has(Vm.Log[] memory logs, bytes32 topic0, uint256 swapId) internal view returns (bool) {
        (bool found,) = _find(logs, topic0, swapId);
        return found;
    }

    function _readSingleState(Vm.Log[] memory logs, bytes32 topic0, uint256 swapId)
        internal
        view
        returns (OpenPuntStorage.MatchedSwap memory s)
    {
        (bool found, Vm.Log memory l) = _find(logs, topic0, swapId);
        require(found, "handler: expected swap-state log");
        s = abi.decode(l.data, (OpenPuntStorage.MatchedSwap));
    }

    function _readOracle(Vm.Log[] memory logs, uint256 reportId)
        internal
        view
        returns (IOpenOracle2.OracleGame memory g, IOpenOracle2.PreimageHelper memory h)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(oracle)) continue;
            if (logs[i].topics.length < 2 || logs[i].topics[0] != OpenOracle.ReportSubmitted.selector) continue;
            if (uint256(logs[i].topics[1]) != reportId) continue;
            g = PackedDecoder.decodeOracleGame(logs[i].data);
            h = PackedDecoder.decodeHelperTail(logs[i].data, reportId);
            return (g, h);
        }
        revert("handler: expected ReportSubmitted");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Selection helpers
    // ══════════════════════════════════════════════════════════════════

    function _pick(uint256 seed, Phase want) internal view returns (bool found, uint256 swapId) {
        uint256 n = ids.length;
        if (n == 0) return (false, 0);
        uint256 start = seed % n;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[(start + i) % n];
            if (pos[id].phase == want) return (true, id);
        }
        return (false, 0);
    }

    function _pickActive(uint256 seed) internal view returns (bool found, uint256 swapId) {
        uint256 n = ids.length;
        if (n == 0) return (false, 0);
        uint256 start = seed % n;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[(start + i) % n];
            Phase p = pos[id].phase;
            if (p == Phase.ActiveIdle || p == Phase.ActiveCloseAuction) return (true, id);
        }
        return (false, 0);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Clock actions
    //
    //  The cadence predicate accepts |blocks*2000 - seconds*1000| <= 2000 ms. At one block per two
    //  seconds `expected == elapsed` exactly, so every "valid" advance below is centred in the band
    //  by construction rather than by copying the production predicate.
    // ══════════════════════════════════════════════════════════════════

    function _advanceValid(uint256 secs) internal {
        if (secs == 0) return;
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 2);
    }

    /// @dev Wall time with too few blocks: elapsed grows while expected does not.
    function clockStallBlocks(uint256 seed) external {
        uint256 secs = 10 + (seed % 300);
        vm.warp(block.timestamp + secs);
        _hit("clockStallBlocks");
    }

    /// @dev Blocks with no wall time: expected grows while elapsed does not. This is the block-mode
    ///      same-timestamp block-mode case.
    function clockBlocksOnly(uint256 seed) external {
        vm.roll(block.number + 1 + (seed % 40));
        _hit("clockBlocksOnly");
    }

    function clockValidHop(uint256 seed) external {
        _advanceValid(2 + 2 * (seed % 60));
        _hit("clockValidHop");
    }

    /// @dev Exactly to a report's settlement eligibility: SETTLE_BLOCKS blocks past the report.
    function clockToEligibility(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.ActiveReport);
        if (!found) (found, id) = _pick(seed, Phase.OpeningReport);
        if (!found) return _miss("clockToEligibility");
        uint256 reportBlock = pos[id].game.reportTimestamp; // block mode: this IS the block number
        uint256 target = reportBlock + pos[id].game.settlementTime;
        if (block.number >= target) return _miss("clockToEligibility");
        uint256 need = target - block.number;
        _advanceValid(need * 2);
        _hit("clockToEligibility");
    }

    /// @dev One block short of eligibility, so `execute()` must refuse.
    function clockOneBlockShort(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.ActiveReport);
        if (!found) return _miss("clockOneBlockShort");
        uint256 target = uint256(pos[id].game.reportTimestamp) + pos[id].game.settlementTime;
        if (block.number + 1 >= target) return _miss("clockOneBlockShort");
        _advanceValid((target - 1 - block.number) * 2);
        _hit("clockOneBlockShort");
    }

    function clockCrossMaturity(uint256 seed) external {
        (bool found, uint256 id) = _pickActive(seed);
        if (!found) return _miss("clockCrossMaturity");
        uint256 target = pos[id].matched.maturity;
        if (block.timestamp >= target) return _miss("clockCrossMaturity");
        _advanceValid(target - block.timestamp + 2);
        _hit("clockCrossMaturity");
    }

    function clockCrossMaturityPlusWeek(uint256 seed) external {
        (bool found, uint256 id) = _pickActive(seed);
        if (!found) (found, id) = _pick(seed, Phase.ActiveReport);
        if (!found) return _miss("clockCrossMaturityPlusWeek");
        uint256 target = uint256(pos[id].matched.maturity) + 1 weeks;
        if (block.timestamp >= target) return _miss("clockCrossMaturityPlusWeek");
        _advanceValid(target - block.timestamp);
        _hit("clockCrossMaturityPlusWeek");
    }

    /// @dev Past a preserved or live heartbeat's maximum, which makes it replaceable.
    function clockCrossHeartbeatMax(uint256 seed) external {
        (bool found, uint256 id) = _pickActive(seed);
        if (!found) return _miss("clockCrossHeartbeatMax");
        uint48 ts = pos[id].hbTimestamp;
        if (ts == 0) return _miss("clockCrossHeartbeatMax");
        uint256 target = uint256(ts) + HB_MAX + 2;
        if (block.timestamp >= target) return _miss("clockCrossHeartbeatMax");
        _advanceValid(target - block.timestamp);
        _hit("clockCrossHeartbeatMax");
    }

    /// @dev Past a heartbeat's minimum notice, which is what authorizes a liquidation.
    function clockCrossHeartbeatMin(uint256 seed) external {
        (bool found, uint256 id) = _pickActive(seed);
        if (!found) return _miss("clockCrossHeartbeatMin");
        uint48 ts = pos[id].hbTimestamp;
        if (ts == 0) return _miss("clockCrossHeartbeatMin");
        // report at ts + HB_MIN - SETTLE_SECONDS so eligibility lands on ts + HB_MIN
        uint256 target = uint256(ts) + HB_MIN - SETTLE_SECONDS;
        if (block.timestamp >= target) return _miss("clockCrossHeartbeatMin");
        _advanceValid(target - block.timestamp);
        _hit("clockCrossHeartbeatMin");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Proposal and opening
    // ══════════════════════════════════════════════════════════════════

    function propose(uint256 seed) external {
        bool heartbeatOn = seed % 2 == 0;
        uint16 latency = seed % 4 == 0 ? 60 : 0;
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _swapCfg(heartbeatOn, latency);
        uint256 value = uint256(s.matcherGasComp) + s.settlerReward + s.openExecutionComp;

        vm.recordLogs();
        vm.prank(swapper);
        try punt.propose{value: value}(s, m, _emptyPermit()) returns (uint256 swapId) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (bool found, Vm.Log memory l) = _find(logs, OpenPuntStorage.SwapProposed.selector, swapId);
            require(found, "handler: SwapProposed missing");
            (OpenPuntStorage.ProposedSwap memory es, OpenPuntStorage.MatcherPreimage memory em) =
                abi.decode(l.data, (OpenPuntStorage.ProposedSwap, OpenPuntStorage.MatcherPreimage));

            ids.push(swapId);
            Pos storage q = pos[swapId];
            q.phase = Phase.Proposed;
            q.proposed = es;
            q.preimage = em;
            q.marginPool = es.initialMarginSwapper;
            expectedCollat += es.initialMarginSwapper;
            modelSwapperPlusReporterCollat -= int256(uint256(es.initialMarginSwapper));
            // propose keeps all three ETH compensations raw on the core, owed to nobody yet
            reservedRawEth += uint256(es.matcherGasComp) + es.settlerReward + es.openExecutionComp;
            _hit("propose");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("propose");
        }
    }

    function cancelProposalBySwapper(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.Proposed);
        if (!found) return _miss("cancelProposalBySwapper");
        Pos storage q = pos[id];
        if (block.timestamp > q.proposed.expiration) return _miss("cancelProposalBySwapper");

        vm.prank(swapper);
        try punt.cancelSwapOpen(id, q.proposed, q.preimage) {
            expectedCollat -= q.marginPool;
            modelSwapperPlusReporterCollat += int256(q.marginPool);
            q.marginPool = 0;
            reservedRawEth -=
                uint256(q.proposed.matcherGasComp) + q.proposed.settlerReward + q.proposed.openExecutionComp;
            q.phase = Phase.Finalized;
            _hit("cancelProposalBySwapper");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("cancelProposalBySwapper");
        }
    }

    /// @dev Ages a specific proposal past its expiration so the outsider-cancellation branch is
    ///      reachable without making every proposal expire.
    function clockPastProposalExpiry(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.Proposed);
        if (!found) return _miss("clockPastProposalExpiry");
        uint256 target = uint256(pos[id].proposed.expiration) + 2;
        if (block.timestamp >= target) return _miss("clockPastProposalExpiry");
        _advanceValid(target - block.timestamp);
        _hit("clockPastProposalExpiry");
    }

    function cancelProposalByOutsider(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.Proposed);
        if (!found) return _miss("cancelProposalByOutsider");
        Pos storage q = pos[id];
        if (block.timestamp <= q.proposed.expiration) return _miss("cancelProposalByOutsider");

        vm.prank(outsider);
        try punt.cancelSwapOpen(id, q.proposed, q.preimage) {
            expectedCollat -= q.marginPool;
            modelSwapperPlusReporterCollat += int256(q.marginPool);
            q.marginPool = 0;
            // after expiration the caller takes the matcher gas compensation, and it is credited
            // through tempHolding rather than paid out; the rest is pushed to the swapper
            modelTemp[outsider] += q.proposed.matcherGasComp;
            reservedRawEth -=
                uint256(q.proposed.matcherGasComp) + q.proposed.settlerReward + q.proposed.openExecutionComp;
            q.phase = Phase.Finalized;
            _hit("cancelProposalByOutsider");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("cancelProposalByOutsider");
        }
    }

    function matchSwap(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.Proposed);
        if (!found) return _miss("matchSwap");
        Pos storage q = pos[id];

        vm.recordLogs();
        vm.prank(matcher);
        try punt.matchSwap(id, A2_OPEN, q.proposed, q.preimage, _noTiming(), matcher) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            OpenPuntStorage.MatchedSwap memory ms = _readSingleState(logs, OpenPuntStorage.SwapMatched.selector, id);
            q.matched = ms;
            q.reportId = punt.swapIdToReportId(id);
            (q.game, q.helper) = _readOracle(logs, q.reportId);
            q.phase = Phase.OpeningReport;
            q.marginPool += ms.initialMarginMatcher;
            expectedCollat += ms.initialMarginMatcher;
            modelMatcherCollat -= int256(uint256(ms.initialMarginMatcher));
            // matcherGasComp stops being unassigned and becomes owed to the matcher; the settler
            // reward leaves the core entirely, into the oracle game
            modelTemp[matcher] += q.proposed.matcherGasComp;
            reservedRawEth -= uint256(q.proposed.matcherGasComp) + q.proposed.settlerReward;
            _hit("matchSwap");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("matchSwap");
        }
    }

    function settleOpeningDirectly(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.OpeningReport);
        if (!found) return _miss("settleOpeningDirectly");
        Pos storage q = pos[id];
        if (q.settledDirectly) return _miss("settleOpeningDirectly");

        vm.recordLogs();
        vm.prank(settler);
        try IOpenOracle2(address(oracle)).settle(q.reportId, q.game, q.helper) {
            q.settledDirectly = true;
            q.game.settlementTimestamp = uint48(block.number); // block mode records the block number
            _hit("settleOpeningDirectly");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("settleOpeningDirectly");
        }
    }

    function executeOpening(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.OpeningReport);
        if (!found) return _miss("executeOpening");
        Pos storage q = pos[id];

        vm.recordLogs();
        vm.prank(executor);
        try puntLifecycle.execute(id, q.matched, q.game, q.helper, false) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (_has(logs, OpenPuntStorage.PositionOpened.selector, id)) {
                q.matched = _readSingleState(logs, OpenPuntStorage.PositionOpened.selector, id);
                q.reportId = 0;
                q.phase = Phase.ActiveIdle;
                q.marginPool = uint256(q.matched.initialMarginSwapper) + q.matched.initialMarginMatcher;
                modelTemp[executor] += q.proposed.openExecutionComp;
                reservedRawEth -= q.proposed.openExecutionComp;
                _hit("executeOpeningSuccess");
            } else {
                // slippage or cadence refund: each margin returns to the party that posted it
                expectedCollat -= q.marginPool;
                modelSwapperPlusReporterCollat += int256(uint256(q.matched.initialMarginSwapper));
                modelMatcherCollat += int256(uint256(q.matched.initialMarginMatcher));
                q.marginPool = 0;
                modelTemp[executor] += q.proposed.openExecutionComp;
                reservedRawEth -= q.proposed.openExecutionComp;
                q.phase = Phase.Finalized;
                _hit("executeOpeningRefund");
            }
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("executeOpening");
        }
    }

    function bailOutOpening(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.OpeningReport);
        if (!found) return _miss("bailOutOpening");
        Pos storage q = pos[id];

        vm.prank(outsider);
        try punt.bailOutOpen(id, q.matched) {
            expectedCollat -= q.marginPool;
            modelSwapperPlusReporterCollat += int256(uint256(q.matched.initialMarginSwapper));
            modelMatcherCollat += int256(uint256(q.matched.initialMarginMatcher));
            q.marginPool = 0;
            modelTemp[outsider] += q.proposed.openExecutionComp; // bailOut pays its caller
            reservedRawEth -= q.proposed.openExecutionComp;
            q.phase = Phase.Finalized;
            _hit("bailOutOpening");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("bailOutOpening");
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  Active-position auxiliary state
    // ══════════════════════════════════════════════════════════════════

    function recordHeartbeat(uint256 seed) external {
        (bool found, uint256 id) = _pickActive(seed);
        if (!found) return _miss("recordHeartbeat");
        Pos storage q = pos[id];

        vm.prank(outsider);
        try punt.liquidationHeartbeat(id, q.matched) {
            // derived, not read back: the position is idle or in an auction, so its reportId is
            // zero and the beat is recorded unbound at the current timestamp
            q.hbReportId = 0;
            q.hbTimestamp = uint48(block.timestamp);
            q.hbPreserved = false;
            _hit("recordHeartbeat");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("recordHeartbeat");
        }
    }

    function startCloseAuction(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.ActiveIdle);
        if (!found) return _miss("startCloseAuction");
        Pos storage q = pos[id];
        OpenPuntStorage.CloseDutch memory input = _dutchInput();

        vm.recordLogs();
        vm.prank(swapper);
        try punt.close{value: CLOSE_COMP}(id, input, q.matched, false, _emptyPermit(), CLOSE_COMP) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (bool f, Vm.Log memory l) = _find(logs, OpenPuntStorage.CloseAuctionStarted.selector, id);
            require(f, "handler: CloseAuctionStarted missing");
            (OpenPuntStorage.CloseDutch memory d, uint128 comp) =
                abi.decode(l.data, (OpenPuntStorage.CloseDutch, uint128));
            q.dutch = d;
            q.dutchHash = l.topics[2];
            q.dutchStatus = DutchStatus.Live;
            q.pendingComp = comp;
            q.closeIntent = true;
            q.closeRequestBlock = uint48(block.number);
            q.dutchHeld = d.maxReward;
            expectedCollat += d.maxReward;
            modelSwapperPlusReporterCollat -= int256(uint256(d.maxReward));
            q.phase = Phase.ActiveCloseAuction;
            _hit("startCloseAuction");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("startCloseAuction");
        }
    }

    function cancelCloseAuction(uint256 seed) external {
        uint256 n = ids.length;
        if (n == 0) return _miss("cancelCloseAuction");
        uint256 start = seed % n;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[(start + i) % n];
            Pos storage q = pos[id];
            if (q.dutchStatus != DutchStatus.Live || q.reportId != 0) continue;

            vm.prank(swapper);
            try punt.cancelCloseAuction(id, q.matched) {
                expectedCollat -= q.dutchHeld;
                modelSwapperPlusReporterCollat += int256(uint256(q.dutchHeld));
                q.dutchHeld = 0;
                q.dutchStatus = DutchStatus.Cancelled;
                q.dutchHash = bytes32(0);
                q.pendingComp = 0;
                q.closeIntent = false;
                q.closeRequestBlock = 0;
                if (q.phase == Phase.ActiveCloseAuction) q.phase = Phase.ActiveIdle;
                _hit("cancelLiveAuction");
                return;
            } catch {
                return _miss("cancelCloseAuction");
            }
        }
        _miss("cancelCloseAuction");
    }

    /// @dev Close intent during a live report: adds funded execution compensation rather than
    ///      creating an auction.
    function setCloseIntentDuringReport(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.ActiveReport);
        if (!found) return _miss("setCloseIntentDuringReport");
        Pos storage q = pos[id];

        vm.prank(swapper);
        try punt.close{value: CLOSE_COMP}(id, _noDutch(), q.matched, false, _emptyPermit(), CLOSE_COMP) {
            q.closeIntent = true;
            q.closeRequestBlock = uint48(block.number);
            q.assignedComp += CLOSE_COMP;
            _hit("setCloseIntentDuringReport");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("setCloseIntentDuringReport");
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  Active reports
    // ══════════════════════════════════════════════════════════════════

    function _report(uint256 id, OpenPuntStorage.CloseDutch memory d, uint128 a2, string memory tag) internal {
        Pos storage q = pos[id];
        uint128 pendingBefore = q.pendingComp;

        bool auctionExists = q.dutchStatus == DutchStatus.Live;
        bytes32 expectedDutchHash = d.maxReward == 0 ? bytes32(0) : keccak256(abi.encode(d));

        vm.recordLogs();
        vm.prank(reporter);
        try puntLifecycle.report(
            id, expectedDutchHash, q.matched, q.preimage, _noTiming(), reporter, A1, a2, REPORT_COMP
        ) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            OpenPuntStorage.MatchedSwap memory ms =
                _readSingleState(logs, OpenPuntStorage.PositionReportStarted.selector, id);
            q.matched = ms;
            q.reportId = punt.swapIdToReportId(id);
            (q.game, q.helper) = _readOracle(logs, q.reportId);
            q.settledDirectly = false;
            q.phase = Phase.ActiveReport;

            // pending compensation migrates onto the report exactly once, and the reporter's own
            // funded tranche is added to it
            q.assignedComp = pendingBefore + REPORT_COMP;
            q.pendingComp = 0;
            if (auctionExists) {
                _hit("dutchClaimBranch");
                q.dutchStatus = DutchStatus.Consumed;
                expectedCollat -= q.dutchHeld;
                modelSwapperPlusReporterCollat += int256(uint256(q.dutchHeld)); // split by calcFee
                q.dutchHeld = 0;
                q.dutchHash = bytes32(0);
                (uint128 storedMaxReward,,,,,,,,) = punt.closeAuctions(id);
                _violation(storedMaxReward == 0, "expected a CLAIM: auction survived");
            }
            // derived, not read back: report() rebinds an unbound beat that is still inside
            // liquidationHeartbeatMax, and leaves everything else alone
            if (
                q.hbTimestamp != 0 && q.hbReportId == 0
                    && block.timestamp <= uint256(q.hbTimestamp) + q.matched.liquidationHeartbeatMax
            ) {
                q.hbReportId = uint128(q.reportId);
            }
            _hit(tag);
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss(tag);
        }
    }

    function reportNoDutch(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.ActiveIdle);
        if (!found) return _miss("reportNoDutch");
        _report(id, _noDutch(), _a2(seed), "reportNoDutch");
    }

    function reportClaimingDutch(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.ActiveCloseAuction);
        if (!found) return _miss("reportClaimingDutch");
        _report(id, pos[id].dutch, _a2(seed), "reportClaimingDutch");
    }

    function reportZeroSentinel(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.ActiveCloseAuction);
        if (!found) return _miss("reportZeroSentinel");
        _report(id, _noDutch(), _a2(seed), "reportZeroSentinel");
    }

    /**
     * @dev Closing token2 leg. Derived from the seed and from the position's own declared
     *      parameters, never from production arithmetic.
     *
     *      The liquidating value is chosen from the ratio directly: the swapper is long, so a fall
     *      in token2 per token1 costs it `notional * delta / openingCross`. With notional and
     *      margin both 1000e18 and a 200e18 maintenance floor, equity drops below the floor once
     *      the loss exceeds 800e18, i.e. once A2 falls below 400e18. 300e18 clears that with room
     *      to spare; a 900e18 fall at these margins would
     *      only cost 450e18 here and leave the position healthy.
     */
    function _a2(uint256 seed) internal pure returns (uint128) {
        uint256 r = seed % 3;
        if (r == 0) return A2_OPEN; // flat: healthy
        if (r == 1) return 300e18; // deeply underwater: liquidatable
        return A2_OPEN + 200e18; // moves in the swapper's favour
    }

    function settleReportDirectly(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.ActiveReport);
        if (!found) return _miss("settleReportDirectly");
        Pos storage q = pos[id];
        if (q.settledDirectly) return _miss("settleReportDirectly");

        vm.prank(settler);
        try IOpenOracle2(address(oracle)).settle(q.reportId, q.game, q.helper) {
            q.settledDirectly = true;
            q.game.settlementTimestamp = uint48(block.number);
            _hit("settleReportDirectly");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("settleReportDirectly");
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  Active outcomes
    // ══════════════════════════════════════════════════════════════════

    function executeActiveReport(uint256 seed) external {
        (bool found, uint256 id) = _pick(seed, Phase.ActiveReport);
        if (!found) return _miss("executeActiveReport");
        Pos storage q = pos[id];
        uint256 reportId = q.reportId;

        // captured before the terminal transition so conservation is checked against the pool the
        // position actually owned, not against whatever the model holds afterwards
        uint256 preTerminalPool = q.marginPool;

        // Per-recipient collateral, measured immediately around this call. The lifetime book
        // reconciles swapper and reporter jointly because a claimed Dutch reward is split by
        // `calcFee`; that split happens during report(), never during terminal execution, so these
        // immediate deltas can name the individual recipient and would catch a payout delivered to
        // the wrong party.
        uint256 swapperBefore = _actorCollat(swapper);
        uint256 matcherBefore = _actorCollat(matcher);
        uint256 reporterBefore = _actorCollat(reporter);

        vm.recordLogs();
        vm.prank(executor);
        try puntLifecycle.execute(id, q.matched, q.game, q.helper, false) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            modelTemp[executor] += 0; // opening comp only; closing execution pays via the oracle ledger
            q.assignedComp = 0; // execution consumes the assigned tranche exactly once
            reportId;

            if (_has(logs, OpenPuntStorage.PositionClosed.selector, id)) {
                (bool f, Vm.Log memory l) = _find(logs, OpenPuntStorage.PositionClosed.selector, id);
                require(f, "handler: PositionClosed");
                (, uint256 owedS, uint256 owedM) = abi.decode(l.data, (OpenPuntStorage.MatchedSwap, uint256, uint256));
                _violation(owedS + owedM == preTerminalPool, "close payouts do not conserve the pool");
                _violation(!q.paidOut, "a terminal payout was delivered twice");
                q.paidOut = true;
                q.owedToSwapper = owedS;
                q.owedToMatcher = owedM;
                q.preTerminalPool = preTerminalPool;
                // the event says who is owed what; the per-actor book below is what proves the
                // transfer actually reached them
                modelSwapperPlusReporterCollat += int256(owedS);
                modelMatcherCollat += int256(owedM);
                _violation(_actorCollat(swapper) - swapperBefore == owedS, "close: swapper delta != owedToSwapper");
                _violation(_actorCollat(matcher) - matcherBefore == owedM, "close: matcher delta != owedToMatcher");
                _violation(_actorCollat(reporter) == reporterBefore, "close: the reporter was paid");
                expectedCollat -= q.marginPool;
                q.marginPool = 0;
                q.closeIntent = false;
                q.closeRequestBlock = 0;
                q.pendingComp = 0;
                q.hbReportId = 0;
                q.hbTimestamp = 0;
                q.phase = Phase.Finalized;
                _hit("outcomeClose");
            } else if (_has(logs, OpenPuntStorage.PositionLiquidated.selector, id)) {
                _violation(!q.paidOut, "a terminal payout was delivered twice");
                q.paidOut = true;
                q.owedToMatcher = preTerminalPool; // liquidation moves the WHOLE pool to the matcher
                q.preTerminalPool = preTerminalPool;
                modelMatcherCollat += int256(preTerminalPool);
                _violation(
                    _actorCollat(matcher) - matcherBefore == preTerminalPool,
                    "liquidation: matcher did not receive the whole pool"
                );
                _violation(_actorCollat(swapper) == swapperBefore, "liquidation: the swapper was paid");
                _violation(_actorCollat(reporter) == reporterBefore, "liquidation: the reporter was paid");
                expectedCollat -= q.marginPool;
                q.marginPool = 0;
                q.closeIntent = false;
                q.closeRequestBlock = 0;
                q.pendingComp = 0;
                q.hbReportId = 0;
                q.hbTimestamp = 0;
                q.phase = Phase.Finalized;
                _hit("outcomeLiquidated");
            } else {
                // reusable: LiquidationFailed, or one of the three bailouts
                q.matched = _readSingleState(logs, _reusableTopic(logs, id), id);
                bool requestApplied = q.closeRequestBlock != 0
                    && uint256(q.closeRequestBlock) < uint256(q.game.reportTimestamp) + q.game.settlementTime;
                if (requestApplied) {
                    q.closeIntent = false;
                    q.closeRequestBlock = 0;
                }
                q.reportId = 0;
                q.phase = q.dutchStatus == DutchStatus.Live ? Phase.ActiveCloseAuction : Phase.ActiveIdle;

                if (_has(logs, OpenPuntStorage.LiquidationHeartbeatBailout.selector, id)) {
                    // an unauthorized liquidation releases the binding but preserves the timestamp
                    q.hbReportId = 0;
                    q.hbPreserved = true;
                    _hit("outcomeHeartbeatBailout");
                } else if (_has(logs, OpenPuntStorage.ImpliedMillisecondsPerBlockBailout.selector, id)) {
                    q.hbReportId = 0; // every other outcome deletes the heartbeat outright
                    q.hbTimestamp = 0;
                    _hit("outcomeCadenceBailout");
                } else if (_has(logs, OpenPuntStorage.MaxExecutionLatencyBailout.selector, id)) {
                    q.hbReportId = 0;
                    q.hbTimestamp = 0;
                    _hit("outcomeLatencyBailout");
                } else {
                    q.hbReportId = 0;
                    q.hbTimestamp = 0;
                    _hit("outcomeLiquidationFailed");
                }
            }
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("executeActiveReport");
        }
    }

    function _reusableTopic(Vm.Log[] memory logs, uint256 id) internal view returns (bytes32) {
        if (_has(logs, OpenPuntStorage.LiquidationFailed.selector, id)) {
            return OpenPuntStorage.LiquidationFailed.selector;
        }
        return OpenPuntStorage.PositionReportBailedOut.selector;
    }

    // ══════════════════════════════════════════════════════════════════
    //  Other
    // ══════════════════════════════════════════════════════════════════

    function withdrawTempHolding(uint256 seed) external {
        address who = seed % 2 == 0 ? executor : swapper;
        if (punt.tempHolding(who) <= 1) return _miss("withdrawTempHolding");
        vm.prank(who);
        try punt.withdraw(who, false) {
            modelTemp[who] = 0;
            _hit("withdrawTempHolding");
        } catch (bytes memory _e) {
            lastRevertData = _e;
            _miss("withdrawTempHolding");
        }
    }
}
