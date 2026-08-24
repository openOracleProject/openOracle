// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./RealPermit2Base.t.sol";

/// @notice Verifies that the authentic Permit2 runtime is installed at its canonical address.
contract RealPermit2InstallTest is RealPermit2Base {
    function setUp() public {
        _setUpRealPermit2();
    }

    function test_authenticRuntimeIsInstalledAtTheCanonicalAddress() public view {
        assertGt(PERMIT2.code.length, 0, "code exists at the canonical Permit2 address");
        assertEq(PERMIT2, 0x000000000022D473030F116dDEE9F6B43aC78BA3, "and it is the canonical address");
    }

    function test_domainSeparatorMatchesAnIndependentDerivation() public view {
        assertEq(block.chainid, TEST_CHAIN_ID, "running off Foundry's default chain id");
        assertEq(
            _permit2DomainSeparator(),
            _domainSeparator(),
            "real DOMAIN_SEPARATOR equals keccak(EIP712Domain, 'Permit2', chainId, canonical address)"
        );
    }

    /**
     * @notice Documents why this fixture does not run on Foundry's default chain id.
     *
     * @dev The precompiled runtime in `DeployPermit2.sol` carries two immutables fixed at the
     *      time that artifact was built: `_CACHED_CHAIN_ID == 31337` and a
     *      `_CACHED_DOMAIN_SEPARATOR` computed from `address(this)` at that moment. `vm.etch`
     *      copies code, and immutables live in code, so the cache travels with it. It was not
     *      built at the canonical address, so on chain 31337 `DOMAIN_SEPARATOR()` returns a
     *      domain for the wrong verifying contract.
     *
     *      Off 31337 the cache is bypassed and the domain is rebuilt live from `address(this)`,
     *      which is the canonical address. That is the mainnet-authentic behaviour, and it is
     *      the configuration used by the real-Permit2 tests.
     *
     *      This is a property of Permit2's shipped test artifact, not of Permit2 itself and not
     *      of OpenPunt.
     */
    function test_cachedDomainOnChain31337IsForTheWrongAddress() public {
        bytes32 liveDomain = _permit2DomainSeparator();
        assertEq(liveDomain, _domainSeparator(), "live branch agrees with the canonical derivation");

        vm.chainId(31337);
        bytes32 cached = _permit2DomainSeparator();

        assertTrue(cached != liveDomain, "the cached value is a different domain entirely");
        assertTrue(
            cached != keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("Permit2"), uint256(31337), PERMIT2)),
            "and it is NOT the correct chain-31337 domain for the canonical address either"
        );
        assertEq(
            cached,
            0xd5a17abc3865df5c1400c0299bd4ce2eefc8114aec5f9d3dded1745783e57b98,
            "it is the constant baked into the shipped artifact"
        );

        vm.chainId(TEST_CHAIN_ID);
        assertEq(_permit2DomainSeparator(), liveDomain, "restored");
    }

    function test_nonceBitmapStartsEmpty() public view {
        assertEq(_nonceBitmap(wallet.addr, 0), 0, "word 0 empty");
        assertEq(_nonceBitmap(wallet.addr, 1), 0, "word 1 empty");
        assertEq(_nonceBitmap(otherWallet.addr, 0), 0, "other signer's word 0 empty");
    }

    /// @dev The spender in the signed struct must be the oracle. This gives a clear failure if a test
    ///      accidentally signs for the core fails here with a clear reason rather than deep
    ///      inside an unrelated happy path.
    function test_spenderIsTheOracleNotTheCore() public view {
        assertTrue(address(oracle) != address(punt), "the two are distinct contracts");

        bytes32 asOracle = _permitWitnessStructHash(address(collat), 1e18, address(oracle), 0, 1, bytes32(uint256(7)));
        bytes32 asCore = _permitWitnessStructHash(address(collat), 1e18, address(punt), 0, 1, bytes32(uint256(7)));
        assertTrue(asOracle != asCore, "the spender genuinely changes the struct hash");
    }

    function test_noncePositionDerivation() public pure {
        (uint256 w0, uint256 b0) = _noncePosition(0);
        assertEq(w0, 0, "nonce 0 -> word 0");
        assertEq(b0, 1, "nonce 0 -> bit 0");

        (uint256 w255, uint256 b255) = _noncePosition(255);
        assertEq(w255, 0, "nonce 255 -> word 0");
        assertEq(b255, 1 << 255, "nonce 255 -> top bit of word 0");

        (uint256 w256, uint256 b256) = _noncePosition(256);
        assertEq(w256, 1, "nonce 256 -> word 1");
        assertEq(b256, 1, "nonce 256 -> bit 0 of word 1");
    }
}
