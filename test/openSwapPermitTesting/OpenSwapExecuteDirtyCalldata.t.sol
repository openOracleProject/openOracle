// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";

/// @notice Dirty-calldata fuzz for openSwap.execute().
///
///         execute() stages TWO buffers via raw calldatacopy:
///           - swapState (MatchedSwap, 0x200) → keccak → swaps[swapId]   ⇒ WrongHash()
///           - oracleState + oracleHelper (0x300) → keccak → oracle.oracleGame[reportId]
///             ⇒ mismatch falls into "loose timing" fallbacks before ultimately reverting.
///
///         Top-level: swapId (uint256, no padding) · looseTiming (bool, padded).
///
///         Layered expectation:
///           looseTiming padding   → strict-decode → empty data
///           MatchedSwap padding   → raw calldatacopy → WrongHash() (4-byte)
///           OracleGame padding    → raw calldatacopy → eventually reverts; we accept
///                                   any 4-byte custom error (covers WrongHash,
///                                   the various loose-timing-related custom errors,
///                                   and the no-such-report path)
///           PreimageHelper padding → same as OracleGame region
contract OpenSwapExecuteDirtyCalldataTest is SlimTestBase {
    uint256 internal constant MATCHED_SWAP_OFFSET = 0x020;     // after swapId
    uint256 internal constant ORACLE_GAME_OFFSET = 0x220;      // after MatchedSwap
    uint256 internal constant ORACLE_HELPER_OFFSET = 0x4A0;    // after OracleGame
    uint256 internal constant LOOSE_TIMING_OFFSET = 0x520;     // after PreimageHelper

    function setUp() public {
        _setUpAll();
    }

    function _proposeMatchSettleAndPrep()
        internal
        returns (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        )
    {
        uint48 expiration;
        (swapId, expiration) = _propose();
        (openSwapV2.ProposedSwap memory s0, openSwapV2.MatcherPreimage memory m0) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 rid, , openSwapV2.MatchedSwap memory sp) = _match(swapId, 2000e18, expiration);
        sp.feeRecipient = address(0); // default protocolFee=0 → no clone
        sPost = sp;

        og = _buildOracleGameAtReport(s0, m0, 2000e18);
        ph = _buildPreimageHelper(rid);

        // Warp past settlementTime and settle the oracle so execute's post-settle hash is the live one.
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        _settle(rid, og, ph);
        og.settlementTimestamp = uint48(block.timestamp);
    }

    function _executeCallData(
        uint256 swapId,
        openSwapV2.MatchedSwap memory sPost,
        IOpenOracle2.OracleGame memory og,
        IOpenOracle2.PreimageHelper memory ph
    ) internal view returns (bytes memory) {
        return abi.encodeCall(swapContract.execute, (swapId, sPost, og, ph, false));
    }

    function testDirtyCalldata_CleanExecuteSucceeds() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatchSettleAndPrep();
        bytes memory cd = _executeCallData(swapId, sPost, og, ph);

        vm.prank(settler);
        (bool ok,) = address(swapContract).call(cd);
        assertTrue(ok, "clean execute must succeed");
    }

    function testFuzzAllPaddingBytes_Execute_LayeredInvariant() public {
        uint256[] memory padBytes = _allExecutePaddingByteOffsets();
        bytes1 DIRTY = 0xFF;

        for (uint256 i = 0; i < padBytes.length; i++) {
            uint256 snap = vm.snapshotState();

            (
                uint256 swapId,
                openSwapV2.MatchedSwap memory sPost,
                IOpenOracle2.OracleGame memory og,
                IOpenOracle2.PreimageHelper memory ph
            ) = _proposeMatchSettleAndPrep();
            bytes32 hashBefore = swapContract.swaps(swapId);
            bytes memory cd = _executeCallData(swapId, sPost, og, ph);
            cd[4 + padBytes[i]] = DIRTY;

            vm.prank(settler);
            (bool ok, bytes memory ret) = address(swapContract).call(cd);

            assertFalse(ok, string.concat("dirty must revert @ byte ", vm.toString(padBytes[i])));

            uint256 off = padBytes[i];
            bytes4 wrongHashSel = bytes4(keccak256("WrongHash()"));
            bytes4 wrongOracleHashSel = bytes4(keccak256("WrongOracleHash()"));

            if (off >= LOOSE_TIMING_OFFSET) {
                // looseTiming bool padding → strict-decode → empty data
                assertEq(
                    ret.length,
                    0,
                    string.concat("looseTiming dirty must be type-decode revert @ byte ", vm.toString(off))
                );
            } else if (off >= MATCHED_SWAP_OFFSET && off < ORACLE_GAME_OFFSET) {
                // MatchedSwap region → swap-hash check fires first → WrongHash().
                assertEq(ret.length, 4, string.concat("MatchedSwap dirty must be 4-byte revert @ byte ", vm.toString(off)));
                assertEq(
                    bytes4(ret), wrongHashSel,
                    string.concat("MatchedSwap dirty must revert WrongHash @ byte ", vm.toString(off))
                );
            } else if (off >= ORACLE_GAME_OFFSET && off < ORACLE_HELPER_OFFSET) {
                // OracleGame region → oracle-hash check fires → WrongOracleHash() EXCEPT
                // settlementTimestamp's padding slot (offset 0x80 in the struct, padding
                // bytes 0..25 of that slot). The loose-timing branches evaluate
                // `oracleState.settlementTimestamp == 0/> 2` via typed calldata access,
                // which strict-decodes the slot's high bytes → empty-data revert before
                // the WrongOracleHash() branch is reached.
                uint256 ogSlotOff = off - ORACLE_GAME_OFFSET;
                bool isSettlementTimestampPadding = ogSlotOff >= 0x80 && ogSlotOff < 0x80 + 26;
                if (isSettlementTimestampPadding) {
                    assertEq(
                        ret.length, 0,
                        string.concat("settlementTimestamp padding must be type-decode @ byte ", vm.toString(off))
                    );
                } else {
                    assertEq(
                        ret.length, 4,
                        string.concat("OracleGame dirty must be 4-byte revert @ byte ", vm.toString(off))
                    );
                    assertEq(
                        bytes4(ret), wrongOracleHashSel,
                        string.concat("OracleGame dirty must revert WrongOracleHash @ byte ", vm.toString(off))
                    );
                }
            } else {
                // PreimageHelper region (only helper.creator has padding) → contributes to
                // the oracle hash → WrongOracleHash().
                assertEq(ret.length, 4, string.concat("helper dirty must be 4-byte revert @ byte ", vm.toString(off)));
                assertEq(
                    bytes4(ret), wrongOracleHashSel,
                    string.concat("helper dirty must revert WrongOracleHash @ byte ", vm.toString(off))
                );
            }
            assertEq(
                swapContract.swaps(swapId),
                hashBefore,
                string.concat("dirty revert must not mutate swap hash @ byte ", vm.toString(off))
            );

            vm.revertToState(snap);
        }
    }

    function _allExecutePaddingByteOffsets() internal pure returns (uint256[] memory out) {
        // execute calldata: swapId · MatchedSwap(16) · OracleGame(20) · PreimageHelper(4) · looseTiming(bool).
        uint256[2][38] memory fields = [
            // MatchedSwap at 0x020 (16 fields)
            [uint256(MATCHED_SWAP_OFFSET + 0x000), uint256(16)], // sellAmt
            [uint256(MATCHED_SWAP_OFFSET + 0x020), uint256(16)], // minFulfillLiquidity
            [uint256(MATCHED_SWAP_OFFSET + 0x040), uint256(3)],  // maxGameTime
            [uint256(MATCHED_SWAP_OFFSET + 0x060), uint256(2)],  // blocksPerSecond
            [uint256(MATCHED_SWAP_OFFSET + 0x080), uint256(20)], // buyToken
            [uint256(MATCHED_SWAP_OFFSET + 0x0A0), uint256(20)], // sellToken
            [uint256(MATCHED_SWAP_OFFSET + 0x0C0), uint256(20)], // swapper
            [uint256(MATCHED_SWAP_OFFSET + 0x0E0), uint256(12)], // executorGasComp
            [uint256(MATCHED_SWAP_OFFSET + 0x100), uint256(1)],  // useInternalBalances
            [uint256(MATCHED_SWAP_OFFSET + 0x120), uint256(16)], // reportId
            [uint256(MATCHED_SWAP_OFFSET + 0x140), uint256(20)], // matcher
            [uint256(MATCHED_SWAP_OFFSET + 0x160), uint256(6)],  // start
            [uint256(MATCHED_SWAP_OFFSET + 0x180), uint256(3)],  // fulfillmentFee
            [uint256(MATCHED_SWAP_OFFSET + 0x1A0), uint256(20)], // feeRecipient
            [uint256(MATCHED_SWAP_OFFSET + 0x1C0), uint256(29)], // priceTolerated
            [uint256(MATCHED_SWAP_OFFSET + 0x1E0), uint256(3)],  // toleranceRange
            // OracleGame at 0x220 (20 fields)
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
            // PreimageHelper.creator at 0x4A0 + 0x020
            [uint256(ORACLE_HELPER_OFFSET + 0x020), uint256(20)],
            // looseTiming bool at 0x520
            [uint256(LOOSE_TIMING_OFFSET), uint256(1)]
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
