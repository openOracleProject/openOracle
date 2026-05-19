// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

// Calldata-mode is the only mode in OpenOracleSlim. These tests exercise:
//   - End-to-end lifecycle with rolling stateHash
//   - Preimage mismatch reverts (InvalidStateHash)
//   - trackDisputes feature: dispute history persisted on-chain
contract OpenOracleGGCalldataModeTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
    }

    // -------------------------------------------------------------------------
    // Section: Full lifecycle (report → dispute → settle)
    // -------------------------------------------------------------------------
    function testOracleLifecycle() public {
        // Alice reports (creator + initial reporter).
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, false, false);

        // Storage hash matches our local computed hash.
        assertEq(_stateHash(ctx.reportId), _hashOracle(ctx.game, ctx.helper), "post-report hash");

        // Alice's tokens pulled, dust seeded.
        assertEq(_heldTokens(alice, address(token1)), 1, "alice token1 dust");
        assertEq(_heldTokens(alice, address(token2)), 1, "alice token2 dust");

        // Wait for dispute delay then dispute.
        vm.warp(block.timestamp + 6);
        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, false, false);

        // Hash advanced to post-dispute state.
        assertEq(_stateHash(ctx.reportId), _hashOracle(ctx.game, ctx.helper), "post-dispute hash");

        // Alice (previous reporter) credited with 2*oldAmount + fee in token1.
        uint256 fee = (1e18 * 3000) / 1e7;
        assertEq(_heldTokens(alice, address(token1)), 1 + 2e18 + fee, "alice internal token1 after dispute");

        // Wait and settle.
        vm.warp(block.timestamp + 300);
        vm.prank(charlie);
        ctx = _settle(ctx);
        assertEq(_stateHash(ctx.reportId), _hashOracle(ctx.game, ctx.helper), "post-settle hash");

        // Charlie's settler reward credited to ETH internal balance.
        uint96 settlerReward = _defaultParams().settlerReward;
        assertEq(
            oracle.tokenHolder(charlie, address(0)),
            1 + settlerReward,
            "charlie settler reward credited (sentinel + reward)"
        );

        // Bob (current reporter at settle) gets the final amounts.
        assertEq(_heldTokens(bob, address(token1)), 1 + 1.1e18, "bob internal token1 at settle");
        assertEq(_heldTokens(bob, address(token2)), 1 + 2100e18, "bob internal token2 at settle");
    }

    // -------------------------------------------------------------------------
    // Section: Preimage mismatch
    // -------------------------------------------------------------------------
    function testCalldataMode_PreimageMismatch_Reverts() public {
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, false, false);

        // Tamper with the local game struct so the hash will mismatch storage.
        Slim.OracleGame memory tampered = ctx.game;
        tampered.escalationHalt = 99e18;

        vm.warp(block.timestamp + 6);
        vm.prank(bob);
        vm.expectRevert(Errors.InvalidStateHash.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, bob, false, false, tampered, ctx.helper, _emptyTiming()
        );
    }

    // -------------------------------------------------------------------------
    // Section: trackDisputes — dispute history persisted on-chain
    // -------------------------------------------------------------------------
    function _readDispute(uint256 reportId, uint256 index)
        internal
        view
        returns (uint128 amount1, uint128 amount2, address tokenToSwap, uint48 reportTimestamp)
    {
        return oracle.disputeHistory(reportId, index);
    }

    function testCalldataMode_TrackDisputes() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_TRACK_DISPUTES;

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, false, false);

        // Index 0 = initial report; tokenToSwap is unset on the initial entry.
        (uint128 a1_0, uint128 a2_0, address tok_0, uint48 ts_0) = _readDispute(ctx.reportId, 0);
        assertEq(a1_0, 1e18, "init record amount1");
        assertEq(a2_0, 2000e18, "init record amount2");
        assertEq(tok_0, address(0), "init record tokenToSwap unset");
        assertEq(ts_0, uint48(block.timestamp), "init record reportTimestamp");

        // Hash committed; numReports == 1 in the game struct.
        assertEq(ctx.game.numReports, 1, "numReports after report");
        assertEq(_stateHash(ctx.reportId), _hashOracle(ctx.game, ctx.helper), "hash after report");

        // Dispute.
        vm.warp(block.timestamp + 6);
        uint256 disputeTimestamp = block.timestamp;

        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, false, false);

        // Index 1 = first dispute.
        (uint128 a1_1, uint128 a2_1, address tok_1, uint48 ts_1) = _readDispute(ctx.reportId, 1);
        assertEq(a1_1, 1.1e18, "dispute record amount1");
        assertEq(a2_1, 2100e18, "dispute record amount2");
        assertEq(tok_1, address(token1), "dispute record tokenToSwap");
        assertEq(uint256(ts_1), disputeTimestamp, "dispute record reportTimestamp");

        assertEq(ctx.game.numReports, 2, "numReports after dispute");
        assertEq(_stateHash(ctx.reportId), _hashOracle(ctx.game, ctx.helper), "hash after dispute");
    }
}
