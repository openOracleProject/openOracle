// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {ISignatureTransfer} from "../../src/interfaces/ISignatureTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice depositFromPermit2 behavioral tests.
///         Uses a witness-verifying Permit2 mock that reproduces Permit2's EIP-712 hash
///         construction and checks the signature against the expected signer + witness.
///         This catches witness-replay attacks (e.g., attacker changing beneficiary, relayer,
///         or swapper in the call), which a permissive mock would silently accept.
contract OpenOracleGGDepositPermit2Test is BaseGGTest {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    Vm.Wallet internal signer;
    bytes32 internal constant WITNESS_TYPEHASH =
        keccak256("Witness(address beneficiary,address relayer,address swapper,bytes32 intent)");
    string internal constant WITNESS_TYPE_STRING =
        "Witness witness)TokenPermissions(address token,uint256 amount)Witness(address beneficiary,address relayer,address swapper,bytes32 intent)";
    bytes32 internal constant PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB =
        keccak256(
            bytes(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Witness witness)TokenPermissions(address token,uint256 amount)Witness(address beneficiary,address relayer,address swapper,bytes32 intent)"
            )
        );

    function setUp() public override {
        super.setUp();
        signer = vm.createWallet("permit2-signer");

        // Deploy and etch a verifying Permit2 mock at the canonical address
        SigVerifyingPermit2 mock = new SigVerifyingPermit2();
        vm.etch(PERMIT2, address(mock).code);
        // Hand the mock the relevant signer info via storage so it can verify
        // (We can't easily etch storage; the mock recomputes EIP-712 hash and uses ecrecover.)

        // Give the signer some token1 for testing and approve Permit2
        token1.transfer(signer.addr, 100 ether);
        vm.prank(signer.addr);
        token1.approve(PERMIT2, type(uint256).max);
    }

    // Reconstructs the EIP-712 hash that Permit2 verifies against the signature.
    function _hashTypedData(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        address spender,
        bytes32 witness
    ) internal view returns (bytes32) {
        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount)
        );
        bytes32 dataHash = keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB,
                tokenPermissionsHash,
                spender,
                nonce,
                deadline,
                witness
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Permit2")),
                block.chainid,
                PERMIT2
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, dataHash));
    }

    function _signPermitWithWitness(
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        address beneficiary,
        address relayer,
        address swapper,
        bytes32 intent
    ) internal view returns (bytes memory sig) {
        bytes32 witness = keccak256(abi.encode(WITNESS_TYPEHASH, beneficiary, relayer, swapper, intent));
        bytes32 digest = _hashTypedData(address(token1), amount, nonce, deadline, address(oracle), witness);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.privateKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _permit(uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token1), amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
    }

    // ── Happy path ─────────────────────────────────────────────────────

    function testDepositFromPermit2_ValidSig_CreditsBeneficiary() public {
        address beneficiary = bob;
        address relayer = address(this); // the test contract itself calls oracle
        bytes32 intent = keccak256("test intent");

        bytes memory sig = _signPermitWithWitness(
            1e18, 1, type(uint256).max, beneficiary, relayer, signer.addr, intent
        );

        uint256 sigBalBefore = token1.balanceOf(signer.addr);

        oracle.depositFromPermit2(
            1e18,
            beneficiary,
            signer.addr,
            intent,
            _permit(1e18, 1, type(uint256).max),
            sig
        );

        // signer's external token1 debited by 1e18
        assertEq(token1.balanceOf(signer.addr), sigBalBefore - 1e18, "signer debited externally");
        // beneficiary credited internally
        assertEq(_heldTokens(beneficiary, address(token1)), 1e18 + 1, "bob credited internally");
    }

    // ── Witness binding rejects replays ────────────────────────────────

    function testDepositFromPermit2_AttackerSwapsBeneficiary_Reverts() public {
        address signedBeneficiary = bob;
        bytes32 intent = keccak256("intent");

        // Signer signs for beneficiary=bob, relayer=this
        bytes memory sig = _signPermitWithWitness(
            1e18, 1, type(uint256).max, signedBeneficiary, address(this), signer.addr, intent
        );

        // Attacker tries to redirect credit to themselves
        address attacker = address(0xBAD);
        vm.expectRevert(); // Permit2 sig recovery fails
        oracle.depositFromPermit2(
            1e18,
            attacker,
            signer.addr,
            intent,
            _permit(1e18, 1, type(uint256).max),
            sig
        );
    }

    function testDepositFromPermit2_DifferentRelayer_Reverts() public {
        bytes32 intent = keccak256("intent");
        address intendedRelayer = address(0xAAAA);

        // Signer signs binding relayer = intendedRelayer
        bytes memory sig = _signPermitWithWitness(
            1e18, 1, type(uint256).max, bob, intendedRelayer, signer.addr, intent
        );

        // But the actual relayer (msg.sender to depositFromPermit2) is this contract.
        // Oracle computes witness with msg.sender (this), which differs from signed relayer.
        vm.expectRevert();
        oracle.depositFromPermit2(
            1e18,
            bob,
            signer.addr,
            intent,
            _permit(1e18, 1, type(uint256).max),
            sig
        );
    }

    function testDepositFromPermit2_DifferentIntent_Reverts() public {
        bytes32 signedIntent = keccak256("intent A");
        bytes32 attackerIntent = keccak256("intent B");

        bytes memory sig = _signPermitWithWitness(
            1e18, 1, type(uint256).max, bob, address(this), signer.addr, signedIntent
        );

        // Call with different intent — oracle computes different witness — sig fails
        vm.expectRevert();
        oracle.depositFromPermit2(
            1e18,
            bob,
            signer.addr,
            attackerIntent,
            _permit(1e18, 1, type(uint256).max),
            sig
        );
    }

    function testDepositFromPermit2_DifferentSwapper_Reverts() public {
        bytes32 intent = keccak256("intent");

        // Signer signs with swapper=signer.addr
        bytes memory sig = _signPermitWithWitness(
            1e18, 1, type(uint256).max, bob, address(this), signer.addr, intent
        );

        // Caller passes from=different address — Permit2 verifies sig against `from`,
        // which is now wrong. Even if it weren't, the witness's swapper field still binds.
        vm.expectRevert();
        oracle.depositFromPermit2(
            1e18,
            bob,
            address(0xC0DE), // wrong from
            intent,
            _permit(1e18, 1, type(uint256).max),
            sig
        );
    }

    // ── Local validation ──────────────────────────────────────────────

    function testDepositFromPermit2_RevertOnZeroBeneficiary() public {
        bytes32 intent = keccak256("intent");
        bytes memory sig = _signPermitWithWitness(
            1e18, 1, type(uint256).max, address(0), address(this), signer.addr, intent
        );

        vm.expectRevert(Errors.AddressCannotBeZero.selector);
        oracle.depositFromPermit2(
            1e18,
            address(0),
            signer.addr,
            intent,
            _permit(1e18, 1, type(uint256).max),
            sig
        );
    }

    function testDepositFromPermit2_ExpiredDeadline_Reverts() public {
        // Warp to a known timestamp so we have headroom to set deadline in the past
        vm.warp(1000);
        bytes32 intent = keccak256("intent");
        uint256 expired = block.timestamp - 1;

        // Sig is valid (correct witness, correct token/amount/nonce/spender) but the deadline has passed
        bytes memory sig = _signPermitWithWitness(
            1e18, 1, expired, bob, address(this), signer.addr, intent
        );

        vm.expectRevert(SigVerifyingPermit2.SignatureExpired.selector);
        oracle.depositFromPermit2(
            1e18,
            bob,
            signer.addr,
            intent,
            _permit(1e18, 1, expired),
            sig
        );
    }

    function testDepositFromPermit2_RevertOnAmountMismatch() public {
        bytes32 intent = keccak256("intent");
        // Sig says 1e18, but caller passes 2e18 as amount param
        bytes memory sig = _signPermitWithWitness(
            1e18, 1, type(uint256).max, bob, address(this), signer.addr, intent
        );

        vm.expectRevert(Errors.Permit2AmountMismatch.selector);
        oracle.depositFromPermit2(
            2e18,   // amount arg mismatches permit.permitted.amount
            bob,
            signer.addr,
            intent,
            _permit(1e18, 1, type(uint256).max),
            sig
        );
    }
}

