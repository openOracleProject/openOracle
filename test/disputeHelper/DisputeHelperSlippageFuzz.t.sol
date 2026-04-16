// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/disputeHelper.sol";
import "../../src/interfaces/IOpenOracle.sol";
import "../../src/interfaces/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DisputeHelper Slippage-Bound Fuzz Tests
 * @notice Fuzzes maxSwapInput across three behavioral bands per swap direction:
 *
 *   Band A: maxSwapInput > surplus   → helper reverts "surplus not enough"
 *   Band B: maxSwapInput too small   → Uniswap router reverts "STF"
 *   Band C: maxSwapInput = surplus   → success, no stuck funds
 *
 * Kept separate from the invariant fuzz suite to avoid router-sensitivity contamination.
 */
contract DisputeHelperSlippageFuzzTest is Test {
    address constant ORACLE = 0x95E228EEeCd7292108F873ca0A8D78846D7d2aC1;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    IOpenOracle oracle = IOpenOracle(ORACLE);
    disputeHelper helper;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant REPORT_ETH_FEE = 0.002 ether;
    uint256 constant SETTLER_REWARD = 0.0001 ether;

    function setUp() public {
        // Uses latest block (unpinned) because free RPCs prune historical state,
        // causing pinned blocks to expire. This is safe here — these tests create
        // their own oracle reports and only assert revert-or-not / no-stuck-funds,
        // so Uniswap pool state changes between blocks don't affect correctness.
        vm.createSelectFork("https://mainnet.base.org");
        helper = new disputeHelper(ORACLE, BASE_WETH, UNISWAP_ROUTER);

        vm.etch(alice, "");
        vm.etch(bob, "");

        vm.deal(alice, 200 ether);
        vm.deal(bob, 200 ether);

        vm.prank(alice);
        IWETH(BASE_WETH).deposit{value: 100 ether}();
        vm.prank(bob);
        IWETH(BASE_WETH).deposit{value: 100 ether}();

        deal(USDC, alice, 500_000e6);
        deal(USDC, bob, 500_000e6);
    }

    // ─── Helpers ──────────────────────────────────────────────

    function _createReport(
        uint256 exactToken1,
        uint16 multiplier,
        uint24 feePercentage
    ) internal returns (uint256 reportId, bytes32 stateHash) {
        IOpenOracle.CreateReportParams memory params = IOpenOracle.CreateReportParams({
            exactToken1Report: uint128(exactToken1),
            escalationHalt: type(uint128).max,
            settlerReward: uint96(SETTLER_REWARD),
            token1Address: BASE_WETH,
            settlementTime: 600,
            disputeDelay: 0,
            protocolFee: 0,
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

    // ═══════════════════════════════════════════════════════════
    //  SHORTFALL1 / SURPLUS2 (need WETH, have extra USDC)
    // ═══════════════════════════════════════════════════════════

    /// @dev Sets up a shortfall1 state. Returns all values needed for dispute.
    struct ShortfallSetup {
        uint256 reportId;
        bytes32 stateHash;
        disputeHelper.DisputeData dispute;
        disputeHelper.oracleParams p;
        uint256 batchAmount1;
        uint256 batchAmount2;
        uint256 surplus;
    }

    function _setupShortfall1(
        uint256 initAmount1,
        uint256 initAmount2,
        uint16 multiplier,
        uint24 feePercentage,
        uint256 surplusAmount
    ) internal returns (ShortfallSetup memory s) {
        (s.reportId, s.stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(s.reportId, initAmount1, initAmount2, s.stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(s.reportId);
        s.p = _buildParams(s.reportId);

        s.dispute = disputeHelper.DisputeData({
            reportId: s.reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: s.stateHash
        });

        uint256 requiredToken1 = newAmount1 + initAmount1 + uint256(feePercentage) * initAmount1 / 1e7;
        uint256 requiredToken2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;

        // Provide half the WETH → creates shortfall1
        s.batchAmount1 = requiredToken1 / 2;
        s.surplus = surplusAmount;
        s.batchAmount2 = requiredToken2 + s.surplus;
    }

    function _setupShortfall2(
        uint256 initAmount1,
        uint256 initAmount2,
        uint16 multiplier,
        uint24 feePercentage,
        uint256 surplusAmount
    ) internal returns (ShortfallSetup memory s) {
        (s.reportId, s.stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(s.reportId, initAmount1, initAmount2, s.stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(s.reportId);
        s.p = _buildParams(s.reportId);

        s.dispute = disputeHelper.DisputeData({
            reportId: s.reportId,
            tokenToSwap: USDC,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: s.stateHash
        });

        uint256 requiredToken1 = newAmount1 > initAmount1 ? newAmount1 - initAmount1 : 0;
        uint256 requiredToken2 = newAmount2 + initAmount2 + uint256(feePercentage) * initAmount2 / 1e7;

        // Provide half the USDC → creates shortfall2
        s.batchAmount2 = requiredToken2 / 2;
        s.surplus = surplusAmount; // actually surplus1 in this path
        s.batchAmount1 = requiredToken1 + s.surplus;
    }

    // ─── Band A: maxSwapInput > surplus → "surplus not enough" ──

    function testFuzz_slippageBound_shortfall1_surplusNotEnough(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed,
        uint256 surplusSeed
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.005 ether, 0.5 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 10e6, 2000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 110, 180));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 100, 30000));
        uint256 surplus = bound(surplusSeed, 1e6, 50_000e6);

        ShortfallSetup memory s = _setupShortfall1(initAmount1, initAmount2, multiplier, feePercentage, surplus);

        // maxSwapInput strictly above surplus → helper's own check fires
        uint256 maxSwapInput = s.surplus + 1;

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC).approve(address(helper), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "surplus not enough"));
        helper.disputeReportSafe(
            s.dispute, s.p, s.batchAmount1, s.batchAmount2,
            block.timestamp, block.number, 60, 100,
            maxSwapInput
        );
        vm.stopPrank();
    }

    // ─── Band B: maxSwapInput too small → router "STF" ──

    function testFuzz_slippageBound_shortfall1_routerSTF(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed,
        uint256 maxSwapSeed
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.005 ether, 0.5 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 10e6, 2000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 110, 180));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 100, 30000));
        uint256 surplus = 50_000e6; // generous surplus so helper check passes

        ShortfallSetup memory s = _setupShortfall1(initAmount1, initAmount2, multiplier, feePercentage, surplus);

        // maxSwapInput between 1 and 100 wei — guaranteed below any real swap cost
        // (even the smallest WETH shortfall requires far more than 100 USDC-wei to fill)
        uint256 maxSwapInput = bound(maxSwapSeed, 1, 100);

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC).approve(address(helper), type(uint256).max);

        vm.expectRevert(bytes("STF"));
        helper.disputeReportSafe(
            s.dispute, s.p, s.batchAmount1, s.batchAmount2,
            block.timestamp, block.number, 60, 100,
            maxSwapInput
        );
        vm.stopPrank();
    }

    // ─── Band C: maxSwapInput = surplus → success, no stuck funds ──

    function testFuzz_slippageBound_shortfall1_success(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.005 ether, 0.5 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 10e6, 2000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 110, 180));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 100, 30000));
        uint256 surplus = 50_000e6;

        ShortfallSetup memory s = _setupShortfall1(initAmount1, initAmount2, multiplier, feePercentage, surplus);

        // maxSwapInput = surplus — at the boundary of the helper check, passes both checks
        uint256 maxSwapInput = s.surplus;

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC).approve(address(helper), type(uint256).max);
        helper.disputeReportSafe(
            s.dispute, s.p, s.batchAmount1, s.batchAmount2,
            block.timestamp, block.number, 60, 100,
            maxSwapInput
        );
        vm.stopPrank();

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), helperWethBefore, "STUCK WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), helperUsdcBefore, "STUCK USDC");
    }

    // ═══════════════════════════════════════════════════════════
    //  SHORTFALL2 / SURPLUS1 (need USDC, have extra WETH)
    // ═══════════════════════════════════════════════════════════

    function testFuzz_slippageBound_shortfall2_surplusNotEnough(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed,
        uint256 surplusSeed
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.005 ether, 0.5 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 10e6, 2000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 110, 180));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 100, 30000));
        uint256 surplus = bound(surplusSeed, 0.01 ether, 5 ether);

        ShortfallSetup memory s = _setupShortfall2(initAmount1, initAmount2, multiplier, feePercentage, surplus);

        uint256 maxSwapInput = s.surplus + 1;

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC).approve(address(helper), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "surplus not enough"));
        helper.disputeReportSafe(
            s.dispute, s.p, s.batchAmount1, s.batchAmount2,
            block.timestamp, block.number, 60, 100,
            maxSwapInput
        );
        vm.stopPrank();
    }

    function testFuzz_slippageBound_shortfall2_routerSTF(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed,
        uint256 maxSwapSeed
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.005 ether, 0.5 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 10e6, 2000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 110, 180));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 100, 30000));
        uint256 surplus = 5 ether;

        ShortfallSetup memory s = _setupShortfall2(initAmount1, initAmount2, multiplier, feePercentage, surplus);

        // 1-100 wei of WETH — guaranteed below any real swap cost
        uint256 maxSwapInput = bound(maxSwapSeed, 1, 100);

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC).approve(address(helper), type(uint256).max);

        vm.expectRevert(bytes("STF"));
        helper.disputeReportSafe(
            s.dispute, s.p, s.batchAmount1, s.batchAmount2,
            block.timestamp, block.number, 60, 100,
            maxSwapInput
        );
        vm.stopPrank();
    }

    function testFuzz_slippageBound_shortfall2_success(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.005 ether, 0.5 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 10e6, 2000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 110, 180));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 100, 30000));
        uint256 surplus = 5 ether;

        ShortfallSetup memory s = _setupShortfall2(initAmount1, initAmount2, multiplier, feePercentage, surplus);

        uint256 maxSwapInput = s.surplus;

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC).approve(address(helper), type(uint256).max);
        helper.disputeReportSafe(
            s.dispute, s.p, s.batchAmount1, s.batchAmount2,
            block.timestamp, block.number, 60, 100,
            maxSwapInput
        );
        vm.stopPrank();

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), helperWethBefore, "STUCK WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), helperUsdcBefore, "STUCK USDC");
    }
}
