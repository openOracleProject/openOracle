// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @title OpenPuntFeeReceiver
/// @notice Counterfactual, permissionlessly deployed fee receiver for one OpenPunt position.
/// @dev Clone immutable args are packed as:
///      `swapId | token1 | token2 | swapper | matcher`.
contract OpenPuntFeeReceiver {
    IOpenOracle2 public immutable ORACLE;
    address private immutable SELF;

    event FeesDistributed(uint256 indexed swapId, uint256 fees1, uint256 fees2);

    error NotClone();

    /// @dev Deploys the implementation and binds the OpenOracle instance used by every clone.
    /// @param oracle_ OpenOracle contract holding the receiver's internal fee balances.
    constructor(IOpenOracle2 oracle_) {
        ORACLE = oracle_;
        SELF = address(this);
    }

    /// @notice Returns the position identifier encoded in this clone.
    /// @return Position identifier.
    function swapId() public view returns (uint256) {
        return uint256(bytes32(LibClone.argsOnClone(address(this), 0, 32)));
    }

    /// @notice Returns the first oracle token encoded in this clone.
    /// @return First oracle token.
    function token1() public view returns (address) {
        return address(bytes20(LibClone.argsOnClone(address(this), 32, 52)));
    }

    /// @notice Returns the second oracle token encoded in this clone.
    /// @return Second oracle token.
    function token2() public view returns (address) {
        return address(bytes20(LibClone.argsOnClone(address(this), 52, 72)));
    }

    /// @notice Returns the position's swapper encoded in this clone.
    /// @return Swapper address.
    function swapper() public view returns (address) {
        return address(bytes20(LibClone.argsOnClone(address(this), 72, 92)));
    }

    /// @notice Returns the position's matcher encoded in this clone.
    /// @return Matcher address.
    function matcher() public view returns (address) {
        return address(bytes20(LibClone.argsOnClone(address(this), 92, 112)));
    }

    /// @notice Splits all currently spendable oracle fees equally between swapper and matcher.
    /// @dev Permissionless. A uint128-sized tranche is distributed per token per call, and the
    ///      oracle's virtual one-unit balance sentinel is preserved.
    /// @return fees1 Amount of token1 distributed in this call.
    /// @return fees2 Amount of token2 distributed in this call.
    function distribute() external returns (uint256 fees1, uint256 fees2) {
        if (address(this) == SELF) revert NotClone();

        fees1 = _distributeToken(token1());
        fees2 = _distributeToken(token2());
        if (fees1 != 0 || fees2 != 0) emit FeesDistributed(swapId(), fees1, fees2);
    }

    /// @dev Distributes one uint128-sized tranche of a token, with odd units assigned to the matcher.
    /// @param token Oracle-ledger token to distribute.
    /// @return collected Total amount distributed for the token.
    function _distributeToken(address token) internal returns (uint256 collected) {
        uint256 balance = ORACLE.tokenHolder(address(this), token);
        if (balance <= 1) return 0;

        uint256 spendable = balance - 1;
        collected = spendable > type(uint128).max ? type(uint128).max : spendable;

        uint256 swapperPiece = collected / 2;
        uint256 matcherPiece = collected - swapperPiece;
        if (swapperPiece != 0) {
            ORACLE.internalTransferFrom(address(this), swapper(), token, uint128(swapperPiece));
        }
        ORACLE.internalTransferFrom(address(this), matcher(), token, uint128(matcherPiece));
    }
}
