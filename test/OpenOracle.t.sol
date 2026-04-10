// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./BaseTest.sol";
import "src/OpenOracle.sol";

contract RejectingReceiver {
    bool internal rejectEth = true;

    receive() external payable {
        require(!rejectEth, "rejecting ETH");
    }

    function setRejectEth(bool shouldReject) external {
        rejectEth = shouldReject;
    }

    function claimETHProtocolFees(OpenOracle oracle) external returns (uint256) {
        return oracle.getETHProtocolFees();
    }
}

contract OpenOracleTest is BaseTest {
    uint256 constant ORACLE_FEE = 0.01 ether;
    uint256 constant SETTLER_REWARD = 0.001 ether;

    // Shared setup for OpenOracle tests
    function setUp() public override {
        BaseTest.setUp();
    }

    // ------------------------------------------------------------------------
    // Section: Protocol Fees
    // ------------------------------------------------------------------------

    // Accrues token protocol fees via dispute and withdraws them
    function testGetProtocolFees() public {
        // Create report with protocol fee recipient
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{
            value: ORACLE_FEE
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: uint128(1e18),
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: uint128(10e18),
                disputeDelay: uint24(5),
                protocolFee: uint24(1000), // 10 bps
                settlerReward: uint96(SETTLER_REWARD),
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        // Get state hash
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        // Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, uint128(1e18), uint128(2000e18), stateHash);

        // Wait for dispute delay
        vm.warp(block.timestamp + 6);

        // Dispute and swap - this will generate protocol fees
        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1), // swap token1
            uint128(1.1e18), // new amount1 (1.1x)
            uint128(2100e18), // new amount2
            uint128(2000e18), // expected amount2
            stateHash
        );

        // Calculate expected protocol fee
        uint256 expectedProtocolFee = (1e18 * 1000) / 1e7; // 0.001e18

        // Check protocol fees accrued
        assertEq(
            oracle.protocolFees(protocolFeeRecipient, address(token1)), expectedProtocolFee, "Protocol fee incorrect"
        );

        // Test withdrawal of protocol fees
        uint256 recipientBalanceBefore = token1.balanceOf(protocolFeeRecipient);

        vm.prank(protocolFeeRecipient);
        oracle.getProtocolFees(address(token1));
        assertEq(
            token1.balanceOf(protocolFeeRecipient),
            recipientBalanceBefore + expectedProtocolFee,
            "Balance after withdrawal incorrect"
        );
        assertEq(oracle.protocolFees(protocolFeeRecipient, address(token1)), 0, "Protocol fees not reset");

        // Wait for settlement
        vm.warp(block.timestamp + 300);

        // Settle
        vm.prank(charlie);
        oracle.settle(reportId);
    }

    // Accrues ETH protocol fees and withdraws them
    function testGetETHProtocolFees() public {
        // Create report to accumulate ETH protocol fees on settlement
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{
            value: ORACLE_FEE
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: uint128(1e18),
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: uint128(10e18),
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: uint96(SETTLER_REWARD),
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        // Get state hash
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        // Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, uint128(1e18), uint128(2000e18), stateHash);

        // Wait for dispute delay
        vm.warp(block.timestamp + 6);

        // Dispute to trigger ETH fee accumulation
        vm.prank(alice);
        oracle.disputeAndSwap(reportId, address(token1), uint128(1.1e18), uint128(2100e18), uint128(2000e18), stateHash);

        // Wait for settlement
        vm.warp(block.timestamp + 300);

        // Settle - this will accumulate ETH protocol fees
        vm.prank(charlie);
        oracle.settle(reportId);

        // In draft oracle, reporter always gets the fee directly via _sendEth.
        // Bob (initialReporter) can receive ETH, so fee goes directly to him.
        uint256 expectedETHFee = ORACLE_FEE - SETTLER_REWARD;
        assertEq(bob.balance, 10 ether + expectedETHFee, "Bob should have received reporter ETH fee");

        // Settler (charlie) should have received settler reward
        assertEq(charlie.balance, 10 ether + SETTLER_REWARD, "Charlie should have received settler reward");
    }

    // Accrues ETH rewards for a reporter that rejects ETH and allows later withdrawal
    function testGetETHProtocolFeesWhenReporterRejectsETH() public {
        RejectingReceiver rejectingReceiver = new RejectingReceiver();

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{
            value: ORACLE_FEE
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: uint128(1e18),
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: uint128(10e18),
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: uint96(SETTLER_REWARD),
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, uint128(1e18), uint128(2000e18), stateHash, address(rejectingReceiver));

        vm.warp(block.timestamp + 300);

        vm.prank(charlie);
        oracle.settle(reportId);

        uint256 expectedETHFee = ORACLE_FEE - SETTLER_REWARD;

        assertEq(charlie.balance, 10 ether + SETTLER_REWARD, "Charlie should have received settler reward");
        assertEq(
            oracle.accruedProtocolFees(address(rejectingReceiver)), expectedETHFee, "ETH protocol fee incorrect"
        );

        uint256 receiverETHBefore = address(rejectingReceiver).balance;

        rejectingReceiver.setRejectEth(false);
        uint256 withdrawnETH = rejectingReceiver.claimETHProtocolFees(oracle);

        assertEq(withdrawnETH, expectedETHFee, "Withdrawn ETH amount incorrect");
        assertEq(
            address(rejectingReceiver).balance,
            receiverETHBefore + expectedETHFee,
            "ETH balance after withdrawal incorrect"
        );
        assertEq(oracle.accruedProtocolFees(address(rejectingReceiver)), 0, "ETH protocol fees not reset");
    }

    // Withdrawing token protocol fees when none accrued does nothing
    function testGetProtocolFeesWithZeroBalance() public {
        // Test withdrawing when no fees have accrued
        uint256 balanceBefore = token1.balanceOf(protocolFeeRecipient);
        vm.prank(protocolFeeRecipient);
        oracle.getProtocolFees(address(token1));
        assertEq(token1.balanceOf(protocolFeeRecipient), balanceBefore, "Balance should not change when no fees accrued");
    }

    // Withdrawing ETH protocol fees when none accrued returns 0
    function testGetETHProtocolFeesWithZeroBalance() public {
        // Test withdrawing ETH when no fees have accrued
        vm.prank(protocolFeeRecipient);
        uint256 withdrawn = oracle.getETHProtocolFees();
        assertEq(withdrawn, 0, "Should return 0 when no ETH fees accrued");
    }

    // Only the configured recipient can withdraw accrued protocol fees
    function testOnlyRecipientCanWithdrawFees() public {
        // Create report and generate protocol fees
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{
            value: ORACLE_FEE
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: uint128(1e18),
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: uint128(10e18),
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: uint96(SETTLER_REWARD),
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, uint128(1e18), uint128(2000e18), stateHash);

        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        oracle.disputeAndSwap(reportId, address(token1), uint128(1.1e18), uint128(2100e18), uint128(2000e18), stateHash);

        // Try to withdraw as non-recipient (should do nothing since alice has no accrued fees)
        uint256 aliceBalanceBefore = token1.balanceOf(alice);
        vm.prank(alice);
        oracle.getProtocolFees(address(token1));
        assertEq(token1.balanceOf(alice), aliceBalanceBefore, "Non-recipient balance should not change");

        // Verify recipient can withdraw their fees
        uint256 recipientBalanceBefore = token1.balanceOf(protocolFeeRecipient);
        uint256 expectedFee = oracle.protocolFees(protocolFeeRecipient, address(token1));
        vm.prank(protocolFeeRecipient);
        oracle.getProtocolFees(address(token1));
        assertEq(token1.balanceOf(protocolFeeRecipient), recipientBalanceBefore + expectedFee, "Recipient should receive exact protocol fee");
    }

    // Reverts when initial report amount1 does not match exactToken1Report
    function testSubmitInitialReportRevertsWhenAmount1IsInvalid() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: uint128(1e18),
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: uint128(10e18),
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: uint96(SETTLER_REWARD),
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        vm.expectRevert(OpenOracle.InvalidAmount1.selector);
        oracle.submitInitialReport(reportId, uint128(1e18 + 1), uint128(2000e18), stateHash);
    }

    // Reverts when initial report amount2 is zero
    function testSubmitInitialReportRevertsWhenAmount2IsZero() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: uint128(1e18),
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: uint128(10e18),
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: uint96(SETTLER_REWARD),
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        vm.expectRevert(OpenOracle.InvalidAmount2.selector);
        oracle.submitInitialReport(reportId, uint128(1e18), uint128(0), stateHash);
    }

    // ------------------------------------------------------------------------
    // Section: Oracle Lifecycle
    // ------------------------------------------------------------------------

    // Full lifecycle: create → initial report → dispute → settle
    function testOracleLifecycle() public {
        uint256 aliceETHBefore = alice.balance;

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);

        uint256 charlieETHBefore = charlie.balance;

        // Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{
            value: ORACLE_FEE
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: uint128(1e18),
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: uint128(10e18),
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: uint96(SETTLER_REWARD),
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                protocolFeeRecipient: address(0)
            })
        );

        // Check Alice paid the oracle fee
        assertEq(alice.balance, aliceETHBefore - ORACLE_FEE, "Alice should have paid oracle fee");
        assertEq(address(oracle).balance, ORACLE_FEE, "Oracle should have received fee");

        // Get state hash
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        // Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, uint128(1e18), uint128(2000e18), stateHash);

        // Check Bob's tokens were transferred to oracle
        assertEq(token1.balanceOf(bob), bobToken1Before - 1e18, "Bob should have sent 1 token1");
        assertEq(token2.balanceOf(bob), bobToken2Before - 2000e18, "Bob should have sent 2000 token2");
        assertEq(token1.balanceOf(address(oracle)), 1e18, "Oracle should have 1 token1");
        assertEq(token2.balanceOf(address(oracle)), 2000e18, "Oracle should have 2000 token2");

        // Wait for dispute delay
        vm.warp(block.timestamp + 6);

        // Track balances before dispute
        uint256 aliceToken1BeforeDispute = token1.balanceOf(alice);
        uint256 aliceToken2BeforeDispute = token2.balanceOf(alice);
        uint256 bobToken1BeforeDispute = token1.balanceOf(bob);

        // Dispute and swap
        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1), // swap token1
            uint128(1.1e18), // new amount1 (1.1x)
            uint128(2100e18), // new amount2
            uint128(2000e18), // expected amount2
            stateHash
        );

        // Calculate fees
        uint256 fee = (1e18 * 3000) / 1e7; // 0.003e18
        uint256 protocolFee = (1e18 * 1000) / 1e7; // 0.001e18

        // Check dispute effects:
        // Alice paid: 1e18 + fee + protocolFee (for swap) + 1.1e18 (new contribution)
        uint256 aliceToken1Spent = 1e18 + fee + protocolFee + 1.1e18;
        assertEq(token1.balanceOf(alice), aliceToken1BeforeDispute - aliceToken1Spent, "Alice token1 after dispute");

        // Alice contributed 100e18 token2 (to make up difference from 2000 to 2100)
        assertEq(token2.balanceOf(alice), aliceToken2BeforeDispute - 100e18, "Alice should have sent 100 token2");

        // Bob (initial reporter) received: 2*1e18 + fee token1
        assertEq(token1.balanceOf(bob), bobToken1BeforeDispute + 2e18 + fee, "Bob should receive refund + fee");

        // Oracle balances after dispute: 1.1e18 token1, 2100e18 token2
        assertEq(token1.balanceOf(address(oracle)), 1.1e18 + protocolFee, "Oracle token1 after dispute");
        assertEq(token2.balanceOf(address(oracle)), 2100e18, "Oracle token2 after dispute");

        // Wait for settlement
        vm.warp(block.timestamp + 300);

        // Track balances before settlement
        uint256 aliceToken1BeforeSettle = token1.balanceOf(alice);
        uint256 aliceToken2BeforeSettle = token2.balanceOf(alice);

        // Settle
        vm.prank(charlie);
        oracle.settle(reportId);
        (uint256 price, uint256 settlementTimestamp) = oracle.getSettlementData(reportId);

        // Check settlement effects:
        // Charlie gets settler reward
        assertEq(charlie.balance, charlieETHBefore + SETTLER_REWARD, "Charlie should get settler reward");

        // Alice (current reporter after dispute) gets back her tokens
        assertEq(token1.balanceOf(alice), aliceToken1BeforeSettle + 1.1e18, "Alice should get back 1.1 token1");
        assertEq(token2.balanceOf(alice), aliceToken2BeforeSettle + 2100e18, "Alice should get back 2100 token2");

        // Oracle should have no tokens left (except protocol fees)
        assertEq(token1.balanceOf(address(oracle)), protocolFee, "Oracle should only have protocol fee");
        assertEq(token2.balanceOf(address(oracle)), 0, "Oracle should have no token2");

        // Verify settlement data
        assertGt(price, 0, "Price should be set");
        assertEq(settlementTimestamp, block.timestamp, "Settlement timestamp should match");
    }

    // Reverts when trying to settle a report twice
    function testSettleRevertsWhenReportIsAlreadySettled() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: uint128(1e18),
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: uint128(10e18),
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: uint96(SETTLER_REWARD),
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                protocolFeeRecipient: address(0)
            })
        );

        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, uint128(1e18), uint128(2000e18), stateHash);

        vm.warp(block.timestamp + 300);

        vm.prank(charlie);
        oracle.settle(reportId);

        vm.expectRevert(OpenOracle.AlreadySettled.selector);
        vm.prank(alice);
        oracle.settle(reportId);
    }

    // Logs gas for a second settle after re-cooling oracle storage to simulate a fresh transaction
    function testGas_SettleRevertsWhenReportIsAlreadySettledWithColdSlots() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: uint128(1e18),
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: uint128(10e18),
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: uint96(SETTLER_REWARD),
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                protocolFeeRecipient: address(0)
            })
        );

        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, uint128(1e18), uint128(2000e18), stateHash);

        vm.warp(block.timestamp + 300);

        vm.prank(charlie);
        oracle.settle(reportId);

        // Reset the oracle's access list state so the second settle reads cold storage slots again.
        vm.cool(address(oracle));

        (bool ok, bytes memory revertData) = address(oracle).call(abi.encodeCall(OpenOracle.settle, (reportId)));
        uint256 gasUsed = vm.snapshotGasLastCall("settleAlreadySettledColdSlots");

        assertFalse(ok, "second settle should revert");
        assertEq(revertData.length, 4, "unexpected revert data length");
        assertEq(bytes4(revertData), OpenOracle.AlreadySettled.selector, "wrong revert selector");

        emit log_named_uint("gas settle already settled cold slots", gasUsed);
    }
}
