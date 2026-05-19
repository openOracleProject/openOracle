// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

// Coverage for oracle games where one of the report tokens is ETH (address(0)).
// Tests cover:
//   - report() with ETH as token1 / as token2
//   - dispute() where ETH is the contribution side
//   - dispute() where ETH is the refund/credit side (newAmount2 < oldAmount2 etc.)
//   - hybrid coverage: partial internal ETH balance + msg.value
//   - excess msg.value credited to reporter (NOT msg.sender) — same applies to disputer on dispute
//   - delegated ETH funding (tib=true with owner != msg.sender) for both sufficient and insufficient allowance
//   - sponsor mode (tib=false, msg.sender != reporter): caller funds externally, reporter gets the position + excess credit
contract OpenOracleGGEthTokenTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
        // Give the test addresses generous ETH for these flows.
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
    }

    function _ethAsToken1Params() internal view returns (CompatTypes.CreateReportParams memory p) {
        p = _defaultParams();
        p.token1Address = ETH_SENTINEL;
        p.token2Address = address(token2);
    }

    function _ethAsToken2Params() internal view returns (CompatTypes.CreateReportParams memory p) {
        p = _defaultParams();
        p.token1Address = address(token1);
        p.token2Address = ETH_SENTINEL;
    }

    // -------------------------------------------------------------------------
    // report() with ETH as a side
    // -------------------------------------------------------------------------

    // ETH as token1: alice sends settlerReward + amount1 of ETH.
    function testReport_EthAsToken1() public {
        CompatTypes.CreateReportParams memory p = _ethAsToken1Params();
        uint128 amount1 = 1 ether;
        uint128 amount2 = 2000e18;

        uint256 aliceEthBefore = alice.balance;
        uint256 oracleEthBefore = address(oracle).balance;

        vm.prank(alice);
        ReportContext memory ctx = _report(p, amount1, amount2, alice, false, false);
        ctx;

        uint256 spent = uint256(p.settlerReward) + amount1;
        assertEq(alice.balance, aliceEthBefore - spent, "alice spent settlerReward + amount1");
        assertEq(address(oracle).balance, oracleEthBefore + spent, "oracle holds the ETH");
    }

    // ETH as token2: alice sends settlerReward + amount2.
    function testReport_EthAsToken2() public {
        CompatTypes.CreateReportParams memory p = _ethAsToken2Params();
        uint128 amount1 = 1e18;
        uint128 amount2 = 2 ether;

        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        _report(p, amount1, amount2, alice, false, false);

        uint256 spent = uint256(p.settlerReward) + amount2;
        assertEq(alice.balance, aliceEthBefore - spent, "alice spent settlerReward + amount2");
    }

    // ETH side fully covered by internal balance: msg.value = settlerReward only.
    function testReport_EthAsToken1_FundedByInternalBalance() public {
        // Pre-deposit 5 ETH to alice's internal balance.
        vm.prank(alice);
        oracle.deposit{value: 5 ether}(ETH_SENTINEL, 5 ether, alice);
        assertEq(oracle.tokenHolder(alice, ETH_SENTINEL), 1 + 5 ether, "alice internal ETH");

        CompatTypes.CreateReportParams memory p = _ethAsToken1Params();
        uint128 amount1 = 1 ether;
        uint128 amount2 = 2000e18;

        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, amount1, amount2, alice, true, false, _emptyTiming());

        // Alice paid only settlerReward externally.
        assertEq(alice.balance, aliceEthBefore - p.settlerReward, "only settlerReward paid externally");
        // Internal ETH decremented by amount1.
        assertEq(oracle.tokenHolder(alice, ETH_SENTINEL), 1 + 5 ether - 1 ether, "internal ETH spent");
    }

    // Hybrid: partial internal coverage + msg.value covers the rest.
    function testReport_EthAsToken1_HybridCoverage() public {
        // Alice has 0.5 ETH internal; needs 1 ETH for the report.
        vm.prank(alice);
        oracle.deposit{value: 0.5 ether}(ETH_SENTINEL, 0.5 ether, alice);

        CompatTypes.CreateReportParams memory p = _ethAsToken1Params();
        uint128 amount1 = 1 ether;
        uint128 amount2 = 2000e18;

        // msg.value = settlerReward + 0.5 ether (the external portion).
        uint256 msgValue = uint256(p.settlerReward) + 0.5 ether;

        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        CompatTypes.reportRaw(oracle, msgValue, p, amount1, amount2, alice, true, false, _emptyTiming());

        assertEq(alice.balance, aliceEthBefore - msgValue, "alice paid settlerReward + 0.5 ether");
        // Internal ETH drained to sentinel.
        assertEq(oracle.tokenHolder(alice, ETH_SENTINEL), 1, "internal drained to sentinel");
    }

    // Excess msg.value: credited to the REPORTER's ETH internal balance (not msg.sender's).
    function testReport_EthAsToken1_ExcessMsgValue_Credited() public {
        CompatTypes.CreateReportParams memory p = _ethAsToken1Params();
        uint128 amount1 = 1 ether;
        uint128 amount2 = 2000e18;

        uint256 expected = uint256(p.settlerReward) + amount1;
        uint256 sent = expected + 0.5 ether; // overpay

        vm.prank(alice);
        CompatTypes.reportRaw(oracle, sent, p, amount1, amount2, alice, false, false, _emptyTiming());

        // Excess credited to alice's internal ETH balance (alice is both msg.sender and reporter).
        assertEq(oracle.tokenHolder(alice, ETH_SENTINEL), 1 + 0.5 ether, "excess credited to reporter (sentinel + 0.5)");
    }

    // Sponsor mode: alice (msg.sender) funds, bob (reporter) gets the position AND excess credit.
    function testReport_EthAsToken1_SponsorMode_ExcessCreditedToReporter() public {
        CompatTypes.CreateReportParams memory p = _ethAsToken1Params();
        uint128 amount1 = 1 ether;
        uint128 amount2 = 2000e18;

        uint256 expected = uint256(p.settlerReward) + amount1;
        uint256 sent = expected + 0.5 ether; // overpay

        uint256 aliceEthBefore = alice.balance;
        uint256 bobEthBefore = bob.balance;

        vm.prank(alice);
        CompatTypes.reportRaw(oracle, sent, p, amount1, amount2, bob, false, false, _emptyTiming());

        // alice (msg.sender) paid the whole msg.value out-of-pocket
        assertEq(alice.balance, aliceEthBefore - sent, "alice paid msg.value externally");
        // bob (reporter) doesn't get an external transfer — they get the excess as internal credit
        assertEq(bob.balance, bobEthBefore, "bob's external ETH unchanged");
        // Excess routed to bob's internal balance (the reporter's), NOT alice's
        assertEq(oracle.tokenHolder(bob, ETH_SENTINEL), 1 + 0.5 ether, "excess credited to reporter (sentinel + 0.5)");
        assertEq(oracle.tokenHolder(alice, ETH_SENTINEL), 0, "alice's internal ETH untouched");
    }

    // -------------------------------------------------------------------------
    // Delegated ETH funding (tib=true with owner != msg.sender)
    // -------------------------------------------------------------------------

    // Sufficient allowance: pulls ETH from owner's internal balance, position to owner.
    function testReport_EthAsToken1_Delegated_SufficientAllowance() public {
        // bob pre-deposits ETH and approves alice
        vm.prank(bob);
        oracle.deposit{value: 5 ether}(ETH_SENTINEL, 5 ether, bob);
        vm.prank(bob);
        oracle.approveInternal(alice, ETH_SENTINEL, 2 ether);

        CompatTypes.CreateReportParams memory p = _ethAsToken1Params();
        uint128 amount1 = 1 ether;
        uint128 amount2 = 2000e18;

        // alice sends only the settler reward — ETH-side comes from bob's internal
        uint256 aliceEthBefore = alice.balance;
        uint256 bobInternalBefore = oracle.tokenHolder(bob, ETH_SENTINEL);

        vm.prank(alice);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, amount1, amount2, bob, true, false, _emptyTiming());

        // alice paid only settlerReward
        assertEq(alice.balance, aliceEthBefore - p.settlerReward, "alice paid only settler reward");
        // bob's internal ETH debited by amount1
        assertEq(oracle.tokenHolder(bob, ETH_SENTINEL), bobInternalBefore - amount1, "bob ETH internal -= amount1");
        // allowance consumed
        assertEq(oracle.internalAllowance(bob, alice, ETH_SENTINEL), 2 ether - amount1, "allowance decremented");
    }

    // Insufficient allowance: strict-delegation revert with InsufficientInternalBalance.
    function testReport_EthAsToken1_Delegated_InsufficientAllowance_Reverts() public {
        vm.prank(bob);
        oracle.deposit{value: 5 ether}(ETH_SENTINEL, 5 ether, bob);
        // Allowance way below the amount needed
        vm.prank(bob);
        oracle.approveInternal(alice, ETH_SENTINEL, 0.1 ether);

        CompatTypes.CreateReportParams memory p = _ethAsToken1Params();
        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientInternalBalance.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1 ether, 2000e18, bob, true, false, _emptyTiming());
    }

    // Delegated dispute: tokenToSwap = ETH, disputer != msg.sender, tib1=true.
    // ETH escalation pulled from disputer's internal balance via internalAllowance.
    function testDispute_EthAsToken1_Delegated_SufficientAllowance() public {
        // alice opens the report with ETH as token1 (self-funded)
        ReportContext memory ctx = _aliceReportsEthToken1(1 ether, 2000e18);

        // bob (intended disputer) pre-deposits ETH and approves charlie to spend on his behalf
        vm.prank(bob);
        oracle.deposit{value: 5 ether}(ETH_SENTINEL, 5 ether, bob);
        // Disputer pays newAmount1 + oldAmount1 + fee + protocolFee
        //   = 1.1 + 1 + 0.0003 (3000*1e18/1e7) + 0.0001 (1000*1e18/1e7)
        //   ≈ 2.1004 ETH
        vm.prank(bob);
        oracle.approveInternal(charlie, ETH_SENTINEL, 3 ether);

        vm.warp(block.timestamp + 6);

        uint256 charlieEthBefore = charlie.balance;
        uint256 bobInternalBefore = oracle.tokenHolder(bob, ETH_SENTINEL);

        // newAmount2 == oldAmount2 → no token2 contribution required from disputer
        vm.prank(charlie);
        _dispute(ctx, ETH_SENTINEL, 1.1 ether, 2000e18, bob, true, false, 0);

        // charlie paid zero ETH externally (everything came from bob's internal balance)
        assertEq(charlie.balance, charlieEthBefore, "charlie's external ETH unchanged");

        // bob's internal ETH debited by (newAmount1 + oldAmount1 + fee + protocolFee)
        uint256 fee = (uint256(1 ether) * 3000) / 1e7;
        uint256 protoFee = (uint256(1 ether) * 1000) / 1e7;
        uint256 expectedDebit = 1.1 ether + 1 ether + fee + protoFee;
        assertEq(
            oracle.tokenHolder(bob, ETH_SENTINEL),
            bobInternalBefore - expectedDebit,
            "bob ETH internal debited correctly"
        );

        // Allowance consumed by the same amount
        assertEq(
            oracle.internalAllowance(bob, charlie, ETH_SENTINEL),
            3 ether - expectedDebit,
            "allowance decremented"
        );
    }

    // Strict-delegation revert on the dispute path with ETH side.
    function testDispute_EthAsToken1_Delegated_InsufficientAllowance_Reverts() public {
        ReportContext memory ctx = _aliceReportsEthToken1(1 ether, 2000e18);

        vm.prank(bob);
        oracle.deposit{value: 5 ether}(ETH_SENTINEL, 5 ether, bob);
        // Allowance too small for the dispute escalation
        vm.prank(bob);
        oracle.approveInternal(charlie, ETH_SENTINEL, 1 ether);

        vm.warp(block.timestamp + 6);

        vm.prank(charlie);
        vm.expectRevert(Errors.InsufficientInternalBalance.selector);
        _dispute(ctx, ETH_SENTINEL, 1.1 ether, 2000e18, bob, true, false, 0);
    }

    // -------------------------------------------------------------------------
    // dispute() where ETH is the contribution side
    // -------------------------------------------------------------------------

    function _aliceReportsEthToken1(uint128 amount1, uint128 amount2) internal returns (ReportContext memory ctx) {
        CompatTypes.CreateReportParams memory p = _ethAsToken1Params();
        vm.prank(alice);
        ctx = _report(p, amount1, amount2, alice, false, false);
    }

    function _aliceReportsEthToken2(uint128 amount1, uint128 amount2) internal returns (ReportContext memory ctx) {
        CompatTypes.CreateReportParams memory p = _ethAsToken2Params();
        vm.prank(alice);
        ctx = _report(p, amount1, amount2, alice, false, false);
    }

    // ETH is token1 (the swap side). Bob disputes; pays ETH for token1 contribution
    // (newA1 + oldA1 + fee + protocolFee), token2 is ERC20.
    function testDispute_EthAsToken1_BobPaysEthContribution() public {
        ReportContext memory ctx = _aliceReportsEthToken1(1 ether, 2000e18);

        vm.warp(block.timestamp + 6);

        uint256 fee = (1 ether * 3000) / 1e7;
        uint256 protoFee = (1 ether * 1000) / 1e7;
        uint256 expectedEthPay = 1.1 ether + 1 ether + fee + protoFee; // ~2.104 ether
        uint256 expectedToken2Pay = 100e18; // newA2 - oldA2

        uint256 bobEthBefore = bob.balance;
        uint256 bobToken2Before = token2.balanceOf(bob);

        vm.prank(bob);
        oracle.dispute{value: expectedEthPay}(
            ctx.reportId,
            address(0), // tokenToSwap = ETH (token1)
            1.1 ether,
            2100e18,
            bob,
            false,
            false,
            ctx.game,
            ctx.helper,
            _emptyTiming()
        );

        assertEq(bob.balance, bobEthBefore - expectedEthPay, "bob paid ETH for token1 swap");
        assertEq(token2.balanceOf(bob), bobToken2Before - expectedToken2Pay, "bob paid token2 net contribution");

        // Alice (previousReporter) credited 2*oldA1 + fee in token1 (= ETH).
        assertEq(
            oracle.tokenHolder(alice, ETH_SENTINEL),
            1 + 2 ether + fee,
            "alice ETH credit = 2*oldA1 + fee"
        );
    }

    // ETH is token2 (the swap side). Bob disputes; pays ETH for token2 contribution.
    function testDispute_EthAsToken2_BobPaysEthContribution() public {
        ReportContext memory ctx = _aliceReportsEthToken2(1e18, 2 ether);

        vm.warp(block.timestamp + 6);

        uint256 fee = (2 ether * 3000) / 1e7;
        uint256 protoFee = (2 ether * 1000) / 1e7;
        uint256 expectedEthPay = 2.1 ether + 2 ether + fee + protoFee; // ~4.008 ether
        uint256 expectedToken1Pay = 0.1e18; // newA1 - oldA1

        uint256 bobEthBefore = bob.balance;
        uint256 bobToken1Before = token1.balanceOf(bob);

        vm.prank(bob);
        oracle.dispute{value: expectedEthPay}(
            ctx.reportId,
            address(0), // tokenToSwap = ETH (token2)
            1.1e18,
            2.1 ether,
            bob,
            false,
            false,
            ctx.game,
            ctx.helper,
            _emptyTiming()
        );

        assertEq(bob.balance, bobEthBefore - expectedEthPay, "bob paid ETH for token2 swap");
        assertEq(token1.balanceOf(bob), bobToken1Before - expectedToken1Pay, "bob paid token1 contribution");

        // Alice (previousReporter) credited 2*oldA2 + fee in token2 (= ETH).
        assertEq(
            oracle.tokenHolder(alice, ETH_SENTINEL),
            1 + 4 ether + fee,
            "alice ETH credit = 2*oldA2 + fee"
        );
    }

    // ETH is token2 (NOT the swap side — token1 is swap). Disputer pays
    // netToken2Contribution in ETH (newA2 - oldA2 if positive).
    function testDispute_EthAsToken2_NetContribution() public {
        ReportContext memory ctx = _aliceReportsEthToken2(1e18, 2 ether);

        vm.warp(block.timestamp + 6);

        // Swap token1 (ERC20). Token2 (ETH) net contribution = 0.1 ether.
        uint256 expectedEthPay = 0.1 ether;
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protoFee = (1e18 * 1000) / 1e7;
        uint256 expectedToken1Pay = 1.1e18 + 1e18 + fee + protoFee;

        uint256 bobEthBefore = bob.balance;
        uint256 bobToken1Before = token1.balanceOf(bob);

        vm.prank(bob);
        oracle.dispute{value: expectedEthPay}(
            ctx.reportId,
            address(token1),
            1.1e18,
            2.1 ether,
            bob,
            false,
            false,
            ctx.game,
            ctx.helper,
            _emptyTiming()
        );

        assertEq(bob.balance, bobEthBefore - expectedEthPay, "bob paid net ETH contribution");
        assertEq(
            token1.balanceOf(bob),
            bobToken1Before - expectedToken1Pay,
            "bob paid token1 dispute amount"
        );
        // Alice (previousReporter) credited in token1 (the ERC20).
        assertEq(_heldTokens(alice, address(token1)), 1 + 2e18 + fee, "alice token1 credit");
        // protocolFeeRecipient credited in token1.
        assertEq(_heldTokens(protocolFeeRecipient, address(token1)), 1 + protoFee, "protocol fee in token1");
    }

    // -------------------------------------------------------------------------
    // dispute() where ETH is the refund/credit side
    // -------------------------------------------------------------------------

    // Swap token1 (ERC20). Token2 (ETH) net RECEIVE: newA2 < oldA2 → bob credited refund.
    function testDispute_EthAsToken2_NetRefund() public {
        ReportContext memory ctx = _aliceReportsEthToken2(1e18, 2 ether);

        vm.warp(block.timestamp + 6);

        // newA2 = 1.5 ether < oldA2 = 2 ether → refund 0.5 ether credited to bob.
        // newA1 = 1.1e18.
        // fee boundary: oldPrice = 1e18 * 1e18 / 2e18 = 5e17. newPrice = 1.1e18 * 1e18 / 1.5e18 = 7.33e17.
        // newPrice >= upperBoundary? upper = 5e17 + 5e17 * 4000 / 1e7 = 5e17 + 2e14 = 5.0002e17. newPrice 7.33e17 > upper. ✓ outside.

        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protoFee = (1e18 * 1000) / 1e7;
        uint256 expectedToken1Pay = 1.1e18 + 1e18 + fee + protoFee;

        uint256 bobEthBefore = bob.balance;
        uint256 bobInternalEthBefore = oracle.tokenHolder(bob, ETH_SENTINEL);
        uint256 bobToken1Before = token1.balanceOf(bob);

        vm.prank(bob);
        oracle.dispute{value: 0}(
            ctx.reportId,
            address(token1),
            1.1e18,
            1.5 ether,
            bob,
            false,
            false,
            ctx.game,
            ctx.helper,
            _emptyTiming()
        );

        // Bob external ETH unchanged (no msg.value).
        assertEq(bob.balance, bobEthBefore, "bob external ETH unchanged");
        // Bob paid token1 (the swap-side ERC20) externally.
        assertEq(
            token1.balanceOf(bob),
            bobToken1Before - expectedToken1Pay,
            "bob paid token1 dispute amount"
        );
        // Bob internal ETH credited the refund.
        assertEq(
            oracle.tokenHolder(bob, ETH_SENTINEL),
            bobInternalEthBefore == 0 ? (1 + 0.5 ether) : (bobInternalEthBefore + 0.5 ether),
            "bob refund credited internally"
        );
    }

    // -------------------------------------------------------------------------
    // settle() with ETH-side: currentReporter gets ETH credited
    // -------------------------------------------------------------------------

    function testSettle_EthAsToken1_CurrentReporterCredited() public {
        ReportContext memory ctx = _aliceReportsEthToken1(1 ether, 2000e18);
        vm.warp(block.timestamp + 301);

        uint256 aliceInternalEthBefore = oracle.tokenHolder(alice, ETH_SENTINEL);
        uint256 aliceInternalT2Before = _heldTokens(alice, address(token2));

        vm.prank(charlie);
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);

        // Alice (currentReporter) credited 1 ETH + 2000e18 token2.
        // Note: alice's ETH internal balance was 0 before, so the credit seeds the sentinel.
        assertEq(
            oracle.tokenHolder(alice, ETH_SENTINEL),
            aliceInternalEthBefore == 0 ? (1 + 1 ether) : (aliceInternalEthBefore + 1 ether),
            "alice ETH credited 1 ether"
        );
        assertEq(_heldTokens(alice, address(token2)), aliceInternalT2Before + 2000e18, "alice token2 credited");
    }

    // ETH is token1 (NOT the swap side — token2 is the ERC20 swap side).
    // tokenToSwap = token2; disputer pays netToken1Contribution in ETH (newA1 - oldA1 if positive)
    // plus the full token2 dispute amount in ERC20.
    // Symmetric mirror of testDispute_EthAsToken2_NetContribution.
    function testDispute_EthAsToken1_NetContribution() public {
        ReportContext memory ctx = _aliceReportsEthToken1(1 ether, 2000e18);

        vm.warp(block.timestamp + 6);

        // Swap token2 (ERC20). Token1 (ETH) net contribution = 0.1 ether.
        uint256 expectedEthPay = 0.1 ether;
        uint256 fee = (2000e18 * 3000) / 1e7;
        uint256 protoFee = (2000e18 * 1000) / 1e7;
        uint256 expectedToken2Pay = 2100e18 + 2000e18 + fee + protoFee;

        uint256 bobEthBefore = bob.balance;
        uint256 bobToken2Before = token2.balanceOf(bob);

        vm.prank(bob);
        oracle.dispute{value: expectedEthPay}(
            ctx.reportId,
            address(token2),
            1.1 ether,
            2100e18,
            bob,
            false,
            false,
            ctx.game,
            ctx.helper,
            _emptyTiming()
        );

        assertEq(bob.balance, bobEthBefore - expectedEthPay, "bob paid net ETH contribution");
        assertEq(
            token2.balanceOf(bob),
            bobToken2Before - expectedToken2Pay,
            "bob paid token2 dispute amount"
        );
        // Alice (previousReporter) credited 2*oldA2 + fee in token2 (the ERC20 swap side).
        assertEq(_heldTokens(alice, address(token2)), 1 + 2 * 2000e18 + fee, "alice token2 credit");
        // Protocol fee credited in token2.
        assertEq(_heldTokens(protocolFeeRecipient, address(token2)), 1 + protoFee, "protocol fee in token2");
    }

    // -------------------------------------------------------------------------
    // msg.value validation reverts
    // -------------------------------------------------------------------------

    function testDeposit_ERC20_NonzeroMsgValue_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidMsgValue.selector);
        oracle.deposit{value: 1 wei}(address(token1), 1e18, alice);
    }

    function testDeposit_ETH_MsgValueMismatch_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidMsgValue.selector);
        // amount = 1 ether but msg.value = 0.5 ether.
        oracle.deposit{value: 0.5 ether}(ETH_SENTINEL, 1 ether, alice);
    }

    function testDeposit_ETH_MsgValueOverpay_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidMsgValue.selector);
        // amount = 0.5 ether but msg.value = 1 ether.
        oracle.deposit{value: 1 ether}(ETH_SENTINEL, 0.5 ether, alice);
    }

    function testReport_EthSide_Underfunded_Reverts() public {
        CompatTypes.CreateReportParams memory p = _ethAsToken1Params();
        // settlerReward + amount1 = 0.001 + 1 = 1.001 ether expected.
        // Send less.
        vm.prank(alice);
        vm.expectRevert(Errors.MsgValueTooLow.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1 ether, 2000e18, alice, false, false, _emptyTiming());
    }

    function testDispute_EthSide_Underfunded_Reverts() public {
        ReportContext memory ctx = _aliceReportsEthToken1(1 ether, 2000e18);
        vm.warp(block.timestamp + 6);

        // Bob needs to send ~2.104 ether but sends 1 ether.
        vm.prank(bob);
        vm.expectRevert(Errors.MsgValueTooLow.selector);
        oracle.dispute{value: 1 ether}(
            ctx.reportId,
            address(0), // tokenToSwap = ETH (token1)
            1.1 ether,
            2100e18,
            bob,
            false,
            false,
            ctx.game,
            ctx.helper,
            _emptyTiming()
        );
    }

    function testDispute_ERC20Pair_NonzeroMsgValue_RevertsNeitherTokenIsETH() public {
        // Default params: ERC20 pair (token1, token2 both ERC20).
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 6);

        vm.prank(bob);
        vm.expectRevert(Errors.NeitherTokenIsETH.selector);
        oracle.dispute{value: 1 wei}(
            ctx.reportId,
            address(token1),
            1.1e18,
            2100e18,
            bob,
            false,
            false,
            ctx.game,
            ctx.helper,
            _emptyTiming()
        );
    }
}
