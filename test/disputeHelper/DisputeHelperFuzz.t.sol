// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/disputeHelper.sol";
import "../../src/interfaces/IOpenOracle.sol";
import "../../src/interfaces/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DisputeHelper Fuzz Tests — Stuck Funds & Pre-existing Balance Invariants
 * @notice All tests run against a live Base mainnet fork. Zero mocking.
 *
 * Core invariants tested:
 *   1. Helper must hold ZERO token1/token2 after every dispute (no stuck funds)
 *   2. Pre-existing balances in the helper must NOT be consumed by a dispute
 *   3. Pre-existing ETH/WETH/USDC in the helper must remain intact after disputes
 */
contract DisputeHelperFuzzTest is Test {
    // ─── Base mainnet addresses ───────────────────────────────
    address constant ORACLE = 0x95E228EEeCd7292108F873ca0A8D78846D7d2aC1;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    IOpenOracle oracle = IOpenOracle(ORACLE);
    disputeHelper helper;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant REPORT_ETH_FEE = 0.002 ether;
    uint256 constant SETTLER_REWARD = 0.0001 ether;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        helper = new disputeHelper(ORACLE, BASE_WETH, UNISWAP_ROUTER);

        vm.deal(alice, 200 ether);
        vm.deal(bob, 200 ether);
        vm.deal(charlie, 200 ether);

        vm.prank(alice);
        IWETH(BASE_WETH).deposit{value: 100 ether}();
        vm.prank(bob);
        IWETH(BASE_WETH).deposit{value: 100 ether}();
        vm.prank(charlie);
        IWETH(BASE_WETH).deposit{value: 100 ether}();

        deal(USDC, alice, 500_000e6);
        deal(USDC, bob, 500_000e6);
        deal(USDC, charlie, 500_000e6);
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════

    function _createReport(
        uint256 exactToken1,
        uint16 multiplier,
        uint24 feePercentage,
        uint24 protocolFee,
        uint48 settlementTime
    ) internal returns (uint256 reportId, bytes32 stateHash) {
        IOpenOracle.CreateReportParams memory params = IOpenOracle.CreateReportParams({
            exactToken1Report: uint128(exactToken1),
            escalationHalt: type(uint128).max,
            settlerReward: uint96(SETTLER_REWARD),
            token1Address: BASE_WETH,
            settlementTime: settlementTime,
            disputeDelay: 0,
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

    function _submitInitial(uint256 reportId, uint256 amount1, uint256 amount2, bytes32 stateHash) internal {
        vm.startPrank(alice);
        IERC20(BASE_WETH).approve(ORACLE, type(uint256).max);
        IERC20(USDC).approve(ORACLE, type(uint256).max);
        oracle.submitInitialReport(reportId, uint128(amount1), uint128(amount2), stateHash, alice);
        vm.stopPrank();
    }

    function _buildParams(uint256 reportId) internal view returns (disputeHelper.oracleParams memory p) {
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

    function _computeNewAmount1(uint256 oldAmount1, uint16 multiplier) internal pure returns (uint256) {
        uint256 expected = (oldAmount1 * multiplier) / 100;
        return expected;
    }

    /// @dev Performs a dispute via the helper and returns balances for assertions
    function _doDispute(
        uint256 reportId,
        bytes32 stateHash,
        uint256 newAmount1,
        uint256 newAmount2,
        address tokenToSwap,
        uint256 batchAmount1,
        uint256 batchAmount2,
        uint256 ethValue,
        address disputer
    ) internal {
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: tokenToSwap,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(disputer);
        IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC).approve(address(helper), type(uint256).max);
        helper.disputeReportSafe{value: ethValue}(
            dispute,
            p,
            batchAmount1,
            batchAmount2,
            block.timestamp,
            block.number,
            60,
            100,
            50_000e6 // generous maxSwapInput for auto-swap tests
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  INVARIANT: No stuck funds after dispute (token1 swap path)
    //  Fuzzed: initAmount1, initAmount2, multiplier, feePercentage, protocolFee
    // ═══════════════════════════════════════════════════════════

    function testFuzz_noStuckFunds_token1Swap(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed,
        uint16 protocolFeeSeed
    ) public {
        // Bound inputs to realistic ranges
        uint256 initAmount1 = bound(initAmount1Seed, 0.001 ether, 1 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 1e6, 5000e6); // 1 - 5000 USDC
        uint16 multiplier = uint16(bound(multiplierSeed, 101, 200)); // 1.01x - 2x
        uint24 feePercentage = uint24(bound(feePercentageSeed, 1, 50000)); // 0.00001% - 0.5%
        uint24 protocolFee = uint24(bound(protocolFeeSeed, 0, 50000));

        // feePercentage + protocolFee must be <= 1e7
        if (uint256(feePercentage) + uint256(protocolFee) > 1e7) {
            protocolFee = uint24(1e7 - feePercentage);
        }

        (uint256 reportId, bytes32 stateHash) = _createReport(
            initAmount1, multiplier, feePercentage, protocolFee, 600
        );
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier);
        // Price must be outside fee boundaries — make it significantly different
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        // Compute required tokens for token1 swap
        uint256 requiredToken1 = newAmount1 + initAmount1
            + uint256(feePercentage) * initAmount1 / 1e7 + uint256(protocolFee) * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        // Give bob generous buffer
        uint256 batch1 = requiredToken1 + 0.5 ether;
        uint256 batch2 = requiredToken2 + 5000e6;

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 helperEthBefore = address(helper).balance;

        _doDispute(reportId, stateHash, newAmount1, newAmount2, BASE_WETH, batch1, batch2, 0, bob);

        // INVARIANT: helper must not retain any tokens
        assertEq(
            IERC20(BASE_WETH).balanceOf(address(helper)),
            helperWethBefore,
            "STUCK WETH in helper"
        );
        assertEq(
            IERC20(USDC).balanceOf(address(helper)),
            helperUsdcBefore,
            "STUCK USDC in helper"
        );
        assertEq(
            address(helper).balance,
            helperEthBefore,
            "STUCK ETH in helper"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INVARIANT: No stuck funds after dispute (token2 swap path)
    // ═══════════════════════════════════════════════════════════

    function testFuzz_noStuckFunds_token2Swap(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed,
        uint16 protocolFeeSeed
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.001 ether, 1 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 1e6, 5000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 101, 200));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 1, 50000));
        uint24 protocolFee = uint24(bound(protocolFeeSeed, 0, 50000));

        if (uint256(feePercentage) + uint256(protocolFee) > 1e7) {
            protocolFee = uint24(1e7 - feePercentage);
        }

        (uint256 reportId, bytes32 stateHash) = _createReport(
            initAmount1, multiplier, feePercentage, protocolFee, 600
        );
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        // Compute required tokens for token2 swap
        uint256 requiredToken1 = newAmount1 > initAmount1 ? newAmount1 - initAmount1 : 0;
        uint256 requiredToken2 = newAmount2 + initAmount2
            + uint256(feePercentage) * initAmount2 / 1e7 + uint256(protocolFee) * initAmount2 / 1e7;

        uint256 batch1 = requiredToken1 + 0.5 ether;
        uint256 batch2 = requiredToken2 + 5000e6;

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 helperEthBefore = address(helper).balance;

        _doDispute(reportId, stateHash, newAmount1, newAmount2, USDC, batch1, batch2, 0, bob);

        assertEq(
            IERC20(BASE_WETH).balanceOf(address(helper)),
            helperWethBefore,
            "STUCK WETH in helper"
        );
        assertEq(
            IERC20(USDC).balanceOf(address(helper)),
            helperUsdcBefore,
            "STUCK USDC in helper"
        );
        assertEq(
            address(helper).balance,
            helperEthBefore,
            "STUCK ETH in helper"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INVARIANT: No stuck funds with ETH wrapping path
    // ═══════════════════════════════════════════════════════════

    function testFuzz_noStuckFunds_ethWrapping(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed,
        uint256 ethSentSeed
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.001 ether, 0.5 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 1e6, 2500e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 101, 200));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 1, 50000));

        (uint256 reportId, bytes32 stateHash) = _createReport(
            initAmount1, multiplier, feePercentage, 0, 600
        );
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        uint256 requiredToken1 = newAmount1 + initAmount1
            + uint256(feePercentage) * initAmount1 / 1e7;

        // Send some as ETH, rest as WETH — fuzz the split
        uint256 ethToSend = bound(ethSentSeed, 0.0001 ether, requiredToken1);
        uint256 wethToSend = requiredToken1 > ethToSend ? requiredToken1 - ethToSend + 0.1 ether : 0.1 ether;
        uint256 usdcToSend = newAmount2 > initAmount2 ? newAmount2 - initAmount2 + 1000e6 : 1000e6;

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 helperEthBefore = address(helper).balance;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC).approve(address(helper), type(uint256).max);
        helper.disputeReportSafe{value: ethToSend}(
            dispute,
            p,
            wethToSend,
            usdcToSend,
            block.timestamp,
            block.number,
            60,
            100,
            0
        );
        vm.stopPrank();

        assertEq(
            IERC20(BASE_WETH).balanceOf(address(helper)),
            helperWethBefore,
            "STUCK WETH in helper after ETH wrap"
        );
        assertEq(
            IERC20(USDC).balanceOf(address(helper)),
            helperUsdcBefore,
            "STUCK USDC in helper after ETH wrap"
        );
        assertEq(
            address(helper).balance,
            helperEthBefore,
            "STUCK ETH in helper after ETH wrap"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  CRITICAL: Pre-existing balances must NOT be consumed
    //  Seeds the helper with ETH, WETH, and USDC before dispute
    // ═══════════════════════════════════════════════════════════

    function testFuzz_preExistingBalances_notConsumed_token1Swap(
        uint256 preWeth,
        uint256 preUsdc,
        uint256 preEth,
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed
    ) public {
        // Seed helper with pre-existing balances
        preWeth = bound(preWeth, 0.001 ether, 5 ether);
        preUsdc = bound(preUsdc, 1e6, 50_000e6);
        preEth = bound(preEth, 0.001 ether, 5 ether);

        // Fund helper with pre-existing tokens
        vm.prank(charlie);
        IERC20(BASE_WETH).transfer(address(helper), preWeth);
        vm.prank(charlie);
        IERC20(USDC).transfer(address(helper), preUsdc);
        vm.deal(address(helper), preEth);

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 helperEthBefore = address(helper).balance;

        // Verify pre-existing balances are set
        assertEq(helperWethBefore, preWeth, "pre-WETH not set");
        assertEq(helperUsdcBefore, preUsdc, "pre-USDC not set");
        assertEq(helperEthBefore, preEth, "pre-ETH not set");

        // Now do a normal dispute
        uint256 initAmount1 = bound(initAmount1Seed, 0.001 ether, 1 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 1e6, 5000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 101, 200));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 1, 50000));

        (uint256 reportId, bytes32 stateHash) = _createReport(
            initAmount1, multiplier, feePercentage, 0, 600
        );
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        uint256 requiredToken1 = newAmount1 + initAmount1
            + uint256(feePercentage) * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        // Bob provides EXACT required tokens (no buffer) to maximize chance of consuming pre-existing
        _doDispute(
            reportId, stateHash, newAmount1, newAmount2, BASE_WETH,
            requiredToken1, requiredToken2, 0, bob
        );

        // CRITICAL INVARIANT: pre-existing balances must be untouched
        assertEq(
            IERC20(BASE_WETH).balanceOf(address(helper)),
            helperWethBefore,
            "PRE-EXISTING WETH CONSUMED"
        );
        assertEq(
            IERC20(USDC).balanceOf(address(helper)),
            helperUsdcBefore,
            "PRE-EXISTING USDC CONSUMED"
        );
        assertEq(
            address(helper).balance,
            helperEthBefore,
            "PRE-EXISTING ETH CONSUMED"
        );
    }

    function testFuzz_preExistingBalances_notConsumed_token2Swap(
        uint256 preWeth,
        uint256 preUsdc,
        uint256 preEth,
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed
    ) public {
        preWeth = bound(preWeth, 0.001 ether, 5 ether);
        preUsdc = bound(preUsdc, 1e6, 50_000e6);
        preEth = bound(preEth, 0.001 ether, 5 ether);

        vm.prank(charlie);
        IERC20(BASE_WETH).transfer(address(helper), preWeth);
        vm.prank(charlie);
        IERC20(USDC).transfer(address(helper), preUsdc);
        vm.deal(address(helper), preEth);

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 helperEthBefore = address(helper).balance;

        uint256 initAmount1 = bound(initAmount1Seed, 0.001 ether, 1 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 1e6, 5000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 101, 200));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 1, 50000));

        (uint256 reportId, bytes32 stateHash) = _createReport(
            initAmount1, multiplier, feePercentage, 0, 600
        );
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        uint256 requiredToken1 = newAmount1 > initAmount1 ? newAmount1 - initAmount1 : 0;
        uint256 requiredToken2 = newAmount2 + initAmount2
            + uint256(feePercentage) * initAmount2 / 1e7;

        _doDispute(
            reportId, stateHash, newAmount1, newAmount2, USDC,
            requiredToken1, requiredToken2, 0, bob
        );

        assertEq(
            IERC20(BASE_WETH).balanceOf(address(helper)),
            helperWethBefore,
            "PRE-EXISTING WETH CONSUMED"
        );
        assertEq(
            IERC20(USDC).balanceOf(address(helper)),
            helperUsdcBefore,
            "PRE-EXISTING USDC CONSUMED"
        );
        assertEq(
            address(helper).balance,
            helperEthBefore,
            "PRE-EXISTING ETH CONSUMED"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  Pre-existing balances + ETH wrapping path
    // ═══════════════════════════════════════════════════════════

    function testFuzz_preExistingBalances_ethWrapping(
        uint256 preWeth,
        uint256 preUsdc,
        uint256 preEth,
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed
    ) public {
        preWeth = bound(preWeth, 0.001 ether, 2 ether);
        preUsdc = bound(preUsdc, 1e6, 10_000e6);
        preEth = bound(preEth, 0.001 ether, 2 ether);

        vm.prank(charlie);
        IERC20(BASE_WETH).transfer(address(helper), preWeth);
        vm.prank(charlie);
        IERC20(USDC).transfer(address(helper), preUsdc);
        vm.deal(address(helper), preEth);

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 helperEthBefore = address(helper).balance;

        uint256 initAmount1 = bound(initAmount1Seed, 0.001 ether, 0.5 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 1e6, 2500e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 101, 180));
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(
            initAmount1, multiplier, feePercentage, 0, 600
        );
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        uint256 requiredToken1 = newAmount1 + initAmount1
            + uint256(feePercentage) * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        // Send ALL token1 requirement as raw ETH
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(USDC).approve(address(helper), type(uint256).max);
        helper.disputeReportSafe{value: requiredToken1}(
            dispute,
            p,
            0, // no WETH batch — all via ETH
            requiredToken2,
            block.timestamp,
            block.number,
            60,
            100,
            0
        );
        vm.stopPrank();

        // Pre-existing balances must be untouched
        assertEq(
            IERC20(BASE_WETH).balanceOf(address(helper)),
            helperWethBefore,
            "PRE-EXISTING WETH CONSUMED (ETH wrap path)"
        );
        assertEq(
            IERC20(USDC).balanceOf(address(helper)),
            helperUsdcBefore,
            "PRE-EXISTING USDC CONSUMED (ETH wrap path)"
        );
        assertEq(
            address(helper).balance,
            helperEthBefore,
            "PRE-EXISTING ETH CONSUMED (ETH wrap path)"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INVARIANT: Multiple sequential disputes don't accumulate dust
    // ═══════════════════════════════════════════════════════════

    function testFuzz_multipleDisputes_noDustAccumulation(
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed
    ) public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = bound(initAmount2Seed, 10e6, 1000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 110, 160));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 1, 30000));

        (uint256 reportId, bytes32 stateHash) = _createReport(
            initAmount1, multiplier, feePercentage, 0, 600
        );
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 helperWethStart = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcStart = IERC20(USDC).balanceOf(address(helper));
        uint256 helperEthStart = address(helper).balance;

        // Do 3 sequential disputes — bob, charlie, bob again
        // Each dispute escalates amount1 by multiplier
        address[3] memory disputers = [bob, charlie, bob];
        uint256 currentAmount1 = initAmount1;
        uint256 currentAmount2 = initAmount2;

        for (uint256 i = 0; i < 3; i++) {
            uint256 newAmount1 = _computeNewAmount1(currentAmount1, multiplier);
            // Alternate price direction to stay outside boundaries
            uint256 newAmount2;
            if (i % 2 == 0) {
                newAmount2 = (currentAmount2 * uint256(multiplier) * 105) / 10000;
            } else {
                newAmount2 = (currentAmount2 * uint256(multiplier) * 95) / 10000;
            }

            IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
            disputeHelper.oracleParams memory p = _buildParams(reportId);

            disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
                reportId: reportId,
                tokenToSwap: BASE_WETH,
                newAmount1: uint128(newAmount1),
                newAmount2: uint128(newAmount2),
                amt2Expected: status.currentAmount2,
                stateHash: stateHash
            });

            uint256 requiredToken1 = newAmount1 + currentAmount1
                + uint256(feePercentage) * currentAmount1 / 1e7;
            uint256 requiredToken2 = newAmount2 > currentAmount2 ? newAmount2 - currentAmount2 : 0;

            vm.startPrank(disputers[i]);
            IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
            IERC20(USDC).approve(address(helper), type(uint256).max);
            helper.disputeReportSafe(
                dispute,
                p,
                requiredToken1 + 0.5 ether,
                requiredToken2 + 5000e6,
                block.timestamp,
                block.number,
                60,
                100,
                0
            );
            vm.stopPrank();

            currentAmount1 = newAmount1;
            currentAmount2 = newAmount2;
        }

        // After 3 disputes, helper must have ZERO accumulated dust
        assertEq(
            IERC20(BASE_WETH).balanceOf(address(helper)),
            helperWethStart,
            "DUST ACCUMULATED: WETH after 3 disputes"
        );
        assertEq(
            IERC20(USDC).balanceOf(address(helper)),
            helperUsdcStart,
            "DUST ACCUMULATED: USDC after 3 disputes"
        );
        assertEq(
            address(helper).balance,
            helperEthStart,
            "DUST ACCUMULATED: ETH after 3 disputes"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  Pre-existing balances + multiple disputes
    // ═══════════════════════════════════════════════════════════

    function testFuzz_preExisting_multipleDisputes(
        uint256 preWeth,
        uint256 preUsdc,
        uint256 preEth
    ) public {
        preWeth = bound(preWeth, 0.01 ether, 3 ether);
        preUsdc = bound(preUsdc, 100e6, 30_000e6);
        preEth = bound(preEth, 0.01 ether, 3 ether);

        vm.prank(charlie);
        IERC20(BASE_WETH).transfer(address(helper), preWeth);
        vm.prank(charlie);
        IERC20(USDC).transfer(address(helper), preUsdc);
        vm.deal(address(helper), preEth);

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 helperEthBefore = address(helper).balance;

        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(
            initAmount1, multiplier, feePercentage, 0, 600
        );
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        // Two disputes
        uint256 currentAmount1 = initAmount1;
        uint256 currentAmount2 = initAmount2;

        for (uint256 i = 0; i < 2; i++) {
            uint256 newAmount1 = _computeNewAmount1(currentAmount1, multiplier);
            uint256 newAmount2 = (currentAmount2 * uint256(multiplier) * 105) / 10000;

            IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
            disputeHelper.oracleParams memory p = _buildParams(reportId);

            disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
                reportId: reportId,
                tokenToSwap: BASE_WETH,
                newAmount1: uint128(newAmount1),
                newAmount2: uint128(newAmount2),
                amt2Expected: status.currentAmount2,
                stateHash: stateHash
            });

            uint256 requiredToken1 = newAmount1 + currentAmount1
                + uint256(feePercentage) * currentAmount1 / 1e7;
            uint256 requiredToken2 = newAmount2 > currentAmount2 ? newAmount2 - currentAmount2 : 0;

            address disputer = i == 0 ? bob : charlie;
            vm.startPrank(disputer);
            IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
            IERC20(USDC).approve(address(helper), type(uint256).max);
            helper.disputeReportSafe(
                dispute,
                p,
                requiredToken1 + 0.1 ether,
                requiredToken2 + 1000e6,
                block.timestamp,
                block.number,
                60,
                100,
                0
            );
            vm.stopPrank();

            currentAmount1 = newAmount1;
            currentAmount2 = newAmount2;
        }

        assertEq(
            IERC20(BASE_WETH).balanceOf(address(helper)),
            helperWethBefore,
            "PRE-EXISTING WETH DRAINED over multiple disputes"
        );
        assertEq(
            IERC20(USDC).balanceOf(address(helper)),
            helperUsdcBefore,
            "PRE-EXISTING USDC DRAINED over multiple disputes"
        );
        assertEq(
            address(helper).balance,
            helperEthBefore,
            "PRE-EXISTING ETH DRAINED over multiple disputes"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  Edge case: exact amounts (no buffer) — any rounding = stuck funds
    // ═══════════════════════════════════════════════════════════

    function testFuzz_exactAmounts_noBuffer(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.001 ether, 1 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 1e6, 5000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 101, 200));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 1, 50000));

        (uint256 reportId, bytes32 stateHash) = _createReport(
            initAmount1, multiplier, feePercentage, 0, 600
        );
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = _computeNewAmount1(initAmount1, multiplier);
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        // Compute EXACT required amounts — no buffer at all
        uint256 requiredToken1 = newAmount1 + initAmount1
            + uint256(feePercentage) * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));

        _doDispute(
            reportId, stateHash, newAmount1, newAmount2, BASE_WETH,
            requiredToken1, requiredToken2, 0, bob
        );

        // With exact amounts, helper should still be clean
        assertEq(
            IERC20(BASE_WETH).balanceOf(address(helper)),
            helperWethBefore,
            "STUCK WETH with exact amounts"
        );
        assertEq(
            IERC20(USDC).balanceOf(address(helper)),
            helperUsdcBefore,
            "STUCK USDC with exact amounts"
        );
    }
}
