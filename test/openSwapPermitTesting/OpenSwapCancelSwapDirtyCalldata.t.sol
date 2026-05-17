// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

/// @notice Dirty-calldata fuzz for openSwap.cancelSwap().
///
///         Unlike matchSwap (which uses raw calldatacopy), cancelSwap hashes via
///         `keccak256(abi.encode(_swap, preimage))` — Solidity's abi.encode reads
///         each calldata struct field through its typed-decode path and re-encodes
///         to memory. For sub-256-bit fields, dirty padding triggers strict-decode
///         BEFORE the hash is even computed → pure type-decode revert (empty data).
///
///         Therefore the expected invariant is: every dirty padding byte in the
///         struct args reverts with empty returndata. swapId (uint256) has no
///         padding.
contract OpenSwapCancelSwapDirtyCalldataTest is SlimTestBase {
    uint256 internal constant PROPOSED_SWAP_OFFSET = 0x020;
    uint256 internal constant MATCHER_PREIMAGE_OFFSET = 0x1E0;

    function setUp() public {
        _setUpAll();
    }

    function _proposeForCancel()
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

    function _cancelCallData(
        uint256 swapId,
        openSwapV2.ProposedSwap memory s,
        openSwapV2.MatcherPreimage memory m
    ) internal view returns (bytes memory) {
        return abi.encodeCall(swapContract.cancelSwap, (swapId, s, m));
    }

    function testDirtyCalldata_CleanCancelSucceeds() public {
        (uint256 swapId,, openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _proposeForCancel();
        bytes memory cd = _cancelCallData(swapId, s, m);

        vm.prank(swapper);
        (bool ok,) = address(swapContract).call(cd);
        assertTrue(ok, "clean cancelSwap must succeed");
    }

    function testFuzzAllPaddingBytes_CancelSwap_Invariant() public {
        uint256[] memory padBytes = _allCancelPaddingByteOffsets();
        bytes1 DIRTY = 0xFF;
        bytes4 wrongHashSel = bytes4(keccak256("WrongHash()"));

        for (uint256 i = 0; i < padBytes.length; i++) {
            uint256 snap = vm.snapshotState();

            (uint256 swapId,, openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
                _proposeForCancel();
            bytes32 hashBefore = swapContract.swaps(swapId);
            bytes memory cd = _cancelCallData(swapId, s, m);
            cd[4 + padBytes[i]] = DIRTY;

            vm.prank(swapper);
            (bool ok, bytes memory ret) = address(swapContract).call(cd);

            assertFalse(ok, string.concat("dirty must revert @ byte ", vm.toString(padBytes[i])));
            // Either pure type-decode revert (empty) or WrongHash() — both are acceptable
            // defenses. What's NOT acceptable: some other downstream custom error, or success.
            bool acceptable = (ret.length == 0) || (ret.length == 4 && bytes4(ret) == wrongHashSel);
            assertTrue(
                acceptable,
                string.concat("dirty must revert via type-decode or WrongHash @ byte ", vm.toString(padBytes[i]))
            );
            assertEq(
                swapContract.swaps(swapId),
                hashBefore,
                string.concat("dirty revert must not mutate swap hash @ byte ", vm.toString(padBytes[i]))
            );

            vm.revertToState(snap);
        }
    }

    function _allCancelPaddingByteOffsets() internal pure returns (uint256[] memory out) {
        // cancelSwap calldata: swapId(uint256) · ProposedSwap(14) · MatcherPreimage(12).
        uint256[2][26] memory fields = [
            // ProposedSwap at 0x020
            [uint256(0x020), uint256(16)], // sellAmt
            [uint256(0x040), uint256(16)], // minFulfillLiquidity
            [uint256(0x060), uint256(12)], // settlerReward
            [uint256(0x080), uint256(3)],  // maxGameTime
            [uint256(0x0A0), uint256(2)],  // blocksPerSecond
            [uint256(0x0C0), uint256(20)], // buyToken
            [uint256(0x0E0), uint256(12)], // matcherGasComp
            [uint256(0x100), uint256(20)], // sellToken
            [uint256(0x120), uint256(20)], // swapper
            [uint256(0x140), uint256(12)], // executorGasComp
            [uint256(0x160), uint256(1)],  // useInternalBalances
            [uint256(0x180), uint256(6)],  // expiration
            [uint256(0x1A0), uint256(29)], // priceTolerated
            [uint256(0x1C0), uint256(3)],  // toleranceRange
            // MatcherPreimage at 0x1E0
            [uint256(0x1E0), uint256(16)], // initialLiquidity
            [uint256(0x200), uint256(16)], // escalationHalt
            [uint256(0x220), uint256(6)],  // settlementTime
            [uint256(0x240), uint256(3)],  // disputeDelay
            [uint256(0x260), uint256(3)],  // protocolFee
            [uint256(0x280), uint256(2)],  // multiplier
            [uint256(0x2A0), uint256(6)],  // startFulfillFeeIncrease
            [uint256(0x2C0), uint256(3)],  // maxFee
            [uint256(0x2E0), uint256(3)],  // startingFee
            [uint256(0x300), uint256(3)],  // roundLength
            [uint256(0x320), uint256(2)],  // growthRate
            [uint256(0x340), uint256(2)]   // maxRounds
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
