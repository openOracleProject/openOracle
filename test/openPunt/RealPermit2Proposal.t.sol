// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./RealPermit2Base.t.sol";

/**
 * @notice Proposal funding against authentic Permit2.
 *
 * @dev Uses real secp256k1 verification, nonce consumption, replay rejection, and deadline
 *      enforcement. Every digest is rebuilt from the five EIP-712 layers, never read out of
 *      production code.
 */
contract RealPermit2ProposalTest is RealPermit2Base {
    uint256 internal constant NONCE = 7;

    function setUp() public {
        _setUpRealPermit2();
    }

    // ── driver ──────────────────────────────────────────────────────────

    struct Signed {
        OpenPuntStorage.ProposedSwap s;
        OpenPuntStorage.MatcherPreimage m;
        uint256 nonce;
        uint256 deadline;
        bytes32 intent;
        bytes32 digest;
        bytes sig;
    }

    function _prepare(uint256 nonce, uint256 deadline) internal returns (Signed memory z) {
        z.s = _defaultProposedSwap();
        z.m = _defaultMatcherPreimage();
        // s.swapper stays zero: propose() requires it and overrides it with msg.sender
        z.nonce = nonce;
        z.deadline = deadline;
        z.intent = _proposalIntent(z.s, z.m, wallet.addr);
        z.digest = _permit2Digest(address(collat), z.s.initialMarginSwapper, nonce, deadline, wallet.addr, z.intent);
        z.sig = _sign65(wallet, z.digest);
    }

    function _value(OpenPuntStorage.ProposedSwap memory s) internal pure returns (uint256) {
        return uint256(s.matcherGasComp) + s.settlerReward + s.openExecutionComp;
    }

    function _submit(Signed memory z) internal returns (uint256 swapId) {
        vm.prank(wallet.addr);
        swapId = punt.propose{value: _value(z.s)}(z.s, z.m, _permitParams(z.nonce, z.deadline, z.sig));
    }

    // ══════════════════════════════════════════════════════════════════
    //  1. Happy path
    // ══════════════════════════════════════════════════════════════════

    function test_realSignatureFundsAProposal() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);

        uint256 margin = z.s.initialMarginSwapper;
        uint256 ownerBefore = collat.balanceOf(wallet.addr);
        uint256 oracleBefore = collat.balanceOf(address(oracle));
        uint256 coreBefore = _spendable(address(punt), address(collat));
        (uint256 wordPos, uint256 bitMask) = _noncePosition(NONCE);
        assertFalse(_nonceUsed(wallet.addr, NONCE), "nonce unused beforehand");

        vm.recordLogs();
        uint256 swapId = _submit(z);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // the proposal genuinely exists, and the emitted structs reconstruct the stored hash
        (OpenPuntStorage.ProposedSwap memory eSwap, OpenPuntStorage.MatcherPreimage memory ePreimage) =
            _decodeSwapProposed(logs, swapId);
        assertTrue(punt.swaps(swapId) != bytes32(0), "swap stored");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(eSwap, ePreimage)), "emitted structs rebuild the hash");
        assertEq(eSwap.swapper, wallet.addr, "the signer is recorded as the swapper");
        assertEq(eSwap.collatToken, address(collat), "collateral token");
        assertEq(eSwap.initialMarginSwapper, z.s.initialMarginSwapper, "margin");
        assertEq(ePreimage.startFulfillFeeIncrease, uint48(vm.getBlockTimestamp()), "fee auction stamped to now");

        // tokens really moved, pulled by Permit2 from the signer into the oracle custodian
        assertEq(collat.balanceOf(wallet.addr), ownerBefore - margin, "signer debited");
        assertEq(collat.balanceOf(address(oracle)) - oracleBefore, margin, "oracle custodies the margin");
        assertEq(_spendable(address(punt), address(collat)) - coreBefore, margin, "core credited internally");

        // the nonce was consumed, at the independently derived word and bit
        assertEq(wordPos, 0, "nonce 7 lives in word 0");
        assertEq(bitMask, 1 << 7, "and at bit 7");
        assertEq(_nonceBitmap(wallet.addr, 0), bitMask, "exactly that one bit is set");
        assertTrue(_nonceUsed(wallet.addr, NONCE), "nonce consumed");
        assertEq(_nonceBitmap(otherWallet.addr, 0), 0, "another signer's bitmap untouched");
    }

    /// @dev The spender bound into the signature is the oracle. Signing with the core as spender
    ///      produces a signature that Permit2 rejects.
    function test_signingWithTheCoreAsSpenderIsRejected() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);

        bytes32 witness = _witnessHash(address(punt), address(punt), wallet.addr, z.intent);
        bytes32 wrongDigest = _digest(
            _permitWitnessStructHash(
                address(collat), z.s.initialMarginSwapper, address(punt), z.nonce, z.deadline, witness
            )
        );
        assertTrue(wrongDigest != z.digest, "the two digests genuinely differ");
        z.sig = _sign65(wallet, wrongDigest);

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(InvalidSigner.selector);
        _submit(z);
        _assertFullyRolledBack(before, wallet.addr, address(collat), z.nonce, "core-as-spender");
    }

    function test_signatureFromAnotherKeyIsRejected() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);
        z.sig = _sign65(otherWallet, z.digest); // right digest, wrong key

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(InvalidSigner.selector);
        _submit(z);
        _assertFullyRolledBack(before, wallet.addr, address(collat), z.nonce, "wrong key");
    }

    function test_malformedSignatureLengthIsRejected() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);
        z.sig = hex"c0ffee"; // neither 64 nor 65 bytes

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(InvalidSignatureLength.selector);
        _submit(z);
        _assertFullyRolledBack(before, wallet.addr, address(collat), z.nonce, "bad length");
    }

    // ══════════════════════════════════════════════════════════════════
    //  2. Nonce consumption and replay
    // ══════════════════════════════════════════════════════════════════

    function test_replayingTheSameSignatureRevertsInvalidNonce() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);
        uint256 firstId = _submit(z);

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        assertTrue(_nonceUsed(wallet.addr, NONCE), "nonce is spent going in");

        vm.expectRevert(InvalidNonce.selector);
        _submit(z);

        // no second position, and the already-spent bit is neither cleared nor duplicated
        assertEq(punt.nextSwapId(), before.nextSwapId, "no second swap id issued");
        assertEq(_nonceBitmap(wallet.addr, 0), before.nonceWord, "bitmap unchanged by the failed replay");
        assertEq(collat.balanceOf(wallet.addr), before.ownerExternal, "no second pull");
        assertEq(collat.balanceOf(address(oracle)), before.oracleCustody, "oracle custody unchanged");
        assertTrue(punt.swaps(firstId) != bytes32(0), "the original proposal still stands");
    }

    /// @dev A fresh, correctly signed proposal on a different nonce still works after the replay
    ///      failure — the rejection is nonce-scoped, not signer-scoped.
    function test_aFreshNonceStillWorksAfterAReplayFailure() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);
        _submit(z);
        vm.expectRevert(InvalidNonce.selector);
        _submit(z);

        Signed memory z2 = _prepare(NONCE + 1, vm.getBlockTimestamp() + 1 days);
        uint256 id2 = _submit(z2);

        assertTrue(punt.swaps(id2) != bytes32(0), "second proposal created");
        assertEq(_nonceBitmap(wallet.addr, 0), (1 << 7) | (1 << 8), "both bits set in word 0");
    }

    // ══════════════════════════════════════════════════════════════════
    //  2b. Failed token pull rolls back the whole proposal
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice A failed Permit2 pull unwinds every pre-funding state change, not just the nonce.
     *
     * @dev The close path proves the nonce-rollback property, but `propose()` mutates more state
     *      before it funds — most importantly `nextSwapId++` and the prospective `swaps` slot —
     *      so it needs its own proof.
     *
     *      The failure is real and caller-caused: the signer undersizes its own Permit2 allowance
     *      to one wei below the margin, through a normal `approve` call. (The close-side test
     *      revokes to zero instead, so the two exercise different allowance shapes.) Permit2
     *      marks the nonce spent before it pulls, so only the transaction reverting restores it.
     */
    function test_aFailedProposalPullLeavesEverythingSpendable() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);
        uint256 margin = z.s.initialMarginSwapper;

        vm.prank(wallet.addr);
        collat.approve(PERMIT2, margin - 1); // one wei short of what the signed permit requests

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);

        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        _submit(z);

        // nonce, nextSwapId, the prospective swap slot, owner balance, oracle custody,
        // core internal collateral and core ETH
        _assertFullyRolledBack(before, wallet.addr, address(collat), z.nonce, "undersized allowance");

        // and the delegatecall module holds nothing in either ledger
        assertEq(address(lifecycleModule).balance, 0, "module raw ETH");
        assertEq(collat.balanceOf(address(lifecycleModule)), 0, "module raw collateral");
        assertEq(_spendable(address(lifecycleModule), address(0)), 0, "module internal ETH");
        assertEq(_spendable(address(lifecycleModule), address(collat)), 0, "module internal collateral");

        // Restore the allowance; the same proposal, signature, deadline and nonce now succeed.
        vm.prank(wallet.addr);
        collat.approve(PERMIT2, type(uint256).max);

        uint256 swapId = _submit(z);

        assertEq(swapId, before.nextSwapId, "the reserved swap id was genuinely never consumed");
        assertTrue(punt.swaps(swapId) != bytes32(0), "proposal created on the retry");
        assertEq(punt.nextSwapId(), before.nextSwapId + 1, "and only now does nextSwapId advance");
        assertEq(collat.balanceOf(wallet.addr), before.ownerExternal - margin, "signer debited once");
        assertEq(collat.balanceOf(address(oracle)) - before.oracleCustody, margin, "oracle custodies the margin");
        assertEq(_spendable(address(punt), address(collat)) - before.coreInternal, margin, "core credited once");
        assertTrue(_nonceUsed(wallet.addr, NONCE), "and only now is the nonce spent");
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. Witness binding
    // ══════════════════════════════════════════════════════════════════

    /// @dev Sign one proposal, submit a materially different one. The witness OpenOracle
    ///      transmits no longer matches the signed struct, so recovery lands on a stranger.
    function test_witnessBindsTheProposalContents() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);

        // The signature covers the original notional; submit with a larger one.
        z.s.notional = z.s.notional + 1;
        assertTrue(
            _proposalIntent(z.s, z.m, wallet.addr) != z.intent, "the mutated proposal really is a different intent"
        );

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(InvalidSigner.selector);
        _submit(z);
        _assertFullyRolledBack(before, wallet.addr, address(collat), z.nonce, "mutated notional");
    }

    function test_witnessBindsThePnlOrientation() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);

        z.s.pnlUsesToken1PerToken2 = !z.s.pnlUsesToken1PerToken2;
        assertTrue(_proposalIntent(z.s, z.m, wallet.addr) != z.intent, "PnL orientation alters the intent");

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(InvalidSigner.selector);
        _submit(z);
        _assertFullyRolledBack(before, wallet.addr, address(collat), z.nonce, "mutated PnL orientation");
    }

    function test_witnessBindsTheMatcherPreimage() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);

        z.m.disputeDelay = z.m.disputeDelay + 1;
        assertTrue(_proposalIntent(z.s, z.m, wallet.addr) != z.intent, "preimage change alters the intent");

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(InvalidSigner.selector);
        _submit(z);
        _assertFullyRolledBack(before, wallet.addr, address(collat), z.nonce, "mutated preimage");
    }

    /// @dev The permitted amount is part of the signed TokenPermissions, so raising the margin
    ///      after signing is rejected too — separately from the witness.
    function test_permittedAmountIsBound() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);
        z.s.initialMarginSwapper = z.s.initialMarginSwapper + 1;

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(InvalidSigner.selector);
        _submit(z);
        _assertFullyRolledBack(before, wallet.addr, address(collat), z.nonce, "raised margin");
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. Deadline boundary
    // ══════════════════════════════════════════════════════════════════

    /// @dev Permit2 checks `block.timestamp > deadline`, so equality is still valid.
    function test_deadlineEqualToNowIsAccepted() public {
        uint256 now_ = vm.getBlockTimestamp();
        Signed memory z = _prepare(NONCE, now_);

        uint256 swapId = _submit(z);

        assertEq(vm.getBlockTimestamp(), z.deadline, "submitted exactly at the deadline");
        assertTrue(punt.swaps(swapId) != bytes32(0), "accepted on the boundary");
        assertTrue(_nonceUsed(wallet.addr, NONCE), "nonce consumed");
    }

    function test_deadlineOneSecondInThePastRevertsSignatureExpired() public {
        uint256 now_ = vm.getBlockTimestamp();
        Signed memory z = _prepare(NONCE, now_ - 1);

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(abi.encodeWithSelector(SignatureExpired.selector, now_ - 1));
        _submit(z);
        _assertFullyRolledBack(before, wallet.addr, address(collat), z.nonce, "expired");
    }

    /// @dev The same signature that is valid now expires with the passage of time alone.
    function test_aValidSignatureExpiresWhenTimePasses() public {
        uint256 deadline = vm.getBlockTimestamp() + 100;
        Signed memory z = _prepare(NONCE, deadline);

        _advanceChain(102); // block cadence is 0.5 blocks/s, so hops must be even
        assertEq(vm.getBlockTimestamp(), deadline + 2, "past the deadline");

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(abi.encodeWithSelector(SignatureExpired.selector, deadline));
        _submit(z);
        _assertFullyRolledBack(before, wallet.addr, address(collat), z.nonce, "aged out");
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. Bitmap word boundary
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Nonces 255 and 256 sit in different words.
     *
     * @dev Derived independently: wordPos = nonce >> 8, bitPos = nonce & 0xff.
     *      255 = 0b11111111 -> word 0, bit 255 (the top bit of word 0).
     *      256 = 0b100000000 -> word 1, bit 0 (the bottom bit of word 1).
     */
    function test_noncesAcrossAWordBoundaryAreIndependent() public {
        Signed memory a = _prepare(255, vm.getBlockTimestamp() + 1 days);
        Signed memory b = _prepare(256, vm.getBlockTimestamp() + 1 days);

        uint256 idA = _submit(a);
        assertEq(_nonceBitmap(wallet.addr, 0), 1 << 255, "word 0 has only its top bit set");
        assertEq(_nonceBitmap(wallet.addr, 1), 0, "word 1 still empty");

        uint256 idB = _submit(b);
        assertEq(_nonceBitmap(wallet.addr, 0), 1 << 255, "word 0 unchanged by the word-1 spend");
        assertEq(_nonceBitmap(wallet.addr, 1), 1, "word 1 has only its bottom bit set");

        assertTrue(idA != idB, "two distinct proposals");
        assertTrue(punt.swaps(idA) != bytes32(0) && punt.swaps(idB) != bytes32(0), "both stored");
    }

    function test_replayAtTheTopOfAWordIsRejectedWithoutDisturbingTheWord() public {
        Signed memory a = _prepare(255, vm.getBlockTimestamp() + 1 days);
        _submit(a);

        (uint256 wordPos, uint256 bitMask) = _noncePosition(255);
        assertEq(wordPos, 0, "derived word");
        assertEq(bitMask, 1 << 255, "derived bit");

        vm.expectRevert(InvalidNonce.selector);
        _submit(a);
        assertEq(_nonceBitmap(wallet.addr, 0), bitMask, "the top bit is neither cleared nor joined by others");
    }

    /// @dev Two signers can spend the same nonce because the bitmap is keyed by owner.
    function test_theBitmapIsPerSigner() public {
        Signed memory z = _prepare(NONCE, vm.getBlockTimestamp() + 1 days);
        _submit(z);

        OpenPuntStorage.ProposedSwap memory s2 = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m2 = _defaultMatcherPreimage();
        bytes32 intent2 = _proposalIntent(s2, m2, otherWallet.addr);
        uint256 deadline2 = vm.getBlockTimestamp() + 1 days;
        bytes memory sig2 = _sign65(
            otherWallet,
            _permit2Digest(address(collat), s2.initialMarginSwapper, NONCE, deadline2, otherWallet.addr, intent2)
        );

        vm.prank(otherWallet.addr);
        uint256 id2 = punt.propose{value: _value(s2)}(s2, m2, _permitParams(NONCE, deadline2, sig2));

        assertTrue(punt.swaps(id2) != bytes32(0), "the second signer's proposal stands");
        assertEq(_nonceBitmap(wallet.addr, 0), 1 << 7, "first signer's word 0");
        assertEq(_nonceBitmap(otherWallet.addr, 0), 1 << 7, "second signer's word 0, same bit, separate word");
    }
}
