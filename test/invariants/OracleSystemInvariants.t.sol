// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {OracleSystemHandler} from "./OracleSystemHandler.sol";
import {AdversarialCallback, RevertingToken, ReturnsFalseToken, NoReturnToken, ReentrantToken} from "./AdversarialMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Broad invariant campaign across the oracle system.
///         Drives randomized report / dispute / settle / deposit / withdraw / transfer / approve ops
///         across multiple actors and a token rotation that includes adversarial mocks
///         (reverting, returns-false, USDT-style no-return, reentrant) plus an adversarial callback.
contract OracleSystemInvariantsTest is StdInvariant, Test {
    OpenOracle internal oracle;
    OracleSystemHandler internal handler;
    AdversarialCallback internal callback;

    MockERC20 internal vanillaA;
    MockERC20 internal vanillaB;
    NoReturnToken internal noReturnTok;
    RevertingToken internal revertingTok;
    ReturnsFalseToken internal returnsFalseTok;
    ReentrantToken internal reentrantTok;

    address[] internal allActors;

    function setUp() public {
        oracle = new OpenOracle();
        callback = new AdversarialCallback();
        handler = new OracleSystemHandler(oracle, callback);

        // Tokens — index 0 is ETH (address(0)).
        handler.addToken(address(0));
        vanillaA = new MockERC20("VanillaA", "VAA");
        vanillaB = new MockERC20("VanillaB", "VAB");
        noReturnTok = new NoReturnToken();
        revertingTok = new RevertingToken();
        returnsFalseTok = new ReturnsFalseToken();
        reentrantTok = new ReentrantToken(address(oracle));

        handler.addToken(address(vanillaA));
        handler.addToken(address(vanillaB));
        handler.addToken(address(noReturnTok));
        handler.addToken(address(revertingTok));
        handler.addToken(address(returnsFalseTok));
        handler.addToken(address(reentrantTok));

        // Actors — 4 distinct EOAs.
        allActors = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
        for (uint256 i = 0; i < allActors.length; i++) {
            address a = allActors[i];
            handler.addActor(a);
            vm.deal(a, 100 ether);
            vanillaA.transfer(a, 100_000e18);
            vanillaB.transfer(a, 100_000e18);
            noReturnTok.transfer(a, 100_000e18);
            vm.prank(a); vanillaA.approve(address(oracle), type(uint256).max);
            vm.prank(a); vanillaB.approve(address(oracle), type(uint256).max);
            vm.prank(a); noReturnTok.approve(address(oracle), type(uint256).max);
            vm.prank(a); revertingTok.approve(address(oracle), type(uint256).max);
            vm.prank(a); returnsFalseTok.approve(address(oracle), type(uint256).max);
            vm.prank(a); reentrantTok.approve(address(oracle), type(uint256).max);
        }
        // Fund actors with the adversarial-transfer tokens via cheatcode.
        for (uint256 i = 0; i < allActors.length; i++) {
            deal(address(reentrantTok), allActors[i], 100_000e18);
            deal(address(returnsFalseTok), allActors[i], 100_000e18);
        }

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](12);
        sels[0] = OracleSystemHandler.actReport.selector;
        sels[1] = OracleSystemHandler.actDispute.selector;
        sels[2] = OracleSystemHandler.actSettle.selector;
        sels[3] = OracleSystemHandler.actDeposit.selector;
        sels[4] = OracleSystemHandler.actWithdraw.selector;
        sels[5] = OracleSystemHandler.actApprove.selector;
        sels[6] = OracleSystemHandler.actInternalTransfer.selector;
        sels[7] = OracleSystemHandler.actPushOrCredit.selector;
        sels[8] = OracleSystemHandler.actDust.selector;
        sels[9] = OracleSystemHandler.actWarp.selector;
        sels[10] = OracleSystemHandler.actReport.selector; // bias toward report
        sels[11] = OracleSystemHandler.actSetCallbackMode.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: sels}));
    }

    // ─── Conservation: real balance vs. tracked accounting ─────────────────

    /// @dev Exact per-token conservation:
    ///        real(token) == Σ_user tokenHolder[u][token] - sentinels(token) + burned(token) + inflight(token)
    ///      where:
    ///        sentinels(token) = count of touched (user, token) slots with bal > 0
    ///        burned(token)    = sum of protocolFee writes whose recipient was address(0)
    ///        inflight(token)  = Σ unsettled reports' currentAmount{1,2} matching token
    ///                            (+ ghostInflightSettlerETH for ETH)
    ///      The sentinel-counting model is exact because every raw `+=` credit in the contract lands on
    ///      a slot pre-seeded by `_getDustAmounts` (reporter / disputer / pfr-when-fee>0&!zero), so every
    ///      nonzero slot has exactly one sentinel unit.
    function invariant_conservationPerToken() public view {
        uint256 tokenN = handler.tokenCount();
        uint256 holderN = handler.holderCount();

        for (uint256 t = 0; t < tokenN; t++) {
            address tok = handler.tokenAt(t);
            uint256 sumHolder;
            uint256 sentinels;
            for (uint256 h = 0; h < holderN; h++) {
                uint256 bal = oracle.tokenHolder(handler.holderAt(h), tok);
                if (bal > 0) sentinels += 1;
                sumHolder += bal;
            }
            uint256 inflight = _inflightForToken(tok);
            uint256 burned = handler.ghostBurned(tok);
            uint256 real = (tok == address(0)) ? address(oracle).balance : IERC20(tok).balanceOf(address(oracle));
            if (tok == address(0)) inflight += handler.ghostInflightSettlerETH();

            assertEq(real, sumHolder - sentinels + burned + inflight, "conservation");
        }
    }

    /// @dev Inflight per token = Σ over unsettled reports of (currentAmount1 if t1==token) + (currentAmount2 if t2==token).
    function _inflightForToken(address token) internal view returns (uint256 sum) {
        uint256 n = handler.reportCount();
        for (uint256 i = 0; i < n; i++) {
            if (handler.getReportSettled(i)) continue;
            OpenOracle.OracleGame memory g = handler.getReportGame(i);
            if (g.token1 == token) sum += g.currentAmount1;
            if (g.token2 == token) sum += g.currentAmount2;
        }
    }

    // ─── Sanity invariants ───────────────────────────────────────────────────

    /// @dev Any touched slot with bal > 0 has bal ≥ 1 (the contract never writes a fractional sentinel).
    function invariant_sentinelMonotone() public view {
        uint256 tokenN = handler.tokenCount();
        uint256 holderN = handler.holderCount();
        for (uint256 t = 0; t < tokenN; t++) {
            address tok = handler.tokenAt(t);
            for (uint256 h = 0; h < holderN; h++) {
                uint256 bal = oracle.tokenHolder(handler.holderAt(h), tok);
                if (bal > 0) assertGe(bal, 1, "sentinel below 1");
            }
        }
    }

    /// @dev Stored oracleGame[reportId] reconciles with handler-tracked (game, helper).
    function invariant_reportHashMatches() public view {
        uint256 n = handler.reportCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.getReportId(i);
            bytes32 stored = oracle.oracleGame(id);
            if (stored == bytes32(0)) continue; // not stored — skip
            OpenOracle.OracleGame memory g = handler.getReportGame(i);
            OpenOracle.PreimageHelper memory h = handler.getReportHelper(i);
            assertEq(stored, keccak256(abi.encode(g, h)), "stored hash != reconstructed");
        }
    }

    /// @dev Callback observed → settle was recorded on that report.
    function invariant_callbackImpliesSettled() public view {
        uint256 n = handler.reportCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.getReportId(i);
            if (callback.called(id)) assertTrue(handler.getReportSettled(i), "callback fired but not settled");
        }
    }

    /// @dev ghostInflightSettlerETH = SETTLER_REWARD × unsettled-report-count.
    function invariant_inflightSettlerETHBookkeeping() public view {
        uint256 n = handler.reportCount();
        uint256 expected;
        for (uint256 i = 0; i < n; i++) {
            if (!handler.getReportSettled(i)) expected += 0.001 ether;
        }
        assertEq(expected, handler.ghostInflightSettlerETH(), "inflight settlerETH ghost drift");
    }

    /// @dev Whenever the callback was observed firing, gas seen at entry must not exceed the
    ///      report's callbackGasLimit. Locks down that the contract caps callback gas regardless
    ///      of mode (Revert / ConsumeAll / Reenter / Noop) and never lets a runaway callback
    ///      consume the caller's surrounding budget.
    function invariant_callbackGasRespectsLimit() public view {
        uint256 n = handler.reportCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.getReportId(i);
            if (!callback.called(id)) continue;
            OpenOracle.OracleGame memory g = handler.getReportGame(i);
            assertLe(callback.lastGas(id), uint256(g.callbackGasLimit), "callback gas exceeded limit");
        }
    }
}
