// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./RealPermit2Base.t.sol";
import {ISignatureTransfer} from "../../src/interfaces/ISignatureTransfer.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/**
 * @notice Positional binding of OpenOracle's witness against authentic Permit2.
 *
 * @dev In every OpenPunt path the witness `beneficiary` and `relayer` are
 *      the same address — the core is what calls the oracle and what gets credited. Swapping
 *      those two fields is therefore unobservable there. A direct oracle call with distinct roles
 *      verifies their positional binding.
 *
 *      `depositFromPermit2` is permissionless and takes `beneficiary` explicitly, so this suite
 *      calls the real deployed oracle directly with the test contract as relayer and a separate
 *      account as beneficiary. This is isolated oracle mechanics — it creates no OpenPunt
 *      position state and stands alongside, not instead of, the routed lifecycle suites.
 */
contract RealPermit2WitnessTest is RealPermit2Base {
    uint256 internal constant NONCE = 900;
    bytes32 internal constant INTENT = keccak256("some-protocol-intent");

    address internal beneficiary = address(0xBEEF01);

    function setUp() public {
        _setUpRealPermit2();
    }

    function _permit(uint128 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(collat), amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
    }

    // ══════════════════════════════════════════════════════════════════
    //  Beneficiary and relayer are positionally distinct
    // ══════════════════════════════════════════════════════════════════

    function test_beneficiaryAndRelayerAreDistinctInThisFixture() public view {
        assertTrue(beneficiary != address(this), "the two witness roles are genuinely different accounts");
        assertTrue(address(this) != address(punt), "and the relayer here is not the core");
    }

    function test_correctlyOrderedWitnessCreditsTheBeneficiary() public {
        uint128 amount = 500e18;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes memory sig = _sign65(
            wallet,
            _permit2DigestFull(
                address(collat), amount, NONCE, deadline, beneficiary, address(this), wallet.addr, INTENT
            )
        );

        uint256 ownerBefore = collat.balanceOf(wallet.addr);
        uint256 oracleBefore = collat.balanceOf(address(oracle));

        oracle.depositFromPermit2(amount, beneficiary, wallet.addr, INTENT, _permit(amount, NONCE, deadline), sig);

        // credit lands on the beneficiary, never on the relayer
        assertEq(_spendable(beneficiary, address(collat)), amount, "beneficiary credited");
        assertEq(_spendable(address(this), address(collat)), 0, "relayer credited nothing");
        assertEq(collat.balanceOf(wallet.addr), ownerBefore - amount, "signer debited");
        assertEq(collat.balanceOf(address(oracle)) - oracleBefore, amount, "oracle custodies the tokens");
        assertTrue(_nonceUsed(wallet.addr, NONCE), "nonce consumed");
    }

    /// @dev Signs with beneficiary and relayer transposed while leaving every other field unchanged.
    function test_swappingBeneficiaryAndRelayerInTheSignatureIsRejected() public {
        uint128 amount = 500e18;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes memory swapped = _sign65(
            wallet,
            _permit2DigestFull(
                address(collat),
                amount,
                NONCE,
                deadline,
                address(this), // beneficiary and relayer transposed
                beneficiary,
                wallet.addr,
                INTENT
            )
        );

        uint256 ownerBefore = collat.balanceOf(wallet.addr);
        vm.expectRevert(InvalidSigner.selector);
        oracle.depositFromPermit2(amount, beneficiary, wallet.addr, INTENT, _permit(amount, NONCE, deadline), swapped);

        assertFalse(_nonceUsed(wallet.addr, NONCE), "nonce rolled back");
        assertEq(collat.balanceOf(wallet.addr), ownerBefore, "signer not debited");
        assertEq(_spendable(beneficiary, address(collat)), 0, "nothing credited");
    }

    /// @dev The signature authorises one relayer. Handing it to a different relayer fails, even
    ///      though every other field is untouched.
    function test_aDifferentRelayerCannotUseTheSignature() public {
        uint128 amount = 500e18;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        // Signed for this contract as relayer.
        bytes memory sig = _sign65(
            wallet,
            _permit2DigestFull(
                address(collat), amount, NONCE, deadline, beneficiary, address(this), wallet.addr, INTENT
            )
        );

        // relayed by a different contract instead
        bytes memory call = abi.encodeWithSelector(
            oracle.depositFromPermit2.selector,
            amount,
            beneficiary,
            wallet.addr,
            INTENT,
            _permit(amount, NONCE, deadline),
            sig
        );
        vm.expectRevert(InvalidSigner.selector);
        rejector.exec(address(oracle), 0, call);

        assertFalse(_nonceUsed(wallet.addr, NONCE), "nonce untouched");
        assertEq(_spendable(beneficiary, address(collat)), 0, "nothing credited");

        // the intended relayer still works with the very same signature
        oracle.depositFromPermit2(amount, beneficiary, wallet.addr, INTENT, _permit(amount, NONCE, deadline), sig);
        assertEq(_spendable(beneficiary, address(collat)), amount, "intended relayer succeeds");
    }

    /// @dev The witness `swapper` field is the token owner. Permit2 recovers against the `from`
    ///      it is handed, so a signature naming a different swapper cannot be used.
    function test_theSwapperFieldBindsTheTokenOwner() public {
        uint128 amount = 500e18;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        // wallet signs, but names otherWallet as the witness swapper
        bytes memory sig = _sign65(
            wallet,
            _permit2DigestFull(
                address(collat), amount, NONCE, deadline, beneficiary, address(this), otherWallet.addr, INTENT
            )
        );

        vm.expectRevert(InvalidSigner.selector);
        oracle.depositFromPermit2(amount, beneficiary, wallet.addr, INTENT, _permit(amount, NONCE, deadline), sig);
        assertFalse(_nonceUsed(wallet.addr, NONCE), "nonce untouched");
    }

    /// @dev The intent is opaque to Permit2 but is inside the signed witness, so it binds.
    function test_theIntentBinds() public {
        uint128 amount = 500e18;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes memory sig = _sign65(
            wallet,
            _permit2DigestFull(
                address(collat), amount, NONCE, deadline, beneficiary, address(this), wallet.addr, INTENT
            )
        );

        vm.expectRevert(InvalidSigner.selector);
        oracle.depositFromPermit2(
            amount, beneficiary, wallet.addr, keccak256("a-different-intent"), _permit(amount, NONCE, deadline), sig
        );
        assertFalse(_nonceUsed(wallet.addr, NONCE), "nonce untouched");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Oracle-side guards reached before Permit2
    // ══════════════════════════════════════════════════════════════════

    /// @dev `permit.permitted.amount != amount` is rejected by the oracle itself, so the signer's
    ///      nonce is never even offered to Permit2.
    function test_amountMismatchIsRejectedBeforePermit2() public {
        uint128 amount = 500e18;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes memory sig = _sign65(
            wallet,
            _permit2DigestFull(
                address(collat), amount, NONCE, deadline, beneficiary, address(this), wallet.addr, INTENT
            )
        );

        vm.expectRevert(Errors.Permit2AmountMismatch.selector);
        oracle.depositFromPermit2(amount, beneficiary, wallet.addr, INTENT, _permit(amount + 1, NONCE, deadline), sig);
        assertFalse(_nonceUsed(wallet.addr, NONCE), "Permit2 was never reached");
    }

    function test_zeroBeneficiaryIsRejectedBeforePermit2() public {
        uint128 amount = 500e18;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes memory sig = _sign65(
            wallet,
            _permit2DigestFull(address(collat), amount, NONCE, deadline, address(0), address(this), wallet.addr, INTENT)
        );

        vm.expectRevert(Errors.AddressCannotBeZero.selector);
        oracle.depositFromPermit2(amount, address(0), wallet.addr, INTENT, _permit(amount, NONCE, deadline), sig);
        assertFalse(_nonceUsed(wallet.addr, NONCE), "Permit2 was never reached");
    }
}
