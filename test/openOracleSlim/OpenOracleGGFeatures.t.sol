// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

// Feature tests for OpenOracleSlim:
//   - Internal balance funding (initial report, dispute) with hybrid coverage
//   - Delegated funding via approveInternal
//   - Self-dispute netting (token1 swap, token2 swap with both directions)
//   - Timing bounds
//   - Dust sentinel
//   - Withdraw / deposit / approveInternal
contract OpenOracleGGFeaturesTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
    }

    // -------------------------------------------------------------------------
    // Internal balance funding for initial report
    // -------------------------------------------------------------------------

    // bob pre-deposits and pre-dusts, then reports using internal balance.
    // tokens come from internal balance, not from external transferFrom.
    function testInitialReport_FundedByInternalBalance() public {
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));

        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 5000e18, bob);

        assertEq(_heldTokens(bob, address(token1)), 1 + 5e18, "bob token1 internal");
        assertEq(_heldTokens(bob, address(token2)), 1 + 5000e18, "bob token2 internal");

        uint256 bobExt1Before = token1.balanceOf(bob);
        uint256 bobExt2Before = token2.balanceOf(bob);

        vm.prank(bob);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, bob, true, true);
        ctx; // silence unused warning

        // External balances unchanged: funding came from internal balance.
        assertEq(token1.balanceOf(bob), bobExt1Before, "bob external token1 unchanged");
        assertEq(token2.balanceOf(bob), bobExt2Before, "bob external token2 unchanged");

        // Internal balances reduced by the report amounts.
        assertEq(_heldTokens(bob, address(token1)), 1 + 5e18 - 1e18, "bob token1 internal decremented");
        assertEq(_heldTokens(bob, address(token2)), 1 + 5000e18 - 2000e18, "bob token2 internal decremented");
    }

    // bob has insufficient internal; tib=true does HYBRID coverage in OpenOracleSlim:
    // uses what's available internally, pulls the rest externally.
    function testInitialReport_HybridCoverageWhenInternalInsufficient() public {
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));

        // Only 0.5 token1 internal — not enough for 1e18 report.
        vm.prank(bob);
        oracle.deposit(address(token1), 0.5e18, bob);
        // Token2 has plenty.
        vm.prank(bob);
        oracle.deposit(address(token2), 5000e18, bob);

        uint256 bobExt1Before = token1.balanceOf(bob);
        uint256 bobExt2Before = token2.balanceOf(bob);

        vm.prank(bob);
        _report(_defaultParams(), 1e18, 2000e18, bob, true, true);

        // token1: 0.5 from internal (now sentinel), 0.5 from external.
        assertEq(token1.balanceOf(bob), bobExt1Before - 0.5e18, "token1 hybrid: 0.5 external");
        assertEq(_heldTokens(bob, address(token1)), 1, "token1 internal drained to sentinel");

        // token2: sufficient internal -> spent from internal; external unchanged.
        assertEq(token2.balanceOf(bob), bobExt2Before, "token2 external unchanged");
        assertEq(_heldTokens(bob, address(token2)), 1 + 5000e18 - 2000e18, "token2 internal decremented");
    }

    // bob authorizes alice via approveInternal; alice reports on bob's behalf, drawing from bob's internal balance.
    function testInitialReport_DelegatedFundingViaApproveInternal() public {
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 5000e18, bob);

        // bob authorizes alice to spend his internal balance.
        vm.prank(bob);
        oracle.approveInternal(alice, address(token1), 1e18);
        vm.prank(bob);
        oracle.approveInternal(alice, address(token2), 2000e18);

        uint256 aliceExt1Before = token1.balanceOf(alice);
        uint256 bobExt1Before = token1.balanceOf(bob);

        // alice (msg.sender) calls report with reporter=bob.
        vm.prank(alice);
        _report(_defaultParams(), 1e18, 2000e18, bob, true, true);

        // Neither alice nor bob loses tokens externally.
        assertEq(token1.balanceOf(alice), aliceExt1Before, "alice external unchanged");
        assertEq(token1.balanceOf(bob), bobExt1Before, "bob external unchanged");

        // bob's internal balance decreased.
        assertEq(_heldTokens(bob, address(token1)), 1 + 5e18 - 1e18, "bob internal token1 spent");

        // Allowance fully consumed.
        assertEq(oracle.internalAllowance(bob, alice, address(token1)), 0, "alice's allowance consumed");
        assertEq(oracle.internalAllowance(bob, alice, address(token2)), 0, "alice's t2 allowance consumed");
    }

    // approveInternal with type(uint256).max: allowance not decremented.
    function testApproveInternal_InfiniteAllowance_NotDecremented() public {
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 5000e18, bob);

        vm.prank(bob);
        oracle.approveInternal(alice, address(token1), type(uint256).max);
        vm.prank(bob);
        oracle.approveInternal(alice, address(token2), type(uint256).max);

        vm.prank(alice);
        _report(_defaultParams(), 1e18, 2000e18, bob, true, true);

        assertEq(_heldTokens(bob, address(token1)), 1 + 5e18 - 1e18, "internal spent");
        assertEq(
            oracle.internalAllowance(bob, alice, address(token1)),
            type(uint256).max,
            "infinite allowance preserved"
        );
    }

    // Insufficient allowance -> hybrid: spend allowance from internal, pull rest externally from msg.sender.
    function testInitialReport_RevertsWhenDelegatedAllowanceInsufficient() public {
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 5000e18, bob);

        // Approve alice for less than the report amount.
        vm.prank(bob);
        oracle.approveInternal(alice, address(token1), 0.5e18);

        // Strict delegation: tib=true with delegated owner whose internal balance + allowance is short
        // reverts instead of silently falling back to msg.sender's external balance.
        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientInternalBalance.selector);
        _report(_defaultParams(), 1e18, 2000e18, bob, true, false);
    }

    function testDispute_RevertsWhenDelegatedAllowanceInsufficient() public {
        // bob reports first (self-funded)
        vm.prank(bob);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, false, false);

        // Charlie pre-funds his own balance but doesn't authorize alice for enough
        vm.prank(charlie);
        oracle.dust(address(token1), address(token2));
        vm.prank(charlie);
        oracle.deposit(address(token1), 5e18, charlie);
        vm.prank(charlie);
        oracle.deposit(address(token2), 5000e18, charlie);
        vm.prank(charlie);
        oracle.approveInternal(alice, address(token1), 0.1e18); // way too low

        vm.warp(block.timestamp + 6);

        // alice tries to dispute on charlie's behalf with tib=true. token1 dispute needs
        // newAmount1 + oldAmount1 + fee + protocolFee ≈ 2.1e18 of token1.
        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientInternalBalance.selector);
        _dispute(ctx, address(token1), 1.1e18, 2100e18, charlie, true, true, 0);
    }

    function testInitialReport_RevertsWhenDelegatedToken2AllowanceShort() public {
        // Mirror of the token1 case but on token2 — confirms both _tryInternalBalanceFull calls
        // enforce the strict-delegation check.
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 5000e18, bob);

        // Full allowance for token1, insufficient for token2.
        vm.prank(bob);
        oracle.approveInternal(alice, address(token1), type(uint256).max);
        vm.prank(bob);
        oracle.approveInternal(alice, address(token2), 100e18); // need 2000e18

        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientInternalBalance.selector);
        _report(_defaultParams(), 1e18, 2000e18, bob, true, true);
    }

    // -------------------------------------------------------------------------
    // Internal balance funding for disputes
    // -------------------------------------------------------------------------

    // Helper: bob creates+reports.
    function _bobReports() internal returns (ReportContext memory ctx) {
        vm.prank(bob);
        ctx = _report(_defaultParams(), 1e18, 2000e18, bob, false, false);
    }

    function testDispute_FundedByInternalBalance() public {
        ReportContext memory ctx = _bobReports();

        // Charlie pre-dusts and pre-funds.
        vm.prank(charlie);
        oracle.dust(address(token1), address(token2));
        vm.prank(charlie);
        oracle.deposit(address(token1), 5e18, charlie);
        vm.prank(charlie);
        oracle.deposit(address(token2), 5000e18, charlie);

        vm.warp(block.timestamp + 6);

        uint256 charlieExt1Before = token1.balanceOf(charlie);
        uint256 internalT1Before = _heldTokens(charlie, address(token1));

        // Charlie disputes (token1 swap), funded internally.
        vm.prank(charlie);
        _dispute(ctx, address(token1), 1.1e18, 2100e18, true, true);

        // External token1 unchanged.
        assertEq(token1.balanceOf(charlie), charlieExt1Before, "charlie external token1 unchanged");

        // Internal token1 decremented by (newA1 + oldA1 + fee + protocolFee).
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protoFee = (1e18 * 1000) / 1e7;
        uint256 expectedSpend = 1.1e18 + 1e18 + fee + protoFee;
        assertEq(
            _heldTokens(charlie, address(token1)),
            internalT1Before - expectedSpend,
            "charlie internal decremented"
        );
    }

    function testDispute_DelegatedFundingViaApproveInternal() public {
        ReportContext memory ctx = _bobReports();

        vm.prank(charlie);
        oracle.dust(address(token1), address(token2));
        vm.prank(charlie);
        oracle.deposit(address(token1), 5e18, charlie);
        vm.prank(charlie);
        oracle.deposit(address(token2), 5000e18, charlie);

        // Charlie authorizes alice to spend his internal balance.
        vm.prank(charlie);
        oracle.approveInternal(alice, address(token1), type(uint256).max);
        vm.prank(charlie);
        oracle.approveInternal(alice, address(token2), type(uint256).max);

        vm.warp(block.timestamp + 6);

        // Alice (msg.sender) disputes with disputer=charlie.
        vm.prank(alice);
        _dispute(ctx, address(token1), 1.1e18, 2100e18, charlie, true, true, 0);

        // Charlie's internal balance decremented.
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protoFee = (1e18 * 1000) / 1e7;
        uint256 expectedSpend = 1.1e18 + 1e18 + fee + protoFee;
        assertEq(
            _heldTokens(charlie, address(token1)),
            1 + 5e18 - expectedSpend,
            "charlie internal token1 spent"
        );
    }

    function testDispute_HybridWhenInternalInsufficient() public {
        ReportContext memory ctx = _bobReports();

        // Charlie has tib enabled but only 0.5 token1 internal — needs ~2.104.
        vm.prank(charlie);
        oracle.dust(address(token1), address(token2));
        vm.prank(charlie);
        oracle.deposit(address(token1), 0.5e18, charlie);

        vm.warp(block.timestamp + 6);

        uint256 charlieExt1Before = token1.balanceOf(charlie);

        vm.prank(charlie);
        _dispute(ctx, address(token1), 1.1e18, 2100e18, true, false);

        // Hybrid: 0.5 from internal, rest from external.
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protoFee = (1e18 * 1000) / 1e7;
        uint256 totalSpend = 1.1e18 + 1e18 + fee + protoFee;
        uint256 expectedExternalSpend = totalSpend - 0.5e18;
        assertEq(
            token1.balanceOf(charlie),
            charlieExt1Before - expectedExternalSpend,
            "charlie paid hybrid"
        );
        assertEq(_heldTokens(charlie, address(token1)), 1, "charlie internal drained to sentinel");
    }

    // -------------------------------------------------------------------------
    // Self-dispute netting
    // -------------------------------------------------------------------------

    // Bob is reporter and disputer. tokenToSwap = token1.
    // Expected: bob pays only (newA1 - oldA1 + protocolFee), keeps fee.
    function testSelfDispute_Token1_Netting() public {
        ReportContext memory ctx = _bobReports();

        vm.warp(block.timestamp + 6);

        uint256 bobExt1Before = token1.balanceOf(bob);
        uint256 bobExt2Before = token2.balanceOf(bob);
        uint256 bobInternal1Before = _heldTokens(bob, address(token1));
        uint256 bobInternal2Before = _heldTokens(bob, address(token2));

        vm.prank(bob);
        _dispute(ctx, address(token1), 1.1e18, 1900e18, false, false);

        uint256 protoFee = (1e18 * 1000) / 1e7;
        // Self-dispute: bob pays only newA1 - oldA1 + protocolFee on token1.
        assertEq(
            token1.balanceOf(bob),
            bobExt1Before - (0.1e18 + protoFee),
            "bob token1 ext: only delta + protocolFee"
        );

        // bob's internal token1 NOT credited the standard 2*oldA1 + fee (only on non-self path).
        assertEq(_heldTokens(bob, address(token1)), bobInternal1Before, "bob internal token1 unchanged");

        // token2: newA2 < oldA2 so net2Receive = 100e18 credited internally.
        assertEq(token2.balanceOf(bob), bobExt2Before, "bob token2 ext unchanged");
        assertEq(
            _heldTokens(bob, address(token2)),
            bobInternal2Before + 100e18,
            "bob internal token2 += refund"
        );

        // Protocol fee credited.
        assertEq(_heldTokens(protocolFeeRecipient, address(token1)), 1 + protoFee, "protocol fee accrued");
    }

    // tokenToSwap = token2. Self-dispute, with a price move that requires bob to ADD token2.
    function testSelfDispute_Token2_Netting_PaysExternal() public {
        ReportContext memory ctx = _bobReports();
        vm.warp(block.timestamp + 6);

        uint256 bobExt2Before = token2.balanceOf(bob);
        uint256 bobInternal2Before = _heldTokens(bob, address(token2));

        vm.prank(bob);
        _dispute(ctx, address(token2), 1.1e18, 2100e18, false, false);

        uint256 protoFee = (2000e18 * 1000) / 1e7; // 2e18
        uint256 token2Needed = 2100e18 + protoFee;
        uint256 token2ExternalPay = token2Needed - 2000e18;

        assertEq(
            token2.balanceOf(bob),
            bobExt2Before - token2ExternalPay,
            "bob paid token2Needed - oldA2"
        );
        assertEq(_heldTokens(bob, address(token2)), bobInternal2Before, "internal token2 unchanged");
        assertEq(_heldTokens(protocolFeeRecipient, address(token2)), 1 + protoFee, "protocol fee in token2");
    }

    // tokenToSwap = token2. Self-dispute where token2Needed < oldA2 -> bob receives refund credit.
    function testSelfDispute_Token2_Netting_ReceivesRefund() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.protocolFee = 0;
        p.feePercentage = 0;

        vm.prank(bob);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, bob, false, false);

        vm.warp(block.timestamp + 6);

        // newA2 = 1500. token2Needed = 1500 + 0 = 1500 < 2000.
        // Refund = 2000 - 1500 = 500e18 credited internally.
        uint256 bobInternal2Before = _heldTokens(bob, address(token2));

        vm.prank(bob);
        _dispute(ctx, address(token2), 1.1e18, 1500e18, false, false);

        assertEq(_heldTokens(bob, address(token2)), bobInternal2Before + 500e18, "refund credited");
    }

    // Self-dispute requires BOTH disputer == previousReporter AND msg.sender == previousReporter.
    // Charlie calls dispute with disputer=bob (= previousReporter); msg.sender (charlie) != bob.
    // -> Non-self path applies.
    function testSelfDispute_OnlyWhenBothConditions() public {
        ReportContext memory ctx = _bobReports();
        vm.warp(block.timestamp + 6);

        uint256 bobInternal1Before = _heldTokens(bob, address(token1));

        // charlie (msg.sender) disputes with disputer=bob. Not self-dispute.
        vm.prank(charlie);
        _dispute(ctx, address(token1), 1.1e18, 2100e18, bob, false, false, 0);

        // Non-self path: previousReporter (bob) credited 2*oldA1 + fee internally.
        uint256 fee = (1e18 * 3000) / 1e7;
        assertEq(
            _heldTokens(bob, address(token1)),
            bobInternal1Before + 2e18 + fee,
            "bob credited as previousReporter (non-self path)"
        );
    }

    // Self-dispute funded entirely from internal balance.
    function testSelfDispute_Token1_FundedByInternalBalance() public {
        // Pre-fund bob's internal balance.
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 5000e18, bob);

        // Bob reports with tib=true so the initial 1e18 + 2000e18 also come internally.
        vm.prank(bob);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, bob, true, true);

        uint256 bobInternal1 = _heldTokens(bob, address(token1));
        uint256 bobInternal2 = _heldTokens(bob, address(token2));
        uint256 bobExt1Before = token1.balanceOf(bob);
        uint256 bobExt2Before = token2.balanceOf(bob);

        vm.warp(block.timestamp + 6);

        // Self-dispute, token1 swap, newA2 < oldA2.
        vm.prank(bob);
        _dispute(ctx, address(token1), 1.1e18, 1900e18, true, true);

        uint256 protoFee = (1e18 * 1000) / 1e7;

        // Externals unchanged — internal balance covered everything.
        assertEq(token1.balanceOf(bob), bobExt1Before, "token1 ext unchanged");
        assertEq(token2.balanceOf(bob), bobExt2Before, "token2 ext unchanged");

        // token1 internal: spent only delta + protocolFee on the self-dispute path.
        assertEq(
            _heldTokens(bob, address(token1)),
            bobInternal1 - (0.1e18 + protoFee),
            "token1 internal: -delta -protoFee"
        );

        // token2 internal: refunded (oldA2 - newA2 = 100e18) on top.
        assertEq(_heldTokens(bob, address(token2)), bobInternal2 + 100e18, "token2 internal: += refund");

        // Protocol fee credited.
        assertEq(_heldTokens(protocolFeeRecipient, address(token1)), 1 + protoFee, "fee credited");
    }

    // Delegated dispute with EXACT finite allowance: after the call, allowance is 0.
    function testDispute_DelegatedFiniteAllowance_DecrementsToZero() public {
        ReportContext memory ctx = _bobReports();

        vm.prank(charlie);
        oracle.dust(address(token1), address(token2));
        vm.prank(charlie);
        oracle.deposit(address(token1), 5e18, charlie);
        vm.prank(charlie);
        oracle.deposit(address(token2), 5000e18, charlie);

        // Computed dispute spend (token1 swap):
        //   token1 = newA1 + oldA1 + fee + protocolFee = 1.1e18 + 1e18 + 3e15 + 1e15 = 2.104e18
        //   token2 = netContribution = newA2 - oldA2 = 100e18
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protoFee = (1e18 * 1000) / 1e7;
        uint256 expectedToken1Spend = 1.1e18 + 1e18 + fee + protoFee;
        uint256 expectedToken2Spend = 100e18;

        vm.prank(charlie);
        oracle.approveInternal(alice, address(token1), expectedToken1Spend);
        vm.prank(charlie);
        oracle.approveInternal(alice, address(token2), expectedToken2Spend);

        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        _dispute(ctx, address(token1), 1.1e18, 2100e18, charlie, true, true, 0);

        // Charlie's internal balances spent exactly.
        assertEq(_heldTokens(charlie, address(token1)), 1 + 5e18 - expectedToken1Spend, "charlie t1 spent");
        assertEq(_heldTokens(charlie, address(token2)), 1 + 5000e18 - expectedToken2Spend, "charlie t2 spent");

        // Allowances fully consumed.
        assertEq(oracle.internalAllowance(charlie, alice, address(token1)), 0, "t1 allowance consumed");
        assertEq(oracle.internalAllowance(charlie, alice, address(token2)), 0, "t2 allowance consumed");
    }

    // -------------------------------------------------------------------------
    // Timing bounds
    // -------------------------------------------------------------------------

    function testTimingBounds_AcceptsWithinTolerance() public {
        Slim.TimingBoundaries memory timing = Slim.TimingBoundaries({
            blockNumber: block.number,
            blockNumberBound: 5,
            blockTimestamp: block.timestamp,
            blockTimestampBound: 60
        });

        CompatTypes.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, timing);
    }

    function testTimingBounds_RejectsStaleTimestamp() public {
        Slim.TimingBoundaries memory timing = Slim.TimingBoundaries({
            blockNumber: block.number,
            blockNumberBound: 5,
            blockTimestamp: block.timestamp,
            blockTimestampBound: 60
        });

        vm.warp(block.timestamp + 200); // 200s elapsed, bound is 60.

        CompatTypes.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidTiming.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, timing);
    }

    function testTimingBounds_ZeroSkipsValidation() public {
        // blockTimestamp == 0 is the sentinel: skip validation.
        Slim.TimingBoundaries memory timing = Slim.TimingBoundaries({
            blockNumber: 99999,
            blockNumberBound: 0,
            blockTimestamp: 0, // sentinel
            blockTimestampBound: 0
        });

        CompatTypes.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, timing);
    }

    function testTimingBounds_OnDispute() public {
        ReportContext memory ctx = _bobReports();
        vm.warp(block.timestamp + 6);

        Slim.TimingBoundaries memory timing = Slim.TimingBoundaries({
            blockNumber: block.number,
            blockNumberBound: 5,
            blockTimestamp: block.timestamp,
            blockTimestampBound: 60
        });

        vm.warp(block.timestamp + 200);

        vm.prank(charlie);
        vm.expectRevert(Errors.InvalidTiming.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, charlie, false, false, ctx.game, ctx.helper, timing
        );
    }

    // -------------------------------------------------------------------------
    // Dust sentinel
    // -------------------------------------------------------------------------

    function testDust_SeedsSentinelOnFirstCall() public {
        // Before any interaction, slot is zero.
        assertEq(_heldTokens(bob, address(token1)), 0);
        assertEq(_heldTokens(bob, address(token2)), 0);

        uint256 b1 = token1.balanceOf(bob);
        uint256 b2 = token2.balanceOf(bob);

        vm.prank(bob);
        oracle.dust(address(token1), address(token2));

        // Virtual sentinel: NO tokens pulled. Storage slots set to 1 only.
        assertEq(token1.balanceOf(bob), b1, "no token1 pulled");
        assertEq(token2.balanceOf(bob), b2, "no token2 pulled");
        assertEq(_heldTokens(bob, address(token1)), 1, "sentinel seeded");
        assertEq(_heldTokens(bob, address(token2)), 1, "sentinel seeded");

        // Subsequent calls don't change anything (dust short-circuits if slot != 0).
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        assertEq(token1.balanceOf(bob), b1, "still no pull");
        assertEq(_heldTokens(bob, address(token1)), 1, "still 1");
    }

    function testDust_CannotWithdrawBelowSentinel() public {
        vm.prank(bob);
        oracle.deposit(address(token1), 10e18, bob);
        // deposit seeds the virtual sentinel before adding the deposit.
        assertEq(_heldTokens(bob, address(token1)), 1 + 10e18);

        uint256 b = token1.balanceOf(bob);

        vm.prank(bob);
        oracle.withdraw(address(token1), type(uint256).max);
        // Withdraw leaves 1 sentinel; bob recovers the full deposit.
        assertEq(token1.balanceOf(bob), b + 10e18, "full deposit withdrawn");
        assertEq(_heldTokens(bob, address(token1)), 1, "1 sentinel left");

        // Second withdrawal: balance == 1 -> no-op.
        b = token1.balanceOf(bob);
        vm.prank(bob);
        oracle.withdraw(address(token1), type(uint256).max);
        assertEq(token1.balanceOf(bob), b, "no further withdrawal");
        assertEq(_heldTokens(bob, address(token1)), 1, "sentinel still 1");
    }

    function testDust_InternalSpendCannotGoBelowSentinel() public {
        // bob has internal balance of exactly 1 (the sentinel) — cannot spend it.
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        assertEq(_heldTokens(bob, address(token1)), 1);

        // tib1=true, but internal balance is only the sentinel; falls back to external pull.
        uint256 bobExt1Before = token1.balanceOf(bob);

        vm.prank(bob);
        _report(_defaultParams(), 1e18, 2000e18, bob, true, false);

        // External pulled 1e18 (sentinel was preserved).
        assertEq(token1.balanceOf(bob), bobExt1Before - 1e18, "external pull when only sentinel");
        assertEq(_heldTokens(bob, address(token1)), 1, "sentinel preserved");
    }

    function testWithdrawEth_LeavesSentinel() public {
        vm.deal(bob, 5 ether);
        vm.prank(bob);
        oracle.deposit{value: 1 ether}(address(0), 1 ether, bob);
        // deposit seeds the virtual sentinel.
        assertEq(oracle.tokenHolder(bob, address(0)), 1 + 1 ether);

        uint256 bobEthBefore = bob.balance;
        vm.prank(bob);
        uint256 amt = oracle.withdraw(address(0), type(uint256).max);
        assertEq(amt, 1 ether, "withdrew full deposit (sentinel virtual)");
        assertEq(bob.balance, bobEthBefore + 1 ether, "balance reflects full deposit");
        assertEq(oracle.tokenHolder(bob, address(0)), 1, "1 wei sentinel left");

        // Second call is a no-op.
        vm.prank(bob);
        amt = oracle.withdraw(address(0), type(uint256).max);
        assertEq(amt, 0, "no further withdrawal");
    }

    // -------------------------------------------------------------------------
    // deposit (any beneficiary)
    // -------------------------------------------------------------------------

    function testDeposit_CreditsBeneficiary() public {
        // charlie's slot is 0; deposit seeds sentinel (1) then adds amount.
        assertEq(_heldTokens(charlie, address(token1)), 0);

        vm.prank(alice);
        oracle.deposit(address(token1), 5e18, charlie);

        assertEq(_heldTokens(charlie, address(token1)), 1 + 5e18, "sentinel + deposit");
    }

    function testDepositETH_CreditsBeneficiary() public {
        // charlie's slot is 0; ETH deposit seeds sentinel then adds amount.
        assertEq(oracle.tokenHolder(charlie, address(0)), 0);

        vm.prank(alice);
        oracle.deposit{value: 0.5 ether}(address(0), 0.5 ether, charlie);

        assertEq(oracle.tokenHolder(charlie, address(0)), 1 + 0.5 ether, "sentinel + deposit");
    }

    function testDeposit_RevertsZeroBeneficiary() public {
        vm.prank(alice);
        vm.expectRevert(Errors.AddressCannotBeZero.selector);
        oracle.deposit(address(token1), 5e18, address(0));

        vm.prank(alice);
        vm.expectRevert(Errors.AddressCannotBeZero.selector);
        oracle.deposit{value: 1 wei}(address(0), 1, address(0));
    }

    function testApproveInternal_RevertsZeroSpender() public {
        vm.prank(bob);
        vm.expectRevert(Errors.AddressCannotBeZero.selector);
        oracle.approveInternal(address(0), address(token1), 1);
    }
}
