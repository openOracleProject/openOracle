// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @notice A token with the two awkward behaviours real USDT actually has, at the same time:
 *
 *         1. `transfer` / `transferFrom` return NO data.
 *         2. `approve` REVERTS when it would change a non-zero allowance to another non-zero
 *            value — the "must reset to zero first" rule.
 *
 *         It additionally caps how much allowance it will store and always decrements on spend, so
 *         an infinite approval genuinely runs down. That combination is what forces a SECOND
 *         approval to occur on a later call, which is the only way to reach `forceApprove`'s
 *         zero-then-set fallback. Without the cap, `type(uint256).max` would never be exhausted and
 *         the re-approval path would be unreachable in a test.
 *
 * @dev Deliberately hand-written rather than an OZ subclass — the missing return values and the
 *      reverting approve are the whole point. Balances are only ever created by `mint`.
 */
contract UsdtStyleERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    /// @notice The largest allowance this token will record, however much is requested.
    uint256 public immutable allowanceCap;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint256 allowanceCap_) {
        name = name_;
        symbol = symbol_;
        allowanceCap = allowanceCap_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev The USDT rule: a non-zero -> non-zero change is refused outright.
    function approve(address spender, uint256 amount) external returns (bool) {
        uint256 current = allowance[msg.sender][spender];
        require(amount == 0 || current == 0, "UsdtStyleERC20: unsafe approve");

        allowance[msg.sender][spender] = amount > allowanceCap ? allowanceCap : amount;
        emit Approval(msg.sender, spender, allowance[msg.sender][spender]);
        return true;
    }

    /// @dev No return value, by design.
    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    /// @dev No return value, by design. Always decrements — there is no infinite-allowance shortcut.
    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "UsdtStyleERC20: allowance");
        allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "UsdtStyleERC20: balance");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
