// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "./interfaces/IOpenOracle2.sol";

/* ------------ Oracle Fee Receiver (Compatible with Clone) ------------ */

contract oracleFeeReceiver {
    error FeesExceedUint128();

    IOpenOracle2 public oracle;

    address public swapper;
    address public matcher;
    address public token1;
    address public token2;
    uint128 public gameId;
    bool private initialized;

    constructor() {
        initialized = true;
    }

    function initialize(
        uint128 _gameId,
        address _oracle,
        address _token1,
        address _token2,
        address _swapper,
        address _matcher
    ) external {
        require(!initialized);
        initialized = true;
        gameId = _gameId;
        oracle = IOpenOracle2(_oracle);
        token1 = _token1;
        token2 = _token2;
        swapper = _swapper;
        matcher = _matcher;
    }

    /**
     * @notice Distributes oracle-game protocol fees 50/50 between swapper and matcher.
     *         Permissionless. Uses internal transfers only.
     *         Recipients withdraw from their oracle internal balance on their own schedule.
     */
    function distribute() external returns (uint256 fees1, uint256 fees2) {
        fees1 = _distributeToken(token1);
        fees2 = _distributeToken(token2);
    }

    function _distributeToken(address token) internal returns (uint256) {
        uint256 bal = oracle.tokenHolder(address(this), token);
        if (bal <= 1) return 0;
        uint256 spendable = bal - 1;
        uint256 swapperPiece = spendable / 2;
        uint256 matcherPiece = spendable - swapperPiece;
        if (matcherPiece > type(uint128).max) revert FeesExceedUint128();
        oracle.internalTransferFrom(address(this), swapper, token, uint128(swapperPiece));
        oracle.internalTransferFrom(address(this), matcher, token, uint128(matcherPiece));
        return spendable;
    }
}
