// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice Proves an off-chain participant holding only transaction logs can advance the
 *         whole lifecycle: every committed hash is reconstructible from events alone,
 *         with no hidden state reads and nothing fabricated.
 *
 *         Each stage feeds the *decoded* struct into the next real call, so a decode
 *         error cannot be papered over by a locally-built struct.
 */
contract HashAndEventRoundTripTest is OpenPuntBase {
    function setUp() public {
        _setUpAll();
    }

    function test_fullLifecycleReconstructibleFromLogsOnly() public {
        // ── 1-4. propose ────────────────────────────────────────────────
        OpenPuntStorage.ProposedSwap memory input = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory inputM = _defaultMatcherPreimage();
        uint48 proposeTs = uint48(vm.getBlockTimestamp());

        Proposal memory p = _proposeWith(input, inputM, swapper);

        // runtime overrides, as emitted
        assertEq(p.swap.swapper, swapper, "swapper override == caller");
        assertEq(p.swap.expiration, proposeTs + EXPIRATION_WINDOW, "expiration became absolute");
        assertEq(p.preimage.startFulfillFeeIncrease, proposeTs, "startFulfillFeeIncrease == proposal timestamp");

        // Every other field survives verbatim: build the complete expected structs from the
        // caller's own input plus exactly the three documented overrides, then compare the
        // full encodings. This covers fields no individual assertion above names.
        // _copy() keeps `input` / `inputM` intact as the control: plain memory assignment
        // would alias them and the "expected" struct would no longer be independent.
        OpenPuntStorage.ProposedSwap memory expectedSwap = _copy(input);
        expectedSwap.swapper = swapper;
        expectedSwap.expiration = proposeTs + input.expiration;

        OpenPuntStorage.MatcherPreimage memory expectedPreimage = _copy(inputM);
        expectedPreimage.startFulfillFeeIncrease = proposeTs;

        assertEq(
            keccak256(abi.encode(p.swap)),
            keccak256(abi.encode(expectedSwap)),
            "emitted ProposedSwap == input with only the swapper/expiration overrides"
        );
        assertEq(
            keccak256(abi.encode(p.preimage)),
            keccak256(abi.encode(expectedPreimage)),
            "emitted MatcherPreimage == input with only the startFulfillFeeIncrease override"
        );

        assertEq(
            punt.swaps(p.swapId),
            keccak256(abi.encode(p.swap, p.preimage)),
            "SwapProposed reconstructs the stored proposal hash"
        );

        // ── 5-9. match, using only decoded event values ─────────────────
        uint48 matchTs = uint48(vm.getBlockTimestamp());
        Matched memory mt = _matchSwap(p);

        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(mt.swap)), "SwapMatched reconstructs stored matched hash");
        assertEq(punt.swapIdToReportId(p.swapId), mt.reportId, "sidecar reportId matches oracle log topic");
        assertEq(
            mt.swap.matcherPreimageHash,
            keccak256(abi.encode(p.preimage)),
            "matcherPreimageHash binds the emitted preimage"
        );
        assertEq(mt.swap.start, matchTs, "matched start == match timestamp");
        assertFalse(mt.swap.active, "not active before opening execution");

        // packed oracle log reconstructs the oracle's own committed hash
        assertEq(
            oracle.oracleGame(mt.reportId),
            keccak256(abi.encode(mt.game, mt.helper)),
            "ReportSubmitted reconstructs the oracle state hash"
        );
        assertEq(mt.helper.creator, address(punt), "oracle game creator is the core");
        assertEq(mt.game.currentReporter, matcher, "matcher is the opening reporter");
        assertEq(mt.game.currentAmount1, INITIAL_LIQUIDITY, "amount1 from log");
        assertEq(mt.game.currentAmount2, AMOUNT2, "amount2 from log");

        // ── 10-11. opening execution ────────────────────────────────────
        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(mt, executor);

        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(active)), "PositionOpened reconstructs stored hash");
        assertTrue(active.active, "active after opening");
        assertEq(punt.swapIdToReportId(p.swapId), 0, "no live report after opening");

        // ── 12. close auction ───────────────────────────────────────────
        OpenPuntStorage.CloseDutch memory dutch = _close(p.swapId, active, CLOSE_EXEC_COMP);

        assertEq(
            _storedAuctionHash(p.swapId, active),
            keccak256(abi.encode(dutch)),
            "CloseAuctionStarted reconstructs stored dutch hash"
        );
        assertEq(dutch.swapper, swapper, "dutch swapper override");
        assertEq(dutch.collatToken, address(collat), "dutch collatToken override");
        assertEq(dutch.swapId, p.swapId, "dutch swapId override");
        assertEq(dutch.start, uint48(vm.getBlockTimestamp()), "dutch start override");
        assertFalse(dutch.useInternalBalances, "dutch useInternalBalances override");

        // ── 13. closing report from event-reconstructed state ───────────
        Matched memory closing = _reportOnPosition(p.swapId, dutch, active, p.preimage, reporter, REPORT_EXEC_COMP);

        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(active)), "active position hash remains stable");
        assertEq(
            oracle.oracleGame(closing.reportId),
            keccak256(abi.encode(closing.game, closing.helper)),
            "closing ReportSubmitted reconstructs the oracle state hash"
        );
        assertTrue(closing.reportId != mt.reportId, "closing report is a new oracle game");
        assertEq(closing.game.currentReporter, reporter, "reporter is the closing reporter");
        assertEq(closing.helper.creator, address(punt), "closing game creator is the core");
        assertEq(punt.swapIdToReportId(p.swapId), closing.reportId, "sidecar points at the closing game");
        assertTrue(closing.swap.active, "still active while the closing game runs");
    }

    /// @dev The oracle's packed payload must round-trip field-for-field against the
    ///      timing the chain actually had, otherwise later preimage submissions would
    ///      silently drift.
    function test_packedOracleLogMatchesChainTiming() public {
        Proposal memory p = _propose();

        uint48 reportTs = uint48(vm.getBlockTimestamp());
        uint48 reportBn = uint48(vm.getBlockNumber());
        Matched memory mt = _matchSwap(p);

        // In block mode (flags: 0), `reportTimestamp` carries the report's block number and
        // `lastReportOppoTime` carries the wall clock. Both are asserted
        // against the chain values captured immediately before the match.
        assertEq(mt.game.reportTimestamp, reportBn, "reportTimestamp holds the BLOCK NUMBER");
        assertEq(mt.game.lastReportOppoTime, reportTs, "lastReportOppoTime holds the WALL CLOCK");
        assertEq(mt.game.settlementTimestamp, 0, "unsettled");
        assertEq(mt.game.settlementTime, SETTLEMENT_BLOCKS, "settlementTime");
        assertEq(mt.game.disputeDelay, DISPUTE_DELAY, "disputeDelay");
        assertEq(mt.game.escalationHalt, ESCALATION_HALT, "escalationHalt");
        assertEq(mt.game.multiplier, MULTIPLIER, "multiplier");
        assertEq(mt.game.protocolFee, PROTOCOL_FEE, "protocolFee");
        assertEq(mt.game.protocolFeeRecipient, address(0), "no fee recipient at zero protocol fee");
        assertEq(mt.game.settlerReward, SETTLER_REWARD, "settlerReward forwarded to the oracle");
        assertEq(mt.game.token1, address(tokenA), "token1");
        assertEq(mt.game.token2, address(tokenB), "token2");
        assertEq(mt.game.feePercentage, 0, "feePercentage");
        assertEq(mt.game.callbackContract, address(0), "no callback");
        assertEq(mt.game.callbackGasLimit, 0, "no callback gas");
        assertEq(mt.game.numReports, 0, "dispute tracking disabled");
        // OpenPunt creates its games with flags == 0: FLAG_TIME_TYPE clear, so the game clock
        // counts blocks, and dispute tracking / store-all / store-price are all off.
        assertEq(mt.game.flags, 0, "block clock, no optional oracle features");

        assertEq(mt.helper.reportId, mt.reportId, "helper reportId from topic");
        assertEq(mt.helper.blockTimestamp, reportTs, "helper blockTimestamp");
        assertEq(mt.helper.blockNumber, reportBn, "helper blockNumber");
    }

    /// @dev A decoded struct with any single field perturbed must be rejected by the
    ///      *deployed contract*, not merely by a locally recomputed hash. Each mutation is
    ///      pushed through a real routed lifecycle call. The position-hash gate is the first
    ///      check in `execute`, so it fires before any oracle argument is inspected — which
    ///      is why empty oracle arguments are sufficient to isolate it here.
    function test_perturbedStateIsRejectedByTheContract() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openPosition();

        bytes32 genuine = punt.swaps(swapId);
        assertEq(genuine, keccak256(abi.encode(active)), "baseline reconstructs");

        // _copy() is required: plain memory assignment would alias `active` and make the
        // three mutations cumulative rather than independent.
        OpenPuntStorage.MatchedSwap memory tampered = _copy(active);
        tampered.initialMarginSwapper += 1;
        _assertRoutedExecuteRejects(swapId, tampered, genuine, "initialMarginSwapper");

        tampered = _copy(active);
        tampered.maturity += 1;
        _assertRoutedExecuteRejects(swapId, tampered, genuine, "maturity");

        tampered = _copy(active);
        tampered.openExecutionComp += 1;
        _assertRoutedExecuteRejects(swapId, tampered, genuine, "openExecutionComp");

        // the genuine state is still exactly what the contract holds after all rejections
        assertEq(punt.swaps(swapId), keccak256(abi.encode(active)), "genuine state survives every rejection");
    }

    /// @dev Pushes a tampered position through routed `execute()` and requires the core to
    ///      reject it with WrongHash while leaving the stored position hash untouched.
    function _assertRoutedExecuteRejects(
        uint256 swapId,
        OpenPuntStorage.MatchedSwap memory tampered,
        bytes32 genuine,
        string memory field
    ) internal {
        IOpenOracle2.OracleGame memory g;
        IOpenOracle2.PreimageHelper memory h;

        assertTrue(keccak256(abi.encode(tampered)) != genuine, string.concat(field, ": mutation changed the encoding"));

        vm.prank(executor);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.execute(swapId, tampered, g, h, 0);

        assertEq(punt.swaps(swapId), genuine, string.concat(field, ": stored position hash unchanged"));
    }
}
