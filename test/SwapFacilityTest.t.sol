// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./BaseTest.sol";
import "src/OracleSwapFacility.sol";

contract TestCallback {
    uint256 public lastReportId;
    uint256 public lastAmount1;
    uint256 public lastAmount2;
    uint256 public lastTimestamp;
    address public lastToken1;
    address public lastToken2;

    function openOracleCallback(
        uint256 reportId,
        uint256 amount1,
        uint256 amount2,
        uint256 timestamp,
        address token1,
        address token2
    ) external {
        lastReportId = reportId;
        lastAmount1 = amount1;
        lastAmount2 = amount2;
        lastTimestamp = timestamp;
        lastToken1 = token1;
        lastToken2 = token2;
    }
}

contract SwapFacilityTest is BaseTest {
    OracleSwapFacility swapFacility;
    TestCallback callbackContract;

    function setUp() public override {
        BaseTest.setUp();

        // Deploy contracts specific to this suite
        swapFacility = new OracleSwapFacility(address(oracle));
        callbackContract = new TestCallback();
    }

    // Creates a swap with full configuration incl. callback and verifies results
    function testSwapFacilityWithFullParams() public {
        uint256 aliceToken1Start = token1.balanceOf(alice);
        uint256 aliceToken2Start = token2.balanceOf(alice);
        vm.startPrank(alice);

        uint128 amount1 = 5e18;
        uint128 amount2 = 5e18;
        uint24 fee = 3000; // 3 bps
        uint48 settlementTime = 120; // 2 minutes

        // Approve tokens for swap facility
        token1.approve(address(swapFacility), amount1);
        token2.approve(address(swapFacility), amount2);

        // Create swap with full parameters including callback
        uint256 reportId = swapFacility.createAndReport{
            value: 0.001 ether
        }(
            address(token1),
            address(token2),
            amount1,
            amount2,
            fee,
            settlementTime,
            true, // timeType = true (seconds)
            address(callbackContract), // callback contract
            true, // trackDisputes
            uint32(300000), // callback gas limit
            uint16(101), // multiplier (default 101%)
            uint24(0), // disputeDelay
            amount1 // escalationHalt (set to amount1)
        );

        // Verify tokens were transferred to oracle
        assertEq(token1.balanceOf(address(oracle)), amount1);
        assertEq(token2.balanceOf(address(oracle)), amount2);
        assertEq(reportId, 1, "Report ID should be 1");

        vm.stopPrank();

        // Bob disputes to trigger a swap
        vm.warp(block.timestamp + 1); // Past dispute delay (which is 0)
        vm.startPrank(bob);

        // Dispute by swapping token1
        uint256 disputeFee = (amount1 * fee) / 1e7;
        // Since escalationHalt = amount1, we can only increase by 1
        uint256 newAmount1 = amount1 + 1;
        // Need to change price by more than 3% to be outside fee boundary
        // Original price is 1:1, so we need amount2 to be significantly different
        uint256 newAmount2 = (amount2 * 95) / 100; // 5% less, definitely outside 3% boundary

        // Approve plenty of both tokens for the dispute
        token1.approve(address(oracle), 100e18);
        token2.approve(address(oracle), 100e18);

        (bytes32 stateHash,,,,,) = oracle.extraData(1);
        oracle.disputeAndSwap(1, address(token1), uint128(newAmount1), uint128(newAmount2), uint128(amount2), stateHash);

        vm.stopPrank();

        // Settle and verify callback
        vm.warp(block.timestamp + settlementTime);
        oracle.settle(reportId);

        // Check callback was executed
        assertEq(callbackContract.lastReportId(), reportId);
        assertTrue(callbackContract.lastAmount1() > 0);
        assertTrue(callbackContract.lastAmount2() > 0);
        assertEq(callbackContract.lastToken1(), address(token1));
        assertEq(callbackContract.lastToken2(), address(token2));

        // Verify Alice got her expected tokens back
        // She should have received 2 * amount1 + fee from the token1 swap
        uint256 expectedToken1 = 2 * amount1 + disputeFee;
        assertEq(token1.balanceOf(alice), aliceToken1Start - amount1 + expectedToken1);
        assertEq(token2.balanceOf(alice), aliceToken2Start - amount2); // No token2 back since it was swapped
    }

    // Creates a swap with the simple constructor and verifies results
    function testSwapFacilityWithSimpleParams() public {
        uint256 aliceToken1Start = token1.balanceOf(alice);
        uint256 aliceToken2Start = token2.balanceOf(alice);
        vm.startPrank(alice);

        uint128 amount1 = 5e18;
        uint128 amount2 = 5e18;
        uint24 fee = 3000; // 3 bps
        uint48 settlementTime = 120; // 2 minutes

        // Approve tokens for swap facility
        token1.approve(address(swapFacility), amount1);
        token2.approve(address(swapFacility), amount2);

        // Create swap with simple parameters (no callback)
        uint256 reportId = swapFacility.createAndReport{
            value: 0.001 ether
        }(address(token1), address(token2), amount1, amount2, fee, settlementTime);

        // Verify tokens were transferred to oracle
        assertEq(token1.balanceOf(address(oracle)), amount1);
        assertEq(token2.balanceOf(address(oracle)), amount2);
        assertEq(reportId, 1, "Report ID should be 1");

        vm.stopPrank();

        // Bob disputes to trigger a swap
        vm.warp(block.timestamp + 1); // Past dispute delay (which is 0)
        vm.startPrank(bob);

        // Dispute by swapping token1
        uint256 disputeFee = (amount1 * fee) / 1e7;
        // Since escalationHalt = amount1, we can only increase by 1
        uint256 newAmount1 = amount1 + 1;
        // Need to change price by more than 3% to be outside fee boundary
        // Original price is 1:1, so we need amount2 to be significantly different
        uint256 newAmount2 = (amount2 * 95) / 100; // 5% less, definitely outside 3% boundary

        // Approve plenty of both tokens for the dispute
        token1.approve(address(oracle), 100e18);
        token2.approve(address(oracle), 100e18);

        (bytes32 stateHash,,,,,) = oracle.extraData(1);
        oracle.disputeAndSwap(1, address(token1), uint128(newAmount1), uint128(newAmount2), uint128(amount2), stateHash);

        vm.stopPrank();

        // Settle
        vm.warp(block.timestamp + settlementTime);
        oracle.settle(reportId);

        // Verify no callback was executed (since we didn't set one)
        assertEq(callbackContract.lastReportId(), 0);

        // Verify Alice got her expected tokens back
        // She should have received 2 * amount1 + fee from the token1 swap
        uint256 expectedToken1 = 2 * amount1 + disputeFee;
        assertEq(token1.balanceOf(alice), aliceToken1Start - amount1 + expectedToken1);
        assertEq(token2.balanceOf(alice), aliceToken2Start - amount2); // No token2 back since it was swapped
    }
}
