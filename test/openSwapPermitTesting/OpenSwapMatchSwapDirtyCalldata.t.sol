// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

/// @notice Dirty-calldata fuzz for openSwap.matchSwap().
///
///         matchSwap stages a buffer via raw calldatacopy of (_swap, preimage) and
///         keccaks it FIRST, comparing against swaps[swapId] before any typed
///         field read. So dirty padding in the struct args is caught by the
///         hash-mismatch path → WrongHash() (4-byte custom error).
///
///         The top-level amount2 (uint128) is read via Solidity typed calldata
///         decode, so dirty padding there is caught by strict-decode → empty
///         returndata. swapId (uint256) and TimingBoundaries (4 uint256) have no
///         padding bytes.
contract OpenSwapMatchSwapDirtyCalldataTest is SlimTestBase {
    uint256 internal constant AMOUNT2_OFFSET = 0x000;          // (post-selector) swapId @ 0x00, amount2 @ 0x20
    uint256 internal constant PROPOSED_SWAP_OFFSET = 0x040;    // after swapId + amount2
    uint256 internal constant MATCHER_PREIMAGE_OFFSET = 0x200; // after ProposedSwap (14 slots)
    uint256 internal constant TIMING_OFFSET = 0x380;           // after MatcherPreimage (12 slots)

    function setUp() public {
        _setUpAll();
    }

    function _proposeForMatch()
        internal
        returns (
            uint256 swapId,
            uint48 expiration,
            openSwapV2.ProposedSwap memory s,
            openSwapV2.MatcherPreimage memory m
        )
    {
        (swapId, expiration) = _propose();
        (s, m) = _buildSwapAndPreimage(swapId, expiration);
    }

    function _matchSwapCallData(
        uint256 swapId,
        openSwapV2.ProposedSwap memory s,
        openSwapV2.MatcherPreimage memory m
    ) internal view returns (bytes memory) {
        IOpenOracle2.TimingBoundaries memory t = IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
        return abi.encodeCall(swapContract.matchSwap, (swapId, 2000e18, s, m, t));
    }

    function testDirtyCalldata_CleanMatchSwapSucceeds() public {
        (uint256 swapId,, openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _proposeForMatch();
        bytes memory cd = _matchSwapCallData(swapId, s, m);

        vm.prank(matcher);
        (bool ok,) = address(swapContract).call(cd);
        assertTrue(ok, "clean matchSwap must succeed");
    }

    function testFuzzAllPaddingBytes_MatchSwap_LayeredInvariant() public {
        uint256[] memory padBytes = _allMatchSwapPaddingByteOffsets();
        bytes1 DIRTY = 0xFF;
        bytes4 wrongHashSel = bytes4(keccak256("WrongHash()"));

        for (uint256 i = 0; i < padBytes.length; i++) {
            uint256 snap = vm.snapshotState();

            (uint256 swapId,, openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
                _proposeForMatch();
            bytes32 hashBefore = swapContract.swaps(swapId);
            bytes memory cd = _matchSwapCallData(swapId, s, m);
            cd[4 + padBytes[i]] = DIRTY;

            vm.prank(matcher);
            (bool ok, bytes memory ret) = address(swapContract).call(cd);

            assertFalse(ok, string.concat("dirty must revert @ byte ", vm.toString(padBytes[i])));

            uint256 off = padBytes[i];
            if (off >= PROPOSED_SWAP_OFFSET && off < TIMING_OFFSET) {
                // Struct fields → calldatacopy → keccak → WrongHash()
                assertEq(
                    ret.length, 4, string.concat("struct dirty must be 4-byte revert @ byte ", vm.toString(off))
                );
                assertEq(
                    bytes4(ret),
                    wrongHashSel,
                    string.concat("struct dirty must revert WrongHash @ byte ", vm.toString(off))
                );
            } else {
                // Top-level amount2 → typed decode → empty returndata
                assertEq(
                    ret.length,
                    0,
                    string.concat("top-level dirty must be type-decode revert @ byte ", vm.toString(off))
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

    function _allMatchSwapPaddingByteOffsets() internal pure returns (uint256[] memory out) {
        // matchSwap calldata: swapId(uint256) · amount2(uint128) · ProposedSwap(14) · MatcherPreimage(12) · Timing(4 uint256).
        uint256[2][27] memory fields = [
            // amount2 at 0x020 (W=16)
            [uint256(0x020), uint256(16)],
            // ProposedSwap at 0x040
            [uint256(0x040), uint256(16)], // sellAmt
            [uint256(0x060), uint256(16)], // minFulfillLiquidity
            [uint256(0x080), uint256(12)], // settlerReward
            [uint256(0x0A0), uint256(3)],  // maxGameTime
            [uint256(0x0C0), uint256(2)],  // blocksPerSecond
            [uint256(0x0E0), uint256(20)], // buyToken
            [uint256(0x100), uint256(12)], // matcherGasComp
            [uint256(0x120), uint256(20)], // sellToken
            [uint256(0x140), uint256(20)], // swapper
            [uint256(0x160), uint256(12)], // executorGasComp
            [uint256(0x180), uint256(1)],  // useInternalBalances
            [uint256(0x1A0), uint256(6)],  // expiration
            [uint256(0x1C0), uint256(29)], // priceTolerated
            [uint256(0x1E0), uint256(3)],  // toleranceRange
            // MatcherPreimage at 0x200
            [uint256(0x200), uint256(16)], // initialLiquidity
            [uint256(0x220), uint256(16)], // escalationHalt
            [uint256(0x240), uint256(6)],  // settlementTime
            [uint256(0x260), uint256(3)],  // disputeDelay
            [uint256(0x280), uint256(3)],  // protocolFee
            [uint256(0x2A0), uint256(2)],  // multiplier
            [uint256(0x2C0), uint256(6)],  // startFulfillFeeIncrease
            [uint256(0x2E0), uint256(3)],  // maxFee
            [uint256(0x300), uint256(3)],  // startingFee
            [uint256(0x320), uint256(3)],  // roundLength
            [uint256(0x340), uint256(2)],  // growthRate
            [uint256(0x360), uint256(2)]   // maxRounds
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
