// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice transfer / transferFrom always revert.
contract RevertingToken is ERC20 {
    constructor() ERC20("Reverting", "RVT") { _mint(msg.sender, 1e30); }
    function transfer(address, uint256) public pure override returns (bool) { revert("RVT-transfer"); }
    function transferFrom(address, address, uint256) public pure override returns (bool) { revert("RVT-transferFrom"); }
}

/// @notice transfer / transferFrom return false without touching balances.
contract ReturnsFalseToken is ERC20 {
    constructor() ERC20("ReturnsFalse", "RFT") { _mint(msg.sender, 1e30); }
    function transfer(address, uint256) public pure override returns (bool) { return false; }
    function transferFrom(address, address, uint256) public pure override returns (bool) { return false; }
}

/// @notice USDT-style: transfer / transferFrom return no value.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 18;
    string public constant name = "NoReturn";
    string public constant symbol = "NRT";
    uint256 public totalSupply = 1e30;

    constructor() { balanceOf[msg.sender] = totalSupply; }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        require(balanceOf[from] >= amount, "bal");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice ERC20 whose transferFrom attempts a single best-effort reentry call into the configured target.
///         The reentry payload is intentionally inert (oracle.dust); invariants catch any state corruption.
contract ReentrantToken is ERC20 {
    address public target;
    bool public reentered;

    constructor(address _target) ERC20("Reentrant", "REN") {
        target = _target;
        _mint(msg.sender, 1e30);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool ok) {
        ok = super.transferFrom(from, to, amount);
        if (target != address(0) && !reentered) {
            reentered = true;
            (bool s,) = target.call(abi.encodeWithSignature("dust(address,address)", address(this), address(0)));
            s;
        }
    }
}

/// @notice Oracle settle() callback target with selectable adversarial modes.
contract AdversarialCallback {
    enum Mode { Noop, Revert, ConsumeAll, Reenter }

    Mode public mode;
    uint256 public calls;
    mapping(uint256 => bool) public called;
    mapping(uint256 => uint256) public lastGas;

    function setMode(Mode m) external { mode = m; }

    function openOracleCallback(
        uint256 reportId,
        uint256,
        uint256,
        uint256,
        address,
        address
    ) external {
        calls += 1;
        called[reportId] = true;
        lastGas[reportId] = gasleft();

        Mode m = mode;
        if (m == Mode.Revert) revert("CB-revert");
        if (m == Mode.ConsumeAll) {
            while (true) {
                assembly { mstore(0, 0) }
            }
        }
        if (m == Mode.Reenter) {
            (bool s,) = msg.sender.call(abi.encodeWithSignature("dust(address,address)", address(0), address(0)));
            s;
        }
    }
}
