// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {openSwapV2} from "../../src/OpenSwapSlim.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {NoReturnToken} from "./AdversarialMocks.sol";
import {MockPermit2} from "../utils/MockPermit2.sol";
import {SwapSystemHandler} from "./SwapSystemHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Broad invariant campaign across openSwap → openOracle. Drives propose / match / cancel /
///         bailOut / oracle-settle / execute / withdraw across 4 actors and 4 tokens (ETH + 2 vanilla +
///         USDT-style). Asserts:
///           1. Swap never holds ERC20 externally (every token flow routes through oracle).
///           2. Swap ETH conservation: swap.balance == Σ tempHolding + active-swap inflight.
///           3. Stored swap hash matches handler-tracked struct for every active swap.
///           4. Oracle conservation (per token, exact) — extended with swap as a tokenHolder.
contract SwapSystemInvariantsTest is StdInvariant, Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    OpenOracle internal oracle;
    openSwapV2 internal swap;
    SwapSystemHandler internal handler;

    MockERC20 internal vanillaA;
    MockERC20 internal vanillaB;
    NoReturnToken internal usdtLike;

    address[] internal allActors;

    function setUp() public {
        MockPermit2 permit2 = new MockPermit2();
        vm.etch(PERMIT2, address(permit2).code);

        oracle = new OpenOracle();
        swap = new openSwapV2(address(oracle));
        handler = new SwapSystemHandler(oracle, swap);

        handler.addToken(address(0)); // ETH
        vanillaA = new MockERC20("VanillaA", "VAA");
        vanillaB = new MockERC20("VanillaB", "VAB");
        usdtLike = new NoReturnToken();
        handler.addToken(address(vanillaA));
        handler.addToken(address(vanillaB));
        handler.addToken(address(usdtLike));

        allActors = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
        for (uint256 i = 0; i < allActors.length; i++) {
            address a = allActors[i];
            handler.addActor(a);
            vm.deal(a, 1000 ether);

            vanillaA.transfer(a, 200_000e18);
            vanillaB.transfer(a, 200_000e18);
            usdtLike.transfer(a, 200_000e18);

            // Approvals for Permit2 path (external sells) and oracle (for internal balance deposit).
            vm.prank(a); vanillaA.approve(PERMIT2, type(uint256).max);
            vm.prank(a); vanillaB.approve(PERMIT2, type(uint256).max);
            vm.prank(a); usdtLike.approve(PERMIT2, type(uint256).max);
            vm.prank(a); vanillaA.approve(address(oracle), type(uint256).max);
            vm.prank(a); vanillaB.approve(address(oracle), type(uint256).max);
            vm.prank(a); usdtLike.approve(address(oracle), type(uint256).max);

            // Deposit internal balances + approve swap (for useInternal proposers and matchers).
            vm.startPrank(a);
            oracle.deposit(address(vanillaA), 100_000e18, a);
            oracle.deposit(address(vanillaB), 100_000e18, a);
            oracle.deposit(address(usdtLike), 100_000e18, a);
            oracle.deposit{value: 50 ether}(address(0), 50 ether, a);
            oracle.approveInternal(address(swap), address(vanillaA), type(uint256).max);
            oracle.approveInternal(address(swap), address(vanillaB), type(uint256).max);
            oracle.approveInternal(address(swap), address(usdtLike), type(uint256).max);
            oracle.approveInternal(address(swap), address(0), type(uint256).max);
            vm.stopPrank();
        }

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](10);
        sels[0] = SwapSystemHandler.actPropose.selector;
        sels[1] = SwapSystemHandler.actPropose.selector; // bias toward propose
        sels[2] = SwapSystemHandler.actMatch.selector;
        sels[3] = SwapSystemHandler.actCancelPreExpire.selector;
        sels[4] = SwapSystemHandler.actCancelPostExpire.selector;
        sels[5] = SwapSystemHandler.actBailOut.selector;
        sels[6] = SwapSystemHandler.actSettleOracle.selector;
        sels[7] = SwapSystemHandler.actExecute.selector;
        sels[8] = SwapSystemHandler.actWithdrawTemp.selector;
        sels[9] = SwapSystemHandler.actWarp.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: sels}));
    }

    // ─── Invariant 1: swap holds no external ERC20 ──────────────────────────

    function invariant_swapHoldsNoExternalERC20() public view {
        // ETH (idx 0) is the only token the swap legitimately holds externally — for gas comps
        // and settler reward in flight. ERC20s should be 0 because every token flow routes
        // through oracle.internalTransferFrom / oracle.pushOrCredit (which target the oracle's
        // address, not openSwap's external balance).
        for (uint256 t = 1; t < handler.tokenCount(); t++) {
            address tok = handler.tokenAt(t);
            assertEq(IERC20(tok).balanceOf(address(swap)), 0, "swap holds external ERC20");
        }
    }

    // ─── Invariant 2: swap ETH conservation ─────────────────────────────────

    /// @dev swap.balance == Σ tempHolding[u] across known holders
    ///                     + (matcherGasComp + settlerReward + executorGasComp) × preMatch swap count
    ///                     + executorGasComp × matched active swap count.
    ///      All gas comps are uniform across swaps (fixed at handler-time) so the formula stays simple.
    function invariant_swapEthConservation() public view {
        uint256 sumTemp;
        uint256 holderN = handler.knownCount();
        for (uint256 h = 0; h < holderN; h++) {
            sumTemp += swap.tempHolding(handler.knownAt(h));
        }
        uint256 perPre = uint256(handler.MATCHER_GAS_COMP())
                       + uint256(handler.SETTLER_REWARD())
                       + uint256(handler.EXECUTOR_GAS_COMP());
        uint256 perMatched = uint256(handler.EXECUTOR_GAS_COMP());
        uint256 inflight = perPre * handler.preMatchCount() + perMatched * handler.matchedCount();
        assertEq(address(swap).balance, sumTemp + inflight, "swap ETH conservation");
    }

    // ─── Invariant 3: every stored swap hash reconciles ────────────────────

    function invariant_perSwapHashMatches() public view {
        uint256 n = handler.swapCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.getSwapId(i);
            bytes32 stored = swap.swaps(id);
            SwapSystemHandler.SwapState st = handler.getSwapState(i);
            if (st == SwapSystemHandler.SwapState.Finalized) {
                assertEq(stored, bytes32(0), "finalized swap has nonzero stored hash");
                continue;
            }
            if (st == SwapSystemHandler.SwapState.PreMatch) {
                bytes32 expected = keccak256(abi.encode(handler.getSwapS(i), handler.getSwapM(i)));
                assertEq(stored, expected, "preMatch hash mismatch");
            } else if (st == SwapSystemHandler.SwapState.Matched) {
                bytes32 expected = keccak256(abi.encode(handler.getSwapMS(i)));
                assertEq(stored, expected, "matched hash mismatch");
            }
        }
    }

    // ─── Invariant 4: oracle conservation including swap as a holder ───────

    /// @dev Same exact-equality conservation as the oracle suite, but the holder set is the
    ///      swap-handler's `knownHolders` which already includes address(swap) (added in handler
    ///      constructor). Inflight for the oracle side = currentAmount{1,2} across un-settled
    ///      reports that the handler created via match, plus settlerReward per such report.
    function invariant_oracleConservationPerToken() public view {
        uint256 tokenN = handler.tokenCount();
        uint256 holderN = handler.knownCount();

        for (uint256 t = 0; t < tokenN; t++) {
            address tok = handler.tokenAt(t);
            uint256 sumHolder;
            uint256 sentinels;
            for (uint256 h = 0; h < holderN; h++) {
                uint256 bal = oracle.tokenHolder(handler.knownAt(h), tok);
                if (bal > 0) sentinels += 1;
                sumHolder += bal;
            }
            uint256 inflight = _oracleInflightForToken(tok);
            uint256 real = (tok == address(0)) ? address(oracle).balance : IERC20(tok).balanceOf(address(oracle));

            assertEq(real, sumHolder - sentinels + inflight, "oracle conservation");
        }
    }

    /// @dev Sum of currentAmount{1,2} for each swap whose oracle game is still alive
    ///      (reportId != 0 && !oracleSettled). Includes bailed-out swaps — those stay
    ///      `Finalized` from the swap's perspective but the oracle game lives on with
    ///      matcher's stake stuck inside (per known_mechanics.md).
    ///      Plus settlerReward in flight for those reports (only matters for ETH).
    function _oracleInflightForToken(address token) internal view returns (uint256 sum) {
        uint256 n = handler.swapCount();
        for (uint256 i = 0; i < n; i++) {
            if (handler.getSwapReportId(i) == 0) continue; // no oracle game
            if (handler.getSwapOracleSettled(i)) continue; // game already finalized
            IOpenOracle2.OracleGame memory g = handler.getSwapGame(i);
            if (g.token1 == token) sum += g.currentAmount1;
            if (g.token2 == token) sum += g.currentAmount2;
            if (token == address(0)) sum += g.settlerReward;
        }
    }
}
