// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrantHook} from "../utils/ReentrantHook.sol";

/// @notice Verifies the terminal-deletion + nonReentrant defenses fire when a
///         malicious swapper re-enters openSwap from inside payEth's ETH transfer.
///
///         Coverage matrix:
///           cancel → cancel  : blocked by nonReentrant
///           cancel → execute : blocked by deleted hash (WrongHash)
///           cancel → bailOut : blocked by nonReentrant
///
///         All three demonstrate that no reentrant call to swap-mutating functions
///         can observe state where the swap hash is still live AND the outer call
///         hasn't completed.
contract OpenSwapReentrancyTest is SlimTestBase {
    ReentrantHook internal hook;

    function setUp() public {
        _baseDeploy();
        _fundAccounts();
        _setupMatcherInternalBalance(matcher, 100e18, 100_000e18);

        // Deploy the malicious swapper and prime its token + permit2 approvals.
        hook = new ReentrantHook();
        sellToken.transfer(address(hook), 100e18);
        vm.deal(address(hook), 10 ether);
        vm.prank(address(hook));
        IERC20(address(sellToken)).approve(PERMIT2, type(uint256).max);
    }

    function _hookPropose() internal returns (uint256 swapId, uint48 expiration) {
        expiration = uint48(block.timestamp + 1 hours);
        proposeTs = uint48(block.timestamp);
        proposeUseInternal = false;
        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        vm.prank(address(hook));
        swapId = SwapCompat.proposeRaw(
            swapContract,
            ethToSend,
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(),
            false
        );
    }

    /// @dev Read the most recent ReentryResult event's returnData and return its 4-byte
    ///      selector (or zero if returnData is shorter than 4 bytes). Tests must wrap
    ///      the outer call in vm.recordLogs() before calling this.
    function _lastReentryRevertSelector() internal returns (bytes4) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReentryResult(bool,bytes)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (l.topics.length >= 1 && l.topics[0] == sig) {
                (, bytes memory data) = abi.decode(l.data, (bool, bytes));
                if (data.length >= 4) return bytes4(data);
                return bytes4(0);
            }
        }
        revert("no ReentryResult event");
    }

    function _buildCancelData(uint256 swapId, uint48 expiration) internal view returns (bytes memory) {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        s.swapper = address(hook);
        return abi.encodeCall(swapContract.cancelSwap, (swapId, s, m));
    }

    // ── cancel → cancel : nonReentrant guard ───────────────────────────────────
    function testReentry_CancelDuringPayEth_CannotRecancel() public {
        (uint256 swapId, uint48 expiration) = _hookPropose();
        bytes memory cancelCalldata = _buildCancelData(swapId, expiration);

        // Arm the hook to re-enter cancelSwap when receive() fires.
        hook.arm(address(swapContract), cancelCalldata);

        // Outer cancel: payEth(hook, gasComp+settlerReward) triggers hook.receive().
        vm.prank(address(hook));
        (bool outerOk,) = address(swapContract).call(cancelCalldata);

        assertTrue(outerOk, "outer cancel must succeed");
        assertTrue(hook.attempted(), "hook receive() must have attempted reentry");
        assertFalse(hook.attemptOk(), "reentrant cancel must fail (nonReentrant)");
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted by outer cancel");
    }

    // ── cancel → execute : terminal deletion ──────────────────────────────────
    function testReentry_CancelDuringPayEth_CannotExecuteDeletedSwap() public {
        (uint256 swapId, uint48 expiration) = _hookPropose();
        bytes memory cancelCalldata = _buildCancelData(swapId, expiration);

        // Build an execute() reentry payload. We never matched the swap, so a
        // MatchedSwap struct won't actually exist on-chain — but execute()'s hash
        // check fires first and reads swaps[swapId] (which is 0 after delete).
        // Any non-empty MatchedSwap → WrongHash().
        openSwapV2.MatchedSwap memory dummyMatched;
        dummyMatched.swapper = address(hook); // any non-zero field; not used past hash check
        IOpenOracle2.OracleGame memory dummyOg;
        IOpenOracle2.PreimageHelper memory dummyPh;
        bytes memory executeCalldata = abi.encodeCall(
            swapContract.execute, (swapId, dummyMatched, dummyOg, dummyPh, false)
        );

        hook.arm(address(swapContract), executeCalldata);

        vm.recordLogs();
        vm.prank(address(hook));
        (bool outerOk,) = address(swapContract).call(cancelCalldata);

        assertTrue(outerOk, "outer cancel must succeed");
        assertTrue(hook.attempted(), "hook receive() must have attempted reentry");
        assertFalse(hook.attemptOk(), "reentrant execute must fail (WrongHash on deleted swap)");
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted");
        assertEq(_lastReentryRevertSelector(), bytes4(keccak256("WrongHash()")), "reentry reverted with WrongHash()");
    }

    // ── cancel → bailOut : nonReentrant guard ──────────────────────────────────
    function testReentry_CancelDuringPayEth_CannotBailOut() public {
        (uint256 swapId, uint48 expiration) = _hookPropose();
        bytes memory cancelCalldata = _buildCancelData(swapId, expiration);

        // Any MatchedSwap (even uninitialized) will trigger nonReentrant before its
        // hash check would run, since the lock is acquired at the top of bailOut().
        openSwapV2.MatchedSwap memory dummyMatched;
        bytes memory bailOutCalldata = abi.encodeCall(swapContract.bailOut, (swapId, dummyMatched));

        hook.arm(address(swapContract), bailOutCalldata);

        vm.prank(address(hook));
        (bool outerOk,) = address(swapContract).call(cancelCalldata);

        assertTrue(outerOk, "outer cancel must succeed");
        assertTrue(hook.attempted(), "hook receive() must have attempted reentry");
        assertFalse(hook.attemptOk(), "reentrant bailOut must fail (nonReentrant)");
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted by outer cancel");
    }
}
