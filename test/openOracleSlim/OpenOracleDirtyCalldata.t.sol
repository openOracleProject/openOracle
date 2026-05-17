// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";

/// @notice Per-field "value vs value+1" boundary probe of report() calldata. For each
///         sub-256-bit field, the byte immediately above the value bytes is set to 0x00
///         (value within declared width → must succeed) and then to 0x01 (value = type-max + 1
///         → must revert).
contract OpenOracleDirtyCalldataTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
    }

    function _cleanInput() internal view returns (Slim.OracleGame memory input) {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        input.token1 = p.token1Address;
        input.token2 = p.token2Address;
        input.feePercentage = p.feePercentage;
        input.multiplier = p.multiplier;
        input.settlementTime = p.settlementTime;
        input.escalationHalt = p.escalationHalt;
        input.disputeDelay = p.disputeDelay;
        input.protocolFee = p.protocolFee;
        input.settlerReward = p.settlerReward;
        input.callbackContract = p.callbackContract;
        input.callbackGasLimit = p.callbackGasLimit;
        input.protocolFeeRecipient = p.protocolFeeRecipient;
        input.flags = p.flags;
        input.currentAmount1 = 1e18;
        input.currentAmount2 = 2000e18;
        input.currentReporter = alice;
    }

    function _reportWithByte(uint256 byteOffset, uint8 b) internal returns (bool ok) {
        Slim.OracleGame memory input = _cleanInput();
        bytes memory data = abi.encodeCall(oracle.report, (input, false, false, _emptyTiming()));
        data[4 + byteOffset] = bytes1(b);

        vm.prank(alice);
        (ok,) = address(oracle).call{value: _defaultParams().settlerReward}(data);
    }

    /// @dev Boundary check: clean byte (0x00) at the padding-edge succeeds; +1 (0x01) reverts.
    function _assertBoundary(uint256 slotOffset, uint256 valueBytes, string memory label) internal {
        uint256 byteIdx = slotOffset + 32 - valueBytes - 1;
        assertTrue(_reportWithByte(byteIdx, 0x00), string.concat(label, ": value must not revert"));
        uint256 idAfterClean = oracle.nextReportId();
        assertFalse(_reportWithByte(byteIdx, 0x01), string.concat(label, ": value+1 must revert"));
        assertEq(oracle.nextReportId(), idAfterClean, "nextReportId unchanged after value+1");
        assertEq(oracle.oracleGame(idAfterClean), bytes32(0), "no state hash on value+1");
    }

    function testDirtyCalldata_CleanReportSucceeds() public {
        Slim.OracleGame memory input = _cleanInput();
        vm.prank(alice);
        oracle.report{value: _defaultParams().settlerReward}(input, false, false, _emptyTiming());
    }

    // OracleGame layout:
    //   0x000 currentAmount1          uint128
    //   0x020 currentAmount2          uint128
    //   0x040 currentReporter         address
    //   0x060 reportTimestamp         uint48
    //   0x080 settlementTimestamp     uint48
    //   0x0a0 token1                  address
    //   0x0c0 lastReportOppoTime      uint48
    //   0x0e0 settlementTime          uint48
    //   0x100 escalationHalt          uint128
    //   0x120 protocolFeeRecipient    address
    //   0x140 settlerReward           uint96
    //   0x160 token2                  address
    //   0x180 numReports              uint24
    //   0x1a0 disputeDelay            uint24
    //   0x1c0 feePercentage           uint24
    //   0x1e0 multiplier              uint16
    //   0x200 callbackContract        address
    //   0x220 callbackGasLimit        uint32
    //   0x240 protocolFee             uint24
    //   0x260 flags                   uint8

    function testBoundary_CurrentAmount1() public { _assertBoundary(0x000, 16, "currentAmount1"); }
    function testBoundary_CurrentAmount2() public { _assertBoundary(0x020, 16, "currentAmount2"); }
    function testBoundary_CurrentReporter() public { _assertBoundary(0x040, 20, "currentReporter"); }
    function testBoundary_ReportTimestamp() public { _assertBoundary(0x060, 6, "reportTimestamp"); }
    function testBoundary_SettlementTimestamp() public { _assertBoundary(0x080, 6, "settlementTimestamp"); }
    function testBoundary_Token1() public { _assertBoundary(0x0A0, 20, "token1"); }
    function testBoundary_LastReportOppoTime() public { _assertBoundary(0x0C0, 6, "lastReportOppoTime"); }
    function testBoundary_SettlementTime() public { _assertBoundary(0x0E0, 6, "settlementTime"); }
    function testBoundary_EscalationHalt() public { _assertBoundary(0x100, 16, "escalationHalt"); }
    function testBoundary_ProtocolFeeRecipient() public { _assertBoundary(0x120, 20, "protocolFeeRecipient"); }
    function testBoundary_SettlerReward() public { _assertBoundary(0x140, 12, "settlerReward"); }
    function testBoundary_Token2() public { _assertBoundary(0x160, 20, "token2"); }
    function testBoundary_NumReports() public { _assertBoundary(0x180, 3, "numReports"); }
    function testBoundary_DisputeDelay() public { _assertBoundary(0x1A0, 3, "disputeDelay"); }
    function testBoundary_FeePercentage() public { _assertBoundary(0x1C0, 3, "feePercentage"); }
    function testBoundary_Multiplier() public { _assertBoundary(0x1E0, 2, "multiplier"); }
    function testBoundary_CallbackContract() public { _assertBoundary(0x200, 20, "callbackContract"); }
    function testBoundary_CallbackGasLimit() public { _assertBoundary(0x220, 4, "callbackGasLimit"); }
    function testBoundary_ProtocolFee() public { _assertBoundary(0x240, 3, "protocolFee"); }
    function testBoundary_Flags() public { _assertBoundary(0x260, 1, "flags"); }

    // ─── Comprehensive every-padding-byte fuzz ────────────────────────────────
    //
    // Strong invariant: dirtying ANY single padding byte of the report() calldata
    // must produce one of two outcomes:
    //   (a) call reverts AND nextReportId is unchanged AND no stored state hash is created
    //   (b) call succeeds AND the new oracleGame[id] equals what a clean report() would store
    //
    // report() calldata layout:
    //   0x000  OracleGame (20 slots)
    //   0x280  tryInternalBalance1 (bool)
    //   0x2A0  tryInternalBalance2 (bool)
    //   0x2C0  TimingBoundaries (4 uint256 slots, no padding)
    //
    // Padding bytes: OracleGame 437 + tib1 31 + tib2 31 + timing 0 = 499 byte positions.
    function testFuzzAllPaddingBytes_Report_StateHashInvariant() public {
        uint256[] memory padBytes = _allReportPaddingByteOffsets();
        bytes1 DIRTY = 0xFF;

        // Compute clean reference: expected stored hash for a clean call.
        bytes32 expectedHash;
        {
            uint256 snap = vm.snapshotState();
            Slim.OracleGame memory input = _cleanInput();
            vm.prank(alice);
            uint256 rid = oracle.report{value: _defaultParams().settlerReward}(input, false, false, _emptyTiming());
            expectedHash = oracle.oracleGame(rid);
            vm.revertToState(snap);
        }

        for (uint256 i = 0; i < padBytes.length; i++) {
            uint256 snap = vm.snapshotState();

            uint256 nextBefore = oracle.nextReportId();

            Slim.OracleGame memory input = _cleanInput();
            bytes memory data = abi.encodeCall(oracle.report, (input, false, false, _emptyTiming()));
            data[4 + padBytes[i]] = DIRTY;

            vm.prank(alice);
            (bool ok, bytes memory ret) =
                address(oracle).call{value: _defaultParams().settlerReward}(data);

            // Strict: every dirty padding byte MUST revert at the type-decode layer
            // (empty returndata from Solidity's `revert(0, 0)`), not via a downstream
            // custom error from business validation.
            assertFalse(ok, string.concat("dirty must revert @ byte ", vm.toString(padBytes[i])));
            assertEq(
                ret.length,
                0,
                string.concat("dirty must revert at type-decode (empty data) @ byte ", vm.toString(padBytes[i]))
            );
            assertEq(
                oracle.nextReportId(),
                nextBefore,
                string.concat("dirty revert must not advance nextReportId @ byte ", vm.toString(padBytes[i]))
            );
            assertEq(
                oracle.oracleGame(nextBefore),
                bytes32(0),
                string.concat("dirty revert must not store state hash @ byte ", vm.toString(padBytes[i]))
            );
            expectedHash; // silence unused

            vm.revertToState(snap);
        }
    }

    function _allReportPaddingByteOffsets() internal pure returns (uint256[] memory out) {
        // (slotOffset, valueBytes). Skipping reportId (no such field here) and timing
        // boundary fields (all uint256). OracleGame matches the table at top of file.
        uint256[2][22] memory fields = [
            // OracleGame at 0x000
            [uint256(0x000), uint256(16)], // currentAmount1
            [uint256(0x020), uint256(16)], // currentAmount2
            [uint256(0x040), uint256(20)], // currentReporter
            [uint256(0x060), uint256(6)],  // reportTimestamp
            [uint256(0x080), uint256(6)],  // settlementTimestamp
            [uint256(0x0A0), uint256(20)], // token1
            [uint256(0x0C0), uint256(6)],  // lastReportOppoTime
            [uint256(0x0E0), uint256(6)],  // settlementTime
            [uint256(0x100), uint256(16)], // escalationHalt
            [uint256(0x120), uint256(20)], // protocolFeeRecipient
            [uint256(0x140), uint256(12)], // settlerReward
            [uint256(0x160), uint256(20)], // token2
            [uint256(0x180), uint256(3)],  // numReports
            [uint256(0x1A0), uint256(3)],  // disputeDelay
            [uint256(0x1C0), uint256(3)],  // feePercentage
            [uint256(0x1E0), uint256(2)],  // multiplier
            [uint256(0x200), uint256(20)], // callbackContract
            [uint256(0x220), uint256(4)],  // callbackGasLimit
            [uint256(0x240), uint256(3)],  // protocolFee
            [uint256(0x260), uint256(1)],  // flags
            // top-level bools
            [uint256(0x280), uint256(1)],  // tryInternalBalance1
            [uint256(0x2A0), uint256(1)]   // tryInternalBalance2
        ];

        uint256 total = 0;
        for (uint256 i = 0; i < fields.length; i++) {
            total += 32 - fields[i][1];
        }

        out = new uint256[](total);
        uint256 k = 0;
        for (uint256 i = 0; i < fields.length; i++) {
            uint256 slotOff = fields[i][0];
            uint256 padLen = 32 - fields[i][1];
            for (uint256 p = 0; p < padLen; p++) {
                out[k++] = slotOff + p;
            }
        }
    }
}
