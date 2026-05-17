// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";

/// @notice Dirty-calldata fuzz for openSwap.bailOut().
///
///         bailOut hashes via `keccak256(abi.encode(_swap))` where `_swap` is a
///         MatchedSwap calldata struct. Solidity reads each field via typed decode
///         with strict-decode → dirty padding causes empty-data revert. If a field
///         somehow slips through (unlikely), the resulting hash differs from
///         swaps[swapId] → WrongHash() revert. Both are accepted as defenses.
contract OpenSwapBailOutDirtyCalldataTest is SlimTestBase {
    uint256 internal constant MATCHED_SWAP_OFFSET = 0x020; // after swapId

    function setUp() public {
        _setUpAll();
    }

    function _proposeMatchAndWarp()
        internal
        returns (uint256 swapId, openSwapV2.MatchedSwap memory sPost)
    {
        uint48 expiration;
        (swapId, expiration) = _propose();
        (, , sPost) = _match(swapId, 2000e18, expiration);
        sPost.feeRecipient = address(0); // protocolFee==0 in default params → no clone
        // Warp past maxGameTime so bailOut is eligible.
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
    }

    function _bailOutCallData(uint256 swapId, openSwapV2.MatchedSwap memory sPost)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(swapContract.bailOut, (swapId, sPost));
    }

    function testDirtyCalldata_CleanBailOutSucceeds() public {
        (uint256 swapId, openSwapV2.MatchedSwap memory sPost) = _proposeMatchAndWarp();
        bytes memory cd = _bailOutCallData(swapId, sPost);

        vm.prank(matcher);
        (bool ok,) = address(swapContract).call(cd);
        assertTrue(ok, "clean bailOut must succeed");
    }

    function testFuzzAllPaddingBytes_BailOut_Invariant() public {
        uint256[] memory padBytes = _allBailOutPaddingByteOffsets();
        bytes1 DIRTY = 0xFF;
        bytes4 wrongHashSel = bytes4(keccak256("WrongHash()"));

        for (uint256 i = 0; i < padBytes.length; i++) {
            uint256 snap = vm.snapshotState();

            (uint256 swapId, openSwapV2.MatchedSwap memory sPost) = _proposeMatchAndWarp();
            bytes32 hashBefore = swapContract.swaps(swapId);
            bytes memory cd = _bailOutCallData(swapId, sPost);
            cd[4 + padBytes[i]] = DIRTY;

            vm.prank(matcher);
            (bool ok, bytes memory ret) = address(swapContract).call(cd);

            assertFalse(ok, string.concat("dirty must revert @ byte ", vm.toString(padBytes[i])));
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

    function _allBailOutPaddingByteOffsets() internal pure returns (uint256[] memory out) {
        // bailOut calldata: swapId(uint256) · MatchedSwap(16 slots).
        // MatchedSwap field widths in declaration order:
        uint256[2][16] memory fields = [
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
            [uint256(MATCHED_SWAP_OFFSET + 0x1E0), uint256(3)]   // toleranceRange
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
