// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

// Callback contracts with controllable behavior.
contract RevertingCallback {
    bool public shouldRevert = true;

    function openOracleCallback(uint256, uint256, uint256, uint256, address, address) external view {
        if (shouldRevert) revert("callback failed");
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }
}

contract GasGuzzlerCallback {
    // Burns gas in a loop until it runs out.
    function openOracleCallback(uint256, uint256, uint256, uint256, address, address) external view {
        uint256 i;
        while (true) {
            i++;
            // No-op work to keep the optimizer from removing the loop.
            if (i == type(uint256).max) revert();
        }
    }
}

// Reads its own oracle tokenHolder balances during the callback to verify they are
// already credited (settle() credits internal balances before invoking the callback).
interface IERC20Like {
    function approve(address, uint256) external returns (bool);
}

contract ReporterCallback {
    Slim internal immutable oracle;
    uint256 public seenToken1Balance;
    uint256 public seenToken2Balance;

    uint256 public lastReportId;
    Slim.OracleGame internal _lastGame;
    Slim.PreimageHelper internal _lastHelper;
    bool internal _captured;

    constructor(Slim _oracle) {
        oracle = _oracle;
    }

    receive() external payable {}

    function fundOracleReport(CompatTypes.CreateReportParams calldata p, uint128 amount1, uint128 amount2) external {
        IERC20Like(p.token1Address).approve(address(oracle), type(uint256).max);
        IERC20Like(p.token2Address).approve(address(oracle), type(uint256).max);
        lastReportId = CompatTypes.reportRaw(oracle, p.settlerReward,
            p, amount1, amount2, address(this), false, false,
            Slim.TimingBoundaries({blockNumber: 0, blockNumberBound: 0, blockTimestamp: 0, blockTimestampBound: 0})
        );
        // Build the OracleGame + PreimageHelper we'll pass into settle()
        _lastGame.token1 = p.token1Address;
        _lastGame.token2 = p.token2Address;
        _lastGame.feePercentage = p.feePercentage;
        _lastGame.multiplier = p.multiplier;
        _lastGame.settlementTime = p.settlementTime;
        _lastGame.escalationHalt = p.escalationHalt;
        _lastGame.disputeDelay = p.disputeDelay;
        _lastGame.protocolFee = p.protocolFee;
        _lastGame.settlerReward = p.settlerReward;
        _lastGame.callbackContract = p.callbackContract;
        _lastGame.callbackGasLimit = p.callbackGasLimit;
        _lastGame.protocolFeeRecipient = p.protocolFeeRecipient;
        _lastGame.flags = p.flags;
        _lastGame.currentAmount1 = amount1;
        _lastGame.currentAmount2 = amount2;
        _lastGame.currentReporter = payable(address(this));
        bool timeType = (p.flags & 1) != 0;
        _lastGame.reportTimestamp = timeType ? uint48(block.timestamp) : uint48(block.number);
        _lastGame.lastReportOppoTime = timeType ? uint48(block.number) : uint48(block.timestamp);
        _lastHelper = Slim.PreimageHelper({
            reportId: lastReportId,
            creator: address(this),
            blockTimestamp: block.timestamp,
            blockNumber: block.number
        });
        _captured = true;
    }

    function lastGame() external view returns (Slim.OracleGame memory) {
        return _lastGame;
    }

    function lastHelper() external view returns (Slim.PreimageHelper memory) {
        return _lastHelper;
    }

    function openOracleCallback(
        uint256, /*reportId*/
        uint256, /*amount1*/
        uint256, /*amount2*/
        uint256, /*currentTime*/
        address token1,
        address token2
    ) external {
        // Read our own credited balances mid-callback
        seenToken1Balance = oracle.tokenHolder(address(this), token1);
        seenToken2Balance = oracle.tokenHolder(address(this), token2);
    }
}

contract SuccessCallback {
    bool public called;
    uint256 public lastReportId;
    uint256 public lastAmount1;
    uint256 public lastAmount2;
    uint256 public lastCurrentTime;
    address public lastToken1;
    address public lastToken2;

    function openOracleCallback(
        uint256 reportId,
        uint256 amount1,
        uint256 amount2,
        uint256 currentTime,
        address token1,
        address token2
    ) external {
        called = true;
        lastReportId = reportId;
        lastAmount1 = amount1;
        lastAmount2 = amount2;
        lastCurrentTime = currentTime;
        lastToken1 = token1;
        lastToken2 = token2;
    }
}

