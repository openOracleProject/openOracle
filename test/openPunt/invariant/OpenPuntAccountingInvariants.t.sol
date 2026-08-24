// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntInvariantBase.t.sol";

/**
 * @notice Campaign 2: active-position accounting and liveness, seeded through genuine opening
 *         calls so the auxiliary state machines have material to work on from the first call.
 *
 * @dev Campaign 1 starts from proposals and spends much of its depth getting positions open. This
 *      one pre-opens a mixed set — heartbeat-enabled, latency-enabled and plain — so the Dutch,
 *      heartbeat, close-state and compensation invariants are exercised densely rather than
 *      incidentally.
 */
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 500
/// forge-config: default.invariant.fail-on-revert = false
contract OpenPuntAccountingInvariantsTest is OpenPuntInvariantBase {
    function setUp() public {
        _setUpAll();
        _deployHandler();
        _restrictSenders();

        // seed a mixed population through the same handler actions the fuzzer uses:
        //   seed 0 -> heartbeat enabled, latency disabled
        //   seed 1 -> heartbeat disabled, latency disabled
        //   seed 4 -> heartbeat enabled, latency enabled
        _seedActive(0);
        _seedActive(1);
        _seedActive(4);
        require(handler.count("executeOpeningSuccess") == 3, "seed: three positions did not open");

        handler.markSeedComplete();

        // Restrict to state-changing actions: the handler also exposes many getters, and letting
        // the fuzzer spend depth on view calls would dilute the liveness state machines this
        // campaign exists to exercise.
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = OpenPuntHandler.recordHeartbeat.selector;
        selectors[1] = OpenPuntHandler.startCloseAuction.selector;
        selectors[2] = OpenPuntHandler.cancelCloseAuction.selector;
        selectors[3] = OpenPuntHandler.setCloseIntentDuringReport.selector;
        selectors[4] = OpenPuntHandler.reportNoDutch.selector;
        selectors[5] = OpenPuntHandler.reportClaimingDutch.selector;
        selectors[6] = OpenPuntHandler.reportZeroSentinel.selector;
        selectors[7] = OpenPuntHandler.settleReportDirectly.selector;
        selectors[8] = OpenPuntHandler.executeActiveReport.selector;
        selectors[9] = OpenPuntHandler.clockToEligibility.selector;
        selectors[10] = OpenPuntHandler.clockValidHop.selector;
        selectors[11] = OpenPuntHandler.clockStallBlocks.selector;
        selectors[12] = OpenPuntHandler.clockCrossHeartbeatMin.selector;
        selectors[13] = OpenPuntHandler.withdrawTempHolding.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _seedActive(uint256 seed) internal {
        handler.propose(seed);
        handler.matchSwap(seed);
        handler.clockToEligibility(seed);
        handler.executeOpening(seed);
    }

    function invariant_collateralConservation() public view {
        _assertCollateralConservation();
        _assertTerminalPayouts();
        _assertNoModelViolations();
    }

    function invariant_executionCompensation() public view {
        _assertCompensation();
    }

    function invariant_dutchAuction() public view {
        _assertDutch();
    }

    function invariant_heartbeat() public view {
        _assertHeartbeat();
    }

    function invariant_closeState() public view {
        _assertCloseState();
    }

    function invariant_lifecycleHashesAndPhases() public view {
        _assertLifecycle();
        _assertOracleCommitment();
        _assertModuleClean();
    }

    /// @dev Structural non-vacuity: the seeded population can never be lost.
    function invariant_populationIsLive() public view {
        assertGe(handler.idCount(), 3, "the seeded population exists");
        assertGe(handler.count("executeOpeningSuccess"), 3, "and genuinely opened");
    }

    function afterInvariant() public view {
        assertGt(
            handler.totalOk(),
            handler.seedOkBaseline(),
            "the randomized phase performed no successful action beyond the seed"
        );
        console.log("-- accounting campaign counters --");
        console.log("heartbeat", handler.count("recordHeartbeat"), "auction", handler.count("startCloseAuction"));
        console.log(
            "reportNoDutch", handler.count("reportNoDutch"), "reportClaim", handler.count("reportClaimingDutch")
        );
        console.log("closed", handler.count("outcomeClose"), "liquidated", handler.count("outcomeLiquidated"));
        console.log(
            "hbBailout", handler.count("outcomeHeartbeatBailout"), "cadence", handler.count("outcomeCadenceBailout")
        );
        console.log(
            "latency", handler.count("outcomeLatencyBailout"), "liqFailed", handler.count("outcomeLiquidationFailed")
        );
        console.log("dutchClaimBranch", handler.count("dutchClaimBranch"));
        console.log("totalOk", handler.totalOk(), "totalRejected", handler.totalRejected());
    }
}
