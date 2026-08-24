// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CloseBase} from "./CloseBase.t.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The report sidecar changes independently while the active position commitment stays stable.
contract ReportIdSidecarTest is CloseBase {
    function setUp() public {
        _setUpClose();
    }

    function test_activeHashStaysStableAcrossReportCycles() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        bytes32 activeHash = punt.swaps(swapId);

        Matched memory first = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, 0);
        assertEq(punt.swapIdToReportId(swapId), first.reportId, "first report stored in sidecar");
        assertEq(punt.swaps(swapId), activeHash, "first report did not change the active hash");

        Vm.Log[] memory logs = _executeReport(swapId, first, closeExecutor);
        assertTrue(_hasLog(logs, OpenPuntStorage.LiquidationFailed.selector, swapId), "first report is reusable");
        assertEq(punt.swapIdToReportId(swapId), 0, "first report released");
        assertEq(punt.swaps(swapId), activeHash, "reusable outcome did not change the active hash");

        Matched memory second = _reportWithDutch(swapId, _noDutch(), active, p.preimage, reporter, 0);
        assertTrue(second.reportId != first.reportId, "second report received a new id");
        assertEq(punt.swapIdToReportId(swapId), second.reportId, "second report stored in sidecar");
        assertEq(punt.swaps(swapId), activeHash, "second report did not change the active hash");
    }
}
