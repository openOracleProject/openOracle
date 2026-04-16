// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/disputeHelper.sol";
import "../../src/interfaces/IOpenOracle.sol";
import "../../src/interfaces/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Separate contract to force balance reads across call boundaries,
///      preventing the via_ir optimizer from caching/reordering balance reads.
contract BalanceReader {
    function read(address who, address weth, address usdc) external view returns (uint256 eth, uint256 w, uint256 u) {
        eth = who.balance;
        w = IERC20(weth).balanceOf(who);
        u = IERC20(usdc).balanceOf(who);
    }
}

/**
 * @title DisputeHelper Fork Tests
 * @notice Fork tests against live Base mainnet state
 */
contract DisputeHelperForkTest is Test {
    // ─── Base mainnet addresses ───────────────────────────────
    address constant ORACLE = 0x95E228EEeCd7292108F873ca0A8D78846D7d2aC1;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    IOpenOracle oracle = IOpenOracle(ORACLE);
    disputeHelper helper;
    BalanceReader reader;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant REPORT_ETH_FEE = 0.001 ether;
    uint256 constant SETTLER_REWARD = 0.0001 ether;

    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork("https://mainnet.base.org");

        // Deploy dispute helper and balance reader
        helper = new disputeHelper(ORACLE, BASE_WETH, UNISWAP_ROUTER);
        reader = new BalanceReader();

        // Clear any contract code at test addresses (they may collide with
        // deployed contracts on the Base fork, causing ETH forwarding issues)
        vm.etch(alice, "");
        vm.etch(bob, "");

        // Fund alice and bob with ETH
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        // Give alice and bob WETH
        vm.prank(alice);
        IWETH(BASE_WETH).deposit{value: 50 ether}();
        vm.prank(bob);
        IWETH(BASE_WETH).deposit{value: 50 ether}();

        // Give alice and bob USDC (deal cheatcode for arbitrary ERC20)
        deal(USDC, alice, 100_000e6); // 100k USDC
        deal(USDC, bob, 100_000e6);
    }

    // ─── Helpers ──────────────────────────────────────────────

    /// @dev Creates a WETH/USDC report instance and returns reportId + stateHash
    function _createWethUsdcReport(
        uint256 exactToken1,
        uint16 multiplier,
        uint24 feePercentage,
        uint24 protocolFee,
        uint48 settlementTime,
        uint24 disputeDelay
    ) internal returns (uint256 reportId, bytes32 stateHash) {
        IOpenOracle.CreateReportParams memory params = IOpenOracle.CreateReportParams({
            exactToken1Report: uint128(exactToken1),
            escalationHalt: type(uint128).max,
            settlerReward: uint96(SETTLER_REWARD),
            token1Address: BASE_WETH,
            settlementTime: settlementTime,
            disputeDelay: disputeDelay,
            protocolFee: protocolFee,
            token2Address: USDC,
            callbackGasLimit: 0,
            feePercentage: feePercentage,
            multiplier: multiplier,
            timeType: true,
            trackDisputes: true,
            callbackContract: address(0),
            callbackSelector: bytes4(0),
            protocolFeeRecipient: alice
        });

        vm.prank(alice);
        reportId = oracle.createReportInstance{value: REPORT_ETH_FEE}(params);
        stateHash = oracle.extraData(reportId).stateHash;
    }

    /// @dev Submits initial report for alice
    function _submitInitialReport(
        uint256 reportId,
        uint256 amount1,
        uint256 amount2,
        bytes32 stateHash
    ) internal {
        vm.startPrank(alice);
        IERC20(BASE_WETH).approve(ORACLE, type(uint256).max);
        IERC20(USDC).approve(ORACLE, type(uint256).max);
        oracle.submitInitialReport(reportId, uint128(amount1), uint128(amount2), stateHash, alice);
        vm.stopPrank();
    }

    /// @dev Builds oracleParams from on-chain state for a given reportId
    function _buildOracleParams(uint256 reportId) internal view returns (disputeHelper.oracleParams memory p) {
        IOpenOracle.ReportMeta memory meta = oracle.reportMeta(reportId);
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        IOpenOracle.extraReportData memory extra = oracle.extraData(reportId);

        p = disputeHelper.oracleParams({
            escalationHalt: meta.escalationHalt,
            fee: meta.fee,
            settlerReward: meta.settlerReward,
            token1: meta.token1,
            settlementTime: meta.settlementTime,
            token2: meta.token2,
            timeType: meta.timeType,
            feePercentage: meta.feePercentage,
            protocolFee: meta.protocolFee,
            multiplier: meta.multiplier,
            disputeDelay: meta.disputeDelay,
            currentAmount1: status.currentAmount1,
            currentAmount2: status.currentAmount2,
            callbackGasLimit: extra.callbackGasLimit,
            protocolFeeRecipient: extra.protocolFeeRecipient,
            trackDisputes: extra.trackDisputes
        });
    }

    /// @dev Reads ETH/WETH/USDC balances via external contract call to prevent
    ///      via_ir optimizer from caching/reordering balance reads across the call
    function _snapshot(address who) internal view returns (uint256 eth, uint256 weth, uint256 usdc) {
        return reader.read(who, BASE_WETH, USDC);
    }

    /// @dev Computes newAmount1 from the oracle's escalation logic
    function _computeNewAmount1(uint256 oldAmount1, uint16 multiplier, uint256 escalationHalt) internal pure returns (uint256) {
        if (escalationHalt > oldAmount1) {
            uint256 expected = (oldAmount1 * multiplier) / 100;
            if (expected > escalationHalt) return escalationHalt;
            return expected;
        }
        return oldAmount1 + 1;
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Happy path — dispute with sufficient tokens (no swap)
    // ═══════════════════════════════════════════════════════════

    function test_happyPath_disputeWithSufficientTokens() public {
        uint256 initAmount1 = 0.01 ether; // 0.01 WETH
        uint256 initAmount2 = 25e6;       // 25 USDC (~$2500/ETH)
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;      // 0.03%
        uint24 protocolFee = 0;
        uint48 settlementTime = 300;
        uint24 disputeDelay = 0;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, multiplier, feePercentage, protocolFee, settlementTime, disputeDelay
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        // Compute dispute amounts
        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier, type(uint256).max);
        // Price should be outside bounds — make newAmount2 reflect a significantly different price
        // newPrice must be outside [lowerBound, upperBound] of oldPrice
        // oldPrice = initAmount1 * 1e18 / initAmount2
        // We'll offer more USDC (lower price for WETH, i.e. WETH is cheaper)
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000; // ~5% cheaper per WETH

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH, // swap token1
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        // Bob disputes — needs: newAmount1 + oldAmount1 + fees in token1, and newAmount2 - oldAmount2 in token2
        uint256 requiredToken1 = newAmount1 + initAmount1 + feePercentage * initAmount1 / 1e7 + protocolFee * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), requiredToken1 + 1 ether); // extra buffer
        IERC20(USDC).approve(address(helper), requiredToken2 + 1000e6);

        helper.disputeReportSafe(
            dispute,
            p,
            requiredToken1,  // batchAmount1 — exact needed
            requiredToken2,   // batchAmount2 — exact needed
            block.timestamp,
            block.number,
            30,   // timestampBound
            10,   // blockNumberBound
            0     // maxSwapInput — no swap needed
        );
        vm.stopPrank();

        // Verify dispute went through
        IOpenOracle.ReportStatus memory newStatus = oracle.reportStatus(reportId);
        assertEq(newStatus.currentAmount1, newAmount1, "newAmount1 mismatch");
        assertEq(newStatus.currentAmount2, newAmount2, "newAmount2 mismatch");

        // Bob should be the current reporter (disputer)
        assertEq(newStatus.currentReporter, bob, "bob should be current reporter");

        // Helper contract should have no leftover tokens
        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper should have no WETH left");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper should have no USDC left");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Dispute with ETH wrapping (send raw ETH for WETH token1)
    // ═══════════════════════════════════════════════════════════

    function test_disputeWithEthWrapping() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;
        uint24 protocolFee = 0;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, multiplier, feePercentage, protocolFee, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 requiredToken1 = newAmount1 + initAmount1 + feePercentage * initAmount1 / 1e7 + protocolFee * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        uint256 bobEthBefore_ = bob.balance;

        vm.startPrank(bob);
        // Send ETH instead of WETH — no WETH approval needed for the ETH portion
        IERC20(USDC).approve(address(helper), requiredToken2 + 1000e6);

        // Send all token1 requirement as raw ETH (batchAmount1 = 0 for WETH, rely on msg.value)
        helper.disputeReportSafe{value: requiredToken1}(
            dispute,
            p,
            0,                // batchAmount1 = 0, using ETH instead
            requiredToken2,
            block.timestamp,
            block.number,
            30,
            10,
            0
        );
        vm.stopPrank();

        // Verify dispute succeeded
        IOpenOracle.ReportStatus memory newStatus = oracle.reportStatus(reportId);
        assertEq(newStatus.currentAmount1, newAmount1, "newAmount1 mismatch");
        assertEq(newStatus.currentReporter, bob, "bob should be reporter");

        // Verify bob's ETH balance: should have spent exactly requiredToken1 worth of ETH
        uint256 bobEthAfter_ = bob.balance;

        // Bob should have gotten ETH refund for any excess (sent requiredToken1, used requiredToken1 → 0 excess)
        assertGe(bobEthAfter_, bobEthBefore_ - requiredToken1, "bob lost more ETH than required");

        // Helper should be clean
        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
        assertEq(address(helper).balance, 0, "helper ETH residual");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Auto-swap — shortfall in token1, surplus in token2
    // ═══════════════════════════════════════════════════════════

    function test_autoSwap_shortfallToken1_surplusToken2() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;
        uint24 protocolFee = 0;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, multiplier, feePercentage, protocolFee, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 requiredToken1 = newAmount1 + initAmount1 + feePercentage * initAmount1 / 1e7 + protocolFee * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        // Provide HALF the required WETH but excess USDC
        uint256 batchAmount1 = requiredToken1 / 2;
        uint256 batchAmount2 = requiredToken2 + 50_000e6; // big surplus of USDC

        uint256 bobWethBefore = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), batchAmount1);
        IERC20(USDC).approve(address(helper), batchAmount2);

        helper.disputeReportSafe(
            dispute,
            p,
            batchAmount1,
            batchAmount2,
            block.timestamp,
            block.number,
            30,
            10,
            50_000e6 // maxSwapInput — allow up to 50k USDC for the swap
        );
        vm.stopPrank();

        // Verify dispute state
        IOpenOracle.ReportStatus memory newStatus = oracle.reportStatus(reportId);
        assertEq(newStatus.currentAmount1, newAmount1, "newAmount1 mismatch");
        assertEq(newStatus.currentReporter, bob, "bob should be reporter");

        // Helper must be clean
        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper USDC residual");

        // User refund: bob sent batchAmount1 WETH + batchAmount2 USDC
        // He should get back surplus minus swap cost
        uint256 bobWethAfter = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcAfter = IERC20(USDC).balanceOf(bob);
        uint256 bobWethSpent = bobWethBefore - bobWethAfter;
        uint256 bobUsdcSpent = bobUsdcBefore - bobUsdcAfter;

        // Bob must not have spent more WETH than he batched
        assertLe(bobWethSpent, batchAmount1, "bob spent more WETH than batched");
        // Bob must not have spent more USDC than he batched
        assertLe(bobUsdcSpent, batchAmount2, "bob spent more USDC than batched");
        // Bob's USDC surplus should have been partially returned (minus swap cost)
        assertGt(bobUsdcAfter, bobUsdcBefore - batchAmount2, "bob didn't get USDC surplus back");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Auto-swap — shortfall in token2, surplus in token1
    // ═══════════════════════════════════════════════════════════

    function test_autoSwap_shortfallToken2_surplusToken1() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;
        uint24 protocolFee = 0;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, multiplier, feePercentage, protocolFee, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        // This time swap token2 (USDC)
        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: USDC, // swap token2
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 requiredToken1 = newAmount1 > initAmount1 ? newAmount1 - initAmount1 : 0;
        uint256 requiredToken2 = newAmount2 + initAmount2 + feePercentage * initAmount2 / 1e7 + protocolFee * initAmount2 / 1e7;

        // Provide excess WETH but HALF the required USDC
        uint256 batchAmount1 = requiredToken1 + 5 ether; // big surplus of WETH
        uint256 batchAmount2 = requiredToken2 / 2;

        uint256 bobWethBefore = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), batchAmount1);
        IERC20(USDC).approve(address(helper), batchAmount2);

        helper.disputeReportSafe(
            dispute,
            p,
            batchAmount1,
            batchAmount2,
            block.timestamp,
            block.number,
            30,
            10,
            5 ether // maxSwapInput — allow up to 5 WETH for the swap
        );
        vm.stopPrank();

        IOpenOracle.ReportStatus memory newStatus = oracle.reportStatus(reportId);
        assertEq(newStatus.currentAmount1, newAmount1, "newAmount1 mismatch");
        assertEq(newStatus.currentReporter, bob, "bob should be reporter");

        // Helper must be clean
        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper USDC residual");

        // User refund assertions
        uint256 bobWethAfter = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcAfter = IERC20(USDC).balanceOf(bob);

        // Bob must not have spent more than he batched
        assertLe(bobWethBefore - bobWethAfter, batchAmount1, "bob spent more WETH than batched");
        assertLe(bobUsdcBefore - bobUsdcAfter, batchAmount2, "bob spent more USDC than batched");
        // Bob's WETH surplus should have been returned (minus swap cost, which may consume entire surplus)
        assertGe(bobWethAfter, bobWethBefore - batchAmount1, "bob lost more WETH than batched");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Revert — stale timestamp
    // ═══════════════════════════════════════════════════════════

    function test_revert_staleTimestamp() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, 133, 3000, 0, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, 133, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * 133 * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        // Warp forward 100 seconds. via_ir optimizer can reorder block.timestamp reads,
        // so compute the stale timestamp AFTER the warp via subtraction.
        vm.warp(block.timestamp + 100);
        uint256 staleTimestamp = block.timestamp - 100;

        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), 10 ether);
        IERC20(USDC).approve(address(helper), 100_000e6);

        try helper.disputeReportSafe(
            dispute,
            p,
            1 ether,
            50_000e6,
            staleTimestamp,   // stale timestamp (100s behind block.timestamp)
            block.number,     // current block (valid)
            5,                // tight bound — 5 seconds (100 > 5, so reverts)
            1000,
            0
        ) {
            fail("should have reverted with stale timestamp");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), disputeHelper.ActionSafetyFailure.selector, "wrong revert reason");
        }
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Revert — param mismatch (validation catches bad RPC)
    // ═══════════════════════════════════════════════════════════

    function test_revert_paramMismatch() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, 133, 3000, 0, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, 133, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * 133 * 105) / 10000;

        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);

        // Tamper with params — simulate bad RPC
        p.multiplier = 200; // wrong!

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), 10 ether);
        IERC20(USDC).approve(address(helper), 100_000e6);

        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "params dont match"));
        helper.disputeReportSafe(
            dispute,
            p,
            1 ether,
            50_000e6,
            block.timestamp,
            block.number,
            30,
            10,
            0
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Revert — token2 is WETH (not supported)
    // ═══════════════════════════════════════════════════════════

    function test_revert_token2IsWeth() public {
        // Create report with token2 = WETH (reversed pair)
        IOpenOracle.CreateReportParams memory params = IOpenOracle.CreateReportParams({
            exactToken1Report: 25e6, // USDC as token1
            escalationHalt: type(uint128).max,
            settlerReward: uint96(SETTLER_REWARD),
            token1Address: USDC,
            settlementTime: 300,
            disputeDelay: 0,
            protocolFee: 0,
            token2Address: BASE_WETH, // WETH as token2!
            callbackGasLimit: 0,
            feePercentage: 3000,
            multiplier: 133,
            timeType: true,
            trackDisputes: false,
            callbackContract: address(0),
            callbackSelector: bytes4(0),
            protocolFeeRecipient: alice
        });

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: REPORT_ETH_FEE}(params);
        bytes32 stateHash = oracle.extraData(reportId).stateHash;

        // Submit initial report
        vm.startPrank(alice);
        IERC20(USDC).approve(ORACLE, type(uint256).max);
        IERC20(BASE_WETH).approve(ORACLE, type(uint256).max);
        oracle.submitInitialReport(reportId, 25e6, 0.01 ether, stateHash, alice);
        vm.stopPrank();

        uint256 newAmount1 = _computeNewAmount1(25e6, 133, type(uint256).max);
        uint256 newAmount2 = (0.01 ether * 133 * 105) / 10000;

        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: USDC,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(USDC).approve(address(helper), type(uint256).max);
        IERC20(BASE_WETH).approve(address(helper), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "no WETH as token2"));
        helper.disputeReportSafe(
            dispute,
            p,
            100_000e6,
            1 ether,
            block.timestamp,
            block.number,
            30,
            10,
            0
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Revert — insufficient total value (both shortfalls)
    // ═══════════════════════════════════════════════════════════

    function test_revert_insufficientTotalValue() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, 133, 3000, 0, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, 133, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * 133 * 105) / 10000;

        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), 1); // tiny amount
        IERC20(USDC).approve(address(helper), 1);       // tiny amount

        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "insufficient total value"));
        helper.disputeReportSafe(
            dispute,
            p,
            1,  // basically nothing
            1,  // basically nothing
            block.timestamp,
            block.number,
            30,
            10,
            0
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Revert — ETH sent but token1 is not WETH
    // ═══════════════════════════════════════════════════════════

    function test_revert_ethSentButToken1NotWeth() public {
        // Create a USDC/DAI-like pair (neither is WETH)
        // We'll use USDC as token1 and a different token as token2
        // For simplicity, use two non-WETH tokens — cbETH as token2
        address cbETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;

        IOpenOracle.CreateReportParams memory params = IOpenOracle.CreateReportParams({
            exactToken1Report: 25e6,
            escalationHalt: type(uint128).max,
            settlerReward: uint96(SETTLER_REWARD),
            token1Address: USDC,     // not WETH
            settlementTime: 300,
            disputeDelay: 0,
            protocolFee: 0,
            token2Address: cbETH,
            callbackGasLimit: 0,
            feePercentage: 3000,
            multiplier: 133,
            timeType: true,
            trackDisputes: false,
            callbackContract: address(0),
            callbackSelector: bytes4(0),
            protocolFeeRecipient: alice
        });

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: REPORT_ETH_FEE}(params);

        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: USDC,
            newAmount1: 1,
            newAmount2: 1,
            amt2Expected: 0,
            stateHash: oracle.extraData(reportId).stateHash
        });

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "no WETH in oracle game"));
        helper.disputeReportSafe{value: 1 ether}(
            dispute,
            p,
            0,
            0,
            block.timestamp,
            block.number,
            30,
            10,
            0
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Settle after dispute — full lifecycle
    // ═══════════════════════════════════════════════════════════

    function test_fullLifecycle_disputeThenSettle() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;
        uint48 settlementTime = 300;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, multiplier, feePercentage, 0, settlementTime, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        // Bob disputes via helper
        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 requiredToken1 = newAmount1 + initAmount1 + feePercentage * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), requiredToken1 + 1 ether);
        IERC20(USDC).approve(address(helper), requiredToken2 + 1000e6);
        helper.disputeReportSafe(
            dispute, p, requiredToken1, requiredToken2,
            block.timestamp, block.number, 30, 10, 0
        );
        vm.stopPrank();

        // Warp past settlement time
        vm.warp(block.timestamp + settlementTime + 1);

        // Anyone can settle
        uint256 bobWethBefore = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);

        vm.prank(alice);
        oracle.settle(reportId);
        (uint256 price, uint256 settlementTs) = oracle.getSettlementData(reportId);

        assertTrue(price > 0, "price should be set");
        assertTrue(settlementTs > 0, "settlement timestamp should be set");

        // Bob (disputer/current reporter) should have received tokens back
        uint256 bobWethAfter = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcAfter = IERC20(USDC).balanceOf(bob);
        assertTrue(bobWethAfter > bobWethBefore, "bob should get WETH back");
        assertTrue(bobUsdcAfter > bobUsdcBefore, "bob should get USDC back");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: Revert — stale block number
    // ═══════════════════════════════════════════════════════════

    function test_revert_staleBlockNumber() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, 133, 3000, 0, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, 133, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * 133 * 105) / 10000;

        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        // Roll forward 100 blocks. Compute stale block AFTER roll to avoid via_ir reorder.
        vm.roll(block.number + 100);
        uint256 staleBlock = block.number - 100;

        // Re-read params after roll
        p = _buildOracleParams(reportId);

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), 10 ether);
        IERC20(USDC).approve(address(helper), 100_000e6);

        try helper.disputeReportSafe(
            dispute,
            p,
            1 ether,
            50_000e6,
            block.timestamp,  // current timestamp (valid)
            staleBlock,       // stale block (100 behind block.number)
            30,               // timestamp bound (valid)
            5,                // tight block bound (100 > 5, so reverts)
            0
        ) {
            fail("should have reverted with stale block number");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), disputeHelper.ActionSafetyFailure.selector, "wrong revert reason");
        }
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  GAP 3: maxSwapInput — "surplus not enough" revert
    // ═══════════════════════════════════════════════════════════

    function test_revert_surplusNotEnough() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, multiplier, feePercentage, 0, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 requiredToken1 = newAmount1 + initAmount1 + feePercentage * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        // Provide HALF token1 and surplus token2, but set maxSwapInput HIGHER than surplus
        uint256 batchAmount1 = requiredToken1 / 2;
        uint256 batchAmount2 = requiredToken2 + 1000e6; // small surplus of 1000 USDC
        uint256 surplus2 = 1000e6;

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), batchAmount1);
        IERC20(USDC).approve(address(helper), batchAmount2);

        // maxSwapInput > surplus2 → "surplus not enough"
        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "surplus not enough"));
        helper.disputeReportSafe(
            dispute,
            p,
            batchAmount1,
            batchAmount2,
            block.timestamp,
            block.number,
            30,
            10,
            surplus2 + 1 // maxSwapInput just above surplus
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  GAP 3: maxSwapInput too tight — Uniswap reverts (slippage)
    // ═══════════════════════════════════════════════════════════

    function test_revert_maxSwapInputTooTight() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, multiplier, feePercentage, 0, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 requiredToken1 = newAmount1 + initAmount1 + feePercentage * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        // Provide HALF token1 and plenty of token2, but maxSwapInput = 1 (impossibly tight)
        uint256 batchAmount1 = requiredToken1 / 2;
        uint256 batchAmount2 = requiredToken2 + 50_000e6;

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), batchAmount1);
        IERC20(USDC).approve(address(helper), batchAmount2);

        // maxSwapInput = 1 wei — surplus2 is large so the helper's own "surplus not enough"
        // check passes, but Uniswap's exactOutputSingle reverts with "STF" (insufficient input)
        // because 1 wei can't cover the required output. This is the correct slippage protection path.
        vm.expectRevert(bytes("STF"));
        helper.disputeReportSafe(
            dispute,
            p,
            batchAmount1,
            batchAmount2,
            block.timestamp,
            block.number,
            30,
            10,
            1 // impossibly tight maxSwapInput
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  GAP 4: Branch-specific revert — "need token2"
    //  shortfall1 > 0 && surplus2 == 0 (no surplus to swap)
    // ═══════════════════════════════════════════════════════════

    function test_revert_needToken2() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, multiplier, feePercentage, 0, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 requiredToken1 = newAmount1 + initAmount1 + feePercentage * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        // Provide HALF the WETH (shortfall1 > 0) and EXACT USDC (surplus2 == 0)
        uint256 batchAmount1 = requiredToken1 / 2;
        uint256 batchAmount2 = requiredToken2; // exact — no surplus

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), batchAmount1);
        IERC20(USDC).approve(address(helper), batchAmount2);

        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "need token2"));
        helper.disputeReportSafe(
            dispute,
            p,
            batchAmount1,
            batchAmount2,
            block.timestamp,
            block.number,
            30,
            10,
            0
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  GAP 4: Branch-specific revert — "need token1"
    //  shortfall2 > 0 && surplus1 == 0 (no surplus to swap)
    // ═══════════════════════════════════════════════════════════

    function test_revert_needToken1() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, multiplier, feePercentage, 0, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        // Token2 swap path: shortfall2 > 0, surplus1 == 0
        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: USDC,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 requiredToken1 = newAmount1 > initAmount1 ? newAmount1 - initAmount1 : 0;
        uint256 requiredToken2 = newAmount2 + initAmount2 + feePercentage * initAmount2 / 1e7;

        // Provide EXACT WETH (surplus1 == 0) and HALF the USDC (shortfall2 > 0)
        uint256 batchAmount1 = requiredToken1; // exact — no surplus
        uint256 batchAmount2 = requiredToken2 / 2;

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), batchAmount1);
        IERC20(USDC).approve(address(helper), batchAmount2);

        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "need token1"));
        helper.disputeReportSafe(
            dispute,
            p,
            batchAmount1,
            batchAmount2,
            block.timestamp,
            block.number,
            30,
            10,
            0
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  GAP 2: ETH wrapping — refund with excess ETH sent
    //  Verifies bob gets correct ETH/WETH/USDC refund amounts
    // ═══════════════════════════════════════════════════════════

    function test_ethWrapping_excessRefundAccounting() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createWethUsdcReport(
            initAmount1, multiplier, feePercentage, 0, 300, 0
        );
        _submitInitialReport(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier, type(uint256).max);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildOracleParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 requiredToken1 = newAmount1 + initAmount1 + feePercentage * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        // Send 2x the required ETH — large excess to test refund
        uint256 ethToSend = requiredToken1 * 2;

        (uint256 bobEthBefore, uint256 bobWethBefore, uint256 bobUsdcBefore) = _snapshot(bob);

        vm.startPrank(bob);
        IERC20(USDC).approve(address(helper), requiredToken2 + 1000e6);

        helper.disputeReportSafe{value: ethToSend}(
            dispute,
            p,
            0,                // no WETH batch
            requiredToken2,
            block.timestamp,
            block.number,
            30,
            10,
            0
        );
        vm.stopPrank();

        (uint256 bobEthAfter, uint256 bobWethAfter, uint256 bobUsdcAfter) = _snapshot(bob);

        // Bob sent ethToSend as msg.value but should get back (ethToSend - requiredToken1) as ETH refund
        // Net ETH spent = requiredToken1
        assertEq(bobEthBefore - bobEthAfter, requiredToken1, "bob ETH refund incorrect");

        // Bob's WETH balance should be unchanged (he sent ETH not WETH)
        assertEq(bobWethAfter, bobWethBefore, "bob WETH balance should be unchanged");

        // Bob should have spent exactly requiredToken2 USDC
        assertEq(bobUsdcBefore - bobUsdcAfter, requiredToken2, "bob USDC spend incorrect");

        // Helper clean
        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper USDC residual");
        assertEq(address(helper).balance, 0, "helper ETH residual");
    }
}
