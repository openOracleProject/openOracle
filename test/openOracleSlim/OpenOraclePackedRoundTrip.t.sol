// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import "../utils/PackedDecoder.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";

/// @notice Layout-pinning round-trip tests for the packed ReportSubmitted and
///         ReportDisputed events. Uses high-entropy non-default values for every
///         narrow field so any silent offset drift surfaces as a field-level
///         assertEq failure.
contract OpenOraclePackedRoundTripTest is BaseGGTest {
    bytes32 internal constant REPORT_SUBMITTED_SIG = keccak256("ReportSubmitted(uint256,bytes)");
    bytes32 internal constant REPORT_DISPUTED_SIG  = keccak256("ReportDisputed(uint256,bytes)");

    function setUp() public override {
        BaseGGTest.setUp();
        // Top up: alice funds currentAmount1/2 (~1.5e23 token1 worst case after escalation cap),
        // bob funds newAmount1 + oldAmount1 + fees on dispute (~3e23 worst case).
        // Total supply per token = 1e24; this leaves ~6e23 in the test contract.
        token1.transfer(alice, 1e23);
        token2.transfer(alice, 1e23);
        token1.transfer(bob,   3e23);
        token2.transfer(bob,   1e23);
        vm.deal(alice, 1e27);
        vm.deal(bob,   1e27);
    }

    function _highEntropyInput() internal view returns (Slim.OracleGame memory g) {
        // High-entropy, distinct values per field. Each value fits within both the
        // declared type AND the available balance (1e23 tokens, 1e27 ETH for alice/bob).
        // Validation-compliant:
        //   - currentAmount1 > 0, currentAmount2 > 0
        //   - escalationHalt >= currentAmount1
        //   - settlementTime > disputeDelay
        //   - feePercentage + protocolFee <= 1e7
        //   - multiplier >= 100 (MULTIPLIER_PRECISION)
        //   - reportTimestamp / settlementTimestamp / lastReportOppoTime / numReports = 0 at input
        //   - flags <= FLAGS_MAX (0x0F)
        g.currentAmount1       = uint128(0x010203040506070809);                     // ~7.4e19 wei
        g.currentAmount2       = uint128(0x1112131415161718191a);                   // ~7.9e22 wei, distinct
        g.currentReporter      = alice;
        g.reportTimestamp      = 0;
        g.settlementTimestamp  = 0;
        g.token1               = address(token1);
        g.lastReportOppoTime   = 0;
        g.settlementTime       = uint48(0x21222324252e);                            // 6 bytes
        g.escalationHalt       = uint128(0x313233343536373839ff);                   // > currentAmount1
        // 20-byte address literal (sub-checksum; explicit cast via uint160)
        g.protocolFeeRecipient = address(uint160(0x4142434445464748495051525354555657585960));
        g.settlerReward        = uint96(0x616263640506070809aa);                    // ~4.6e23 wei, fits in 1e27
        g.token2               = address(token2);
        g.numReports           = 0;
        g.disputeDelay         = uint24(0x7a7b7c);                                  // 3 bytes
        g.feePercentage        = uint24(0x002710);                                  // 10_000
        g.multiplier           = uint16(0x0bb8);                                    // 3_000
        g.callbackContract     = address(0);
        g.callbackGasLimit     = uint32(0xdeadbeef);
        g.protocolFee          = uint24(0x002328);                                  // 9_000 ; sum 19k <= 1e7 ✓
        g.flags                = uint8(FLAG_TIME_TYPE | FLAG_TRACK_DISPUTES);       // 0x03
    }

    function _findPackedLog(Vm.Log[] memory logs, bytes32 sig)
        internal
        pure
        returns (uint256 reportId, bytes memory packed)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == sig) {
                reportId = uint256(logs[i].topics[1]);
                packed = logs[i].data;
                return (reportId, packed);
            }
        }
        revert("packed event not found");
    }

    function testRoundTrip_ReportSubmitted_DecodesAllFields() public {
        Slim.OracleGame memory input = _highEntropyInput();
        uint256 valueToSend = uint256(input.settlerReward);
        vm.recordLogs();
        vm.prank(alice);
        uint256 reportId = oracle.report{value: valueToSend}(input, false, false, _emptyTiming());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 topicRid, bytes memory packed) = _findPackedLog(logs, REPORT_SUBMITTED_SIG);
        assertEq(topicRid, reportId, "topic reportId");
        assertEq(packed.length, 235, "packed length");

        // Build expected OracleGame: input + contract-applied overrides.
        (uint48 expectedRts, uint48 expectedOppo) = _timestamps(input.flags);
        Slim.OracleGame memory expected = input;
        expected.reportTimestamp    = expectedRts;
        expected.lastReportOppoTime = expectedOppo;
        if (input.flags & FLAG_TRACK_DISPUTES != 0) expected.numReports = 1;

        IOpenOracle2.OracleGame memory decoded = PackedDecoder.decodeOracleGame(packed);

        assertEq(decoded.currentAmount1,       expected.currentAmount1,       "currentAmount1");
        assertEq(decoded.currentAmount2,       expected.currentAmount2,       "currentAmount2");
        assertEq(decoded.currentReporter,      expected.currentReporter,      "currentReporter");
        assertEq(decoded.reportTimestamp,      expected.reportTimestamp,      "reportTimestamp");
        assertEq(decoded.settlementTimestamp,  expected.settlementTimestamp,  "settlementTimestamp");
        assertEq(decoded.token1,               expected.token1,               "token1");
        assertEq(decoded.lastReportOppoTime,   expected.lastReportOppoTime,   "lastReportOppoTime");
        assertEq(decoded.settlementTime,       expected.settlementTime,       "settlementTime");
        assertEq(decoded.escalationHalt,       expected.escalationHalt,       "escalationHalt");
        assertEq(decoded.protocolFeeRecipient, expected.protocolFeeRecipient, "protocolFeeRecipient");
        assertEq(decoded.settlerReward,        expected.settlerReward,        "settlerReward");
        assertEq(decoded.token2,               expected.token2,               "token2");
        assertEq(decoded.numReports,           expected.numReports,           "numReports");
        assertEq(decoded.disputeDelay,         expected.disputeDelay,         "disputeDelay");
        assertEq(decoded.feePercentage,        expected.feePercentage,        "feePercentage");
        assertEq(decoded.multiplier,           expected.multiplier,           "multiplier");
        assertEq(decoded.callbackContract,     expected.callbackContract,     "callbackContract");
        assertEq(decoded.callbackGasLimit,     expected.callbackGasLimit,     "callbackGasLimit");
        assertEq(decoded.protocolFee,          expected.protocolFee,          "protocolFee");
        assertEq(decoded.flags,                expected.flags,                "flags");

        // PreimageHelper tail.
        IOpenOracle2.PreimageHelper memory dh = PackedDecoder.decodeHelperTail(packed, reportId);
        assertEq(dh.reportId,       reportId,                 "helper.reportId");
        assertEq(dh.creator,        alice,                    "helper.creator");
        assertEq(dh.blockTimestamp, uint48(block.timestamp),  "helper.blockTimestamp (uint48-narrowed)");
        assertEq(dh.blockNumber,    uint48(block.number),     "helper.blockNumber (uint48-narrowed)");
    }

    function testRoundTrip_ReportDisputed_DecodesAllFields() public {
        Slim.OracleGame memory input = _highEntropyInput();
        uint256 valueToSend = uint256(input.settlerReward);
        vm.prank(alice);
        uint256 reportId = oracle.report{value: valueToSend}(input, false, false, _emptyTiming());

        (uint48 rts, uint48 oppo) = _timestamps(input.flags);
        Slim.OracleGame memory preGame = input;
        preGame.reportTimestamp    = rts;
        preGame.lastReportOppoTime = oppo;
        if (input.flags & FLAG_TRACK_DISPUTES != 0) preGame.numReports = 1;
        Slim.PreimageHelper memory helper = Slim.PreimageHelper({
            reportId: reportId,
            creator: alice,
            blockTimestamp: block.timestamp,
            blockNumber: block.number
        });

        // Compute expected escalated amount1: multiplier=3000, MULTIPLIER_PRECISION=100, so newAmount1 = old*30.
        // currentAmount1 * 3000 / 100 = currentAmount1 * 30.
        uint128 newAmount1;
        unchecked { newAmount1 = uint128(uint256(preGame.currentAmount1) * preGame.multiplier / 100); }
        // newAmount1 must be <= escalationHalt; given escalationHalt 0xff22... > currentAmount1*30, OK.
        // For uint128, currentAmount1 ~= 2^124, *30 still fits within uint128 if escalationHalt caps it. Let me cap explicitly.
        if (newAmount1 > preGame.escalationHalt) newAmount1 = preGame.escalationHalt;
        // newAmount2 chosen < currentAmount2 so disputer collects token2 (no funding needed),
        // letting us keep a distinct multi-byte newAmount2 without blowing token2 balance.
        uint128 newAmount2 = uint128(0x010203040506);

        // Warp past disputeDelay (in seconds since flags has FLAG_TIME_TYPE)
        vm.warp(block.timestamp + preGame.disputeDelay + 1);

        vm.recordLogs();
        vm.prank(bob);
        oracle.dispute(
            reportId, address(token1), newAmount1, newAmount2, bob, false, false, preGame, helper, _emptyTiming()
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 topicRid, bytes memory packed) = _findPackedLog(logs, REPORT_DISPUTED_SIG);
        assertEq(topicRid, reportId, "topic reportId");
        assertEq(packed.length, 235, "packed length");

        // Build expected post-dispute game.
        (uint48 ct, uint48 oppoNow) = _timestamps(preGame.flags);
        Slim.OracleGame memory expected = _gameAfterDispute(preGame, newAmount1, newAmount2, bob, ct, oppoNow);

        IOpenOracle2.OracleGame memory decoded = PackedDecoder.decodeOracleGame(packed);
        assertEq(decoded.currentAmount1,       expected.currentAmount1,       "currentAmount1");
        assertEq(decoded.currentAmount2,       expected.currentAmount2,       "currentAmount2");
        assertEq(decoded.currentReporter,      expected.currentReporter,      "currentReporter (post-dispute)");
        assertEq(decoded.reportTimestamp,      expected.reportTimestamp,      "reportTimestamp (post-dispute)");
        assertEq(decoded.settlementTimestamp,  expected.settlementTimestamp,  "settlementTimestamp");
        assertEq(decoded.token1,               expected.token1,               "token1");
        assertEq(decoded.lastReportOppoTime,   expected.lastReportOppoTime,   "lastReportOppoTime (post-dispute)");
        assertEq(decoded.settlementTime,       expected.settlementTime,       "settlementTime");
        assertEq(decoded.escalationHalt,       expected.escalationHalt,       "escalationHalt");
        assertEq(decoded.protocolFeeRecipient, expected.protocolFeeRecipient, "protocolFeeRecipient");
        assertEq(decoded.settlerReward,        expected.settlerReward,        "settlerReward");
        assertEq(decoded.token2,               expected.token2,               "token2");
        assertEq(decoded.numReports,           expected.numReports,           "numReports (bumped if track flag set)");
        assertEq(decoded.disputeDelay,         expected.disputeDelay,         "disputeDelay");
        assertEq(decoded.feePercentage,        expected.feePercentage,        "feePercentage");
        assertEq(decoded.multiplier,           expected.multiplier,           "multiplier");
        assertEq(decoded.callbackContract,     expected.callbackContract,     "callbackContract");
        assertEq(decoded.callbackGasLimit,     expected.callbackGasLimit,     "callbackGasLimit");
        assertEq(decoded.protocolFee,          expected.protocolFee,          "protocolFee");
        assertEq(decoded.flags,                expected.flags,                "flags");

        // Helper is unchanged at dispute; tail must still match the original report creator+context.
        IOpenOracle2.PreimageHelper memory dh = PackedDecoder.decodeHelperTail(packed, reportId);
        assertEq(dh.creator,        helper.creator,                 "helper.creator unchanged");
        assertEq(dh.blockTimestamp, uint48(helper.blockTimestamp),  "helper.blockTimestamp unchanged");
        assertEq(dh.blockNumber,    uint48(helper.blockNumber),     "helper.blockNumber unchanged");
    }
}
