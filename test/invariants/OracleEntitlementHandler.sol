// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice Per-actor ENTITLEMENT ledger — the layer above locality. Locality proves no NON-party
///         balance moves; it cannot catch a party taking MORE THAN OWED (a redistribution among an
///         op's legitimate participants that still conserves the global total and touches only
///         declared parties). This handler maintains a ghost that mirrors the contract's payout
///         SPEC per (actor, token), computed from the operation inputs — independent of what the
///         contract actually credits. The invariant then asserts each actor's withdrawable internal
///         balance EQUALS its spec entitlement. A bug that credited the wrong actor, or the right
///         actor by the wrong amount, diverges from the spec mirror and is caught on both sides
///         (the over-credited beneficiary AND the short-changed victim).
///
///         Soundness constraints that keep the mirror exact:
///           - report/dispute tokens are ERC20-only (vanillaA/vanillaB); ETH appears ONLY as the
///             settler reward. So dispute msg.value is 0 and there is no ETH-excess credit to model.
///           - disputers fund externally (tib=false), so no internal-balance debits to track on the
///             funding side — only the contract's explicit credits move withdrawable balances.
///           - every credit the contract makes lands on a slot already seeded by _getDustAmounts,
///             so `withdrawable == credited amount` with no sentinel off-by-one.
contract OracleEntitlementHandler is Test {
    OpenOracle public immutable oracle;

    address[] public actors;
    address[] public tokens; // [vanillaA, vanillaB, ETH]
    address[] public holders;

    address public immutable vA;
    address public immutable vB;
    address internal constant ETH = address(0);
    address internal constant PFR = address(0xFEE);

    uint96 internal constant SETTLER_REWARD = 0.001 ether;
    uint8 internal constant FLAG_TIME_TYPE = 1 << 0;
    uint24 internal constant FEE_PCT = 3000; // /1e7
    uint24 internal constant PROTO_FEE = 1000; // /1e7
    uint256 internal constant PCT_PREC = 1e7;
    uint16 internal constant MULT = 110;

    struct ReportState {
        uint256 id;
        OpenOracle.OracleGame game;
        OpenOracle.PreimageHelper helper;
        bool settled;
    }

    ReportState[] public reports;

    // Ghost: spec-derived withdrawable entitlement per (holder, token).
    mapping(address => mapping(address => uint256)) public entitled;

    uint256 public totalReports;
    uint256 public totalDisputes;
    uint256 public totalSettles;

    constructor(OpenOracle _oracle, address _vA, address _vB) {
        oracle = _oracle;
        vA = _vA;
        vB = _vB;
        holders.push(address(this)); // settler (actSettle has no prank)
    }

    receive() external payable {}

    function addActor(address a) external {
        actors.push(a);
        holders.push(a);
    }

    function initTokensAndHolders() external {
        tokens.push(vA);
        tokens.push(vB);
        tokens.push(ETH);
        holders.push(PFR);
    }

    function reportCount() external view returns (uint256) {
        return reports.length;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    function _pickActor(uint8 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _emptyTiming() internal pure returns (OpenOracle.TimingBoundaries memory t) {}

    /// @dev Distinct token pair from {vA, vB, ETH}. ETH (address(0)) is a first-class side, not just
    ///      the settler reward — exercising the oracle's ETH funding/credit paths.
    function _pickPair(uint8 seed) internal view returns (address t1, address t2) {
        uint8 a = seed % 3;
        uint8 b = (seed / 3) % 3;
        if (b == a) b = (b + 1) % 3;
        t1 = tokens[a];
        t2 = tokens[b];
    }

    // ── report (ERC20 and/or ETH side; settlerReward always in ETH) ───────────
    function actReport(uint8 actorSeed, uint8 pairSeed, uint128 a1Seed, uint128 a2Seed) external {
        address reporter = _pickActor(actorSeed);
        (address t1, address t2) = _pickPair(pairSeed);

        uint128 a1 = uint128(bound(uint256(a1Seed), 1, 1e20));
        uint128 a2 = uint128(bound(uint256(a2Seed), 1, 1e20));

        OpenOracle.OracleGame memory g;
        g.currentAmount1 = a1;
        g.currentAmount2 = a2;
        g.currentReporter = reporter;
        g.token1 = t1;
        g.token2 = t2;
        g.settlementTime = 300;
        g.escalationHalt = type(uint128).max;
        g.protocolFeeRecipient = PFR;
        g.settlerReward = SETTLER_REWARD;
        g.disputeDelay = 5;
        g.feePercentage = FEE_PCT;
        g.multiplier = MULT;
        g.protocolFee = PROTO_FEE;
        g.flags = FLAG_TIME_TYPE;

        // Exact msg.value: settlerReward + any ETH-side amounts. No excess → no excess credit.
        uint256 ethValue = uint256(SETTLER_REWARD) + (t1 == ETH ? a1 : 0) + (t2 == ETH ? a2 : 0);
        vm.deal(reporter, reporter.balance + ethValue);
        uint256 ts = block.timestamp;
        uint256 bn = block.number;

        vm.prank(reporter);
        try oracle.report{value: ethValue}(g, false, false, _emptyTiming()) returns (uint256 reportId) {
            // No withdrawable credits at report: amounts + settlerReward are inflight.
            g.reportTimestamp = uint48(ts);
            g.lastReportOppoTime = uint48(bn);
            reports.push(ReportState({id: reportId, game: g, helper: _helper(reportId, reporter, ts, bn), settled: false}));
            totalReports += 1;
        } catch {}
    }

    // ── dispute ────────────────────────────────────────────────────────────────
    function actDispute(uint8 actorSeed, uint8 reportSeed, bool swapT1, uint128 newA2Seed) external {
        if (reports.length == 0) return;
        uint256 idx = reportSeed % reports.length;
        ReportState storage r = reports[idx];
        if (r.settled || r.game.settlementTimestamp != 0) return;

        OpenOracle.OracleGame memory g = r.game;
        address disputer = _pickActor(actorSeed);
        address prev = g.currentReporter;
        address tokenToSwap = swapT1 ? g.token1 : g.token2;

        uint128 oldA1 = g.currentAmount1;
        uint128 oldA2 = g.currentAmount2;
        uint256 nextA1Raw = (uint256(oldA1) * MULT) / 100;
        if (nextA1Raw > type(uint128).max || nextA1Raw == oldA1) return;
        uint128 newA1 = uint128(nextA1Raw);
        uint128 newA2 = uint128(bound(uint256(newA2Seed), 1, 1e20));

        if (block.timestamp >= uint256(g.reportTimestamp) + g.settlementTime) return;
        if (block.timestamp < uint256(g.reportTimestamp) + g.disputeDelay) {
            vm.warp(uint256(g.reportTimestamp) + g.disputeDelay + 1);
        }
        uint48 ct = uint48(block.timestamp);
        bool isSelf = (disputer == prev);

        // Exact ETH the contract will require for the funding legs that are ETH-sided. Sending
        // exactly this leaves no excess, so no _credit(disputer, ETH, excess) to mirror.
        uint256 ethValue =
            _disputeEthRequired(tokenToSwap, g.token1, g.token2, oldA1, oldA2, newA1, newA2, isSelf);
        if (ethValue > 0) vm.deal(disputer, disputer.balance + ethValue);

        vm.prank(disputer);
        try oracle.dispute{value: ethValue}(
            r.id, tokenToSwap, newA1, newA2, disputer, false, false, g, r.helper, _emptyTiming()
        ) {
            _mirrorDispute(tokenToSwap, g.token1, g.token2, oldA1, oldA2, newA2, disputer, prev, isSelf);
            g.currentAmount1 = newA1;
            g.currentAmount2 = newA2;
            g.currentReporter = disputer;
            g.reportTimestamp = ct;
            g.lastReportOppoTime = uint48(block.number);
            r.game = g;
            totalDisputes += 1;
        } catch {}
    }

    /// @dev Mirror of OpenOracleSlim.dispute's credit arms (the only ops that move withdrawable
    ///      balances; funding is external so there are no debits).
    function _mirrorDispute(
        address tokenToSwap,
        address t1,
        address t2,
        uint128 oldA1,
        uint128 oldA2,
        uint128 newA2,
        address disputer,
        address prev,
        bool isSelf
    ) internal {
        if (tokenToSwap == t1) {
            uint256 fee = (uint256(oldA1) * FEE_PCT) / PCT_PREC;
            uint256 pf = (uint256(oldA1) * PROTO_FEE) / PCT_PREC;
            if (pf > 0) entitled[PFR][t1] += pf;
            if (newA2 < oldA2) entitled[disputer][t2] += uint256(oldA2) - newA2; // netToken2Receive
            if (!isSelf) entitled[prev][t1] += 2 * uint256(oldA1) + fee;
        } else {
            uint256 fee = (uint256(oldA2) * FEE_PCT) / PCT_PREC;
            uint256 pf = (uint256(oldA2) * PROTO_FEE) / PCT_PREC;
            if (pf > 0) entitled[PFR][t2] += pf;
            if (isSelf) {
                uint256 token2Needed = uint256(newA2) + pf;
                if (token2Needed < oldA2) entitled[disputer][t2] += uint256(oldA2) - token2Needed;
            } else {
                entitled[prev][t2] += 2 * uint256(oldA2) + fee;
            }
        }
    }

    /// @dev Exact ETH the contract requires from the disputer (tib=false ⇒ every ETH-sided funding
    ///      leg comes from msg.value). Mirrors OpenOracleSlim.dispute's funding amounts so we can
    ///      send precisely that and avoid an excess credit.
    function _disputeEthRequired(
        address tokenToSwap,
        address t1,
        address t2,
        uint128 oldA1,
        uint128 oldA2,
        uint128 newA1,
        uint128 newA2,
        bool isSelf
    ) internal pure returns (uint256 ethReq) {
        if (tokenToSwap == t1) {
            uint256 pf = (uint256(oldA1) * PROTO_FEE) / PCT_PREC;
            uint256 fee = (uint256(oldA1) * FEE_PCT) / PCT_PREC;
            if (t2 == ETH && newA2 >= oldA2) ethReq += uint256(newA2) - oldA2; // netToken2Contribution
            if (t1 == ETH) {
                ethReq += isSelf ? (uint256(newA1) - oldA1 + pf) : (uint256(newA1) + oldA1 + fee + pf);
            }
        } else {
            uint256 pf = (uint256(oldA2) * PROTO_FEE) / PCT_PREC;
            uint256 fee = (uint256(oldA2) * FEE_PCT) / PCT_PREC;
            if (t1 == ETH && newA1 > oldA1) ethReq += uint256(newA1) - oldA1; // netToken1Contribution
            if (t2 == ETH) {
                if (isSelf) {
                    uint256 token2Needed = uint256(newA2) + pf;
                    if (token2Needed >= oldA2) ethReq += token2Needed - oldA2;
                } else {
                    ethReq += uint256(newA2) + oldA2 + fee + pf;
                }
            }
        }
    }

    // ── settle ───────────────────────────────────────────────────────────────
    function actSettle(uint8 reportSeed) external {
        if (reports.length == 0) return;
        uint256 idx = reportSeed % reports.length;
        ReportState storage r = reports[idx];
        if (r.settled || r.game.settlementTimestamp != 0 || r.game.reportTimestamp == 0) return;

        OpenOracle.OracleGame memory g = r.game;
        uint256 target = uint256(g.reportTimestamp) + g.settlementTime + 1;
        if (block.timestamp < target) vm.warp(target);

        try oracle.settle(r.id, g, r.helper) {
            entitled[g.currentReporter][g.token1] += g.currentAmount1;
            entitled[g.currentReporter][g.token2] += g.currentAmount2;
            entitled[address(this)][ETH] += g.settlerReward; // settler == handler (no prank)
            g.settlementTimestamp = uint48(block.timestamp);
            r.game = g;
            r.settled = true;
            totalSettles += 1;
        } catch {}
    }

    // ── deposit / withdraw / internalTransfer ────────────────────────────────
    function actDeposit(uint8 actorSeed, uint8 benSeed, uint8 tokSeed, uint128 amtSeed) external {
        address user = _pickActor(actorSeed);
        address beneficiary = _pickActor(benSeed);
        address tok = tokens[tokSeed % tokens.length];
        uint128 amt = uint128(bound(uint256(amtSeed), 1, 1e20));
        if (tok == ETH) vm.deal(user, user.balance + amt);

        vm.prank(user);
        try oracle.deposit{value: tok == ETH ? amt : 0}(tok, amt, beneficiary) {
            entitled[beneficiary][tok] += amt;
        } catch {}
    }

    function actWithdraw(uint8 actorSeed, uint8 tokSeed, uint128 amtSeed) external {
        address user = _pickActor(actorSeed);
        address tok = tokens[tokSeed % tokens.length];
        uint256 amt = bound(uint256(amtSeed), 1, type(uint256).max);

        vm.prank(user);
        try oracle.withdraw(tok, amt) returns (uint256 sent) {
            entitled[user][tok] -= sent;
        } catch {}
    }

    function actInternalTransfer(uint8 fromSeed, uint8 toSeed, uint8 tokSeed, uint128 amtSeed) external {
        address from = _pickActor(fromSeed);
        address to = _pickActor(toSeed);
        address tok = tokens[tokSeed % tokens.length];
        uint128 amt = uint128(bound(uint256(amtSeed), 1, 1e20));

        vm.prank(from);
        try oracle.internalTransferFrom(from, to, tok, amt) {
            entitled[from][tok] -= amt;
            entitled[to][tok] += amt;
        } catch {}
    }

    function actWarp(uint16 dtSeed) external {
        uint256 dt = (uint256(dtSeed) % 600) + 1;
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + (dt / 12 + 1));
    }

    function _helper(uint256 id, address creator, uint256 ts, uint256 bn)
        internal
        pure
        returns (OpenOracle.PreimageHelper memory)
    {
        return OpenOracle.PreimageHelper({reportId: id, creator: creator, blockTimestamp: ts, blockNumber: bn});
    }
}
