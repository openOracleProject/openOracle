// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice Policy, commitment, discovery, and lifecycle coverage for swap-selected oracle flags.
 */
contract OracleFlagsTest is OpenPuntBase {
    function setUp() public {
        _setUpAll();
        collat.mint(swapper, type(uint96).max);
    }

    function test_acceptsEveryDefinedOptionalFlagInBlockMode() public {
        uint8[7] memory accepted = [
            ORACLE_FLAG_STORE_SETTLEMENT_ELIGIBILITY,
            ORACLE_FLAG_STORE_SETTLEMENT_ELIGIBILITY | ORACLE_FLAG_TRACK_DISPUTES,
            ORACLE_FLAG_STORE_SETTLEMENT_ELIGIBILITY | ORACLE_FLAG_STORE_ALL,
            ORACLE_FLAG_STORE_SETTLEMENT_ELIGIBILITY | ORACLE_FLAG_STORE_PRICE,
            ORACLE_FLAG_STORE_SETTLEMENT_ELIGIBILITY | ORACLE_FLAG_FEES_ONLY_AT_HALT,
            ORACLE_FLAG_STORE_SETTLEMENT_ELIGIBILITY | ORACLE_FLAG_FLEXIBLE_ESCALATION,
            uint8(0x7e)
        ];

        for (uint256 i = 0; i < accepted.length; i++) {
            OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
            s.oracleFlags = accepted[i];
            _proposeOk(s, _defaultMatcherPreimage(), "defined block-mode oracle flags");
        }
    }

    function test_rejectsTimeModeMissingEligibilityAndUndefinedFlags() public {
        uint8[5] memory rejected = [
            uint8(0),
            ORACLE_FLAG_TRACK_DISPUTES,
            ORACLE_FLAG_TIME_TYPE | ORACLE_FLAG_STORE_SETTLEMENT_ELIGIBILITY,
            uint8(0x90),
            type(uint8).max
        ];

        for (uint256 i = 0; i < rejected.length; i++) {
            OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
            s.oracleFlags = rejected[i];
            _proposeBad(s, _defaultMatcherPreimage(), PuntErrors.InvalidOracleParams.selector, "invalid oracle flags");
        }
    }

    function test_flagsRemainDiscoverableAndFlowToTheCorrectOracleGames() public {
        OpenPuntStorage.ProposedSwap memory input = _defaultProposedSwap();
        input.oracleFlags = 0x7e;

        Proposal memory p = _proposeWith(input, _defaultMatcherPreimage(), swapper);
        assertEq(p.swap.oracleFlags, input.oracleFlags, "SwapProposed exposes the selected flags");

        Matched memory opening = _matchSwap(p);
        assertEq(opening.swap.oracleFlags, input.oracleFlags, "SwapMatched carries the selected flags");
        assertEq(
            opening.game.flags,
            input.oracleFlags & ~ORACLE_FLAG_STORE_SETTLEMENT_ELIGIBILITY,
            "opening strips only settlement-eligibility storage"
        );
        assertEq(oracle.settlementEligibility(opening.reportId), 0, "opening creates no eligibility sidecar");

        _advanceToSettlementEligibility();
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(opening, executor);
        assertEq(active.oracleFlags, input.oracleFlags, "PositionOpened preserves the selected flags");

        OpenPuntStorage.CloseDutch memory dutchInput = _defaultCloseDutch();
        vm.recordLogs();
        vm.prank(swapper);
        punt.close{value: CLOSE_EXEC_COMP}(
            p.swapId,
            dutchInput,
            active,
            false,
            _emptyPermit2(),
            CLOSE_EXEC_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory auctionLog = _findLog(logs, address(punt), OpenPuntStorage.CloseAuctionStarted.selector, p.swapId);
        (OpenPuntStorage.MatchedSwap memory discovered, OpenPuntStorage.CloseDutch memory dutch,) =
            abi.decode(auctionLog.data, (OpenPuntStorage.MatchedSwap, OpenPuntStorage.CloseDutch, uint128));
        assertEq(discovered.oracleFlags, input.oracleFlags, "CloseAuctionStarted exposes flags to Dutch reporters");

        Matched memory closing = _reportOnPosition(p.swapId, dutch, discovered, p.preimage, reporter, REPORT_EXEC_COMP);
        assertEq(closing.swap.oracleFlags, input.oracleFlags, "PositionReportStarted preserves the selected flags");
        assertEq(closing.game.flags, input.oracleFlags, "active report forwards every selected flag");
        assertEq(closing.game.numReports, 1, "tracked closing game starts with one report");
        assertEq(
            oracle.settlementEligibility(closing.reportId),
            closing.game.reportTimestamp + closing.game.settlementTime,
            "active report stores settlement eligibility"
        );

        uint256 originalEligibility = oracle.settlementEligibility(closing.reportId);
        uint256 hopBlocks = uint256(closing.game.disputeDelay) + 1;
        _advanceTimeAndBlocks(_secondsForBlocks(hopBlocks), hopBlocks);

        uint128 disputedAmount1 = uint128(uint256(closing.game.currentAmount1) * closing.game.multiplier / 100);
        uint128 disputedAmount2 = uint128(uint256(closing.game.currentAmount2) * closing.game.multiplier / 100);

        vm.recordLogs();
        vm.prank(matcher);
        IOpenOracle2(address(oracle)).dispute(
            closing.reportId,
            disputedAmount1,
            disputedAmount2,
            matcher,
            true,
            true,
            closing.game,
            closing.helper,
            _noTiming()
        );
        Vm.Log memory disputedLog =
            _findLog(vm.getRecordedLogs(), address(oracle), OpenOracle.ReportDisputed.selector, closing.reportId);
        IOpenOracle2.OracleGame memory disputedGame = PackedDecoder.decodeOracleGame(disputedLog.data);
        IOpenOracle2.PreimageHelper memory disputedHelper =
            PackedDecoder.decodeHelperTail(disputedLog.data, closing.reportId);

        assertEq(disputedGame.flags, input.oracleFlags, "dispute preserves every selected flag");
        assertEq(disputedGame.numReports, 2, "tracked dispute increments numReports");
        assertEq(disputedGame.currentAmount1, disputedAmount1, "event reconstructs disputed amount1");
        assertEq(disputedGame.currentAmount2, disputedAmount2, "event reconstructs disputed amount2");
        assertEq(disputedGame.currentReporter, matcher, "event reconstructs the disputer");
        assertEq(
            keccak256(abi.encode(disputedHelper)),
            keccak256(abi.encode(closing.helper)),
            "dispute preserves the original report helper"
        );
        assertEq(
            oracle.oracleGame(closing.reportId),
            keccak256(abi.encode(disputedGame, disputedHelper)),
            "event-derived disputed preimage reconstructs the oracle commitment"
        );

        uint256 disputedEligibility = oracle.settlementEligibility(closing.reportId);
        assertGt(disputedEligibility, originalEligibility, "dispute advances settlement eligibility");
        assertEq(
            disputedEligibility,
            disputedGame.reportTimestamp + disputedGame.settlementTime,
            "updated eligibility matches the disputed preimage"
        );

        _advanceToSettlementEligibility();
        vm.recordLogs();
        vm.prank(closeExecutor);
        puntLifecycle.execute(p.swapId, closing.swap, disputedGame, disputedHelper, 0);
        _findLog(vm.getRecordedLogs(), address(punt), OpenPuntStorage.PositionClosed.selector, p.swapId);
        assertEq(punt.swaps(p.swapId), bytes32(0), "disputed closing report terminates the position");
        assertEq(punt.swapIdToReportId(p.swapId), 0, "terminal execution clears the report binding");
    }

    function test_oracleFlagsAreBoundByBothProposalAndMatchedHashes() public {
        Proposal memory p = _propose();
        bytes32 proposedHash = punt.swaps(p.swapId);

        OpenPuntStorage.ProposedSwap memory tamperedProposal = _copy(p.swap);
        tamperedProposal.oracleFlags |= ORACLE_FLAG_TRACK_DISPUTES;
        vm.prank(matcher);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.matchSwap(p.swapId, AMOUNT2, tamperedProposal, p.preimage, _noTiming(), matcher);
        assertEq(punt.swaps(p.swapId), proposedHash, "tampered proposal flags leave the proposal intact");

        Matched memory opening = _matchSwap(p);
        bytes32 matchedHash = punt.swaps(p.swapId);
        OpenPuntStorage.MatchedSwap memory tamperedMatched = _copy(opening.swap);
        tamperedMatched.oracleFlags |= ORACLE_FLAG_TRACK_DISPUTES;

        vm.prank(executor);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        puntLifecycle.execute(p.swapId, tamperedMatched, opening.game, opening.helper, 0);
        assertEq(punt.swaps(p.swapId), matchedHash, "tampered matched flags leave the position intact");
    }
}
