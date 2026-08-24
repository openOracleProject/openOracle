// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "../../../src/interfaces/ISignatureTransfer.sol";

/**
 * @notice Permissive Permit2 stand-in that records everything the caller sent.
 *
 * @dev It records and forwards without validating. It does not check
 *      signatures, does not consume or reject nonces, and does not enforce deadlines.
 *      Tests may therefore assert *what OpenPunt/OpenOracle transmitted*, and must not
 *      claim signature validity, replay protection, or deadline enforcement from it.
 *      Those properties require the real Permit2 deployment.
 *
 *      No immutables and no constructor state: this contract's runtime code is installed
 *      at the canonical Permit2 address with `vm.etch`, which copies code but not storage.
 */
contract RecordingPermit2 is ISignatureTransfer {
    struct Call {
        address owner;
        address permittedToken;
        uint256 permittedAmount;
        uint256 nonce;
        uint256 deadline;
        address to;
        uint256 requestedAmount;
        bytes32 witness;
        string witnessTypeString;
        bytes signature;
        bool hadWitness;
    }

    uint256 public callCount;
    mapping(uint256 => Call) internal _calls;

    function lastCall() external view returns (Call memory) {
        require(callCount > 0, "RecordingPermit2: no calls");
        return _calls[callCount - 1];
    }

    function callAt(uint256 i) external view returns (Call memory) {
        require(i < callCount, "RecordingPermit2: out of range");
        return _calls[i];
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external {
        _record(permit, transferDetails, owner, bytes32(0), "", signature, false);
        _pull(permit.permitted.token, owner, transferDetails.to, transferDetails.requestedAmount);
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        _record(permit, transferDetails, owner, witness, witnessTypeString, signature, true);
        _pull(permit.permitted.token, owner, transferDetails.to, transferDetails.requestedAmount);
    }

    /// @dev SafeERC20-style pull that accepts either `true` or empty return data, so the
    ///      recorder can transport USDT-style no-return tokens. Real Permit2 supports those;
    ///      a plain `IERC20.transferFrom` here would have made the recorder the incompatible
    ///      party rather than the protocol.
    ///
    ///      This still records and forwards only. It proves nothing about signature validity,
    ///      nonce consumption, replay rejection, or deadline enforcement.
    function _pull(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(
            ok && (ret.length == 0 || abi.decode(ret, (bool))) && token.code.length > 0,
            "RecordingPermit2: transferFrom failed"
        );
    }

    function _record(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string memory witnessTypeString,
        bytes calldata signature,
        bool hadWitness
    ) internal {
        Call storage c = _calls[callCount++];
        c.owner = owner;
        c.permittedToken = permit.permitted.token;
        c.permittedAmount = permit.permitted.amount;
        c.nonce = permit.nonce;
        c.deadline = permit.deadline;
        c.to = transferDetails.to;
        c.requestedAmount = transferDetails.requestedAmount;
        c.witness = witness;
        c.witnessTypeString = witnessTypeString;
        c.signature = signature;
        c.hadWitness = hadWitness;
    }
}
