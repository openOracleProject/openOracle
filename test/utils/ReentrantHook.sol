// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Reentrancy probe used as the swapper. receive() conditionally re-enters
///         the armed target with the stored payload. The return data is emitted as
///         an event (not stored) so the post-call SSTORE doesn't blow the 50k gas
///         budget that payEth / pushOrCredit allow for receive().
///
///         Tests use vm.recordLogs() + decode ReentryResult to read the revert
///         reason. The two bool slots (attempted, attemptOk) are cheap to store
///         and provide a fast path for assertions.
contract ReentrantHook {
    address public target;
    bytes public reentryPayload;
    bool public attempted;
    bool public attemptOk;

    /// @notice Emitted once per reentry attempt. `returnData` is the raw bytes the
    ///         inner CALL returned (typically a 4-byte custom-error selector on revert,
    ///         or empty bytes on success / type-decode revert).
    event ReentryResult(bool ok, bytes returnData);

    function arm(address _target, bytes calldata _payload) external {
        target = _target;
        reentryPayload = _payload;
        attempted = false;
        attemptOk = false;
    }

    function disarm() external {
        target = address(0);
        delete reentryPayload;
        attempted = false;
        attemptOk = false;
    }

    receive() external payable {
        if (target == address(0) || reentryPayload.length == 0 || attempted) return;
        attempted = true;
        (bool ok, bytes memory data) = target.call(reentryPayload);
        attemptOk = ok;
        emit ReentryResult(ok, data);
    }
}
