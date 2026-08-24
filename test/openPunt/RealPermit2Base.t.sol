// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./TokenCompatBase.t.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

/**
 * @notice Fixture for integration against the authentic Uniswap Permit2 implementation.
 *
 * @dev Dependency: uniswap/permit2 @ cc56ad0f3439c502c246fc5cfcc3db92bb8b7219.
 *      The official `test/utils/DeployPermit2.sol` helper etches Permit2's precompiled 0.8.17
 *      runtime at the canonical address, so the repository's own compiler configuration is
 *      untouched and no RPC fork is needed.
 *
 *      `RecordingPermit2` proves what payload
 *      OpenPunt transmits. This fixture proves the signature, nonce, replay and deadline
 *      semantics of that payload. Neither replaces the other.
 *
 *      The Permit2 `spender` bound into the signed struct is `msg.sender` as seen by
 *      Permit2 — which is OpenOracle, not OpenPunt. OpenPunt calls OpenOracle, and OpenOracle
 *      is what calls Permit2. `test_spenderIsTheOracleNotTheCore` pins this so a mis-signed
 *      test cannot fail obscurely.
 */
abstract contract RealPermit2Base is TokenCompatBase {
    // ── authentic Permit2 errors, declared locally for their selectors ───
    error InvalidNonce();
    error InvalidSigner();
    error SignatureExpired(uint256 signatureDeadline);
    error InvalidSignatureLength();
    error InvalidSignature();

    // ── EIP-712 pieces, derived here rather than read from production ────
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 internal constant WITNESS_TYPEHASH =
        keccak256("Witness(address beneficiary,address relayer,address swapper,bytes32 intent)");

    string internal constant PERMIT_WITNESS_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    string internal constant WITNESS_TYPE_STRING =
        "Witness witness)TokenPermissions(address token,uint256 amount)Witness(address beneficiary,address relayer,address swapper,bytes32 intent)";

    /// @dev The fixture does not use Foundry's default chain id 31337. The precompiled artifact
    ///      has `_CACHED_CHAIN_ID = 31337` and a `_CACHED_DOMAIN_SEPARATOR` immutable baked in at
    ///      whatever address that artifact was originally constructed at — which is not the
    ///      canonical address the helper etches it to. On chain 31337 `DOMAIN_SEPARATOR()`
    ///      therefore returns that stale cache. On any other chain id Permit2 takes the
    ///      `_buildDomainSeparator` branch and computes it live from `address(this)`, which after
    ///      etching is the canonical address. Running off 31337 makes this artifact
    ///      behave like the real mainnet deployment. Pinned by
    ///      `RealPermit2InstallTest.test_cachedDomainOnChain31337IsForTheWrongAddress`.
    ///
    ///      Neither OpenPunt nor OpenOracle reads `block.chainid` anywhere, so this is inert for
    ///      the protocol itself.
    uint256 internal constant TEST_CHAIN_ID = 1;

    Vm.Wallet internal wallet;
    Vm.Wallet internal otherWallet;

    function _setUpRealPermit2() internal {
        vm.chainId(TEST_CHAIN_ID);
        _setUpTokenCompat();

        // authentic runtime replaces the recorder, before any Permit2 interaction has occurred
        DeployPermit2 deployer = new DeployPermit2();
        deployer.deployPermit2();

        wallet = vm.createWallet("permit2-signer");
        otherWallet = vm.createWallet("permit2-other");

        _armWallet(wallet.addr);
        _armWallet(otherWallet.addr);

        // matcher margin for both collateral tokens the close suite uses
        _nrtDeposit(matcher, 1_000_000e18);
        _nrtApproveInternal(matcher);
    }

    // ── opening positions owned by a signing wallet ─────────────────────

    /// @dev Distinct nonce per fixture proposal, so fixture setup never collides with the
    ///      nonces a test is deliberately exercising.
    uint256 internal fixtureNonce = 1_000_000;

    function _proposeSigned(
        Vm.Wallet memory w,
        OpenPuntStorage.ProposedSwap memory s,
        OpenPuntStorage.MatcherPreimage memory m
    ) internal returns (Proposal memory p) {
        uint256 nonce = fixtureNonce++;
        uint256 deadline = vm.getBlockTimestamp() + 365 days;
        bytes32 intent = _proposalIntent(s, m, w.addr);
        bytes memory sig =
            _sign65(w, _permit2Digest(s.collatToken, s.initialMarginSwapper, nonce, deadline, w.addr, intent));

        vm.recordLogs();
        vm.prank(w.addr);
        p.swapId = punt.propose{value: _correctMsgValue(s)}(s, m, _permitParams(nonce, deadline, sig));
        (p.swap, p.preimage) = _decodeSwapProposed(vm.getRecordedLogs(), p.swapId);
    }

    /// @dev Active, idle, pre-maturity position genuinely owned by `w`, funded
    ///      externally through the authentic Permit2. `close()` requires `msg.sender == swapper`,
    ///      so close-side signing tests need the position owner to be a keyed account.
    function _openIdleFor(Vm.Wallet memory w, address collatToken)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _tokenCfg(address(tokenA), address(tokenB), collatToken, false);

        p = _proposeSigned(w, s, m);
        Matched memory mt = _matchSwapWith(p, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        active = _executeOpening(mt, executor);
        swapId = p.swapId;

        assertEq(punt.swapIdToReportId(swapId), 0, "fixture: idle position");
        assertTrue(active.active, "fixture: active position");
        assertEq(active.swapper, w.addr, "fixture: the signing wallet owns the position");
    }

    function _armWallet(address who) internal {
        vm.deal(who, 10_000 ether);
        collat.mint(who, 1_000_000e18);
        nrt.mint(who, 1_000_000e18);
        vm.startPrank(who);
        collat.approve(PERMIT2, type(uint256).max);
        nrt.approve(PERMIT2, type(uint256).max);
        vm.stopPrank();
    }

    // ── authentic Permit2 views ─────────────────────────────────────────

    function _permit2DomainSeparator() internal view returns (bytes32) {
        (bool ok, bytes memory ret) = PERMIT2.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok, "permit2 DOMAIN_SEPARATOR failed");
        return abi.decode(ret, (bytes32));
    }

    function _nonceBitmap(address owner, uint256 wordPos) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            PERMIT2.staticcall(abi.encodeWithSignature("nonceBitmap(address,uint256)", owner, wordPos));
        require(ok, "permit2 nonceBitmap failed");
        return abi.decode(ret, (uint256));
    }

    /// @dev wordPos and bitMask derived here, not read back from Permit2.
    function _noncePosition(uint256 nonce) internal pure returns (uint256 wordPos, uint256 bitMask) {
        wordPos = nonce >> 8;
        bitMask = 1 << (nonce & 0xff);
    }

    function _nonceUsed(address owner, uint256 nonce) internal view returns (bool) {
        (uint256 wordPos, uint256 bitMask) = _noncePosition(nonce);
        return _nonceBitmap(owner, wordPos) & bitMask != 0;
    }

    // ── independent EIP-712 derivation, layer by layer ──────────────────

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("Permit2"), block.chainid, PERMIT2));
    }

    function _tokenPermissionsHash(address token, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, token, amount));
    }

    /// @dev OpenOracle's witness. beneficiary and relayer are both the core; swapper is the
    ///      token owner; intent is the proposal or close intent.
    function _witnessHash(address beneficiary, address relayer, address swapper_, bytes32 intent)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(WITNESS_TYPEHASH, beneficiary, relayer, swapper_, intent));
    }

    function _permitWitnessStructHash(
        address token,
        uint256 amount,
        address spender,
        uint256 nonce,
        uint256 deadline,
        bytes32 witness
    ) internal pure returns (bytes32) {
        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_WITNESS_STUB, WITNESS_TYPE_STRING));
        return keccak256(abi.encode(typeHash, _tokenPermissionsHash(token, amount), spender, nonce, deadline, witness));
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /// @dev General digest: every witness role supplied explicitly. The Permit2 `spender` is
    ///      always the oracle, because the oracle is what calls Permit2.
    function _permit2DigestFull(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        address beneficiary,
        address relayer,
        address from,
        bytes32 intent
    ) internal view returns (bytes32) {
        bytes32 witness = _witnessHash(beneficiary, relayer, from, intent);
        return _digest(_permitWitnessStructHash(token, amount, address(oracle), nonce, deadline, witness));
    }

    /// @dev Digest for a transfer OpenPunt drives. The core is both the witness beneficiary and
    ///      the relayer, because the core is what calls the oracle and what gets credited. Those
    ///      two roles coincide in every OpenPunt path, which is why their positional order is
    ///      pinned separately in `RealPermit2WitnessTest`.
    function _permit2Digest(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        address owner,
        bytes32 intent
    ) internal view returns (bytes32) {
        return _permit2DigestFull(token, amount, nonce, deadline, address(punt), address(punt), owner, intent);
    }

    // ── intents ─────────────────────────────────────────────────────────

    /// @dev The proposal intent uses raw caller input with only the swapper override applied. The
    ///      expiration is still the relative duration and startFulfillFeeIncrease is still zero.
    function _proposalIntent(
        OpenPuntStorage.ProposedSwap memory s,
        OpenPuntStorage.MatcherPreimage memory m,
        address actualCaller
    ) internal pure returns (bytes32) {
        OpenPuntStorage.ProposedSwap memory intentSwap = _copy(s);
        intentSwap.swapper = actualCaller;
        return keccak256(abi.encode(intentSwap, m));
    }

    /// @dev The close intent: canonical Dutch with swapper/collatToken/swapId stamped,
    ///      useInternalBalances false, and `start` still zero.
    function _closeIntent(
        OpenPuntStorage.CloseDutch memory input,
        uint256 swapId,
        address collatToken,
        address positionSwapper
    ) internal pure returns (bytes32) {
        OpenPuntStorage.CloseDutch memory d = _copy(input);
        d.swapper = positionSwapper;
        d.collatToken = collatToken;
        d.swapId = swapId;
        d.useInternalBalances = false;
        d.start = 0;
        return keccak256(abi.encode(d));
    }

    /// @dev CloseBase's `_canonicalDutch` stamps the fixture EOA as the swapper. These positions
    ///      are owned by a signing wallet, so the canonical struct is rebuilt for that owner.
    ///      Externally funded by construction, hence `useInternalBalances == false`.
    function _canonicalDutchFor(
        OpenPuntStorage.CloseDutch memory input,
        uint256 swapId,
        address collatToken,
        address positionSwapper,
        uint48 startTs
    ) internal pure returns (OpenPuntStorage.CloseDutch memory d) {
        d = _copy(input);
        d.swapper = positionSwapper;
        d.collatToken = collatToken;
        d.swapId = swapId;
        d.useInternalBalances = false;
        d.start = startTs;
    }

    // ── signing ─────────────────────────────────────────────────────────

    function _sign65(Vm.Wallet memory w, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev EIP-2098 compact 64-byte form: the recovery bit is packed into the top bit of s.
    function _sign2098(Vm.Wallet memory w, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w, digest);
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        return abi.encodePacked(r, vs);
    }

    function _permitParams(uint256 nonce, uint256 deadline, bytes memory sig)
        internal
        pure
        returns (OpenPuntStorage.Permit2Params memory)
    {
        return OpenPuntStorage.Permit2Params({nonce: nonce, deadline: deadline, signature: sig});
    }

    // ── rollback snapshots ──────────────────────────────────────────────

    struct P2Book {
        uint256 nextSwapId;
        uint256 ownerExternal;
        uint256 oracleCustody;
        uint256 coreInternal;
        uint256 coreEth;
        uint256 nonceWord;
    }

    function _p2Book(address owner, address token, uint256 nonce) internal view returns (P2Book memory b) {
        (uint256 wordPos,) = _noncePosition(nonce);
        b.nextSwapId = punt.nextSwapId();
        b.ownerExternal = _erc20BalanceOf(token, owner);
        b.oracleCustody = _erc20BalanceOf(token, address(oracle));
        b.coreInternal = _spendable(address(punt), token);
        b.coreEth = address(punt).balance;
        b.nonceWord = _nonceBitmap(owner, wordPos);
    }

    function _assertFullyRolledBack(
        P2Book memory before,
        address owner,
        address token,
        uint256 nonce,
        string memory what
    ) internal view {
        (uint256 wordPos,) = _noncePosition(nonce);
        assertFalse(_nonceUsed(owner, nonce), string.concat(what, ": nonce still unused"));
        assertEq(_nonceBitmap(owner, wordPos), before.nonceWord, string.concat(what, ": nonce word untouched"));
        assertEq(punt.nextSwapId(), before.nextSwapId, string.concat(what, ": nextSwapId rolled back"));
        assertEq(punt.swaps(before.nextSwapId), bytes32(0), string.concat(what, ": no swap stored"));
        assertEq(_erc20BalanceOf(token, owner), before.ownerExternal, string.concat(what, ": owner balance"));
        assertEq(_erc20BalanceOf(token, address(oracle)), before.oracleCustody, string.concat(what, ": oracle custody"));
        assertEq(_spendable(address(punt), token), before.coreInternal, string.concat(what, ": core credit"));
        assertEq(address(punt).balance, before.coreEth, string.concat(what, ": core retained no ETH"));
    }

    /// @dev Works for both the boolean-return and the no-return token.
    function _erc20BalanceOf(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        return abi.decode(ret, (uint256));
    }
}
