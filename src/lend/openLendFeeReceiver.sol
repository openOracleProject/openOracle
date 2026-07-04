// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/* ------ Oracle Fee Receiver (Solady clone with immutable args) ------ */

// Per-liquidation fee splitter. No storage, no initialize. openLend deploys one clone per report:
//   args = abi.encodePacked(lendingId, token1, token2, borrower, lender, liquidator)
//   offsets:                0..32      32..52  52..72  72..92    92..112 112..132
//   feeReceiver = LibClone.cloneDeterministic(impl, args, bytes32(reportId));
// Predict with LibClone.predictDeterministicAddress(impl, args, bytes32(reportId), openLend).
// The only external calls are to the trusted oracle, whose functions are storage-only.
contract oracleFeeReceiver {
    // Immutables live in the implementation's code and are shared by all clones.
    IOpenOracle2 public immutable ORACLE;
    address private immutable SELF;

    event FeesDistributed(uint256 indexed lendingId, uint256 fees1, uint256 fees2);

    error NotClone();

    constructor(IOpenOracle2 _oracle) {
        ORACLE = _oracle;
        SELF = address(this);
    }

    function lendingId() public view returns (uint256) {
        return uint256(bytes32(LibClone.argsOnClone(address(this), 0, 32)));
    }

    function token1() public view returns (address) {
        return address(bytes20(LibClone.argsOnClone(address(this), 32, 52)));
    }

    function token2() public view returns (address) {
        return address(bytes20(LibClone.argsOnClone(address(this), 52, 72)));
    }

    function borrower() public view returns (address) {
        return address(bytes20(LibClone.argsOnClone(address(this), 72, 92)));
    }

    function lender() public view returns (address) {
        return address(bytes20(LibClone.argsOnClone(address(this), 92, 112)));
    }

    function liquidator() public view returns (address) {
        return address(bytes20(LibClone.argsOnClone(address(this), 112, 132)));
    }

    /// @notice Splits this clone's accumulated oracle-game fees between the snapshot beneficiaries.
    ///         Callable by anyone.
    function distribute() external returns (uint256 fees1, uint256 fees2) {
        if (address(this) == SELF) revert NotClone(); // args only exist on clones

        fees1 = _distributeToken(token1());
        fees2 = _distributeToken(token2());
        if (fees1 == 0 && fees2 == 0) return (0, 0);
        emit FeesDistributed(lendingId(), fees1, fees2);
    }

    function _distributeToken(address token) internal returns (uint256) {
        uint256 bal = ORACLE.tokenHolder(address(this), token);
        if (bal <= 1) return 0; // preserve the oracle's virtual 1-unit sentinel
        uint256 spendable = bal - 1;
        // uint128 cap per sweep; any excess is collectable by calling distribute again.
        uint256 collected = spendable > type(uint128).max ? type(uint128).max : spendable;

        uint256 borrowerPiece = collected / 2;
        uint256 lenderPiece = borrowerPiece / 2;
        uint256 liquidatorPiece = collected - borrowerPiece - lenderPiece;

        if (borrowerPiece > 0) ORACLE.internalTransferFrom(address(this), borrower(), token, uint128(borrowerPiece));
        if (lenderPiece > 0) ORACLE.internalTransferFrom(address(this), lender(), token, uint128(lenderPiece));
        if (liquidatorPiece > 0) {
            ORACLE.internalTransferFrom(address(this), liquidator(), token, uint128(liquidatorPiece));
        }
        return collected;
    }
}
