// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "./interfaces/IOpenOracle2.sol";
import {IERC20}      from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}   from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/* ------------ Oracle Fee Receiver (Compatible with Clone) ------------ */

contract oracleFeeReceiver is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IOpenOracle2 public oracle;

    address public owner;
    address public token1;
    address public token2;
    uint128 public gameId;
    bool private initialized;

    error FeesExceedUint128();

    constructor() {                                                                                                                                                                                                                  
        initialized = true;                                                                                                                                                                                                          
    }

    function initialize(address _owner, uint128 _gameId, address _oracle, address _token1, address _token2) external {
        require(!initialized);
        initialized = true;
        owner = _owner;
        gameId = _gameId;
        oracle = IOpenOracle2(_oracle);
        token1 = _token1;
        token2 = _token2;
    }

    function collect() external nonReentrant returns (uint256 fees1, uint256 fees2) {
        require(msg.sender == owner);
        fees1 = _distributeToken(token1);
        fees2 = _distributeToken(token2);
    }

    function _distributeToken(address token) internal returns (uint256) {
        uint256 bal = oracle.tokenHolder(address(this), token);
        if (bal <= 1) return 0;
        uint256 spendable = bal - 1;
        uint256 collected = spendable > type(uint128).max ? type(uint128).max : spendable;
        oracle.internalTransferFrom(address(this), owner, token, uint128(collected));
        return collected;
    }
}
