// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";

/// @notice Dirty-calldata fuzz for settle(). Same staging pattern as dispute():
///         calldatacopy(params, helper) → keccak → check vs stored hash → alias `oracle`
///         to staged memory. There are no top-level free-choice args here (only
///         `reportId` which is uint256 / no padding), so every padding byte lives
///         in the OracleGame or PreimageHelper struct and is caught by the hash
///         mismatch path → InvalidStateHash() (4-byte custom error).
contract OpenOracleSettleDirtyCalldataTest is BaseGGTest {
    uint256 internal constant ORACLE_GAME_OFFSET = 0x020;       // after reportId
    uint256 internal constant PREIMAGE_HELPER_OFFSET = 0x2A0;   // after OracleGame (0x280)

    function setUp() public override {
        BaseGGTest.setUp();
    }

    function _settledReadyContext() internal returns (ReportContext memory ctx) {
        vm.prank(alice);
        ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);
        // Past settlementTime so settle is otherwise valid.
        vm.warp(block.timestamp + _defaultParams().settlementTime + 1);
    }

    function _settleCallData(ReportContext memory ctx) internal pure returns (bytes memory data) {
        data = abi.encodeCall(Slim.settle, (ctx.reportId, ctx.game, ctx.helper));
    }

    function testDirtyCalldata_CleanSettleSucceeds() public {
        ReportContext memory ctx = _settledReadyContext();
        bytes memory data = _settleCallData(ctx);

        vm.prank(charlie);
        (bool ok,) = address(oracle).call(data);
        assertTrue(ok, "clean settle must succeed");
    }

    function testFuzzAllPaddingBytes_Settle_StateHashInvariant() public {
        uint256[] memory padBytes = _allPaddingByteOffsets();
        bytes1 DIRTY = 0xFF;
        bytes4 invalidStateHashSel = bytes4(keccak256("InvalidStateHash()"));

        for (uint256 i = 0; i < padBytes.length; i++) {
            uint256 snap = vm.snapshotState();

            ReportContext memory ctx = _settledReadyContext();
            bytes32 hashBefore = oracle.oracleGame(ctx.reportId);
            bytes memory cd = _settleCallData(ctx);
            cd[4 + padBytes[i]] = DIRTY;

            vm.prank(charlie);
            (bool ok, bytes memory ret) = address(oracle).call(cd);

            assertFalse(ok, string.concat("dirty must revert @ byte ", vm.toString(padBytes[i])));
            // All padding here is inside the OracleGame or PreimageHelper struct,
            // both of which feed into the calldatacopy → keccak → check path.
            assertEq(
                ret.length, 4, string.concat("dirty must revert with 4-byte custom error @ byte ", vm.toString(padBytes[i]))
            );
            assertEq(
                bytes4(ret),
                invalidStateHashSel,
                string.concat("dirty must revert InvalidStateHash @ byte ", vm.toString(padBytes[i]))
            );
            assertEq(
                oracle.oracleGame(ctx.reportId),
                hashBefore,
                string.concat("dirty revert must not mutate state hash @ byte ", vm.toString(padBytes[i]))
            );

            vm.revertToState(snap);
        }
    }

    function _allPaddingByteOffsets() internal pure returns (uint256[] memory out) {
        // settle() calldata: reportId(uint256 @ 0x00) · OracleGame @ 0x20 · PreimageHelper @ 0x2A0.
        // reportId has no padding. PreimageHelper.{reportId,blockTimestamp,blockNumber} are uint256, no padding;
        // only helper.creator has padding.
        uint256[2][21] memory fields = [
            // OracleGame at 0x020
            [uint256(ORACLE_GAME_OFFSET + 0x000), uint256(16)], // currentAmount1
            [uint256(ORACLE_GAME_OFFSET + 0x020), uint256(16)], // currentAmount2
            [uint256(ORACLE_GAME_OFFSET + 0x040), uint256(20)], // currentReporter
            [uint256(ORACLE_GAME_OFFSET + 0x060), uint256(6)],  // reportTimestamp
            [uint256(ORACLE_GAME_OFFSET + 0x080), uint256(6)],  // settlementTimestamp
            [uint256(ORACLE_GAME_OFFSET + 0x0A0), uint256(20)], // token1
            [uint256(ORACLE_GAME_OFFSET + 0x0C0), uint256(6)],  // lastReportOppoTime
            [uint256(ORACLE_GAME_OFFSET + 0x0E0), uint256(6)],  // settlementTime
            [uint256(ORACLE_GAME_OFFSET + 0x100), uint256(16)], // escalationHalt
            [uint256(ORACLE_GAME_OFFSET + 0x120), uint256(20)], // protocolFeeRecipient
            [uint256(ORACLE_GAME_OFFSET + 0x140), uint256(12)], // settlerReward
            [uint256(ORACLE_GAME_OFFSET + 0x160), uint256(20)], // token2
            [uint256(ORACLE_GAME_OFFSET + 0x180), uint256(3)],  // numReports
            [uint256(ORACLE_GAME_OFFSET + 0x1A0), uint256(3)],  // disputeDelay
            [uint256(ORACLE_GAME_OFFSET + 0x1C0), uint256(3)],  // feePercentage
            [uint256(ORACLE_GAME_OFFSET + 0x1E0), uint256(2)],  // multiplier
            [uint256(ORACLE_GAME_OFFSET + 0x200), uint256(20)], // callbackContract
            [uint256(ORACLE_GAME_OFFSET + 0x220), uint256(4)],  // callbackGasLimit
            [uint256(ORACLE_GAME_OFFSET + 0x240), uint256(3)],  // protocolFee
            [uint256(ORACLE_GAME_OFFSET + 0x260), uint256(1)],  // flags
            // PreimageHelper.creator at PREIMAGE_HELPER_OFFSET + 0x020
            [uint256(PREIMAGE_HELPER_OFFSET + 0x020), uint256(20)]
        ];

        uint256 total = 0;
        for (uint256 i = 0; i < fields.length; i++) total += 32 - fields[i][1];
        out = new uint256[](total);
        uint256 k = 0;
        for (uint256 i = 0; i < fields.length; i++) {
            uint256 slotOff = fields[i][0];
            uint256 padLen = 32 - fields[i][1];
            for (uint256 p = 0; p < padLen; p++) out[k++] = slotOff + p;
        }
    }
}
