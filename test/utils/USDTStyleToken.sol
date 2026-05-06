// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev A mock token whose approve/transfer/transferFrom return *no value* — like
/// real USDT on Ethereum mainnet. Used to verify whether contracts under test
/// support the documented "USDT-style" token class.
contract USDTStyleToken {
    string public name = "USDT-Style";
    string public symbol = "USDT";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _supply) {
        decimals = 18;
        totalSupply = _supply;
        balanceOf[msg.sender] = _supply;
    }

    // Note: NO `returns (bool)` — emulates USDT's missing return value.
    function approve(address spender, uint256 value) public {
        allowance[msg.sender][spender] = value;
    }

    function transfer(address to, uint256 value) public {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
    }

    function transferFrom(address from, address to, uint256 value) public {
        allowance[from][msg.sender] -= value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}
