// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "forge-std/Vm.sol";

import {OpenOracle as OpenOracleGG} from "../../src/OpenOracleGasGolfing_ContractSizeLimit2.sol";
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

    function onOracleSettle(uint256 reportId, uint256, uint256, address, address) external {
        executions[reportId] = Execution({
            called: true,
            gasReceived: gasleft(),
            reportId: reportId,
            timestamp: block.timestamp
        });
        executionCount[reportId]++;
    }
}

contract InvariantHandler {
    Vm public constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    OpenOracleGG public immutable oracle;
    MockERC20 public immutable token1;
    MockERC20 public immutable token2;
    TestCallback public immutable callback;

    uint96 public constant ORACLE_FEE = 0.01 ether;
    uint96 public constant SETTLER_REWARD = 0.001 ether;
    uint32 public constant CALLBACK_GAS_LIMIT = 200_000;

    uint256 internal constant ORACLE_GAME_SLOT = 1;

    uint256[] public reportIds;
    mapping(uint256 => bool) public hasSettled;

    constructor(OpenOracleGG _oracle, MockERC20 _t1, MockERC20 _t2, TestCallback _cb) {
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

    function _stateHash(uint256 reportId) internal view returns (bytes32) {
        return vm.load(address(oracle), keccak256(abi.encode(reportId, ORACLE_GAME_SLOT)));
    }

    function _readSettlementTimestamp(uint256 reportId) public view returns (uint48) {
        // OracleGame layout (storage):
        //   slot+0: stateHash (bytes32)
        //   slot+1: currentAmount1 (u128) | currentAmount2 (u128)
        //   slot+2: currentReporter (160) | reportTimestamp (48) | settlementTimestamp (48)
        bytes32 base = keccak256(abi.encode(reportId, ORACLE_GAME_SLOT));
        bytes32 packed = vm.load(address(oracle), bytes32(uint256(base) + 2));
        // settlementTimestamp at offset 160+48 = 208 bits.
        return uint48(uint256(packed) >> 208);
    }

    function _emptyTiming() internal pure returns (OpenOracleGG.TimingBoundaries memory t) {}

    function createReport() external {
        uint256 id = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracleGG.CreateReportParams({
                exactToken1Report: 1e18,
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
                timeType: true,
                trackDisputes: false,
                callbackContract: address(callback),
                callbackSelector: TestCallback.onOracleSettle.selector,
                protocolFeeRecipient: address(this)
            }),
            true
        );
        reportIds.push(id);
    }

    function submitInitial(uint256 idSeed) external {
        if (reportIds.length == 0) return;
        uint256 reportId = getReportId(idSeed);
        if (reportId == 0) return;
        if (oracle.tokenHolder(address(this), address(token1)) > 0 && _alreadySubmitted(reportId)) return;
        if (_alreadySubmitted(reportId)) return;
        bytes32 sh = _stateHash(reportId);
        try oracle.submitInitialReport(reportId, 1e18, 1e18, sh, address(this), false, false, _emptyTiming()) {} catch {}
    }

    function dispute(uint256 idSeed) external {
        if (reportIds.length == 0) return;
        uint256 reportId = getReportId(idSeed);
        if (reportId == 0) return;
        if (!_alreadySubmitted(reportId)) return;
        if (_readSettlementTimestamp(reportId) != 0) return;

        // Read current amounts.
        bytes32 base = keccak256(abi.encode(reportId, ORACLE_GAME_SLOT));
        bytes32 packed = vm.load(address(oracle), bytes32(uint256(base) + 1));
        uint128 oldA1 = uint128(uint256(packed));
        uint128 oldA2 = uint128(uint256(packed) >> 128);
        if (oldA1 == 0) return;

        // Compute next amount1 per escalation rules. Hardcoded multiplier=110, halt=10e18.
        uint256 nextA1;
        if (oldA1 >= 10e18) {
            nextA1 = uint256(oldA1) + 1;
        } else {
            uint256 scaled = (uint256(oldA1) * 110) / 100;
            nextA1 = scaled > 10e18 ? 10e18 : scaled;
        }
        // Choose newAmount2 to be ~1% lower for fee-boundary compliance.
        uint256 newA2 = oldA2 > 100 ? (uint256(oldA2) * 99) / 100 : uint256(oldA2) + 1;

        bytes32 sh = _stateHash(reportId);
        try oracle.disputeAndSwap(
            reportId,
            address(token1),
            uint128(nextA1),
            uint128(newA2),
            address(this),
            oldA2,
            sh,
            false,
            false,
            _emptyTiming()
        ) {} catch {}
    }

    function settle(uint256 idSeed, uint256 gasSeed) external {
        if (reportIds.length == 0) return;
        uint256 reportId = getReportId(idSeed);
        if (reportId == 0) return;
        if (_readSettlementTimestamp(reportId) != 0) return;
        if (!_alreadySubmitted(reportId)) return;

        // Read reportTimestamp.
        bytes32 base = keccak256(abi.encode(reportId, ORACLE_GAME_SLOT));
        bytes32 packed = vm.load(address(oracle), bytes32(uint256(base) + 2));
        uint48 reportTs = uint48(uint256(packed) >> 160);
        if (reportTs == 0) return;
        if (block.timestamp < uint256(reportTs) + 60) {
            vm.warp(uint256(reportTs) + 60 + 1);
        }

        uint256 gasAmt = 60_000 + (gasSeed % 600_000);
        try oracle.settle{gas: gasAmt}(reportId) {
            hasSettled[reportId] = true;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + ((dt % 3600) + 1));
    }

    function _alreadySubmitted(uint256 reportId) internal view returns (bool) {
        bytes32 base = keccak256(abi.encode(reportId, ORACLE_GAME_SLOT));
        bytes32 packed = vm.load(address(oracle), bytes32(uint256(base) + 1));
        uint128 currentA1 = uint128(uint256(packed));
        return currentA1 != 0;
    }
}

