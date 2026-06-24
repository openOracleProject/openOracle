// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {ArmableReentrantToken} from "../utils/ArmableReentrantToken.sol";

/// @notice Fuzz handler that drives the ERC20-transferFrom/transfer reentry hook with REAL,
///         fuzzer-chosen payloads — the fuzzer-driven completion of item 1 (the deterministic
///         windows are pinned in OpenOracleArmedReentrancyTest). On every operation that moves the
///         armable token, a fuzzer-selected reentrant payload (settle/withdraw/internalTransfer/
///         pushOrCredit/dust against current live state) fires at a fuzzer-chosen trigger point
///         (before/after the balance move).
///
///         Referee: SOLVENCY — for every token, the oracle's real balance is >= the sum of all
///         withdrawable internal balances. This is the reentrancy-robust form of conservation: it
///         needs no off-chain mirror of report state, so a reentrant settle/dispute that mutates a
///         report behind the handler's back cannot produce a false positive. A reentrancy that
///         printed value (double-credit) would push withdrawable above the real backing and trip it.
///         (Pure conservation-preserving theft is locality's job — OracleLocalityInvariants.)
contract OracleArmedReentrancyHandler is Test {
    OpenOracle public immutable oracle;
    ArmableReentrantToken public immutable armToken;

    address[] public actors;
    address[] public tokens; // [ETH, vanillaA, armToken]

    struct ReportState {
        uint256 id;
        OpenOracle.OracleGame game;
        OpenOracle.PreimageHelper helper;
        bool settled;
    }

    ReportState[] public reports;

    uint96 internal constant SETTLER_REWARD = 0.001 ether;
    uint8 internal constant FLAG_TIME_TYPE = 1 << 0;
    address internal constant PFR = address(0xFEE);

    uint256 public totalReports;
    uint256 public totalDisputes;
    uint256 public totalSettles;
    uint256 public reentriesFired; // outer ops during which the armed reentry actually executed
    uint256 public reentrantDisputesLanded; // reentrant kind-6 disputes that SUCCEEDED (ran credit-arms)
    uint8 internal lastArmKind;
    bytes4 internal constant PUSH_OR_CREDIT_SELECTOR = bytes4(keccak256("pushOrCredit(address,address,uint128)"));
    bytes4 internal constant PUSH_OR_CREDIT_GAS_SELECTOR =
        bytes4(keccak256("pushOrCredit(address,address,uint128,uint32)"));

    constructor(OpenOracle _oracle, ArmableReentrantToken _armToken) {
        oracle = _oracle;
        armToken = _armToken;
    }

    receive() external payable {}

    function addActor(address a) external {
        actors.push(a);
    }

    function addToken(address t) external {
        tokens.push(t);
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

    // ── arming: build a fuzzer-chosen reentrant payload against current live state ──
    function _arm(uint8 armSeed) internal {
        _armKind(armSeed % 8, armSeed, (armSeed & 0x40) != 0);
    }

    /// @param kind 0 = no reentry; 1 = settle a live report; 2 = withdraw; 3 = internalTransfer;
    ///             4 = pushOrCredit; 5 = dust; 6 = DISPUTE a live report; 7 = a fresh REPORT.
    ///             The reentry's msg.sender is the armToken contract; disputes/reports are funded via
    ///             an actor's internal balance (tib=true) with armToken as the approved spender, so
    ///             they can actually LAND and exercise the credit-arms — the cross-token
    ///             over-credit-then-backfill path the menu previously never reached.
    function _armKind(uint8 kind, uint8 seed, bool before) internal {
        address actor = _pickActor(seed >> 1);
        address tok = _pickToken(seed >> 2);

        bytes memory payload;
        if (kind == 1 && reports.length > 0) {
            ReportState storage r = reports[uint256(seed) % reports.length];
            payload = abi.encodeCall(oracle.settle, (r.id, r.game, r.helper));
        } else if (kind == 2) {
            payload = abi.encodeCall(oracle.withdraw, (tok, type(uint256).max));
        } else if (kind == 3) {
            payload = abi.encodeCall(oracle.internalTransferFrom, (address(armToken), actor, tok, uint128(1e18)));
        } else if (kind == 4) {
            if ((seed & 0x80) == 0) {
                payload = abi.encodeWithSelector(PUSH_OR_CREDIT_SELECTOR, tok, actor, uint128(1e18));
            } else {
                payload = abi.encodeWithSelector(
                    PUSH_OR_CREDIT_GAS_SELECTOR, tok, actor, uint128(1e18), uint32(uint256(seed) % 200_001)
                );
            }
        } else if (kind == 5) {
            payload = abi.encodeCall(oracle.dust, (tokens[1], address(armToken)));
        } else if (kind == 6 && reports.length > 0) {
            ReportState storage r = reports[uint256(seed) % reports.length];
            OpenOracle.OracleGame memory dg = r.game;
            uint256 nA1 = (uint256(dg.currentAmount1) * dg.multiplier) / 100;
            if (r.settled || nA1 > type(uint128).max || nA1 == dg.currentAmount1) {
                armToken.disarm();
                return;
            }
            address swapTok = (seed & 0x20) == 0 ? dg.token1 : dg.token2;
            payload = abi.encodeCall(
                oracle.dispute,
                (r.id, swapTok, uint128(nA1), uint128(1e18), actor, true, true, dg, r.helper, _emptyTiming())
            );
        } else if (kind == 7) {
            payload = abi.encodeCall(oracle.report, (_reentrantReportGame(actor), true, true, _emptyTiming()));
        } else {
            armToken.disarm();
            lastArmKind = 0;
            return;
        }
        lastArmKind = kind;
        armToken.arm(address(oracle), payload, before);
    }

    /// @dev A fresh report fully fundable from `reporter`'s internal balance (settlerReward 0 so the
    ///      value-less reentrant call suffices; armToken-spender approval set up in the test).
    function _reentrantReportGame(address reporter) internal view returns (OpenOracle.OracleGame memory g) {
        g.currentAmount1 = 1e18;
        g.currentAmount2 = 1e18;
        g.currentReporter = reporter;
        g.token1 = tokens[1]; // vanillaA
        g.token2 = address(armToken);
        g.settlementTime = 300;
        g.escalationHalt = type(uint128).max;
        g.protocolFeeRecipient = address(0);
        g.settlerReward = 0;
        g.disputeDelay = 5;
        g.feePercentage = 0;
        g.multiplier = 110;
        g.protocolFee = 0;
        g.flags = FLAG_TIME_TYPE;
    }

    function _nonArmToken(uint8 seed) internal view returns (address) {
        return (seed & 1) == 0 ? tokens[0] : tokens[1]; // ETH or vanillaA
    }

    function _afterArmedCall() internal {
        if (armToken.attempted()) {
            reentriesFired += 1;
            if (lastArmKind == 6 && armToken.lastCallOk()) reentrantDisputesLanded += 1;
        }
        armToken.disarm();
        lastArmKind = 0;
    }

    // ── actions ───────────────────────────────────────────────────────────────

    function actReport(uint8 actorSeed, uint8 t1Seed, uint8 t2Seed, uint128 a1Seed, uint128 a2Seed, uint8 armSeed)
        external
    {
        _runReport(_pickActor(actorSeed), _pickToken(t1Seed), _pickToken(t2Seed), a1Seed, a2Seed, armSeed % 8, armSeed);
    }

    /// @notice Forces the armable token onto one side of the pair and a non-zero reentry kind, so the
    ///         funding pull is guaranteed to fire the armed reentry. Drives the report hash-then-fund
    ///         window hard (the generic actReport leaves it to chance).
    function actArmedReport(uint8 actorSeed, uint8 sideSeed, uint128 a1Seed, uint128 a2Seed, uint8 armSeed) external {
        address other = _nonArmToken(sideSeed);
        bool armFirst = (sideSeed & 2) == 0;
        address t1 = armFirst ? address(armToken) : other;
        address t2 = armFirst ? other : address(armToken);
        _runReport(_pickActor(actorSeed), t1, t2, a1Seed, a2Seed, (armSeed % 7) + 1, armSeed);
    }

    function _runReport(address reporter, address t1, address t2, uint128 a1Seed, uint128 a2Seed, uint8 kind, uint8 armSeed)
        internal
    {
        if (t1 == t2) return;

        // Bounded small so the reentrant disputer can always fund the grown amounts from its
        // internal balance, letting kind-6 reentrant disputes actually land.
        uint128 a1 = uint128(bound(uint256(a1Seed), 1, 1e18));
        uint128 a2 = uint128(bound(uint256(a2Seed), 1, 1e18));

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
        // Vary disputeDelay INCLUDING 0: with disputeDelay == 0 a reentrant dispute can land on a
        // same-block live report (the in-block over-credit-then-backfill case the deterministic
        // window test cannot reach, since disputeDelay > 0 there seals it).
        g.disputeDelay = uint24(uint256(a2Seed >> 64) % 6);
        g.feePercentage = 3000;
        g.multiplier = 110;
        g.protocolFee = 1000;
        g.flags = FLAG_TIME_TYPE;

        uint256 ethSide;
        if (t1 == address(0)) ethSide += a1;
        if (t2 == address(0)) ethSide += a2;
        uint256 ethValue = uint256(SETTLER_REWARD) + ethSide;
        vm.deal(reporter, reporter.balance + ethValue);

        uint256 ts = block.timestamp;
        uint256 bn = block.number;

        _armKind(kind, armSeed, (armSeed & 0x40) != 0);
        vm.prank(reporter);
        try oracle.report{value: ethValue}(g, false, false, _emptyTiming()) returns (uint256 reportId) {
            g.reportTimestamp = uint48(ts);
            g.lastReportOppoTime = uint48(bn);
            reports.push(ReportState({id: reportId, game: g, helper: _helper(reportId, reporter, ts, bn), settled: false}));
            totalReports += 1;
        } catch {}
        _afterArmedCall();
    }

    function actDispute(uint8 actorSeed, uint8 reportSeed, uint8 sideSeed, uint128 newA2Seed, uint8 armSeed) external {
        if (reports.length == 0) return;
        uint256 idx = reportSeed % reports.length;
        ReportState storage r = reports[idx];
        if (r.settled || r.game.settlementTimestamp != 0) return;

        OpenOracle.OracleGame memory g = r.game;
        address disputer = _pickActor(actorSeed);
        address tokenToSwap = (sideSeed & 1) == 0 ? g.token1 : g.token2;

        uint128 oldA1 = g.currentAmount1;
        uint256 nextA1Raw = (uint256(oldA1) * g.multiplier) / 100;
        if (nextA1Raw > g.escalationHalt) nextA1Raw = g.escalationHalt;
        if (nextA1Raw > type(uint128).max || nextA1Raw == oldA1) return;
        uint128 nextA1 = uint128(nextA1Raw);
        uint128 newA2 = uint128(bound(uint256(newA2Seed), 1, 1e21));

        if (block.timestamp >= uint256(g.reportTimestamp) + g.settlementTime) return;
        if (block.timestamp < uint256(g.reportTimestamp) + g.disputeDelay) {
            vm.warp(uint256(g.reportTimestamp) + g.disputeDelay + 1);
        }
        uint48 ct = uint48(block.timestamp);

        bool ethSide = (g.token1 == address(0) || g.token2 == address(0));
        uint256 disputeValue = ethSide ? 100 ether : 0;
        if (ethSide) vm.deal(disputer, disputer.balance + disputeValue);

        _arm(armSeed);
        vm.prank(disputer);
        try oracle.dispute{value: disputeValue}(
            r.id, tokenToSwap, nextA1, newA2, disputer, false, false, g, r.helper, _emptyTiming()
        ) {
            g.currentAmount1 = nextA1;
            g.currentAmount2 = newA2;
            g.currentReporter = disputer;
            g.reportTimestamp = ct;
            g.lastReportOppoTime = uint48(block.number);
            r.game = g;
            totalDisputes += 1;
        } catch {}
        _afterArmedCall();
    }

    function actSettle(uint8 reportSeed) external {
        if (reports.length == 0) return;
        uint256 idx = reportSeed % reports.length;
        ReportState storage r = reports[idx];
        if (r.settled || r.game.settlementTimestamp != 0 || r.game.reportTimestamp == 0) return;

        OpenOracle.OracleGame memory g = r.game;
        uint256 target = uint256(g.reportTimestamp) + g.settlementTime + 1;
        if (block.timestamp < target) vm.warp(target);

        try oracle.settle(r.id, g, r.helper) {
            g.settlementTimestamp = uint48(block.timestamp);
            r.game = g;
            r.settled = true;
            totalSettles += 1;
        } catch {}
    }

    function actDeposit(uint8 actorSeed, uint8 benSeed, uint8 tokSeed, uint128 amtSeed, uint8 armSeed) external {
        _runDeposit(_pickActor(actorSeed), _pickActor(benSeed), _pickToken(tokSeed), amtSeed, armSeed % 8, armSeed);
    }

    /// @notice Forces an armToken deposit and a non-zero reentry kind, fired (per armSeed bit) BEFORE
    ///         the pull — the credit-before-transfer window. Beneficiary defaults toward armToken so
    ///         a credited-beneficiary reentry is in play.
    function actArmedDeposit(uint8 actorSeed, uint8 benSeed, uint128 amtSeed, uint8 armSeed) external {
        address beneficiary = (benSeed & 1) == 0 ? address(armToken) : _pickActor(benSeed);
        _runDeposit(_pickActor(actorSeed), beneficiary, address(armToken), amtSeed, (armSeed % 7) + 1, armSeed);
    }

    function _runDeposit(address user, address beneficiary, address tok, uint128 amtSeed, uint8 kind, uint8 armSeed)
        internal
    {
        uint128 amt = uint128(bound(uint256(amtSeed), 1, 1e21));
        vm.deal(user, user.balance + (tok == address(0) ? uint256(amt) : 0));

        _armKind(kind, armSeed, (armSeed & 0x40) != 0);
        vm.prank(user);
        try oracle.deposit{value: tok == address(0) ? amt : 0}(tok, amt, beneficiary) {} catch {}
        _afterArmedCall();
    }

    /// @notice Self-contained landing of a reentrant DISPUTE: create a FRESH report with
    ///         disputeDelay == 0 (immediately disputable, hash fresh), then fire a kind-6 reentrant
    ///         dispute against it — funded from the disputer's internal balance with armToken as the
    ///         approved spender — during an armToken deposit in the SAME block. This makes a landing
    ///         near-certain per call, so the afterInvariant "a reentrant dispute landed" gate is
    ///         robust every run rather than dependent on the fuzzer hitting the window by chance.
    function actLandReentrantDispute(uint8 reporterSeed, uint8 disputerSeed, bool swapArmSide) external {
        address reporter = _pickActor(reporterSeed);
        address disputer = _pickActor(disputerSeed);

        OpenOracle.OracleGame memory g;
        g.currentAmount1 = 1e18;
        g.currentAmount2 = 1e18;
        g.currentReporter = reporter;
        g.token1 = address(armToken);
        g.token2 = tokens[1]; // vanillaA
        g.settlementTime = 300;
        g.escalationHalt = type(uint128).max;
        g.protocolFeeRecipient = PFR;
        g.settlerReward = SETTLER_REWARD;
        g.disputeDelay = 0; // disputable in-block
        g.feePercentage = 3000;
        g.multiplier = 110;
        g.protocolFee = 1000;
        g.flags = FLAG_TIME_TYPE;

        uint256 ts = block.timestamp;
        uint256 bn = block.number;
        vm.deal(reporter, reporter.balance + SETTLER_REWARD);

        vm.prank(reporter);
        try oracle.report{value: SETTLER_REWARD}(g, false, false, _emptyTiming()) returns (uint256 reportId) {
            totalReports += 1;
            g.reportTimestamp = uint48(ts);
            g.lastReportOppoTime = uint48(bn);
            OpenOracle.PreimageHelper memory h = _helper(reportId, reporter, ts, bn);

            // Arm a dispute against the just-created report (fresh hash, in-window, disputeDelay 0).
            address swapTok = swapArmSide ? g.token1 : g.token2;
            uint128 nA1 = uint128((uint256(g.currentAmount1) * g.multiplier) / 100);
            bytes memory payload = abi.encodeCall(
                oracle.dispute, (reportId, swapTok, nA1, uint128(1e18), disputer, true, true, g, h, _emptyTiming())
            );
            armToken.arm(address(oracle), payload, false);
            lastArmKind = 6;

            // Trigger: an armToken deposit; its transferFrom fires the armed reentrant dispute.
            vm.prank(reporter);
            try oracle.deposit(address(armToken), 1e18, reporter) {} catch {}
            _afterArmedCall();
        } catch {}
    }

    function actWithdraw(uint8 actorSeed, uint8 tokSeed, uint8 armSeed) external {
        address user = _pickActor(actorSeed);
        address tok = _pickToken(tokSeed);
        _arm(armSeed);
        vm.prank(user);
        try oracle.withdraw(tok, type(uint256).max) {} catch {}
        _afterArmedCall();
    }

    function actPushOrCredit(
        uint8 actorSeed,
        uint8 toSeed,
        uint8 tokSeed,
        uint128 amtSeed,
        uint8 armSeed,
        uint32 gasSeed,
        bool customGas
    ) external {
        address caller = _pickActor(actorSeed);
        address to = _pickActor(toSeed);
        address tok = _pickToken(tokSeed);
        uint128 amt = uint128(bound(uint256(amtSeed), 0, 1e21));
        uint32 gasLimit = uint32(bound(uint256(gasSeed), 0, 200_000));
        _arm(armSeed);
        vm.prank(caller);
        if (customGas) {
            try oracle.pushOrCredit(tok, to, amt, gasLimit) {} catch {}
        } else {
            try oracle.pushOrCredit(tok, to, amt) {} catch {}
        }
        _afterArmedCall();
    }

    function actInternalTransfer(uint8 fromSeed, uint8 toSeed, uint8 tokSeed, uint128 amtSeed) external {
        address from = _pickActor(fromSeed);
        address to = _pickActor(toSeed);
        address tok = _pickToken(tokSeed);
        uint128 amt = uint128(bound(uint256(amtSeed), 0, 1e21));
        vm.prank(from);
        try oracle.internalTransferFrom(from, to, tok, amt) {} catch {}
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
