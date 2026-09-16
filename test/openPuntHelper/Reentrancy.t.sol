// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenPuntHelperBase} from "./OpenPuntHelperBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {ReentrantERC20, Create2Factory} from "../disputeHelper/util/Actors.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice Hostile callbacks at every boundary this helper crosses.
 *
 * @dev Both entry points carry the same `nonReentrant` modifier, and the helper holds no persistent
 *      per-position state between calls, so a broad cross-position accounting matrix would
 *      re-prove one modifier many times. Each boundary must hand control to caller-chosen code,
 *      the callback must fire with unrestricted remaining gas, and the nested call must fail on
 *      the guard.
 *
 *      Covered boundaries are the caller's ERC20 `transferFrom` during the initial pull, the oracle's
 *      `transfer` during `withdrawTo` when funding internally; and the helper's own `transfer`
 *      during a refund. Each is reached by making one of the aggregated assets a token that
 *      re-enters.
 *
 *      The hostile token swallows the nested revert and records its
 *      selector. If it bubbled, a passing test could not distinguish "the guard held" from "the
 *      callback broke the transfer for unrelated reasons". Every test asserts three things: the
 *      callback fired, the nested call failed, and it failed with `ReentrancyGuardReentrantCall`.
 *
 *      Cross-entry behavior is covered by aiming the nested call at the other entry point: a callback raised
 *      inside `matchWithRoute` attempting `reportWithRoute` must hit the same guard.
 */
