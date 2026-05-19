// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {AdversarialCallback, RevertingToken, ReturnsFalseToken, NoReturnToken, ReentrantToken} from "./AdversarialMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deterministic regression fixtures for adversarial tokens and callbacks. These pin
///         specific attack shapes the fuzz campaign exercises stochastically.
contract OracleAdversarialFixturesTest is Test {
    OpenOracle internal oracle;
    AdversarialCallback internal cb;
    MockERC20 internal vanilla;
    NoReturnToken internal usdtLike;
    RevertingToken internal reverting;
    ReturnsFalseToken internal returnsFalse;
    ReentrantToken internal reentrant;

    address internal alice = address(0xA1);

    uint8 internal constant FLAG_TIME_TYPE = 1;
    uint96 internal constant SETTLER_REWARD = 0.001 ether;

    // Captured preimage of the most recent report-with-callback.
    OpenOracle.OracleGame internal lastGame;
    OpenOracle.PreimageHelper internal lastHelper;
    uint256 internal lastReportId;

    function setUp() public {
        oracle = new OpenOracle();
        cb = new AdversarialCallback();

        vanilla = new MockERC20("V", "V");
        usdtLike = new NoReturnToken();
        reverting = new RevertingToken();
        returnsFalse = new ReturnsFalseToken();
        reentrant = new ReentrantToken(address(oracle));

        vanilla.transfer(alice, 100_000e18);
        usdtLike.transfer(alice, 100_000e18);
        deal(address(returnsFalse), alice, 100_000e18);
        deal(address(reentrant), alice, 100_000e18);

        vm.deal(alice, 100 ether);

        vm.startPrank(alice);
        vanilla.approve(address(oracle), type(uint256).max);
        usdtLike.approve(address(oracle), type(uint256).max);
        reverting.approve(address(oracle), type(uint256).max);
        returnsFalse.approve(address(oracle), type(uint256).max);
        reentrant.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    function _baseGame(address t1, address t2) internal view returns (OpenOracle.OracleGame memory g) {
        g.currentAmount1 = 1e18;
        g.currentAmount2 = 1e18;
        g.currentReporter = alice;
        g.token1 = t1;
        g.token2 = t2;
        g.settlementTime = 60;
        g.escalationHalt = 10e18;
        g.protocolFeeRecipient = alice;
        g.settlerReward = SETTLER_REWARD;
        g.disputeDelay = 1;
        g.feePercentage = 3000;
        g.multiplier = 110;
        g.callbackContract = address(0);
        g.callbackGasLimit = 0;
        g.protocolFee = 1000;
        g.flags = FLAG_TIME_TYPE;
    }

    function _baseTiming() internal pure returns (OpenOracle.TimingBoundaries memory t) {}

    // ─── Adversarial tokens ────────────────────────────────────────────────

    function testFixture_ReportRevertsWithRevertingToken() public {
        OpenOracle.OracleGame memory g = _baseGame(address(reverting), address(vanilla));
        uint256 idBefore = oracle.nextReportId();
        bytes32 holderBefore = bytes32(oracle.tokenHolder(alice, address(reverting)));

        vm.prank(alice);
        vm.expectRevert();
        oracle.report{value: SETTLER_REWARD}(g, false, false, _baseTiming());

        assertEq(oracle.nextReportId(), idBefore, "nextReportId unchanged");
        assertEq(bytes32(oracle.tokenHolder(alice, address(reverting))), holderBefore, "no tokenHolder mutation");
        assertEq(address(oracle).balance, 0, "no ETH retained");
    }

    function testFixture_ReportRevertsWithReturnsFalseToken() public {
        OpenOracle.OracleGame memory g = _baseGame(address(returnsFalse), address(vanilla));
        uint256 idBefore = oracle.nextReportId();
        vm.prank(alice);
        vm.expectRevert();
        oracle.report{value: SETTLER_REWARD}(g, false, false, _baseTiming());
        assertEq(oracle.nextReportId(), idBefore);
        assertEq(address(oracle).balance, 0);
    }

    function testFixture_ReportSucceedsWithUsdtLikeToken() public {
        OpenOracle.OracleGame memory g = _baseGame(address(usdtLike), address(vanilla));
        vm.prank(alice);
        uint256 id = oracle.report{value: SETTLER_REWARD}(g, false, false, _baseTiming());
        assertEq(id, 1, "report created");
        assertEq(usdtLike.balanceOf(address(oracle)), 1e18, "USDT-style transfer landed");
    }

    function testFixture_DepositReentrantTokenNoCorruption() public {
        vm.prank(alice);
        oracle.deposit(address(reentrant), 100e18, alice);

        assertEq(oracle.tokenHolder(alice, address(reentrant)), 100e18 + 1, "alice credited with sentinel");
        assertEq(reentrant.balanceOf(address(oracle)), 100e18, "real balance matches");
        assertTrue(reentrant.reentered(), "reentry attempted");
    }

    // ─── Adversarial callback modes ────────────────────────────────────────

    function testFixture_SettleSurvivesCallbackRevert() public {
        cb.setMode(AdversarialCallback.Mode.Revert);
        _createReportWithCallback(200_000);

        vm.warp(block.timestamp + 120);
        oracle.settle(lastReportId, lastGame, lastHelper);

        // The callback's body writes get reverted with its revert, so cb.called(id) stays false.
        // The settle still completes because the contract intentionally ignores callback success.
        assertTrue(_isSettled(lastReportId), "settle landed despite callback revert");
    }

    /// @notice When the caller doesn't supply enough headroom for the 63/64 EVM rule, settle
    ///         reverts with InvalidGasLimit so the gas-griefing attempt is detectable.
    function testFixture_SettleRevertsOnGasGriefingCallback() public {
        cb.setMode(AdversarialCallback.Mode.ConsumeAll);
        _createReportWithCallback(200_000);

        vm.warp(block.timestamp + 120);
        // Outer gas tight enough that gasleft_at_callsite < callbackGasLimit * 64/63 ≈ 203174.
        // EVM forwards 63/64 * gasleft → parent retains 1/64 → triggers InvalidGasLimit.
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        oracle.settle{gas: 220_000}(lastReportId, lastGame, lastHelper);
    }

    function testFixture_SettleCallbackReentryAfterStateWrite() public {
        cb.setMode(AdversarialCallback.Mode.Reenter);
        _createReportWithCallback(200_000);

        vm.warp(block.timestamp + 120);
        oracle.settle(lastReportId, lastGame, lastHelper);

        assertTrue(_isSettled(lastReportId), "settled despite reentry");
        assertEq(cb.calls(), 1, "callback fired exactly once");
    }

    function testFixture_CallbackGasCappedAtLimit() public {
        cb.setMode(AdversarialCallback.Mode.Noop);
        uint32 limit = 150_000;
        _createReportWithCallback(limit);

        vm.warp(block.timestamp + 120);
        oracle.settle(lastReportId, lastGame, lastHelper);

        assertLe(cb.lastGas(lastReportId), uint256(limit), "callback gas at entry <= limit");
    }

    // ─── Helpers ───────────────────────────────────────────────────────────

    function _createReportWithCallback(uint32 limit) internal {
        OpenOracle.OracleGame memory g = _baseGame(address(vanilla), address(usdtLike));
        g.callbackContract = address(cb);
        g.callbackGasLimit = limit;

        uint256 ts = block.timestamp;
        uint256 bn = block.number;

        vm.prank(alice);
        lastReportId = oracle.report{value: SETTLER_REWARD}(g, false, false, _baseTiming());

        // Capture the contract-finalized OracleGame for later settle.
        g.reportTimestamp = uint48(ts);
        g.lastReportOppoTime = uint48(bn);
        lastGame = g;

        lastHelper = OpenOracle.PreimageHelper({
            reportId: lastReportId,
            creator: alice,
            blockTimestamp: ts,
            blockNumber: bn
        });
    }

    function _isSettled(uint256 id) internal view returns (bool) {
        // After settle, the stored hash includes settlementTimestamp != 0.
        // We can verify by reconstructing the post-settle hash.
        OpenOracle.OracleGame memory g = lastGame;
        g.settlementTimestamp = uint48(block.timestamp);
        return oracle.oracleGame(id) == keccak256(abi.encode(g, lastHelper));
    }
}
