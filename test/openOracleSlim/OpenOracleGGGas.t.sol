// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";

// Gas snapshot suite for OpenOracleSlim happy paths.
//
// Each test pre-funds / pre-dusts in setUp (and in test bodies), then calls
// `_coolAll()` immediately before the measured op to reset EIP-2929 access
// lists. This simulates a real production tx where slots start cold —
// otherwise consecutive ops in the same forge call would all read warm.
contract OpenOracleGGGasTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        // Pre-warm: dust common pairs for alice and bob.
        vm.prank(alice);
        oracle.dust(address(token1), address(token2));
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));

        // Pre-warm ETH sentinel for alice and bob.
        vm.prank(alice);
        oracle.deposit{value: 1 wei}(ETH_SENTINEL, 1 wei, alice);
        vm.prank(bob);
        oracle.deposit{value: 1 wei}(ETH_SENTINEL, 1 wei, bob);
    }

    // Reset access lists for oracle and token contracts so the next call sees
    // all slots cold (mimicking a fresh tx).
    function _coolAll() internal {
        vm.cool(address(oracle));
        vm.cool(address(token1));
        vm.cool(address(token2));
    }

    // -------------------------------------------------------------------------
    // report (ERC20 pair, no flags)
    // -------------------------------------------------------------------------
    function testGas_Report_Erc20() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        _coolAll();
        vm.prank(alice);
        uint256 g0 = gasleft();
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, false, false, _emptyTiming());
        emit log_named_uint("report (ERC20 pair)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // report (ETH-as-token, ETH from msg.value)
    // -------------------------------------------------------------------------
    function testGas_Report_EthToken1() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.token1Address = ETH_SENTINEL;
        uint128 amount1 = 1 ether;
        uint256 value = uint256(p.settlerReward) + amount1;
        _coolAll();
        vm.prank(alice);
        uint256 g0 = gasleft();
        CompatTypes.reportRaw(oracle, value, p, amount1, 2000e18, alice, false, false, _emptyTiming());
        emit log_named_uint("report (ETH as token1)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // report (funded by internal balance)
    // -------------------------------------------------------------------------
    function testGas_Report_InternalBalance() public {
        // Pre-fund alice's internal token1 + token2.
        vm.prank(alice);
        oracle.deposit(address(token1), 5e18, alice);
        vm.prank(alice);
        oracle.deposit(address(token2), 5000e18, alice);

        CompatTypes.CreateReportParams memory p = _defaultParams();
        _coolAll();
        vm.prank(alice);
        uint256 g0 = gasleft();
        CompatTypes.reportRaw(oracle, p.settlerReward, p, 1e18, 2000e18, alice, true, true, _emptyTiming());
        emit log_named_uint("report (internal balance)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // dispute (token1 swap, ERC20 pair)
    // -------------------------------------------------------------------------
    function testGas_Dispute_Token1() public {
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 6);

        _coolAll();
        vm.prank(bob);
        uint256 g0 = gasleft();
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
        emit log_named_uint("dispute (token1 swap)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // dispute (token2 swap, ERC20 pair)
    // -------------------------------------------------------------------------
    function testGas_Dispute_Token2() public {
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 6);

        _coolAll();
        vm.prank(bob);
        uint256 g0 = gasleft();
        oracle.dispute(
            ctx.reportId, address(token2), 1.1e18, 2100e18, bob, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
        emit log_named_uint("dispute (token2 swap)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // dispute (token1 swap, funded by internal balance, tib=true)
    // -------------------------------------------------------------------------
    function testGas_Dispute_Token1_InternalBalance() public {
        // Alice reports (any setup).
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);

        // Pre-fund bob's internal balance for dispute.
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 5000e18, bob);

        vm.warp(block.timestamp + 6);

        _coolAll();
        vm.prank(bob);
        uint256 g0 = gasleft();
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, bob, true, true, ctx.game, ctx.helper, _emptyTiming()
        );
        emit log_named_uint("dispute (token1 swap, internal balance)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // dispute (token2 swap, funded by internal balance, tib=true)
    // -------------------------------------------------------------------------
    function testGas_Dispute_Token2_InternalBalance() public {
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);

        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 10000e18, bob);

        vm.warp(block.timestamp + 6);

        _coolAll();
        vm.prank(bob);
        uint256 g0 = gasleft();
        oracle.dispute(
            ctx.reportId, address(token2), 1.1e18, 2100e18, bob, true, true, ctx.game, ctx.helper, _emptyTiming()
        );
        emit log_named_uint("dispute (token2 swap, internal balance)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // Self-dispute on token1 (bob is reporter AND disputer), internal balance.
    // The cheapest dispute path: skips the previousReporter credit + only pays
    // the netDelta + protocolFee on the swap side.
    // -------------------------------------------------------------------------
    function testGas_Dispute_SelfDispute_InternalBalance() public {
        // Bob reports (so he's the previousReporter).
        vm.prank(bob);
        oracle.deposit(address(token1), 5e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 5000e18, bob);

        vm.prank(bob);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, bob, true, true);

        vm.warp(block.timestamp + 6);

        _coolAll();
        vm.prank(bob);
        uint256 g0 = gasleft();
        // Self-dispute: bob disputing his own report. newA2 < oldA2 → refund credited.
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 1900e18, bob, true, true, ctx.game, ctx.helper, _emptyTiming()
        );
        emit log_named_uint("dispute (self-dispute, internal balance)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // settle (no flags, ERC20 pair, no callback)
    // -------------------------------------------------------------------------
    function testGas_Settle_NoFlags() public {
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 301);

        _coolAll();
        vm.prank(charlie);
        uint256 g0 = gasleft();
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);
        emit log_named_uint("settle (no flags)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // settle (FLAG_STORE_PRICE)
    // -------------------------------------------------------------------------
    function testGas_Settle_StorePrice() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_STORE_PRICE;
        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 301);

        _coolAll();
        vm.prank(charlie);
        uint256 g0 = gasleft();
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);
        emit log_named_uint("settle (FLAG_STORE_PRICE)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // settle (FLAG_STORE_ALL)
    // -------------------------------------------------------------------------
    function testGas_Settle_StoreAll() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        p.flags |= FLAG_STORE_ALL;
        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 301);

        _coolAll();
        vm.prank(charlie);
        uint256 g0 = gasleft();
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);
        emit log_named_uint("settle (FLAG_STORE_ALL)", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // Full lifecycle (report -> dispute -> settle, ERC20 pair, no flags)
    // External-pull path: tib=false everywhere, alice/bob spend external tokens.
    // -------------------------------------------------------------------------
    function testGas_FullLifecycle_ExternalPulls() public {
        CompatTypes.CreateReportParams memory p = _defaultParams();

        _coolAll();
        vm.prank(alice);
        uint256 g0 = gasleft();
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        uint256 gReport = g0 - gasleft();

        vm.warp(block.timestamp + 6);
        _coolAll();
        vm.prank(bob);
        g0 = gasleft();
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, false, false);
        uint256 gDispute = g0 - gasleft();

        vm.warp(block.timestamp + 301);
        _coolAll();
        vm.prank(charlie);
        g0 = gasleft();
        ctx = _settle(ctx);
        uint256 gSettle = g0 - gasleft();

        emit log_named_uint("ext-lifecycle: report", gReport);
        emit log_named_uint("ext-lifecycle: dispute", gDispute);
        emit log_named_uint("ext-lifecycle: settle", gSettle);
        emit log_named_uint("ext-lifecycle: TOTAL", gReport + gDispute + gSettle);
    }

    // -------------------------------------------------------------------------
    // Full lifecycle, INTERNAL-balance-funded path.
    // Apples-to-apples comparison vs the canonical ContractSizeLimit2 benchmark
    // (which also pre-funds internal balances and uses tib=true).
    // -------------------------------------------------------------------------
    function testGas_FullLifecycle_InternalBalance() public {
        // Pre-fund internal balances for alice (reporter) and bob (disputer).
        // alice: 5 token1, 5000 token2 (covers 1e18 / 2000e18 report).
        // bob: 10 token1, 10000 token2 (covers dispute spending).
        vm.prank(alice);
        oracle.deposit(address(token1), 5e18, alice);
        vm.prank(alice);
        oracle.deposit(address(token2), 5000e18, alice);
        vm.prank(bob);
        oracle.deposit(address(token1), 10e18, bob);
        vm.prank(bob);
        oracle.deposit(address(token2), 10000e18, bob);

        CompatTypes.CreateReportParams memory p = _defaultParams();

        _coolAll();
        vm.prank(alice);
        uint256 g0 = gasleft();
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, true, true);
        uint256 gReport = g0 - gasleft();

        vm.warp(block.timestamp + 6);
        _coolAll();
        vm.prank(bob);
        g0 = gasleft();
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, true, true);
        uint256 gDispute = g0 - gasleft();

        vm.warp(block.timestamp + 301);
        _coolAll();
        vm.prank(charlie);
        g0 = gasleft();
        ctx = _settle(ctx);
        uint256 gSettle = g0 - gasleft();

        emit log_named_uint("int-lifecycle: report", gReport);
        emit log_named_uint("int-lifecycle: dispute", gDispute);
        emit log_named_uint("int-lifecycle: settle", gSettle);
        emit log_named_uint("int-lifecycle: TOTAL", gReport + gDispute + gSettle);
    }
}
