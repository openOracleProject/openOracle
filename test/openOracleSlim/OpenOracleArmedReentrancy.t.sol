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
}
