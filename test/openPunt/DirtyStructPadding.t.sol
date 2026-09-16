// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DirtyCalldataBase.t.sol";

/**
 * @notice Exhaustive high-padding sweeps over every member of all six
 *         commitment-relevant structs, each at a representative entry point where the whole
 *         struct is hash-bound.
 *
 * @dev The property is not "all noncanonical bytes revert" because trailing calldata is
 *      lawfully ignored, and that is covered separately. It is that a dirty high bit in a field
 *      which is read, validated, hashed, or used for value movement can never be silently
 *      truncated into a successful state transition.
 *
 *      Under solc 0.8.28 / via-IR / cancun / optimizer 190, the calldata ABI decoder validates
 *      every sub-256-bit member on entry and reverts with empty returndata.
 *      Nothing reaches the commitment, so `WrongHash` is never even the failing guard. The
 *      per-iteration state reconciliation proves nothing moved regardless of which guard fired.
 *
 *      Each iteration restores a snapshot of the genuinely reached state, so no iteration can
 *      contaminate the next.
 */
contract DirtyStructPaddingTest is DirtyCalldataBase {
    uint256 internal sweepCount;

    function setUp() public {
        _setUpDirty();
    }

    // ── sweep driver ────────────────────────────────────────────────────

    struct Sweep {
        bytes clean;
        uint256 structArgOffset;
        uint256 swapId;
        address collatToken;
        address caller;
        uint256 value;
    }

    /// @dev Runs every padding byte of every member. For unsigned/address/bool members the clean
    ///      padding is zero, so 0x01 at any padding position is noncanonical. For signed members
    ///      the clean padding is the sign extension, so the probe is chosen against the observed
    ///      sign: 0xff into zero-padding, 0x00 into 0xff-padding.
    function _sweepStruct(Sweep memory sw, Field[] memory f, string memory structName)
        internal
        returns (uint256 probed)
    {
        Book memory before = _book(sw.swapId, sw.collatToken);

        for (uint256 i = 0; i < f.length; i++) {
            uint256 memberOffset = sw.structArgOffset + 32 * i;
            uint256 padCount = 32 - f[i].width;
            if (padCount == 0) continue; // full-width member: no padding region exists

            bytes32 cleanWord = _readWord(sw.clean, _argOffset(memberOffset));

            for (uint256 p = 0; p < padCount; p++) {
                uint8 cleanByte = _readByte(sw.clean, _argOffset(memberOffset) + p);
                uint8 dirtyByte;

                if (f[i].cls == C_INT) {
                    // padding must equal the sign extension; flip it to the other one
                    dirtyByte = cleanByte == 0xff ? 0x00 : 0xff;
                } else {
                    require(cleanByte == 0, "clean padding of an unsigned/address/bool member must be zero");
                    dirtyByte = 0x01;
                }

                uint256 snap = vm.snapshotState();

                // offset self-check against the clean encoding, before every mutation
                _assertCleanWord(
                    sw.clean, _argOffset(memberOffset), cleanWord, string.concat(structName, ".", f[i].name)
                );

                bytes memory dirty = _copyBytes(sw.clean);
                _writeByte(dirty, _argOffset(memberOffset) + p, dirtyByte);
                require(
                    _readWord(dirty, _argOffset(memberOffset)) != cleanWord,
                    string.concat(structName, ".", f[i].name, ": mutation did not change the word")
                );

                (bool ok, bytes memory ret) = _rawCallPunt(sw.caller, sw.value, dirty);
                _assertFailedClosed(ok, ret, string.concat(structName, ".", f[i].name));
                _assertRevertedEmpty(ok, ret, string.concat(structName, ".", f[i].name));
                _assertStateUnchanged(before, sw.swapId, sw.collatToken, string.concat(structName, ".", f[i].name));

                vm.revertToState(snap);
                probed++;
            }
        }

        sweepCount += probed;
    }

    /// @dev Proves the clean payload actually reaches its intended transition, so a sweep can
    ///      never pass merely because the entry point was unreachable.
    function _assertCleanReaches(Sweep memory sw) internal {
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory ret) = _rawCallPunt(sw.caller, sw.value, sw.clean);
        if (!ok) {
            emit log_named_bytes("clean control reverted with", ret);
            if (ret.length >= 4) emit log_named_bytes32("selector", bytes32(bytes4(ret)));
        }
        require(ok, "clean control payload did not reach its transition");
        vm.revertToState(snap);
    }

    // ══════════════════════════════════════════════════════════════════
    //  MatchedSwap via liquidationHeartbeat() — 734 padding bytes
    // ══════════════════════════════════════════════════════════════════

    function test_matchedSwapPaddingSweep() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openHeartbeatPosition();

        Sweep memory sw = Sweep({
            clean: abi.encodeCall(punt.liquidationHeartbeat, (swapId, active)),
            structArgOffset: 32, // after uint256 swapId
            swapId: swapId,
            collatToken: active.collatToken,
            caller: outsider,
            value: 0
        });
        assertEq(sw.clean.length, 4 + 32 + 34 * 32, "liquidationHeartbeat calldata length");
        _assertCleanReaches(sw);

        uint256 n = _sweepStruct(sw, _matchedSwapFields(), "MatchedSwap");
        assertEq(n, 734, "every MatchedSwap padding byte probed");
    }

    // ══════════════════════════════════════════════════════════════════
    //  ProposedSwap + MatcherPreimage via matchSwap() — 692 + 317
    // ══════════════════════════════════════════════════════════════════

    function _matchSweep() internal returns (Sweep memory sw, uint256 swapId) {
        Proposal memory p = _propose();
        swapId = p.swapId;
        sw = Sweep({
            clean: abi.encodeCall(punt.matchSwap, (swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), matcher)),
            structArgOffset: 64, // after uint256 swapId, uint128 amount2
            swapId: swapId,
            collatToken: p.swap.collatToken,
            caller: matcher,
            value: 0
        });
        assertEq(sw.clean.length, 4 + 32 + 32 + 30 * 32 + 12 * 32 + 4 * 32 + 32, "matchSwap calldata length");
        _assertCleanReaches(sw);
    }

    function test_proposedSwapPaddingSweep() public {
        (Sweep memory sw,) = _matchSweep();
        uint256 n = _sweepStruct(sw, _proposedSwapFields(), "ProposedSwap");
        assertEq(n, 692, "every ProposedSwap padding byte probed");
    }

    function test_matcherPreimagePaddingSweep() public {
        (Sweep memory sw,) = _matchSweep();
        sw.structArgOffset = 64 + 30 * 32; // MatcherPreimage follows ProposedSwap
        uint256 n = _sweepStruct(sw, _matcherPreimageFields(), "MatcherPreimage");
        assertEq(n, 317, "every MatcherPreimage padding byte probed");
    }

    // ══════════════════════════════════════════════════════════════════
    //  ProposedSwap + MatcherPreimage via cancelSwapOpen() — 692 + 317
    // ══════════════════════════════════════════════════════════════════

    /// @dev This path deliberately has its own exhaustive matrix. `cancelSwapOpen()` keeps both
    ///      structs in calldata, whereas `matchSwap()` materializes a MatchedSwap in memory after
    ///      authenticating them. A clean control proves the calldata aliases remain usable all
    ///      the way through owner cancellation and its collateral/ETH payouts.
    function _cancelOpenSweepFrom(Proposal memory p) internal returns (Sweep memory sw) {
        sw = Sweep({
            clean: abi.encodeCall(punt.cancelSwapOpen, (p.swapId, p.swap, p.preimage)),
            structArgOffset: 32, // after uint256 swapId
            swapId: p.swapId,
            collatToken: p.swap.collatToken,
            caller: swapper,
            value: 0
        });
        assertEq(sw.clean.length, 4 + 32 + 30 * 32 + 12 * 32, "cancelSwapOpen calldata length");
        _assertCleanReaches(sw);
    }

    function _cancelOpenSweep() internal returns (Sweep memory sw) {
        return _cancelOpenSweepFrom(_propose());
    }

    function test_cancelSwapOpenProposedSwapPaddingSweep() public {
        Sweep memory sw = _cancelOpenSweep();
        uint256 n = _sweepStruct(sw, _proposedSwapFields(), "cancelSwapOpen.ProposedSwap");
        assertEq(n, 692, "every cancelSwapOpen ProposedSwap padding byte probed");
    }

    function test_cancelSwapOpenMatcherPreimagePaddingSweep() public {
        Sweep memory sw = _cancelOpenSweep();
        sw.structArgOffset = 32 + 30 * 32; // MatcherPreimage follows ProposedSwap
        uint256 n = _sweepStruct(sw, _matcherPreimageFields(), "cancelSwapOpen.MatcherPreimage");
        assertEq(n, 317, "every cancelSwapOpen MatcherPreimage padding byte probed");
    }

    /// @dev Produces a different canonical value without touching a field's padding. Since
    ///      cancelSwapOpen hashes the complete decoded structs before any payout logic, every
    ///      such change must reach and fail the commitment check with WrongHash—not the decoder.
    function _differentCanonicalWord(bytes32 cleanWord, Field memory field) internal pure returns (bytes32) {
        if (field.cls == C_BOOL) return cleanWord == bytes32(0) ? bytes32(uint256(1)) : bytes32(0);
        return cleanWord ^ bytes32(uint256(1));
    }

    function _sweepCancelCanonicalValues(Sweep memory sw, Field[] memory fields, string memory structName)
        internal
        returns (uint256 probed)
    {
        Book memory before = _book(sw.swapId, sw.collatToken);

        for (uint256 i = 0; i < fields.length; i++) {
            uint256 off = _argOffset(sw.structArgOffset + 32 * i);
            bytes32 cleanWord = _readWord(sw.clean, off);
            bytes memory altered = _copyBytes(sw.clean);
            _writeWord(altered, off, _differentCanonicalWord(cleanWord, fields[i]));

            (bool ok, bytes memory ret) = _rawCallPunt(sw.caller, sw.value, altered);
            _assertRevertedWith(
                ok,
                ret,
                PuntErrors.WrongHash.selector,
                string.concat(structName, ".", fields[i].name, " canonical mutation")
            );
            _assertStateUnchanged(before, sw.swapId, sw.collatToken, string.concat(structName, ".", fields[i].name));
            probed++;
        }
    }

    function test_cancelSwapOpenCanonicalValueChangesFailTheCommitment() public {
        Sweep memory sw = _cancelOpenSweep();
        uint256 proposed = _sweepCancelCanonicalValues(sw, _proposedSwapFields(), "ProposedSwap");

        sw.structArgOffset = 32 + 30 * 32;
        uint256 preimage = _sweepCancelCanonicalValues(sw, _matcherPreimageFields(), "MatcherPreimage");

        assertEq(proposed, 30, "every ProposedSwap field changed canonically");
        assertEq(preimage, 12, "every MatcherPreimage field changed canonically");
    }

    /// @dev The generic fixture's signed values are nonnegative. This separately proves that
    ///      cancelSwapOpen accepts genuine negative int32 values with 0xff sign extension and
    ///      rejects every single-byte break in that extension before reaching the hash check.
    function _sweepNegativeCancelPadding(Sweep memory sw, uint256 wordIndex, string memory name)
        internal
        returns (uint256 probed)
    {
        uint256 off = _argOffset(sw.structArgOffset + 32 * wordIndex);
        Book memory before = _book(sw.swapId, sw.collatToken);

        for (uint256 p = 0; p < 28; p++) {
            assertEq(_readByte(sw.clean, off + p), 0xff, string.concat(name, ": canonical negative padding"));

            bytes memory dirty = _copyBytes(sw.clean);
            _writeByte(dirty, off + p, 0x00);
            (bool ok, bytes memory ret) = _rawCallPunt(sw.caller, sw.value, dirty);
            _assertRevertedEmpty(ok, ret, string.concat(name, ": broken negative sign extension"));
            _assertStateUnchanged(before, sw.swapId, sw.collatToken, name);
            probed++;
        }
    }

    function test_cancelSwapOpenNegativeFundingRateSignExtension() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.fundingRate = -1;
        Proposal memory p = _proposeWith(s, _defaultMatcherPreimage(), swapper);
        Sweep memory sw = _cancelOpenSweepFrom(p);

        uint256 n = _sweepNegativeCancelPadding(sw, 10, "cancelSwapOpen.ProposedSwap.fundingRate");
        assertEq(n, 28, "every negative fundingRate padding byte probed through cancelSwapOpen");
    }

    function test_cancelSwapOpenNegativeAuctionBoundsSignExtension() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.auctionFunding = true;
        s.fulfillmentFee = 10_000;
        s.fundingRate = 0;

        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();
        m.auctionStart = -2;
        m.auctionEnd = -1;

        Proposal memory p = _proposeWith(s, m, swapper);
        Sweep memory sw = _cancelOpenSweepFrom(p);
        sw.structArgOffset = 32 + 30 * 32;

        uint256 starts = _sweepNegativeCancelPadding(sw, 6, "cancelSwapOpen.MatcherPreimage.auctionStart");
        uint256 ends = _sweepNegativeCancelPadding(sw, 7, "cancelSwapOpen.MatcherPreimage.auctionEnd");
        assertEq(starts, 28, "every negative auctionStart padding byte probed through cancelSwapOpen");
        assertEq(ends, 28, "every negative auctionEnd padding byte probed through cancelSwapOpen");
    }

    // ══════════════════════════════════════════════════════════════════
    //  MatchedSwap via cancelCloseAuction() — 734 padding bytes
    // ══════════════════════════════════════════════════════════════════

    function test_closeDutchPaddingSweep() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _startAuction(swapId, active, _dutchInput(), false, CLOSE_COMP);
        assertTrue(_storedDutchState(swapId) != bytes32(0), "fixture: genuine live auction");

        Sweep memory sw = Sweep({
            clean: abi.encodeCall(puntLifecycle.cancelCloseAuction, (swapId, active)),
            structArgOffset: 32,
            swapId: swapId,
            collatToken: active.collatToken,
            caller: swapper,
            value: 0
        });
        assertEq(sw.clean.length, 4 + 32 + 34 * 32, "cancelCloseAuction calldata length");
        _assertCleanReaches(sw);

        uint256 n = _sweepStruct(sw, _matchedSwapFields(), "MatchedSwap");
        assertEq(n, 734, "every MatchedSwap padding byte probed");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Booleans: 2 is neither true nor false
    // ══════════════════════════════════════════════════════════════════

    /// @dev Distinct from the padding sweep: a bool's padding is bytes 0..30, but the dangerous
    ///      value lives in byte 31. `iszero(iszero(x))` would map 2 to true; this proves the
    ///      decoder rejects it instead.
    function _assertBoolValueRejected(Sweep memory sw, uint256 wordIndex, uint256 raw, string memory name) internal {
        Book memory before = _book(sw.swapId, sw.collatToken);
        uint256 off = _argOffset(sw.structArgOffset + 32 * wordIndex);
        bytes32 cleanWord = _readWord(sw.clean, off);
        require(uint256(cleanWord) <= 1, string.concat(name, ": clean bool is canonical"));

        uint256 snap = vm.snapshotState();
        bytes memory dirty = _copyBytes(sw.clean);
        _writeWord(dirty, off, bytes32(raw));

        (bool ok, bytes memory ret) = _rawCallPunt(sw.caller, sw.value, dirty);
        _assertFailedClosed(ok, ret, name);
        _assertRevertedEmpty(ok, ret, name);
        _assertStateUnchanged(before, sw.swapId, sw.collatToken, name);
        vm.revertToState(snap);
    }

    /// @dev Canonical 0 and 1 are the controls: both must decode (they may still be rejected by
    ///      business logic, which is a different and acceptable outcome), proving the rejection
    ///      of 2 is about the value and not about the field being touched at all.
    function _assertBoolControlDecodes(Sweep memory sw, uint256 wordIndex, uint256 raw, string memory name) internal {
        uint256 snap = vm.snapshotState();
        bytes memory data = _copyBytes(sw.clean);
        _writeWord(data, _argOffset(sw.structArgOffset + 32 * wordIndex), bytes32(raw));
        (bool ok, bytes memory ret) = _rawCallPunt(sw.caller, sw.value, data);
        require(ok || ret.length > 0, string.concat(name, ": canonical bool must not fail ABI decoding"));
        vm.revertToState(snap);
    }

    function test_matchedSwapBooleansRejectTwo() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openHeartbeatPosition();
        Sweep memory sw = Sweep({
            clean: abi.encodeCall(punt.liquidationHeartbeat, (swapId, active)),
            structArgOffset: 32,
            swapId: swapId,
            collatToken: active.collatToken,
            caller: outsider,
            value: 0
        });
        _assertCleanReaches(sw);

        uint256[5] memory boolWords = [uint256(9), 10, 27, 29, 30];
        string[5] memory names =
            ["swapperIsLong", "pnlUsesToken1PerToken2", "active", "useInternalBalances", "maturityOnly"];
        for (uint256 i = 0; i < 5; i++) {
            _assertBoolControlDecodes(sw, boolWords[i], 0, string.concat("MatchedSwap.", names[i], " = 0"));
            _assertBoolControlDecodes(sw, boolWords[i], 1, string.concat("MatchedSwap.", names[i], " = 1"));
            _assertBoolValueRejected(sw, boolWords[i], 2, string.concat("MatchedSwap.", names[i], " = 2"));
            _assertBoolValueRejected(sw, boolWords[i], 255, string.concat("MatchedSwap.", names[i], " = 255"));
            _assertBoolValueRejected(
                sw, boolWords[i], type(uint256).max, string.concat("MatchedSwap.", names[i], " = max")
            );
        }
    }

    function test_proposedSwapBooleansRejectTwo() public {
        (Sweep memory sw,) = _matchSweep();
        uint256[5] memory boolWords = [uint256(8), 9, 12, 25, 26];
        string[5] memory names =
            ["isLong", "pnlUsesToken1PerToken2", "auctionFunding", "useInternalBalances", "maturityOnly"];
        for (uint256 i = 0; i < 5; i++) {
            _assertBoolValueRejected(sw, boolWords[i], 2, string.concat("ProposedSwap.", names[i], " = 2"));
        }
    }

    function test_cancelSwapOpenProposedSwapBooleansRejectNonCanonicalValues() public {
        Sweep memory sw = _cancelOpenSweep();
        uint256[5] memory boolWords = [uint256(8), 9, 12, 25, 26];
        string[5] memory names =
            ["isLong", "pnlUsesToken1PerToken2", "auctionFunding", "useInternalBalances", "maturityOnly"];
        uint256[3] memory invalid = [uint256(2), 255, type(uint256).max];

        for (uint256 i = 0; i < boolWords.length; i++) {
            for (uint256 j = 0; j < invalid.length; j++) {
                _assertBoolValueRejected(
                    sw,
                    boolWords[i],
                    invalid[j],
                    string.concat("cancelSwapOpen.ProposedSwap.", names[i], " invalid bool")
                );
            }
        }
    }

    function test_cancelCloseAuctionMatchedSwapBooleanRejectsTwo() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _startAuction(swapId, active, _dutchInput(), false, CLOSE_COMP);

        Sweep memory sw = Sweep({
            clean: abi.encodeCall(puntLifecycle.cancelCloseAuction, (swapId, active)),
            structArgOffset: 32,
            swapId: swapId,
            collatToken: active.collatToken,
            caller: swapper,
            value: 0
        });
        _assertCleanReaches(sw);
        _assertBoolValueRejected(sw, 29, 2, "MatchedSwap.useInternalBalances = 2");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Signed int32: sign extension in both directions
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice A negative int32 legitimately carries 0xff across all 28 padding bytes.
     *
     * @dev The generic sweep above chooses its probe from the observed clean byte, but that
     *      fixture's fundingRate is zero, so only the 0x00 -> 0xff direction was exercised there.
     *      This opens a position with a genuinely negative funding rate so the opposite direction
     *      — zeroing a byte of a real sign extension — is exercised too, and so that a correct
     *      negative value is proven to be accepted rather than rejected as if it were dirty.
     */
    function test_negativeSignedFieldSignExtensionBothDirections() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(-100_000);
        s.isLong = true;
        s.maturityWindow = MATURITY_LONG;
        s.liquidationHeartbeatMin = 30;
        s.liquidationHeartbeatMax = 300;
        m.disputeDelay = 5;
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openAccounting(s, m);
        assertLt(active.fundingRate, 0, "fixture: genuinely negative funding rate");

        Sweep memory sw = Sweep({
            clean: abi.encodeCall(punt.liquidationHeartbeat, (swapId, active)),
            structArgOffset: 32,
            swapId: swapId,
            collatToken: active.collatToken,
            caller: outsider,
            value: 0
        });

        // Canonical negative: all 28 padding bytes are 0xff and the call succeeds.
        uint256 off = _argOffset(sw.structArgOffset + 32 * 12); // MatchedSwap.fundingRate
        for (uint256 p = 0; p < 28; p++) {
            assertEq(_readByte(sw.clean, off + p), 0xff, "canonical negative padding is the sign extension");
        }
        _assertCleanReaches(sw);

        // Zeroing any byte of that sign extension is noncanonical and must fail closed.
        Book memory before = _book(swapId, active.collatToken);
        for (uint256 p = 0; p < 28; p++) {
            uint256 snap = vm.snapshotState();
            bytes memory dirty = _copyBytes(sw.clean);
            _writeByte(dirty, off + p, 0x00);
            (bool ok, bytes memory ret) = _rawCallPunt(outsider, 0, dirty);
            _assertFailedClosed(ok, ret, "negative fundingRate sign extension zeroed");
            _assertRevertedEmpty(ok, ret, "negative fundingRate sign extension zeroed");
            _assertStateUnchanged(before, swapId, active.collatToken, "negative fundingRate sign extension zeroed");
            vm.revertToState(snap);
        }

        // Making the value positive while leaving 0xff padding is still an invalid sign
        // extension, so it is a decoder rejection rather than a commitment one.
        uint256 snapA = vm.snapshotState();
        bytes memory positiveWithNegativePadding = _copyBytes(sw.clean);
        _writeByte(positiveWithNegativePadding, off + 28, 0x7f); // top byte of the 4-byte value region
        (bool okA, bytes memory retA) = _rawCallPunt(outsider, 0, positiveWithNegativePadding);
        _assertRevertedEmpty(okA, retA, "positive value carrying negative padding");
        _assertStateUnchanged(before, swapId, active.collatToken, "positive value carrying negative padding");
        vm.revertToState(snapA);

        // A different but still canonical negative value decodes cleanly, so the commitment must
        // reject it. This pair separates the two failure categories.
        uint256 snapB = vm.snapshotState();
        bytes memory otherNegative = _copyBytes(sw.clean);
        uint8 lowByte = _readByte(otherNegative, off + 31);
        _writeByte(otherNegative, off + 31, lowByte ^ 0x01); // still negative, padding untouched
        (bool okB, bytes memory retB) = _rawCallPunt(outsider, 0, otherNegative);
        assertFalse(okB, "a different legal fundingRate must not authenticate");
        assertEq(bytes4(retB), PuntErrors.WrongHash.selector, "rejected by the hash, not the decoder");
        _assertStateUnchanged(before, swapId, active.collatToken, "different canonical negative");
        vm.revertToState(snapB);
    }
}
