// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./RealPermit2Base.t.sol";

/**
 * @notice Close-auction funding against authentic Permit2.
 *
 * @dev `close()` requires `msg.sender == s.swapper`, so every position here is genuinely opened
 *      by a keyed wallet — itself through a real signature — rather than by relabelling a field.
 *
 *      Permit2 flips the nonce bit before it verifies the signature and before
 *      it moves any tokens. Every rejection below therefore relies on the whole transaction
 *      reverting to roll that bit back, which is exactly what `_assertFullyRolledBack` checks.
 *
 *      Contract-wallet signatures are not covered. OpenPunt gates
 *      `close()` on `msg.sender == s.swapper`, so a contract signer would have to both own and
 *      drive the position; that is a distinct fixture, and the isContract branch belongs to
 *      Permit2 rather than OpenPunt.
 */
contract RealPermit2CloseTest is RealPermit2Base {
    uint256 internal constant NONCE = 42;

    function setUp() public {
        _setUpRealPermit2();
    }

    // ── driver ──────────────────────────────────────────────────────────

    struct SignedClose {
        uint256 swapId;
        OpenPuntStorage.MatchedSwap active;
        OpenPuntStorage.CloseDutch input;
        address collatToken;
        uint256 nonce;
        uint256 deadline;
        bytes32 intent;
        bytes sig;
    }

    function _prepareClose(Vm.Wallet memory w, address collatToken, uint256 nonce)
        internal
        returns (SignedClose memory z)
    {
        (z.swapId, z.active,) = _openIdleFor(w, collatToken);
        z.input = _dutchInput();
        z.collatToken = collatToken;
        z.nonce = nonce;
        z.deadline = vm.getBlockTimestamp() + 1 days;
        _reSign(w, z);
    }

    /// @dev Rebuilds the intent and the signature from whatever `z.input` currently holds.
    function _reSign(Vm.Wallet memory w, SignedClose memory z) internal {
        z.intent = _closeIntent(z.input, z.swapId, z.collatToken, w.addr);
        z.sig = _sign65(w, _permit2Digest(z.collatToken, z.input.maxReward, z.nonce, z.deadline, w.addr, z.intent));
    }

    function _submitClose(Vm.Wallet memory w, SignedClose memory z) internal {
        vm.prank(w.addr);
        punt.close{value: CLOSE_COMP}(
            z.swapId,
            z.input,
            z.active,
            false,
            _permitParams(z.nonce, z.deadline, z.sig),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  1. Happy path
    // ══════════════════════════════════════════════════════════════════

    function test_realSignatureFundsACloseAuction() public {
        SignedClose memory z = _prepareClose(wallet, address(collat), NONCE);

        uint256 ownerBefore = collat.balanceOf(wallet.addr);
        uint256 oracleBefore = collat.balanceOf(address(oracle));
        uint256 coreBefore = _spendable(address(punt), address(collat));
        (uint256 wordPos, uint256 bitMask) = _noncePosition(NONCE);
        assertEq(_storedDutchState(z.swapId), bytes32(0), "no auction beforehand");

        vm.recordLogs();
        _submitClose(wallet, z);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // the auction genuinely exists, at the canonical struct with the absolute start stamped
        uint48 startTs = uint48(vm.getBlockTimestamp());
        OpenPuntStorage.CloseDutch memory canonical =
            _canonicalDutchFor(z.input, z.swapId, address(collat), wallet.addr, startTs);
        bytes32 expectedHash = keccak256(abi.encode(canonical));
        assertEq(_storedAuctionHash(z.swapId, z.active), expectedHash, "stored auction hash");

        // the emitted struct reconstructs that same hash, and carries the absolute start
        OpenPuntStorage.CloseDutch memory emitted = _decodeCloseAuctionStarted(logs, z.swapId);
        assertEq(keccak256(abi.encode(emitted)), expectedHash, "emitted Dutch rebuilds the stored hash");
        assertEq(emitted.start, startTs, "absolute start stamped, not the zero the intent was signed over");
        assertTrue(emitted.start != 0, "and the signed intent's zero start did not survive into storage");
        assertEq(emitted.swapper, wallet.addr, "swapper stamped");
        assertEq(emitted.collatToken, address(collat), "collateral token stamped");
        assertEq(emitted.swapId, z.swapId, "swapId stamped");
        assertFalse(emitted.useInternalBalances, "externally funded");
        assertEq(emitted.maxReward, DUTCH_MAX, "maxReward carried through");

        // close state
        (uint128 pendingComp,, bool intentSet) = _closeState(z.swapId);
        assertTrue(intentSet, "close request is live");
        assertEq(pendingComp, CLOSE_COMP, "pending execution compensation");

        // the reward really was pulled from the signer by Permit2
        assertEq(collat.balanceOf(wallet.addr), ownerBefore - DUTCH_MAX, "signer debited the max reward");
        assertEq(collat.balanceOf(address(oracle)) - oracleBefore, DUTCH_MAX, "oracle custodies it");
        assertEq(_spendable(address(punt), address(collat)) - coreBefore, DUTCH_MAX, "core credited internally");

        // nonce 42 = 0b101010 -> word 0, bit 42
        assertEq(wordPos, 0, "derived word");
        assertEq(bitMask, 1 << 42, "derived bit");
        assertEq(_nonceBitmap(wallet.addr, 0) & bitMask, bitMask, "close nonce consumed");
    }

    function test_compactEip2098SignatureIsAccepted() public {
        SignedClose memory z = _prepareClose(wallet, address(collat), NONCE);

        bytes32 digest = _permit2Digest(address(collat), z.input.maxReward, z.nonce, z.deadline, wallet.addr, z.intent);
        z.sig = _sign2098(wallet, digest);
        assertEq(z.sig.length, 64, "compact form is 64 bytes");

        _submitClose(wallet, z);

        assertTrue(_storedDutchState(z.swapId) != bytes32(0), "auction created from a compact signature");
        assertTrue(_nonceUsed(wallet.addr, NONCE), "nonce consumed");
    }

    // ══════════════════════════════════════════════════════════════════
    //  2. Close intent binding
    // ══════════════════════════════════════════════════════════════════

    /// @dev `startingReward` is inside the signed intent but is not the permitted amount, so
    ///      this isolates witness binding from TokenPermissions binding.
    function test_closeIntentBindsTheDutchParametersBeyondTheAmount() public {
        SignedClose memory z = _prepareClose(wallet, address(collat), NONCE);

        z.input.startingReward = z.input.startingReward + 1;
        assertTrue(
            _closeIntent(z.input, z.swapId, address(collat), wallet.addr) != z.intent, "the intent really changed"
        );

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(InvalidSigner.selector);
        _submitClose(wallet, z);
        _assertCloseRolledBack(before, z, "mutated startingReward");
    }

    function test_closeIntentBindsTheExpiration() public {
        SignedClose memory z = _prepareClose(wallet, address(collat), NONCE);

        z.input.expiration = z.input.expiration - 1;

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(InvalidSigner.selector);
        _submitClose(wallet, z);
        _assertCloseRolledBack(before, z, "mutated expiration");
    }

    function test_closeIntentBindsTheMaxReward() public {
        SignedClose memory z = _prepareClose(wallet, address(collat), NONCE);

        z.input.maxReward = z.input.maxReward + 1; // both the intent AND the permitted amount

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(InvalidSigner.selector);
        _submitClose(wallet, z);
        _assertCloseRolledBack(before, z, "mutated maxReward");
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. Cross-position replay
    // ══════════════════════════════════════════════════════════════════

    /// @dev The swapId is inside the signed close intent, so a signature authorising an auction
    ///      on position A cannot fund one on position B even with a fresh, unused nonce.
    function test_aCloseSignatureCannotBeReusedOnAnotherPosition() public {
        SignedClose memory a = _prepareClose(wallet, address(collat), NONCE);
        SignedClose memory b = _prepareClose(wallet, address(collat), NONCE + 1);
        assertTrue(a.swapId != b.swapId, "two distinct positions, same owner");

        // move A's signature and nonce onto B, unchanged
        b.sig = a.sig;
        b.nonce = a.nonce;
        b.deadline = a.deadline;
        b.input = _copy(a.input);

        P2Book memory before = _p2Book(wallet.addr, address(collat), b.nonce);
        vm.expectRevert(InvalidSigner.selector);
        _submitClose(wallet, b);
        _assertCloseRolledBack(before, b, "cross-position replay");

        // and A itself is still fundable with that same signature
        _submitClose(wallet, a);
        assertTrue(_storedDutchState(a.swapId) != bytes32(0), "A's auction created by its own signature");
        assertEq(_storedDutchState(b.swapId), bytes32(0), "B still has no auction");
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. Close nonce consumption across positions
    // ══════════════════════════════════════════════════════════════════

    /// @dev Two positions and two individually valid signatures share one nonce. The bitmap is global
    ///      per signer, not per position, so the second is rejected on the nonce alone.
    function test_oneNonceServesOnlyOneClose() public {
        SignedClose memory a = _prepareClose(wallet, address(collat), NONCE);
        SignedClose memory b = _prepareClose(wallet, address(collat), NONCE); // same nonce
        _reSign(wallet, b); // b's signature is correct FOR b

        _submitClose(wallet, a);
        assertTrue(_nonceUsed(wallet.addr, NONCE), "the shared nonce is spent");

        P2Book memory before = _p2Book(wallet.addr, address(collat), NONCE);
        vm.expectRevert(InvalidNonce.selector);
        _submitClose(wallet, b);

        assertEq(_storedDutchState(b.swapId), bytes32(0), "B got no auction");
        assertEq(_nonceBitmap(wallet.addr, 0), before.nonceWord, "bitmap unchanged by the rejection");
        assertEq(collat.balanceOf(wallet.addr), before.ownerExternal, "no second pull");

        // B is still closable on a fresh nonce
        b.nonce = NONCE + 1;
        _reSign(wallet, b);
        _submitClose(wallet, b);
        assertTrue(_storedDutchState(b.swapId) != bytes32(0), "B closes on a fresh nonce");
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. Authorization
    // ══════════════════════════════════════════════════════════════════

    /// @dev A valid signature is not authorization. OpenPunt rejects the non-owner before
    ///      Permit2 is ever reached, so the signer's nonce survives untouched.
    function test_aStrangerCannotCloseEvenHoldingAValidSignature() public {
        SignedClose memory z = _prepareClose(wallet, address(collat), NONCE);

        // otherWallet signs a perfectly well-formed permit for the same auction
        bytes memory strangerSig = _sign65(
            otherWallet,
            _permit2Digest(address(collat), z.input.maxReward, z.nonce, z.deadline, otherWallet.addr, z.intent)
        );

        P2Book memory before = _p2Book(otherWallet.addr, address(collat), z.nonce);
        vm.prank(otherWallet.addr);
        vm.expectRevert(PuntErrors.NotSwapper.selector);
        punt.close{value: CLOSE_COMP}(
            z.swapId,
            z.input,
            z.active,
            false,
            _permitParams(z.nonce, z.deadline, strangerSig),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );

        assertEq(_storedDutchState(z.swapId), bytes32(0), "no auction created");
        assertFalse(_nonceUsed(otherWallet.addr, z.nonce), "the stranger's nonce was never reached");
        assertEq(_nonceBitmap(otherWallet.addr, 0), before.nonceWord, "stranger's bitmap untouched");
        assertEq(collat.balanceOf(otherWallet.addr), before.ownerExternal, "stranger not debited");
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. Failed token pull rolls the nonce back
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Permit2 marks the nonce spent before it pulls tokens. If the pull fails, the whole
     *         transaction reverts, so the nonce is genuinely reusable afterwards.
     *
     * @dev The failure is real: the signer revokes its own ERC20 allowance to Permit2 through a
     *      normal `approve` call. Nothing is mocked.
     */
    function test_aFailedTokenPullLeavesTheNonceSpendable() public {
        SignedClose memory z = _prepareClose(wallet, address(collat), NONCE);

        vm.prank(wallet.addr);
        collat.approve(PERMIT2, 0);

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        _submitClose(wallet, z);
        _assertCloseRolledBack(before, z, "revoked allowance");

        // Restore the allowance; the same signature and nonce now work.
        vm.prank(wallet.addr);
        collat.approve(PERMIT2, type(uint256).max);
        _submitClose(wallet, z);

        assertTrue(_storedDutchState(z.swapId) != bytes32(0), "auction created on the retry");
        assertTrue(_nonceUsed(wallet.addr, NONCE), "and only now is the nonce spent");
    }

    // ══════════════════════════════════════════════════════════════════
    //  7. Deadline
    // ══════════════════════════════════════════════════════════════════

    function test_closeDeadlineEqualToNowIsAccepted() public {
        SignedClose memory z = _prepareClose(wallet, address(collat), NONCE);
        z.deadline = vm.getBlockTimestamp();
        _reSign(wallet, z);

        _submitClose(wallet, z);

        assertEq(vm.getBlockTimestamp(), z.deadline, "submitted exactly on the boundary");
        assertTrue(_storedDutchState(z.swapId) != bytes32(0), "accepted");
    }

    function test_closeDeadlineOneSecondInThePastIsRejected() public {
        SignedClose memory z = _prepareClose(wallet, address(collat), NONCE);
        z.deadline = vm.getBlockTimestamp() - 1;
        _reSign(wallet, z);

        P2Book memory before = _p2Book(wallet.addr, address(collat), z.nonce);
        vm.expectRevert(abi.encodeWithSelector(SignatureExpired.selector, z.deadline));
        _submitClose(wallet, z);
        _assertCloseRolledBack(before, z, "expired close");
    }

    // ══════════════════════════════════════════════════════════════════
    //  8. No-return (USDT-style) collateral
    // ══════════════════════════════════════════════════════════════════

    /// @dev Authentic Permit2 uses SafeTransferLib, which accepts an empty return. This is the
    ///      real proof of the compatibility the recorder suites could only assume.
    function test_noReturnCollateralCloseAuction() public {
        SignedClose memory z = _prepareClose(wallet, address(nrt), NONCE);

        uint256 ownerBefore = nrt.balanceOf(wallet.addr);
        uint256 oracleBefore = nrt.balanceOf(address(oracle));
        uint256 coreBefore = _spendable(address(punt), address(nrt));

        _submitClose(wallet, z);

        OpenPuntStorage.CloseDutch memory canonical =
            _canonicalDutchFor(z.input, z.swapId, address(nrt), wallet.addr, uint48(vm.getBlockTimestamp()));
        assertEq(_storedAuctionHash(z.swapId, z.active), keccak256(abi.encode(canonical)), "auction created");
        assertEq(nrt.balanceOf(wallet.addr), ownerBefore - DUTCH_MAX, "no-return token debited");
        assertEq(nrt.balanceOf(address(oracle)) - oracleBefore, DUTCH_MAX, "oracle custodies it");
        assertEq(_spendable(address(punt), address(nrt)) - coreBefore, DUTCH_MAX, "core credited internally");
        assertTrue(_nonceUsed(wallet.addr, NONCE), "nonce consumed");
    }

    // ── shared rollback assertion ───────────────────────────────────────

    function _assertCloseRolledBack(P2Book memory before, SignedClose memory z, string memory what) internal view {
        assertEq(_storedDutchState(z.swapId), bytes32(0), string.concat(what, ": no auction stored"));
        assertFalse(_nonceUsed(wallet.addr, z.nonce), string.concat(what, ": nonce still unused"));
        assertEq(
            _erc20BalanceOf(z.collatToken, wallet.addr), before.ownerExternal, string.concat(what, ": owner balance")
        );
        assertEq(
            _erc20BalanceOf(z.collatToken, address(oracle)),
            before.oracleCustody,
            string.concat(what, ": oracle custody")
        );
        assertEq(_spendable(address(punt), z.collatToken), before.coreInternal, string.concat(what, ": core credit"));
        assertEq(address(punt).balance, before.coreEth, string.concat(what, ": core retained no ETH"));
    }
}