contract ReentrancyTest is OpenPuntHelperBase {
    bytes4 internal constant REENTRANT_CALL = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    ReentrantERC20 internal evil;

    Create2Factory internal create2;
    address internal hook;

    /// @dev v4-core `Hooks.BEFORE_SWAP_FLAG` is `1 << 7`, and a hook's address declares its
    ///      permissions in the low 14 bits.
    uint160 internal constant HOOK_FLAG_MASK = uint160((1 << 14) - 1);
    uint160 internal constant BEFORE_SWAP_FLAG = uint160(1 << 7);

    function setUp() public override {
        super.setUp();

        create2 = new Create2Factory();
        hook = _deployMinedHook();
        _seedHookedV4Pool(address(tokenC), address(tokenA), hook);

        evil = new ReentrantERC20("Reentrant", "EVIL");
        evil.mint(funder, 10_000_000e18);
        evil.mint(swapper, 10_000_000e18);

        vm.startPrank(funder);
        evil.approve(address(helper), type(uint256).max);
        evil.approve(address(oracle), type(uint256).max);
        vm.stopPrank();

        vm.prank(swapper);
        evil.approve(PERMIT2, type(uint256).max);
    }

    // ────────────────────────────────────────────────────────────────────
    //  the caller's ERC20 pull
    // ────────────────────────────────────────────────────────────────────

    /// @dev `transferFrom` during the helper's initial pull — the earliest boundary, before any
    ///      deposit or router interaction.
    function test_aTokenCannotReenterFromTheInitialPull() public {
        Proposal memory p = _proposeEvilCollateral();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        evil.arm(address(helper), _matchPayload(p), true, false);

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, EVIL_MARGIN, false),
            router
        );

        _assertGuardHeld("initial pull");
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the outer match must still complete");
    }

    // ────────────────────────────────────────────────────────────────────
    //  the oracle's withdrawal
    // ────────────────────────────────────────────────────────────────────

    /// @dev With `tryInternalBalances` the helper calls `oracle.withdrawTo`, and the oracle then
    ///      calls `token.transfer(helper, ...)` — a callback raised by a third party, from inside
    ///      the helper's guarded call, moving funds that until that instant were a ledger entry.
    function test_aTokenCannotReenterFromTheInternalWithdrawal() public {
        Proposal memory p = _proposeEvilCollateral();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        // Real deposit and internal approval, made while the callback is disarmed.
        vm.startPrank(funder);
        oracle.deposit(address(evil), EVIL_MARGIN, funder);
        oracle.approveInternal(address(helper), address(evil), type(uint256).max);
        vm.stopPrank();

        // onTransfer: the withdrawal is a plain `transfer` and is the first such call.
        evil.arm(address(helper), _matchPayload(p), false, true);

        uint256 wallet0 = evil.balanceOf(funder);

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, EVIL_MARGIN, true),
            router
        );

        _assertGuardHeld("internal withdrawal");
        assertEq(evil.balanceOf(funder), wallet0, "the collateral should have come from the ledger");
        assertEq(oracle.tokenHolder(funder, address(evil)), 1, "internal balance drained to the sentinel");
    }

    // ────────────────────────────────────────────────────────────────────
    //  the refund
    // ────────────────────────────────────────────────────────────────────

    /// @dev `transfer` during the refund, at the end of the call after OpenPunt has
    ///      already been driven. A successful re-entry here would be operating on freshly-changed
    ///      protocol state.
    function test_aTokenCannotReenterFromTheRefund() public {
        Proposal memory p = _proposeEvilCollateral();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        // No internal balance, so the first `transfer` the token sees is the refund of the
        // oversupply rather than a withdrawal.
        evil.arm(address(helper), _matchPayload(p), false, true);

        uint256 wallet0 = evil.balanceOf(funder);

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, EVIL_MARGIN + 500e18, false),
            router
        );

        _assertGuardHeld("refund");
        assertEq(wallet0 - evil.balanceOf(funder), EVIL_MARGIN, "the oversupply must still be refunded");
    }

    // ────────────────────────────────────────────────────────────────────
    //  cross-entry
    // ────────────────────────────────────────────────────────────────────

    /// @dev A callback raised inside `matchWithRoute` attempts the other entry point. Both share
    ///      one guard, so the nested `reportWithRoute` is rejected identically.
    function test_aCallbackCannotCrossIntoTheOtherEntryPoint() public {
        Proposal memory p = _proposeEvilCollateral();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        // A live position, so the nested report call is otherwise well formed.
        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openPositionForReport();
        _approveReporterLegs(designatedReporter, address(tokenA), address(tokenB));

        evil.arm(address(helper), _reportPayload(sid, live, pre), true, false);

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, EVIL_MARGIN, false),
            router
        );

        _assertGuardHeld("cross-entry match -> report");
    }

    /// @dev And the reverse direction: a callback inside `reportWithRoute` attempting a match.
    function test_aCallbackInsideReportCannotCrossIntoMatch() public {
        Proposal memory victim = _propose();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre) =
            _openEvilLegPosition();
        _approveReporterLegs(designatedReporter, address(evil), address(tokenB));

        evil.arm(address(helper), _matchPayload(victim), true, false);

        vm.prank(funder);
        helper.reportWithRoute{value: REPORT_EXEC_COMP}(
            sid,
            bytes32(0),
            live,
            pre,
            _noTiming(),
            designatedReporter,
            EVIL_LEG1,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(EVIL_LEG1, AMOUNT2, REPORT_EXEC_COMP, false),
            router
        );

        _assertGuardHeld("cross-entry report -> match");
    }

    // ────────────────────────────────────────────────────────────────────
    //  a real Uniswap V4 hook
    // ────────────────────────────────────────────────────────────────────

    function test_theMinedHookAddressReallyDeclaresBeforeSwap() public view {
        assertEq(uint160(hook) & HOOK_FLAG_MASK, BEFORE_SWAP_FLAG, "hook address does not declare beforeSwap only");
        assertGt(hook.code.length, 0, "hook has no code");
    }

    /// @dev A genuine V4 hook re-entering from INSIDE the swap, mid-route: funds have left the
    ///      caller, the router holds them, and neither the oracle deposits nor OpenPunt have run.
    function test_aV4HookCannotReenterDuringTheRoute() public {
        Proposal memory p = _propose();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        IHook(hook).arm(address(helper), _matchPayloadPlain(p));

        (bytes memory cmds, bytes[] memory ins) =
            _v4ExactInSingle(address(tokenC), address(tokenA), 5000e18, INITIAL_LIQUIDITY, hook);
        (cmds, ins) = _withSweep(cmds, ins, address(tokenC));

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), 5000e18, cmds, ins),
            router
        );

        assertTrue(IHook(hook).fired(), "the hook never ran -- the test proves nothing");
        assertFalse(IHook(hook).reenterSucceeded(), "the hook re-entered the helper");
        assertEq(_hookSelector(), REENTRANT_CALL, "the nested call failed for the wrong reason");
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the outer match must still complete");
    }

    /// @dev With the hook disarmed, the same pool routes normally, proving the guarded test reaches
    ///      a real swap callback.
    function test_theHookedPoolRoutesNormallyWhenDisarmed() public {
        Proposal memory p = _propose();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        (bytes memory cmds, bytes[] memory ins) =
            _v4ExactInSingle(address(tokenC), address(tokenA), 5000e18, INITIAL_LIQUIDITY, hook);
        (cmds, ins) = _withSweep(cmds, ins, address(tokenC));

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), 5000e18, cmds, ins),
            router
        );

        assertFalse(IHook(hook).fired(), "the hook should be disarmed here");
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the hooked pool did not trade");
    }

    // ────────────────────────────────────────────────────────────────────
    //  downstream: oracle deposit, and OpenPunt's own funding
    // ────────────────────────────────────────────────────────────────────

    /// @dev The oracle deposit is the first armed callback boundary. The token's
    ///      callback is one-shot: an external pull would consume it first. So the collateral is
    ///      collateral is sourced entirely from the internal ledger and only `onTransferFrom` is armed:
    ///
    ///        - `internalTransferFrom(funder -> helper)` is a pure ledger move: no callback;
    ///        - `withdrawTo` calls `transfer`, which is disarmed here;
    ///        - `deposit` then calls `transferFrom(helper -> oracle)` — the first armed boundary.
    function test_aTokenCannotReenterFromTheOracleDeposit() public {
        Proposal memory p = _proposeEvilCollateral();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        // Real deposit and internal approval, made while the callback is disarmed.
        vm.startPrank(funder);
        oracle.deposit(address(evil), EVIL_MARGIN, funder);
        oracle.approveInternal(address(helper), address(evil), type(uint256).max);
        vm.stopPrank();

        evil.arm(address(helper), _matchPayload(p), true, false); // transferFrom only

        uint256 wallet0 = evil.balanceOf(funder);

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, EVIL_MARGIN, true),
            router
        );

        _assertGuardHeld("oracle deposit");
        assertEq(evil.balanceOf(funder), wallet0, "the collateral must have come from the ledger, not a pull");
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the outer match must still complete");
    }

    /// @dev OpenPunt's own downstream funding moves the collateral
    ///      `internalTransferFrom(helper -> punt)` — a ledger entry that raises no token callback.
    ///
    ///      Proved positively by counting the token's `Transfer` events rather than by leaving the
    ///      hostile token disarmed: exactly three ERC20 transfers occur for the collateral over the
    ///      whole call (funder -> helper, helper -> oracle, then the opening-fee refund -> swapper),
    ///      and none during OpenPunt's own internal funding.
    function test_openPuntInternalFundingRaisesNoTokenCallback() public {
        Proposal memory p = _proposeEvilCollateral();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));

        vm.recordLogs();
        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, EVIL_MARGIN, false),
            router
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Transfer(address,address,uint256)");

        uint256 count;
        address firstTo;
        address secondTo;
        address thirdTo;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(evil) || logs[i].topics.length < 3 || logs[i].topics[0] != sig) continue;
            address to = address(uint160(uint256(logs[i].topics[2])));
            if (count == 0) firstTo = to;
            if (count == 1) secondTo = to;
            if (count == 2) thirdTo = to;
            ++count;
        }

        assertEq(count, 3, "the collateral should move exactly three times as an ERC20");
        assertEq(firstTo, address(helper), "first move: caller -> helper");
        assertEq(secondTo, address(oracle), "second move: helper -> oracle");
        assertEq(thirdTo, swapper, "third move: opening-fee refund -> swapper");
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the match must still complete");
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    /// @dev The same payload without the collateral oversupply, for hook-driven re-entry.
    function _matchPayloadPlain(Proposal memory p) internal view returns (bytes memory) {
        return abi.encodeCall(
            OpenPuntHelper.matchWithRoute,
            (
                p.swapId,
                AMOUNT2,
                p.swap,
                p.preimage,
                _noTiming(),
                designatedMatcher,
                _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false),
                router
            )
        );
    }

    function _hookSelector() internal view returns (bytes4 sel) {
        bytes memory ret = IHook(hook).reenterReturndata();
        if (ret.length >= 4) sel = bytes4(ret);
    }

    /// @dev Mines a CREATE2 salt until the address declares beforeSwap and nothing else, then
    ///      deploys the real hook bytecode there.
    function _deployMinedHook() internal returns (address) {
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
        IV4LiquidityLike(v4Liquidity).initializePool(c0, c1, V4_FEE, V4_TICK_SPACING, hooks, SQRT_PRICE_1_1);
        _mintTo(c0, v4Liquidity, POOL_LIQUIDITY);
        _mintTo(c1, v4Liquidity, POOL_LIQUIDITY);
        IV4LiquidityLike(v4Liquidity).addLiquidity(c0, c1, V4_FEE, V4_TICK_SPACING, hooks, MIN_TICK, MAX_TICK, 1e21);
    }

    uint128 internal constant EVIL_MARGIN = 900e18;
    uint128 internal constant EVIL_LEG1 = 1e18;

    function _assertGuardHeld(string memory where) internal view {
        assertTrue(evil.fired(), string.concat("the callback never ran: ", where));
        assertFalse(evil.reenterSucceeded(), string.concat("re-entered the helper from: ", where));
        assertEq(evil.reenterErrorSelector(), REENTRANT_CALL, string.concat("wrong failure reason: ", where));
    }

    /// @dev A well-formed call that would otherwise succeed, so the only expected failure is the
    ///      guard.
    function _matchPayload(Proposal memory p) internal view returns (bytes memory) {
        return abi.encodeCall(
            OpenPuntHelper.matchWithRoute,
            (
                p.swapId,
                AMOUNT2,
                p.swap,
                p.preimage,
                _noTiming(),
                designatedMatcher,
                _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, EVIL_MARGIN, false),
                router
            )
        );
    }

    function _reportPayload(
        uint256 sid,
        OpenPuntStorage.MatchedSwap memory live,
        OpenPuntStorage.MatcherPreimage memory pre
    ) internal view returns (bytes memory) {
        return abi.encodeCall(
            OpenPuntHelper.reportWithRoute,
            (
                sid,
                bytes32(0),
                live,
                pre,
                _noTiming(),
                designatedReporter,
                INITIAL_LIQUIDITY,
                AMOUNT2,
                REPORT_EXEC_COMP,
                _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, false),
                router
            )
        );
    }

    /// @dev A proposal whose collateral token re-enters.
    function _proposeEvilCollateral() internal returns (Proposal memory) {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.collatToken = address(evil);
        s.initialMarginSwapper = EVIL_MARGIN;
        s.initialMarginMatcher = EVIL_MARGIN;
        s.maintenanceMarginSwapper = 150e18;
        s.notional = 9000e18;
        return _proposeWith(s, _defaultMatcherPreimage(), swapper);
    }

    function _openPositionForReport()
        internal
        returns (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre)
    {
        Proposal memory p = _propose();
        pre = p.preimage;
        Matched memory mt = _matchSwap(p);
        _advanceToSettlementEligibility();
        live = _executeOpening(mt, executor);
        sid = p.swapId;
    }

    /// @dev A live position whose oracleToken1 re-enters, so a later report crosses the callback.
    function _openEvilLegPosition()
        internal
        returns (uint256 sid, OpenPuntStorage.MatchedSwap memory live, OpenPuntStorage.MatcherPreimage memory pre)
    {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.oracleToken1 = address(evil);

        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();
        m.initialLiquidity = EVIL_LEG1;

        Proposal memory p = _proposeWith(s, m, swapper);
        pre = p.preimage;

        evil.mint(matcher, 1_000_000e18);
        vm.startPrank(matcher);
        evil.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(evil), 100e18, matcher);
        oracle.approveInternal(address(punt), address(evil), type(uint256).max);
        vm.stopPrank();

        vm.recordLogs();
        vm.prank(matcher);
        punt.matchSwap(p.swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), matcher);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Matched memory mt;
        mt.swapId = p.swapId;
        (mt.reportId, mt.swap) = _decodeSwapMatched(logs, p.swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);

        _advanceToSettlementEligibility();
        live = _executeOpening(mt, executor);
        sid = p.swapId;
    }
}

interface IHook {
    function arm(address target, bytes calldata payload) external;
    function fired() external view returns (bool);
    function reenterSucceeded() external view returns (bool);
    function reenterReturndata() external view returns (bytes memory);
}

interface IV4LiquidityLike {
    function initializePool(address, address, uint24, int24, address, uint160) external;
    function addLiquidity(address, address, uint24, int24, address, int24, int24, int256) external payable;
}
