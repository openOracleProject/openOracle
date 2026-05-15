// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {AdversarialCallback, RevertingToken, ReturnsFalseToken, NoReturnToken, ReentrantToken} from "./AdversarialMocks.sol";

/// @notice Drives randomized report / dispute / settle / deposit / withdraw / transfer ops across multiple
///         actors, multiple tokens (including ETH and adversarial mocks), and an adversarial callback.
///         Maintains exact ghost bookkeeping so the test contract can assert per-token conservation.
contract OracleSystemHandler is Test {
    OpenOracle public immutable oracle;
    AdversarialCallback public immutable callback;

    address[] public actors;
    address[] public tokens; // index 0 = ETH (address(0))

    // Track live reports + their full preimage state.
    struct ReportState {
        uint256 id;
        OpenOracle.OracleGame game;
        OpenOracle.PreimageHelper helper;
        bool settled;
    }
    ReportState[] public reports;
    mapping(uint256 => uint256) public reportIdToIdx; // reportId → reports[] index (+1; 0 = absent)

    // Ghost vars for conservation invariant.
    // realBalance(token) == Σ_user tokenHolder[u][token] - ghostSentinels[token] + ghostBurned[token]
    //                        (+ ghostInflightSettlerETH for ETH)
    mapping(address => uint256) public ghostBurned;
    uint256 public ghostInflightSettlerETH;

    // Tracking which (user, token) slots have ever been touched, so the invariant
    // can iterate them deterministically.
    mapping(address => mapping(address => bool)) internal slotTouched;
    address[] public touchedHolders;
    // We piggyback on `tokens` for the token axis of the slot enumeration.

    // Stats for sanity asserts.
    uint256 public totalReports;
    uint256 public totalDisputes;
    uint256 public totalSettles;
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;
    uint256 public totalInternalTransfers;
    uint256 public totalPushOrCredits;

    uint96 internal constant SETTLER_REWARD = 0.001 ether;
    uint8 internal constant FLAG_TIME_TYPE = 1 << 0;
    uint8 internal constant FLAG_TRACK_DISPUTES = 1 << 1;

    constructor(OpenOracle _oracle, AdversarialCallback _callback) {
        oracle = _oracle;
        callback = _callback;
        // Handler itself is a potential token holder (becomes settler when actSettle runs without prank).
        touchedHolders.push(address(this));
    }

    receive() external payable {}

    // ─── Setup helpers ──────────────────────────────────────────────────────

    function addActor(address a) external { actors.push(a); _markTouched(a); }
    function addToken(address t) external { tokens.push(t); }
    function actorCount() external view returns (uint256) { return actors.length; }
    function tokenCount() external view returns (uint256) { return tokens.length; }
    function reportCount() external view returns (uint256) { return reports.length; }
    function holderCount() external view returns (uint256) { return touchedHolders.length; }
    function holderAt(uint256 i) external view returns (address) { return touchedHolders[i]; }
    function tokenAt(uint256 i) external view returns (address) { return tokens[i]; }

    /// @dev Explicit accessors — Solidity's array-of-struct auto-getter may not return nested struct fields.
    function getReportId(uint256 i) external view returns (uint256) { return reports[i].id; }
    function getReportGame(uint256 i) external view returns (OpenOracle.OracleGame memory) { return reports[i].game; }
    function getReportHelper(uint256 i) external view returns (OpenOracle.PreimageHelper memory) { return reports[i].helper; }
    function getReportSettled(uint256 i) external view returns (bool) { return reports[i].settled; }

    function _markTouched(address user) internal {
        for (uint256 t = 0; t < tokens.length; t++) {
            address tok = tokens[t];
            if (!slotTouched[user][tok]) {
                slotTouched[user][tok] = true;
            }
        }
        // Also add to touchedHolders if not seen.
        for (uint256 i = 0; i < touchedHolders.length; i++) {
            if (touchedHolders[i] == user) return;
        }
        touchedHolders.push(user);
    }

    function _pickActor(uint8 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickToken(uint8 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    function _emptyTiming() internal pure returns (OpenOracle.TimingBoundaries memory t) {}

    // ─── Actions: report ────────────────────────────────────────────────────

    /// @dev Try to create a new report. Bounds randomize every param within its valid contract window
    ///      (settlement time, dispute delay, fee splits, multiplier, escalationHalt, callback gas).
    function actReport(
        uint8 actorSeed,
        uint8 tok1Seed,
        uint8 tok2Seed,
        uint128 amt1Seed,
        uint128 amt2Seed,
        uint8 flagSeed,
        uint8 cbSeed,
        uint128 paramSeedA,
        uint128 paramSeedB
    ) external {
        address reporter = _pickActor(actorSeed);
        address t1 = _pickToken(tok1Seed);
        address t2 = _pickToken(tok2Seed);
        if (t1 == t2) return;

        uint128 amt1 = uint128(bound(uint256(amt1Seed), 1, 1e21));
        uint128 amt2 = uint128(bound(uint256(amt2Seed), 1, 1e21));
        uint8 flags = uint8(bound(uint256(flagSeed), 0, 0x0F));
        bool useCallback = (cbSeed & 1) == 1;

        // Param window: contract constraints are settlementTime > disputeDelay, multiplier ≥ 100,
        // feePercentage + protocolFee ≤ 1e7, escalationHalt ≥ amt1, settlement ≤ 14400 isn't enforced
        // in oracle (only in openSwap). Keep within sane ranges so reports validate often.
        uint48 settlementTime = uint48(bound(uint256(paramSeedA % type(uint48).max), 2, 14400));
        uint24 disputeDelay = uint24(bound(uint256(paramSeedB % type(uint24).max), 0, uint256(settlementTime) - 1));
        uint16 multiplier = uint16(bound(uint256(uint128(paramSeedA >> 48)), 100, 1000));
        uint24 feePercentage = uint24(bound(uint256(uint128(paramSeedB >> 24)), 0, 5_000_000));
        uint24 protocolFee = uint24(bound(uint256(uint128(paramSeedA >> 80)), 0, 1e7 - uint256(feePercentage)));
        uint128 escalationHalt = uint128(bound(uint256(uint128(paramSeedB >> 64)), uint256(amt1), uint256(amt1) * 100 + 1));
        uint32 callbackGasLimit = useCallback ? uint32(bound(uint256(uint128(paramSeedA >> 16)), 30_000, 500_000)) : 0;

        OpenOracle.OracleGame memory g;
        g.currentAmount1 = amt1;
        g.currentAmount2 = amt2;
        g.currentReporter = reporter;
        g.token1 = t1;
        g.token2 = t2;
        g.settlementTime = settlementTime;
        g.escalationHalt = escalationHalt;
        g.protocolFeeRecipient = (cbSeed & 2) == 2 ? address(0) : _pickActor(cbSeed >> 1);
        g.settlerReward = SETTLER_REWARD;
        g.disputeDelay = disputeDelay;
        g.feePercentage = feePercentage;
        g.multiplier = multiplier;
        g.callbackContract = useCallback ? address(callback) : address(0);
        g.callbackGasLimit = callbackGasLimit;
        g.protocolFee = protocolFee;
        g.flags = flags;

        uint256 ethSide = 0;
        if (t1 == address(0)) ethSide += amt1;
        if (t2 == address(0)) ethSide += amt2;
        uint256 ethValue = uint256(SETTLER_REWARD) + ethSide;

        // Make sure reporter has enough ETH for the call.
        vm.deal(reporter, reporter.balance + ethValue + 1 ether);

        uint256 idBefore = oracle.nextReportId();
        uint256 ts = block.timestamp;
        uint256 bn = block.number;

        vm.prank(reporter);
        try oracle.report{value: ethValue}(g, false, false, _emptyTiming()) returns (uint256 reportId) {
            // Build the post-report game state for future dispute/settle.
            g.reportTimestamp = uint48((g.flags & FLAG_TIME_TYPE) != 0 ? ts : bn);
            g.lastReportOppoTime = uint48((g.flags & FLAG_TIME_TYPE) != 0 ? bn : ts);
            if ((g.flags & FLAG_TRACK_DISPUTES) != 0) g.numReports = 1;

            OpenOracle.PreimageHelper memory h = OpenOracle.PreimageHelper({
                reportId: reportId,
                creator: reporter,
                blockTimestamp: ts,
                blockNumber: bn
            });

            reports.push(ReportState({id: reportId, game: g, helper: h, settled: false}));
            reportIdToIdx[reportId] = reports.length;

            ghostInflightSettlerETH += SETTLER_REWARD;
            totalReports += 1;

            _markTouched(reporter);
            if (g.protocolFeeRecipient != address(0)) _markTouched(g.protocolFeeRecipient);
        } catch {
            // Bounds may have produced an invalid combo; that's fine, no state change.
            idBefore;
        }
    }

    // ─── Actions: dispute ──────────────────────────────────────────────────

    function actDispute(uint8 actorSeed, uint8 reportSeed, uint8 sideSeed, uint128 newAmt2Seed) external {
        if (reports.length == 0) return;
        uint256 idx = reportSeed % reports.length;
        ReportState storage r = reports[idx];
        if (r.settled) return;
        OpenOracle.OracleGame memory g = r.game;
        if (g.settlementTimestamp != 0) return;

        address disputer = _pickActor(actorSeed);
        address tokenToSwap = (sideSeed & 1) == 0 ? g.token1 : g.token2;
        uint128 oldA1 = g.currentAmount1;
        uint128 oldA2 = g.currentAmount2;

        uint256 nextA1Raw;
        if (oldA1 >= g.escalationHalt) {
            nextA1Raw = uint256(oldA1) + 1;
        } else {
            uint256 scaled = (uint256(oldA1) * uint256(g.multiplier)) / 100;
            nextA1Raw = scaled > uint256(g.escalationHalt) ? uint256(g.escalationHalt) : scaled;
        }
        if (nextA1Raw > type(uint128).max) return;

        uint128 nextA1 = uint128(nextA1Raw);
        uint128 newA2 = uint128(bound(uint256(newAmt2Seed), 1, type(uint128).max - 1));

        // Time-window for dispute: must be >= disputeDelay since report and < settlementTime.
        bool timeType = (g.flags & FLAG_TIME_TYPE) != 0;
        uint48 ct = timeType ? uint48(block.timestamp) : uint48(block.number);
        if (ct >= g.reportTimestamp + g.settlementTime) return;
        if (ct < g.reportTimestamp + g.disputeDelay) {
            uint256 target = uint256(g.reportTimestamp) + g.disputeDelay + 1;
            if (timeType) vm.warp(target);
            else vm.roll(target);
        }
        // Recompute after any warp/roll — the contract uses live block.timestamp/number at call time.
        uint48 currentTime = timeType ? uint48(block.timestamp) : uint48(block.number);

        // Fund disputer (only useful when one of the tokens is ETH; otherwise msg.value must be 0).
        bool ethSide = (g.token1 == address(0) || g.token2 == address(0));
        uint256 disputeValue = ethSide ? 10 ether : 0;
        if (ethSide) vm.deal(disputer, disputer.balance + 10 ether);

        // Precompute protocol fee burn (if applicable).
        uint256 oldSideAmt = (sideSeed & 1) == 0 ? oldA1 : oldA2;
        uint256 protocolFee = (oldSideAmt * g.protocolFee) / 1e7;
        bool burns = protocolFee > 0 && g.protocolFeeRecipient == address(0);

        vm.prank(disputer);
        try oracle.dispute{value: disputeValue}(
            r.id,
            tokenToSwap,
            nextA1,
            newA2,
            disputer,
            false,
            false,
            g,
            r.helper,
            _emptyTiming()
        ) {
            uint48 newOppo = timeType ? uint48(block.number) : uint48(block.timestamp);
            g.currentAmount1 = nextA1;
            g.currentAmount2 = newA2;
            g.currentReporter = disputer;
            g.reportTimestamp = currentTime;
            g.lastReportOppoTime = newOppo;
            if ((g.flags & FLAG_TRACK_DISPUTES) != 0 && g.numReports < type(uint24).max) {
                g.numReports += 1;
            }
            r.game = g;

            if (burns) ghostBurned[tokenToSwap] += protocolFee;
            totalDisputes += 1;
            _markTouched(disputer);
        } catch {}
    }

    // ─── Actions: settle ───────────────────────────────────────────────────

    function actSettle(uint8 reportSeed) external {
        if (reports.length == 0) return;
        uint256 idx = reportSeed % reports.length;
        ReportState storage r = reports[idx];
        if (r.settled) return;
        OpenOracle.OracleGame memory g = r.game;
        if (g.settlementTimestamp != 0) return;
        if (g.reportTimestamp == 0) return;

        bool timeType = (g.flags & FLAG_TIME_TYPE) != 0;
        uint256 target = uint256(g.reportTimestamp) + uint256(g.settlementTime) + 1;
        if (timeType) {
            if (block.timestamp < target) vm.warp(target);
        } else {
            if (block.number < target) vm.roll(target);
        }

        // settle() needs enough gas budget for the callback path; provide generously.
        try oracle.settle(r.id, g, r.helper) {
            uint48 currentTime = timeType ? uint48(block.timestamp) : uint48(block.number);
            g.settlementTimestamp = currentTime;
            r.game = g;
            r.settled = true;

            ghostInflightSettlerETH -= SETTLER_REWARD;
            totalSettles += 1;
            _markTouched(tx.origin); // settler is whoever called handler; conservatively touch tx.origin
        } catch {}
    }

    // ─── Actions: deposit / withdraw / approve / internalTransfer / pushOrCredit / dust ─────

    function actDeposit(uint8 actorSeed, uint8 tokSeed, uint128 amtSeed) external {
        address user = _pickActor(actorSeed);
        address tok = _pickToken(tokSeed);
        uint128 amt = uint128(bound(uint256(amtSeed), 1, 1e21));
        vm.deal(user, user.balance + (tok == address(0) ? uint256(amt) : 0) + 1 ether);

        vm.prank(user);
        try oracle.deposit{value: tok == address(0) ? amt : 0}(tok, amt, user) {
            totalDeposits += 1;
            _markTouched(user);
        } catch {}
    }

    function actWithdraw(uint8 actorSeed, uint8 tokSeed) external {
        address user = _pickActor(actorSeed);
        address tok = _pickToken(tokSeed);
        vm.prank(user);
        try oracle.withdraw(tok) {
            totalWithdrawals += 1;
            _markTouched(user);
        } catch {}
    }

    function actApprove(uint8 ownerSeed, uint8 spenderSeed, uint8 tokSeed, uint256 amtSeed) external {
        address owner = _pickActor(ownerSeed);
        address spender = _pickActor(spenderSeed);
        address tok = _pickToken(tokSeed);
        uint256 amt = bound(amtSeed, 0, type(uint128).max);
        vm.prank(owner);
        try oracle.approveInternal(spender, tok, amt) {} catch {}
    }

    function actInternalTransfer(uint8 fromSeed, uint8 toSeed, uint8 tokSeed, uint128 amtSeed) external {
        address from = _pickActor(fromSeed);
        address to = _pickActor(toSeed);
        if (to == address(0)) return;
        address tok = _pickToken(tokSeed);
        uint128 amt = uint128(bound(uint256(amtSeed), 0, 1e21));

        vm.prank(from);
        try oracle.internalTransferFrom(from, to, tok, amt) {
            totalInternalTransfers += 1;
            _markTouched(from);
            _markTouched(to);
        } catch {}
    }

    function actPushOrCredit(uint8 actorSeed, uint8 tokSeed, uint8 toSeed, uint128 amtSeed) external {
        address caller = _pickActor(actorSeed);
        address to = _pickActor(toSeed);
        if (to == address(0)) return;
        address tok = _pickToken(tokSeed);
        uint128 amt = uint128(bound(uint256(amtSeed), 0, 1e21));

        vm.prank(caller);
        try oracle.pushOrCredit(tok, to, amt) {
            totalPushOrCredits += 1;
            _markTouched(caller);
            _markTouched(to);
        } catch {}
    }

    function actDust(uint8 actorSeed, uint8 t1Seed, uint8 t2Seed) external {
        address user = _pickActor(actorSeed);
        address t1 = _pickToken(t1Seed);
        address t2 = _pickToken(t2Seed);
        vm.prank(user);
        try oracle.dust(t1, t2) {
            _markTouched(user);
        } catch {}
    }

    // ─── Actions: time ─────────────────────────────────────────────────────

    function actWarp(uint16 dtSeed) external {
        uint256 dt = (uint256(dtSeed) % 1800) + 1;
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + (dt / 12 + 1));
    }

    // ─── Actions: adversarial callback mode ────────────────────────────────

    /// @dev Rotates the callback's mode across {Noop, Revert, ConsumeAll, Reenter} so subsequent
    ///      report → settle paths exercise the adversarial branches.
    function actSetCallbackMode(uint8 modeSeed) external {
        AdversarialCallback.Mode m = AdversarialCallback.Mode(modeSeed % 4);
        callback.setMode(m);
    }
}
