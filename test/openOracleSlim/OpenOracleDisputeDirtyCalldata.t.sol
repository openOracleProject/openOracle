// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";

/// @notice Dispute() calldata dirtying probes.
///
///         The pre-state hash is computed from the OracleGame + PreimageHelper struct
///         calldata after Solidity's typed read masks each field — that path is exercised
///         by the per-field boundary tests below.
///
///         The post-state hash is the interesting case: the top-level free-choice args
///         (tokenToSwap, newAmount1, newAmount2, disputer) feed into in-place mutations
///         on the staged buffer (`oracle.currentAmount1 = newAmount1;` etc.), and that
///         buffer gets re-keccak'd. If any dirty high bits in those args escape Solidity's
///         calldata mask, they end up in the second hash. The fuzz at the bottom asserts
///         the strong invariant: for EVERY non-value (padding) byte in the dispute
///         calldata, the resulting on-chain state hash must either be unchanged (revert)
///         or match the hash a clean dispute would produce.
contract OpenOracleDisputeDirtyCalldataTest is BaseGGTest {
    uint256 internal constant ORACLE_GAME_OFFSET = 0x0E0;
    uint256 internal constant PREIMAGE_HELPER_OFFSET = 0x360;
    uint256 internal constant TIMING_OFFSET = 0x3E0;

    uint128 internal constant DISPUTE_NEW_AMOUNT1 = uint128(1.1e18);
    uint128 internal constant DISPUTE_NEW_AMOUNT2 = uint128(2100e18);

    function setUp() public override {
        BaseGGTest.setUp();
    }

    function _reportedContext() internal returns (ReportContext memory ctx) {
        vm.prank(alice);
        ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + _defaultParams().disputeDelay + 1);
    }

    function _disputeCallData(ReportContext memory ctx) internal view returns (bytes memory data) {
        data = abi.encodeCall(
            oracle.dispute,
            (
                ctx.reportId,
                address(token1),
                DISPUTE_NEW_AMOUNT1,
                DISPUTE_NEW_AMOUNT2,
                bob,
                false,
                false,
                ctx.game,
                ctx.helper,
                _emptyTiming()
            )
        );
    }

    function _expectedPostHash(ReportContext memory ctx) internal view returns (bytes32) {
        (uint48 ct, uint48 oppo) = _timestamps(ctx.game.flags);
        Slim.OracleGame memory newGame =
            _gameAfterDispute(ctx.game, DISPUTE_NEW_AMOUNT1, DISPUTE_NEW_AMOUNT2, bob, ct, oppo);
        return _hashOracle(newGame, ctx.helper);
    }

    function _dirtyPaddingByte(uint256 slotOffset, uint256 valueBytes) internal pure returns (uint256) {
        return slotOffset + 32 - valueBytes - 1;
    }

    function _assertDirtyReverts(uint256 byteOffset, string memory label) internal {
        ReportContext memory ctx = _reportedContext();
        bytes32 hashBefore = oracle.oracleGame(ctx.reportId);
        bytes memory data = _disputeCallData(ctx);
        data[4 + byteOffset] = bytes1(0x01);

        vm.prank(bob);
        (bool ok,) = address(oracle).call(data);

        assertFalse(ok, string.concat(label, " must revert"));
        assertEq(oracle.oracleGame(ctx.reportId), hashBefore, string.concat(label, " must not mutate state hash"));
    }

    function testDirtyCalldata_CleanDisputeSucceeds() public {
        ReportContext memory ctx = _reportedContext();
        bytes memory data = _disputeCallData(ctx);

        vm.prank(bob);
        (bool ok,) = address(oracle).call(data);

        assertTrue(ok, "clean dispute must succeed");
    }

    // ─── dispute() top-level args ──────────────────────────────────────────────
    // 0x000 reportId              uint256
    // 0x020 tokenToSwap           address
    // 0x040 newAmount1            uint128
    // 0x060 newAmount2            uint128
    // 0x080 disputer              address
    // 0x0A0 tryInternalBalance1   bool
    // 0x0C0 tryInternalBalance2   bool

    function testDirtyCalldata_DisputeRevertsDirtyTokenToSwap() public {
        _assertDirtyReverts(_dirtyPaddingByte(0x020, 20), "tokenToSwap");
    }

    function testDirtyCalldata_DisputeRevertsDirtyNewAmount1() public {
        _assertDirtyReverts(_dirtyPaddingByte(0x040, 16), "newAmount1");
    }

    function testDirtyCalldata_DisputeRevertsDirtyNewAmount2() public {
        _assertDirtyReverts(_dirtyPaddingByte(0x060, 16), "newAmount2");
    }

    function testDirtyCalldata_DisputeRevertsDirtyDisputer() public {
        _assertDirtyReverts(_dirtyPaddingByte(0x080, 20), "disputer");
    }

    function testDirtyCalldata_DisputeRevertsDirtyTryInternalBalance1() public {
        _assertDirtyReverts(_dirtyPaddingByte(0x0A0, 1), "tryInternalBalance1");
    }

    function testDirtyCalldata_DisputeRevertsDirtyTryInternalBalance2() public {
        _assertDirtyReverts(_dirtyPaddingByte(0x0C0, 1), "tryInternalBalance2");
    }

    // ─── OracleGame struct (at 0x0E0) ─────────────────────────────────────────
    // Same layout as report() — the pre-state hash check catches any dirty padding
    // bit because it builds the hash buffer via calldatacopy(params, 0x280).

    function testDirtyCalldata_DisputeRevertsDirtyCurrentAmount1() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x000, 16), "currentAmount1");
    }

    function testDirtyCalldata_DisputeRevertsDirtyCurrentAmount2() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x020, 16), "currentAmount2");
    }

    function testDirtyCalldata_DisputeRevertsDirtyCurrentReporter() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x040, 20), "currentReporter");
    }

    function testDirtyCalldata_DisputeRevertsDirtyReportTimestamp() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x060, 6), "reportTimestamp");
    }

    function testDirtyCalldata_DisputeRevertsDirtySettlementTimestamp() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x080, 6), "settlementTimestamp");
    }

    function testDirtyCalldata_DisputeRevertsDirtyToken1() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x0A0, 20), "token1");
    }

    function testDirtyCalldata_DisputeRevertsDirtyLastReportOppoTime() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x0C0, 6), "lastReportOppoTime");
    }

    function testDirtyCalldata_DisputeRevertsDirtySettlementTime() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x0E0, 6), "settlementTime");
    }

    function testDirtyCalldata_DisputeRevertsDirtyEscalationHalt() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x100, 16), "escalationHalt");
    }

    function testDirtyCalldata_DisputeRevertsDirtyProtocolFeeRecipient() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x120, 20), "protocolFeeRecipient");
    }

    function testDirtyCalldata_DisputeRevertsDirtySettlerReward() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x140, 12), "settlerReward");
    }

    function testDirtyCalldata_DisputeRevertsDirtyToken2() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x160, 20), "token2");
    }

    function testDirtyCalldata_DisputeRevertsDirtyNumReports() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x180, 3), "numReports");
    }

    function testDirtyCalldata_DisputeRevertsDirtyDisputeDelay() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x1A0, 3), "disputeDelay");
    }

    function testDirtyCalldata_DisputeRevertsDirtyFeePercentage() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x1C0, 3), "feePercentage");
    }

    function testDirtyCalldata_DisputeRevertsDirtyMultiplier() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x1E0, 2), "multiplier");
    }

    function testDirtyCalldata_DisputeRevertsDirtyCallbackContract() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x200, 20), "callbackContract");
    }

    function testDirtyCalldata_DisputeRevertsDirtyCallbackGasLimit() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x220, 4), "callbackGasLimit");
    }

    function testDirtyCalldata_DisputeRevertsDirtyProtocolFee() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x240, 3), "protocolFee");
    }

    function testDirtyCalldata_DisputeRevertsDirtyFlags() public {
        _assertDirtyReverts(ORACLE_GAME_OFFSET + _dirtyPaddingByte(0x260, 1), "flags");
    }

    // ─── PreimageHelper struct (at 0x360) ─────────────────────────────────────
    // reportId / blockTimestamp / blockNumber are all uint256 → no padding bytes.
    // Only creator (address) has a 12-byte padding zone.

    function testDirtyCalldata_DisputeRevertsDirtyHelperCreator() public {
        _assertDirtyReverts(PREIMAGE_HELPER_OFFSET + _dirtyPaddingByte(0x020, 20), "helper.creator");
    }

    // ─── Comprehensive every-padding-byte fuzz ────────────────────────────────
    //
    // Strong invariant: dirtying ANY single padding byte of the dispute calldata
    // must produce one of two outcomes:
    //   (a) the call reverts AND the on-chain state hash is unchanged
    //   (b) the call succeeds AND the on-chain state hash equals what a clean
    //       dispute (same inputs, no dirty bytes) would have produced
    //
    // This is the security-critical guarantee: a wrapper or malicious encoder
    // cannot craft dirty calldata that both succeeds and poisons the second
    // (post-mutation) hash, leaving the report in a state inconsistent with
    // what off-chain observers / disputers / settlers reconstructed.
    //
    // Padding bytes covered (per dispute calldata):
    //   top-level:     tokenToSwap(12) + newAmount1(16) + newAmount2(16)
    //                + disputer(12) + tib1(31) + tib2(31)                 = 118
    //   OracleGame:    sum of (32 - W) for 20 fields                       = 437
    //   PreimageHelper: only creator has padding                           = 12
    //   TimingBoundaries: all uint256, no padding                          = 0
    //                                                                  Total = 567 byte positions
    function testFuzzAllPaddingBytes_Dispute_StateHashInvariant() public {
        // Build the full padding-byte index list once (deterministic order).
        uint256[] memory padBytes = _allPaddingByteOffsets();
        bytes1 DIRTY = 0xFF;

        // For each padding byte: fresh report, dirty that single byte, dispute,
        // assert one of the two outcomes.
        for (uint256 i = 0; i < padBytes.length; i++) {
            uint256 snap = vm.snapshotState();

            ReportContext memory ctx = _reportedContext();
            bytes32 hashBefore = oracle.oracleGame(ctx.reportId);
            bytes32 expectedPost = _expectedPostHash(ctx);

            bytes memory cd = _disputeCallData(ctx);
            cd[4 + padBytes[i]] = DIRTY;

            vm.prank(bob);
            (bool ok, bytes memory ret) = address(oracle).call(cd);

            bytes32 hashAfter = oracle.oracleGame(ctx.reportId);
            // Strict layered invariant:
            //   - Top-level args (offsets < 0x0E0)            → pure type-decode revert: empty returndata
            //   - PreimageHelper.creator (offset 0x380..0x38B) → pure type-decode revert: empty returndata
            //   - OracleGame struct fields (0x0E0..0x35F)     → hash-mismatch revert: InvalidStateHash() selector
            // Anything else (downstream business error from masked-then-validated values) FAILS the test.
            assertFalse(ok, string.concat("dirty must revert @ byte ", vm.toString(padBytes[i])));

            uint256 off = padBytes[i];
            bytes4 invalidStateHashSel = bytes4(keccak256("InvalidStateHash()"));
            if (off < ORACLE_GAME_OFFSET) {
                // Top-level arg padding → Solidity strict-decode → empty returndata.
                assertEq(
                    ret.length,
                    0,
                    string.concat("top-level dirty must be type-decode revert @ byte ", vm.toString(off))
                );
            } else if (off >= ORACLE_GAME_OFFSET && off < PREIMAGE_HELPER_OFFSET) {
                // OracleGame struct field padding → hash mismatch → InvalidStateHash().
                assertEq(ret.length, 4, string.concat("OracleGame dirty must be 4-byte revert @ byte ", vm.toString(off)));
                assertEq(
                    bytes4(ret),
                    invalidStateHashSel,
                    string.concat("OracleGame dirty must revert InvalidStateHash @ byte ", vm.toString(off))
                );
            } else {
                // PreimageHelper.creator padding. Helper struct is part of the hash buffer
                // (calldatacopy), so dirty creator padding triggers the same hash mismatch.
                assertEq(ret.length, 4, string.concat("helper dirty must be 4-byte revert @ byte ", vm.toString(off)));
                assertEq(
                    bytes4(ret),
                    invalidStateHashSel,
                    string.concat("helper dirty must revert InvalidStateHash @ byte ", vm.toString(off))
                );
            }
            assertEq(
                hashAfter,
                hashBefore,
                string.concat("dirty revert must not mutate hash @ byte ", vm.toString(off))
            );
            expectedPost; // silence unused

            vm.revertToState(snap);
        }
    }

    function _allPaddingByteOffsets() internal pure returns (uint256[] memory out) {
        // Field table: (slotOffset, valueBytes). Order matches the calldata layout.
        // reportId / TimingBoundaries fields / helper.reportId / helper.blockTimestamp /
        // helper.blockNumber are all uint256 → no padding, omitted.
        uint256[2][27] memory fields = [
            // top-level args
            [uint256(0x020), uint256(20)], // tokenToSwap
            [uint256(0x040), uint256(16)], // newAmount1
            [uint256(0x060), uint256(16)], // newAmount2
            [uint256(0x080), uint256(20)], // disputer
            [uint256(0x0A0), uint256(1)],  // tib1
            [uint256(0x0C0), uint256(1)],  // tib2
            // OracleGame at 0x0E0 (offsets below are absolute, already including base)
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
            // PreimageHelper at 0x360 — only creator has padding
            [uint256(PREIMAGE_HELPER_OFFSET + 0x020), uint256(20)] // helper.creator
        ];

        // Count total padding bytes.
        uint256 total = 0;
        for (uint256 i = 0; i < fields.length; i++) {
            total += 32 - fields[i][1];
        }

        out = new uint256[](total);
        uint256 k = 0;
        for (uint256 i = 0; i < fields.length; i++) {
            uint256 slotOff = fields[i][0];
            uint256 padLen = 32 - fields[i][1];
            // Padding bytes are at slot offsets [0 .. 32 - valueBytes).
            for (uint256 p = 0; p < padLen; p++) {
                out[k++] = slotOff + p;
            }
        }
    }
}
