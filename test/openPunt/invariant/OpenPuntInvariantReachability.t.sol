// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntInvariantBase.t.sol";
import {OpenPuntHandler} from "./OpenPuntHandler.sol";

/**
 * @notice Deterministic proof that the handler actions the campaigns rely on are genuinely
 *         reachable, driven through the same functions the fuzzer calls.
 *
 * @dev Random campaigns report counters for selector-weighting diagnostics; these deterministic
 *      tests cover rare outcomes directly.
 */
contract OpenPuntInvariantReachabilityTest is OpenPuntInvariantBase {
    function setUp() public {
        _setUpAll();
        _deployHandler();
    }

    function _need(string memory name) internal view {
        if (handler.count(name) == 0) {
            revert(string.concat("unreachable: ", name, " | last revert: ", vm.toString(handler.lastRevertData())));
        }
    }

    /// @dev seed 0: heartbeat and latency enabled. seed 1: heartbeat and latency disabled.
    ///      seed 4: heartbeat and latency enabled.
    function _openPosition(uint256 seed) internal {
        handler.propose(seed);
        handler.matchSwap(seed);
        handler.clockToEligibility(seed);
        handler.executeOpening(seed);
    }

    // ── proposal and opening ────────────────────────────────────────────

    function test_reach_proposeMatchOpen() public {
        _openPosition(0);
        _need("propose");
        _need("matchSwap");
        _need("executeOpeningSuccess");
    }

    function test_reach_openingRefundOnBrokenCadence() public {
        handler.propose(0);
        handler.matchSwap(0);
        handler.clockToEligibility(0);
        handler.clockStallBlocks(7); // wall time with no blocks: cadence can no longer hold
        handler.executeOpening(0);
        _need("executeOpeningRefund");
    }

    function test_reach_openingBailout() public {
        handler.propose(0);
        handler.matchSwap(0);
        // clockValidHop advances 2 + 2*(seed % 60) seconds, so seed 59 is the maximum 120 s hop.
        // 60 hops is 7200 s, comfortably past the 6000 s maxGameTime.
        for (uint256 i = 0; i < 60; i++) {
            handler.clockValidHop(59);
        }
        handler.bailOutOpening(0);
        _need("bailOutOpening");
    }

    function test_reach_openingTimeoutRefundThroughExecute() public {
        handler.propose(1); // execution latency disabled, isolating maxGameTime
        handler.matchSwap(1);
        // clockValidHop(59) advances 120 seconds at the configured cadence.
        for (uint256 i = 0; i < 51; i++) {
            handler.clockValidHop(59);
        }
        handler.executeOpening(1);
        _need("executeOpeningRefund");
    }

    function test_reach_proposalCancellationBothWays() public {
        handler.propose(0);
        handler.cancelProposalBySwapper(0);
        _need("cancelProposalBySwapper");

        handler.propose(1);
        handler.clockPastProposalExpiry(1);
        handler.cancelProposalByOutsider(1);
        _need("cancelProposalByOutsider");
    }

    function test_reach_directOracleSettlement() public {
        handler.propose(0);
        handler.matchSwap(0);
        handler.clockToEligibility(0);
        handler.settleOpeningDirectly(0);
        _need("settleOpeningDirectly");
        handler.executeOpening(0);
        _need("executeOpeningSuccess");
    }

    // ── close auction ───────────────────────────────────────────────────

    function test_reach_auctionCreateAndCancel() public {
        _openPosition(0);
        handler.startCloseAuction(0);
        _need("startCloseAuction");
        handler.cancelCloseAuction(0);
        _need("cancelLiveAuction");
    }

    function test_reach_dutchClaim() public {
        _openPosition(0);
        handler.startCloseAuction(0);
        handler.reportClaimingDutch(0);
        _need("reportClaimingDutch");
        OpenPuntHandler.Pos memory q = handler.get(handler.ids(0));
        assertTrue(q.dutchStatus == OpenPuntHandler.DutchStatus.Consumed, "the auction was consumed");
        // the model chose the claim branch before the call; production must match it
        assertEq(handler.modelViolations(), 0, handler.lastViolation());
        assertEq(_storedDutchState(handler.ids(0)), bytes32(0), "a claimed auction's state is deleted");
    }

    function test_reach_zeroHashClaimsCurrentDutch() public {
        _openPosition(0);
        handler.startCloseAuction(0);
        handler.reportZeroSentinel(0);
        _need("reportZeroSentinel");
        OpenPuntHandler.Pos memory q = handler.get(handler.ids(0));
        assertTrue(q.dutchStatus == OpenPuntHandler.DutchStatus.Consumed, "zero hash claims the current auction");
        assertEq(handler.modelViolations(), 0, handler.lastViolation());
        assertEq(_storedDutchState(handler.ids(0)), bytes32(0), "the consumed auction is deleted");
    }

    // ── active outcomes ─────────────────────────────────────────────────

    function test_reach_healthyLiquidationFailed() public {
        _openPosition(0);
        handler.reportNoDutch(0); // seed 0 -> flat price, healthy
        _need("reportNoDutch");
        handler.clockToEligibility(0);
        handler.executeActiveReport(0);
        _need("outcomeLiquidationFailed");
    }

    /// @dev Intent set during a live report before its fixed cutoff applies to that report.
    function test_reach_closeThroughIntent() public {
        _openPosition(0);
        handler.reportNoDutch(0);
        handler.setCloseIntentDuringReport(0);
        _need("setCloseIntentDuringReport");

        handler.clockToEligibility(0);
        handler.executeActiveReport(0);
        _need("outcomeClose");
    }

    /// @dev A request registered at the old report's eligibility survives that reusable outcome
    ///      and closes on the next report instead of receiving the already-known old price.
    function test_reach_lateCloseAppliesToTheNextReport() public {
        _openPosition(0);
        handler.reportNoDutch(0);
        handler.clockToEligibility(0);
        handler.setCloseIntentDuringReport(0);

        handler.executeActiveReport(0);
        _need("outcomeLiquidationFailed");
        uint256 id = handler.ids(0);
        assertTrue(punt.closeRequestBlock(id) != 0, "future close request survived the old report");

        handler.reportZeroSentinel(0);
        handler.clockToEligibility(0);
        handler.executeActiveReport(0);
        _need("outcomeClose");
    }

    function test_reach_terminalOldReportRefundsTheFutureAuction() public {
        _openPosition(1); // heartbeat disabled
        handler.reportNoDutch(1); // deeply underwater
        handler.clockToEligibility(1);
        handler.setCloseIntentDuringReport(1); // eligible report: funds the future auction

        uint256 id = handler.ids(0);
        assertTrue(_storedDutchState(id) != bytes32(0), "future auction exists beside old report");
        handler.executeActiveReport(1);

        _need("outcomeLiquidated");
        assertEq(_storedDutchState(id), bytes32(0), "terminal execution returned and deleted auction");
    }

    function test_reach_liquidationWithoutHeartbeatMode() public {
        _openPosition(1); // seed 1 -> heartbeat mode DISABLED, so liquidation needs no notice
        handler.reportNoDutch(1); // seed 1 -> deeply underwater
        handler.clockToEligibility(1);
        handler.executeActiveReport(1);
        _need("outcomeLiquidated");
    }

    function test_reach_heartbeatBailoutAndPreservedRebinding() public {
        _openPosition(0); // heartbeat mode ENABLED
        handler.recordHeartbeat(0);
        _need("recordHeartbeat");
        uint256 id = handler.ids(0);
        (, uint48 H) = punt.liquidationHeartbeats(id);

        // premature liquidating report: eligibility is only four seconds out
        handler.reportNoDutch(1);
        handler.clockToEligibility(1);
        handler.executeActiveReport(1);
        _need("outcomeHeartbeatBailout");

        // the notice clock survived, unbound and unrestamped
        (uint128 keptId, uint48 keptTs) = punt.liquidationHeartbeats(id);
        assertEq(keptId, 0, "binding released");
        assertEq(keptTs, H, "timestamp preserved");

        // a later report rebinds it, and once notice has accrued the liquidation lands
        handler.clockValidHop(20); // well past H + 30
        handler.reportNoDutch(1);
        (uint128 reboundId,) = punt.liquidationHeartbeats(id);
        assertTrue(reboundId != 0, "the preserved heartbeat rebound to the new report");
        handler.clockToEligibility(1);
        handler.executeActiveReport(1);
        _need("outcomeLiquidated");
    }

    function test_reach_cadenceBailoutOnActivePosition() public {
        _openPosition(0);
        handler.reportNoDutch(0);
        handler.clockToEligibility(0);
        handler.clockStallBlocks(9); // wall time without blocks
        handler.executeActiveReport(0);
        _need("outcomeCadenceBailout");
    }

    function test_reach_latencyBailout() public {
        _openPosition(4); // seed 4 -> heartbeat on AND maxExecutionLatency = 60
        handler.reportNoDutch(0);
        handler.clockToEligibility(0);
        for (uint256 i = 0; i < 3; i++) {
            handler.clockValidHop(15); // 32 s each at a valid cadence: past the 60 s deadline
        }
        handler.executeActiveReport(0);
        _need("outcomeLatencyBailout");
    }

    // ── terminal sweep and withdrawal ───────────────────────────────────

    function test_reach_terminalOutcomeAndWithdrawal() public {
        _openPosition(1); // heartbeat disabled so the liquidation is unconditional
        handler.startCloseAuction(0);
        handler.reportZeroSentinel(1); // zero claims the auction; seed 1 makes the report liquidating
        handler.clockToEligibility(1);
        handler.executeActiveReport(1); // underwater -> liquidation, position deleted
        _need("outcomeLiquidated");

        handler.withdrawTempHolding(0);
        _need("withdrawTempHolding");
    }

    // ── remaining actions and clock modes ───────────────────────────────

    function test_reach_settleReportDirectly() public {
        _openPosition(2);
        handler.reportNoDutch(0);
        handler.clockToEligibility(0);
        handler.settleReportDirectly(0);
        _need("settleReportDirectly");
        handler.executeActiveReport(0);
        _need("outcomeLiquidationFailed");
    }

    /// @dev Maturity alone closes a healthy position, with no close intent anywhere.
    function test_reach_maturityCloseWithoutIntent() public {
        _openPosition(2); // heartbeat on, latency disabled
        uint256 id = handler.ids(0);
        handler.clockCrossMaturity(0);
        _need("clockCrossMaturity");

        handler.reportNoDutch(0); // healthy
        (,, bool intent) = _closeState(id);
        assertFalse(intent, "no close intent was ever set");

        handler.clockToEligibility(0);
        handler.executeActiveReport(0);
        _need("outcomeClose");
    }

    /// @dev A fresh recovery-era report bypasses both cadence-derived checks.
    function test_reach_cadenceRecoveryAfterMaturityPlusWeek() public {
        _openPosition(4); // heartbeat and maxExecutionLatency enabled

        handler.clockCrossMaturityPlusWeek(0);
        _need("clockCrossMaturityPlusWeek");

        handler.reportNoDutch(0);
        handler.clockToEligibility(0);
        handler.clockStallBlocks(51); // 61 seconds: cadence broken and synthetic latency exceeded

        handler.executeActiveReport(0);
        _need("outcomeClose");
        assertEq(handler.count("outcomeCadenceBailout"), 0, "recovery applied instead of bailing out");
        assertEq(handler.count("outcomeLatencyBailout"), 0, "synthetic latency was also bypassed");
    }

    /// @dev Each clock mode reaches its intended downstream result.
    function test_reach_allClockModes() public {
        _openPosition(0);
        handler.reportNoDutch(0);

        handler.clockOneBlockShort(0);
        _need("clockOneBlockShort");
        handler.executeActiveReport(0);
        assertEq(handler.count("outcomeLiquidationFailed"), 0, "one block short: execution is refused");

        handler.clockToEligibility(0);
        handler.executeActiveReport(0);
        _need("outcomeLiquidationFailed"); // the extra block made it reachable

        handler.clockBlocksOnly(3);
        _need("clockBlocksOnly");

        // crossing the heartbeat maximum needs a heartbeat to exist in the first place
        handler.recordHeartbeat(0);
        _need("recordHeartbeat");
        handler.clockCrossHeartbeatMax(0);
        _need("clockCrossHeartbeatMax");
    }

    function test_reach_heartbeatMinimumClockMode() public {
        _openPosition(0);
        handler.recordHeartbeat(0);
        handler.clockCrossHeartbeatMin(0);
        _need("clockCrossHeartbeatMin");
    }

    function test_reach_matchTimeOpeningFeeRefund() public {
        handler.propose(8); // bit 3 selects the opening-fee auction
        handler.matchSwap(8);
        uint256 id = handler.ids(0);
        OpenPuntHandler.Pos memory q = handler.get(id);

        assertEq(uint8(q.phase), uint8(OpenPuntHandler.Phase.OpeningReport), "position reached the opening report");
        assertLt(q.matched.initialMarginSwapper, q.proposed.initialMarginSwapper, "unused fee reserve was returned");
    }

    /// @dev Reports the full counter table so selector weighting can be judged.
    function test_reach_reportAllCounters() public {
        _openPosition(0);
        handler.startCloseAuction(0);
        handler.reportClaimingDutch(0);
        handler.clockToEligibility(0);
        handler.executeActiveReport(0);
        console.log("totalOk", handler.totalOk(), "totalRejected", handler.totalRejected());
        assertGt(handler.totalOk(), 0, "deterministic driver performed real work");
    }
}
