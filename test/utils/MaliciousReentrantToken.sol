// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/OpenOracle.sol";

/// @dev Token whose internal _update hook (fired by both transfer and transferFrom)
/// triggers a one-shot oracle.settle call. Used to reproduce reentrancy-grief
/// shapes where an attacker uses a hook-bearing token to fire the settle
/// callback while another openSwap function holds its lock.
contract MaliciousReentrantToken is ERC20 {
    OpenOracle public oracle;
    uint256 public targetReportId;
    bool public hookArmed;

    constructor() ERC20("Malicious", "MAL") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function armHook(OpenOracle _oracle, uint256 _reportId) external {
        oracle = _oracle;
        targetReportId = _reportId;
        hookArmed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookArmed) {
            hookArmed = false;
            oracle.settle(targetReportId);
        }
    }
}
