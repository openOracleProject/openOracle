// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @notice Contract-account actors for the dispute helper suites.
 *
 * @dev None of these mocks any contract under test. `ContractDisputer` is a caller — it becomes
 *      `msg.sender` for a real `disputeWithRoute` call, which is the only way to reach the
 *      helper's ETH-refund failure path, since an EOA always accepts ETH. `ReentrantERC20` is a
 *      token, and a token is allowed to do anything during a transfer; that is precisely the
 *      hostile-callback surface being tested.
 */

/// @notice A contract caller whose willingness to receive ETH can be switched off.
contract ContractDisputer {
    bool public acceptEth = true;

    /// @notice Number of times `receive` was entered, so tests can tell "refund refused" apart
    ///         from "no refund was attempted".
    uint256 public ethReceipts;

    function setAcceptEth(bool value) external {
        acceptEth = value;
    }

    function approveToken(address token, address spender, uint256 amount) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }

    /// @notice Calls `target` with `payload`, forwarding `value`, and bubbles any revert verbatim so
    ///         tests can assert on the helper's own error selectors.
    function fire(address target, uint256 value, bytes calldata payload) external payable {
        (bool ok, bytes memory ret) = target.call{value: value}(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    receive() external payable {
        ++ethReceipts;
        require(acceptEth, "ContractDisputer: ETH refused");
    }
}

/// @notice An ERC20 that re-enters an arbitrary target from inside `transferFrom` / `transfer`.
/// @dev Models a hostile or hook-bearing token. Balances only ever come from `mint`.
contract ReentrantERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    bytes public payload;
    bool public onTransferFrom;
    bool public onTransfer;

    bool public fired;
    bool public reenterSucceeded;
    bytes4 public reenterErrorSelector;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function arm(address target_, bytes calldata payload_, bool onTransferFrom_, bool onTransfer_) external {
        target = target_;
        payload = payload_;
        onTransferFrom = onTransferFrom_;
        onTransfer = onTransfer_;
        fired = false;
        reenterSucceeded = false;
        reenterErrorSelector = bytes4(0);
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

    function transfer(address to, uint256 amount) external returns (bool) {
        if (onTransfer) _reenter();
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (onTransferFrom) _reenter();
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ReentrantERC20: allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    /// @dev The re-entry is attempted but its failure is SWALLOWED, so the outer call continues.
    ///      That is deliberate: if the nested call reverted the whole transaction, a test could not
    ///      distinguish "the guard held" from "the token simply broke the transfer".
    function _reenter() internal {
        if (fired || target == address(0)) return;
        fired = true;
        (bool ok, bytes memory ret) = target.call(payload);
        reenterSucceeded = ok;
        if (!ok && ret.length >= 4) reenterErrorSelector = bytes4(ret);
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ReentrantERC20: balance");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}

/// @notice Deploys arbitrary creation bytecode at a CREATE2 address, so a Uniswap V4 hook can be
///         placed at an address whose low bits encode its permissions.
contract Create2Factory {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        require(deployed != address(0), "Create2Factory: deploy failed");
    }

    function addressOf(bytes32 codeHash, bytes32 salt) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
    }
}