// Tests for the settle() callback behavior:
//   - Successful callback: state changes commit
//   - Reverting callback (sufficient gas provided): revert is swallowed,
//     settlement still commits (this is the intentional design)
//   - Insufficient gas (gasleft < callbackGasLimit/63): InvalidGasLimit, all
//     state changes (settlementTimestamp, oracleGame hash, settlerReward
//     credit, currentReporter token credits) rolled back
contract OpenOracleGGCallbackTest is BaseGGTest {
    RevertingCallback internal revertingCb;
    GasGuzzlerCallback internal guzzlerCb;
    SuccessCallback internal successCb;

    function setUp() public override {
        BaseGGTest.setUp();
        revertingCb = new RevertingCallback();
        guzzlerCb = new GasGuzzlerCallback();
        successCb = new SuccessCallback();
    }

    function _paramsWithCallback(address cb, uint32 gasLimit)
        internal
        view
        returns (CompatTypes.CreateReportParams memory p)
    {
        p = _defaultParams();
        p.callbackContract = cb;
        p.callbackGasLimit = gasLimit;
    }

    // -------------------------------------------------------------------------
    // Successful callback: state commits
    // -------------------------------------------------------------------------
    function testCallback_Success_CommitsState() public {
        CompatTypes.CreateReportParams memory p = _paramsWithCallback(address(successCb), 200_000);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 301);

        vm.prank(charlie);
        ctx = _settle(ctx);

        assertTrue(successCb.called(), "callback fired");
        // Settled state visible.
        assertEq(_stateHash(ctx.reportId), _hashOracle(ctx.game, ctx.helper), "state advanced");
        // Charlie credited settler reward.
        assertEq(oracle.tokenHolder(charlie, address(0)), 1 + p.settlerReward, "settler reward credited");
    }

    // -------------------------------------------------------------------------
    // Reverting callback (enough gas): swallowed, settlement still commits
    // -------------------------------------------------------------------------
    function testCallback_Revert_Swallowed_SettlementCommits() public {
        CompatTypes.CreateReportParams memory p = _paramsWithCallback(address(revertingCb), 100_000);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 301);

        // Provide ample gas so gasleft check passes after the revert.
        vm.prank(charlie);
        ctx = _settle(ctx); // should NOT revert

        // Settled state visible.
        assertEq(_stateHash(ctx.reportId), _hashOracle(ctx.game, ctx.helper), "state advanced");
        assertEq(oracle.tokenHolder(charlie, address(0)), 1 + p.settlerReward, "settler reward credited");
        // Reporter (alice) credited final amounts.
        assertEq(_heldTokens(alice, address(token1)), 1 + 1e18, "alice token1 credited");
        assertEq(_heldTokens(alice, address(token2)), 1 + 2000e18, "alice token2 credited");
    }

    // -------------------------------------------------------------------------
    // Insufficient gas: InvalidGasLimit, full rollback
    // -------------------------------------------------------------------------
    function testCallback_InsufficientGas_RevertsWithInvalidGasLimit() public {
        // Callback that burns all forwarded gas. Ample callbackGasLimit so
        // when the call returns, gasleft < callbackGasLimit/63 triggers revert.
        CompatTypes.CreateReportParams memory p = _paramsWithCallback(address(guzzlerCb), 1_000_000);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 301);

        // Snapshot state before settle.
        bytes32 stateHashBefore = _stateHash(ctx.reportId);
        uint256 charlieEthBefore = oracle.tokenHolder(charlie, address(0));
        uint256 aliceT1Before = _heldTokens(alice, address(token1));
        uint256 aliceT2Before = _heldTokens(alice, address(token2));

        // settle reverts with InvalidGasLimit. Tight gas budget so that after
        // the callback consumes everything, gasleft() < callbackGasLimit/63.
        vm.prank(charlie);
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        oracle.settle{gas: 500_000}(ctx.reportId, ctx.game, ctx.helper);

        // All state changes rolled back.
        assertEq(_stateHash(ctx.reportId), stateHashBefore, "stateHash unchanged");
        assertEq(oracle.tokenHolder(charlie, address(0)), charlieEthBefore, "settler reward not credited");
        assertEq(_heldTokens(alice, address(token1)), aliceT1Before, "token1 not credited");
        assertEq(_heldTokens(alice, address(token2)), aliceT2Before, "token2 not credited");
    }

    // -------------------------------------------------------------------------
    // No callback configured: no callback path executed; settle still commits
    // -------------------------------------------------------------------------
    function testCallback_NoCallback_NoExecution() public {
        // Default params have callbackContract = address(0).
        vm.prank(alice);
        ReportContext memory ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 301);

        vm.prank(charlie);
        ctx = _settle(ctx);

        assertEq(_stateHash(ctx.reportId), _hashOracle(ctx.game, ctx.helper), "state advanced");
        assertEq(oracle.tokenHolder(charlie, address(0)), 1 + _defaultParams().settlerReward, "settler reward");
    }

    // -------------------------------------------------------------------------
    // Callback receives the raw currentAmount1/currentAmount2 from the oracle.
    // -------------------------------------------------------------------------
    function testCallback_ReceivesCorrectFinalRatio() public {
        uint128 amount1 = 1e18;
        uint128 amount2 = 2000e18;

        CompatTypes.CreateReportParams memory p = _paramsWithCallback(address(successCb), 200_000);
        assertEq(p.flags & FLAG_STORE_PRICE, 0, "STORE_PRICE flag is OFF");

        vm.prank(alice);
        ReportContext memory ctx = _report(p, amount1, amount2, alice, false, false);
        vm.warp(block.timestamp + 301);

        vm.prank(charlie);
        ctx = _settle(ctx);

        assertTrue(successCb.called(), "callback fired");

        assertEq(successCb.lastAmount1(), amount1, "callback received correct amount1");
        assertEq(successCb.lastAmount2(), amount2, "callback received correct amount2");
        assertEq(successCb.lastReportId(), ctx.reportId, "callback received correct reportId");
        assertEq(successCb.lastToken1(), address(token1), "callback received correct token1");
        assertEq(successCb.lastToken2(), address(token2), "callback received correct token2");
        // currentTime at settle (timeType=true): block.timestamp.
        assertEq(successCb.lastCurrentTime(), block.timestamp, "callback received correct currentTime");

        // finalPrice mapping should NOT have been written (FLAG_STORE_PRICE off).
        assertEq(oracle.finalPrice(ctx.reportId), 0, "finalPrice mapping not written");
    }

    // -------------------------------------------------------------------------
    // Fixed selector: arbitrary callbackContract (e.g. a real ERC20 token) cannot
    // be coerced into draining the oracle. settle() always sends data prefixed by
    // the openOracleCallback selector — wrong-selector calls revert inside the
    // target and the revert is swallowed. Oracle-held tokens stay put.
    // -------------------------------------------------------------------------
    function testCallback_FixedSelector_TokenCannotBeCoerced() public {
        // Point callbackContract at the actual token1 contract.
        // The callback would have to match `openOracleCallback(...)` selector — token1
        // doesn't have that function — call reverts inside token1, settle swallows it.
        CompatTypes.CreateReportParams memory p = _paramsWithCallback(address(token1), 200_000);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 301);

        uint256 oracleToken1Before = token1.balanceOf(address(oracle));

        vm.prank(charlie);
        ctx = _settle(ctx); // settle commits despite swallowed revert

        // Oracle's token1 balance unchanged — the unknown-selector call cannot move tokens.
        assertEq(token1.balanceOf(address(oracle)), oracleToken1Before, "oracle token1 not drained");
        // Settlement state still committed.
        assertEq(_stateHash(ctx.reportId), _hashOracle(ctx.game, ctx.helper), "state advanced");
        assertEq(oracle.tokenHolder(charlie, address(0)), 1 + p.settlerReward, "settler reward credited");
    }

    // -------------------------------------------------------------------------
    // Callback composability: settle credits internal balances BEFORE invoking
    // the callback, so a callback contract that is also the currentReporter can
    // read its own credited balances during the callback.
    // -------------------------------------------------------------------------
    function testCallback_CreditedBalancesVisibleDuringCallback() public {
        ReporterCallback cb = new ReporterCallback(oracle);

        // cb is BOTH the reporter and the callbackContract
        CompatTypes.CreateReportParams memory p = _paramsWithCallback(address(cb), 200_000);

        // Fund cb's external balances and approve, so cb can fund the report
        token1.transfer(address(cb), 10e18);
        token2.transfer(address(cb), 10000e18);
        vm.deal(address(cb), 1 ether);

        cb.fundOracleReport(p, 1e18, 2000e18);

        vm.warp(block.timestamp + 301);
        vm.prank(charlie);
        oracle.settle(cb.lastReportId(), cb.lastGame(), cb.lastHelper());

        // During the callback, cb saw its own credited balances
        assertEq(cb.seenToken1Balance(), 1 + 1e18, "cb saw token1 credit during callback");
        assertEq(cb.seenToken2Balance(), 1 + 2000e18, "cb saw token2 credit during callback");
    }

    // -------------------------------------------------------------------------
    // Callback receives post-dispute currentAmount1/currentAmount2 (not the original report).
    // -------------------------------------------------------------------------
    function testCallback_FinalRatio_AfterDispute() public {
        CompatTypes.CreateReportParams memory p = _paramsWithCallback(address(successCb), 200_000);

        vm.prank(alice);
        ReportContext memory ctx = _report(p, 1e18, 2000e18, alice, false, false);

        vm.warp(block.timestamp + 6);
        vm.prank(bob);
        ctx = _dispute(ctx, address(token1), 1.1e18, 2100e18, false, false);

        vm.warp(block.timestamp + 301);
        vm.prank(charlie);
        ctx = _settle(ctx);

        assertEq(successCb.lastAmount1(), 1.1e18, "callback amount1 reflects post-dispute");
        assertEq(successCb.lastAmount2(), 2100e18, "callback amount2 reflects post-dispute");
    }

}