/// @dev Mock Permit2 that fully verifies EIP-712 sigs against the witness
///      typestring our slim uses. Lets replay-attack tests actually fail.
contract SigVerifyingPermit2 is ISignatureTransfer {
    using ECDSA for bytes32;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 private constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 private constant WITNESS_STUB =
        keccak256(
            bytes(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Witness witness)TokenPermissions(address token,uint256 amount)Witness(address beneficiary,address relayer,address swapper,bytes32 intent)"
            )
        );

    mapping(address => mapping(uint256 => uint256)) public nonceBitmap; // not really used; just for ABI

    error InvalidSignature();
    error SignatureExpired();
    error InvalidNonce();

    function permitTransferFrom(
        PermitTransferFrom calldata, /*permit*/
        SignatureTransferDetails calldata, /*transferDetails*/
        address, /*owner*/
        bytes calldata /*signature*/
    ) external pure {
        revert("not implemented in mock");
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata, /*witnessTypeString*/
        bytes calldata signature
    ) external {
        if (block.timestamp > permit.deadline) revert SignatureExpired();
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount));
        bytes32 dataHash = keccak256(
            abi.encode(
                WITNESS_STUB,
                tokenPermissionsHash,
                msg.sender, // spender = caller of Permit2
                permit.nonce,
                permit.deadline,
                witness
            )
        );
        bytes32 domainSep =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("Permit2")), block.chainid, address(this)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, dataHash));
        address recovered = digest.recover(signature);
        if (recovered != owner) revert InvalidSignature();

        // Pull the tokens
        IERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}

library ECDSA {
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "bad sig");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        return ecrecover(hash, v, r, s);
    }
}
