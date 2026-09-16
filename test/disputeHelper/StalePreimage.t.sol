// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase} from "./DisputeHelperBase.t.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";

/**
 * @notice A stale oracle preimage must be rejected before funds are sourced or a router is called.
 *
 * @dev The helper authenticates the complete oracle preimage itself before taking snapshots,
 *      pulling funds or entering the caller-selected router.
 *
 *      WHAT THESE TESTS PIN. Not merely that the call reverts, but that nothing survives it: pool
 *      reserves, router balances, the disputer's wallet and the helper's approvals are all compared
 *      against a snapshot taken before the attempt. A partial effect would be a real loss, because
 *      the swap consumed the disputer's capital for nothing.
 *
 *      Stale preimages arise naturally: the oracle's `dispute` and `settle` both rewrite the state
 *      hash, so any competing transaction landing first invalidates a pending route. This is the
 *      ordinary race, not an exotic attack.
 */
contract StalePreimageTest is DisputeHelperBase {
    uint128 internal constant NEW_AMOUNT_1 = 1.1e18;
    uint256 internal constant REQUIRED_1 = 2.1004e18;

    struct Snapshot {
        uint256 disputerA;
        uint256 disputerB;
        uint256 disputerC;
        uint256 helperA;
        uint256 helperC;
        uint256 routerC;
        uint256 poolC;
        bytes32 stateHash;
    }

    function _snapshot(Game memory ctx) internal view returns (Snapshot memory s) {
        s.disputerA = tokenA.balanceOf(disputer);
        s.disputerB = tokenB.balanceOf(disputer);
        s.disputerC = tokenC.balanceOf(disputer);
        s.helperA = tokenA.balanceOf(address(helper));
        s.helperC = tokenC.balanceOf(address(helper));
        s.routerC = tokenC.balanceOf(router);
        s.poolC = tokenC.balanceOf(_v2Pair(address(tokenC), address(tokenA)));
        s.stateHash = oracle.oracleGame(ctx.reportId);
    }

    function _assertUnchanged(Game memory ctx, Snapshot memory s) internal view {
        assertEq(tokenA.balanceOf(disputer), s.disputerA, "disputer token1 moved");
        assertEq(tokenB.balanceOf(disputer), s.disputerB, "disputer token2 moved");
        assertEq(tokenC.balanceOf(disputer), s.disputerC, "disputer route token moved");
        assertEq(tokenA.balanceOf(address(helper)), s.helperA, "helper token1 moved");
        assertEq(tokenC.balanceOf(address(helper)), s.helperC, "helper route token moved");
        assertEq(tokenC.balanceOf(router), s.routerC, "router retained route input");
        assertEq(tokenC.balanceOf(_v2Pair(address(tokenC), address(tokenA))), s.poolC, "the pool swap survived");
        assertEq(oracle.oracleGame(ctx.reportId), s.stateHash, "oracle state changed");
    }

    // ────────────────────────────────────────────────────────────────────

    /// @dev A competing dispute lands first, so the pending preimage is one generation old.
    function test_aPreimageStaleByOneDisputeUnwindsTheWholeRoute() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        // Someone else disputes first, rewriting the state hash.
        (bytes memory nc, bytes[] memory ni) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(tokenA), 0, nc, ni, 0);

        Snapshot memory s = _snapshot(ctx);

        // `ctx` still describes the pre-dispute game, so it is now stale.
        uint256 maxIn = 5e18;
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);

        vm.expectRevert(OracleDisputeHelper.WrongHash.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        _assertUnchanged(ctx, s);
    }

    /// @dev The same with a plan that routes BOTH legs and sweeps — the largest amount of work to
    ///      roll back.
    function test_aTwoLegRouteWithASweepAlsoUnwindsCompletely() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory nc, bytes[] memory ni) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(tokenA), 0, nc, ni, 0);

        Snapshot memory s = _snapshot(ctx);

        uint256 maxIn = 100e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), 50e18, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        bytes[] memory sweepInput = new bytes[](1);
        sweepInput[0] = _sweep(address(tokenC), address(helper), 0);
        (bytes memory c, bytes[] memory i) = _join(cj, ij, abi.encodePacked(CMD_SWEEP), sweepInput);

        vm.expectRevert(OracleDisputeHelper.WrongHash.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 1050e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        _assertUnchanged(ctx, s);
    }

    /// @dev A single mutated field is enough. `settlerReward` does not participate in any funding
    ///      calculation, so this can only be caught by the hash — the helper itself would happily
    ///      proceed.
    function test_aSingleAlteredPreimageFieldIsRejectedBeforeTheRouteRuns() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        Snapshot memory s = _snapshot(ctx);

        ctx.game.settlerReward = SETTLER_REWARD + 1;

        uint256 maxIn = 5e18;
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);

        vm.expectRevert(OracleDisputeHelper.WrongHash.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        _assertUnchanged(ctx, s);
    }

    /// @dev The PreimageHelper half of the hash is equally load-bearing.
    function test_anAlteredPreimageHelperIsAlsoRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        Snapshot memory s = _snapshot(ctx);

        ctx.helper.blockNumber = ctx.helper.blockNumber + 1;

        uint256 maxIn = 5e18;
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);

        vm.expectRevert(OracleDisputeHelper.WrongHash.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        _assertUnchanged(ctx, s);
    }

    /// @dev A game that has been settled can no longer be disputed, and the route unwinds with it.
    function test_aSettledGameUnwindsTheRoute() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        // Settlement needs the dispute window to have elapsed.
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        oracleI.settle(ctx.reportId, ctx.game, ctx.helper);

        Snapshot memory s = _snapshot(ctx);

        uint256 maxIn = 5e18;
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);

        // The preimage no longer matches: settle() wrote settlementTimestamp into the game.
        vm.expectRevert(OracleDisputeHelper.WrongHash.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        _assertUnchanged(ctx, s);
    }

    /// @dev A wrong reportId with an otherwise valid-looking preimage: the hash is read from the
    ///      slot named by the id, so this fails the same way.
    function test_aMismatchedReportIdIsRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        Game memory other = _newGame(address(tokenA), address(tokenB));

        Snapshot memory s = _snapshot(other);

        ctx.reportId = other.reportId; // the preimage still describes the FIRST game

        uint256 maxIn = 5e18;
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);

        vm.expectRevert(OracleDisputeHelper.WrongHash.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        _assertUnchanged(other, s);
    }

    /// @dev Control: the identical route on a FRESH preimage succeeds. Without this, every
    ///      assertion above would also pass if the route were simply broken.
    function test_theSameRouteSucceedsOnAFreshPreimage() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5e18;
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);

        uint256 c0 = tokenC.balanceOf(disputer);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), maxIn, c, i, 0);

        assertEq(c0 - tokenC.balanceOf(disputer), maxIn, "the control route did not execute");
        assertTrue(oracle.oracleGame(ctx.reportId) != bytes32(0), "the game should still exist");
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    function _v2Pair(address a, address b) internal view returns (address) {
        return IV2FactoryView(v2Factory).getPair(a, b);
    }
}

interface IV2FactoryView {
    function getPair(address, address) external view returns (address);
}
