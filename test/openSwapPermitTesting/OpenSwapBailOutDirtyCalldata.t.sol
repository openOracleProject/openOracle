// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";

/// @notice Dirty-calldata fuzz for openSwap.bailOut().
///
///         bailOut hashes `keccak256(abi.encode(_swap))` against swaps[swapId] and
///         `keccak256(abi.encode(oracleState, oracleHelper))` against the oracle's stored
///         game hash. Solidity reads each calldata field via typed decode with
///         strict-decode → dirty padding causes empty-data revert. If a field somehow
///         slips through (unlikely), the resulting hash differs → WrongHash() for the
///         MatchedSwap region, WrongOracleHash() for the OracleGame / PreimageHelper
///         regions. Both are accepted as defenses.
contract OpenSwapBailOutDirtyCalldataTest is SlimTestBase {
    uint256 internal constant MATCHED_SWAP_OFFSET = 0x020; // after swapId
    uint256 internal constant ORACLE_GAME_OFFSET = 0x200; // after MatchedSwap
    uint256 internal constant ORACLE_HELPER_OFFSET = 0x480; // after OracleGame

    function setUp() public {
        _setUpAll();
    }

    function _proposeMatchAndDispute()
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
        (, , sPost) = _match(swapId, 2000e18, expiration);
        sPost.feeRecipient = address(0); // protocolFee==0 in default params → no clone
        (og, ph) = _gameAtMatch(swapId, expiration, 2000e18, sPost);
        // Dispute past maxGameTime so bailOut is eligible.
        og = _disputePastMaxGameTime(og, ph, sPost);
    }

    function _bailOutCallData(
        uint256 swapId,
        openSwapV2.MatchedSwap memory sPost,
        IOpenOracle2.OracleGame memory og,
        IOpenOracle2.PreimageHelper memory ph
    ) internal view returns (bytes memory) {
        return abi.encodeCall(swapContract.bailOut, (swapId, sPost, og, ph));
    }

    function testDirtyCalldata_CleanBailOutSucceeds() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatchAndDispute();
        bytes memory cd = _bailOutCallData(swapId, sPost, og, ph);

        vm.prank(matcher);
        (bool ok,) = address(swapContract).call(cd);
        assertTrue(ok, "clean bailOut must succeed");
    }

    function testFuzzAllPaddingBytes_BailOut_Invariant() public {
        uint256[] memory padBytes = _allBailOutPaddingByteOffsets();
        bytes1 DIRTY = 0xFF;
        bytes4 wrongHashSel = bytes4(keccak256("WrongHash()"));
        bytes4 wrongOracleHashSel = bytes4(keccak256("WrongOracleHash()"));

        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatchAndDispute();
        bytes32 hashBefore = swapContract.swaps(swapId);
        bytes memory clean = _bailOutCallData(swapId, sPost, og, ph);

        for (uint256 i = 0; i < padBytes.length; i++) {
            uint256 snap = vm.snapshotState();

            bytes memory cd = bytes.concat(clean);
            cd[4 + padBytes[i]] = DIRTY;

            vm.prank(matcher);
            (bool ok, bytes memory ret) = address(swapContract).call(cd);

            assertFalse(ok, string.concat("dirty must revert @ byte ", vm.toString(padBytes[i])));
            bytes4 hashSel = padBytes[i] < ORACLE_GAME_OFFSET ? wrongHashSel : wrongOracleHashSel;
            bool acceptable = (ret.length == 0) || (ret.length == 4 && bytes4(ret) == hashSel);
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
        // bailOut calldata: swapId(uint256) · MatchedSwap(15 slots) · OracleGame(20) · PreimageHelper(4).
        // Field widths in declaration order:
        uint256[2][36] memory fields = [
            [uint256(MATCHED_SWAP_OFFSET + 0x000), uint256(16)], // sellAmt
            [uint256(MATCHED_SWAP_OFFSET + 0x020), uint256(16)], // minFulfillLiquidity
            [uint256(MATCHED_SWAP_OFFSET + 0x040), uint256(3)],  // maxGameTime
            [uint256(MATCHED_SWAP_OFFSET + 0x060), uint256(20)], // buyToken
            [uint256(MATCHED_SWAP_OFFSET + 0x080), uint256(20)], // sellToken
            [uint256(MATCHED_SWAP_OFFSET + 0x0A0), uint256(20)], // swapper
            [uint256(MATCHED_SWAP_OFFSET + 0x0C0), uint256(12)], // executorGasComp
            [uint256(MATCHED_SWAP_OFFSET + 0x0E0), uint256(1)],  // useInternalBalances
            [uint256(MATCHED_SWAP_OFFSET + 0x100), uint256(16)], // reportId
            [uint256(MATCHED_SWAP_OFFSET + 0x120), uint256(20)], // matcher
            [uint256(MATCHED_SWAP_OFFSET + 0x140), uint256(6)],  // start
            [uint256(MATCHED_SWAP_OFFSET + 0x160), uint256(3)],  // fulfillmentFee
            [uint256(MATCHED_SWAP_OFFSET + 0x180), uint256(20)], // feeRecipient
            [uint256(MATCHED_SWAP_OFFSET + 0x1A0), uint256(29)], // priceTolerated
            [uint256(MATCHED_SWAP_OFFSET + 0x1C0), uint256(3)],  // toleranceRange
            // OracleGame at 0x200 (20 fields)
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
            // PreimageHelper.creator at 0x480 + 0x020 (the other helper fields are full-width)
            [uint256(ORACLE_HELPER_OFFSET + 0x020), uint256(20)]
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
