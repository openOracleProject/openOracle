// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {ArmableReentrantToken} from "../utils/ArmableReentrantToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Drives REAL reentrant payloads through the ERC20 `transferFrom`/`transfer` hook, the gap
///         the existing suite left open: `ReentrantToken` only re-enters with an inert `dust(...)`
///         AFTER the balance has moved (a no-op snapshot), and `ReentrantHook` only covers the
///         ETH-`receive` path. Here an armable token fires attacker-chosen calldata into the oracle,
///         at a chosen trigger point, during two specific interleavings:
///
///           1. report() hash-then-fund window — `oracleGame[reportId]` is written (OpenOracleSlim
///              ~L210) BEFORE the two funding legs are pulled. A reentry fired while token1 is being
///              pulled sees a LIVE reportId whose token2 leg has not yet landed.
///
///           2. deposit() credit-before-transfer window — `_credit(beneficiary)` runs BEFORE
///              `safeTransferFrom` (OpenOracleSlim ~L535 then ~L540). A reentry fired BEFORE the
///              balance moves sees the beneficiary credited while the backing tokens are absent.
///
///         The referee is exact per-token conservation plus the committed state hash. The thesis:
///         no reentry can leave the oracle insolvent, mis-credited, or holding a state hash that
///         doesn't reconstruct — regardless of payload or trigger point.
contract OpenOracleArmedReentrancyTest is BaseGGTest {
    ArmableReentrantToken internal armToken;
    address internal attacker = address(0xBAD);

    // Conservation enumeration sets.
    address[] internal holders;

    function setUp() public override {
        BaseGGTest.setUp();
        armToken = new ArmableReentrantToken();

        // Fund + approve the actors that pull armToken through the oracle.
        armToken.transfer(alice, 1_000e18);
        armToken.transfer(bob, 1_000e18);
        vm.prank(alice);
        armToken.approve(address(oracle), type(uint256).max);
        vm.prank(bob);
        armToken.approve(address(oracle), type(uint256).max);

        holders = [alice, bob, charlie, attacker, address(armToken), address(protocolFeeRecipient), address(this)];
    }

    // ── Conservation referee ─────────────────────────────────────────────────
    // real(armToken in oracle) == Σ tokenHolder[h][armToken] − (#nonzero slots) + inflight,
    // where inflight is the armToken locked in still-unsettled reports. Mirrors the model in
    // OracleSystemInvariantsTest.invariant_conservationPerToken.
    function _assertArmTokenConserved(uint256 inflight, string memory tag) internal view {
        uint256 sumHolder;
        uint256 sentinels;
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 bal = oracle.tokenHolder(holders[i], address(armToken));
            if (bal > 0) sentinels += 1;
            sumHolder += bal;
        }
        uint256 real = armToken.balanceOf(address(oracle));
        assertEq(real, sumHolder - sentinels + inflight, string.concat("armToken conservation: ", tag));
    }

    function _armParams() internal view returns (CompatTypes.CreateReportParams memory p) {
        p = _defaultParams();
        p.token1Address = address(armToken);
        p.token2Address = address(token2);
        p.protocolFee = 0; // keep conservation arithmetic free of fee burns/credits
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. report() hash-then-fund window
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A reentrant settle() on the just-created (live) reportId fires while token1 is being
    ///      pulled and token2 has not yet landed. It must fail (settlement timer has not elapsed),
    ///      the report must still commit a reconstructable hash, and armToken stays conserved
    ///      (the full amount1 is locked inflight).
    function testReportWindow_ReentrantSettleOnLiveReport_Fails() public {
        CompatTypes.CreateReportParams memory p = _armParams();
        uint128 amount1 = 5e18;
        uint128 amount2 = 2000e18;

        uint256 reportId = oracle.nextReportId();
        (uint48 rts, uint48 oppo) = _timestamps(p.flags);

        // Reconstruct the exact (game, helper) report() will commit, so settle()'s hash check passes
        // and we exercise the temporal guard rather than a hash mismatch.
        Slim.OracleGame memory g = _gameAfterReport(p, amount1, amount2, alice, rts, oppo);
        Slim.PreimageHelper memory h =
            Slim.PreimageHelper({reportId: reportId, creator: alice, blockTimestamp: block.timestamp, blockNumber: block.number});

        // Fire after the token1 balance moves: reportId is live, token2 leg not yet pulled.
        armToken.arm(address(oracle), abi.encodeCall(oracle.settle, (reportId, g, h)), false);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, amount1, amount2, alice, false, false);

        assertEq(ctx.reportId, reportId, "reportId as predicted");
        assertTrue(armToken.attempted(), "reentry fired during token1 funding");
        assertFalse(armToken.lastCallOk(), "reentrant settle on live report must fail");
        assertEq(bytes4(armToken.lastReturnData()), Errors.SettleTooEarly.selector, "fails on settlement timer");

        // Report committed a hash that reconstructs, and amount1 is fully inflight.
        assertEq(_stateHash(reportId), _hashOracle(ctx.game, ctx.helper), "committed hash reconstructs");
        _assertArmTokenConserved(amount1, "report window");
    }

    /// @dev Sibling to the settle case: a reentrant DISPUTE on the just-created report, fired while
    ///      token1 is funded but token2 is not, must revert DisputeTooEarly — disputeDelay > 0 seals
    ///      the half-funded report against an in-block swap against its own funding leg. Together
    ///      with the settle case this pins the full property: the live-but-half-funded report is
    ///      inert to BOTH settle and dispute, so the cross-token over-credit-then-backfill that this
    ///      whole effort targets cannot be triggered in-block. The amount-growth check is satisfied
    ///      (expectedAmount1 = oldAmount1 * multiplier / 100) so we reach the temporal guard, not an
    ///      earlier InvalidAmount1.
    function testReportWindow_ReentrantDisputeOnLiveReport_TooEarly() public {
        CompatTypes.CreateReportParams memory p = _armParams();
        uint128 amount1 = 5e18;
        uint128 amount2 = 2000e18;

        uint256 reportId = oracle.nextReportId();
        (uint48 rts, uint48 oppo) = _timestamps(p.flags);
        Slim.OracleGame memory g = _gameAfterReport(p, amount1, amount2, alice, rts, oppo);
        Slim.PreimageHelper memory h =
            Slim.PreimageHelper({reportId: reportId, creator: alice, blockTimestamp: block.timestamp, blockNumber: block.number});

        uint128 expectedA1 = uint128((uint256(amount1) * p.multiplier) / 100);
        bytes memory disputePayload = abi.encodeCall(
            oracle.dispute,
            (reportId, address(armToken), expectedA1, uint128(2100e18), alice, false, false, g, h, _emptyTiming())
        );
        armToken.arm(address(oracle), disputePayload, false);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, amount1, amount2, alice, false, false);

        assertTrue(armToken.attempted(), "reentry fired during token1 funding");
        assertFalse(armToken.lastCallOk(), "reentrant dispute on half-funded report must fail");
        assertEq(bytes4(armToken.lastReturnData()), Errors.DisputeTooEarly.selector, "sealed by disputeDelay");

        assertEq(_stateHash(reportId), _hashOracle(ctx.game, ctx.helper), "committed hash reconstructs");
        _assertArmTokenConserved(amount1, "report window / dispute");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. deposit() credit-before-transfer window
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev beneficiary is credited before the pull. A reentrant withdraw fired BEFORE the balance
    ///      moves tries to drain the just-credited amount while the backing tokens are still absent.
    ///      It must fail (the oracle holds no armToken yet), and the deposit must still settle to an
    ///      exact, conserved credit.
    function testDepositWindow_ReentrantWithdrawBeforePull_CannotDrain() public {
        uint128 amount = 100e18;

        // beneficiary == armToken so the credited party is the one re-entering.
        armToken.arm(address(oracle), abi.encodeCall(oracle.withdraw, (address(armToken), type(uint256).max)), true);

        vm.prank(alice);
        oracle.deposit(address(armToken), amount, address(armToken));

        assertTrue(armToken.attempted(), "reentry fired before pull");
        assertFalse(armToken.lastCallOk(), "withdraw cannot move tokens that are not in the oracle yet");

        // The credit landed exactly once; no value escaped.
        assertEq(oracle.tokenHolder(address(armToken), address(armToken)), uint256(amount) + 1, "beneficiary credited once");
        assertEq(oracle.tokenHolder(attacker, address(armToken)), 0, "attacker gained nothing");
        _assertArmTokenConserved(0, "deposit window / withdraw");
    }

    /// @dev Same window, but the reentry tries to forward a THIRD party's (alice's) internal balance
    ///      to the attacker via internalTransferFrom. Without alice's internal allowance to armToken
    ///      it must revert — the credit-before-transfer ordering never lets a non-beneficiary extract.
    function testDepositWindow_ReentrantInternalTransferOfThirdParty_Reverts() public {
        uint128 amount = 100e18;

        // Give alice some pre-existing internal armToken balance (a normal prior deposit).
        vm.prank(alice);
        oracle.deposit(address(armToken), 10e18, alice);

        bytes memory payload =
            abi.encodeCall(oracle.internalTransferFrom, (alice, attacker, address(armToken), 10e18));
        armToken.arm(address(oracle), payload, true);

        vm.prank(bob);
        oracle.deposit(address(armToken), amount, address(armToken));

        assertTrue(armToken.attempted(), "reentry fired");
        assertFalse(armToken.lastCallOk(), "cannot move alice's balance without her internal allowance");
        assertEq(bytes4(armToken.lastReturnData()), Errors.InsufficientInternalAllowance.selector, "blocked by allowance");

        assertEq(oracle.tokenHolder(attacker, address(armToken)), 0, "attacker gained nothing");
        assertEq(oracle.tokenHolder(alice, address(armToken)), uint256(10e18) + 1, "alice balance untouched");
        _assertArmTokenConserved(0, "deposit window / 3rd-party transfer");
    }

    /// @dev The beneficiary forwarding ITS OWN just-credited balance mid-deposit is authorized and
    ///      must succeed — and must still conserve. This pins that the window is safe because of
    ///      access control, not because the internal ledger is frozen during the pull.
    function testDepositWindow_BeneficiaryForwardsOwnCredit_ConservesValue() public {
        uint128 amount = 100e18;

        // armToken (the beneficiary) forwards its own incoming credit to the attacker.
        bytes memory payload =
            abi.encodeCall(oracle.internalTransferFrom, (address(armToken), attacker, address(armToken), amount));
        armToken.arm(address(oracle), payload, false); // after credit lands

        vm.prank(alice);
        oracle.deposit(address(armToken), amount, address(armToken));

        assertTrue(armToken.attempted(), "reentry fired");
        assertTrue(armToken.lastCallOk(), "beneficiary may forward its own credit");

        // Value moved to the attacker, but only the beneficiary's own funds — total is conserved.
        assertEq(oracle.tokenHolder(attacker, address(armToken)), uint256(amount) + 1, "attacker holds forwarded credit");
        assertEq(oracle.tokenHolder(address(armToken), address(armToken)), 1, "beneficiary slot left at sentinel");
        _assertArmTokenConserved(0, "deposit window / self-forward");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. A reentrant DISPUTE that actually LANDS and runs the credit-arms
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The case the whole thread targets: a reentrant dispute that doesn't just bounce off a
    ///      guard but SUCCEEDS mid-operation and executes the cross-token credit-arms. The report
    ///      uses disputeDelay = 0 so it is disputable in-block (the deterministic report-window test
    ///      proves disputeDelay > 0 seals the SAME report; here the target is a separate, already
    ///      open report). The reentrant disputer funds from its internal balance with armToken as the
    ///      approved spender, so the dispute lands during an unrelated armToken deposit. We then prove
    ///      the previous reporter's credit-arm executed (2*oldAmount1 + fee) and the oracle stayed
    ///      solvent — the property the fuzz solvency referee enforces, pinned deterministically here.
    function testReentrantDispute_Lands_RunsCreditArms_AndStaysSolvent() public {
        // Open report R: vanilla/vanilla, disputeDelay = 0, protocolFee = 0, reporter = alice.
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.disputeDelay = 0;
        p.protocolFee = 0;
        p.escalationHalt = type(uint128).max; // let the multiplier growth apply (default halt == oldA1)
        uint128 oldA1 = 10e18;
        uint128 oldA2 = 2000e18;

        vm.prank(alice);
        ReportContext memory ctx = _report(p, oldA1, oldA2, alice, false, false);

        // bob will be the reentrant disputer, funding token1 from his internal balance via armToken.
        vm.startPrank(bob);
        oracle.deposit(address(token1), 50e18, bob);
        oracle.approveInternal(address(armToken), address(token1), type(uint256).max);
        oracle.approveInternal(address(armToken), address(token2), type(uint256).max);
        vm.stopPrank();

        // newAmount1 must equal oldAmount1 * multiplier / 100; newAmount2 == oldAmount2 → no token2 leg.
        uint128 newA1 = uint128((uint256(oldA1) * p.multiplier) / 100); // 11e18
        uint256 fee = (uint256(oldA1) * p.feePercentage) / 1e7; // oldA1 * 0.0003
        bytes memory disputePayload = abi.encodeCall(
            oracle.dispute,
            (ctx.reportId, address(token1), newA1, oldA2, bob, true, true, ctx.game, ctx.helper, _emptyTiming())
        );
        armToken.arm(address(oracle), disputePayload, false);

        uint256 aliceT1Before = oracle.tokenHolder(alice, address(token1));

        // Trigger: alice deposits armToken (unrelated op); its transferFrom fires bob's dispute on R.
        vm.prank(alice);
        oracle.deposit(address(armToken), 1e18, charlie);

        // The reentrant dispute LANDED (not merely attempted-and-reverted).
        assertTrue(armToken.attempted(), "reentry fired");
        assertTrue(armToken.lastCallOk(), "reentrant dispute landed");

        // Credit-arm executed under reentrancy: previous reporter (alice) received 2*oldA1 + fee token1.
        assertEq(
            oracle.tokenHolder(alice, address(token1)) - aliceT1Before,
            2 * uint256(oldA1) + fee,
            "previous-reporter credit-arm ran during reentrancy"
        );
        // State advanced to bob as the new reporter (hash moved off the original preimage).
        assertTrue(_stateHash(ctx.reportId) != _hashOracle(ctx.game, ctx.helper), "report state advanced via reentrancy");

        // Solvency holds for token1: real backing >= sum of withdrawable internal balances.
        _assertToken1Solvent();
    }

    function _assertToken1Solvent() internal view {
        address[5] memory hs = [alice, bob, charlie, attacker, address(armToken)];
        uint256 withdrawable;
        for (uint256 i = 0; i < hs.length; i++) {
            uint256 bal = oracle.tokenHolder(hs[i], address(token1));
            if (bal > 0) withdrawable += bal - 1;
        }
        assertGe(token1.balanceOf(address(oracle)), withdrawable, "token1 insolvent after reentrant dispute");
    }
}
