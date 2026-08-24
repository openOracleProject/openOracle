// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";
import {Errors as OracleErrors} from "../../src/libraries/Errors.sol";

/**
 * @notice report() input validation and the reporter-adapter funding path.
 *
 * @dev The post-reportId `NotActive` branch is unreachable: the only inactive
 *      positions that exist are matched-but-not-yet-opened ones, and those always carry a
 *      nonzero opening reportId, so `OracleGameInProgress` fires first. Every other route out
 *      of "inactive" deletes the position entirely.
 */
contract ReportValidationTest is CloseBase {
    address internal designatedReporter = address(0x4001);

    function setUp() public {
        _setUpClose();

        // designated reporter: oracle allowances only, deliberately no balances
        vm.startPrank(designatedReporter);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();

        // adapter/funder: real balances and allowances for both legs and ETH
        _mintAndDeposit(tokenA, adapter, 1_000e18);
        _mintAndDeposit(tokenB, adapter, 10_000_000e18);
        vm.startPrank(adapter);
        oracle.deposit{value: 10 ether}(address(0), 10 ether, adapter);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();
    }

    function _rejectReport(
        uint256 swapId,
        OpenPuntStorage.CloseDutch memory d,
        OpenPuntStorage.MatchedSwap memory state,
        OpenPuntStorage.MatcherPreimage memory preimage,
        address who,
        address reporterArg,
        uint128 a1,
        uint128 a2,
        bytes4 err,
        string memory what
    ) internal {
        bytes32 positionBefore = punt.swaps(swapId);
        bytes32 dutchBefore = _storedDutchState(swapId);
        uint256 nextReportIdBefore = oracle.nextReportId();
        (uint128 pendingBefore,,) = _closeState(swapId);

        vm.prank(who);
        vm.expectRevert(err);
        puntLifecycle.report(swapId, _expectedDutchHash(d), state, preimage, _noTiming(), reporterArg, a1, a2, 0);

        assertEq(punt.swaps(swapId), positionBefore, string.concat(what, ": position unchanged"));
        assertEq(_storedDutchState(swapId), dutchBefore, string.concat(what, ": auction unchanged"));
        assertEq(oracle.nextReportId(), nextReportIdBefore, string.concat(what, ": no oracle game created"));
        (uint128 pendingAfter,,) = _closeState(swapId);
        assertEq(pendingAfter, pendingBefore, string.concat(what, ": pending compensation unchanged"));
    }

    // ══════════════════════════════════════════════════════════════════
    //  Validation
    // ══════════════════════════════════════════════════════════════════

    function test_wrongPositionStateRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.MatchedSwap memory tampered = _copy(active);
        tampered.maintenanceMarginSwapper += 1;

        _rejectReport(
            swapId,
            _noDutch(),
            tampered,
            p.preimage,
            reporter,
            reporter,
            A1,
            A2_OPEN,
            PuntErrors.WrongHash.selector,
            "tampered position"
        );
    }

    function test_wrongMatcherPreimageRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.MatcherPreimage memory tampered = _copy(p.preimage);
        tampered.multiplier += 1;

        _rejectReport(
            swapId,
            _noDutch(),
            active,
            tampered,
            reporter,
            reporter,
            A1,
            A2_OPEN,
            PuntErrors.WrongHash.selector,
            "tampered preimage"
        );
    }

    function test_zeroAmountsReject() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();

        _rejectReport(
            swapId,
            _noDutch(),
            active,
            p.preimage,
            reporter,
            reporter,
            0,
            A2_OPEN,
            PuntErrors.AmountsCannotBeZero.selector,
            "zero amount1"
        );
        _rejectReport(
            swapId,
            _noDutch(),
            active,
            p.preimage,
            reporter,
            reporter,
            A1,
            0,
            PuntErrors.AmountsCannotBeZero.selector,
            "zero amount2"
        );
    }

    function test_zeroReporterRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();

        _rejectReport(
            swapId,
            _noDutch(),
            active,
            p.preimage,
            reporter,
            address(0),
            A1,
            A2_OPEN,
            PuntErrors.AddressCannotBeZero.selector,
            "zero reporter"
        );
    }

    function test_coreCannotBeTheReporter() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();

        _rejectReport(
            swapId,
            _noDutch(),
            active,
            p.preimage,
            reporter,
            address(punt),
            A1,
            A2_OPEN,
            PuntErrors.ContractCannotBeParticipant.selector,
            "core reporter"
        );
    }

    function test_reportAlreadyInProgressRejects() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        Matched memory mt = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, 0);

        _rejectReport(
            swapId,
            _noDutch(),
            mt.swap,
            p.preimage,
            outsider,
            outsider,
            A1,
            A2_OPEN,
            PuntErrors.OracleGameInProgress.selector,
            "report in progress"
        );
    }

    /// @dev The matched-but-inactive position has a nonzero opening reportId in the sidecar, so the
    ///      OracleGameInProgress guard fires before `NotActive` can ever be reached.
    function test_matchedButInactivePositionHitsOracleGameInProgressNotNotActive() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _positionCfg(false, false);
        Proposal memory p = _proposeWith(s, m, swapper);
        Matched memory mt = _matchSwapWith(p, A2_OPEN, matcher);

        assertFalse(mt.swap.active, "inactive");
        assertEq(punt.swapIdToReportId(p.swapId), mt.reportId, "sidecar carries the opening report id");

        _rejectReport(
            p.swapId,
            _noDutch(),
            mt.swap,
            p.preimage,
            reporter,
            reporter,
            A1,
            A2_OPEN,
            PuntErrors.OracleGameInProgress.selector,
            "matched but inactive"
        );
    }

    /// @dev Confirms that the liquidity gate remains enforced through the close fixture.
    function test_liquidityGateStillEnforced() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();

        _rejectReport(
            swapId,
            _noDutch(),
            active,
            p.preimage,
            reporter,
            reporter,
            A1 * 2,
            A2_OPEN,
            PuntErrors.InvalidAmount1.selector,
            "above initialLiquidity with a nonzero dispute delay"
        );
        _rejectReport(
            swapId,
            _noDutch(),
            active,
            p.preimage,
            reporter,
            reporter,
            A1 - 1,
            A2_OPEN,
            PuntErrors.InvalidAmount1.selector,
            "below initialLiquidity"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  Reporter-adapter path
    // ══════════════════════════════════════════════════════════════════

    function test_adapterFundsADistinctDesignatedReporter() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();

        uint256 adapterA0 = _spendable(adapter, address(tokenA));
        uint256 adapterB0 = _spendable(adapter, address(tokenB));
        uint256 adapterEth0 = _spendable(adapter, address(0));
        uint128 comp = 0.001 ether;

        assertEq(_spendable(designatedReporter, address(tokenA)), 0, "designated reporter starts empty");
        assertEq(_spendable(designatedReporter, address(tokenB)), 0, "designated reporter starts empty");

        vm.recordLogs();
        vm.prank(adapter);
        puntLifecycle.report(swapId, bytes32(0), active, p.preimage, _noTiming(), designatedReporter, A1, A2_OPEN, comp);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        OpenPuntStorage.MatchedSwap memory after1 =
            _decodeSingleSwapState(logs, OpenPuntStorage.PositionReportStarted.selector, swapId);
        uint256 reportId = punt.swapIdToReportId(swapId);
        (IOpenOracle2.OracleGame memory g,) = _decodeReportSubmitted(logs, reportId);

        // identity
        assertEq(g.currentReporter, designatedReporter, "designated reporter owns the oracle game");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(after1)), "event reconstructs the stored hash");

        // the funder paid for everything
        assertEq(_spendable(adapter, address(tokenA)), adapterA0 - A1, "funder supplied leg1");
        assertEq(_spendable(adapter, address(tokenB)), adapterB0 - A2_OPEN, "funder supplied leg2");
        assertEq(_spendable(adapter, address(0)), adapterEth0 - comp, "funder supplied the execution comp");
        assertEq(punt.executionGasComp(reportId), comp, "comp recorded against the new report");

        // nothing was left behind on the designated reporter
        assertEq(_spendable(designatedReporter, address(tokenA)), 0, "no residual leg1");
        assertEq(_spendable(designatedReporter, address(tokenB)), 0, "no residual leg2");
        assertEq(_spendable(designatedReporter, address(0)), 0, "no residual ETH");
    }

    function test_adapterMissingBalanceRevertsTheWholeTransition() public {
        address broke = address(0x4002);
        vm.startPrank(broke);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();

        _rejectReport(
            swapId,
            _noDutch(),
            active,
            p.preimage,
            broke,
            designatedReporter,
            A1,
            A2_OPEN,
            OracleErrors.InsufficientInternalBalance.selector,
            "funder with no balance"
        );
    }

    function test_adapterMissingAllowanceRevertsTheWholeTransition() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();

        vm.prank(adapter);
        oracle.approveInternal(address(punt), address(tokenB), 0);

        _rejectReport(
            swapId,
            _noDutch(),
            active,
            p.preimage,
            adapter,
            designatedReporter,
            A1,
            A2_OPEN,
            OracleErrors.InsufficientInternalAllowance.selector,
            "funder allowance revoked"
        );
    }

    /// @dev The oracle pulls the legs from the reporter, so the designated reporter must have
    ///      granted the core an internal allowance even though the funder supplies the tokens.
    function test_designatedReporterMissingAllowanceRevertsTheWholeTransition() public {
        address unarmed = address(0x4003);
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();

        _rejectReport(
            swapId,
            _noDutch(),
            active,
            p.preimage,
            adapter,
            unarmed,
            A1,
            A2_OPEN,
            OracleErrors.InsufficientInternalBalance.selector,
            "designated reporter unarmed"
        );
    }

    /// @dev A failed oracle funding call must unwind the Dutch resolution as well.
    function test_failedOracleFundingRollsBackDutchResolution() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);
        bytes32 dutchHash = keccak256(abi.encode(d));

        address broke = address(0x4004);
        vm.startPrank(broke);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        vm.stopPrank();

        uint256 nextReportIdBefore = oracle.nextReportId();
        uint256 reporterCollat0 = _spendable(reporter, address(collat));

        vm.prank(broke);
        vm.expectRevert(OracleErrors.InsufficientInternalBalance.selector);
        puntLifecycle.report(swapId, _expectedDutchHash(d), active, p.preimage, _noTiming(), broke, A1, A2_OPEN, 0);

        // every piece of the transition rolled back
        assertEq(_storedAuctionHash(swapId, active), dutchHash, "dutch resolution rolled back");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, CLOSE_COMP, "pending compensation migration rolled back");
        assertTrue(intent, "close request remains live");
        assertEq(oracle.nextReportId(), nextReportIdBefore, "report id allocation rolled back");
        assertEq(punt.executionGasComp(nextReportIdBefore), 0, "no compensation recorded");
        assertEq(punt.swaps(swapId), keccak256(abi.encode(active)), "position hash rolled back");
        assertEq(_spendable(reporter, address(collat)), reporterCollat0, "no reward paid");

        // and a properly funded reporter can still claim the auction afterwards
        Matched memory mt = _reportWithDutch(swapId, d, active, p.preimage, reporter, 0);
        assertEq(_spendable(reporter, address(collat)) - reporterCollat0, DUTCH_START, "reward still claimable");
        assertEq(_storedDutchState(swapId), bytes32(0), "auction consumed on the successful attempt");
        assertTrue(mt.reportId != 0, "report created");
    }
}
