// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice An ERC777-style hook token: it calls a configured target from inside `transfer` and
 *         `transferFrom`.
 *
 * @dev Hook tokens are unsupported economically by OpenPunt, but remain callable token addresses
 *      address, so it is the right instrument for modelling every token-bearing callback boundary
 *      under unbounded gas. OpenPunt's ERC20 refunds and payouts run through
 *      `oracle.pushOrCredit`, whose gas limit applies only to the ETH branch, and its funding
 *      callbacks run through Permit2/`transferFrom`. All of these forward essentially all
 *      remaining gas through real production code.
 *
 *      The hook fires before the balance movement, allowing a
 *      test observe protocol state during the window between OpenPunt's own writes and the
 *      collateral actually arriving.
 */
contract HookERC20 is ERC20 {
    address public hookTarget;
    bytes public hookPayload;
    bool public hookArmed;
    bool public hookOnTransferFrom = true;
    bool public bubbleHookRevert;

    uint256 public hookCount;
    bool public lastHookOk;
    bytes public lastHookReturndata;

    bool internal inHook;

    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function armHook(address target_, bytes calldata payload_) external {
        hookTarget = target_;
        hookPayload = payload_;
        hookArmed = true;
    }

    function disarmHook() external {
        hookArmed = false;
        bubbleHookRevert = false;
    }

    function setBubbleHookRevert(bool v) external {
        bubbleHookRevert = v;
    }

    function resetHook() external {
        hookCount = 0;
        lastHookOk = false;
        lastHookReturndata = "";
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (hookOnTransferFrom) _fire();
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _fire();
        return super.transfer(to, amount);
    }

    function _fire() internal {
        if (!hookArmed || inHook) return;
        inHook = true;
        hookCount++;
        (bool ok, bytes memory ret) = hookTarget.call(hookPayload);
        lastHookOk = ok;
        lastHookReturndata = ret;
        inHook = false;
        if (!ok && bubbleHookRevert) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function lastHookSelector() external view returns (bytes4) {
        bytes memory r = lastHookReturndata;
        if (r.length < 4) return bytes4(0);
        return bytes4(r[0]) | (bytes4(r[1]) >> 8) | (bytes4(r[2]) >> 16) | (bytes4(r[3]) >> 24);
    }
}

/**
 * @notice Reads OpenPunt state when called, so a hook can capture the exact protocol state
 *         visible during a funding callback in a single payload.
 */
interface IPuntView {
    function swaps(uint256) external view returns (bytes32);
    function closeAuctions(uint256)
        external
        view
        returns (uint128, uint128, uint128, uint48, uint24, uint16, uint16, uint8, bool);
    function closeRequestBlock(uint256) external view returns (uint48);
    function nextSwapId() external view returns (uint256);
}

contract CloseWindowObserver {
    bool public observed;
    bytes32 public swapHash;
    bytes32 public dutchHash;
    uint128 public pendingComp;
    bool public intent;
    uint256 public nextSwapId;

    function observe(address punt_, uint256 swapId) external {
        IPuntView p = IPuntView(punt_);
        observed = true;
        swapHash = p.swaps(swapId);
        uint128 maxReward;
        (maxReward,, pendingComp,,,,,,) = p.closeAuctions(swapId);
        dutchHash = bytes32(uint256(maxReward));
        intent = p.closeRequestBlock(swapId) != 0;
        nextSwapId = p.nextSwapId();
    }

    function reset() external {
        observed = false;
        swapHash = bytes32(0);
        dutchHash = bytes32(0);
        pendingComp = 0;
        intent = false;
        nextSwapId = 0;
    }
}
