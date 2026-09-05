// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";

contract ReportBountyTest is CloseBase {
    function setUp() public {
        _setUpClose();
    }

    function test_reportWithoutAuctionEmitsZeroBounty() public {
        _checkBounty(false, 0, 0);
    }

    function test_reportEmitsActualGrownBounty() public {
        _checkBounty(true, 2 * DUTCH_ROUND_LEN, 22.5e18);
    }

    function test_reportEmitsCappedBounty() public {
        _checkBounty(true, 6 * DUTCH_ROUND_LEN, DUTCH_MAX);
    }

    function test_reportAtAuctionExpirationEmitsZeroBounty() public {
        _checkBounty(true, 30 minutes, 0);
    }

    function _checkBounty(bool withAuction, uint256 delaySeconds, uint128 expected) internal {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openIdle();
        OpenPuntStorage.CloseDutch memory dutch = _noDutch();
        if (withAuction) dutch = _startDefaultAuction(swapId, active);
        vm.warp(vm.getBlockTimestamp() + delaySeconds);

        uint256 reportId = oracle.nextReportId();
        uint256 balanceBefore = _spendable(reporter, address(collat));
        vm.recordLogs();
        vm.prank(reporter);
        puntLifecycle.report(
            swapId, _expectedDutchHash(dutch), active, p.preimage, _noTiming(), reporter, A1, A2_OPEN, 0
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Existing consumers retain their original topic and state-only data decoder.
        bytes32 legacyTopic = 0xd275e775eb154290b570020176f25ae1ec34ab60a8faef5befc9b7a2fbbc68a6;
        Vm.Log memory legacy = _findLog(logs, address(punt), legacyTopic, swapId);
        assertEq(legacy.topics[2], bytes32(reportId));
        assertEq(legacy.topics[3], bytes32(uint256(uint160(reporter))));
        assertEq(legacy.data, abi.encode(active), "legacy payload unchanged");

        Vm.Log memory bounty = _findLog(logs, address(punt), OpenPuntStorage.ReportBountyPaid.selector, swapId);
        assertEq(bounty.topics.length, 3);
        assertEq(bounty.topics[2], bytes32(reportId));
        uint128 paid = abi.decode(bounty.data, (uint128));
        assertEq(paid, expected, "reported bounty");
        assertEq(_spendable(reporter, address(collat)) - balanceBefore, paid, "event equals actual payment");

        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(punt) && logs[i].topics[0] == OpenPuntStorage.ReportBountyPaid.selector) {
                ++count;
            }
        }
        assertEq(count, 1, "one bounty event per report");
    }
}
