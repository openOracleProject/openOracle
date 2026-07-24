// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";

// baseFee recording in DisputeRecord (trackDisputes mode). Exercises:
//   - initial report records block.basefee at index 0
//   - each dispute round records its own block.basefee
//   - swap direction is derivable from consecutive records (tokenToSwap removal)
//   - no records written when FLAG_TRACK_DISPUTES is off
//   - zero basefee and uint128 cast truncation behavior
contract OpenOracleBaseFeeTrackingTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
    }

    function _readDispute(uint256 reportId, uint256 index)
        internal
        view
        returns (uint128 amount1, uint128 amount2, uint128 baseFee, uint48 reportTimestamp)
    {
        return oracle.disputeHistory(reportId, index);
    }

    // Mirrors the contract's dispute-side derivation: true = token2 was swapped.
    function _swapSideToken2(uint128 prevA1, uint128 prevA2, uint128 newA1, uint128 newA2)
        internal
        pure
        returns (bool)
    {
        return uint256(newA2) * prevA1 > uint256(prevA2) * newA1;
    }

    function testBaseFee_RecordedPerRound() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_TRACK_DISPUTES;

        // Single TIMESTAMP read; warp to absolute times only. Re-reading
        // block.timestamp after a warp can return the pre-warp value under
        // via_ir CSE.
        uint256 t0 = block.timestamp;

        // Round 0: initial report at 1 gwei basefee.
        vm.fee(1 gwei);
        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, false, false);

        // Round 1: bob disputes at 4 gwei. 2100*1 < 2000*1.1 → token1 side.
        vm.warp(t0 + 6);
        vm.fee(4 gwei);
        vm.prank(bob);
        ctx = _dispute(ctx, address(0), 1.1e18, 2100e18, false, false);

        // Round 2: charlie disputes at 12 gwei. 2662*1.1 > 2100*1.21 → token2 side.
        vm.warp(t0 + 12);
        vm.fee(12 gwei);
        vm.prank(charlie);
        ctx = _dispute(ctx, address(0), 1.21e18, 2662e18, false, false);

        assertEq(ctx.game.numReports, 3, "numReports after two disputes");

        (uint128 a1_0, uint128 a2_0, uint128 bf_0,) = _readDispute(ctx.reportId, 0);
        (uint128 a1_1, uint128 a2_1, uint128 bf_1,) = _readDispute(ctx.reportId, 1);
        (uint128 a1_2, uint128 a2_2, uint128 bf_2,) = _readDispute(ctx.reportId, 2);

        assertEq(bf_0, uint128(1 gwei), "round 0 baseFee");
        assertEq(bf_1, uint128(4 gwei), "round 1 baseFee");
        assertEq(bf_2, uint128(12 gwei), "round 2 baseFee");

        assertEq(a1_1, 1.1e18, "round 1 amount1");
        assertEq(a2_1, 2100e18, "round 1 amount2");
        assertEq(a1_2, 1.21e18, "round 2 amount1");
        assertEq(a2_2, 2662e18, "round 2 amount2");

        // Swap direction reconstructed from consecutive records.
        assertFalse(_swapSideToken2(a1_0, a2_0, a1_1, a2_1), "round 1 swapped token1");
        assertTrue(_swapSideToken2(a1_1, a2_1, a1_2, a2_2), "round 2 swapped token2");
    }

    function testBaseFee_NoRecordsWithoutTrackDisputes() public {
        vm.fee(6 gwei);
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, false, false);

        vm.warp(block.timestamp + 6);
        vm.prank(bob);
        ctx = _dispute(ctx, address(0), 1.1e18, 2100e18, false, false);

        (uint128 a1_0, uint128 a2_0, uint128 bf_0, uint48 ts_0) = _readDispute(ctx.reportId, 0);
        (uint128 a1_1, uint128 a2_1, uint128 bf_1, uint48 ts_1) = _readDispute(ctx.reportId, 1);

        assertEq(a1_0 | a2_0 | bf_0 | uint128(ts_0), 0, "index 0 empty when tracking off");
        assertEq(a1_1 | a2_1 | bf_1 | uint128(ts_1), 0, "index 1 empty when tracking off");
    }

    function testBaseFee_ZeroBaseFee() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_TRACK_DISPUTES;

        vm.fee(0);
        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, false, false);

        (uint128 a1_0,, uint128 bf_0,) = _readDispute(ctx.reportId, 0);
        assertEq(bf_0, 0, "zero basefee recorded as zero");
        assertEq(a1_0, 1e18, "record exists; amounts are the existence marker, not baseFee");
    }

    function testBaseFee_Uint128CastTruncates() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_TRACK_DISPUTES;

        // Above-uint128 basefee is physically unreachable; pin that the cast
        // truncates to the low 128 bits rather than reverting.
        vm.fee(uint256(type(uint128).max) + 1 + 7 gwei);
        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, false, false);

        (,, uint128 bf_0,) = _readDispute(ctx.reportId, 0);
        assertEq(bf_0, uint128(7 gwei), "cast keeps low 128 bits");
    }
}
