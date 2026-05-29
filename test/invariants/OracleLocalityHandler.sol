// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice Handler for the LOCALITY referee. Global per-token conservation (already covered by
///         OracleSystemInvariantsTest) catches insolvency and value-printing, but is blind to a
///         conservation-preserving REDISTRIBUTION — a victim's funds moved to an attacker with the
///         books still balancing. That is the payoff of a successful reentrancy or a plain
///         accounting bug, and it sails straight through conservation.
///
///         Locality closes that gap WITHOUT modeling payouts: for each top-level action we declare
///         the set of addresses legitimately party to it (the caller plus every address the call is
///         specified to credit/debit), snapshot all internal balances, run the action, and assert
///         that every NON-party holder's balances are byte-for-byte unchanged. Value can only move
///         between declared participants; it can never silently leave or enter a bystander's slot.
///
///         The party set is deliberately a SUPERSET (always includes msg.sender) so a mis-modeled
///         payout can never false-positive; the invariant still catches the meaningful direction —
///         a non-party losing or gaining value. Tokens are vanilla ERC20 + ETH only (no reentrant
///         mocks) so the property is exact; the armed-reentrancy interleavings are pinned separately
///         in OpenOracleArmedReentrancyTest.
contract OracleLocalityHandler is Test {
    OpenOracle public immutable oracle;

    address[] public actors;
    address[] public tokens; // index 0 = ETH
    address[] public holders; // every address whose internal balance we police

    uint96 internal constant SETTLER_REWARD = 0.001 ether;
    uint8 internal constant FLAG_TIME_TYPE = 1 << 0;
    address internal constant PFR = address(0xFEE);

    struct ReportState {
        uint256 id;
        OpenOracle.OracleGame game;
        OpenOracle.PreimageHelper helper;
        bool settled;
    }

    ReportState[] public reports;

    // ── Locality bookkeeping (stamped so nothing needs clearing) ──────────────
    uint256 internal actionId;
    mapping(address => uint256) internal partyAt; // holder -> actionId it was a party of
    mapping(bytes32 => uint256) internal snapBal; // key(holder,token) -> balance at action start

    bool public localityViolated;
    string public violationTag;

    // Stats
    uint256 public totalReports;
    uint256 public totalDisputes;
    uint256 public totalSettles;
    uint256 public totalOps;

    constructor(OpenOracle _oracle) {
        oracle = _oracle;
        holders.push(address(this)); // handler is the settler / a possible recipient
    }

    receive() external payable {}

    // ── setup ─────────────────────────────────────────────────────────────────
    function addActor(address a) external {
        actors.push(a);
        holders.push(a);
    }

    function addToken(address t) external {
        tokens.push(t);
    }

    function initHolders() external {
        holders.push(PFR);
    }

    function reportCount() external view returns (uint256) {
        return reports.length;
    }

    function _pickActor(uint8 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickToken(uint8 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    function _emptyTiming() internal pure returns (OpenOracle.TimingBoundaries memory t) {}

    // ── locality core ───────────────────────────────────────────────────────
    function _begin() internal {
        actionId += 1;
        totalOps += 1;
        for (uint256 h = 0; h < holders.length; h++) {
            for (uint256 t = 0; t < tokens.length; t++) {
                snapBal[_key(holders[h], tokens[t])] = oracle.tokenHolder(holders[h], tokens[t]);
            }
        }
    }

    function _party(address a) internal {
        partyAt[a] = actionId;
    }

    function _key(address h, address t) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(h, t));
    }

    /// @dev After the action, every non-party holder's balances must equal the snapshot.
    function _check(string memory tag) internal {
        for (uint256 h = 0; h < holders.length; h++) {
            address holder = holders[h];
            if (partyAt[holder] == actionId) continue; // party — allowed to move
            for (uint256 t = 0; t < tokens.length; t++) {
                if (oracle.tokenHolder(holder, tokens[t]) != snapBal[_key(holder, tokens[t])]) {
                    localityViolated = true;
                    violationTag = tag;
                    return;
                }
            }
        }
    }

    // ── actions ───────────────────────────────────────────────────────────────

    function actReport(uint8 actorSeed, uint8 t1Seed, uint8 t2Seed, uint128 a1Seed, uint128 a2Seed, bool withFee)
        external
    {
        address reporter = _pickActor(actorSeed);
        address t1 = _pickToken(t1Seed);
        address t2 = _pickToken(t2Seed);
        if (t1 == t2) return;

        uint128 a1 = uint128(bound(uint256(a1Seed), 1, 1e21));
        uint128 a2 = uint128(bound(uint256(a2Seed), 1, 1e21));

        OpenOracle.OracleGame memory g;
        g.currentAmount1 = a1;
        g.currentAmount2 = a2;
        g.currentReporter = reporter;
        g.token1 = t1;
        g.token2 = t2;
        g.settlementTime = 300;
        g.escalationHalt = type(uint128).max;
        g.protocolFeeRecipient = withFee ? PFR : address(0);
        g.settlerReward = SETTLER_REWARD;
        g.disputeDelay = 5;
        g.feePercentage = 3000;
        g.multiplier = 110;
        g.protocolFee = withFee ? 1000 : 0;
        g.flags = FLAG_TIME_TYPE;

        uint256 ethSide;
        if (t1 == address(0)) ethSide += a1;
        if (t2 == address(0)) ethSide += a2;
        uint256 ethValue = uint256(SETTLER_REWARD) + ethSide;
        vm.deal(reporter, reporter.balance + ethValue);

        uint256 ts = block.timestamp;
        uint256 bn = block.number;

        _begin();
        _party(reporter);
        if (g.protocolFeeRecipient != address(0)) _party(g.protocolFeeRecipient);

        vm.prank(reporter);
        try oracle.report{value: ethValue}(g, false, false, _emptyTiming()) returns (uint256 reportId) {
            _check("report");
            g.reportTimestamp = uint48(ts);
            g.lastReportOppoTime = uint48(bn);
            reports.push(ReportState({id: reportId, game: g, helper: _helper(reportId, reporter, ts, bn), settled: false}));
            totalReports += 1;
        } catch {}
    }

    function actDispute(uint8 actorSeed, uint8 reportSeed, uint8 sideSeed, uint128 newA2Seed) external {
        if (reports.length == 0) return;
        uint256 idx = reportSeed % reports.length;
        ReportState storage r = reports[idx];
        if (r.settled || r.game.settlementTimestamp != 0) return;

        OpenOracle.OracleGame memory g = r.game;
        address disputer = _pickActor(actorSeed);
        address previousReporter = g.currentReporter;
        address tokenToSwap = (sideSeed & 1) == 0 ? g.token1 : g.token2;

        uint128 oldA1 = g.currentAmount1;
        uint256 nextA1Raw = (uint256(oldA1) * g.multiplier) / 100;
        if (nextA1Raw > g.escalationHalt) nextA1Raw = g.escalationHalt;
        if (nextA1Raw > type(uint128).max || nextA1Raw == oldA1) return;
        uint128 nextA1 = uint128(nextA1Raw);
        uint128 newA2 = uint128(bound(uint256(newA2Seed), 1, 1e21));

        // Move into the dispute window, then read the resulting time on its own line.
        if (block.timestamp >= uint256(g.reportTimestamp) + g.settlementTime) return;
        if (block.timestamp < uint256(g.reportTimestamp) + g.disputeDelay) {
            vm.warp(uint256(g.reportTimestamp) + g.disputeDelay + 1);
        }
        uint48 ct = uint48(block.timestamp);

        bool ethSide = (g.token1 == address(0) || g.token2 == address(0));
        uint256 disputeValue = ethSide ? 100 ether : 0;
        if (ethSide) vm.deal(disputer, disputer.balance + disputeValue);

        _begin();
        _party(disputer);
        _party(previousReporter);
        if (g.protocolFeeRecipient != address(0)) _party(g.protocolFeeRecipient);

        vm.prank(disputer);
        try oracle.dispute{value: disputeValue}(
            r.id, tokenToSwap, nextA1, newA2, disputer, false, false, g, r.helper, _emptyTiming()
        ) {
            _check("dispute");
            uint48 oppo = uint48(block.number);
            g.currentAmount1 = nextA1;
            g.currentAmount2 = newA2;
            g.currentReporter = disputer;
            g.reportTimestamp = ct;
            g.lastReportOppoTime = oppo;
            r.game = g;
            totalDisputes += 1;
        } catch {}
    }

    function actSettle(uint8 reportSeed) external {
        if (reports.length == 0) return;
        uint256 idx = reportSeed % reports.length;
        ReportState storage r = reports[idx];
        if (r.settled || r.game.settlementTimestamp != 0 || r.game.reportTimestamp == 0) return;

        OpenOracle.OracleGame memory g = r.game;
        uint256 target = uint256(g.reportTimestamp) + g.settlementTime + 1;
        if (block.timestamp < target) vm.warp(target);

        _begin();
        _party(g.currentReporter);
        _party(address(this)); // settler (no prank → handler)

        try oracle.settle(r.id, g, r.helper) {
            _check("settle");
            g.settlementTimestamp = uint48(block.timestamp);
            r.game = g;
            r.settled = true;
            totalSettles += 1;
        } catch {}
    }

    function actDeposit(uint8 actorSeed, uint8 benSeed, uint8 tokSeed, uint128 amtSeed) external {
        address user = _pickActor(actorSeed);
        address beneficiary = _pickActor(benSeed);
        address tok = _pickToken(tokSeed);
        uint128 amt = uint128(bound(uint256(amtSeed), 1, 1e21));
        vm.deal(user, user.balance + (tok == address(0) ? uint256(amt) : 0));

        _begin();
        _party(beneficiary);

        vm.prank(user);
        try oracle.deposit{value: tok == address(0) ? amt : 0}(tok, amt, beneficiary) {
            _check("deposit");
        } catch {}
    }

    function actWithdraw(uint8 actorSeed, uint8 tokSeed) external {
        address user = _pickActor(actorSeed);
        address tok = _pickToken(tokSeed);
        _begin();
        _party(user);
        vm.prank(user);
        try oracle.withdraw(tok, type(uint256).max) {
            _check("withdraw");
        } catch {}
    }

    function actInternalTransfer(uint8 fromSeed, uint8 toSeed, uint8 tokSeed, uint128 amtSeed) external {
        address from = _pickActor(fromSeed);
        address to = _pickActor(toSeed);
        address tok = _pickToken(tokSeed);
        uint128 amt = uint128(bound(uint256(amtSeed), 0, 1e21));

        _begin();
        _party(from);
        _party(to);

        vm.prank(from);
        try oracle.internalTransferFrom(from, to, tok, amt) {
            _check("internalTransfer");
        } catch {}
    }

    function actPushOrCredit(uint8 actorSeed, uint8 toSeed, uint8 tokSeed, uint128 amtSeed) external {
        address caller = _pickActor(actorSeed);
        address to = _pickActor(toSeed);
        address tok = _pickToken(tokSeed);
        uint128 amt = uint128(bound(uint256(amtSeed), 0, 1e21));

        _begin();
        _party(caller);
        _party(to);

        vm.prank(caller);
        try oracle.pushOrCredit(tok, to, amt) {
            _check("pushOrCredit");
        } catch {}
    }

    function actDust(uint8 actorSeed, uint8 t1Seed, uint8 t2Seed) external {
        address user = _pickActor(actorSeed);
        _begin();
        _party(user);
        vm.prank(user);
        try oracle.dust(_pickToken(t1Seed), _pickToken(t2Seed)) {
            _check("dust");
        } catch {}
    }

    function actWarp(uint16 dtSeed) external {
        uint256 dt = (uint256(dtSeed) % 600) + 1;
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + (dt / 12 + 1));
    }

    /// @dev Referee self-test: mark an unrelated keeper as the sole party, move value to `victim`,
    ///      then run the locality check. Returns whether the violation was caught. Used by the
    ///      invariant suite to prove the detector actually fires on a non-party balance move (guards
    ///      against a toothless referee). `victim` must be a registered holder.
    function selftestForeignMoveIsCaught(address victim) external returns (bool) {
        _begin();
        _party(address(0xC0FFEE)); // sole party — deliberately NOT the victim
        vm.deal(address(this), address(this).balance + 1 ether);
        oracle.deposit{value: 1 ether}(address(0), 1 ether, victim);
        _check("selftest");
        return localityViolated;
    }

    function _helper(uint256 id, address creator, uint256 ts, uint256 bn)
        internal
        pure
        returns (OpenOracle.PreimageHelper memory)
    {
        return OpenOracle.PreimageHelper({reportId: id, creator: creator, blockTimestamp: ts, blockNumber: bn});
    }
}
