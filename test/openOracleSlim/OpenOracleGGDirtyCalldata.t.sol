// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {CompatTypes} from "./CompatTypes.sol";

/// @notice Locks down that Solidity 0.8.28's strict ABI v2 decoder rejects dirty
///         high-padding bits in sub-256-bit calldata fields of OracleGame, preventing the
///         "calldatacopy preserves dirty bits → stored hash diverges from abi.encode hash"
///         self-DoS finding. If any of these reverts stop happening on a compiler upgrade,
///         the assembly hash path in OpenOracleSlim.report() needs explicit masking.
contract OpenOracleGGDirtyCalldataTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
    }

    function _buildCleanInputGame() internal view returns (Slim.OracleGame memory g) {
        CompatTypes.CreateReportParams memory p = _defaultParams();
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
        g.currentAmount1 = 1e18;
        g.currentAmount2 = 2000e18;
        g.currentReporter = alice;
        // reportTimestamp / lastReportOppoTime / settlementTimestamp / numReports = 0
    }

    /// @dev Build clean abi-encoded oracle.report() call, then set byte at `byteOffset`
    ///      (from start of args, post-selector) to `dirtyByte`. Low-level call. Returns ok.
    function _reportWithDirtyByte(uint256 byteOffset, uint8 dirtyByte) internal returns (bool ok) {
        Slim.OracleGame memory g = _buildCleanInputGame();
        Slim.TimingBoundaries memory timing = _emptyTiming();
        bytes memory data = abi.encodeCall(oracle.report, (g, false, false, timing));
        // Selector at bytes 0..3. Args start at byte 4.
        data[4 + byteOffset] = bytes1(dirtyByte);

        vm.prank(alice);
        (ok,) = address(oracle).call{value: g.settlerReward}(data);
    }

    /// @dev Control: clean call must succeed.
    function testDirtyCalldata_CleanCallSucceeds() public {
        Slim.OracleGame memory g = _buildCleanInputGame();
        bytes memory data = abi.encodeCall(oracle.report, (g, false, false, _emptyTiming()));
        vm.prank(alice);
        (bool ok,) = address(oracle).call{value: g.settlerReward}(data);
        assertTrue(ok, "clean abi.encodeCall must succeed");
    }

    // OracleGame memory layout (matches abi.encode):
    //   slot 0  (offset 0x000)  currentAmount1        uint128
    //   slot 1  (offset 0x020)  currentAmount2        uint128
    //   slot 2  (offset 0x040)  currentReporter       address
    //   slot 3  (offset 0x060)  reportTimestamp       uint48  (must be 0)
    //   slot 4  (offset 0x080)  settlementTimestamp   uint48  (must be 0)
    //   slot 5  (offset 0x0A0)  token1                address
    //   slot 6  (offset 0x0C0)  lastReportOppoTime    uint48  (must be 0)
    //   slot 7  (offset 0x0E0)  settlementTime        uint48
    //   slot 8  (offset 0x100)  escalationHalt        uint128
    //   slot 9  (offset 0x120)  protocolFeeRecipient  address
    //   slot 10 (offset 0x140)  settlerReward         uint96
    //   slot 11 (offset 0x160)  token2                address
    //   slot 12 (offset 0x180)  numReports            uint24  (must be 0)
    //   slot 13 (offset 0x1A0)  disputeDelay          uint24
    //   slot 14 (offset 0x1C0)  feePercentage         uint24
    //   slot 15 (offset 0x1E0)  multiplier            uint16
    //   slot 16 (offset 0x200)  callbackContract      address
    //   slot 17 (offset 0x220)  callbackGasLimit      uint32
    //   slot 18 (offset 0x240)  protocolFee           uint24
    //   slot 19 (offset 0x260)  flags                 uint8

    function testDirtyCalldata_RevertsDirtyUint128CurrentAmount1() public {
        // uint128 currentAmount1 at slot 0. Byte 0 of slot = high padding.
        assertFalse(_reportWithDirtyByte(0x00, 0xff), "dirty uint128 high padding must revert");
    }

    function testDirtyCalldata_RevertsDirtyAddressCurrentReporter() public {
        // address currentReporter at slot 2 (offset 0x40). High 12 bytes = padding.
        assertFalse(_reportWithDirtyByte(0x40, 0xff), "dirty address high padding must revert");
    }

    function testDirtyCalldata_RevertsDirtyUint48SettlementTime() public {
        // uint48 settlementTime at slot 7 (offset 0xE0). High 26 bytes = padding.
        assertFalse(_reportWithDirtyByte(0xE0, 0xff), "dirty uint48 high padding must revert");
    }

    function testDirtyCalldata_RevertsDirtyUint96SettlerReward() public {
        // uint96 settlerReward at slot 10 (offset 0x140). High 20 bytes = padding.
        assertFalse(_reportWithDirtyByte(0x140, 0xff), "dirty uint96 high padding must revert");
    }

    function testDirtyCalldata_RevertsDirtyUint24DisputeDelay() public {
        // uint24 disputeDelay at slot 13 (offset 0x1A0). High 29 bytes = padding.
        assertFalse(_reportWithDirtyByte(0x1A0, 0xff), "dirty uint24 high padding must revert");
    }

    // These fields are only needed by later dispute/settle paths, but report()
    // deliberately touches them before its raw calldatacopy hash so dirty high
    // bits cannot poison the stored state hash.

    function testDirtyCalldata_RevertsDirtyUint32CallbackGasLimit() public {
        assertFalse(_reportWithDirtyByte(0x220, 0xff), "dirty uint32 callbackGasLimit must revert");
    }

    function testDirtyCalldata_RevertsDirtyUint128EscalationHalt() public {
        assertFalse(_reportWithDirtyByte(0x100, 0xff), "dirty uint128 escalationHalt must revert");
    }

    function testDirtyCalldata_RevertsDirtyAddressCallbackContract() public {
        assertFalse(_reportWithDirtyByte(0x200, 0xff), "dirty address callbackContract must revert");
    }

    function testDirtyCalldata_RevertsDirtyUint8Flags() public {
        // uint8 flags at slot 19 (offset 0x260). Value at byte 31; high 31 bytes = padding.
        // (Setting byte 31 to 0x10 would pass decoder but hit InvalidMode — different path.
        //  Setting a high byte tests the decoder specifically.)
        assertFalse(_reportWithDirtyByte(0x260, 0xff), "dirty uint8 high padding must revert");
    }
}
