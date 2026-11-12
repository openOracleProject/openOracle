// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {openSwapV2} from "../../src/swap/OpenSwapSlim.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {NoReturnToken} from "./AdversarialMocks.sol";
import {SwapCompat} from "../openSwapPermitTesting/SwapCompat.sol";

/// @notice Drives propose / match / cancel / dispute / bailOut / settleOracle / execute / withdraw across multiple
///         actors and tokens (ETH + vanilla + USDT-style). Tracks per-swap state so the invariant test
///         can assert (a) the swap holds no ERC20 directly, (b) ETH conservation across tempHolding +
///         active-swap inflight, and (c) every stored swap hash matches a reconstruction.
contract SwapSystemHandler is Test {
    OpenOracle public immutable oracle;
    openSwapV2 public immutable swap;

    address[] public actors;
    address[] public tokens; // index 0 = ETH (address(0))

    // Fixed gas comps / oracle params — uniform across swaps so the conservation invariant has a simple form.
    uint96 public constant MATCHER_GAS_COMP = 0.001 ether;
    uint96 public constant EXECUTOR_GAS_COMP = 0.001 ether;
    uint96 public constant SETTLER_REWARD = 0.001 ether;
    uint128 public constant MIN_FULFILL_LIQUIDITY = 25_000e18;
    uint128 public constant INITIAL_LIQUIDITY = 1e18;
    uint48 public constant SETTLEMENT_TIME = 300;
    uint24 public constant DISPUTE_DELAY = 5;
    uint24 public constant PROTOCOL_FEE = 0;
    uint24 public constant MAX_GAME_TIME = 15000;
    uint16 public constant MULTIPLIER = 110;
    uint24 public constant MAX_FEE = 10000;
    uint24 public constant STARTING_FEE = 10000;
    uint24 public constant ROUND_LENGTH = 60;
    uint16 public constant GROWTH_RATE = 10000; // 1.0x — no fee growth (deterministic)
    uint16 public constant MAX_ROUNDS = 10;
    uint128 public constant ESCALATION_HALT = 10e18;
    uint232 public constant PRICE_TOLERATED = 2e38;
    uint24 public constant TOLERANCE_RANGE = 1_000_000; // 10%

    enum SwapState { None, PreMatch, Matched, Finalized }

    struct Tracked {
        uint256 swapId;
        SwapState state;
        // Pre-match preimage
        openSwapV2.ProposedSwap s;
        openSwapV2.MatcherPreimage m;
        // Post-match
        openSwapV2.MatchedSwap ms;
        uint256 reportId;
        IOpenOracle2.OracleGame game;
        IOpenOracle2.PreimageHelper helper;
        bool oracleSettled;
    }

    Tracked[] public _swaps;

    // Counters
    uint256 public preMatchCount;
    uint256 public matchedCount;

    address[] public knownHolders;
    mapping(address => bool) internal inKnown;

    uint256 public totalProposes;
    uint256 public totalMatches;
    uint256 public totalCancels;
    uint256 public totalBailOuts;
    uint256 public totalDisputes;
    uint256 public totalExecutes;
    uint256 public totalOracleSettles;
    uint256 public totalWithdrawals;

    constructor(OpenOracle _oracle, openSwapV2 _swap) {
        oracle = _oracle;
        swap = _swap;
        _markKnown(address(swap));
        // Handler is the settler when actSettleOracle runs without a prank.
        _markKnown(address(this));
    }

    receive() external payable {}

    function addActor(address a) external { actors.push(a); _markKnown(a); }
    function addToken(address t) external { tokens.push(t); }
    function actorCount() external view returns (uint256) { return actors.length; }
    function tokenCount() external view returns (uint256) { return tokens.length; }
    function tokenAt(uint256 i) external view returns (address) { return tokens[i]; }
    function swapCount() external view returns (uint256) { return _swaps.length; }
    function knownCount() external view returns (uint256) { return knownHolders.length; }
    function knownAt(uint256 i) external view returns (address) { return knownHolders[i]; }
    function getSwapId(uint256 i) external view returns (uint256) { return _swaps[i].swapId; }
    function getSwapState(uint256 i) external view returns (SwapState) { return _swaps[i].state; }
    function getSwapS(uint256 i) external view returns (openSwapV2.ProposedSwap memory) { return _swaps[i].s; }
    function getSwapM(uint256 i) external view returns (openSwapV2.MatcherPreimage memory) { return _swaps[i].m; }
    function getSwapMS(uint256 i) external view returns (openSwapV2.MatchedSwap memory) { return _swaps[i].ms; }
    function getSwapReportId(uint256 i) external view returns (uint256) { return _swaps[i].reportId; }
    function getSwapGame(uint256 i) external view returns (IOpenOracle2.OracleGame memory) { return _swaps[i].game; }
    function getSwapHelper(uint256 i) external view returns (IOpenOracle2.PreimageHelper memory) { return _swaps[i].helper; }
    function getSwapOracleSettled(uint256 i) external view returns (bool) { return _swaps[i].oracleSettled; }

    function _markKnown(address u) internal {
        if (!inKnown[u]) {
            inKnown[u] = true;
            knownHolders.push(u);
        }
    }

    function _pickActor(uint8 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
    function _pickToken(uint8 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    function _emptyTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory t) {}
    function _emptyPermit2() internal pure returns (openSwapV2.Permit2Params memory p) {}

    function _defaultSlip() internal pure returns (SwapCompat.SlippageParams memory s) {
        s.priceTolerated = PRICE_TOLERATED;
        s.toleranceRange = TOLERANCE_RANGE;
    }

    // ─── Actions: propose ───────────────────────────────────────────────────

    function actPropose(
        uint8 swapperSeed,
        uint8 sellTokSeed,
        uint8 buyTokSeed,
        uint128 sellAmtSeed,
        bool useInternal
    ) external {
        address swapper = _pickActor(swapperSeed);
        address sellToken = _pickToken(sellTokSeed);
        address buyToken = _pickToken(buyTokSeed);
        if (sellToken == buyToken) return;

        uint128 sellAmt = uint128(bound(uint256(sellAmtSeed), 1e15, 50e18));
        uint48 expirationOffset = 1 hours;
        uint128 minOut = 1;

        openSwapV2.ProposedSwap memory s;
        s.sellAmt = sellAmt;
        s.minFulfillLiquidity = MIN_FULFILL_LIQUIDITY;
        s.settlerReward = SETTLER_REWARD;
        s.maxGameTime = MAX_GAME_TIME;
        s.buyToken = buyToken;
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.sellToken = sellToken;
        s.executorGasComp = EXECUTOR_GAS_COMP;
        s.useInternalBalances = useInternal;
        s.expiration = expirationOffset;
        SwapCompat.SlippageParams memory slip = _defaultSlip();
        s.priceTolerated = slip.priceTolerated;
        s.toleranceRange = slip.toleranceRange;

        openSwapV2.MatcherPreimage memory m;
        m.initialLiquidity = INITIAL_LIQUIDITY;
        m.escalationHalt = ESCALATION_HALT;
        m.settlementTime = SETTLEMENT_TIME;
        m.disputeDelay = DISPUTE_DELAY;
        m.protocolFee = PROTOCOL_FEE;
        m.multiplier = MULTIPLIER;
        m.maxFee = MAX_FEE;
        m.startingFee = STARTING_FEE;
        m.roundLength = ROUND_LENGTH;
        m.growthRate = GROWTH_RATE;
        m.maxRounds = MAX_ROUNDS;

        bool isEth = sellToken == address(0);
        uint256 extraEth = uint256(MATCHER_GAS_COMP) + SETTLER_REWARD + EXECUTOR_GAS_COMP;
        uint256 ethValue = (isEth && !useInternal) ? uint256(sellAmt) + extraEth : extraEth;

        vm.deal(swapper, swapper.balance + ethValue + 1 ether);

        uint256 idBefore = swap.nextSwapId();
        vm.prank(swapper);
        try swap.propose{value: ethValue}(s, m, _emptyPermit2(), minOut) returns (uint256 newId) {
            // Capture post-propose canonical s (with swapper override + absolute expiration).
            s.swapper = swapper;
            s.expiration = uint48(block.timestamp) + expirationOffset;
            m.startFulfillFeeIncrease = uint48(block.number);

            Tracked storage t = _swaps.push();
            t.swapId = newId;
            t.state = SwapState.PreMatch;
            t.s = s;
            t.m = m;
            // ms / game / helper / reportId left zero until match

            preMatchCount += 1;
            totalProposes += 1;
            idBefore;
        } catch {}
    }

    // ─── Actions: match ─────────────────────────────────────────────────────

    function actMatch(uint8 matcherSeed, uint16 swapSeed, uint128 amt2Seed) external {
        if (_swaps.length == 0) return;
        uint256 idx = swapSeed % _swaps.length;
        Tracked storage t = _swaps[idx];
        if (t.state != SwapState.PreMatch) return;

        address matcher = _pickActor(matcherSeed);
        if (matcher == t.s.swapper) return; // matcher must differ from swapper for some flows

        uint128 amount2 = uint128(bound(uint256(amt2Seed), 1, 1e22));

        // Capture pre-match oracle-game prep.
        uint256 reportIdAtMatch = oracle.nextReportId();
        uint256 ts = block.timestamp;
        uint256 bn = block.number;

        vm.prank(matcher);
        try swap.matchSwap(t.swapId, amount2, t.s, t.m, _emptyTiming()) {
            // Build MatchedSwap struct as the contract would.
            openSwapV2.MatchedSwap memory ms;
            ms.sellAmt = t.s.sellAmt;
            ms.minFulfillLiquidity = t.s.minFulfillLiquidity;
            ms.maxGameTime = t.s.maxGameTime;
            ms.buyToken = t.s.buyToken;
            ms.sellToken = t.s.sellToken;
            ms.swapper = t.s.swapper;
            ms.executorGasComp = t.s.executorGasComp;
            ms.useInternalBalances = t.s.useInternalBalances;
            ms.reportId = uint128(reportIdAtMatch);
            ms.matcher = matcher;
            ms.start = uint48(bn);
            // fulfillmentFee = calcFee with maxFee=startingFee, growthRate=1.0x → always startingFee.
            ms.fulfillmentFee = STARTING_FEE;
            ms.feeRecipient = address(0); // PROTOCOL_FEE == 0 → no feeRecipient clone
            ms.priceTolerated = t.s.priceTolerated;
            ms.toleranceRange = t.s.toleranceRange;

            t.ms = ms;
            t.reportId = reportIdAtMatch;

            // Build the post-report OracleGame state the swap creates internally.
            IOpenOracle2.OracleGame memory g = IOpenOracle2.OracleGame({
                currentAmount1: INITIAL_LIQUIDITY,
                currentAmount2: amount2,
                currentReporter: matcher,
                reportTimestamp: uint48(bn),
                settlementTimestamp: 0,
                token1: t.s.sellToken,
                lastReportOppoTime: uint48(ts),
                settlementTime: SETTLEMENT_TIME,
                escalationHalt: ESCALATION_HALT,
                protocolFeeRecipient: address(0),
                settlerReward: SETTLER_REWARD,
                token2: t.s.buyToken,
                numReports: 0,
                disputeDelay: DISPUTE_DELAY,
                feePercentage: 0,
                multiplier: MULTIPLIER,
                callbackContract: address(0),
                callbackGasLimit: 0,
                protocolFee: PROTOCOL_FEE,
                flags: 32 // FLAG_FEES_ONLY_AT_HALT, block-number timing (hardcoded in oracleGame() of openSwap)
            });
            t.game = g;
            t.helper = IOpenOracle2.PreimageHelper({
                reportId: reportIdAtMatch,
                creator: address(swap),
                blockTimestamp: ts,
                blockNumber: bn
            });

            t.state = SwapState.Matched;
            preMatchCount -= 1;
            matchedCount += 1;
            totalMatches += 1;
            _markKnown(matcher);
        } catch {}
    }

    // ─── Actions: cancel (pre-match) ───────────────────────────────────────

    function actCancelPreExpire(uint16 swapSeed) external {
        if (_swaps.length == 0) return;
        uint256 idx = swapSeed % _swaps.length;
        Tracked storage t = _swaps[idx];
        if (t.state != SwapState.PreMatch) return;
        if (block.timestamp > t.s.expiration) return; // would need post-expire path

        vm.prank(t.s.swapper);
        try swap.cancelSwap(t.swapId, t.s, t.m) {
            t.state = SwapState.Finalized;
            preMatchCount -= 1;
            totalCancels += 1;
        } catch {}
    }

    function actCancelPostExpire(uint8 callerSeed, uint16 swapSeed) external {
        if (_swaps.length == 0) return;
        uint256 idx = swapSeed % _swaps.length;
        Tracked storage t = _swaps[idx];
        if (t.state != SwapState.PreMatch) return;

        if (block.timestamp <= t.s.expiration) {
            vm.warp(uint256(t.s.expiration) + 1);
        }

        address caller = _pickActor(callerSeed);
        if (caller == t.s.swapper) return;

        vm.prank(caller);
        try swap.cancelSwap(t.swapId, t.s, t.m) {
            t.state = SwapState.Finalized;
            preMatchCount -= 1;
            totalCancels += 1;
            _markKnown(caller);
        } catch {}
    }

    // ─── Actions: dispute ──────────────────────────────────────────────────

    /// @dev Picks the first game from swapSeed onward whose dispute window is still open, then runs
    ///      1-80 dispute rounds on it, rotating disputers. Each round lands at a
    ///      fuzzed block in the last eighth of the dispute window and moves the price by up to ±5%. Late
    ///      landings advance the game ~a full round each, so long bursts carry it past maxGameTime, which is
    ///      what makes bailOut and execute's maxGameTime refund reachable.
    function actDispute(uint8 disputerSeed, uint16 swapSeed, uint8 roundsSeed, uint16 offsetSeed, uint8 priceSeed)
        external
    {
        uint256 n = _swaps.length;
        uint256 idx = type(uint256).max;
        for (uint256 k; k < n; ++k) {
            Tracked storage c = _swaps[(uint256(swapSeed) + k) % n];
            if (c.reportId == 0 || c.oracleSettled) continue;
            if (block.number >= uint256(c.game.reportTimestamp) + c.game.settlementTime) continue;
            idx = (uint256(swapSeed) + k) % n;
            break;
        }
        if (idx == type(uint256).max) return;
        Tracked storage t = _swaps[idx];

        uint256 rounds = bound(uint256(roundsSeed), 1, 80);
        for (uint256 i; i < rounds; ++i) {
            IOpenOracle2.OracleGame memory g = t.game;
            uint256 open = uint256(g.reportTimestamp) + g.disputeDelay;
            uint256 close = uint256(g.reportTimestamp) + g.settlementTime; // exclusive
            if (block.number >= close) return;
            uint256 target = close - 1 - (uint256(offsetSeed) + i * 7919) % ((close - open) / 8 + 1);
            if (target < block.number) target = block.number;
            vm.roll(target);

            uint256 old1 = g.currentAmount1;
            uint256 new1 = old1 + 1;
            if (g.escalationHalt > old1) {
                new1 = (old1 * g.multiplier) / 100;
                if (new1 > g.escalationHalt) new1 = g.escalationHalt;
            }
            uint256 new2 = (uint256(g.currentAmount2) * new1) / old1;
            new2 = (new2 * (95 + (uint256(priceSeed) + i) % 11)) / 100;
            if (new2 == 0) new2 = 1;
            if (new2 > type(uint128).max) return;

            address disputer = _pickActor(uint8(uint256(disputerSeed) + i));
            vm.prank(disputer);
            try IOpenOracle2(address(oracle)).dispute(
                t.reportId, uint128(new1), uint128(new2), disputer, true, true, g, t.helper, _emptyTiming()
            ) {
                t.game.currentAmount1 = uint128(new1);
                t.game.currentAmount2 = uint128(new2);
                t.game.currentReporter = disputer;
                t.game.reportTimestamp = uint48(target);
                t.game.lastReportOppoTime = uint48(block.timestamp);
                totalDisputes += 1;
            } catch {
                return;
            }
        }
    }

    // ─── Actions: bailOut ──────────────────────────────────────────────────

    /// @dev Prefers the first matched swap from swapSeed onward whose game ran past maxGameTime;
    ///      otherwise tries swapSeed's swap, which exercises the CantBailOutYet revert.
    function actBailOut(uint8 callerSeed, uint16 swapSeed) external {
        uint256 n = _swaps.length;
        if (n == 0) return;
        uint256 idx = swapSeed % n;
        for (uint256 k; k < n; ++k) {
            Tracked storage c = _swaps[(uint256(swapSeed) + k) % n];
            if (c.state != SwapState.Matched) continue;
            if (uint256(c.game.reportTimestamp) + c.game.settlementTime - c.ms.start <= c.ms.maxGameTime) continue;
            idx = (uint256(swapSeed) + k) % n;
            break;
        }
        Tracked storage t = _swaps[idx];
        if (t.state != SwapState.Matched) return;

        address caller = _pickActor(callerSeed);
        vm.prank(caller);
        try swap.bailOut(t.swapId, t.ms, t.game, t.helper) {
            t.state = SwapState.Finalized;
            matchedCount -= 1;
            totalBailOuts += 1;
            _markKnown(caller);
        } catch {}
    }

    // ─── Actions: settle oracle game for a matched swap ────────────────────

    function actSettleOracle(uint16 swapSeed) external {
        if (_swaps.length == 0) return;
        uint256 idx = swapSeed % _swaps.length;
        Tracked storage t = _swaps[idx];
        if (t.state != SwapState.Matched) return;
        if (t.oracleSettled) return;
        if (t.game.reportTimestamp == 0) return;

        uint256 target = uint256(t.game.reportTimestamp) + t.game.settlementTime + 1;
        if (block.number < target) vm.roll(target);

        try IOpenOracle2(address(oracle)).settle(t.reportId, t.game, t.helper) {
            t.game.settlementTimestamp = uint48(block.number);
            t.oracleSettled = true;
            totalOracleSettles += 1;
        } catch {}
    }

    // ─── Actions: execute ──────────────────────────────────────────────────

    function actExecute(uint8 callerSeed, uint16 swapSeed) external {
        if (_swaps.length == 0) return;
        uint256 idx = swapSeed % _swaps.length;
        Tracked storage t = _swaps[idx];
        if (t.state != SwapState.Matched) return;

        // Need to be past oracle's settlementTime (in blocks).
        uint256 target = uint256(t.game.reportTimestamp) + t.game.settlementTime + 1;
        if (block.number < target) vm.roll(target);

        address caller = _pickActor(callerSeed);
        uint8 settlementSearchDepth = callerSeed & 1;

        vm.prank(caller);
        try swap.execute(t.swapId, t.ms, t.game, t.helper, settlementSearchDepth) {
            t.state = SwapState.Finalized;
            matchedCount -= 1;
            totalExecutes += 1;
            // If execute called settle internally, update tracking.
            if (!t.oracleSettled) {
                t.oracleSettled = true;
                t.game.settlementTimestamp = uint48(block.number);
            }
            _markKnown(caller);
        } catch {}
    }

    // ─── Actions: withdraw from tempHolding ────────────────────────────────

    function actWithdrawTemp(uint8 actorSeed, bool leaveOne) external {
        address user = _pickActor(actorSeed);
        vm.prank(user);
        try swap.withdraw(user, leaveOne) {
            totalWithdrawals += 1;
        } catch {}
    }

    // ─── Actions: time ─────────────────────────────────────────────────────

    function actWarp(uint16 dtSeed) external {
        uint256 dt = (uint256(dtSeed) % 1800) + 1;
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + dt * 5); // 200ms blocks
    }
}
