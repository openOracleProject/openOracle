// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DirtyEntryPointsBase.t.sol";
import {RecordingPermit2} from "./util/RecordingPermit2.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

/**
 * @notice Malformed dynamic encoding of `Permit2Params`, whose `bytes signature` member is the
 *         only dynamic data anywhere in OpenPunt's ABI surface.
 *
 * @dev These structural ABI tests run against the
 *      permissive `RecordingPermit2`, where any well-formed byte string is a valid signature.
 *      That keeps ABI rejection and cryptographic rejection from being conflated: a clean control
 *      with an arbitrary signature succeeds here, so every failure below is attributable to the
 *      encoding alone. Cryptographic rejection is covered by the real-Permit2 suite.
 *
 *      Permit2Params tail layout, relative to the start of the tuple:
 *          +0    nonce
 *          +32   deadline
 *          +64   offset to the signature (relative to the tuple start)
 *          +96   signature length
 *          +128  signature bytes, zero-padded to a whole word
 */
contract DirtyPermit2AbiTest is DirtyEntryPointsBase {
    bytes internal SIG = hex"1122334455667788990011223344556677889900112233445566778899001122334455";

    /// @dev Permit2's own error selector, declared here rather than imported.
    bytes4 internal constant INVALID_SIGNATURE_LENGTH = bytes4(keccak256("InvalidSignatureLength()"));

    function setUp() public {
        _setUpDirty();
    }

    function _params() internal view returns (OpenPuntStorage.Permit2Params memory) {
        return OpenPuntStorage.Permit2Params({nonce: 77, deadline: 1_999_999_999, signature: SIG});
    }

    // ══════════════════════════════════════════════════════════════════
    //  Layout self-check
    // ══════════════════════════════════════════════════════════════════

    function test_permit2TailLayoutIsWhereTheManifestSaysItIs() public view {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _proposalCfg();
        bytes memory clean = abi.encodeCall(punt.propose, (s, m, _params()));

        uint256 headOff = _argOffset(PROPOSE_PERMIT2_HEAD_OFF);
        uint256 tailStart = PROPOSE_PERMIT2_HEAD_OFF + 32; // 1280
        _assertCleanWord(clean, headOff, bytes32(tailStart), "Permit2Params head offset");
        _assertCleanWord(clean, _argOffset(tailStart), bytes32(uint256(77)), "nonce");
        _assertCleanWord(clean, _argOffset(tailStart + 32), bytes32(uint256(1_999_999_999)), "deadline");
        _assertCleanWord(clean, _argOffset(tailStart + 64), bytes32(uint256(96)), "signature offset");
        _assertCleanWord(clean, _argOffset(tailStart + 96), bytes32(SIG.length), "signature length");

        // 35 bytes of signature occupy two words, so 29 padding bytes follow
        assertEq(SIG.length, 35, "fixture signature length");
        assertEq(clean.length, 4 + tailStart + 128 + 64, "total propose calldata length");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Clean control
    // ══════════════════════════════════════════════════════════════════

    function _cleanPropose() internal view returns (bytes memory, uint256) {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _proposalCfg();
        return (abi.encodeCall(punt.propose, (s, m, _params())), _correctMsgValue(s));
    }

    function test_cleanArbitrarySignatureReachesPermit2Verbatim() public {
        (bytes memory clean, uint256 value) = _cleanPropose();
        uint256 calls0 = _permit2().callCount();

        (bool ok,) = _rawCallPunt(swapper, value, clean);
        assertTrue(ok, "clean control succeeds against the permissive recorder");
        assertEq(_permit2().callCount(), calls0 + 1, "Permit2 was reached exactly once");

        RecordingPermit2.Call memory c = _permit2().lastCall();
        assertEq(keccak256(c.signature), keccak256(SIG), "the recorder observed EXACTLY the declared bytes");
        assertEq(c.signature.length, SIG.length, "and exactly the declared length");
        assertEq(c.nonce, 77, "nonce forwarded");
        assertEq(c.deadline, 1_999_999_999, "deadline forwarded");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Malformed offsets and lengths
    // ══════════════════════════════════════════════════════════════════

    /// @dev Every case here must fail without reaching Permit2 or moving protocol state.
    function _rejectAbi(bytes memory dirty, uint256 value, string memory what) internal {
        uint256 calls0 = _permit2().callCount();
        Book memory before = _book(0, address(collat));

        (bool ok, bytes memory ret) = _rawCallPunt(swapper, value, dirty);
        _assertFailedClosed(ok, ret, what);
        _assertRevertedEmpty(ok, ret, what);
        assertEq(_permit2().callCount(), calls0, string.concat(what, ": Permit2 was REACHED"));
        _assertStateUnchanged(before, 0, address(collat), what);
    }

    function test_headOffsetOutOfBounds() public {
        (bytes memory clean, uint256 value) = _cleanPropose();
        uint256 headOff = _argOffset(PROPOSE_PERMIT2_HEAD_OFF);
        _rejectAbi(_withWord(clean, headOff, bytes32(type(uint256).max)), value, "head offset = max");
        _rejectAbi(_withWord(clean, headOff, bytes32(uint256(1 << 200))), value, "head offset huge");
        _rejectAbi(_withWord(clean, headOff, bytes32(clean.length)), value, "head offset past the end");
    }

    /// @dev Pointing the head back into the static region is a legal-looking offset that would
    ///      reinterpret proposal bytes as the Permit2 tuple.
    function test_headOffsetIntoTheStaticHead() public {
        (bytes memory clean, uint256 value) = _cleanPropose();
        uint256 headOff = _argOffset(PROPOSE_PERMIT2_HEAD_OFF);
        _rejectAbi(_withWord(clean, headOff, bytes32(uint256(0))), value, "head offset -> ProposedSwap word 0");
        _rejectAbi(_withWord(clean, headOff, bytes32(PROPOSE_PREIMAGE_OFF)), value, "head offset -> MatcherPreimage");
    }

    /**
     * @notice Solidity accepts an in-bounds re-pointed signature offset.
     *
     * @dev Offset 0 makes the length word land on `nonce` (77), and 77 bytes are genuinely
     *      available from there, so the decode is in-bounds and lawful. The result is simply a
     *      different byte string presented as the signature.
     *
     *      The re-pointed bytes cannot reach any commitment. The proposal intent is
     *      built from the typed structs alone, so the stored swap hash and issued swapId are
     *      byte-identical to the clean run; only the forwarded signature blob differs, and under
     *      authentic Permit2 a wrong blob is what signature verification exists to reject.
     */
    function test_nestedSignatureOffsetIntoTheStaticHeadIsAnInBoundsRepoint() public {
        (bytes memory clean, uint256 value) = _cleanPropose();
        uint256 sigOffWord = _argOffset(PROPOSE_PERMIT2_HEAD_OFF + 32 + 64);
        _assertCleanWord(clean, sigOffWord, bytes32(uint256(96)), "signature offset");

        // clean run, for comparison
        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(swapper, value, clean);
        assertTrue(okClean, "clean control");
        uint256 cleanSwapId = punt.nextSwapId() - 1;
        bytes32 cleanHash = punt.swaps(cleanSwapId);
        vm.revertToState(snap);

        // offset 0 -> the length word is read at `nonce` == 77
        bytes memory repointed = _withWord(clean, sigOffWord, bytes32(uint256(0)));
        uint256 calls0 = _permit2().callCount();
        (bool ok,) = _rawCallPunt(swapper, value, repointed);

        assertTrue(ok, "ACCEPTED: an in-bounds re-point is lawful ABI");
        assertEq(_permit2().callCount(), calls0 + 1, "Permit2 reached once");

        RecordingPermit2.Call memory c = _permit2().lastCall();
        assertEq(c.signature.length, 77, "the reinterpreted length is the nonce value");
        assertTrue(keccak256(c.signature) != keccak256(SIG), "and the bytes genuinely differ from the real signature");

        // The commitment is unchanged.
        uint256 dirtySwapId = punt.nextSwapId() - 1;
        assertEq(dirtySwapId, cleanSwapId, "same swapId issued");
        assertEq(punt.swaps(dirtySwapId), cleanHash, "byte-identical stored proposal hash");
    }

    function test_nestedSignatureOffsetBeyondCalldata() public {
        (bytes memory clean, uint256 value) = _cleanPropose();
        uint256 sigOffWord = _argOffset(PROPOSE_PERMIT2_HEAD_OFF + 32 + 64);
        _rejectAbi(_withWord(clean, sigOffWord, bytes32(uint256(1 << 128))), value, "signature offset huge");
        _rejectAbi(_withWord(clean, sigOffWord, bytes32(clean.length)), value, "signature offset past the end");
    }

    /// @dev With this ABI shape, the same signed-offset decoder edge exercised below for close()
    ///      also forwards an empty signature from propose(). The permissive recorder accepts it;
    ///      the authentic Permit2 test proves the cryptographic boundary rejects it.
    function test_proposeMaximumSignatureOffsetYieldsAnEmptySignature() public {
        (bytes memory clean, uint256 value) = _cleanPropose();
        uint256 sigOffWord = _argOffset(PROPOSE_PERMIT2_HEAD_OFF + 32 + 64);

        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(swapper, value, clean);
        assertTrue(okClean, "clean control");
        uint256 cleanSwapId = punt.nextSwapId() - 1;
        bytes32 cleanHash = punt.swaps(cleanSwapId);
        bytes32 cleanWitness = _permit2().lastCall().witness;
        vm.revertToState(snap);

        uint256 calls0 = _permit2().callCount();
        bytes memory dirty = _withWord(clean, sigOffWord, bytes32(type(uint256).max));
        (bool ok,) = _rawCallPunt(swapper, value, dirty);

        assertTrue(ok, "signed offset is forwarded as an empty signature");
        assertEq(_permit2().callCount(), calls0 + 1, "Permit2 reached once");
        assertEq(_permit2().lastCall().signature.length, 0, "empty signature forwarded");
        assertEq(punt.nextSwapId() - 1, cleanSwapId, "same swapId issued");
        assertEq(punt.swaps(cleanSwapId), cleanHash, "proposal commitment is byte-identical");
        assertEq(_permit2().lastCall().witness, cleanWitness, "Permit2 witness is byte-identical");
    }

    function test_authenticPermit2RejectsTheEmptyProposeSignature() public {
        (bytes memory clean, uint256 value) = _cleanPropose();
        uint256 sigOffWord = _argOffset(PROPOSE_PERMIT2_HEAD_OFF + 32 + 64);
        bytes memory dirty = _withWord(clean, sigOffWord, bytes32(type(uint256).max));

        new DeployPermit2().deployPermit2();
        assertGt(PERMIT2.code.length, 0, "authentic Permit2 installed");

        Book memory before = _book(0, address(collat));
        (bool ok, bytes memory ret) = _rawCallPunt(swapper, value, dirty);
        assertFalse(ok, "authentic Permit2 refuses the empty signature");
        assertEq(bytes4(ret), INVALID_SIGNATURE_LENGTH, "InvalidSignatureLength()");
        _assertStateUnchanged(before, 0, address(collat), "authentic/empty propose signature");
    }

    function test_signatureLengthBeyondAvailableCalldata() public {
        (bytes memory clean, uint256 value) = _cleanPropose();
        uint256 lenWord = _argOffset(PROPOSE_PERMIT2_HEAD_OFF + 32 + 96);
        _assertCleanWord(clean, lenWord, bytes32(SIG.length), "signature length");

        _rejectAbi(_withWord(clean, lenWord, bytes32(uint256(10_000))), value, "length far beyond calldata");
        _rejectAbi(_withWord(clean, lenWord, bytes32(type(uint256).max)), value, "length = max");
        _rejectAbi(_withWord(clean, lenWord, bytes32(uint256(1 << 64))), value, "length overflow-ish");
    }

    /// @dev Truncating inside the declared signature data, or removing a header word, is rejected.
    function test_truncationIntoTheDeclaredSignatureDataIsRejected() public {
        (bytes memory clean, uint256 value) = _cleanPropose();
        // 35 declared bytes occupy 64 bytes of data region, so 29 trailing bytes are padding.
        // Cutting 30 removes a declared byte.
        _rejectAbi(_truncate(clean, clean.length - 30), value, "one declared signature byte removed");
        _rejectAbi(_truncate(clean, clean.length - 64), value, "a full data word removed");
        _rejectAbi(_truncate(clean, _argOffset(PROPOSE_PERMIT2_HEAD_OFF + 32 + 96)), value, "length word removed");
    }

    /**
     * @notice Truncating inside the signature's trailing padding is accepted.
     *
     * @dev Solidity requires only that the declared length fits within calldata; it does not
     *      require the tail to be padded out to a whole word. Removing padding bytes is therefore
     *      lawful, and the requirement is that it changes nothing observable — which is what this
     *      asserts against a clean baseline.
     */
    function test_truncationWithinTheSignaturePaddingIsAcceptedAndInert() public {
        (bytes memory clean, uint256 value) = _cleanPropose();

        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(swapper, value, clean);
        assertTrue(okClean, "clean control");
        uint256 cleanSwapId = punt.nextSwapId() - 1;
        bytes32 cleanHash = punt.swaps(cleanSwapId);
        vm.revertToState(snap);

        bytes memory shortened = _truncate(clean, clean.length - 29); // exactly the padding
        (bool ok,) = _rawCallPunt(swapper, value, shortened);
        assertTrue(ok, "ACCEPTED: the declared bytes are all still present");

        RecordingPermit2.Call memory c = _permit2().lastCall();
        assertEq(keccak256(c.signature), keccak256(SIG), "the recorder still saw exactly the declared bytes");
        assertEq(punt.nextSwapId() - 1, cleanSwapId, "same swapId");
        assertEq(punt.swaps(punt.nextSwapId() - 1), cleanHash, "byte-identical stored hash");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Padding after the declared length: accepted and ignored
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Solidity does not require the tail padding of a `bytes` value to be zero.
     *
     * @dev This is lawful noncanonical encoding, so the requirement is not rejection — it is that
     *      the ignored bytes cannot leak anywhere. Proven three ways: the recorder observes
     *      exactly the declared 35 bytes, the swap hash is byte-identical to the clean run, and
     *      the resulting swapId is the same.
     */
    function test_nonzeroPaddingAfterTheDeclaredSignatureLengthIsIgnored() public {
        (bytes memory clean, uint256 value) = _cleanPropose();

        // clean run, for comparison
        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(swapper, value, clean);
        assertTrue(okClean, "clean control");
        uint256 cleanSwapId = punt.nextSwapId() - 1;
        bytes32 cleanHash = punt.swaps(cleanSwapId);
        bytes memory cleanObserved = _permit2().lastCall().signature;
        vm.revertToState(snap);

        // 35 declared bytes occupy 64 bytes of data region, so bytes 35..63 are padding
        uint256 dataStart = _argOffset(PROPOSE_PERMIT2_HEAD_OFF + 32 + 128);
        bytes memory dirty = _copyBytes(clean);
        for (uint256 i = SIG.length; i < 64; i++) {
            _writeByte(dirty, dataStart + i, 0xAB);
        }
        assertTrue(keccak256(dirty) != keccak256(clean), "the payload genuinely differs");

        uint256 calls0 = _permit2().callCount();
        (bool ok,) = _rawCallPunt(swapper, value, dirty);
        assertTrue(ok, "ACCEPTED: trailing padding inside a bytes tail is lawful");

        assertEq(_permit2().callCount(), calls0 + 1, "Permit2 reached once");
        RecordingPermit2.Call memory c = _permit2().lastCall();
        assertEq(c.signature.length, SIG.length, "the declared length still bounds what is read");
        assertEq(keccak256(c.signature), keccak256(SIG), "and the recorder saw EXACTLY the declared bytes");
        assertEq(keccak256(c.signature), keccak256(cleanObserved), "identical to the clean run");

        uint256 dirtySwapId = punt.nextSwapId() - 1;
        assertEq(dirtySwapId, cleanSwapId, "same swapId issued");
        assertEq(punt.swaps(dirtySwapId), cleanHash, "and a byte-identical stored proposal hash");
    }

    /// @dev The intent hash is built from the typed structs only, so no padding or trailing byte
    ///      can enter it. Same proof shape on the close side.
    function test_closeIntentIsUnaffectedByPermit2TailPadding() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory input = _dutchInput();

        bytes memory clean = abi.encodeCall(
            punt.close,
            (swapId, input, active, false, _params(), CLOSE_COMP, _emptyOracleGame(), _emptyOracleHelper(), 0)
        );
        uint256 tailStart = CLOSE_PERMIT2_TAIL_OFF;
        _assertCleanWord(clean, _argOffset(CLOSE_PERMIT2_HEAD_OFF), bytes32(tailStart), "close Permit2 head offset");

        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(swapper, CLOSE_COMP, clean);
        assertTrue(okClean, "clean close control");
        bytes32 cleanDutch = _storedDutchState(swapId);
        bytes32 cleanWitness = _permit2().lastCall().witness;
        vm.revertToState(snap);

        uint256 dataStart = _argOffset(tailStart + 128);
        bytes memory dirty = _copyBytes(clean);
        for (uint256 i = SIG.length; i < 64; i++) {
            _writeByte(dirty, dataStart + i, 0xCD);
        }

        (bool ok,) = _rawCallPunt(swapper, CLOSE_COMP, dirty);
        assertTrue(ok, "tail padding accepted on close too");
        assertEq(_storedDutchState(swapId), cleanDutch, "stored Dutch hash is byte-identical");
        assertEq(_permit2().lastCall().witness, cleanWitness, "and the intent witness is unchanged");
        assertEq(keccak256(_permit2().lastCall().signature), keccak256(SIG), "declared bytes only");
    }

    /**
     * @notice A huge nested offset is accepted as an empty signature and forwarded to Permit2.
     *
     * @dev Solidity's calldata-tail accessor bounds-checks the relative offset with a signed
     *      comparison, so an offset of
     *      `type(uint256).max` reads as -1 and passes. The pointer lands outside the intended
     *      tail, a length of zero is read, and `permit2.signature` decodes to an empty
     *      `bytes` — no revert.
     *
     *      Against the permissive recorder this therefore succeeds, and an auction is created.
     *      That is a property of the recorder, not of the protocol: the recorder validates
     *      nothing. The companion test below installs authentic Permit2 and shows the same
     *      payload reverting, which is where the real guarantee lives.
     *
     *      What matters for OpenPunt is that the malformed offset cannot corrupt anything it
     *      commits to: the stored Dutch hash is byte-identical to the clean run, because the
     *      close intent is built from the typed structs alone and never from the signature bytes.
     */
    function test_hugeSignatureOffsetYieldsAnEmptySignatureRatherThanReverting() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        bytes memory clean = abi.encodeCall(
            punt.close,
            (swapId, _dutchInput(), active, false, _params(), CLOSE_COMP, _emptyOracleGame(), _emptyOracleHelper(), 0)
        );
        uint256 tailStart = CLOSE_PERMIT2_TAIL_OFF;
        _assertCleanWord(clean, _argOffset(tailStart + 64), bytes32(uint256(96)), "close signature offset");

        // clean baseline
        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(swapper, CLOSE_COMP, clean);
        assertTrue(okClean, "clean close control");
        bytes32 cleanDutch = _storedDutchState(swapId);
        bytes32 cleanWitness = _permit2().lastCall().witness;
        vm.revertToState(snap);

        uint256 calls0 = _permit2().callCount();
        bytes memory dirty = _withWord(clean, _argOffset(tailStart + 64), bytes32(type(uint256).max));
        (bool ok,) = _rawCallPunt(swapper, CLOSE_COMP, dirty);

        assertTrue(ok, "the signed bounds check lets this through instead of reverting");
        assertEq(_permit2().callCount(), calls0 + 1, "and Permit2 IS reached");
        assertEq(_permit2().lastCall().signature.length, 0, "with an EMPTY signature");

        // the commitment is untouched
        assertEq(_storedDutchState(swapId), cleanDutch, "stored Dutch hash byte-identical to the clean run");
        assertEq(_permit2().lastCall().witness, cleanWitness, "and the close intent witness is unchanged");
    }

    /**
     * @notice The same payload against authentic Permit2 is rejected with no state movement.
     *
     * @dev This is the half of the guarantee the recorder cannot provide, and it is why the two
     *      layers must not be conflated. The ABI layer forwards an empty signature; the
     *      cryptographic layer refuses it with Permit2's own `InvalidSignatureLength()`.
     *
     *      Installed with the same official `DeployPermit2` helper and commit
     *      (cc56ad0f3439c502c246fc5cfcc3db92bb8b7219) used by the real-Permit2 suite.
     */
    function test_authenticPermit2RejectsTheEmptySignatureThatTheAbiLayerLetsThrough() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        bytes memory clean = abi.encodeCall(
            punt.close,
            (swapId, _dutchInput(), active, false, _params(), CLOSE_COMP, _emptyOracleGame(), _emptyOracleHelper(), 0)
        );
        uint256 tailStart = CLOSE_PERMIT2_TAIL_OFF;

        // Swap the permissive recorder for the authentic runtime after fixture setup.
        new DeployPermit2().deployPermit2();
        assertGt(PERMIT2.code.length, 0, "authentic Permit2 installed");

        Book memory before = _book(swapId, active.collatToken);
        bytes memory dirty = _withWord(clean, _argOffset(tailStart + 64), bytes32(type(uint256).max));

        (bool ok, bytes memory ret) = _rawCallPunt(swapper, CLOSE_COMP, dirty);
        assertFalse(ok, "authentic Permit2 refuses the empty signature");
        assertEq(bytes4(ret), INVALID_SIGNATURE_LENGTH, "InvalidSignatureLength()");
        _assertStateUnchanged(before, swapId, active.collatToken, "authentic/empty signature");
        assertEq(_storedDutchState(swapId), bytes32(0), "no auction stored");
    }
}
