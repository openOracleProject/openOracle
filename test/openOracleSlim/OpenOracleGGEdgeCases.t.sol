// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

// Edge-case and regression coverage for OpenOracleSlim:
//   - reversed-pair sentinel safety (dust(t2, t1) doesn't reset existing balances)
//   - tampered-preimage reverts on dispute and settle
//   - stale-preimage reverts on settle
//   - protocolFeeRecipient == address(0) (intended burn)
//   - block-number-only timing rejection
//   - timeType=false (block-clock) lifecycle
contract OpenOracleGGEdgeCasesTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
    }

    // =========================================================================
    // Reversed-pair sentinel safety
    // =========================================================================

    // If tokenHolder[user][token1] is already > 1 from a prior interaction,
    // calling dust(token2, token1) (reversed pair) must NOT clobber that balance.
    // The dust seed is conditional on slot == 0.
    function testReversedPairDust_DoesNotResetExistingBalance() public {
        // bob deposits 5 token1 and 7 token2; both slots seeded by deposit().
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 7e18, bob);

        uint256 t1Before = _heldTokens(bob, address(token1));
        uint256 t2Before = _heldTokens(bob, address(token2));
        assertEq(t1Before, 1 + 5e18, "token1 sentinel + deposit");
        assertEq(t2Before, 1 + 7e18, "token2 sentinel + deposit");

        // Reversed-pair dust call.
        vm.prank(bob);
        oracle.dust(address(token2), address(token1));

        // Balances must be unchanged — _dust only seeds slots that are 0.
        assertEq(_heldTokens(bob, address(token1)), t1Before, "token1 unchanged");
        assertEq(_heldTokens(bob, address(token2)), t2Before, "token2 unchanged");

        // Forward-pair dust call: also a no-op (still both nonzero).
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        assertEq(_heldTokens(bob, address(token1)), t1Before, "token1 still unchanged");
        assertEq(_heldTokens(bob, address(token2)), t2Before, "token2 still unchanged");
    }

    // =========================================================================
    // Calldata preimage mismatch on dispute and settle
    // =========================================================================

    function testDispute_TamperedPreimage_Reverts() public {
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, false, false);

        vm.warp(block.timestamp + 6);

        // Tamper a hashed field.
        Slim.OracleGame memory tampered = ctx.game;
        tampered.escalationHalt = 99e18;

        vm.prank(charlie);
        vm.expectRevert(Errors.InvalidStateHash.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, charlie, false, false, tampered, ctx.helper, _emptyTiming()
        );
    }

    function testSettle_TamperedPreimage_Reverts() public {
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, false, false);

        vm.warp(block.timestamp + 301);

        // Tamper helper.creator — it commits to the hash.
        Slim.PreimageHelper memory tamperedHelper = ctx.helper;
        tamperedHelper.creator = charlie;

        vm.prank(charlie);
        vm.expectRevert(Errors.InvalidStateHash.selector);
        oracle.settle(ctx.reportId, ctx.game, tamperedHelper);
    }

    // Stale preimage — a preimage from an earlier state must fail because the
    // stored hash has rolled forward.
    function testSettle_StalePreimage_Reverts() public {
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, false, false);

        // Save the post-report game (will become stale after dispute).
        // Deep-copy via abi encode/decode to avoid Solidity's memory aliasing.
        Slim.OracleGame memory staleGame = abi.decode(abi.encode(ctx.game), (Slim.OracleGame));

        vm.warp(block.timestamp + 6);

        // Dispute advances the on-chain stateHash.
        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, false, false);

        vm.warp(block.timestamp + 301);

        // Try to settle using the stale (pre-dispute) game preimage.
        vm.prank(charlie);
        vm.expectRevert(Errors.InvalidStateHash.selector);
        oracle.settle(ctx.reportId, staleGame, ctx.helper);
    }

    // =========================================================================
    // protocolFeeRecipient == address(0) (intended burn)
    // =========================================================================

    // Passing address(0) leaves oracle.protocolFeeRecipient as the zero address.
    // Protocol fees are credited to tokenHolder[address(0)][token], where they
    // are effectively burned (no one can prank as address(0) and call withdraw).
    // Dispute must NOT revert in this case.
    function testProtocolFeeRecipient_ZeroAddress_BurnsFees() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.protocolFeeRecipient = address(0);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, false, false);

        vm.warp(block.timestamp + 6);

        vm.prank(charlie);
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, false, false);

        // Slim's "burn" is implemented by skipping the credit entirely (no SSTORE).
        // The protocolFee tokens remain in oracle's actual ERC20 balance but no slot
        // tracks them — nobody can claim them, achieving the burn semantically without
        // the storage write.
        assertEq(oracle.tokenHolder(address(0), address(token1)), 0, "no credit at address(0)");

        // Charlie (disputer) only has the dust sentinel for token1.
        assertEq(oracle.tokenHolder(charlie, address(token1)), 1, "charlie only sentinel");
        // Alice (previous reporter) got 2*oldA1 + fee, no protocol-fee credit.
        uint256 reporterFeeAmount = (1e18 * 3000) / 1e7;
        assertEq(
            oracle.tokenHolder(alice, address(token1)),
            1 + 2e18 + reporterFeeAmount,
            "alice only previousReporter credit, no protocol fee"
        );
    }

    // =========================================================================
    // Block-number-only timing rejection
    // =========================================================================

    // Even with a perfect block.timestamp match, a stale block.number must
    // cause _validateTiming to revert. Defends against regressions to the
    // block-clock branch of the validator.
    function testTimingBounds_RejectsStaleBlockNumber() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();

        // Advance block.number a lot, but keep block.timestamp identical.
        vm.roll(block.number + 1000);

        Slim.TimingBoundaries memory timing = Slim.TimingBoundaries({
            blockNumber: block.number - 1000, // stale
            blockNumberBound: 5,
            blockTimestamp: block.timestamp,
            blockTimestampBound: 60
        });

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidTiming.selector);
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, timing);
    }

    // =========================================================================
    // timeType=false (block-clock) lifecycle
    // =========================================================================

    // Lifecycle with block-clock semantics: dispute delay and settlement time
    // are measured in blocks. Asserts the block-clock branch of the
    // dispute-too-early / settle-too-early checks works.
    function testBlockClockLifecycle() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        // Clear FLAG_TIME_TYPE → block-clock.
        p.flags = p.flags & ~FLAG_TIME_TYPE;
        p.settlementTime = 10; // 10 blocks
        p.disputeDelay = 2; // 2 blocks

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, false, false);

        // Immediate dispute reverts (blocks haven't advanced).
        vm.prank(charlie);
        vm.expectRevert(Errors.DisputeTooEarly.selector);
        oracle.dispute(
            ctx.reportId,
            address(token1),
            1.1e18,
            2100e18,
            charlie,
            false,
            false,
            ctx.game,
            ctx.helper,
            _emptyTiming()
        );

        // Roll past dispute delay.
        vm.roll(block.number + 3);

        vm.prank(charlie);
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, charlie, false, false, 0);

        // Settle attempt before settlement window elapses reverts.
        vm.prank(alice);
        vm.expectRevert(Errors.SettleTooEarly.selector);
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);

        // Roll past settlement window (10 blocks from last dispute).
        vm.roll(block.number + 11);

        vm.prank(alice);
        ctx = _settle(ctx);

        // settlementTimestamp uses block.number for block-clock reports.
        assertEq(uint256(ctx.game.settlementTimestamp), block.number, "settlement uses block.number");

        // currentReporter (charlie, the disputer) credited their final amounts.
        assertEq(_heldTokens(charlie, address(token1)), 1 + 1.1e18, "charlie token1 credited");
        assertEq(_heldTokens(charlie, address(token2)), 1 + 2100e18, "charlie token2 credited");
    }
}
