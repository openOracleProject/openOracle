// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DirtyCalldataBase.t.sol";

/// @notice Shared drivers for the per-entry-point dirty-argument matrix.
abstract contract DirtyEntryPointsBase is DirtyCalldataBase {
    // ── close() top-level argument offsets ──────────────────────────────
    //
    //   close(uint256 swapId, CloseDutch dutch, MatchedSwap swapState,
    //         bool useInternalBalances, Permit2Params permit2, uint128 altGasCompExec,
    //         OracleGame oracleState, PreimageHelper oracleHelper,
    //         uint8 settlementTimestampSearchDepth)
    //
    //   0     swapId                (1 word)
    //   32    CloseDutch            (11 words -> 352 bytes)
    //   384   MatchedSwap           (31 words -> 992 bytes)
    //   1376  useInternalBalances   (1 word)
    //   1408  Permit2Params HEAD    (1 word: offset to the dynamic tail)
    //   1440  altGasCompExec        (1 word)
    //   1472  OracleGame            (20 words -> 640 bytes)
    //   2112  PreimageHelper        (4 words -> 128 bytes)
    //   2240  settlementTimestampSearchDepth (1 word)
    //   2272  Permit2Params TAIL
    uint256 internal constant CLOSE_DUTCH_OFF = 32;
    uint256 internal constant CLOSE_MATCHED_OFF = 384;
    uint256 internal constant CLOSE_USE_INTERNAL_OFF = 1376;
    uint256 internal constant CLOSE_PERMIT2_HEAD_OFF = 1408;
    uint256 internal constant CLOSE_ALT_COMP_OFF = 1440;
    uint256 internal constant CLOSE_GAME_OFF = 1472;
    uint256 internal constant CLOSE_HELPER_OFF = 2112;
    uint256 internal constant CLOSE_SEARCH_DEPTH_OFF = 2240;
    uint256 internal constant CLOSE_PERMIT2_TAIL_OFF = 2272;

    // ── propose() top-level argument offsets ────────────────────────────
    //
    //   propose(ProposedSwap s, MatcherPreimage m, Permit2Params permit2)
    //
    //   0     ProposedSwap     (27 words -> 864 bytes)
    //   864   MatcherPreimage  (12 words -> 384 bytes)
    //   1248  Permit2Params HEAD
    uint256 internal constant PROPOSE_PREIMAGE_OFF = 864;
    uint256 internal constant PROPOSE_PERMIT2_HEAD_OFF = 1248;

    // ── raw mutation shorthands ─────────────────────────────────────────

    function _withByte(bytes memory clean, uint256 absoluteByteOffset, uint8 value)
        internal
        pure
        returns (bytes memory out)
    {
        out = _copyBytes(clean);
        _writeByte(out, absoluteByteOffset, value);
        require(keccak256(out) != keccak256(clean), "mutation did not change the payload");
    }

    function _withWord(bytes memory clean, uint256 absoluteByteOffset, bytes32 value)
        internal
        pure
        returns (bytes memory out)
    {
        out = _copyBytes(clean);
        _writeWord(out, absoluteByteOffset, value);
        require(keccak256(out) != keccak256(clean), "mutation did not change the payload");
    }

    /**
     * @notice The five-step shape every entry-point case uses.
     *
     * @dev 1. the clean raw payload reaches its intended transition (so the case cannot pass
     *         merely because the entry point was unreachable);
     *      2. that transition is rolled back to the genuine pre-call state;
     *      3. the dirty variant is submitted;
     *      4. it is proven not to make the transition;
     *      5. the phase hash and every balance the function could touch are reconciled.
     */
    function _proveCleanThenDirty(
        bytes memory clean,
        bytes memory dirty,
        address caller,
        uint256 value,
        uint256 swapId,
        address collatToken,
        string memory what
    ) internal returns (uint8 kind, bytes4 sel) {
        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(caller, value, clean);
        require(okClean, string.concat(what, ": the CLEAN control payload did not reach its transition"));
        vm.revertToState(snap);

        Book memory before = _book(swapId, collatToken);

        bool ok;
        bytes memory ret;
        (ok, ret) = _rawCallPunt(caller, value, dirty);
        (kind, sel) = _assertFailedClosed(ok, ret, what);
        _assertRevertedEmpty(ok, ret, what);
        _assertStateUnchanged(before, swapId, collatToken, what);
    }

    // ── fixtures ────────────────────────────────────────────────────────

    /// @dev ERC20-collateral proposal funded externally through the recording Permit2, so a raw
    ///      `propose` payload with an empty Permit2Params is a genuine successful control.
    function _proposalCfg()
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        s = _defaultProposedSwap();
        m = _defaultMatcherPreimage();
    }

    /// @dev Matched-but-never-opened position, plus its maxGameTime, so a bailout can be made
    ///      genuinely eligible by advancing the clock.
    function _matchedAwaitingBailout()
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory matched, uint256 maxGameTime)
    {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        swapId = p.swapId;
        matched = mt.swap;
        maxGameTime = p.swap.maxGameTime;
        assertFalse(matched.active, "fixture: matched but not yet opened");
    }

    function _seedTempHolding(address who, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.prank(outsider);
            punt.dust{value: 1}(who);
        }
        assertEq(punt.tempHolding(who), n, "fixture: tempHolding seeded through real dust() calls");
    }
}
