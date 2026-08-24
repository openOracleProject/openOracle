// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DirtyEntryPointsBase.t.sol";

/**
 * @notice Trailing calldata and truncated calldata.
 *
 * @dev Trailing calldata acceptance is normal ABI behavior. The requirement is inertness: the
 *      transition and emitted
 *      state must be byte-identical to the clean call, no second selector may execute, the
 *      fallback's forwarding of the full `calldatasize()` must not change how the module decodes,
 *      and stored hashes must remain canonical and exclude the suffix.
 */
contract DirtyTrailingTruncationTest is DirtyEntryPointsBase {
    address internal constant SUFFIX_VICTIM = address(0x5FF1);

    uint256 internal swapId;
    OpenPuntStorage.MatchedSwap internal active;
    OpenPuntStorage.MatcherPreimage internal preimage;

    function setUp() public {
        _setUpDirty();
        (swapId, active, preimage) = _openHeartbeatPosition();
    }

    // ── suffixes ────────────────────────────────────────────────────────

    function _oneByte() internal pure returns (bytes memory) {
        return hex"01";
    }

    function _oneWord() internal pure returns (bytes memory) {
        return bytes.concat(bytes32(type(uint256).max));
    }

    /// @dev A complete, individually valid call to another OpenPunt function. If the suffix were
    ///      ever executed, this one would visibly seed a tempHolding sentinel.
    function _selectorSuffix() internal view returns (bytes memory) {
        return abi.encodeCall(punt.dust, (SUFFIX_VICTIM));
    }

    function _largeSuffix() internal pure returns (bytes memory out) {
        out = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            out[i] = bytes1(uint8((i % 255) + 1));
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  10. Trailing calldata on a successful core function
    // ══════════════════════════════════════════════════════════════════

    struct Outcome {
        bytes32 swapHash;
        uint128 hbReportId;
        uint48 hbTimestamp;
        uint256 victimTemp;
        bytes32 logDigest;
    }

    function _runHeartbeat(bytes memory data) internal returns (bool ok, Outcome memory o) {
        vm.recordLogs();
        (ok,) = _rawCallPunt(outsider, 0, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        o.swapHash = punt.swaps(swapId);
        (o.hbReportId, o.hbTimestamp) = punt.liquidationHeartbeats(swapId);
        o.victimTemp = punt.tempHolding(SUFFIX_VICTIM);

        bytes memory acc;
        for (uint256 i = 0; i < logs.length; i++) {
            acc = bytes.concat(acc, bytes32(uint256(uint160(logs[i].emitter))), logs[i].data);
            for (uint256 t = 0; t < logs[i].topics.length; t++) {
                acc = bytes.concat(acc, logs[i].topics[t]);
            }
        }
        o.logDigest = keccak256(acc);
    }

    function _assertSuffixInert(bytes memory suffix, string memory what) internal {
        bytes memory clean = abi.encodeCall(punt.liquidationHeartbeat, (swapId, active));

        uint256 snap = vm.snapshotState();
        (bool okClean, Outcome memory expected) = _runHeartbeat(clean);
        require(okClean, "clean control failed");
        vm.revertToState(snap);

        (bool ok, Outcome memory got) = _runHeartbeat(_append(clean, suffix));

        assertTrue(ok, string.concat(what, ": suffix should be accepted and ignored"));
        assertEq(got.swapHash, expected.swapHash, string.concat(what, ": stored hash identical"));
        assertEq(got.hbReportId, expected.hbReportId, string.concat(what, ": heartbeat report id identical"));
        assertEq(got.hbTimestamp, expected.hbTimestamp, string.concat(what, ": heartbeat timestamp identical"));
        assertEq(got.logDigest, expected.logDigest, string.concat(what, ": emitted logs byte-identical"));
        assertEq(got.victimTemp, 0, string.concat(what, ": the trailing selector did NOT execute"));
    }

    function test_trailingOneByteIsInert() public {
        _assertSuffixInert(_oneByte(), "one trailing byte");
    }

    function test_trailingFullWordIsInert() public {
        _assertSuffixInert(_oneWord(), "one trailing word");
    }

    function test_trailingValidSelectorDoesNotExecute() public {
        // the suffix is a genuinely valid call on its own
        uint256 snap = vm.snapshotState();
        (bool okAlone,) = _rawCallPunt(outsider, 1, _selectorSuffix());
        assertTrue(okAlone, "the suffix IS a valid call when sent on its own");
        assertEq(punt.tempHolding(SUFFIX_VICTIM), 1, "and it would seed a sentinel");
        vm.revertToState(snap);

        _assertSuffixInert(_selectorSuffix(), "trailing dust() call");
    }

    function test_trailingLargeArbitrarySuffixIsInert() public {
        _assertSuffixInert(_largeSuffix(), "1024-byte suffix");
    }

    // ══════════════════════════════════════════════════════════════════
    //  10b. Trailing calldata through the fallback
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice The fallback forwards `calldatasize()` verbatim, so a suffix reaches the module's
     *         decoder too. It must not change what the module decodes.
     */
    function test_trailingCalldataThroughTheFallbackOnReport() public {
        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);
        bytes memory clean = abi.encodeCall(
            puntLifecycle.report,
            (swapId, bytes32(0), active, preimage, _noTiming(), reporter, A1, A2_OPEN, REPORT_EXEC_COMP)
        );

        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        (bool okClean,) = _rawCallPunt(reporter, 0, clean);
        require(okClean, "clean report control failed");
        Vm.Log[] memory cleanLogs = vm.getRecordedLogs();
        bytes32 cleanHash = punt.swaps(swapId);
        uint256 cleanNextReport = oracle.nextReportId();
        uint256 cleanLogCount = cleanLogs.length;
        vm.revertToState(snap);

        vm.recordLogs();
        (bool ok,) = _rawCallPunt(reporter, 0, _append(clean, _selectorSuffix()));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok, "the module decoded the same arguments despite the suffix");
        assertEq(punt.swaps(swapId), cleanHash, "stored position hash identical");
        assertEq(oracle.nextReportId(), cleanNextReport, "the same single report was allocated");
        assertEq(logs.length, cleanLogCount, "same number of events");
        assertEq(punt.tempHolding(SUFFIX_VICTIM), 0, "the trailing selector did NOT execute");
    }

    function test_trailingCalldataThroughTheFallbackOnExecute() public {
        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);
        Matched memory mt =
            _reportOnPositionWithAmounts(swapId, _noDutch(), active, preimage, reporter, REPORT_EXEC_COMP, A1, A2_OPEN);
        _advanceToSettlementEligibility();

        bytes memory clean = abi.encodeCall(puntLifecycle.execute, (swapId, mt.swap, mt.game, mt.helper, false));

        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(closeExecutor, 0, clean);
        require(okClean, "clean execute control failed");
        bytes32 cleanHash = punt.swaps(swapId);
        uint256 cleanTemp = punt.tempHolding(closeExecutor);
        vm.revertToState(snap);

        (bool ok,) = _rawCallPunt(closeExecutor, 0, _append(clean, _largeSuffix()));

        // execute() hashes abi.encode of the decoded structs, whose sizes are fixed by their
        // types, so a suffix cannot enter the oracle hash
        assertTrue(ok, "suffix does not disturb the decoded oracle preimage");
        assertEq(punt.swaps(swapId), cleanHash, "stored position hash identical");
        assertEq(punt.tempHolding(closeExecutor), cleanTemp, "compensation identical");
    }

    // ══════════════════════════════════════════════════════════════════
    //  11. Truncation and malformed static calldata
    // ══════════════════════════════════════════════════════════════════

    function _assertTruncationRejected(bytes memory data, string memory what) internal {
        Book memory before = _book(swapId, active.collatToken);
        (bool ok, bytes memory ret) = _rawCallPunt(outsider, 0, data);
        _assertFailedClosed(ok, ret, what);
        _assertStateUnchanged(before, swapId, active.collatToken, what);
    }

    function test_truncationWithinAStructWord() public {
        bytes memory clean = abi.encodeCall(punt.liquidationHeartbeat, (swapId, active));
        // cut 16 bytes into MatchedSwap.notional's word
        _assertTruncationRejected(_truncate(clean, _argOffset(32 + 32 * 8) + 16), "cut inside a struct word");
    }

    function test_truncationExactlyBeforeTheFinalStaticArgument() public {
        bytes memory clean = abi.encodeCall(punt.liquidationHeartbeat, (swapId, active));
        // MatchedSwap's last word is useInternalBalances (word 29)
        _assertTruncationRejected(_truncate(clean, clean.length - 32), "final static word removed");
    }

    function test_selectorOnly() public {
        bytes memory clean = abi.encodeCall(punt.liquidationHeartbeat, (swapId, active));
        _assertTruncationRejected(_truncate(clean, 4), "selector only");
    }

    function test_truncatedFallbackRoutedCall() public {
        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);
        bytes memory clean = abi.encodeCall(
            puntLifecycle.report,
            (swapId, bytes32(0), active, preimage, _noTiming(), reporter, A1, A2_OPEN, REPORT_EXEC_COMP)
        );

        // An approved selector with a malformed body bubbles the module decoder's empty failure.
        Book memory before = _book(swapId, active.collatToken);
        (bool ok, bytes memory ret) = _rawCallPunt(reporter, 0, _truncate(clean, clean.length - 32));
        _assertRevertedEmpty(ok, ret, "truncated report through the fallback");
        _assertStateUnchanged(before, swapId, active.collatToken, "truncated report through the fallback");

        (bool ok2, bytes memory ret2) = _rawCallPunt(reporter, 0, _truncate(clean, 4));
        _assertRevertedEmpty(ok2, ret2, "report selector only");
    }

    // ══════════════════════════════════════════════════════════════════
    //  11b. Selector handling at the fallback
    // ══════════════════════════════════════════════════════════════════

    function test_unapprovedSelectorGivesInvalidSelector() public {
        Book memory before = _book(swapId, active.collatToken);

        (bool ok, bytes memory ret) = _rawCallPunt(outsider, 0, abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertFalse(ok, "an unapproved selector is rejected");
        assertEq(bytes4(ret), PuntErrors.InvalidSelector.selector, "with InvalidSelector");
        _assertStateUnchanged(before, swapId, active.collatToken, "unapproved selector");

        // The allowlist is exactly three selectors. Anything else — including a selector that
        // merely resembles a lifecycle function, lands on the same guard.
        (bool ok2, bytes memory ret2) =
            _rawCallPunt(outsider, 0, abi.encodeWithSelector(bytes4(keccak256("settle(uint256)")), uint256(1)));
        assertFalse(ok2, "an unrouted selector is rejected");
        assertEq(bytes4(ret2), PuntErrors.InvalidSelector.selector, "with InvalidSelector");

        // Each of the three approved selectors is genuinely different from it.
        assertTrue(OpenPuntLifecycle.report.selector != bytes4(0xdeadbeef), "report is allowlisted separately");
        assertTrue(OpenPuntLifecycle.execute.selector != bytes4(0xdeadbeef), "execute is allowlisted separately");
        assertTrue(
            OpenPuntLifecycle.deployAndDistributeFeeReceiver.selector != bytes4(0xdeadbeef),
            "deployAndDistributeFeeReceiver is allowlisted separately"
        );
    }

    /// @dev `msg.sig` zero-pads short calldata, so a sub-4-byte payload can never match one of the
    ///      three approved selectors and lands on the same guard.
    function test_fewerThanFourBytesToTheFallback() public {
        Book memory before = _book(swapId, active.collatToken);

        bytes[4] memory shorts = [bytes(hex""), bytes(hex"01"), bytes(hex"0102"), bytes(hex"010203")];
        for (uint256 i = 0; i < shorts.length; i++) {
            (bool ok, bytes memory ret) = _rawCallPunt(outsider, 0, shorts[i]);
            assertFalse(ok, "short calldata is rejected");
            assertEq(bytes4(ret), PuntErrors.InvalidSelector.selector, "with InvalidSelector");
        }
        _assertStateUnchanged(before, swapId, active.collatToken, "short calldata");
    }

    /// @dev The first three bytes of an approved selector, zero-padded, must not match it.
    function test_truncatedApprovedSelectorDoesNotMatch() public {
        bytes4 reportSel = OpenPuntLifecycle.report.selector;
        bytes memory threeBytes = new bytes(3);
        threeBytes[0] = reportSel[0];
        threeBytes[1] = reportSel[1];
        threeBytes[2] = reportSel[2];

        (bool ok, bytes memory ret) = _rawCallPunt(reporter, 0, threeBytes);
        assertFalse(ok, "a truncated selector must not route");
        assertEq(bytes4(ret), PuntErrors.InvalidSelector.selector, "with InvalidSelector");
    }
}
