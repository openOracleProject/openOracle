// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @notice A contract that genuinely owns and drives an OpenPunt position while it may refuse
 *         raw ETH.
 *
 * @dev Every protocol call is made by this contract, so it is the real `msg.sender` for
 *      `propose`, `close`, `cancelSwapOpen`, `withdraw`, `oracle.withdrawTo` and so on. Tests
 *      must not shortcut by naming this address as the swapper while an EOA does the calling.
 *
 *      `receive()` reverts while `rejectEth` is set, which is what forces OpenPunt's `payEth`
 *      and OpenOracle's `pushOrCredit` down their fallback-credit branches. Balances are funded
 *      with `vm.deal`, which does not invoke `receive()`.
 */
contract RejectingSwapper {
    bool public rejectEth = true;

    error EthRejected();

    receive() external payable {
        if (rejectEth) revert EthRejected();
    }

    function setRejectEth(bool value) external {
        rejectEth = value;
    }

    /// @dev Generic forwarder so this contract is the genuine caller. Reverts bubble up
    ///      verbatim, so `vm.expectRevert(selector)` still works through it.
    function exec(address target, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /// @dev ERC20 approve made by this contract, for Permit2 or the oracle.
    function approveToken(address token, address spender, uint256 amount) external {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "RejectingSwapper: approve failed");
    }
}
