// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntInvariantBase.t.sol";

/**
 * @notice Campaign 1: full lifecycle from proposals, with the hash, phase and conservation
 *         invariants applied after every call.
 */
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 500
/// forge-config: default.invariant.fail-on-revert = false
contract OpenPuntLifecycleInvariantsTest is OpenPuntInvariantBase {
    function setUp() public {
        _setUpAll();
        _deployHandler();

        // The handler exposes getters alongside actions, so the randomized
        // target set is restricted to the state-changing actions; otherwise a large share of the
        // depth is spent on view calls that cannot advance the state machine.
        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = OpenPuntHandler.propose.selector;
        selectors[1] = OpenPuntHandler.matchSwap.selector;
        selectors[2] = OpenPuntHandler.executeOpening.selector;
        selectors[3] = OpenPuntHandler.cancelProposalBySwapper.selector;
        selectors[4] = OpenPuntHandler.cancelProposalByOutsider.selector;
        selectors[5] = OpenPuntHandler.bailOutOpening.selector;
        selectors[6] = OpenPuntHandler.settleOpeningDirectly.selector;
        selectors[7] = OpenPuntHandler.startCloseAuction.selector;
        selectors[8] = OpenPuntHandler.cancelCloseAuction.selector;
        selectors[9] = OpenPuntHandler.reportNoDutch.selector;
        selectors[10] = OpenPuntHandler.reportClaimingDutch.selector;
        selectors[11] = OpenPuntHandler.reportZeroSentinel.selector;
        selectors[12] = OpenPuntHandler.executeActiveReport.selector;
        selectors[13] = OpenPuntHandler.clockToEligibility.selector;
        selectors[14] = OpenPuntHandler.clockValidHop.selector;
        selectors[15] = OpenPuntHandler.withdrawTempHolding.selector;
        selectors[16] = OpenPuntHandler.clockPastProposalExpiry.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
        _restrictSenders();
        _seedOnePosition();
        handler.markSeedComplete();
    }

    function invariant_lifecycleHashesAndPhases() public view {
        _assertLifecycle();
        _assertOracleCommitment();
    }

    function invariant_collateralConservation() public view {
        _assertCollateralConservation();
        _assertTerminalPayouts();
        _assertNoModelViolations();
    }

    function invariant_auxiliaryState() public view {
        _assertDutch();
        _assertHeartbeat();
        _assertCloseState();
        _assertCompensation();
        _assertModuleClean();
    }

    /**
     * @notice Structural non-vacuity.
     *
     * @dev `setUp` seeds a real opened position, so this holds from the first invariant evaluation
     *      and can only break if the model loses a live position.
     */
    function invariant_campaignHasLivePositions() public view {
        assertGt(handler.idCount(), 0, "no position exists");
        assertGt(handler.count("executeOpeningSuccess"), 0, "no position ever progressed past proposal");
    }

    /// @dev Counters are reported rather than asserted because selector weighting is diagnostic;
    ///      deterministic reachability tests prove each action can succeed.
    /**
     * @notice The randomized phase must do real work beyond the seed.
     *
     * @dev Compares the final success counter with its post-seeding baseline.
     */
    function afterInvariant() public view {
        assertGt(
            handler.totalOk(),
            handler.seedOkBaseline(),
            "the randomized phase performed no successful action beyond the seed"
        );
        console.log("-- lifecycle campaign counters --");
        console.log("propose", handler.count("propose"), "match", handler.count("matchSwap"));
        console.log(
            "openSuccess", handler.count("executeOpeningSuccess"), "openRefund", handler.count("executeOpeningRefund")
        );
        console.log("auctionStart", handler.count("startCloseAuction"), "reportNoDutch", handler.count("reportNoDutch"));
        console.log("close", handler.count("outcomeClose"), "liquidated", handler.count("outcomeLiquidated"));
        console.log("totalOk", handler.totalOk(), "totalRejected", handler.totalRejected());
    }
}
