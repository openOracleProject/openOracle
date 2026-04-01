// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {OpenOracle as OpenOracleDraft} from "src/openOracleDraft.sol";
import "./utils/MockERC20.sol";

contract RejectingReceiver {
    bool internal rejectEth = true;

    receive() external payable {
        require(!rejectEth, "rejecting ETH");
    }

    function setRejectEth(bool shouldReject) external {
        rejectEth = shouldReject;
    }

    function claimETHProtocolFees(OpenOracleDraft oracle) external returns (uint256) {
        return oracle.getETHProtocolFees();
    }
}

abstract contract BaseTestDraft is Test {
    OpenOracleDraft internal oracle;
    MockERC20 internal token1;
    MockERC20 internal token2;

    address internal alice = address(0x1);
    address internal bob = address(0x2);
    address internal charlie = address(0x3);
    address payable internal protocolFeeRecipient = payable(address(0x123456));

    function setUp() public virtual {
        oracle = new OpenOracleDraft();
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        token1.transfer(alice, 100 ether);
        token1.transfer(bob, 100 ether);
        token1.transfer(charlie, 100 ether);
        token2.transfer(alice, 100_000 ether);
        token2.transfer(bob, 100_000 ether);
        token2.transfer(charlie, 100_000 ether);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);
        vm.deal(protocolFeeRecipient, 1 ether);

        vm.startPrank(alice);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(charlie);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }
}

