// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {OpenOracleErrors} from "../../src/OpenOracleErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Minimal interface used by the composability callbacks below.
interface IOpenOracleGGForCallback {
    function getHeldTokens(address tokenToGet) external;
    function getHeldEth() external returns (uint256);
    function submitInitialReport(
        uint256 reportId,
        uint128 amount1,
        uint128 amount2,
        bytes32 stateHash,
        address reporter,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OpenOracleGG.TimingBoundaries calldata timing
    ) external;
    function settle(uint256 reportId) external;
}

// Callback that records the data it receives at settle time.
contract LifecycleCallback {
    bool public called;
    uint256 public reportIdSeen;
    uint256 public priceSeen;
    uint256 public settlementTimestampSeen;
    address public token1Seen;
    address public token2Seen;
    uint256 public gasReceived;

    function onOracleSettle(
        uint256 reportId,
        uint256 price,
        uint256 settlementTimestamp,
        address t1,
        address t2
    ) external {
        called = true;
        gasReceived = gasleft();
        reportIdSeen = reportId;
        priceSeen = price;
        settlementTimestampSeen = settlementTimestamp;
        token1Seen = t1;
        token2Seen = t2;
    }
}

// Callback that doubles as the report's currentReporter and withdraws its
// credited token balances inside the callback.
contract WithdrawingReporterCallback {
    IOpenOracleGGForCallback public immutable oracle;
    bool public called;
    bool public t1WithdrawOk;
    bool public t2WithdrawOk;

    constructor(address _oracle) {
        oracle = IOpenOracleGGForCallback(_oracle);
    }

    function approveOracle(address token) external {
        IERC20(token).approve(address(oracle), type(uint256).max);
    }

    function submit(uint256 reportId, uint128 amount1, uint128 amount2, bytes32 sh) external {
        OpenOracleGG.TimingBoundaries memory empty;
        oracle.submitInitialReport(reportId, amount1, amount2, sh, address(this), false, false, empty);
    }

    function onOracleSettle(uint256, uint256, uint256, address t1, address t2) external {
        called = true;
        // settle() must have already credited my token balances before this call,
        // so the withdrawals should succeed and leave 1 sentinel.
        try oracle.getHeldTokens(t1) {
            t1WithdrawOk = true;
        } catch {}
        try oracle.getHeldTokens(t2) {
            t2WithdrawOk = true;
        } catch {}
    }
}

// Callback that doubles as the settler and withdraws its ETH credit inside the
// callback.
contract WithdrawingSettlerCallback {
    IOpenOracleGGForCallback public immutable oracle;
    bool public called;
    bool public ethWithdrawOk;

    constructor(address _oracle) {
        oracle = IOpenOracleGGForCallback(_oracle);
    }

    receive() external payable {}

    function settleAs(uint256 reportId) external {
        oracle.settle(reportId);
    }

    function onOracleSettle(uint256, uint256, uint256, address, address) external {
        called = true;
        try oracle.getHeldEth() returns (uint256) {
            ethWithdrawOk = true;
        } catch {}
    }
}

