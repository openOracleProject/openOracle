// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LivenessBase.t.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

/**
 * @notice End-to-end coverage for the per-token dispute-cost commitment.
 *
 * @dev The fixture chooses a rate that makes the arithmetic observable at tiny base fees:
 *      1e18 token1 units support 20,000 wei equivalent base fee at match/execute, while
 *      report()'s deliberate 90% liquidity haircut supports exactly 18,000 wei. Report tests
 *      subtract the Fjord reference's live L1 equivalent to obtain the exact L2 boundary.
 */
contract DisputeGasCostTest is LivenessBase {
    using stdStorage for StdStorage;

    uint128 internal constant MAX_DISPUTE_COST = 2e9;
    uint256 internal constant DISPUTE_SCALE = 1e18;
    uint32 internal constant DISPUTE_GAS = 100_000;
    uint256 internal constant MATCH_BASE_FEE_LIMIT = 20_000;
    uint256 internal constant REPORT_EQUIVALENT_FEE_LIMIT = 18_000;
    uint256 internal constant CALIBRATED_DISPUTE_SIZE = 320;
    uint256 internal constant OPEN_BASE_FEE = 1_000;
    uint256 internal constant RECOVERY_DELAY = 60 hours;

    function setUp() public {
        _setUpLiveness();
        vm.fee(0);
    }

    function _gasTerms(uint48 maturityWindow)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        LiveCfg memory c = _defaultLiveCfg();
        c.maturityWindow = maturityWindow;
        (s, m) = _liveCfg(c);
        s.oracleFlags |= ORACLE_FLAG_TRACK_DISPUTES;
        s.maxDisputeCostPerToken1 = MAX_DISPUTE_COST;
        s.estimatedDisputeGas = DISPUTE_GAS;
    }

    function _proposeGasTerms(uint48 maturityWindow) internal returns (Proposal memory p) {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _gasTerms(maturityWindow);
        p = _proposeWith(s, m, swapper);
    }

    function _openGasPosition(uint48 maturityWindow)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _gasTerms(maturityWindow);
        return _openGasPositionWithTerms(s, m);
    }

    function _openGasPositionWithTerms(OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p)
    {
        vm.fee(OPEN_BASE_FEE);
        p = _proposeWith(s, m, swapper);
        Matched memory opening = _matchSwapWith(p, A2_OPEN, matcher);
        _advanceValid(_secondsForBlocks(p.preimage.settlementTime) + 2);
        active = _executeOpening(opening, executor);
        swapId = p.swapId;
        assertEq(
            active.maxDisputeCostPerToken1, s.maxDisputeCostPerToken1, "active position preserves dispute-cost limit"
        );
        assertEq(active.estimatedDisputeGas, s.estimatedDisputeGas, "active position preserves gas estimate");
    }

    function _ceilDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    function _l1Fee() internal view returns (uint256) {
        return gasPriceOracle.getL1FeeUpperBound(CALIBRATED_DISPUTE_SIZE);
    }

    function _l1EquivalentBaseFee() internal view returns (uint256) {
        return _ceilDiv(_l1Fee(), DISPUTE_GAS);
    }

    function _adjustedBaseFee(uint256 l2BaseFee) internal view returns (uint256) {
        return l2BaseFee + _l1EquivalentBaseFee();
    }

    function _reportL2BaseFeeLimit() internal view returns (uint256) {
        uint256 l1Equivalent = _l1EquivalentBaseFee();
        assertLt(l1Equivalent, REPORT_EQUIVALENT_FEE_LIMIT, "fixture leaves an observable L2 boundary");
        return REPORT_EQUIVALENT_FEE_LIMIT - l1Equivalent;
    }

    function _gasMinimumReportAmount(uint256 adjustedBaseFee) internal pure returns (uint128) {
        uint256 discountedRequired = _ceilDiv(adjustedBaseFee * DISPUTE_SCALE * DISPUTE_GAS, MAX_DISPUTE_COST);
        return uint128(_ceilDiv(discountedRequired * 10, 9));
    }

    function _paddedNonFlexibleCeiling(uint256 adjustedBaseFee) internal pure returns (uint128) {
        uint256 required = _gasMinimumReportAmount(adjustedBaseFee);
        return uint128(_ceilDiv(required * 9, 8));
    }

    function _disputeAtBaseFee(Matched memory mt, address who, uint256 baseFee)
        internal
        returns (Matched memory disputed)
    {
        uint256 hopBlocks = uint256(mt.game.disputeDelay) + 1;
        _advanceTimeAndBlocks(_secondsForBlocks(hopBlocks), hopBlocks);
        uint128 disputedAmount1 = uint128(uint256(mt.game.currentAmount1) * mt.game.multiplier / 100);
        uint128 disputedAmount2 = uint128(uint256(mt.game.currentAmount2) * mt.game.multiplier / 100);

        vm.fee(baseFee);
        vm.recordLogs();
        vm.prank(who);
        IOpenOracle2(address(oracle)).dispute(
            mt.reportId, disputedAmount1, disputedAmount2, who, true, true, mt.game, mt.helper, _noTiming()
        );
        Vm.Log memory disputedLog =
            _findLog(vm.getRecordedLogs(), address(oracle), OpenOracle.ReportDisputed.selector, mt.reportId);

        disputed = mt;
        disputed.game = PackedDecoder.decodeOracleGame(disputedLog.data);
        disputed.helper = PackedDecoder.decodeHelperTail(disputedLog.data, mt.reportId);
        assertEq(disputed.game.currentAmount1, disputedAmount1, "dispute records final amount1");
        assertEq(disputed.game.currentAmount2, disputedAmount2, "dispute records final amount2");
        assertEq(
            oracle.oracleGame(mt.reportId),
            keccak256(abi.encode(disputed.game, disputed.helper)),
            "event-derived disputed state reconstructs the oracle commitment"
        );
    }

    /// @dev Rewrites only the committed report counter so a real dispute can exercise uint24
    ///      saturation without executing more than sixteen million preceding disputes. stdStorage
    ///      discovers the oracleGame mapping slot from its getter rather than pinning a layout slot.
    function _setTrackedReportCount(Matched memory mt, uint24 numReports) internal returns (Matched memory updated) {
        updated = mt;
        updated.game.numReports = numReports;
        bytes32 updatedHash = keccak256(abi.encode(updated.game, updated.helper));
        stdstore.target(address(oracle)).sig("oracleGame(uint256)").with_key(updated.reportId).checked_write(
            updatedHash
        );
        assertEq(oracle.oracleGame(updated.reportId), updatedHash, "saturation fixture reconstructs oracle commitment");
    }

    function test_matchChecksExactBoundaryAndCopiesCommittedParameter() public {
        Proposal memory p = _proposeGasTerms(MATURITY_LONG);
        bytes32 proposalHash = punt.swaps(p.swapId);

        vm.fee(MATCH_BASE_FEE_LIMIT + 1);
        vm.prank(matcher);
        vm.expectRevert(PuntErrors.DisputeGasTooHigh.selector);
        punt.matchSwap(p.swapId, A2_OPEN, p.swap, p.preimage, _noTiming(), matcher);

        assertEq(punt.swaps(p.swapId), proposalHash, "failed match leaves proposal live");
        assertEq(punt.swapIdToReportId(p.swapId), 0, "failed match creates no oracle game");

        vm.fee(MATCH_BASE_FEE_LIMIT);
        Matched memory opening = _matchSwapWith(p, A2_OPEN, matcher);
        assertEq(opening.swap.maxDisputeCostPerToken1, MAX_DISPUTE_COST, "matched state copies the commitment");
        assertEq(opening.swap.estimatedDisputeGas, DISPUTE_GAS, "matched state copies the gas estimate");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(opening.swap)), "copied state is hash-bound");
    }

    function test_gasTermsAreBoundByProposalAndMatchedHashes() public {
        Proposal memory p = _proposeGasTerms(MATURITY_LONG);
        OpenPuntStorage.ProposedSwap memory alteredProposal =
            abi.decode(abi.encode(p.swap), (OpenPuntStorage.ProposedSwap));
        alteredProposal.maxDisputeCostPerToken1++;

        vm.prank(matcher);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.matchSwap(p.swapId, A2_OPEN, alteredProposal, p.preimage, _noTiming(), matcher);

        alteredProposal = abi.decode(abi.encode(p.swap), (OpenPuntStorage.ProposedSwap));
        alteredProposal.estimatedDisputeGas++;
        vm.prank(matcher);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.matchSwap(p.swapId, A2_OPEN, alteredProposal, p.preimage, _noTiming(), matcher);

        vm.fee(OPEN_BASE_FEE);
        Matched memory opening = _matchSwapWith(p, A2_OPEN, matcher);
        _advanceValid(_secondsForBlocks(p.preimage.settlementTime) + 2);
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(opening, executor);
        OpenPuntStorage.MatchedSwap memory alteredMatched =
            abi.decode(abi.encode(active), (OpenPuntStorage.MatchedSwap));
        alteredMatched.maxDisputeCostPerToken1++;

        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.liquidationHeartbeat(p.swapId, alteredMatched);

        alteredMatched = abi.decode(abi.encode(active), (OpenPuntStorage.MatchedSwap));
        alteredMatched.estimatedDisputeGas++;
        vm.prank(outsider);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.liquidationHeartbeat(p.swapId, alteredMatched);
    }

    function test_zeroEstimatedDisputeGasIsRejectedEvenWhenCostGateIsDisabled() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _gasTerms(MATURITY_LONG);
        s.maxDisputeCostPerToken1 = 0;
        s.estimatedDisputeGas = 0;

        _proposeBad(s, m, PuntErrors.InvalidDisputeGasEstimate.selector, "zero dispute-gas estimate");
    }

    function test_estimatedGasChangesTheMatchBoundary() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _gasTerms(MATURITY_LONG);
        s.estimatedDisputeGas = DISPUTE_GAS * 2;
        Proposal memory p = _proposeWith(s, m, swapper);
        uint256 scaledLimit = MATCH_BASE_FEE_LIMIT / 2;

        vm.fee(scaledLimit + 1);
        vm.prank(matcher);
        vm.expectRevert(PuntErrors.DisputeGasTooHigh.selector);
        punt.matchSwap(p.swapId, A2_OPEN, p.swap, p.preimage, _noTiming(), matcher);

        vm.fee(scaledLimit);
        Matched memory opening = _matchSwapWith(p, A2_OPEN, matcher);
        assertEq(opening.swap.estimatedDisputeGas, DISPUTE_GAS * 2, "selected estimate controls the boundary");
    }

    function test_zeroParameterDisablesTheGasGateThroughExecution() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _gasTerms(MATURITY_LONG);
        s.maxDisputeCostPerToken1 = 0;
        Proposal memory p = _proposeWith(s, m, swapper);

        vm.fee(type(uint64).max);
        Matched memory opening = _matchSwapWith(p, A2_OPEN, matcher);
        assertEq(opening.swap.maxDisputeCostPerToken1, 0, "disabled value copied unchanged");

        _advanceValid(_secondsForBlocks(p.preimage.settlementTime) + 2);
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(opening, executor);
        assertTrue(active.active, "zero parameter bypasses the recorded-fee execution check");

        // Removing the dependency proves report() does not even call the predeploy when the
        // committed gas gate is disabled.
        vm.etch(BASE_GAS_PRICE_ORACLE, hex"");
        Matched memory closing = _reportOnPositionWithAmounts(
            p.swapId, _noDutch(), active, p.preimage, reporter, 0, INITIAL_LIQUIDITY, A2_HEALTHY
        );
        _advanceValid(_secondsForBlocks(closing.game.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(p.swapId, closing, closeExecutor);
        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.DisputeGasBailout.selector, p.swapId),
            "disabled gate cannot produce a gas bailout"
        );
    }

    function test_trackingOffSkipsFinalRecordedFeeCheck() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _gasTerms(MATURITY_LONG);
        s.oracleFlags &= ~ORACLE_FLAG_TRACK_DISPUTES;

        vm.fee(OPEN_BASE_FEE);
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory opening = _matchSwapWith(p, A2_OPEN, matcher);
        Matched memory disputed = _disputeAtBaseFee(opening, matcher, type(uint64).max);
        assertEq(disputed.game.numReports, 0, "tracking-off oracle state has no report counter");

        _advanceValid(_secondsForBlocks(disputed.game.settlementTime) + 2);
        vm.fee(OPEN_BASE_FEE);
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(disputed, executor);
        assertTrue(active.active, "tracking off skips the final recorded-fee check");
    }

    function test_reportUsesNinetyPercentLiquidityAtItsExactBoundary() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openGasPosition(MATURITY_LONG);

        uint256 l1Fee = _l1Fee();
        assertGt(l1Fee, 0, "fixture supplies a real L1 component");
        assertNotEq(l1Fee % DISPUTE_GAS, 0, "fixture exercises ceiling division");
        vm.fee(_reportL2BaseFeeLimit());
        Matched memory closing = _reportOnPositionWithAmounts(
            swapId, _noDutch(), active, p.preimage, reporter, REPORT_EXEC_COMP, INITIAL_LIQUIDITY, A2_HEALTHY
        );
        assertEq(closing.game.currentAmount1, INITIAL_LIQUIDITY, "minimum report accepted at exact boundary");
    }

    function test_reportRejectsOneWeiPastNinetyPercentBoundaryWithoutStateChange() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openGasPosition(MATURITY_LONG);
        bytes32 storedBefore = punt.swaps(swapId);
        uint256 nextReportBefore = oracle.nextReportId();

        vm.fee(_reportL2BaseFeeLimit() + 1);
        vm.prank(reporter);
        vm.expectRevert(PuntErrors.DisputeGasTooHigh.selector);
        puntLifecycle.report(
            swapId, bytes32(0), active, p.preimage, _noTiming(), reporter, INITIAL_LIQUIDITY, A2_HEALTHY, 0
        );

        assertEq(punt.swaps(swapId), storedBefore, "position unchanged");
        assertEq(punt.swapIdToReportId(swapId), 0, "no report sidecar written");
        assertEq(oracle.nextReportId(), nextReportBefore, "no oracle game created");
    }

    function test_scaledGasTermsModelACompressedL1ShapeAtTheExactBoundary() public {
        uint256 k = 4;
        uint32 calibratedGas = DISPUTE_GAS / 2;
        uint256 modeledActualGas = uint256(calibratedGas) * k;
        uint256 modeledActualCostLimit = uint256(MAX_DISPUTE_COST) * k;
        uint256 discountedLiquidity = 9 * uint256(INITIAL_LIQUIDITY) / 10;

        uint256 modeledBoundary = discountedLiquidity * modeledActualCostLimit / DISPUTE_SCALE / modeledActualGas
            - _ceilDiv(k * _l1Fee(), modeledActualGas);
        uint256 committedBoundary =
            discountedLiquidity * MAX_DISPUTE_COST / DISPUTE_SCALE / calibratedGas - _ceilDiv(_l1Fee(), calibratedGas);
        assertEq(committedBoundary, modeledBoundary, "k-scaled parameters preserve the intended cost boundary");

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _gasTerms(MATURITY_LONG);
        s.estimatedDisputeGas = calibratedGas;

        (uint256 acceptedId, OpenPuntStorage.MatchedSwap memory accepted, Proposal memory acceptedP) =
            _openGasPositionWithTerms(s, m);
        vm.fee(committedBoundary);
        Matched memory closing = _reportOnPositionWithAmounts(
            acceptedId, _noDutch(), accepted, acceptedP.preimage, reporter, 0, INITIAL_LIQUIDITY, A2_HEALTHY
        );
        assertEq(closing.game.currentAmount1, INITIAL_LIQUIDITY, "scaled parameters accept their exact boundary");

        (uint256 rejectedId, OpenPuntStorage.MatchedSwap memory rejected, Proposal memory rejectedP) =
            _openGasPositionWithTerms(s, m);
        vm.fee(committedBoundary + 1);
        vm.prank(reporter);
        vm.expectRevert(PuntErrors.DisputeGasTooHigh.selector);
        puntLifecycle.report(
            rejectedId,
            bytes32(0),
            rejected,
            rejectedP.preimage,
            _noTiming(),
            reporter,
            INITIAL_LIQUIDITY,
            A2_HEALTHY,
            0
        );
        assertEq(punt.swapIdToReportId(rejectedId), 0, "one wei past the scaled boundary creates no report");
    }

    function test_nonFlexibleDelayedReportScalesToGasRequiredMinimum() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openGasPosition(MATURITY_LONG);
        uint256 baseFee = MATCH_BASE_FEE_LIMIT;
        uint128 minimum = _gasMinimumReportAmount(_adjustedBaseFee(baseFee));
        assertGt(minimum, INITIAL_LIQUIDITY, "fixture requires increased liquidity");

        vm.fee(baseFee);
        vm.prank(reporter);
        vm.expectRevert(PuntErrors.DisputeGasTooHigh.selector);
        puntLifecycle.report(swapId, bytes32(0), active, p.preimage, _noTiming(), reporter, minimum - 1, A2_HEALTHY, 0);

        Matched memory closing =
            _reportOnPositionWithAmounts(swapId, _noDutch(), active, p.preimage, reporter, 0, minimum, A2_HEALTHY);
        assertEq(closing.game.currentAmount1, minimum, "first gas-sufficient amount is accepted");
    }

    function test_nonFlexibleDelayedReportAllowsPaddingButRejectsAboveItsCeiling() public {
        uint256 baseFee = MATCH_BASE_FEE_LIMIT;
        uint128 ceiling = _paddedNonFlexibleCeiling(_adjustedBaseFee(baseFee));
        assertLt(ceiling, ESCALATION_HALT, "fixture ceiling remains below escalation halt");

        (uint256 acceptedId, OpenPuntStorage.MatchedSwap memory accepted, Proposal memory acceptedP) =
            _openGasPosition(MATURITY_LONG);
        vm.fee(baseFee);
        Matched memory closing = _reportOnPositionWithAmounts(
            acceptedId, _noDutch(), accepted, acceptedP.preimage, reporter, 0, ceiling, A2_HEALTHY
        );
        assertEq(closing.game.currentAmount1, ceiling, "12.5% inclusion padding is accepted");

        (uint256 rejectedId, OpenPuntStorage.MatchedSwap memory rejected, Proposal memory rejectedP) =
            _openGasPosition(MATURITY_LONG);
        vm.fee(baseFee);
        vm.prank(reporter);
        vm.expectRevert(PuntErrors.InvalidAmount1.selector);
        puntLifecycle.report(
            rejectedId, bytes32(0), rejected, rejectedP.preimage, _noTiming(), reporter, ceiling + 1, A2_HEALTHY, 0
        );
        assertEq(punt.swapIdToReportId(rejectedId), 0, "amount above padded ceiling creates no report");
    }

    function test_nonFlexibleCeilingUsesTheCommittedNonDefaultEstimate() public {
        uint32 selectedGas = DISPUTE_GAS * 2;
        uint256 baseFee = MATCH_BASE_FEE_LIMIT;
        uint256 adjustedBaseFee = baseFee + _ceilDiv(_l1Fee(), selectedGas);
        uint256 required = _ceilDiv(adjustedBaseFee * DISPUTE_SCALE * selectedGas, MAX_DISPUTE_COST);
        required = _ceilDiv(required * 10, 9);
        uint128 ceiling = uint128(_ceilDiv(required * 9, 8));
        assertLt(ceiling, ESCALATION_HALT, "non-default fixture ceiling remains below escalation halt");

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _gasTerms(MATURITY_LONG);
        s.estimatedDisputeGas = selectedGas;

        (uint256 acceptedId, OpenPuntStorage.MatchedSwap memory accepted, Proposal memory acceptedP) =
            _openGasPositionWithTerms(s, m);
        vm.fee(baseFee);
        Matched memory closing = _reportOnPositionWithAmounts(
            acceptedId, _noDutch(), accepted, acceptedP.preimage, reporter, 0, ceiling, A2_HEALTHY
        );
        assertEq(closing.game.currentAmount1, ceiling, "non-default estimate's padded ceiling is accepted");

        (uint256 rejectedId, OpenPuntStorage.MatchedSwap memory rejected, Proposal memory rejectedP) =
            _openGasPositionWithTerms(s, m);
        vm.fee(baseFee);
        vm.prank(reporter);
        vm.expectRevert(PuntErrors.InvalidAmount1.selector);
        puntLifecycle.report(
            rejectedId, bytes32(0), rejected, rejectedP.preimage, _noTiming(), reporter, ceiling + 1, A2_HEALTHY, 0
        );
        assertEq(punt.swapIdToReportId(rejectedId), 0, "one unit above non-default ceiling creates no report");
    }

    function test_nonFlexibleSizingSurvivesTwelvePointFivePercentBaseFeeIncrease() public {
        uint256 sizingBaseFee = MATCH_BASE_FEE_LIMIT;
        uint256 sizingAdjustedFee = _adjustedBaseFee(sizingBaseFee);
        uint128 selectedAmount = _paddedNonFlexibleCeiling(sizingAdjustedFee);
        uint256 inclusionAdjustedFee = _ceilDiv(sizingAdjustedFee * 9, 8);
        uint256 inclusionBaseFee = inclusionAdjustedFee - _l1EquivalentBaseFee();

        assertGe(
            selectedAmount,
            _gasMinimumReportAmount(inclusionAdjustedFee),
            "selected amount covers a 12.5% inclusion-time increase in total dispute cost"
        );

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openGasPosition(MATURITY_LONG);
        vm.fee(inclusionBaseFee);
        Matched memory closing = _reportOnPositionWithAmounts(
            swapId, _noDutch(), active, p.preimage, reporter, 0, selectedAmount, A2_HEALTHY
        );

        assertEq(closing.game.currentAmount1, selectedAmount, "pre-sized report survives inclusion slack");
    }

    function test_executionChecksFinalDisputedLiquidity() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) =
            _openGasPosition(MATURITY_INSTANT);
        vm.fee(OPEN_BASE_FEE);
        Matched memory closing = _reportOnPositionWithAmounts(
            swapId, _noDutch(), active, p.preimage, reporter, 0, INITIAL_LIQUIDITY, A2_HEALTHY
        );

        uint128 disputedAmount1 = uint128(uint256(closing.game.currentAmount1) * closing.game.multiplier / 100);
        uint256 originalLimit = uint256(closing.game.currentAmount1) * MAX_DISPUTE_COST / DISPUTE_SCALE / DISPUTE_GAS;
        uint256 finalLimit = uint256(disputedAmount1) * MAX_DISPUTE_COST / DISPUTE_SCALE / DISPUTE_GAS;
        uint256 recordedBaseFee = (originalLimit + finalLimit) / 2;
        assertGt(recordedBaseFee, originalLimit, "recorded fee fails against original report liquidity");
        assertLe(recordedBaseFee, finalLimit, "recorded fee passes against final disputed liquidity");

        Matched memory disputed = _disputeAtBaseFee(closing, matcher, recordedBaseFee);
        assertEq(
            uint256(disputed.game.currentAmount1) * closing.game.currentAmount2,
            uint256(disputed.game.currentAmount2) * closing.game.currentAmount1,
            "dispute preserves the reported price"
        );
        (,, uint128 storedBaseFee,) = oracle.disputeHistory(closing.reportId, disputed.game.numReports - 1);
        assertEq(storedBaseFee, recordedBaseFee, "final round records the decisive base fee");

        _advanceValid(_secondsForBlocks(disputed.game.settlementTime) + 2);
        vm.fee(finalLimit + 1);
        Vm.Log[] memory logs = _executeNow(swapId, disputed, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.DisputeGasBailout.selector, swapId),
            "final disputed liquidity prevents a gas bailout"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "mature position closes");
        assertEq(punt.swaps(swapId), bytes32(0), "successful execution reaches terminal state");
    }

    function test_executionUsesTheCommittedNonDefaultEstimate() public {
        uint32 selectedGas = DISPUTE_GAS * 2;
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _gasTerms(MATURITY_INSTANT);
        s.estimatedDisputeGas = selectedGas;
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openGasPositionWithTerms(s, m);

        vm.fee(OPEN_BASE_FEE);
        Matched memory closing = _reportOnPositionWithAmounts(
            swapId, _noDutch(), active, p.preimage, reporter, 0, INITIAL_LIQUIDITY, A2_HEALTHY
        );

        uint128 finalAmount1 = uint128(uint256(closing.game.currentAmount1) * closing.game.multiplier / 100);
        uint256 selectedEstimateLimit = uint256(finalAmount1) * MAX_DISPUTE_COST / DISPUTE_SCALE / selectedGas;
        uint256 staleConstantLimit = uint256(finalAmount1) * MAX_DISPUTE_COST / DISPUTE_SCALE / DISPUTE_GAS;
        uint256 recordedBaseFee = (selectedEstimateLimit + staleConstantLimit) / 2;
        assertGt(recordedBaseFee, selectedEstimateLimit, "recorded fee fails the committed 200k estimate");
        assertLe(recordedBaseFee, staleConstantLimit, "recorded fee would pass a stale 100k constant");

        Matched memory disputed = _disputeAtBaseFee(closing, matcher, recordedBaseFee);
        _advanceValid(_secondsForBlocks(disputed.game.settlementTime) + 2);
        vm.fee(0);
        Vm.Log[] memory logs = _executeNow(swapId, disputed, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.DisputeGasBailout.selector, swapId),
            "execution applies the committed non-default estimate"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionReportBailedOut.selector, swapId), "report is released");
        _assertNoEconomicOutcome(logs, swapId);
        assertEq(punt.swaps(swapId), keccak256(abi.encode(active)), "active position survives the gas bailout");
    }

    function test_firstSaturatingDisputeUsesMaxMinusOneRecordedFee() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) =
            _openGasPosition(MATURITY_INSTANT);
        vm.fee(OPEN_BASE_FEE);
        Matched memory closing = _reportOnPositionWithAmounts(
            swapId, _noDutch(), active, p.preimage, reporter, 0, INITIAL_LIQUIDITY, A2_HEALTHY
        );

        closing = _setTrackedReportCount(closing, type(uint24).max - 1);
        uint128 finalAmount1 = uint128(uint256(closing.game.currentAmount1) * closing.game.multiplier / 100);
        uint256 finalLimit = uint256(finalAmount1) * MAX_DISPUTE_COST / DISPUTE_SCALE / DISPUTE_GAS;
        uint256 failingRecordedFee = finalLimit + 1;
        Matched memory saturated = _disputeAtBaseFee(closing, matcher, failingRecordedFee);

        assertEq(saturated.game.numReports, type(uint24).max, "first saturation reaches the counter maximum");
        (uint128 fallbackAmount1,, uint128 fallbackFee,) =
            oracle.disputeHistory(saturated.reportId, type(uint24).max - 1);
        (uint128 maxAmount1,, uint128 maxFee,) = oracle.disputeHistory(saturated.reportId, type(uint24).max);
        assertEq(fallbackAmount1, saturated.game.currentAmount1, "first saturation writes max minus one");
        assertEq(fallbackFee, failingRecordedFee, "max-minus-one row holds the decisive fee");
        assertEq(maxAmount1, 0, "max row is empty on first saturation");
        assertEq(maxFee, 0, "empty max row has no recorded fee");

        _advanceValid(_secondsForBlocks(saturated.game.settlementTime) + 2);
        vm.fee(0);
        Vm.Log[] memory logs = _executeNow(swapId, saturated, closeExecutor);

        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.DisputeGasBailout.selector, swapId),
            "execution uses the failing max-minus-one fee"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionReportBailedOut.selector, swapId), "report is released");
        _assertNoEconomicOutcome(logs, swapId);
        assertEq(punt.swaps(swapId), keccak256(abi.encode(active)), "active position survives the bailout");
    }

    function test_subsequentSaturatedDisputeUsesMaxRecordedFee() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) =
            _openGasPosition(MATURITY_INSTANT);
        vm.fee(OPEN_BASE_FEE);
        Matched memory closing = _reportOnPositionWithAmounts(
            swapId, _noDutch(), active, p.preimage, reporter, 0, INITIAL_LIQUIDITY, A2_HEALTHY
        );

        closing = _setTrackedReportCount(closing, type(uint24).max - 1);
        uint128 firstAmount1 = uint128(uint256(closing.game.currentAmount1) * closing.game.multiplier / 100);
        uint256 firstLimit = uint256(firstAmount1) * MAX_DISPUTE_COST / DISPUTE_SCALE / DISPUTE_GAS;
        uint256 staleFailingFee = firstLimit + 1;
        Matched memory firstSaturation = _disputeAtBaseFee(closing, matcher, staleFailingFee);
        uint128 firstSaturatedAmount1 = firstSaturation.game.currentAmount1;

        uint256 latestPassingFee = OPEN_BASE_FEE;
        Matched memory secondSaturation = _disputeAtBaseFee(firstSaturation, reporter, latestPassingFee);
        assertEq(secondSaturation.game.numReports, type(uint24).max, "counter remains saturated");

        (uint128 staleAmount1,, uint128 staleFee,) =
            oracle.disputeHistory(secondSaturation.reportId, type(uint24).max - 1);
        (uint128 latestAmount1,, uint128 latestFee,) =
            oracle.disputeHistory(secondSaturation.reportId, type(uint24).max);
        assertEq(staleAmount1, firstSaturatedAmount1, "max-minus-one row remains the prior round");
        assertEq(staleFee, staleFailingFee, "prior saturated row preserves its failing fee");
        assertEq(latestAmount1, secondSaturation.game.currentAmount1, "later dispute writes the max row");
        assertEq(latestFee, latestPassingFee, "max row holds the latest passing fee");

        _advanceValid(_secondsForBlocks(secondSaturation.game.settlementTime) + 2);
        vm.fee(type(uint64).max);
        Vm.Log[] memory logs = _executeNow(swapId, secondSaturation, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.DisputeGasBailout.selector, swapId),
            "execution uses the populated max row rather than the stale fallback"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "mature position closes normally");
        assertEq(punt.swaps(swapId), bytes32(0), "latest passing round reaches terminal state");
    }

    function test_openingExecutionUsesInitialReportRecordInsteadOfExecutionBaseFee() public {
        vm.fee(MATCH_BASE_FEE_LIMIT);
        Proposal memory p = _proposeGasTerms(MATURITY_LONG);
        Matched memory opening = _matchSwapWith(p, A2_OPEN, matcher);
        assertEq(opening.game.numReports, 1, "tracked opening starts at report count one");
        (uint128 recordedAmount1,, uint128 recordedBaseFee,) = oracle.disputeHistory(opening.reportId, 0);
        assertEq(recordedAmount1, INITIAL_LIQUIDITY, "initial report is stored at index zero");
        assertEq(recordedBaseFee, MATCH_BASE_FEE_LIMIT, "initial report records its own base fee");

        _advanceValid(_secondsForBlocks(p.preimage.settlementTime) + 2);
        vm.fee(MATCH_BASE_FEE_LIMIT + 1);
        OpenPuntStorage.MatchedSwap memory active = _executeOpening(opening, executor);
        assertTrue(active.active, "higher execution-time base fee does not change the recorded verdict");
    }

    function test_openingFinalRecordedFeeFailureRefundsEvenWhenExecutionFeeFalls() public {
        vm.fee(OPEN_BASE_FEE);
        Proposal memory p = _proposeGasTerms(MATURITY_LONG);
        Matched memory opening = _matchSwapWith(p, A2_OPEN, matcher);
        uint128 finalAmount1 = uint128(uint256(opening.game.currentAmount1) * opening.game.multiplier / 100);
        uint256 finalLimit = uint256(finalAmount1) * MAX_DISPUTE_COST / DISPUTE_SCALE / DISPUTE_GAS;
        Matched memory disputed = _disputeAtBaseFee(opening, matcher, finalLimit + 1);
        uint256 swapperBefore = collat.balanceOf(swapper);
        uint256 matcherBefore = _spendable(matcher, address(collat));

        _advanceValid(_secondsForBlocks(disputed.game.settlementTime) + 2);
        vm.fee(OPEN_BASE_FEE);
        vm.recordLogs();
        vm.prank(executor);
        puntLifecycle.execute(p.swapId, disputed.swap, disputed.game, disputed.helper, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasBailoutLog(logs, OpenPuntStorage.DisputeGasBailout.selector, p.swapId), "gas bailout emitted");
        assertTrue(
            _hasBailoutLog(logs, OpenPuntStorage.PositionOpeningFailed.selector, p.swapId), "opening failure emitted"
        );
        assertFalse(_hasLog(logs, OpenPuntStorage.PositionOpened.selector, p.swapId), "position never opened");
        assertEq(punt.swaps(p.swapId), bytes32(0), "opening commitment deleted");
        assertEq(punt.swapIdToReportId(p.swapId), 0, "opening report sidecar deleted");
        assertEq(collat.balanceOf(swapper), swapperBefore + disputed.swap.initialMarginSwapper, "swapper refunded");
        assertEq(
            _spendable(matcher, address(collat)), matcherBefore + disputed.swap.initialMarginMatcher, "matcher refunded"
        );
    }

    function test_activeFinalRecordedFeeFailureBailsOutEvenWhenExecutionFeeFalls() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openGasPosition(MATURITY_LONG);
        vm.fee(OPEN_BASE_FEE);
        Matched memory closing = _reportOnPositionWithAmounts(
            swapId, _noDutch(), active, p.preimage, reporter, REPORT_EXEC_COMP, INITIAL_LIQUIDITY, A2_HEALTHY
        );
        uint128 finalAmount1 = uint128(uint256(closing.game.currentAmount1) * closing.game.multiplier / 100);
        uint256 finalLimit = uint256(finalAmount1) * MAX_DISPUTE_COST / DISPUTE_SCALE / DISPUTE_GAS;
        Matched memory disputed = _disputeAtBaseFee(closing, matcher, finalLimit + 1);

        vm.prank(swapper);
        punt.close{value: 0}(
            swapId, _dutchInput(), disputed.swap, true, _emptyPermit2(), 0, _emptyOracleGame(), _emptyOracleHelper(), 0
        );
        assertTrue(punt.closeRequestBlock(swapId) != 0, "applicable close intent recorded");

        _advanceValid(_secondsForBlocks(disputed.game.settlementTime) + 2);
        vm.fee(OPEN_BASE_FEE);
        Vm.Log[] memory logs = _executeNow(swapId, disputed, closeExecutor);

        assertTrue(_hasBailoutLog(logs, OpenPuntStorage.DisputeGasBailout.selector, swapId), "gas bailout emitted");
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionReportBailedOut.selector, swapId), "report released");
        _assertNoEconomicOutcome(logs, swapId);
        assertEq(punt.swapIdToReportId(swapId), 0, "report sidecar made reusable");
        assertEq(punt.closeRequestBlock(swapId), 0, "applicable close intent consumed");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(active)), "active position survives unchanged");
    }

    function test_recoveryBoundaryBypassesGasForReportAndExecution() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) =
            _openGasPosition(MATURITY_INSTANT);
        uint256 recoveryStart = uint256(active.maturity) + RECOVERY_DELAY;

        vm.warp(recoveryStart - 1);
        vm.fee(MATCH_BASE_FEE_LIMIT + 1);
        vm.prank(reporter);
        vm.expectRevert(PuntErrors.DisputeGasTooHigh.selector);
        puntLifecycle.report(
            swapId, bytes32(0), active, p.preimage, _noTiming(), reporter, INITIAL_LIQUIDITY, A2_HEALTHY, 0
        );

        // Recovery must not depend on the Base predeploy remaining callable.
        vm.etch(BASE_GAS_PRICE_ORACLE, hex"");
        vm.warp(recoveryStart);
        Matched memory recoveryReport = _reportOnPositionWithAmounts(
            swapId, _noDutch(), active, p.preimage, reporter, 0, INITIAL_LIQUIDITY, A2_HEALTHY
        );
        assertEq(recoveryReport.game.lastReportOppoTime, recoveryStart, "report begins at recovery boundary");

        _advanceValid(_secondsForBlocks(p.preimage.settlementTime) + 2);
        Vm.Log[] memory logs = _executeNow(swapId, recoveryReport, closeExecutor);

        assertFalse(
            _hasBailoutLog(logs, OpenPuntStorage.DisputeGasBailout.selector, swapId),
            "recovery execution bypasses spot gas gate"
        );
        assertTrue(_hasLog(logs, OpenPuntStorage.PositionClosed.selector, swapId), "recovered position closes");
        assertEq(punt.swaps(swapId), bytes32(0), "recovery reaches terminal state");
    }
}
