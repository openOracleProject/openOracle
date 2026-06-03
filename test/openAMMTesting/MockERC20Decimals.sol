// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 with a configurable `decimals()` so we can model 6-decimal USDC.
contract MockERC20Decimals is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
        _mint(msg.sender, 1_000_000_000 * 10 ** dec_);
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}
