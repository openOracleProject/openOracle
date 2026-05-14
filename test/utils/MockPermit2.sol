// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "../../src/interfaces/ISignatureTransfer.sol";

/**
 * @notice Permissive Permit2 mock for testing. Skips signature verification and
 *         nonce tracking. Pulls tokens via standard ERC20 allowance from `owner`
 *         to `transferDetails.to`. Tests must have `owner` approve this contract
 *         for the relevant token via the usual ERC20 approve.
 */
contract MockPermit2 is ISignatureTransfer {
    bytes32 public lastWitness;
    string public lastWitnessTypeString;
    address public lastOwner;
    uint256 public callCount;

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata /* signature */
    ) external {
        IERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata /* signature */
    ) external {
        lastWitness = witness;
        lastWitnessTypeString = witnessTypeString;
        lastOwner = owner;
        callCount += 1;
        IERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}