contract OpenOracleDraftTest is BaseTestDraft {
    uint256 constant ORACLE_FEE = 0.01 ether;
    uint96 constant SETTLER_REWARD = 0.001 ether;

    function setUp() public override {
        BaseTestDraft.setUp();
    }

    function testGetProtocolFees() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracleDraft.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
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
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        oracle.disputeAndSwap(reportId, address(token1), 1.1e18, 2100e18, 2000e18, stateHash);

        uint256 expectedProtocolFee = (1e18 * 1000) / 1e7;

        assertEq(
            oracle.protocolFees(protocolFeeRecipient, address(token1)), expectedProtocolFee, "Protocol fee incorrect"
        );

        uint256 recipientBalanceBefore = token1.balanceOf(protocolFeeRecipient);

        vm.prank(protocolFeeRecipient);
        oracle.getProtocolFees(address(token1));
        assertEq(
            token1.balanceOf(protocolFeeRecipient),
            recipientBalanceBefore + expectedProtocolFee,
            "Balance after withdrawal incorrect"
        );
        assertEq(oracle.protocolFees(protocolFeeRecipient, address(token1)), 0, "Protocol fees not reset");

        vm.warp(block.timestamp + 300);

        vm.prank(charlie);
        oracle.settle(reportId);
    }

    function testGetETHProtocolFees() public {
        RejectingReceiver rejectingReceiver = new RejectingReceiver();

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracleDraft.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
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
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash, address(rejectingReceiver));

        vm.warp(block.timestamp + 300);

        vm.prank(charlie);
        oracle.settle(reportId);

        uint256 expectedETHFee = ORACLE_FEE - SETTLER_REWARD;

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

    function testGetProtocolFeesWithZeroBalance() public {
        uint256 balanceBefore = token1.balanceOf(protocolFeeRecipient);
        vm.prank(protocolFeeRecipient);
        oracle.getProtocolFees(address(token1));
        assertEq(token1.balanceOf(protocolFeeRecipient), balanceBefore, "Balance should not change when no fees accrued");
    }

    function testGetETHProtocolFeesWithZeroBalance() public {
        vm.prank(protocolFeeRecipient);
        uint256 withdrawn = oracle.getETHProtocolFees();
        assertEq(withdrawn, 0, "Should return 0 when no ETH fees accrued");
    }

    function testOnlyRecipientCanWithdrawFees() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracleDraft.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
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
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        oracle.disputeAndSwap(reportId, address(token1), 1.1e18, 2100e18, 2000e18, stateHash);

        uint256 aliceBalanceBefore = token1.balanceOf(alice);
        vm.prank(alice);
        oracle.getProtocolFees(address(token1));
        assertEq(token1.balanceOf(alice), aliceBalanceBefore, "Non-recipient balance should not change");

        uint256 recipientBalanceBefore = token1.balanceOf(protocolFeeRecipient);
        uint256 expectedFee = oracle.protocolFees(protocolFeeRecipient, address(token1));
        vm.prank(protocolFeeRecipient);
        oracle.getProtocolFees(address(token1));
        assertEq(token1.balanceOf(protocolFeeRecipient), recipientBalanceBefore + expectedFee, "Recipient should receive exact protocol fee");
    }

    function testOracleLifecycle() public {
        uint256 aliceETHBefore = alice.balance;
        uint256 bobETHBefore = bob.balance;

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);

        uint256 charlieETHBefore = charlie.balance;

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracleDraft.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                protocolFeeRecipient: address(0)
            })
        );

        assertEq(alice.balance, aliceETHBefore - ORACLE_FEE, "Alice should have paid oracle fee");
        assertEq(address(oracle).balance, ORACLE_FEE, "Oracle should have received fee");

        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        assertEq(token1.balanceOf(bob), bobToken1Before - 1e18, "Bob should have sent 1 token1");
        assertEq(token2.balanceOf(bob), bobToken2Before - 2000e18, "Bob should have sent 2000 token2");
        assertEq(token1.balanceOf(address(oracle)), 1e18, "Oracle should have 1 token1");
        assertEq(token2.balanceOf(address(oracle)), 2000e18, "Oracle should have 2000 token2");

        vm.warp(block.timestamp + 6);

        uint256 aliceToken1BeforeDispute = token1.balanceOf(alice);
        uint256 aliceToken2BeforeDispute = token2.balanceOf(alice);
        uint256 bobToken1BeforeDispute = token1.balanceOf(bob);

        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1),
            1.1e18,
            2100e18,
            2000e18,
            stateHash
        );

        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protocolFee = (1e18 * 1000) / 1e7;

        uint256 aliceToken1Spent = 1e18 + fee + protocolFee + 1.1e18;
        assertEq(token1.balanceOf(alice), aliceToken1BeforeDispute - aliceToken1Spent, "Alice token1 after dispute");

        assertEq(token2.balanceOf(alice), aliceToken2BeforeDispute - 100e18, "Alice should have sent 100 token2");

        assertEq(token1.balanceOf(bob), bobToken1BeforeDispute + 2e18 + fee, "Bob should receive refund + fee");

        assertEq(token1.balanceOf(address(oracle)), 1.1e18 + protocolFee, "Oracle token1 after dispute");
        assertEq(token2.balanceOf(address(oracle)), 2100e18, "Oracle token2 after dispute");

        vm.warp(block.timestamp + 300);

        uint256 aliceToken1BeforeSettle = token1.balanceOf(alice);
        uint256 aliceToken2BeforeSettle = token2.balanceOf(alice);

        vm.prank(charlie);
        oracle.settle(reportId);

        assertEq(charlie.balance, charlieETHBefore + SETTLER_REWARD, "Charlie should get settler reward");
        assertEq(bob.balance, bobETHBefore + (ORACLE_FEE - SETTLER_REWARD), "Bob should get reporter reward");

        assertEq(token1.balanceOf(alice), aliceToken1BeforeSettle + 1.1e18, "Alice should get back 1.1 token1");
        assertEq(token2.balanceOf(alice), aliceToken2BeforeSettle + 2100e18, "Alice should get back 2100 token2");

        assertEq(token1.balanceOf(address(oracle)), protocolFee, "Oracle should only have protocol fee");
        assertEq(token2.balanceOf(address(oracle)), 0, "Oracle should have no token2");

        (uint256 settledAmount1, uint256 settledAmount2) = oracle.getSettlementData(reportId);
        (, , , , uint48 settlementTimestamp, , , , bool isDistributed) = oracle.reportStatus(reportId);

        assertEq(settledAmount1, 1.1e18, "Settled token1 amount should match final report");
        assertEq(settledAmount2, 2100e18, "Settled token2 amount should match final report");
        assertTrue(isDistributed, "Report should be marked settled");
        assertEq(uint256(settlementTimestamp), block.timestamp, "Settlement timestamp should match");
    }
}
