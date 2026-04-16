// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/disputeHelper.sol";
import "../../src/interfaces/IOpenOracle.sol";
import "../../src/interfaces/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DisputeHelper ExactTokens Fork Tests
 * @notice Tests for disputeReportExactTokens -- the simpler pass-through dispute path.
 *         Unlike disputeReportSafe, this path:
 *         - Does NO auto-swaps (no Uniswap interaction)
 *         - Supports ETH wrapping via msg.value when EITHER token1 or token2 is WETH
 *         - Refunds leftover tokens as WETH (not unwrapped ETH)
 *         - Requires the caller to provide exact (or excess) token amounts
 *
 *         All tests pinned to Base mainnet block 43225333 for determinism.
 */
contract DisputeHelperExactTokensTest is Test {
    address constant ORACLE = 0x95E228EEeCd7292108F873ca0A8D78846D7d2aC1;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    IOpenOracle oracle = IOpenOracle(ORACLE);
    disputeHelper helper;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant REPORT_ETH_FEE = 0.001 ether;
    uint256 constant SETTLER_REWARD = 0.0001 ether;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        helper = new disputeHelper(ORACLE, BASE_WETH, UNISWAP_ROUTER);

        vm.etch(alice, "");
        vm.etch(bob, "");
        vm.etch(charlie, "");

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);

        vm.prank(alice);
        IWETH(BASE_WETH).deposit{value: 50 ether}();
        vm.prank(bob);
        IWETH(BASE_WETH).deposit{value: 50 ether}();
        vm.prank(charlie);
        IWETH(BASE_WETH).deposit{value: 50 ether}();

        deal(USDC, alice, 100_000e6);
        deal(USDC, bob, 100_000e6);
        deal(USDC, charlie, 100_000e6);
    }

    // ─── Helpers ──────────────────────────────────────────────

    /// @dev Creates report with token1=WETH, token2=USDC
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
            settlementTime: 300,
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

    /// @dev Creates report with token1=USDC, token2=WETH (reversed pair for token2==WETH tests)
    function _createReversedReport(
        uint256 exactToken1,
        uint16 multiplier,
        uint24 feePercentage
    ) internal returns (uint256 reportId, bytes32 stateHash) {
        IOpenOracle.CreateReportParams memory params = IOpenOracle.CreateReportParams({
            exactToken1Report: uint128(exactToken1),
            escalationHalt: type(uint128).max,
            settlerReward: uint96(SETTLER_REWARD),
            token1Address: USDC,
            settlementTime: 300,
            disputeDelay: 0,
            protocolFee: 0,
            token2Address: BASE_WETH,
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
        IOpenOracle.ReportMeta memory meta = oracle.reportMeta(reportId);
        vm.startPrank(alice);
        IERC20(meta.token1).approve(ORACLE, type(uint256).max);
        IERC20(meta.token2).approve(ORACLE, type(uint256).max);
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

    /// @dev Required tokens when tokenToSwap == token1 (disputer buys token1 side)
    function _requiredForToken1Path(
        uint256 initAmount1,
        uint256 initAmount2,
        uint256 newAmount1,
        uint256 newAmount2,
        uint24 feePercentage
    ) internal pure returns (uint256 req1, uint256 req2) {
        req1 = newAmount1 + initAmount1 + uint256(feePercentage) * initAmount1 / 1e7;
        req2 = newAmount2 > initAmount2 ? newAmount2 - initAmount2 : 0;
    }

    /// @dev Required tokens when tokenToSwap == token2 (disputer buys token2 side)
    function _requiredForToken2Path(
        uint256 initAmount1,
        uint256 initAmount2,
        uint256 newAmount1,
        uint256 newAmount2,
        uint24 feePercentage
    ) internal pure returns (uint256 req1, uint256 req2) {
        req1 = newAmount1 > initAmount1 ? newAmount1 - initAmount1 : 0;
        req2 = newAmount2 + initAmount2 + uint256(feePercentage) * initAmount2 / 1e7;
    }

    // ═══════════════════════════════════════════════════════════
    //  1. Token1-swap happy path (token1=WETH, tokenToSwap=WETH)
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_happyPath_token1Swap() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken1Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), req1);
        IERC20(USDC).approve(address(helper), req2);

        helper.disputeReportExactTokens(
            dispute, p, req1, req2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        IOpenOracle.ReportStatus memory postStatus = oracle.reportStatus(reportId);
        assertEq(postStatus.currentAmount1, newAmount1, "oracle amount1 not updated");
        assertEq(postStatus.currentAmount2, newAmount2, "oracle amount2 not updated");

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper USDC residual");
    }

    // ═══════════════════════════════════════════════════════════
    //  2. Token2-swap happy path (token1=WETH, tokenToSwap=USDC)
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_happyPath_token2Swap() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken2Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: USDC,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), req1);
        IERC20(USDC).approve(address(helper), req2);

        helper.disputeReportExactTokens(
            dispute, p, req1, req2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        IOpenOracle.ReportStatus memory postStatus = oracle.reportStatus(reportId);
        assertEq(postStatus.currentAmount1, newAmount1, "oracle amount1 not updated");
        assertEq(postStatus.currentAmount2, newAmount2, "oracle amount2 not updated");

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper USDC residual");
    }

    // ═══════════════════════════════════════════════════════════
    //  3. Token2-swap pre-existing balances not consumed
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_token2Swap_preExistingUntouched() public {
        vm.prank(charlie);
        IERC20(BASE_WETH).transfer(address(helper), 1 ether);
        vm.prank(charlie);
        IERC20(USDC).transfer(address(helper), 10_000e6);

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));

        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken2Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: USDC,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), req1);
        IERC20(USDC).approve(address(helper), req2);

        helper.disputeReportExactTokens(
            dispute, p, req1, req2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), helperWethBefore, "PRE-EXISTING WETH CONSUMED");
        assertEq(IERC20(USDC).balanceOf(address(helper)), helperUsdcBefore, "PRE-EXISTING USDC CONSUMED");
    }

    // ═══════════════════════════════════════════════════════════
    //  4. Exact refunds excess -- assertEq (tight)
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_refundsExcess_token1Swap() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken1Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        // Send 2x required
        uint256 batch1 = req1 * 2;
        uint256 batch2 = req2 + 50_000e6;

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 bobWethBefore = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), batch1);
        IERC20(USDC).approve(address(helper), batch2);

        helper.disputeReportExactTokens(
            dispute, p, batch1, batch2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        uint256 bobWethAfter = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcAfter = IERC20(USDC).balanceOf(bob);

        // Exact refund assertions -- bob should lose exactly req1 and req2
        assertEq(bobWethBefore - bobWethAfter, req1, "bob WETH spent != required");
        assertEq(bobUsdcBefore - bobUsdcAfter, req2, "bob USDC spent != required");

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper USDC residual");
    }

    function test_exactTokens_refundsExcess_token2Swap() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken2Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        uint256 batch1 = req1 + 1 ether;
        uint256 batch2 = req2 * 2;

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: USDC,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 bobWethBefore = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), batch1);
        IERC20(USDC).approve(address(helper), batch2);

        helper.disputeReportExactTokens(
            dispute, p, batch1, batch2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        uint256 bobWethAfter = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcAfter = IERC20(USDC).balanceOf(bob);

        assertEq(bobWethBefore - bobWethAfter, req1, "bob WETH spent != required");
        assertEq(bobUsdcBefore - bobUsdcAfter, req2, "bob USDC spent != required");

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper USDC residual");
    }

    // ═══════════════════════════════════════════════════════════
    //  5. Pure ERC20 (no msg.value) -- ETH unchanged
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_wethAsERC20Only() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken1Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 bobEthBefore = bob.balance;

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), req1);
        IERC20(USDC).approve(address(helper), req2);

        helper.disputeReportExactTokens(
            dispute, p, req1, req2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        assertEq(bob.balance, bobEthBefore, "bob ETH changed - wrapping should not happen");

        IOpenOracle.ReportStatus memory postStatus = oracle.reportStatus(reportId);
        assertEq(postStatus.currentAmount1, newAmount1, "oracle not updated");
    }

    // ═══════════════════════════════════════════════════════════
    //  6. Pre-existing balances not consumed (token1 swap)
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_preExistingBalancesUntouched() public {
        vm.prank(charlie);
        IERC20(BASE_WETH).transfer(address(helper), 1 ether);
        vm.prank(charlie);
        IERC20(USDC).transfer(address(helper), 10_000e6);
        vm.deal(address(helper), 1 ether);

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 helperEthBefore = address(helper).balance;

        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken1Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), req1);
        IERC20(USDC).approve(address(helper), req2);

        helper.disputeReportExactTokens(
            dispute, p, req1, req2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), helperWethBefore, "PRE-EXISTING WETH CONSUMED");
        assertEq(IERC20(USDC).balanceOf(address(helper)), helperUsdcBefore, "PRE-EXISTING USDC CONSUMED");
        assertEq(address(helper).balance, helperEthBefore, "PRE-EXISTING ETH CONSUMED");
    }

    // ═══════════════════════════════════════════════════════════
    //  7. ETH wrapping -- token1 == WETH, msg.value supplements batchAmount1
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_ethWrap_token1IsWeth() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken1Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        // Split req1: half as WETH ERC20, half as ETH via msg.value
        uint256 ethPortion = req1 / 2;
        uint256 wethPortion = req1 - ethPortion;

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 bobEthBefore = bob.balance;
        uint256 bobWethBefore = IERC20(BASE_WETH).balanceOf(bob);

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), wethPortion);
        IERC20(USDC).approve(address(helper), req2);

        helper.disputeReportExactTokens{value: ethPortion}(
            dispute, p, wethPortion, req2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        // Oracle updated
        IOpenOracle.ReportStatus memory postStatus = oracle.reportStatus(reportId);
        assertEq(postStatus.currentAmount1, newAmount1, "oracle amount1 not updated");
        assertEq(postStatus.currentAmount2, newAmount2, "oracle amount2 not updated");

        // Bob spent ethPortion from ETH and wethPortion from WETH
        assertEq(bobEthBefore - bob.balance, ethPortion, "bob ETH spent mismatch");
        assertEq(bobWethBefore - IERC20(BASE_WETH).balanceOf(bob), wethPortion, "bob WETH spent mismatch");

        // Helper clean
        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper USDC residual");
    }

    // ═══════════════════════════════════════════════════════════
    //  8. ETH wrapping -- token2 == WETH, msg.value supplements batchAmount2
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_ethWrap_token2IsWeth() public {
        // Reversed pair: token1=USDC, token2=WETH
        uint256 initAmount1 = 25e6;       // USDC
        uint256 initAmount2 = 0.01 ether;  // WETH
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReversedReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        // tokenToSwap = token1 (USDC) -- disputer buys USDC side
        (uint256 req1, uint256 req2) = _requiredForToken1Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        // Split req2 (WETH): half as WETH ERC20, half as ETH via msg.value
        uint256 ethPortion = req2 / 2;
        uint256 wethPortion = req2 - ethPortion;

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: USDC,     // token1 in reversed pair
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 bobEthBefore = bob.balance;
        uint256 bobWethBefore = IERC20(BASE_WETH).balanceOf(bob);

        vm.startPrank(bob);
        IERC20(USDC).approve(address(helper), req1);
        IERC20(BASE_WETH).approve(address(helper), wethPortion);

        helper.disputeReportExactTokens{value: ethPortion}(
            dispute, p, req1, wethPortion,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        // Oracle updated
        IOpenOracle.ReportStatus memory postStatus = oracle.reportStatus(reportId);
        assertEq(postStatus.currentAmount1, newAmount1, "oracle amount1 not updated");
        assertEq(postStatus.currentAmount2, newAmount2, "oracle amount2 not updated");

        // Bob spent ethPortion from ETH and wethPortion from WETH
        assertEq(bobEthBefore - bob.balance, ethPortion, "bob ETH spent mismatch");
        assertEq(bobWethBefore - IERC20(BASE_WETH).balanceOf(bob), wethPortion, "bob WETH spent mismatch");

        // Helper clean
        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper USDC residual");
    }

    // ═══════════════════════════════════════════════════════════
    //  9. ETH wrapping with excess -- refunded as WETH (not ETH)
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_ethWrap_excessRefundedAsWeth() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken1Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        // Send req1 as WETH + extra 1 ETH via msg.value
        uint256 extraEth = 1 ether;

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        uint256 bobEthBefore = bob.balance;
        uint256 bobWethBefore = IERC20(BASE_WETH).balanceOf(bob);

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), req1);
        IERC20(USDC).approve(address(helper), req2);

        helper.disputeReportExactTokens{value: extraEth}(
            dispute, p, req1, req2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        uint256 bobEthAfter = bob.balance;
        uint256 bobWethAfter = IERC20(BASE_WETH).balanceOf(bob);

        // Bob's ETH went down by extraEth (wrapped, not returned as ETH)
        assertEq(bobEthBefore - bobEthAfter, extraEth, "ETH not fully spent");

        // Bob got excess back as WETH: lost req1 from WETH, gained extraEth as WETH refund
        assertEq(bobWethAfter, bobWethBefore - req1 + extraEth, "excess not refunded as WETH");

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), 0, "helper WETH residual");
    }

    // ═══════════════════════════════════════════════════════════
    //  10. Revert: params mismatch
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_revert_paramsMismatch() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, 133, 3000);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        disputeHelper.oracleParams memory p = _buildParams(reportId);
        p.feePercentage = 9999; // tamper

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: 0.0133 ether,
            newAmount2: 34912500,
            amt2Expected: uint128(initAmount2),
            stateHash: stateHash
        });

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "params dont match"));
        helper.disputeReportExactTokens(
            dispute, p, 1 ether, 100_000e6,
            block.timestamp, block.number, 30, 10
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  12. Revert: stale timestamp
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_revert_staleTimestamp() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, 133, 3000);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        disputeHelper.oracleParams memory p = _buildParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: 0.0133 ether,
            newAmount2: 34912500,
            amt2Expected: uint128(initAmount2),
            stateHash: stateHash
        });

        vm.warp(block.timestamp + 100);
        uint256 staleTimestamp = block.timestamp - 100;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "timestamp"));
        helper.disputeReportExactTokens(
            dispute, p, 1 ether, 100_000e6,
            staleTimestamp, block.number, 30, 10
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  13. Revert: stale block number
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_revert_staleBlockNumber() public {
        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, 133, 3000);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        disputeHelper.oracleParams memory p = _buildParams(reportId);

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: 0.0133 ether,
            newAmount2: 34912500,
            amt2Expected: uint128(initAmount2),
            stateHash: stateHash
        });

        vm.roll(block.number + 100);
        uint256 staleBlock = block.number - 100;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(disputeHelper.ActionSafetyFailure.selector, "block number"));
        helper.disputeReportExactTokens(
            dispute, p, 1 ether, 100_000e6,
            block.timestamp, staleBlock, 30, 10
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  14. Underfunding reverts -- insufficient token1 for token1-swap path
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_revert_insufficientToken1() public {
        // Seed helper with pre-existing balances to verify they survive revert
        vm.prank(charlie);
        IERC20(BASE_WETH).transfer(address(helper), 0.5 ether);
        vm.prank(charlie);
        IERC20(USDC).transfer(address(helper), 500e6);

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 bobWethBefore = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);

        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken1Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        uint256 batch1 = req1 / 2;

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: BASE_WETH,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), batch1);
        IERC20(USDC).approve(address(helper), req2);

        vm.expectRevert();
        helper.disputeReportExactTokens(
            dispute, p, batch1, req2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        // Revert rolled everything back -- nothing stranded, pre-existing untouched
        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), helperWethBefore, "helper WETH changed after revert");
        assertEq(IERC20(USDC).balanceOf(address(helper)), helperUsdcBefore, "helper USDC changed after revert");
        assertEq(IERC20(BASE_WETH).balanceOf(bob), bobWethBefore, "bob WETH changed after revert");
        assertEq(IERC20(USDC).balanceOf(bob), bobUsdcBefore, "bob USDC changed after revert");
    }

    // ═══════════════════════════════════════════════════════════
    //  15. Underfunding reverts -- insufficient token2 for token2-swap path
    // ═══════════════════════════════════════════════════════════

    function test_exactTokens_revert_insufficientToken2() public {
        // Seed helper with pre-existing balances to verify they survive revert
        vm.prank(charlie);
        IERC20(BASE_WETH).transfer(address(helper), 0.5 ether);
        vm.prank(charlie);
        IERC20(USDC).transfer(address(helper), 500e6);

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 bobWethBefore = IERC20(BASE_WETH).balanceOf(bob);
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);

        uint256 initAmount1 = 0.01 ether;
        uint256 initAmount2 = 25e6;
        uint16 multiplier = 133;
        uint24 feePercentage = 3000;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken2Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        uint256 batch2 = req2 / 2;

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: USDC,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), req1);
        IERC20(USDC).approve(address(helper), batch2);

        vm.expectRevert();
        helper.disputeReportExactTokens(
            dispute, p, req1, batch2,
            block.timestamp, block.number, 30, 10
        );
        vm.stopPrank();

        // Revert rolled everything back -- nothing stranded, pre-existing untouched
        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), helperWethBefore, "helper WETH changed after revert");
        assertEq(IERC20(USDC).balanceOf(address(helper)), helperUsdcBefore, "helper USDC changed after revert");
        assertEq(IERC20(BASE_WETH).balanceOf(bob), bobWethBefore, "bob WETH changed after revert");
        assertEq(IERC20(USDC).balanceOf(bob), bobUsdcBefore, "bob USDC changed after revert");
    }

    // ═══════════════════════════════════════════════════════════
    //  FUZZ: token1-swap -- no dust, no pre-existing consumed
    // ═══════════════════════════════════════════════════════════

    function testFuzz_exactTokens_token1Swap_noDust(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed,
        uint256 preWeth,
        uint256 preUsdc,
        uint256 preEth
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.001 ether, 1 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 1e6, 5000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 101, 200));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 1, 50000));

        preWeth = bound(preWeth, 0, 2 ether);
        preUsdc = bound(preUsdc, 0, 10_000e6);
        preEth = bound(preEth, 0, 2 ether);

        if (preWeth > 0) {
            vm.prank(charlie);
            IERC20(BASE_WETH).transfer(address(helper), preWeth);
        }
        if (preUsdc > 0) {
            vm.prank(charlie);
            IERC20(USDC).transfer(address(helper), preUsdc);
        }
        if (preEth > 0) {
            vm.deal(address(helper), preEth);
        }

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));
        uint256 helperEthBefore = address(helper).balance;

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken1Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

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

        helper.disputeReportExactTokens(
            dispute, p, req1, req2,
            block.timestamp, block.number, 60, 100
        );
        vm.stopPrank();

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), helperWethBefore, "DUST WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), helperUsdcBefore, "DUST USDC");
        assertEq(address(helper).balance, helperEthBefore, "DUST ETH");
    }

    // ═══════════════════════════════════════════════════════════
    //  FUZZ: token2-swap -- no dust, no pre-existing consumed
    // ═══════════════════════════════════════════════════════════

    function testFuzz_exactTokens_token2Swap_noDust(
        uint256 initAmount1Seed,
        uint256 initAmount2Seed,
        uint8 multiplierSeed,
        uint16 feePercentageSeed,
        uint256 preWeth,
        uint256 preUsdc
    ) public {
        uint256 initAmount1 = bound(initAmount1Seed, 0.001 ether, 1 ether);
        uint256 initAmount2 = bound(initAmount2Seed, 1e6, 5000e6);
        uint16 multiplier = uint16(bound(multiplierSeed, 101, 200));
        uint24 feePercentage = uint24(bound(feePercentageSeed, 1, 50000));

        preWeth = bound(preWeth, 0, 2 ether);
        preUsdc = bound(preUsdc, 0, 10_000e6);

        if (preWeth > 0) {
            vm.prank(charlie);
            IERC20(BASE_WETH).transfer(address(helper), preWeth);
        }
        if (preUsdc > 0) {
            vm.prank(charlie);
            IERC20(USDC).transfer(address(helper), preUsdc);
        }

        uint256 helperWethBefore = IERC20(BASE_WETH).balanceOf(address(helper));
        uint256 helperUsdcBefore = IERC20(USDC).balanceOf(address(helper));

        (uint256 reportId, bytes32 stateHash) = _createReport(initAmount1, multiplier, feePercentage);
        _submitInitial(reportId, initAmount1, initAmount2, stateHash);

        uint256 newAmount1 = (initAmount1 * uint256(multiplier)) / 100;
        uint256 newAmount2 = (initAmount2 * uint256(multiplier) * 105) / 10000;

        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        disputeHelper.oracleParams memory p = _buildParams(reportId);

        (uint256 req1, uint256 req2) = _requiredForToken2Path(
            initAmount1, initAmount2, newAmount1, newAmount2, feePercentage
        );

        disputeHelper.DisputeData memory dispute = disputeHelper.DisputeData({
            reportId: reportId,
            tokenToSwap: USDC,
            newAmount1: uint128(newAmount1),
            newAmount2: uint128(newAmount2),
            amt2Expected: status.currentAmount2,
            stateHash: stateHash
        });

        vm.startPrank(bob);
        IERC20(BASE_WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC).approve(address(helper), type(uint256).max);

        helper.disputeReportExactTokens(
            dispute, p, req1, req2,
            block.timestamp, block.number, 60, 100
        );
        vm.stopPrank();

        assertEq(IERC20(BASE_WETH).balanceOf(address(helper)), helperWethBefore, "DUST WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), helperUsdcBefore, "DUST USDC");
    }
}
