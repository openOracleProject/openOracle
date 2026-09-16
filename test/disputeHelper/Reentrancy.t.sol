// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase, IV4Liquidity} from "./DisputeHelperBase.t.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";
import {ReentrantERC20, Create2Factory} from "./util/Actors.sol";

/**
 * @notice Hostile callbacks from inside an opaque route: a real Uniswap V4 hook, and a token that
 *         re-enters from `transferFrom` and `transfer`.
 *
 * @dev WHY THIS SURFACE EXISTS. `disputeWithRoute` hands control to code the caller chose, twice
 *      over: the router plan is arbitrary, and the tokens involved are arbitrary. A V4 pool's hook
 *      runs INSIDE the swap, and an ERC20's transfer hooks run inside the helper's own pulls and
 *      refunds. At those moments the helper is mid-flight — funds pulled, approvals granted,
 *      dispute not yet submitted.
 *
 *      WHAT STOPS IT. `nonReentrant` on `disputeWithRoute`. These tests do not assert that a nested
 *      call is "too expensive" or "unlikely"; the callbacks are given a full re-entry attempt with
 *      all remaining gas and their outcome is read back explicitly.
 *
 *      HOW FAILURE IS OBSERVED. Each hostile contract SWALLOWS the nested revert and records it.
 *      If it bubbled the revert instead, a passing test could not distinguish "the guard held" from
 *      "the callback broke the transfer for unrelated reasons". Every test therefore asserts three
 *      things: the callback actually fired, the nested call failed, and it failed with
 *      `ReentrancyGuardReentrantCall` specifically.
 */
