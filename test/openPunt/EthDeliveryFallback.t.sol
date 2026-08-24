// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./TokenCompatBase.t.sol";

/**
 * @notice Failed raw-ETH delivery, through a contract that genuinely owns and drives the
 *         position while refusing `receive()`.
 *
 * @dev There are two distinct fallback ledgers:
 *        - `openPunt.payEth`      -> credits `tempHolding`, recovered via `punt.withdraw`
 *        - `oracle.pushOrCredit`  -> credits the OpenOracle internal ledger, recovered via
 *                                    `oracle.withdrawTo`
 *      Both are denominated in ETH, so every assertion below separates raw balance, oracle
 *      internal credit and tempHolding, and never sums them.
 *
 *      The rejecting contract is the real `msg.sender` for propose / cancel / withdraw, so the
 *      failures are genuine rather than staged by naming it as a passive recipient.
 */
contract EthDeliveryFallbackTest is TokenCompatBase {
    uint256 internal constant EXTRA_ETH = uint256(MATCHER_GAS_COMP) + SETTLER_REWARD + OPEN_EXEC_COMP;

    function setUp() public {
        _setUpTokenCompat();

        // the rejecting contract funds ERC20 collateral through Permit2, by its own call
        collat.mint(address(rejector), 1_000_000e18);
        rejector.approveToken(address(collat), PERMIT2, type(uint256).max);
    }

    function _rejectorCfg(address collatToken)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _tokenCfg(address(tokenA), address(tokenB), collatToken, false);
        s.maturityWindow = 1; // mature at the closing execution, for the terminal case
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. OpenPunt payEth fallback -> tempHolding
    // ══════════════════════════════════════════════════════════════════

    function test_payEthFallbackCreatesExactlyOneTempHoldingClaim() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _rejectorCfg(address(collat));

        uint256 collatBefore = collat.balanceOf(address(rejector));
        Proposal memory p = _rejectorPropose(s, m, EXTRA_ETH);
        assertEq(p.swap.swapper, address(rejector), "the rejecting contract really is the swapper");
        assertEq(collat.balanceOf(address(rejector)), collatBefore - MARGIN_S, "collateral paid in");

        EthClaims memory before = _ethClaims(address(rejector));
        uint256 coreEthBefore = address(punt).balance;

        // the contract cancels its own proposal, while still refusing ETH
        assertTrue(rejector.rejectEth(), "ETH rejection is enabled");
        _rejectorCall(address(punt), 0, abi.encodeCall(openPunt.cancelSwapOpen, (p.swapId, p.swap, p.preimage)));

        // collateral came back normally; the ETH became exactly one tempHolding claim
        assertEq(collat.balanceOf(address(rejector)), collatBefore, "collateral returned in full");
        _assertSingleClaim(before, address(rejector), 0, EXTRA_ETH, "payEth fallback");
        assertEq(punt.swaps(p.swapId), bytes32(0), "proposal deleted");
        assertEq(address(punt).balance, coreEthBefore, "the core still holds the ETH it now owes");

        // ── withdrawal fails while ETH is still refused, restoring the claim ─
        vm.expectRevert(PuntErrors.EthTransferFailed.selector);
        _rejectorCall(address(punt), 0, abi.encodeCall(openPunt.withdraw, (address(rejector), false)));
        assertEq(punt.tempHolding(address(rejector)), EXTRA_ETH, "the failed withdrawal restored the whole claim");
        assertEq(address(rejector).balance, before.raw, "and nothing was delivered");

        // ── then accept ETH and withdraw for real ────────────────────────
        rejector.setRejectEth(false);
        uint256 rawBeforeWithdraw = address(rejector).balance;
        _rejectorCall(address(punt), 0, abi.encodeCall(openPunt.withdraw, (address(rejector), false)));

        assertEq(address(rejector).balance - rawBeforeWithdraw, EXTRA_ETH, "exact amount received");
        assertEq(punt.tempHolding(address(rejector)), 0, "claim cleared");
        assertEq(_spendable(address(rejector), address(0)), 0, "no oracle credit was ever created for this");

        // a second withdrawal cannot pay it again
        vm.expectRevert(PuntErrors.NothingToWithdraw.selector);
        _rejectorCall(address(punt), 0, abi.encodeCall(openPunt.withdraw, (address(rejector), false)));

        assertEq(address(punt).balance, 0, "the core retains no unclaimed ETH");
        _assertModuleHoldsNothing(address(tokenA), address(tokenB), "payEth fallback");
    }

    /// @dev `leaveOne` keeps precisely the one-wei sentinel and nothing more.
    function test_withdrawalCanLeaveExactlyTheSentinel() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _rejectorCfg(address(collat));
        Proposal memory p = _rejectorPropose(s, m, EXTRA_ETH);
        _rejectorCall(address(punt), 0, abi.encodeCall(openPunt.cancelSwapOpen, (p.swapId, p.swap, p.preimage)));
        assertEq(punt.tempHolding(address(rejector)), EXTRA_ETH, "claim recorded");

        rejector.setRejectEth(false);
        uint256 rawBefore = address(rejector).balance;
        _rejectorCall(address(punt), 0, abi.encodeCall(openPunt.withdraw, (address(rejector), true)));

        assertEq(address(rejector).balance - rawBefore, EXTRA_ETH - 1, "everything except the sentinel");
        assertEq(punt.tempHolding(address(rejector)), 1, "precisely the requested sentinel remains");
        assertEq(address(punt).balance, 1, "and the core holds exactly that");
    }

    // ══════════════════════════════════════════════════════════════════
    //  5a. Oracle pushOrCredit fallback, core-side (cancelSwapOpen)
    // ══════════════════════════════════════════════════════════════════

    /// @dev Native-ETH collateral: the margin refund goes through `oracle.pushOrCredit` and the
    ///      compensations through `payEth`. Two failures reach two different ledgers.
    function test_bothFallbacksFireIntoSeparateLedgersOnCancellation() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _rejectorCfg(address(0));

        uint256 value = EXTRA_ETH + MARGIN_S;
        Proposal memory p = _rejectorPropose(s, m, value);
        assertEq(_spendable(address(punt), address(0)), MARGIN_S, "core holds the ETH margin internally");

        EthClaims memory before = _ethClaims(address(rejector));
        _rejectorCall(address(punt), 0, abi.encodeCall(openPunt.cancelSwapOpen, (p.swapId, p.swap, p.preimage)));

        // margin -> oracle internal ledger; compensations -> tempHolding; raw untouched
        EthClaims memory after_ = _ethClaims(address(rejector));
        assertEq(after_.raw, before.raw, "no raw ETH delivered at all");
        assertEq(
            after_.oracleInternal - before.oracleInternal, MARGIN_S, "the ETH MARGIN became an oracle internal credit"
        );
        assertEq(
            after_.tempHolding - before.tempHolding, EXTRA_ETH, "the COMPENSATIONS became a separate tempHolding claim"
        );
        assertTrue(MARGIN_S != EXTRA_ETH, "the two claims are distinguishable amounts");
        assertEq(punt.swaps(p.swapId), bytes32(0), "proposal deleted");
        assertEq(_spendable(address(punt), address(0)), 0, "core's own oracle ETH drained");

        // ── recover the oracle credit to an accepting recipient ──────────
        uint256 acceptingBefore = accepting.balance;
        _rejectorCall(address(oracle), 0, abi.encodeCall(IOpenOracle2.withdrawTo, (address(0), MARGIN_S, accepting)));
        assertEq(accepting.balance - acceptingBefore, MARGIN_S, "oracle credit recovered to an accepting address");
        assertEq(_spendable(address(rejector), address(0)), 0, "oracle credit fully drawn down");

        // ── recover the tempHolding claim separately, through OpenPunt ────
        rejector.setRejectEth(false);
        uint256 rawBefore = address(rejector).balance;
        _rejectorCall(address(punt), 0, abi.encodeCall(openPunt.withdraw, (address(rejector), false)));
        assertEq(address(rejector).balance - rawBefore, EXTRA_ETH, "tempHolding recovered independently");
        assertEq(punt.tempHolding(address(rejector)), 0, "claim cleared");
    }

    // ══════════════════════════════════════════════════════════════════
    //  5b. Oracle pushOrCredit fallback, module-side (terminal close)
    // ══════════════════════════════════════════════════════════════════

    /// @dev The terminal payout runs inside the delegatecalled lifecycle module, so this is a
    ///      genuinely different execution context from the core-side cancellation above.
    function test_terminalPayoutFallsBackToOracleCreditFromTheModule() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _rejectorCfg(address(0));

        Proposal memory p = _rejectorPropose(s, m, EXTRA_ETH + MARGIN_S);
        Matched memory mt = _matchSwapWith(p, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);
        assertTrue(active.active, "the rejecting contract owns a live position");

        // asymmetric payout, so assigning the wrong party is detectable
        Matched memory closing =
            _reportOnPositionWithAmounts(p.swapId, _noDutch(), active, p.preimage, reporter, 0, OA1, A2_CLOSE_UP);

        EthClaims memory before = _ethClaims(address(rejector));
        uint256 matcherEthBefore = _spendable(matcher, address(0));

        _advanceToSettlementEligibility();
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, closing.game, closing.helper, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, p.swapId);
        assertEq(owedS + owedM, uint256(MARGIN_S) + MARGIN_M, "pool conserved");
        assertEq(owedS, EXPECTED_OWED_SWAPPER, "hand-derived swapper entitlement");
        assertEq(owedM, EXPECTED_OWED_MATCHER, "hand-derived matcher entitlement");
        assertTrue(owedS != owedM, "the two entitlements differ, so party assignment is checkable");

        // The swapper's entitlement became an oracle credit, not raw ETH or tempHolding.
        _assertSingleClaim(before, address(rejector), owedS, 0, "module-side pushOrCredit fallback");
        assertEq(_spendable(matcher, address(0)) - matcherEthBefore, owedM, "matcher received its own entitlement");

        assertEq(punt.swaps(p.swapId), bytes32(0), "position deleted");
        (uint128 pending,, bool intent) = _closeState(p.swapId);
        assertEq(pending, 0, "close state deleted");
        assertFalse(intent, "close state deleted");
        assertEq(_spendable(address(punt), address(0)), 0, "core holds no position ETH");
        _assertModuleHoldsNothing(address(tokenA), address(tokenB), "module-side fallback");

        // recover to an accepting address
        uint256 acceptingBefore = accepting.balance;
        _rejectorCall(address(oracle), 0, abi.encodeCall(IOpenOracle2.withdrawTo, (address(0), owedS, accepting)));
        assertEq(accepting.balance - acceptingBefore, owedS, "credit withdrawn to an accepting recipient");
        assertEq(_spendable(address(rejector), address(0)), 0, "nothing left behind");
    }

    /// @dev Once the contract accepts ETH again, the same terminal path delivers raw ETH and creates
    ///      no credit at all — the two outcomes are mutually exclusive.
    function test_acceptingSwapperIsPaidRawWithNoFallbackCredit() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _rejectorCfg(address(0));

        Proposal memory p = _rejectorPropose(s, m, EXTRA_ETH + MARGIN_S);
        Matched memory mt = _matchSwapWith(p, OA2, matcher);
        openingReportTs = mt.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);

        Matched memory closing =
            _reportOnPositionWithAmounts(p.swapId, _noDutch(), active, p.preimage, reporter, 0, OA1, A2_CLOSE_UP);

        rejector.setRejectEth(false); // now it accepts
        EthClaims memory before = _ethClaims(address(rejector));

        _advanceToSettlementEligibility();
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, closing.game, closing.helper, false);
        (uint256 owedS, uint256 owedM) = _readPositionClosed(vm.getRecordedLogs(), p.swapId);
        assertEq(owedS, EXPECTED_OWED_SWAPPER, "hand-derived swapper entitlement");
        assertTrue(owedS != owedM, "asymmetric, so the recipient is checkable");

        EthClaims memory after_ = _ethClaims(address(rejector));
        assertEq(after_.raw - before.raw, owedS, "paid RAW this time");
        assertEq(after_.oracleInternal, before.oracleInternal, "and no fallback credit was created");
        assertEq(after_.tempHolding, before.tempHolding, "and no tempHolding claim either");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  5c. Externally funded Dutch remainder uses the same push-or-credit route
    // ══════════════════════════════════════════════════════════════════════════

    function test_externalDutchRemainderFallsBackToOracleCredit() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _rejectorCfg(address(0));

        Proposal memory p = _rejectorPropose(s, m, EXTRA_ETH + MARGIN_S);
        Matched memory opening = _matchSwapWith(p, OA2, matcher);
        openingReportTs = opening.game.lastReportOppoTime;
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(opening, executor);

        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        uint256 closeValue = uint256(input.maxReward) + CLOSE_COMP;
        vm.recordLogs();
        _rejectorCall(
            address(punt),
            closeValue,
            abi.encodeCall(punt.close, (p.swapId, input, active, false, _emptyPermit2(), CLOSE_COMP))
        );
        OpenPuntStorage.CloseDutch memory dutch = _decodeCloseAuctionStarted(vm.getRecordedLogs(), p.swapId);
        assertFalse(dutch.useInternalBalances, "fixture: auction was externally funded");

        _advanceTimeAndBlocks(60, 30); // round one: reward 15e18, remainder 85e18
        uint256 reward = uint256(dutch.startingReward) * dutch.growthRate / 10_000;
        uint256 remainder = uint256(dutch.maxReward) - reward;
        EthClaims memory before = _ethClaims(address(rejector));

        Matched memory closing =
            _reportOnPositionWithAmounts(p.swapId, dutch, active, p.preimage, reporter, REPORTER_COMP, OA1, OA2);

        _assertSingleClaim(before, address(rejector), remainder, 0, "Dutch remainder pushOrCredit fallback");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(closing.swap)), "report committed before delivery");
        assertEq(_storedDutchState(p.swapId), bytes32(0), "claimed auction deleted before delivery");
        assertEq(
            punt.executionGasComp(closing.reportId),
            uint256(CLOSE_COMP) + REPORTER_COMP,
            "execution compensation committed"
        );

        uint256 acceptingBefore = accepting.balance;
        _rejectorCall(
            address(oracle), 0, abi.encodeCall(IOpenOracle2.withdrawTo, (address(0), uint128(remainder), accepting))
        );
        assertEq(accepting.balance - acceptingBefore, remainder, "fallback credit remains recoverable");
    }
}
