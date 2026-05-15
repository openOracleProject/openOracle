// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {OpenOracle as Slim} from "../../src/OpenOracleSlim.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {CompatTypes} from "./CompatTypes.sol";

// Shared base for OpenOracleSlim behavioral tests.
// OpenOracleSlim is calldata-mode-only: there's a single `report()` entry that
// creates and submits in one call, and dispute/settle take the OracleGame +
// PreimageHelper preimage as calldata.
abstract contract BaseGGTest is Test {
    Slim internal oracle;
    MockERC20 internal token1;
    MockERC20 internal token2;

    address internal alice = address(0x1);
    address internal bob = address(0x2);
    address internal charlie = address(0x3);
    address payable internal protocolFeeRecipient = payable(address(0x123456));

    // Layout: slot 0 = nextReportId, slot 1 = oracleGame mapping
    uint256 internal constant ORACLE_GAME_SLOT = 1;

    // Flag bit positions (mirror Slim's public constants).
    uint8 internal constant FLAG_TIME_TYPE = 1 << 0;
    uint8 internal constant FLAG_TRACK_DISPUTES = 1 << 1;
    uint8 internal constant FLAG_STORE_ALL = 1 << 2;
    uint8 internal constant FLAG_STORE_PRICE = 1 << 3;

    // ETH side sentinel (matches Slim.ETH_SENTINEL).
    address internal constant ETH_SENTINEL = address(0);

    // Captures the full preimage (game struct + helper) for a given report.
    // After mutating ops (dispute, settle), the caller must update `game`.
    struct ReportContext {
        uint256 reportId;
        Slim.OracleGame game;
        Slim.PreimageHelper helper;
    }

    // CompatTypes.CreateReportParams type alias — defined in CompatTypes for shared reuse with
    // standalone tests that don't inherit BaseGGTest.
    // (Use CompatTypes.CompatTypes.CreateReportParams or import CompatTypes if outside this contract.)

    function setUp() public virtual {
        oracle = new Slim();
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        token1.transfer(alice, 100 ether);
        token1.transfer(bob, 100 ether);
        token1.transfer(charlie, 100 ether);
        token2.transfer(alice, 100_000 ether);
        token2.transfer(bob, 100_000 ether);
        token2.transfer(charlie, 100_000 ether);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);
        vm.deal(protocolFeeRecipient, 1 ether);

        _approveOracle(alice);
        _approveOracle(bob);
        _approveOracle(charlie);
    }

    function _approveOracle(address user) internal {
        vm.startPrank(user);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    // Read the current stateHash directly from the oracleGame mapping.
    function _stateHash(uint256 reportId) internal view returns (bytes32) {
        return oracle.oracleGame(reportId);
    }

    function _emptyTiming() internal pure returns (Slim.TimingBoundaries memory) {
        return
            Slim.TimingBoundaries({blockNumber: 0, blockNumberBound: 0, blockTimestamp: 0, blockTimestampBound: 0});
    }

    function _oracleCaller() internal returns (address) {
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        if (mode == VmSafe.CallerMode.Prank || mode == VmSafe.CallerMode.RecurrentPrank) return sender;
        return address(this);
    }

    // Default params for ERC20-pair, time-typed reports with no fancy flags.
    function _defaultParams() internal view returns (CompatTypes.CreateReportParams memory) {
        return CompatTypes.CreateReportParams({
            escalationHalt: 10e18,
            settlerReward: 0.001 ether,
            token1Address: address(token1),
            settlementTime: uint48(300),
            disputeDelay: uint24(5),
            protocolFee: uint24(1000),
            token2Address: address(token2),
            callbackGasLimit: 0,
            feePercentage: uint24(3000),
            multiplier: uint16(110),
            callbackContract: address(0),
            protocolFeeRecipient: protocolFeeRecipient,
            flags: FLAG_TIME_TYPE
        });
    }

    // Mirrors the contract's _hashOracle (just keccak of abi.encode).
    function _hashOracle(Slim.OracleGame memory game, Slim.PreimageHelper memory helper)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(game, helper));
    }

    // Build the OracleGame struct as it exists immediately after `report()`.
    // Caller provides the (reportTimestamp, oppoTime) captured at report time.
    function _gameAfterReport(
        CompatTypes.CreateReportParams memory params,
        uint128 amount1,
        uint128 amount2,
        address reporter,
        uint48 reportTimestamp,
        uint48 oppoTime
    ) internal pure returns (Slim.OracleGame memory g) {
        g.token1 = params.token1Address;
        g.token2 = params.token2Address;
        g.feePercentage = params.feePercentage;
        g.multiplier = params.multiplier;
        g.settlementTime = params.settlementTime;
        g.escalationHalt = params.escalationHalt;
        g.disputeDelay = params.disputeDelay;
        g.protocolFee = params.protocolFee;
        g.settlerReward = params.settlerReward;
        g.callbackContract = params.callbackContract;
        g.callbackGasLimit = params.callbackGasLimit;
        g.protocolFeeRecipient = params.protocolFeeRecipient;
        g.flags = params.flags;
        g.currentAmount1 = amount1;
        g.currentAmount2 = amount2;
        g.currentReporter = reporter;
        g.reportTimestamp = reportTimestamp;
        g.lastReportOppoTime = oppoTime;
        if ((params.flags & FLAG_TRACK_DISPUTES) != 0) {
            g.numReports = 1;
        }
        // settlementTimestamp = 0 (default)
    }

    // Apply a dispute mutation to a game struct.
    function _gameAfterDispute(
        Slim.OracleGame memory prev,
        uint128 newAmount1,
        uint128 newAmount2,
        address disputer,
        uint48 currentTime,
        uint48 oppoTime
    ) internal pure returns (Slim.OracleGame memory g) {
        g = prev;
        g.currentAmount1 = newAmount1;
        g.currentAmount2 = newAmount2;
        g.currentReporter = disputer;
        g.reportTimestamp = currentTime;
        g.lastReportOppoTime = oppoTime;
        if ((g.flags & FLAG_TRACK_DISPUTES) != 0 && g.numReports < type(uint24).max) {
            g.numReports = g.numReports + 1;
        }
    }

    // Apply a settle mutation to a game struct.
    function _gameAfterSettle(Slim.OracleGame memory prev, uint48 currentTime)
        internal
        pure
        returns (Slim.OracleGame memory g)
    {
        g = prev;
        g.settlementTimestamp = currentTime;
    }

    // Compute the ETH side amount that msg.value must cover (in addition to settlerReward).
    function _ethSide(CompatTypes.CreateReportParams memory params, uint128 amount1, uint128 amount2)
        internal
        pure
        returns (uint256)
    {
        if (params.token1Address == ETH_SENTINEL) return amount1;
        if (params.token2Address == ETH_SENTINEL) return amount2;
        return 0;
    }

    // Compute (reportTimestamp, oppoTime) given the timeType flag and current block context.
    function _timestamps(uint8 flags) internal view returns (uint48 reportTimestamp, uint48 oppoTime) {
        bool timeType = (flags & FLAG_TIME_TYPE) != 0;
        reportTimestamp = timeType ? uint48(block.timestamp) : uint48(block.number);
        oppoTime = timeType ? uint48(block.number) : uint48(block.timestamp);
    }

    // Mirrors the pre-hash-refactor oracle.report() signature for tests written before the
    // OracleGame-calldata refactor. Delegates to CompatTypes.reportRaw().
    function _oracleReport(
        uint256 value,
        CompatTypes.CreateReportParams memory params,
        uint128 amount1,
        uint128 amount2,
        address reporter,
        bool tib1,
        bool tib2,
        Slim.TimingBoundaries memory timing
    ) internal returns (uint256 reportId) {
        return CompatTypes.reportRaw(oracle, value, params, amount1, amount2, reporter, tib1, tib2, timing);
    }

    // Wrapper: call report(), capture preimage. msg.sender is the caller (or pranked).
    // Translates the convenience CompatTypes.CreateReportParams + amounts + reporter into the new
    // oracle.report's OracleGame-calldata input. Reportable-by-contract fields
    // (reportTimestamp / lastReportOppoTime / settlementTimestamp / numReports) are left zero
    // — oracle.report validates and overrides them.
    function _report(
        CompatTypes.CreateReportParams memory params,
        uint128 amount1,
        uint128 amount2,
        address reporter,
        bool tib1,
        bool tib2
    ) internal returns (ReportContext memory ctx) {
        address creator = _oracleCaller();
        uint256 createTs = block.timestamp;
        uint256 createBn = block.number;
        (uint48 rts, uint48 oppo) = _timestamps(params.flags);
        uint256 value = uint256(params.settlerReward) + _ethSide(params, amount1, amount2);

        Slim.OracleGame memory input;
        input.token1 = params.token1Address;
        input.token2 = params.token2Address;
        input.feePercentage = params.feePercentage;
        input.multiplier = params.multiplier;
        input.settlementTime = params.settlementTime;
        input.escalationHalt = params.escalationHalt;
        input.disputeDelay = params.disputeDelay;
        input.protocolFee = params.protocolFee;
        input.settlerReward = params.settlerReward;
        input.callbackContract = params.callbackContract;
        input.callbackGasLimit = params.callbackGasLimit;
        input.protocolFeeRecipient = params.protocolFeeRecipient;
        input.flags = params.flags;
        input.currentAmount1 = amount1;
        input.currentAmount2 = amount2;
        input.currentReporter = reporter;
        // reportTimestamp / lastReportOppoTime / settlementTimestamp / numReports = 0

        ctx.reportId = oracle.report{value: value}(input, tib1, tib2, _emptyTiming());

        ctx.game = _gameAfterReport(params, amount1, amount2, reporter, rts, oppo);
        ctx.helper = Slim.PreimageHelper({
            reportId: ctx.reportId,
            creator: creator,
            blockTimestamp: createTs,
            blockNumber: createBn
        });
    }

    // Convenience: reporter = _oracleCaller().
    function _report(CompatTypes.CreateReportParams memory params, uint128 amount1, uint128 amount2, bool tib1, bool tib2)
        internal
        returns (ReportContext memory)
    {
        return _report(params, amount1, amount2, _oracleCaller(), tib1, tib2);
    }

    // Wrapper: call dispute(), update ctx.game in place to reflect new state.
    function _dispute(
        ReportContext memory ctx,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        address disputer,
        bool tib1,
        bool tib2,
        uint256 ethValue
    ) internal returns (ReportContext memory) {
        (uint48 ct, uint48 oppo) = _timestamps(ctx.game.flags);

        oracle.dispute{value: ethValue}(
            ctx.reportId,
            tokenToSwap,
            newAmount1,
            newAmount2,
            disputer,
            tib1,
            tib2,
            ctx.game,
            ctx.helper,
            _emptyTiming()
        );

        ctx.game = _gameAfterDispute(ctx.game, newAmount1, newAmount2, disputer, ct, oppo);
        return ctx;
    }

    // Convenience: disputer = _oracleCaller(), value = 0 (ERC20 pair).
    function _dispute(
        ReportContext memory ctx,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        bool tib1,
        bool tib2
    ) internal returns (ReportContext memory) {
        return _dispute(ctx, tokenToSwap, newAmount1, newAmount2, _oracleCaller(), tib1, tib2, 0);
    }

    // Wrapper: call settle(), update ctx.game.
    function _settle(ReportContext memory ctx) internal returns (ReportContext memory) {
        (uint48 ct,) = _timestamps(ctx.game.flags);
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);
        ctx.game = _gameAfterSettle(ctx.game, ct);
        return ctx;
    }

    // Read internal token holder balance (raw, includes sentinel).
    function _heldTokens(address user, address token) internal view returns (uint256) {
        return oracle.tokenHolder(user, token);
    }
}
