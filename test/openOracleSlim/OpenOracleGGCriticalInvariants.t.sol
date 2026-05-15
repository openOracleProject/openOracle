// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {CompatTypes} from "./CompatTypes.sol";
import "forge-std/StdInvariant.sol";
import "forge-std/Vm.sol";

import {OpenOracle as Slim} from "../../src/OpenOracleSlim.sol";
import {MockERC20} from "../utils/MockERC20.sol";

// Records callback execution for callback-related invariants.
contract TestCallback {
    struct Execution {
        bool called;
        uint256 gasReceived;
        uint256 reportId;
        uint256 timestamp;
    }

    mapping(uint256 => Execution) public executions;
    mapping(uint256 => uint256) public executionCount;

    function openOracleCallback(uint256 reportId, uint256, uint256, uint256, address, address) external {
        executions[reportId] = Execution({
            called: true,
            gasReceived: gasleft(),
            reportId: reportId,
            timestamp: block.timestamp
        });
        executionCount[reportId]++;
    }
}

// Calldata-mode-only handler for OpenOracleSlim.
//
// Since OpenOracleSlim stores only stateHash on-chain, the handler maintains
// its own preimage state (game struct + helper) per report, updates it on
// each successful op, and uses it for subsequent dispute/settle calls.
contract InvariantHandler {
    Vm public constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    Slim public immutable oracle;
    MockERC20 public immutable token1;
    MockERC20 public immutable token2;
    TestCallback public immutable callback;

    uint96 public constant SETTLER_REWARD = 0.001 ether;
    uint32 public constant CALLBACK_GAS_LIMIT = 200_000;
    uint8 internal constant FLAG_TIME_TYPE = 1 << 0;

    uint256[] public reportIds;
    mapping(uint256 => bool) public hasSettled;

    // Per-report preimage state (handler-tracked).
    mapping(uint256 => Slim.OracleGame) internal _games;
    mapping(uint256 => Slim.PreimageHelper) internal _helpers;

    constructor(Slim _oracle, MockERC20 _t1, MockERC20 _t2, TestCallback _cb) {
        oracle = _oracle;
        token1 = _t1;
        token2 = _t2;
        callback = _cb;
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
    }

    receive() external payable {}

    function reportCount() external view returns (uint256) {
        return reportIds.length;
    }

    function getReportId(uint256 idx) public view returns (uint256) {
        if (reportIds.length == 0) return 0;
        return reportIds[idx % reportIds.length];
    }

    function callbackContractFor(uint256 reportId) external view returns (address) {
        return _games[reportId].callbackContract;
    }

    function callbackGasLimitFor(uint256 reportId) external view returns (uint32) {
        return _games[reportId].callbackGasLimit;
    }

    function settlementTimestampFor(uint256 reportId) external view returns (uint48) {
        return _games[reportId].settlementTimestamp;
    }

    function _emptyTiming() internal pure returns (Slim.TimingBoundaries memory t) {}

    function _defaultParams() internal view returns (CompatTypes.CreateReportParams memory) {
        return CompatTypes.CreateReportParams({
            escalationHalt: 10e18,
            settlerReward: SETTLER_REWARD,
            token1Address: address(token1),
            settlementTime: uint48(60),
            disputeDelay: 0,
            protocolFee: uint24(1000),
            token2Address: address(token2),
            callbackGasLimit: CALLBACK_GAS_LIMIT,
            feePercentage: uint24(3000),
            multiplier: uint16(110),
            callbackContract: address(callback),
            protocolFeeRecipient: address(this),
            flags: FLAG_TIME_TYPE
        });
    }

    function createReport() external {
        CompatTypes.CreateReportParams memory p = _defaultParams();
        uint128 amount1 = 1e18;
        uint128 amount2 = 1e18;
        uint256 createTs = block.timestamp;
        uint256 createBn = block.number;

        uint256 id = CompatTypes.reportRaw(oracle, SETTLER_REWARD, 
            p, amount1, amount2, address(this), false, false, _emptyTiming()
        );

        // Build the post-report preimage state.
        Slim.OracleGame memory g;
        g.token1 = p.token1Address;
        g.token2 = p.token2Address;
        g.feePercentage = p.feePercentage;
        g.multiplier = p.multiplier;
        g.settlementTime = p.settlementTime;
        g.escalationHalt = p.escalationHalt;
        g.disputeDelay = p.disputeDelay;
        g.protocolFee = p.protocolFee;
        g.settlerReward = p.settlerReward;
        g.callbackContract = p.callbackContract;
        g.callbackGasLimit = p.callbackGasLimit;
        g.protocolFeeRecipient = p.protocolFeeRecipient;
        g.flags = p.flags;
        g.currentAmount1 = amount1;
        g.currentAmount2 = amount2;
        g.currentReporter = payable(address(this));
        g.reportTimestamp = uint48(block.timestamp);
        g.lastReportOppoTime = uint48(block.number);

        Slim.PreimageHelper memory h = Slim.PreimageHelper({
            reportId: id,
            creator: address(this),
            blockTimestamp: createTs,
            blockNumber: createBn
        });

        _games[id] = g;
        _helpers[id] = h;
        reportIds.push(id);
    }

    function dispute(uint256 idSeed) external {
        if (reportIds.length == 0) return;
        uint256 reportId = getReportId(idSeed);
        if (reportId == 0) return;
        if (_games[reportId].settlementTimestamp != 0) return;
        if (_games[reportId].currentAmount1 == 0) return;

        Slim.OracleGame memory g = _games[reportId];
        uint128 oldA1 = g.currentAmount1;
        uint128 oldA2 = g.currentAmount2;

        // Compute next amount1 per escalation rules (multiplier=110, halt=10e18).
        uint256 nextA1;
        if (oldA1 >= g.escalationHalt) {
            nextA1 = uint256(oldA1) + 1;
        } else {
            uint256 scaled = (uint256(oldA1) * uint256(g.multiplier)) / 100;
            nextA1 = scaled > uint256(g.escalationHalt) ? uint256(g.escalationHalt) : scaled;
        }
        // Choose newAmount2 to be ~1% lower for fee-boundary compliance.
        uint256 newA2 = oldA2 > 100 ? (uint256(oldA2) * 99) / 100 : uint256(oldA2) + 1;

        Slim.PreimageHelper memory h = _helpers[reportId];

        try oracle.dispute(
            reportId,
            address(token1),
            uint128(nextA1),
            uint128(newA2),
            address(this),
            false,
            false,
            g,
            h,
            _emptyTiming()
        ) {
            // Update tracked state to post-dispute.
            g.currentAmount1 = uint128(nextA1);
            g.currentAmount2 = uint128(newA2);
            g.currentReporter = payable(address(this));
            g.reportTimestamp = uint48(block.timestamp);
            g.lastReportOppoTime = uint48(block.number);
            _games[reportId] = g;
        } catch {}
    }

    function settle(uint256 idSeed, uint256 gasSeed) external {
        if (reportIds.length == 0) return;
        uint256 reportId = getReportId(idSeed);
        if (reportId == 0) return;
        if (_games[reportId].settlementTimestamp != 0) return;
        if (_games[reportId].currentAmount1 == 0) return;

        Slim.OracleGame memory g = _games[reportId];
        Slim.PreimageHelper memory h = _helpers[reportId];

        if (g.reportTimestamp == 0) return;
        if (block.timestamp < uint256(g.reportTimestamp) + uint256(g.settlementTime)) {
            vm.warp(uint256(g.reportTimestamp) + uint256(g.settlementTime) + 1);
        }

        uint256 gasAmt = 60_000 + (gasSeed % 600_000);
        try oracle.settle{gas: gasAmt}(reportId, g, h) {
            g.settlementTimestamp = uint48(block.timestamp);
            _games[reportId] = g;
            hasSettled[reportId] = true;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + ((dt % 3600) + 1));
    }
}

