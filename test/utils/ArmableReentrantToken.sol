// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 whose transfer / transferFrom re-enter an armed target with an armed payload.
///         Unlike the fixed `ReentrantToken` (which only re-enters with a hardcoded inert
///         `oracle.dust(...)` AFTER the balance has moved), this token is armable like
///         `ReentrantHook` is on the ETH-`receive` side: the caller supplies an arbitrary
///         target + calldata, AND chooses the trigger point relative to the underlying
///         balance move.
///
///         The trigger-point flag is the important part. The oracle's `deposit` credits the
///         beneficiary's internal balance BEFORE pulling tokens (a deliberate
///         credit-before-transfer ordering). A reentry that fires AFTER `super.transferFrom`
///         sees a consistent snapshot (credit present AND backing tokens present) and proves
///         nothing about that window. Firing BEFORE the balance moves is the only way to land
///         inside the genuine "credited internally, real tokens not yet in" interleaving.
///
///         A one-shot latch (`attempted`) bounds recursion depth to a single reentry per outer
///         call. The reentry's success/return-data is captured (and emitted) rather than stored
///         in a way that reverts the outer transfer — a reverting reentry must not break the
///         legitimate transfer it rode in on.
contract ArmableReentrantToken is ERC20 {
    address public reentryTarget;
    bytes public reentryPayload;
    bool public triggerBeforeTransfer; // true: re-enter before the balance moves
    bool public armed;

    bool public attempted;
    bool public lastCallOk;
    bytes public lastReturnData;

    event ReentryAttempt(bool ok, bytes ret);

    constructor() ERC20("ArmableReentrant", "ARM") {
        _mint(msg.sender, 1e30);
    }

    /// @param target   contract to re-enter (typically the oracle)
    /// @param payload  raw calldata for the reentrant call
    /// @param before_  fire the reentry before (true) or after (false) the underlying balance move
    function arm(address target, bytes calldata payload, bool before_) external {
        reentryTarget = target;
        reentryPayload = payload;
        triggerBeforeTransfer = before_;
        armed = true;
        attempted = false;
        lastCallOk = false;
        delete lastReturnData;
    }

    function disarm() external {
        armed = false;
        reentryTarget = address(0);
        delete reentryPayload;
        attempted = false;
    }

    function _maybeReenter() internal {
        if (!armed || attempted || reentryTarget == address(0) || reentryPayload.length == 0) return;
        attempted = true;
        (bool ok, bytes memory ret) = reentryTarget.call(reentryPayload);
        lastCallOk = ok;
        lastReturnData = ret;
        emit ReentryAttempt(ok, ret);
    }

    function transfer(address to, uint256 amount) public override returns (bool ok) {
        if (triggerBeforeTransfer) _maybeReenter();
        ok = super.transfer(to, amount);
        if (!triggerBeforeTransfer) _maybeReenter();
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool ok) {
        if (triggerBeforeTransfer) _maybeReenter();
        ok = super.transferFrom(from, to, amount);
        if (!triggerBeforeTransfer) _maybeReenter();
    }
}
