// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Behavioral tests for slim primitives added in V3:
///         internalTransferFrom, pushOrCredit, and the protocolFeeRecipient
///         pre-dusting branch in report().
///
///         depositFromPermit2 has its own file because it requires sig-verifying
///         Permit2 scaffolding.
contract OpenOracleGGNewPrimitivesTest is BaseGGTest {
    EthRejecter internal rejecter;

    function setUp() public override {
        super.setUp();
        rejecter = new EthRejecter();
        vm.deal(address(rejecter), 10 ether);
    }

    // ── internalTransferFrom ──────────────────────────────────────────
    // Note: _heldTokens returns raw mapping value INCLUDING the 1-wei sentinel.
    // Spendable balance is _heldTokens() - 1.

    function testInternalTransferFrom_SelfTransfer_NoAllowanceNeeded() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);

        vm.prank(bob);
        oracle.internalTransferFrom(bob, alice, address(token1), 2e18);

        assertEq(_heldTokens(bob, address(token1)), 5e18 - 2e18 + 1, "bob: 3e18 spendable + sentinel");
        assertEq(_heldTokens(alice, address(token1)), 2e18 + 1, "alice: 2e18 spendable + sentinel");
        assertEq(oracle.internalAllowance(bob, bob, address(token1)), 0, "no allowance set or consumed");
    }

    function testInternalTransferFrom_Delegated_ConsumesAllowance() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.approveInternal(alice, address(token1), 3e18);

        vm.prank(alice);
        oracle.internalTransferFrom(bob, charlie, address(token1), 2e18);

        assertEq(_heldTokens(bob, address(token1)), 5e18 - 2e18 + 1, "bob debited (sentinel intact)");
        assertEq(_heldTokens(charlie, address(token1)), 2e18 + 1, "charlie credited");
        assertEq(oracle.internalAllowance(bob, alice, address(token1)), 1e18, "allowance decremented");
    }

    function testInternalTransferFrom_Delegated_MaxAllowanceNotDecremented() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.approveInternal(alice, address(token1), type(uint256).max);

        vm.prank(alice);
        oracle.internalTransferFrom(bob, charlie, address(token1), 2e18);

        assertEq(oracle.internalAllowance(bob, alice, address(token1)), type(uint256).max, "max allowance preserved");
    }

    function testInternalTransferFrom_RevertOnInsufficientAllowance() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.approveInternal(alice, address(token1), 1e18);

        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientInternalAllowance.selector);
        oracle.internalTransferFrom(bob, charlie, address(token1), 2e18);
    }

    function testInternalTransferFrom_RevertOnInsufficientBalance() public {
        // bob has only 1e18 deposited; tries to send 2e18
        vm.prank(bob);
        oracle.deposit(address(token1), 1e18, bob);

        vm.prank(bob);
        vm.expectRevert(Errors.InsufficientInternalBalance.selector);
        oracle.internalTransferFrom(bob, alice, address(token1), 2e18);
    }

    function testInternalTransferFrom_RevertOnFullBalanceTransfer_PreservesSentinel() public {
        // bob can't transfer exactly his spendable amount + sentinel — must leave the 1 wei sentinel
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);

        // Raw balance is 5e18 + 1 (sentinel). Spendable is 5e18. Attempting to transfer 5e18 + 1 reverts.
        vm.prank(bob);
        vm.expectRevert(Errors.InsufficientInternalBalance.selector);
        oracle.internalTransferFrom(bob, alice, address(token1), uint128(5e18 + 1));

        // Transferring exactly the spendable amount is OK
        vm.prank(bob);
        oracle.internalTransferFrom(bob, alice, address(token1), 5e18);
        assertEq(oracle.tokenHolder(bob, address(token1)), 1, "bob slot back to sentinel only");
    }

    function testInternalTransferFrom_ZeroAmount_NoOp() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);

        uint256 bobBefore = oracle.tokenHolder(bob, address(token1));
        uint256 aliceBefore = oracle.tokenHolder(alice, address(token1));

        vm.prank(bob);
        oracle.internalTransferFrom(bob, alice, address(token1), 0);

        // No state changes anywhere — recipient sentinel NOT seeded
        assertEq(oracle.tokenHolder(bob, address(token1)), bobBefore, "bob unchanged");
        assertEq(oracle.tokenHolder(alice, address(token1)), aliceBefore, "alice unchanged (no sentinel seed)");
    }

    function testInternalTransferFrom_RevertOnZeroRecipient() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);

        vm.prank(bob);
        vm.expectRevert(Errors.AddressCannotBeZero.selector);
        oracle.internalTransferFrom(bob, address(0), address(token1), 1e18);
    }

    // ── pushOrCredit ──────────────────────────────────────────────────

    function testPushOrCredit_ETH_PushSucceedsToEOA() public {
        vm.prank(bob);
        oracle.deposit{value: 5 ether}(ETH_SENTINEL, 5 ether, bob);

        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        oracle.pushOrCredit(ETH_SENTINEL, alice, 1 ether);

        // Pushed externally to EOA
        assertEq(alice.balance, aliceBefore + 1 ether, "alice got ETH externally");
        assertEq(_heldTokens(bob, ETH_SENTINEL), 5 ether - 1 ether + 1, "bob internal debited (sentinel intact)");
        // alice's internal slot untouched (push succeeded externally)
        assertEq(oracle.tokenHolder(alice, ETH_SENTINEL), 0, "alice internal slot uninitialized");
    }

    function testPushOrCredit_ETH_PushFails_CreditsInternal() public {
        vm.prank(bob);
        oracle.deposit{value: 5 ether}(ETH_SENTINEL, 5 ether, bob);

        uint256 rejecterExtBefore = address(rejecter).balance;
        vm.prank(bob);
        oracle.pushOrCredit(ETH_SENTINEL, address(rejecter), 1 ether);

        assertEq(address(rejecter).balance, rejecterExtBefore, "rejecter external unchanged (push failed)");
        assertEq(_heldTokens(address(rejecter), ETH_SENTINEL), 1 ether + 1, "rejecter got internal credit + sentinel");
        assertEq(_heldTokens(bob, ETH_SENTINEL), 5 ether - 1 ether + 1, "bob debited");
    }

    function testPushOrCredit_ERC20_PushFails_CreditsInternal() public {
        // Deploy a token whose transfer() reverts. Use it for an oracle.deposit so msg.sender (this)
        // has internal balance; then pushOrCredit to a recipient — the transfer should fail and
        // fall back to crediting the recipient's internal balance.
        RejectingErc20 rej = new RejectingErc20();
        rej.mint(address(this), 100e18);
        rej.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(rej), 5e18, address(this));

        uint256 aliceInternalBefore = oracle.tokenHolder(alice, address(rej));
        uint256 aliceExtBefore = rej.balanceOf(alice);

        oracle.pushOrCredit(address(rej), alice, 1e18);

        // External transfer failed, fallback credited internal
        assertEq(rej.balanceOf(alice), aliceExtBefore, "alice external unchanged (transfer reverted)");
        assertEq(oracle.tokenHolder(alice, address(rej)), aliceInternalBefore + 1e18 + 1, "alice internal credit + sentinel");
        // caller's internal balance debited
        assertEq(_heldTokens(address(this), address(rej)), 5e18 - 1e18 + 1, "caller debited (sentinel intact)");
    }

    function testPushOrCredit_ERC20_PushSucceedsToEOA() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);

        uint256 aliceExtBefore = token1.balanceOf(alice);
        vm.prank(bob);
        oracle.pushOrCredit(address(token1), alice, 1e18);

        assertEq(token1.balanceOf(alice), aliceExtBefore + 1e18, "alice got token1 externally");
        assertEq(_heldTokens(bob, address(token1)), 5e18 - 1e18 + 1, "bob debited (sentinel intact)");
    }

    function testPushOrCredit_RevertOnInsufficientBalance() public {
        // bob deposits 1e18; tries to push 2e18
        vm.prank(bob);
        oracle.deposit(address(token1), 1e18, bob);

        vm.prank(bob);
        vm.expectRevert(Errors.InsufficientInternalBalance.selector);
        oracle.pushOrCredit(address(token1), alice, 2e18);
    }

    function testPushOrCredit_RevertOnFullBalance_PreservesSentinel() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);

        // Can't push raw balance (5e18 + 1) — sentinel must remain
        vm.prank(bob);
        vm.expectRevert(Errors.InsufficientInternalBalance.selector);
        oracle.pushOrCredit(address(token1), alice, uint128(5e18 + 1));

        // Pushing exact spendable is OK
        vm.prank(bob);
        oracle.pushOrCredit(address(token1), alice, 5e18);
        assertEq(oracle.tokenHolder(bob, address(token1)), 1, "bob slot is sentinel only");
    }

    function testPushOrCredit_ZeroAmount_NoOp() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);

        uint256 bobBefore = oracle.tokenHolder(bob, address(token1));
        uint256 aliceExtBefore = token1.balanceOf(alice);
        uint256 aliceInternalBefore = oracle.tokenHolder(alice, address(token1));

        vm.prank(bob);
        oracle.pushOrCredit(address(token1), alice, 0);

        assertEq(oracle.tokenHolder(bob, address(token1)), bobBefore, "bob unchanged");
        assertEq(token1.balanceOf(alice), aliceExtBefore, "alice external unchanged");
        assertEq(oracle.tokenHolder(alice, address(token1)), aliceInternalBefore, "alice internal unchanged");
    }

    function testPushOrCredit_RevertOnZeroRecipient() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);

        vm.prank(bob);
        vm.expectRevert(Errors.AddressCannotBeZero.selector);
        oracle.pushOrCredit(address(token1), address(0), 1e18);
    }

    // ── report() pre-dusts protocolFeeRecipient ───────────────────────

    function testReport_PreDustsProtocolFeeRecipientSlot() public {
        // Use a fresh PFR that has no tokenHolder entries yet
        address freshPfr = address(0xCAFE);
        assertEq(oracle.tokenHolder(freshPfr, address(token1)), 0, "PFR token1 slot uninit");
        assertEq(oracle.tokenHolder(freshPfr, address(token2)), 0, "PFR token2 slot uninit");

        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.protocolFeeRecipient = payable(freshPfr);

        vm.prank(alice);
        _report(p, 1e18, 2000e18, false, false);

        // Both PFR token slots are now dusted (sentinel = 1) so the first dispute's fee credit
        // pays a warm SSTORE instead of a cold one.
        assertEq(oracle.tokenHolder(freshPfr, address(token1)), 1, "PFR token1 dusted");
        assertEq(oracle.tokenHolder(freshPfr, address(token2)), 1, "PFR token2 dusted");
    }

    function testReport_NoDustWhenProtocolFeeZero() public {
        address freshPfr = address(0xBEEF);

        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.protocolFeeRecipient = payable(freshPfr);
        p.protocolFee = 0;

        vm.prank(alice);
        _report(p, 1e18, 2000e18, false, false);

        // No dust applied since protocolFee == 0 means fees won't ever route here
        assertEq(oracle.tokenHolder(freshPfr, address(token1)), 0, "PFR token1 uninit");
        assertEq(oracle.tokenHolder(freshPfr, address(token2)), 0, "PFR token2 uninit");
    }

    function testReport_NoDustWhenPfrIsZeroAddress() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.protocolFeeRecipient = payable(address(0));

        vm.prank(alice);
        _report(p, 1e18, 2000e18, false, false);

        // address(0) is intentionally skipped (the "gas-opt burn" pattern)
        assertEq(oracle.tokenHolder(address(0), address(token1)), 0, "address(0) token1 uninit");
        assertEq(oracle.tokenHolder(address(0), address(token2)), 0, "address(0) token2 uninit");
    }
}

/// @notice Contract with no `receive()` / `fallback()` — ETH `.call{value:}` always reverts.
contract EthRejecter {
    // intentionally empty
}

/// @notice Minimal ERC20 that reverts on transfer() to anyone except address(this) deposits.
///         Lets oracle.deposit pull tokens in (via transferFrom), then a subsequent
///         pushOrCredit.transfer() fails — exercising the credit-fallback path.
contract RejectingErc20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name = "Rejecter";
    string public symbol = "REJ";
    uint8 public decimals = 18;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        // Allow inbound transfers (e.g. oracle.deposit pulling from someone)
        require(balanceOf[from] >= amt, "bal");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amt, "allowance");
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    // Always reverts — used to trigger pushOrCredit's fallback path.
    function transfer(address, uint256) external pure returns (bool) {
        revert("transfer rejected");
    }
}