// Critical invariants ported from CriticalInvariants.t.sol.
// In OpenOracleSlim, "isDistributed" maps to "settlementTimestamp != 0".
contract OpenOracleGGCriticalInvariantsTest is StdInvariant, Test {
    Slim internal oracle;
    MockERC20 internal token1;
    MockERC20 internal token2;
    TestCallback internal callback;
    InvariantHandler internal handler;

    function setUp() public {
        oracle = new Slim();
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");
        callback = new TestCallback();

        handler = new InvariantHandler(oracle, token1, token2, callback);

        token1.transfer(address(handler), 200_000 ether);
        token2.transfer(address(handler), 200_000 ether);
        vm.deal(address(handler), 100 ether);

        targetContract(address(handler));

        handler.createReport();
        handler.warp(120);
    }

    // Invariant: callback must have been invoked if settlement happened with a callback configured.
    function invariant_fullAttemptOnDistribution() public view {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            address cb = handler.callbackContractFor(reportId);
            uint48 settlementTs = handler.settlementTimestampFor(reportId);
            if (cb != address(0) && settlementTs != 0) {
                (bool called,,,) = callback.executions(reportId);
                assertTrue(called, "callback not called on settled report");
            }
        }
    }

    // Invariant: callback observed as called -> settlementTimestamp != 0.
    function invariant_atomicityCallbackImpliesSettled() public view {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            (bool called,,,) = callback.executions(reportId);
            if (called) {
                assertTrue(handler.settlementTimestampFor(reportId) != 0, "callback called while not settled");
            }
        }
    }

    // Invariant: callback invoked at most once per report.
    function invariant_callbackAtMostOnce() public view {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            uint256 times = callback.executionCount(reportId);
            assertLe(times, 1, "callback executed more than once");
        }
    }

    // Invariant: callback gas observed never exceeds the configured limit.
    function invariant_callbackGasRespectsLimit() public view {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            address cb = handler.callbackContractFor(reportId);
            uint32 cbGasLimit = handler.callbackGasLimitFor(reportId);
            uint48 settlementTs = handler.settlementTimestampFor(reportId);
            if (cb != address(0) && settlementTs != 0) {
                (bool called, uint256 gasReceived,,) = callback.executions(reportId);
                if (called && cbGasLimit > 0) {
                    assertLe(gasReceived, uint256(cbGasLimit), "callback gas exceeded limit");
                }
            }
        }
    }

    // Invariant: settlementTimestamp set only after a successful settle call (handler-recorded).
    function invariant_settlementOnlyAfterSettle() public view {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            uint48 settlementTs = handler.settlementTimestampFor(reportId);
            if (settlementTs != 0) {
                assertTrue(handler.hasSettled(reportId), "settlement set without handler-settle");
            }
        }
    }
}