contract ReentrancyTest is DisputeHelperBase {
    uint128 internal constant NEW_AMOUNT_1 = 1.1e18;
    uint256 internal constant REQUIRED_1 = 2.1004e18;

    /// @dev OpenZeppelin ReentrancyGuard's error.
    bytes4 internal constant REENTRANT_CALL = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    /// @dev v4-core `Hooks.BEFORE_SWAP_FLAG` is `1 << 7`, and the low 14 bits of a hook's ADDRESS
    ///      declare its permissions. A hook that only implements beforeSwap must therefore live at
    ///      an address whose low 14 bits are exactly 0x0080.
    uint160 internal constant HOOK_FLAG_MASK = uint160((1 << 14) - 1);
    uint160 internal constant BEFORE_SWAP_FLAG = uint160(1 << 7);

    Create2Factory internal create2;
    address internal hook;

    ReentrantERC20 internal evilToken;

    function setUp() public override {
        super.setUp();

        create2 = new Create2Factory();
        hook = _deployMinedHook();
        _seedHookedV4Pool(address(tokenC), address(tokenA), hook);

        evilToken = new ReentrantERC20("Reentrant", "EVIL");
        evilToken.mint(disputer, 1_000_000e18);
        evilToken.mint(reporter, 1_000_000e18);
        vm.prank(disputer);
        evilToken.approve(address(helper), type(uint256).max);
        vm.prank(reporter);
        evilToken.approve(address(oracle), type(uint256).max);
    }

    // ────────────────────────────────────────────────────────────────────
    //  V4 hook
    // ────────────────────────────────────────────────────────────────────

    function test_theMinedHookAddressReallyEncodesBeforeSwap() public view {
        assertEq(uint160(hook) & HOOK_FLAG_MASK, BEFORE_SWAP_FLAG, "hook address does not declare beforeSwap only");
        assertGt(hook.code.length, 0, "hook has no code");
    }

    /// @dev A hook re-entering `disputeWithRoute` from inside the swap. The outer dispute still
    ///      succeeds — the guard rejects only the nested call — and the hook records the rejection.
    function test_aV4HookCannotReenterTheHelper() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        _armHook(_reentryPayload(ctx));

        (bytes memory c, bytes[] memory i) =
            _v4ExactInSingle(address(tokenC), address(tokenA), 5e18, uint128(REQUIRED_1), hook);

        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);

        assertTrue(IHook(hook).fired(), "the hook never ran -- the test proves nothing");
        assertFalse(IHook(hook).reenterSucceeded(), "the hook re-entered the helper");
        assertEq(_hookErrorSelector(), REENTRANT_CALL, "the nested call failed for the wrong reason");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    /// @dev Control: with the hook disarmed, the identical hooked pool routes normally. Without
    ///      this the test above could pass on a route that never swapped at all.
    function test_theHookedPoolRoutesNormallyWhenDisarmed() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        (bytes memory c, bytes[] memory i) =
            _v4ExactInSingle(address(tokenC), address(tokenA), 5e18, uint128(REQUIRED_1), hook);

        uint256 c0 = tokenC.balanceOf(disputer);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);

        assertEq(c0 - tokenC.balanceOf(disputer), 5e18, "the hooked pool did not trade");
        assertFalse(IHook(hook).fired(), "the hook should be disarmed here");
    }

    /// @dev A hook re-entering with a plan that would drain a DIFFERENT game is rejected identically
    ///      — the guard is on the helper, not on the arguments.
    function test_aV4HookCannotStartASecondDisputeOnAnotherGame() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        Game memory victim = _newGame(address(tokenA), address(tokenB));

        _armHook(_reentryPayload(victim));

        (bytes memory c, bytes[] memory i) =
            _v4ExactInSingle(address(tokenC), address(tokenA), 5e18, uint128(REQUIRED_1), hook);

        bytes32 victimStateBefore = oracle.oracleGame(victim.reportId);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(tokenC), 5e18, c, i, 0);

        assertTrue(IHook(hook).fired(), "the hook never ran");
        assertFalse(IHook(hook).reenterSucceeded(), "the hook disputed a second game");
        assertEq(oracle.oracleGame(victim.reportId), victimStateBefore, "the second game was mutated");
    }

    // ────────────────────────────────────────────────────────────────────
    //  token callbacks
    // ────────────────────────────────────────────────────────────────────

    /// @dev Re-entry from `transferFrom`, i.e. during the helper's initial pull — the earliest
    ///      moment, before any snapshot has been acted on.
    function test_aTokenCannotReenterFromTheInitialPull() public {
        Game memory ctx = _newGame(address(evilToken), address(tokenB));

        evilToken.arm(address(helper), _reentryPayload(ctx), true, false);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(evilToken), 0, c, i, 0);

        assertTrue(evilToken.fired(), "the token callback never ran");
        assertFalse(evilToken.reenterSucceeded(), "the token re-entered the helper");
        assertEq(evilToken.reenterErrorSelector(), REENTRANT_CALL, "wrong failure reason");
    }

    /// @dev Re-entry from `transfer`, i.e. during the REFUND at the very end of the call. The
    ///      dispute has already been submitted at this point, so a successful re-entry here would
    ///      be operating on freshly-changed oracle state.
    function test_aTokenCannotReenterFromTheRefund() public {
        Game memory ctx = _newGame(address(evilToken), address(tokenB));

        evilToken.arm(address(helper), _reentryPayload(ctx), false, true);

        (bytes memory c, bytes[] memory i) = _noRoute();
        // Oversupply so a refund transfer definitely happens.
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1 + 50e18, 0, address(evilToken), 0, c, i, 0);

        assertTrue(evilToken.fired(), "the refund callback never ran");
        assertFalse(evilToken.reenterSucceeded(), "the token re-entered the helper during the refund");
        assertEq(evilToken.reenterErrorSelector(), REENTRANT_CALL, "wrong failure reason");
    }

    /// @dev Re-entry from the ORACLE'S WITHDRAWAL, which is a boundary the external-pull and
    ///      refund tests do not reach. With `tryInternalBalances` the helper calls
    ///      `oracle.withdrawTo(...)`, and the oracle then does `token.transfer(helper, amount)` —
    ///      a call made by the ORACLE, from inside the helper's own guarded call, moving funds that
    ///      until this instant existed only as a ledger entry.
    ///
    ///      The callback is given the full remaining gas and a payload that would otherwise
    ///      succeed, so the only thing that can stop it is the guard.
    function test_aTokenCannotReenterFromTheInternalWithdrawal() public {
        Game memory ctx = _newGame(address(evilToken), address(tokenB));

        // A real deposit and a real internal approval, made while the callback is disarmed.
        vm.startPrank(disputer);
        evilToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(evilToken), uint128(REQUIRED_1), disputer);
        oracle.approveInternal(address(helper), address(evilToken), type(uint256).max);
        vm.stopPrank();

        // onTransfer, not onTransferFrom: the withdrawal is a plain `transfer` by the oracle, and
        // it is the FIRST transfer of the call, so the one-shot callback lands exactly there.
        evilToken.arm(address(helper), _reentryPayload(ctx), false, true);

        uint256 wallet0 = evilToken.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, true, address(evilToken), 0, c, i, 0);

        assertTrue(evilToken.fired(), "the withdrawal callback never ran -- the test proves nothing");
        assertFalse(evilToken.reenterSucceeded(), "re-entered the helper from inside withdrawTo");
        assertEq(evilToken.reenterErrorSelector(), REENTRANT_CALL, "the nested call failed for the wrong reason");

        // ...and the accounting still lands: funded entirely from the ledger, nothing stranded.
        assertEq(evilToken.balanceOf(disputer), wallet0, "no external tokens should have been pulled");
        assertEq(oracle.tokenHolder(disputer, address(evilToken)), 1, "internal balance drained to the sentinel");
        assertEq(evilToken.balanceOf(address(helper)), 0, "helper retained a balance");
        assertLe(oracle.tokenHolder(address(helper), address(evilToken)), 1, "helper retained an internal balance");
    }

    /// @dev The same withdrawal boundary, but the re-entry attempt is what a thief would actually
    ///      want: a dispute on a DIFFERENT game. Rejected identically, and that game is untouched.
    function test_aWithdrawalCallbackCannotTouchAnotherGame() public {
        Game memory ctx = _newGame(address(evilToken), address(tokenB));
        Game memory victim = _newGame(address(tokenA), address(tokenB));

        vm.startPrank(disputer);
        evilToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(evilToken), uint128(REQUIRED_1), disputer);
        oracle.approveInternal(address(helper), address(evilToken), type(uint256).max);
        vm.stopPrank();

        evilToken.arm(address(helper), _reentryPayload(victim), false, true);

        bytes32 victimBefore = oracle.oracleGame(victim.reportId);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, true, address(evilToken), 0, c, i, 0);

        assertTrue(evilToken.fired(), "the withdrawal callback never ran");
        assertFalse(evilToken.reenterSucceeded(), "the callback disputed a second game");
        assertEq(oracle.oracleGame(victim.reportId), victimBefore, "the second game was mutated");
    }

    /// @dev Re-entry from the route-input pull, which happens on a different code path from the
    ///      oracle-token pull (`safeTransferFrom` for the third asset).
    function test_aRouteInputTokenCannotReenterFromItsPull() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        // The route itself will fail to fund the leg; what matters is that the pull's callback runs
        // before that, and is rejected.
        evilToken.arm(address(helper), _reentryPayload(ctx), true, false);

        (bytes memory c, bytes[] memory i) = _noRoute();

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, 0, 0, address(evilToken), 5e18, c, i, 0);
    }

    /// @dev A refund callback that re-enters must not be able to walk away with the refund twice.
    ///      The disputer's net debit is pinned to the requirement exactly.
    function test_aReentrantRefundDoesNotDoublePay() public {
        Game memory ctx = _newGame(address(evilToken), address(tokenB));

        evilToken.arm(address(helper), _reentryPayload(ctx), false, true);

        uint256 before = evilToken.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1 + 50e18, 0, address(evilToken), 0, c, i, 0);

        assertEq(before - evilToken.balanceOf(disputer), REQUIRED_1, "the refund was paid more than once");
        assertEq(evilToken.balanceOf(address(helper)), 0, "helper retained a balance");
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    /// @dev A complete, well-formed `disputeWithRoute` call. It is deliberately one that WOULD
    ///      succeed on its own, so the only reason it can fail is the guard.
    function _reentryPayload(Game memory ctx) internal view returns (bytes memory) {
        (bytes memory c, bytes[] memory i) = _noRoute();
        return abi.encodeCall(
            OracleDisputeHelper.disputeWithRoute,
            (
                _dd(ctx, NEW_AMOUNT_1, 900e18),
                ctx.game,
                ctx.helper,
                _emptyTiming(),
                REQUIRED_1,
                0,
                false,
                ctx.game.token1,
                0,
                c,
                i,
                block.timestamp + 1,
                router
            )
        );
    }

    function _armHook(bytes memory payload) internal {
        IHook(hook).arm(address(helper), payload);
    }

    function _hookErrorSelector() internal view returns (bytes4 sel) {
        bytes memory ret = IHook(hook).reenterReturndata();
        if (ret.length >= 4) sel = bytes4(ret);
    }

    /// @dev Mines a CREATE2 salt until the resulting address declares beforeSwap and nothing else,
    ///      then deploys the real hook bytecode there. One in 2**14 salts qualifies.
    function _deployMinedHook() internal returns (address deployed) {
        bytes memory code = vm.getCode("uniswap-venues/out/V4Support.sol/ReentrantV4Hook.json");
        bytes32 codeHash = keccak256(code);

        for (uint256 salt; salt < 200_000; ++salt) {
            address candidate = create2.addressOf(codeHash, bytes32(salt));
            if (uint160(candidate) & HOOK_FLAG_MASK == BEFORE_SWAP_FLAG) {
                return create2.deploy(code, bytes32(salt));
            }
        }
        revert("no hook salt found");
    }

    function _seedHookedV4Pool(address a, address b, address hooks) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        IV4Liquidity(v4Liquidity).initializePool(c0, c1, V4_FEE, V4_TICK_SPACING, hooks, SQRT_PRICE_1_1);
        _mintTo(c0, v4Liquidity, POOL_LIQUIDITY);
        _mintTo(c1, v4Liquidity, POOL_LIQUIDITY);
        IV4Liquidity(v4Liquidity).addLiquidity(c0, c1, V4_FEE, V4_TICK_SPACING, hooks, MIN_TICK, MAX_TICK, 1e21);
    }
}

interface IHook {
    function arm(address target, bytes calldata payload) external;
    function fired() external view returns (bool);
    function reenterSucceeded() external view returns (bool);
    function reenterReturndata() external view returns (bytes memory);
}