// Critical invariants ported from CriticalInvariants.t.sol.
// In gas-golfing, "isDistributed" maps to "settlementTimestamp != 0".
contract OpenOracleGGCriticalInvariantsTest is StdInvariant, Test {
    OpenOracleGG internal oracle;
    MockERC20 internal token1;
    MockERC20 internal token2;
    TestCallback internal callback;
    InvariantHandler internal handler;

    uint256 internal constant ORACLE_GAME_SLOT = 1;

    function setUp() public {
        oracle = new OpenOracleGG();
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");
        callback = new TestCallback();

        handler = new InvariantHandler(oracle, token1, token2, callback);

        token1.transfer(address(handler), 200_000 ether);
        token2.transfer(address(handler), 200_000 ether);
        vm.deal(address(handler), 100 ether);

        targetContract(address(handler));

        handler.createReport();
        handler.submitInitial(0);
        handler.warp(120);
    }

    function _readSettlementTimestamp(uint256 reportId) internal view returns (uint48) {
        bytes32 base = keccak256(abi.encode(reportId, ORACLE_GAME_SLOT));
        bytes32 packed = vm.load(address(oracle), bytes32(uint256(base) + 2));
        return uint48(uint256(packed) >> 208);
    }

    function _readCallbackContract(uint256 reportId) internal view returns (address cb, uint32 cbGasLimit) {
        // OracleGame layout offsets continued:
        //   slot+8: callbackContract (160) | numReports (32) | callbackGasLimit (32) | callbackSelector (32)
        // Let me recompute from the struct field order:
        //   stateHash (32) -> slot 0
        //   currentAmount1+currentAmount2 (16+16) -> slot 1
        //   currentReporter (20) + reportTimestamp (6) + settlementTimestamp (6) -> slot 2
        //   initialReporter (20) + lastReportOppoTime (6) -> slot 3
        //   exactToken1Report (16) + escalationHalt (16) -> slot 4
        //   fee (12) + settlerReward (12) -> slot 5
        //   token1 (20) + settlementTime (6) -> slot 6
        //   token2 (20) + timeType (1) + feePercentage (3) + protocolFee (3) + multiplier (2) + disputeDelay (3) -> slot 7
        //   callbackContract (20) + numReports (4) + callbackGasLimit (4) + callbackSelector (4) -> slot 8
        //   protocolFeeRecipient (20) + trackDisputes (1) -> slot 9
        bytes32 base = keccak256(abi.encode(reportId, ORACLE_GAME_SLOT));
        bytes32 packed = vm.load(address(oracle), bytes32(uint256(base) + 8));
        cb = address(uint160(uint256(packed)));
        cbGasLimit = uint32(uint256(packed) >> (160 + 32));
    }

    // Invariant: callback must have been invoked if settlement happened with a callback configured.
    function invariant_fullAttemptOnDistribution() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            (address cb,) = _readCallbackContract(reportId);
            uint48 settlementTs = _readSettlementTimestamp(reportId);
            if (cb != address(0) && settlementTs != 0) {
                (bool called,,,) = callback.executions(reportId);
                assertTrue(called, "callback not called on settled report");
            }
        }
    }

    // Invariant: callback observed as called -> settlementTimestamp != 0.
    function invariant_atomicityCallbackImpliesSettled() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            (bool called,,,) = callback.executions(reportId);
            if (called) {
                assertTrue(_readSettlementTimestamp(reportId) != 0, "callback called while not settled");
            }
        }
    }

    // Invariant: callback invoked at most once per report.
    function invariant_callbackAtMostOnce() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            uint256 times = callback.executionCount(reportId);
            assertLe(times, 1, "callback executed more than once");
        }
    }

    // Invariant: callback gas observed never exceeds the configured limit.
    function invariant_callbackGasRespectsLimit() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            (address cb, uint32 cbGasLimit) = _readCallbackContract(reportId);
            uint48 settlementTs = _readSettlementTimestamp(reportId);
            if (cb != address(0) && settlementTs != 0) {
                (bool called, uint256 gasReceived,,) = callback.executions(reportId);
                if (called && cbGasLimit > 0) {
                    assertLe(gasReceived, uint256(cbGasLimit), "callback gas exceeded limit");
                }
            }
        }
    }

    // Invariant: settlementTimestamp set only after a successful settle call (handler-recorded).
    function invariant_settlementOnlyAfterSettle() public {
        uint256 count = handler.reportCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 reportId = handler.getReportId(i);
            if (reportId == 0) continue;
            uint48 settlementTs = _readSettlementTimestamp(reportId);
            if (settlementTs != 0) {
                assertTrue(handler.hasSettled(reportId), "settlement set without handler-settle");
            }
        }
    }
}
