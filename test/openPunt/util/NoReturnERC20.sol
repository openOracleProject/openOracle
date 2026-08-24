// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @notice USDT-style ERC20: real balance and allowance accounting, but `transfer` and
 *         `transferFrom` return no data.
 *
 * @dev This is not an OZ ERC20 subclass because the transfer functions omit return values.
 *      Everything else behaves normally: `balanceOf`, `allowance` and `approve` are ordinary,
 *      and funding happens through real `mint`/`transfer` calls so no test ever needs to write
 *      a balance slot.
 *
 *      This models a supported token shape. It is not fee-on-transfer, not rebasing, and has no
 *      transfer hooks; those remain explicitly unsupported.
 */
contract NoReturnERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev No return value, by design.
    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    /// @dev No return value, by design.
    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "NoReturnERC20: allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "NoReturnERC20: balance");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
