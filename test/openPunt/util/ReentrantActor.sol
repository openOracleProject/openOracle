// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @notice A contract that genuinely participates in OpenPunt — as swapper, matcher, reporter,
 *         executor or payout recipient — and fires one configured reentrant payload from inside
 *         its callback.
 *
 * @dev Every callback boundary is modelled as though the recipient receives all
 *      remaining gas. The security properties this fixture exists to test are state ordering,
 *      commitment revalidation and entitlement consumption — never affordability. Nothing here is
 *      shaped to fit under a gas stipend, and no test may conclude "unreachable" from a payload
 *      being expensive.
 *
 *      The reentrant payloads are therefore driven through OpenPunt's genuinely unbounded
 *      production paths: ERC20 refunds and payouts via `oracle.pushOrCredit` (whose gas limit
 *      applies only to the ETH branch), ERC20/Permit2 funding callbacks, and `withdraw()`.
 *
 *      `inCallback` prevents the payload from re-arming itself into accidental recursion.
 *      `bubbleInnerRevert` chooses between swallowing the inner failure so the outer transition
 *      completes, and propagating it so the outer transaction rolls back entirely.
 */
contract ReentrantActor {
    // ── configuration ───────────────────────────────────────────────────
    address public target;
    bytes public payload;
    uint256 public payloadValue;
    bool public armed;
    bool public bubbleInnerRevert;
    bool public rejectEth;

    // ── observations ────────────────────────────────────────────────────
    uint256 public callbackCount;
    uint256 public lastValueObserved;
    bool public lastInnerOk;
    bytes public lastInnerReturndata;
    bool public payloadExecuted;

    bool internal inCallback;

    error EthRejected();
    error InnerReverted(bytes data);

    // ── configuration ───────────────────────────────────────────────────

    function arm(address target_, bytes calldata payload_, uint256 value_) external {
        target = target_;
        payload = payload_;
        payloadValue = value_;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function setBubbleInnerRevert(bool v) external {
        bubbleInnerRevert = v;
    }

    function setRejectEth(bool v) external {
        rejectEth = v;
    }

    function resetObservations() external {
        callbackCount = 0;
        lastValueObserved = 0;
        lastInnerOk = false;
        lastInnerReturndata = "";
        payloadExecuted = false;
    }

    // ── acting as a normal participant ──────────────────────────────────

    function exec(address to, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function approveToken(address token, address spender, uint256 amount) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }

    /// @dev Lets a test move the actor's own tokens, e.g. to zero its balance before a probe.
    function sendToken(address token, address to, uint256 amount) external {
        (bool ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer failed");
    }

    // ── the callback ────────────────────────────────────────────────────

    receive() external payable {
        _fire(msg.value);
    }

    fallback() external payable {
        _fire(msg.value);
    }

    /// @dev ERC20 hook tokens call this directly rather than transferring ETH.
    function onTokenMoved() external {
        _fire(0);
    }

    function _fire(uint256 value) internal {
        callbackCount++;
        lastValueObserved = value;

        if (rejectEth) revert EthRejected();
        if (inCallback || !armed) return;

        inCallback = true;
        payloadExecuted = true;
        (bool ok, bytes memory ret) = target.call{value: payloadValue}(payload);
        lastInnerOk = ok;
        lastInnerReturndata = ret;
        inCallback = false;

        if (!ok && bubbleInnerRevert) revert InnerReverted(ret);
    }

    // ── observation helpers ─────────────────────────────────────────────

    function lastInnerSelector() external view returns (bytes4) {
        bytes memory r = lastInnerReturndata;
        if (r.length < 4) return bytes4(0);
        return bytes4(r[0]) | (bytes4(r[1]) >> 8) | (bytes4(r[2]) >> 16) | (bytes4(r[3]) >> 24);
    }

    function lastInnerReturndataLength() external view returns (uint256) {
        return lastInnerReturndata.length;
    }

    function lastInnerWord() external view returns (uint256) {
        bytes memory r = lastInnerReturndata;
        if (r.length < 32) return type(uint256).max;
        uint256 w;
        assembly {
            w := mload(add(r, 0x20))
        }
        return w;
    }
}
