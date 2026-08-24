// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AssetModeBase.t.sol";
import {Errors as OracleErrors} from "../../src/libraries/Errors.sol";

/**
 * @notice The reporter-adapter path when one oracle leg is native ETH.
 *
 * @dev The funder pushes the ETH leg AND the execution compensation through the designated
 *      reporter's single address(0) ledger slot, then OpenPunt pulls the compensation back and
 *      the oracle consumes the leg. Both must clear to zero spendable — a residue would mean
 *      one purpose was funded at the other's expense.
 */
contract DelegatedReporterEthTest is AssetModeBase {
    address internal designated = address(0x5001);
    uint128 internal constant ADAPTER_COMP = 0.001 ether;

    function setUp() public {
        _setUpAssets();

        // approvals only; deliberately no balances of any kind
        vm.startPrank(designated);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();
    }

    function _openFor(Legs legs)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p, address t1, address t2)
    {
        OpenPuntStorage.ProposedSwap memory s;
        OpenPuntStorage.MatcherPreimage memory m;
        (s, m) = _assetCfg(legs, address(collat), false);
        t1 = s.oracleToken1;
        t2 = s.oracleToken2;
        (swapId, active, p,) = _openAsset(s, m);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Success
    // ══════════════════════════════════════════════════════════════════

    function _runDelegated(Legs legs) internal {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p, address t1, address t2) =
            _openFor(legs);

        // the ERC20 companion leg, tracked separately from the ETH leg throughout
        address erc20Leg = t1 == address(0) ? t2 : t1;
        uint128 erc20Amount = t1 == address(0) ? OA2 : OA1;

        uint256 adapterLeg1 = _spendable(adapter, t1);
        uint256 adapterLeg2 = _spendable(adapter, t2);
        uint256 adapterEth = _spendable(adapter, address(0));
        uint256 adapterErc20 = _spendable(adapter, erc20Leg);
        uint256 designatedErc20 = _spendable(designated, erc20Leg);

        assertEq(_spendable(designated, address(0)), 0, "designated reporter starts with no ETH");
        assertEq(_spendable(designated, t1), 0, "designated reporter starts with no leg1");
        assertEq(_spendable(designated, t2), 0, "designated reporter starts with no leg2");
        assertEq(designatedErc20, 0, "designated reporter starts with no ERC20 leg");

        vm.recordLogs();
        vm.prank(adapter);
        puntLifecycle.report(swapId, bytes32(0), active, p.preimage, _noTiming(), designated, OA1, OA2, ADAPTER_COMP);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Matched memory mt;
        mt.swapId = swapId;
        mt.swap = _decodeSingleSwapState(logs, OpenPuntStorage.PositionReportStarted.selector, swapId);
        mt.reportId = punt.swapIdToReportId(swapId);
        (mt.game, mt.helper) = _decodeReportSubmitted(logs, mt.reportId);

        assertEq(mt.game.currentReporter, designated, "the designated address is the oracle reporter");
        assertEq(mt.game.token1, t1, "leg1 token");
        assertEq(mt.game.token2, t2, "leg2 token");

        // the funder paid for both legs and the compensation, out of its own ledgers
        uint256 ethLeg = t1 == address(0) ? OA1 : OA2;
        if (t1 == address(0)) {
            assertEq(_spendable(adapter, t2), adapterLeg2 - OA2, "funder supplied the ERC20 leg");
        } else {
            assertEq(_spendable(adapter, t1), adapterLeg1 - OA1, "funder supplied the ERC20 leg");
        }
        assertEq(
            _spendable(adapter, address(0)),
            adapterEth - ethLeg - ADAPTER_COMP,
            "funder supplied the ETH leg plus the compensation, and nothing more"
        );
        assertEq(punt.executionGasComp(mt.reportId), ADAPTER_COMP, "only the compensation reached the core");

        // the pass-through left nothing behind on the designated reporter
        assertEq(_spendable(designated, address(0)), 0, "no ETH residue: leg consumed, compensation forwarded");
        assertEq(_spendable(designated, t1), 0, "no leg1 residue");
        assertEq(_spendable(designated, t2), 0, "no leg2 residue");
        assertEq(punt.executionGasComp(0), 0, "no compensation stranded on report id zero");

        // and the report settles back to the designated reporter, not the funder
        vm.prank(swapper);
        punt.close{value: 0}(swapId, _dutchInput(), mt.swap, true, _emptyPermit2(), 0);

        Vm.Log[] memory closeLogs = _executeReport(swapId, mt, closeExecutor);
        assertTrue(
            _hasLog(closeLogs, OpenPuntStorage.PositionClosed.selector, swapId), "timely intent closes the live report"
        );

        // Both legs settle to the designated reporter, not to the funder.
        assertEq(_spendable(designated, address(0)), ethLeg, "settlement paid the ETH leg to the designated reporter");
        assertEq(
            _spendable(designated, erc20Leg) - designatedErc20,
            erc20Amount,
            "settlement paid the ERC20 leg to the designated reporter too"
        );
        assertEq(
            _spendable(adapter, erc20Leg),
            adapterErc20 - erc20Amount,
            "the funder stays down the ERC20 leg: it funded the report but is not the oracle reporter"
        );

        assertEq(_spendable(closeExecutor, address(0)), ADAPTER_COMP, "executor paid the compensation exactly once");
        assertEq(punt.executionGasComp(mt.reportId), 0, "no compensation left on the report");
        assertEq(_spendable(address(punt), erc20Leg), 0, "no ERC20 leg stranded on the core");
        assertEq(_spendable(address(punt), address(0)), 0, "no ETH leg or compensation stranded on the core");
        _assertNoLegResidue(t1, t2);
    }

    function test_delegated_ethIsToken1() public {
        _runDelegated(Legs.EthIsToken1);
    }

    function test_delegated_ethIsToken2() public {
        _runDelegated(Legs.EthIsToken2);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Rollback
    // ══════════════════════════════════════════════════════════════════

    struct Roll {
        bytes32 positionHash;
        bytes32 dutchHash;
        uint128 pendingComp;
        uint256 nextReportId;
        uint256 designatedEth;
        uint256 designatedLeg;
        uint256 funderEth;
        uint256 funderLeg;
    }

    function _rollSnapshot(uint256 swapId, address funder, address erc20Leg) internal view returns (Roll memory r) {
        r.positionHash = punt.swaps(swapId);
        r.dutchHash = _storedDutchState(swapId);
        (r.pendingComp,,) = _closeState(swapId);
        r.nextReportId = oracle.nextReportId();
        r.designatedEth = _spendable(designated, address(0));
        r.designatedLeg = _spendable(designated, erc20Leg);
        r.funderEth = _spendable(funder, address(0));
        r.funderLeg = _spendable(funder, erc20Leg);
    }

    function _assertRolledBack(Roll memory r, uint256 swapId, address funder, address erc20Leg, string memory what)
        internal
        view
    {
        (uint128 pending,,) = _closeState(swapId);
        assertEq(punt.swaps(swapId), r.positionHash, string.concat(what, ": position hash"));
        assertEq(_storedDutchState(swapId), r.dutchHash, string.concat(what, ": dutch resolution"));
        assertEq(pending, r.pendingComp, string.concat(what, ": pending compensation"));
        assertEq(oracle.nextReportId(), r.nextReportId, string.concat(what, ": report id allocation"));
        assertEq(punt.executionGasComp(r.nextReportId), 0, string.concat(what, ": no compensation recorded"));
        assertEq(_spendable(designated, address(0)), r.designatedEth, string.concat(what, ": designated ETH"));
        assertEq(_spendable(designated, erc20Leg), r.designatedLeg, string.concat(what, ": designated ERC20 leg"));
        assertEq(_spendable(funder, address(0)), r.funderEth, string.concat(what, ": funder ETH"));
        assertEq(_spendable(funder, erc20Leg), r.funderLeg, string.concat(what, ": funder ERC20 leg"));
    }

    /// @dev A funder with allowances but not enough internal ETH to cover leg + compensation.
    function test_rollback_adapterLacksInternalEth() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,, address t2) =
            _openFor(Legs.EthIsToken1);
        OpenPuntStorage.CloseDutch memory dutch = _startDefaultAuction(swapId, active);

        address poorFunder = address(0x5002);
        vm.deal(poorFunder, 10 ether);
        vm.startPrank(poorFunder);
        oracle.deposit{value: 0.1 ether}(address(0), 0.1 ether, poorFunder); // far below OA1
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        vm.stopPrank();
        _mintAndDeposit(tokenB, poorFunder, 100e18);

        Roll memory r = _rollSnapshot(swapId, poorFunder, t2);

        vm.prank(poorFunder);
        vm.expectRevert(OracleErrors.InsufficientInternalBalance.selector);
        puntLifecycle.report(
            swapId, _expectedDutchHash(dutch), active, p.preimage, _noTiming(), designated, OA1, OA2, ADAPTER_COMP
        );

        _assertRolledBack(r, swapId, poorFunder, t2, "funder short of ETH");
        assertEq(_storedAuctionHash(swapId, active), keccak256(abi.encode(dutch)), "auction consumption rolled back");
    }

    function test_rollback_adapterLacksInternalEthAllowance() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,, address t2) =
            _openFor(Legs.EthIsToken1);
        OpenPuntStorage.CloseDutch memory dutch = _startDefaultAuction(swapId, active);

        vm.prank(adapter);
        oracle.approveInternal(address(punt), address(0), 0);

        Roll memory r = _rollSnapshot(swapId, adapter, t2);

        vm.prank(adapter);
        vm.expectRevert(OracleErrors.InsufficientInternalAllowance.selector);
        puntLifecycle.report(
            swapId, _expectedDutchHash(dutch), active, p.preimage, _noTiming(), designated, OA1, OA2, ADAPTER_COMP
        );

        _assertRolledBack(r, swapId, adapter, t2, "funder ETH allowance revoked");
        assertEq(_storedAuctionHash(swapId, active), keccak256(abi.encode(dutch)), "auction consumption rolled back");
    }

    struct Deep {
        uint256 adapterEth;
        uint256 adapterLeg;
        uint256 halfEth;
        uint256 halfLeg;
        uint256 nextId;
        bytes32 positionHash;
        bytes32 dutchHash;
        uint128 pendingComp;
        uint128 hbReportId;
        uint48 hbTimestamp;
        uint256 halfCollat;
        uint256 swapperCollat;
    }

    function _deepSnapshot(uint256 swapId, address half, address erc20Leg) internal view returns (Deep memory d) {
        d.adapterEth = _spendable(adapter, address(0));
        d.adapterLeg = _spendable(adapter, erc20Leg);
        d.halfEth = _spendable(half, address(0));
        d.halfLeg = _spendable(half, erc20Leg);
        d.nextId = oracle.nextReportId();
        d.positionHash = punt.swaps(swapId);
        d.dutchHash = _storedDutchState(swapId);
        (d.pendingComp,,) = _closeState(swapId);
        (d.hbReportId, d.hbTimestamp) = punt.liquidationHeartbeats(swapId);
        d.halfCollat = _spendable(half, address(collat));
        d.swapperCollat = _spendable(swapper, address(collat));
    }

    function _assertDeepRollback(Deep memory d, uint256 swapId, address half, address erc20Leg) internal view {
        // both funder assets restored, including the ETH the oracle had already consumed
        assertEq(_spendable(adapter, address(0)), d.adapterEth, "funder ETH fully restored");
        assertEq(_spendable(adapter, erc20Leg), d.adapterLeg, "funder ERC20 leg fully restored");

        // the designated reporter holds nothing it was temporarily handed
        assertEq(_spendable(half, address(0)), d.halfEth, "designated reporter ETH unchanged");
        assertEq(_spendable(half, erc20Leg), d.halfLeg, "designated reporter ERC20 leg unchanged");

        // compensation, report allocation, Dutch resolution, heartbeat, position hash
        assertEq(punt.executionGasComp(d.nextId), 0, "no compensation recorded");
        assertEq(oracle.nextReportId(), d.nextId, "report id allocation rolled back");
        assertEq(oracle.oracleGame(d.nextId), bytes32(0), "no oracle game at the would-be id");
        assertEq(_storedDutchState(swapId), d.dutchHash, "dutch resolution rolled back");
        (uint128 pendingAfter,,) = _closeState(swapId);
        assertEq(pendingAfter, d.pendingComp, "pending compensation migration rolled back");
        (uint128 hbId, uint48 hbTs) = punt.liquidationHeartbeats(swapId);
        assertEq(hbId, d.hbReportId, "heartbeat binding unchanged");
        assertEq(hbTs, d.hbTimestamp, "heartbeat binding unchanged");
        assertEq(punt.swaps(swapId), d.positionHash, "position hash rolled back");

        // the Dutch reward had already been split and paid out before the revert; both the
        // reporter's reward and the swapper's remainder must be unwound too
        assertEq(_spendable(half, address(collat)), d.halfCollat, "reporter's Dutch reward rolled back");
        assertEq(_spendable(swapper, address(collat)), d.swapperCollat, "swapper's Dutch remainder rolled back");
    }

    /// @dev Atomicity after the first asset stage has already been consumed.
    ///
    ///      With EthIsToken1 and a designated reporter armed for ETH but not for token2, the
    ///      transaction gets a long way in before failing: the funder's ETH leg, ERC20 leg and
    ///      compensation all transfer to the designated reporter, OpenPunt pulls the
    ///      compensation back, and the oracle successfully consumes the ETH leg from the
    ///      designated reporter — only then does the token2 pull hit the missing allowance.
    ///
    ///      The trace confirms the failure lands inside `oracle.report`, by which point the
    ///      Dutch reward has already been split and paid to both the reporter and the swapper,
    ///      the pending compensation has migrated, and the ETH leg has been consumed. Every one
    ///      of those must unwind.
    function test_rollback_designatedReporterArmedForEthButNotForToken2() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,, address t2) =
            _openFor(Legs.EthIsToken1);
        OpenPuntStorage.CloseDutch memory dutch = _startDefaultAuction(swapId, active);

        // Armed for ETH so the earlier stages succeed, but not for the ERC20 leg.
        address halfArmed = address(0x5004);
        vm.prank(halfArmed);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        assertEq(oracle.internalAllowance(halfArmed, address(punt), t2), 0, "no ERC20 leg allowance");

        // the funder possesses and has approved everything required
        assertGt(_spendable(adapter, address(0)), uint256(OA1) + ADAPTER_COMP, "funder holds the ETH");
        assertGt(_spendable(adapter, t2), uint256(OA2), "funder holds the ERC20 leg");

        Deep memory before = _deepSnapshot(swapId, halfArmed, t2);

        vm.prank(adapter);
        vm.expectRevert(OracleErrors.InsufficientInternalBalance.selector);
        puntLifecycle.report(
            swapId, _expectedDutchHash(dutch), active, p.preimage, _noTiming(), halfArmed, OA1, OA2, ADAPTER_COMP
        );

        _assertDeepRollback(before, swapId, halfArmed, t2);

        // and a fully armed reporter still succeeds afterwards
        vm.prank(adapter);
        puntLifecycle.report(
            swapId, _expectedDutchHash(dutch), active, p.preimage, _noTiming(), designated, OA1, OA2, ADAPTER_COMP
        );
        assertEq(punt.swaps(swapId), before.positionHash, "the retry preserved the active hash");
        assertTrue(punt.swapIdToReportId(swapId) != 0, "the retry created a live report in the sidecar");
    }

    /// @dev The oracle pulls the ETH leg from the REPORTER, so the designated reporter's own
    ///      address(0) allowance is required even though the funder supplies the ETH.
    function test_rollback_designatedReporterLacksEthAllowance() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,, address t2) =
            _openFor(Legs.EthIsToken1);
        OpenPuntStorage.CloseDutch memory dutch = _startDefaultAuction(swapId, active);

        // armed for the ERC20 leg only
        address halfArmed = address(0x5003);
        vm.startPrank(halfArmed);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        vm.stopPrank();

        bytes32 positionBefore = punt.swaps(swapId);
        uint256 nextIdBefore = oracle.nextReportId();
        uint256 adapterEth0 = _spendable(adapter, address(0));

        vm.prank(adapter);
        vm.expectRevert(OracleErrors.InsufficientInternalAllowance.selector);
        puntLifecycle.report(
            swapId, _expectedDutchHash(dutch), active, p.preimage, _noTiming(), halfArmed, OA1, OA2, ADAPTER_COMP
        );

        assertEq(punt.swaps(swapId), positionBefore, "position hash rolled back");
        assertEq(oracle.nextReportId(), nextIdBefore, "report id allocation rolled back");
        assertEq(_storedAuctionHash(swapId, active), keccak256(abi.encode(dutch)), "dutch resolution rolled back");
        (uint128 pending,,) = _closeState(swapId);
        assertEq(pending, CLOSE_COMP, "pending compensation rolled back");
        assertEq(_spendable(adapter, address(0)), adapterEth0, "funder ETH untouched");
        assertEq(_spendable(halfArmed, address(0)), 0, "half-armed reporter holds nothing");
        assertEq(_spendable(halfArmed, t2), 0, "half-armed reporter holds nothing");
    }
}