contract OpenOracleGGStorageModeTest is BaseGGTest {
    uint256 constant ORACLE_FEE = 0.01 ether;
    uint256 constant SETTLER_REWARD = 0.001 ether;

    function setUp() public override {
        BaseGGTest.setUp();
    }

    // -------------------------------------------------------------------------
    // Section: Oracle Lifecycle (ported from OpenOracle.testOracleLifecycle)
    // -------------------------------------------------------------------------

    // Full lifecycle: create -> initial report -> dispute -> settle.
    // In gas-golfing, settlement does not push tokens; reporter and settler
    // rewards are credited to internal balances and must be withdrawn.
    function testOracleLifecycle_StorageMode() public {
        uint256 aliceETHBefore = alice.balance;
        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);

        // Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);

        assertEq(alice.balance, aliceETHBefore - ORACLE_FEE, "alice paid oracle fee");
        assertEq(address(oracle).balance, ORACLE_FEE, "oracle holds oracle fee");

        bytes32 stateHash = _stateHash(reportId);
        assertTrue(stateHash != bytes32(0), "stateHash must be set after create");

        // Submit initial report.
        // Sentinel is now virtual: bob's slots are seeded to 1 in storage but
        // NO extra real tokens are pulled.
        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());

        assertEq(token1.balanceOf(bob), bobToken1Before - 1e18, "bob token1 = report amount only");
        assertEq(token2.balanceOf(bob), bobToken2Before - 2000e18, "bob token2 = report amount only");

        // Bob's tokenHolder slot reads 1 (virtual sentinel marker).
        assertEq(_heldTokens(bob, address(token1)), 1, "bob token1 sentinel seeded");
        assertEq(_heldTokens(bob, address(token2)), 1, "bob token2 sentinel seeded");

        // Wait past dispute delay.
        vm.warp(block.timestamp + 6);

        uint256 aliceToken1BeforeDispute = token1.balanceOf(alice);
        uint256 aliceToken2BeforeDispute = token2.balanceOf(alice);
        uint256 bobToken1BeforeDispute = token1.balanceOf(bob);
        uint256 bobToken2BeforeDispute = token2.balanceOf(bob);

        // Alice disputes by swapping token1 (claims token2 is overvalued).
        vm.prank(alice);
        _disputeAndSwap(
            reportId,
            address(token1),
            1.1e18,
            2100e18,
            2000e18,
            stateHash,
            false,
            false,
            _emptyTiming()
        );

        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protocolFee = (1e18 * 1000) / 1e7;

        // Alice's slots get virtually seeded to 1 (no extra token pull).
        uint256 aliceToken1Spent = 1e18 + fee + protocolFee + 1.1e18;
        assertEq(token1.balanceOf(alice), aliceToken1BeforeDispute - aliceToken1Spent, "alice token1 after dispute");
        assertEq(token2.balanceOf(alice), aliceToken2BeforeDispute - 100e18, "alice token2 after dispute");

        // Bob (previous reporter) is paid via tokenHolder, not external transfer.
        assertEq(token1.balanceOf(bob), bobToken1BeforeDispute, "bob external balance unchanged");
        assertEq(token2.balanceOf(bob), bobToken2BeforeDispute, "bob external balance unchanged");
        // Bob's internal balance grows by 2*oldAmount1 + fee on top of his sentinel.
        assertEq(_heldTokens(bob, address(token1)), 1 + 2e18 + fee, "bob internal token1 = sentinel + 2*oldAmount + fee");

        // Protocol fee credited; the contract seeds the fee recipient's sentinel
        // before adding the fee, so slot = 1 + protocolFee.
        assertEq(_heldTokens(protocolFeeRecipient, address(token1)), 1 + protocolFee, "protocol fee internal (sentinel + fee)");

        // Wait for settlement window.
        vm.warp(block.timestamp + 300);

        // Settle by charlie.
        uint256 charlieETHBefore = charlie.balance;
        vm.prank(charlie);
        oracle.settle(reportId);

        // Charlie's settler reward goes to ethHolder, not push transfer.
        // Slot was 0 → contract seeds sentinel (1) + reward.
        assertEq(charlie.balance, charlieETHBefore, "charlie external ETH unchanged");
        assertEq(oracle.ethHolder(charlie), 1 + SETTLER_REWARD, "settler reward credited (sentinel + reward)");

        // Bob (initial reporter) gets the reporter fee (msg.value - settler reward).
        assertEq(oracle.ethHolder(bob), 1 + ORACLE_FEE - SETTLER_REWARD, "initial reporter ETH credited");

        // Alice (current reporter at settle) is credited her tokens.
        assertEq(_heldTokens(alice, address(token1)), 1 + 1.1e18, "alice internal token1 = dust + 1.1");
        assertEq(_heldTokens(alice, address(token2)), 1 + 2100e18, "alice internal token2 = dust + 2100");

        // Withdraw and confirm: getHeldTokens leaves 1 unit dust.
        uint256 aliceToken1Pre = token1.balanceOf(alice);
        vm.prank(alice);
        oracle.getHeldTokens(address(token1));
        assertEq(token1.balanceOf(alice), aliceToken1Pre + 1.1e18, "alice withdrew 1.1 token1");
        assertEq(_heldTokens(alice, address(token1)), 1, "1 dust remains");

        // Withdraw ETH for charlie. Sentinel is virtual — full reward delivered.
        uint256 charlieETHPre = charlie.balance;
        vm.prank(charlie);
        uint256 amt = oracle.getHeldEth();
        assertEq(amt, SETTLER_REWARD, "charlie withdrew full settler reward");
        assertEq(charlie.balance, charlieETHPre + SETTLER_REWARD, "charlie balance updated");
        assertEq(oracle.ethHolder(charlie), 1, "1 wei virtual sentinel remains");

        // Settlement timestamp lives in storage at OracleGame slot+2 (offset 208 bits).
        bytes32 base = keccak256(abi.encode(reportId, ORACLE_GAME_SLOT));
        bytes32 packed = vm.load(address(oracle), bytes32(uint256(base) + 2));
        uint48 settlementTimestamp = uint48(uint256(packed) >> 208);
        assertEq(settlementTimestamp, block.timestamp, "settlement ts matches");
        // Price = currentAmount1 * 1e18 / currentAmount2 (computed off-chain).
        uint256 price = (uint256(1.1e18) * 1e18) / 2100e18;
        assertGt(price, 0, "price set");
    }

    // -------------------------------------------------------------------------
    // Section: Protocol Fees (ported)
    // -------------------------------------------------------------------------

    function testProtocolFees_AccrueAndWithdraw_StorageMode() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);

        bytes32 stateHash = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());

        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, stateHash, false, false, _emptyTiming()
        );

        uint256 expectedProtocolFee = (1e18 * 1000) / 1e7; // 0.001e18
        // Slot was 0 before; contract seeds sentinel to 1 then adds the fee.
        assertEq(
            _heldTokens(protocolFeeRecipient, address(token1)),
            1 + expectedProtocolFee,
            "protocol fee accrued (sentinel + fee)"
        );

        uint256 recipientBefore = token1.balanceOf(protocolFeeRecipient);
        vm.prank(protocolFeeRecipient);
        oracle.getHeldTokens(address(token1));
        // Virtual sentinel: recipient withdraws the full fee (no real forfeit).
        assertEq(
            token1.balanceOf(protocolFeeRecipient),
            recipientBefore + expectedProtocolFee,
            "recipient withdrew full fee"
        );
        assertEq(_heldTokens(protocolFeeRecipient, address(token1)), 1, "sentinel left behind");
    }

    // Withdrawing token fees with no balance is a no-op.
    function testGetHeldTokens_NoBalance_NoOp() public {
        uint256 before_ = token1.balanceOf(protocolFeeRecipient);
        vm.prank(protocolFeeRecipient);
        oracle.getHeldTokens(address(token1));
        assertEq(token1.balanceOf(protocolFeeRecipient), before_, "no change");
    }

    // Withdrawing ETH with no balance returns 0.
    function testGetHeldEth_NoBalance_ReturnsZero() public {
        vm.prank(protocolFeeRecipient);
        uint256 amt = oracle.getHeldEth();
        assertEq(amt, 0, "no eth withdrawn");
    }

    // -------------------------------------------------------------------------
    // Section: Escalation Halt (ported from EscalationHaltCapTest)
    // -------------------------------------------------------------------------

    function testEscalationHaltCapBehavior_StorageMode() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.exactToken1Report = 10e18;
        p.escalationHalt = 15e18;
        p.multiplier = 200; // 2x
        p.disputeDelay = 0;
        p.settlementTime = 120;
        p.protocolFeeRecipient = alice;

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(p, true);

        bytes32 stateHash = _stateHash(reportId);

        vm.prank(alice);
        _submitInitialReport(reportId, 10e18, 10e18, stateHash, false, false, _emptyTiming());

        // 10 * 2 = 20 > 15, so cap at 15.
        vm.prank(bob);
        _disputeAndSwap(reportId, address(token1), 15e18, 12e18, 10e18, stateHash, false, false, _emptyTiming());

        // Now at cap; expected next = halt + 1 = 15e18 + 1.
        vm.prank(charlie);
        _disputeAndSwap(
            reportId, address(token1), 15e18 + 1, 10e18, 12e18, stateHash, false, false, _emptyTiming()
        );

        // Read currentAmount1 — second field of OracleGame at slot keccak(id,1)+1.
        bytes32 baseSlot = keccak256(abi.encode(reportId, ORACLE_GAME_SLOT));
        bytes32 packedSlot = vm.load(address(oracle), bytes32(uint256(baseSlot) + 1));
        // currentAmount1 is uint128 at offset 0 of slot 1, currentAmount2 uint128 at offset 16.
        uint128 currentAmount1 = uint128(uint256(packedSlot));
        uint128 currentAmount2 = uint128(uint256(packedSlot) >> 128);
        assertEq(currentAmount1, 15e18 + 1, "currentAmount1 = halt + 1");
        assertEq(currentAmount2, 10e18, "currentAmount2 = last newAmount2");
    }

    function testEscalationHaltCapBehavior_RevertsWrongAmount() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.exactToken1Report = 5e18;
        p.escalationHalt = 8e18;
        p.multiplier = 150;
        p.disputeDelay = 0;
        p.protocolFeeRecipient = alice;

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(p, true);
        bytes32 stateHash = _stateHash(reportId);

        vm.prank(alice);
        _submitInitialReport(reportId, 5e18, 5e18, stateHash, false, false, _emptyTiming());

        // expected = 5 * 1.5 = 7.5e18; bob sends 7.6e18 -> should revert.
        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.InvalidAmount1.selector);
        _disputeAndSwap(reportId, address(token1), 76e17, 6e18, 5e18, stateHash, false, false, _emptyTiming());

        // Correct amount succeeds.
        vm.prank(bob);
        _disputeAndSwap(reportId, address(token1), 75e17, 6e18, 5e18, stateHash, false, false, _emptyTiming());

        // 7.5 * 1.5 = 11.25, but capped at halt 8e18.
        // Charlie tries uncapped value -> revert.
        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.InvalidAmount1.selector);
        _disputeAndSwap(
            reportId, address(token1), 1125e16, 7e18, 6e18, stateHash, false, false, _emptyTiming()
        );

        // Capped value succeeds.
        vm.prank(charlie);
        _disputeAndSwap(reportId, address(token1), 8e18, 7e18, 6e18, stateHash, false, false, _emptyTiming());
    }

    // -------------------------------------------------------------------------
    // Section: Dispute Delay
    // -------------------------------------------------------------------------

    function testDisputeTooEarly_Reverts_StorageMode() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 stateHash = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());

        // Default disputeDelay is 5 seconds; immediate dispute reverts.
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.DisputeTooEarly.selector);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, stateHash, false, false, _emptyTiming()
        );

        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, stateHash, false, false, _emptyTiming()
        );
    }

    // -------------------------------------------------------------------------
    // Section: Settlement Timing
    // -------------------------------------------------------------------------

    function testSettleTooEarly_Reverts_StorageMode() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 stateHash = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());

        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.SettleTooEarly.selector);
        oracle.settle(reportId);

        vm.warp(block.timestamp + 301);

        vm.prank(charlie);
        oracle.settle(reportId);
    }

    function testDisputeTooLate_Reverts_StorageMode() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 stateHash = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());

        // Past settlementTime, disputes are no longer allowed.
        vm.warp(block.timestamp + 301);
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.DisputeTooLate.selector);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, stateHash, false, false, _emptyTiming()
        );
    }

    // -------------------------------------------------------------------------
    // Section: Fee Boundary
    // -------------------------------------------------------------------------

    function testFeeBoundary_RevertsInsideBoundary_StorageMode() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 stateHash = _stateHash(reportId);

        // Initial price = 1/2000.
        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());

        vm.warp(block.timestamp + 6);

        // newPrice equal to oldPrice is inside the fee band -> reverts.
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.NewPriceInsideFeeBoundary.selector);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2200e18, 2000e18, stateHash, false, false, _emptyTiming()
        );

        // Sufficiently different price succeeds.
        vm.prank(alice);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, stateHash, false, false, _emptyTiming()
        );
    }

    // -------------------------------------------------------------------------
    // Section: Callback
    // -------------------------------------------------------------------------

    function testCallback_FiresAtSettle_StorageMode() public {
        LifecycleCallback cb = new LifecycleCallback();
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.callbackContract = address(cb);
        p.callbackSelector = LifecycleCallback.onOracleSettle.selector;
        p.callbackGasLimit = 200_000;

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, true);
        bytes32 stateHash = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());

        vm.warp(block.timestamp + 301);

        vm.prank(charlie);
        oracle.settle{gas: 1_000_000}(reportId);

        assertTrue(cb.called(), "callback fired");
        assertEq(cb.reportIdSeen(), reportId, "callback reportId");
        assertEq(cb.token1Seen(), address(token1), "callback token1");
        assertEq(cb.token2Seen(), address(token2), "callback token2");
        // Price should be 1e18 * 1e18 / 2000e18 = 5e14
        assertEq(cb.priceSeen(), (1e18 * 1e18) / 2000e18, "callback price");
    }

    // Composability: settle() now writes the currentReporter token credits and
    // initialReporter/settler ETH credits BEFORE invoking the callback. This
    // means a callback contract that is itself the currentReporter can withdraw
    // its credited tokens during settle. Verifies the new ordering.
    function testCallback_AsCurrentReporter_WithdrawsDuringSettle() public {
        WithdrawingReporterCallback cb = new WithdrawingReporterCallback(address(oracle));

        // Fund cb so it can act as initial reporter (it needs to pay 1e18 + 2000e18).
        token1.transfer(address(cb), 5e18);
        token2.transfer(address(cb), 5000e18);
        cb.approveOracle(address(token1));
        cb.approveOracle(address(token2));

        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.callbackContract = address(cb);
        p.callbackSelector = WithdrawingReporterCallback.onOracleSettle.selector;
        p.callbackGasLimit = 400_000;

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, true);
        bytes32 sh = _stateHash(reportId);

        // cb is the reporter and currentReporter at settle time.
        cb.submit(reportId, 1e18, 2000e18, sh);

        uint256 cbT1Before = token1.balanceOf(address(cb));
        uint256 cbT2Before = token2.balanceOf(address(cb));

        vm.warp(block.timestamp + 301);

        vm.prank(charlie);
        oracle.settle{gas: 1_500_000}(reportId);

        // The callback withdrew its credits: external balances are up by the
        // amounts that were credited during settle, and the internal slots are
        // back to the virtual sentinel (1).
        assertEq(token1.balanceOf(address(cb)), cbT1Before + 1e18, "cb withdrew token1 in callback");
        assertEq(token2.balanceOf(address(cb)), cbT2Before + 2000e18, "cb withdrew token2 in callback");
        assertEq(_heldTokens(address(cb), address(token1)), 1, "cb token1 sentinel left");
        assertEq(_heldTokens(address(cb), address(token2)), 1, "cb token2 sentinel left");

        assertTrue(cb.called(), "callback fired");
        assertTrue(cb.t1WithdrawOk(), "callback t1 withdraw ok");
        assertTrue(cb.t2WithdrawOk(), "callback t2 withdraw ok");
    }

    // ETH composability: callback is the settler (msg.sender of settle), and
    // inside the callback it calls getHeldEth() to claim the settler reward.
    function testCallback_AsSettler_WithdrawsETHDuringSettle() public {
        WithdrawingSettlerCallback cb = new WithdrawingSettlerCallback(address(oracle));

        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.callbackContract = address(cb);
        p.callbackSelector = WithdrawingSettlerCallback.onOracleSettle.selector;
        p.callbackGasLimit = 400_000;

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, true);
        bytes32 sh = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, _emptyTiming());

        vm.warp(block.timestamp + 301);

        uint256 cbEthBefore = address(cb).balance;

        // cb is msg.sender of settle, so settler reward is credited to cb.ethHolder.
        cb.settleAs(reportId);

        // After settle, cb withdrew its ETH inside the callback.
        assertEq(address(cb).balance, cbEthBefore + SETTLER_REWARD, "cb withdrew settler reward in callback");
        assertEq(oracle.ethHolder(address(cb)), 1, "cb ETH sentinel left");
        assertTrue(cb.called(), "callback fired");
        assertTrue(cb.ethWithdrawOk(), "callback eth withdraw ok");
    }

    // -------------------------------------------------------------------------
    // Section: trackDisputes
    // -------------------------------------------------------------------------

    function testTrackDisputes_HistoryRecorded_StorageMode() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.trackDisputes = true;

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, true);
        bytes32 stateHash = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());

        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, stateHash, false, false, _emptyTiming()
        );

        // Index 0 = initial report
        (uint128 a1_0, uint128 a2_0, address tok_0,) = oracle.disputeHistory(reportId, 0);
        assertEq(a1_0, 1e18, "init record amount1");
        assertEq(a2_0, 2000e18, "init record amount2");
        assertEq(tok_0, address(0), "init record has no tokenToSwap");

        // Index 1 = first dispute
        (uint128 a1_1, uint128 a2_1, address tok_1,) = oracle.disputeHistory(reportId, 1);
        assertEq(a1_1, 1.1e18, "dispute record amount1");
        assertEq(a2_1, 2100e18, "dispute record amount2");
        assertEq(tok_1, address(token1), "dispute record tokenToSwap");
    }

    // -------------------------------------------------------------------------
    // Section: State hash mismatch
    // -------------------------------------------------------------------------

    function testInvalidStateHash_Reverts_StorageMode() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);

        // Use a wrong stateHash on submit.
        bytes32 wrong = bytes32(uint256(0xdead));
        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.InvalidStateHash.selector);
        _submitInitialReport(reportId, 1e18, 2000e18, wrong, false, false, _emptyTiming());
    }

    function testReportAlreadySubmitted_Reverts_StorageMode() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 stateHash = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());

        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.ReportAlreadySubmitted.selector);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());
    }

    function testInvalidAmount1_Reverts_StorageMode() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 stateHash = _stateHash(reportId);

        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.InvalidAmount1.selector);
        _submitInitialReport(reportId, 2e18, 2000e18, stateHash, false, false, _emptyTiming());
    }

    function testInvalidAmount2_Reverts_StorageMode() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 stateHash = _stateHash(reportId);

        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.InvalidAmount2.selector);
        _submitInitialReport(reportId, 1e18, 0, stateHash, false, false, _emptyTiming());
    }

    function testCannotSettleTwice_StorageMode() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 stateHash = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());

        vm.warp(block.timestamp + 301);

        vm.prank(charlie);
        oracle.settle(reportId);

        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.AlreadySettled.selector);
        oracle.settle(reportId);
    }

    function testCannotCreateWithSameToken() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.token2Address = p.token1Address;

        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.TokensCannotBeSame.selector);
        oracle.createReportInstance{value: ORACLE_FEE}(p, true);
    }

    function testCannotCreateWithLowMultiplier() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.multiplier = 99; // < 100

        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.MultiplierTooLow.selector);
        oracle.createReportInstance{value: ORACLE_FEE}(p, true);
    }

    function testCannotCreateWithHighFees() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.feePercentage = uint24(5e6);
        p.protocolFee = uint24(5e6 + 1); // sum > 1e7

        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.FeesTooHigh.selector);
        oracle.createReportInstance{value: ORACLE_FEE}(p, true);
    }
}
