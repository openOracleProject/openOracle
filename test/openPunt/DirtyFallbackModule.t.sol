// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DirtyEntryPointsBase.t.sol";

/**
 * @notice Dirty calldata delivered to fallback-routed module entry points.
 *
 * @dev Every call here targets `address(punt)` — never `lifecycleModule` directly — so the full
 *      path is exercised:
 *
 *          core fallback -> selector allowlist -> calldatacopy(0, calldatasize())
 *            -> delegatecall -> module ABI decoder -> returndata bubbling
 *
 *      The module's decoder failure is an empty revert, and the fallback bubbles exactly that:
 *      `returndatacopy` of zero bytes followed by `revert(ptr, 0)`. So an ABI rejection reaching
 *      the caller as empty returndata is evidence the bubbling is faithful, not evidence the
 *      fallback swallowed something.
 *
 *      execute() decodes OracleGame and PreimageHelper into memory and hashes
 *      `abi.encode(oracleStateMem, oracleHelperMem)`, exactly as every other commitment path does.
 *      Two distinct rejection categories therefore remain, and the tests record which one occurs:
 *
 *        - a malformed typed value (dirty padding) is rejected by the ABI decoder, with empty
 *          returndata, before any hash is computed;
 *        - a valid ABI value that reconstructs the wrong state is rejected by the commitment,
 *          with `WrongOracleHash`.
 */
contract DirtyFallbackModuleTest is DirtyEntryPointsBase {
    // ── report() argument offsets ───────────────────────────────────────
    //   0     swapId            1 word
    //   32    expectedDutchHash  bytes32
    //   64    MatchedSwap       29 words -> 928
    //   992   MatcherPreimage   12 words -> 384
    //   1376  TimingBoundaries  4 words  -> 128
    //   1504  reporter          address
    //   1536  amount1           uint128
    //   1568  amount2           uint128
    //   1600  altGasCompExec    uint128
    uint256 internal constant REP_DUTCH_HASH_OFF = 32;
    uint256 internal constant REP_MATCHED_OFF = 64;
    uint256 internal constant REP_PREIMAGE_OFF = 992;
    uint256 internal constant REP_TIMING_OFF = 1376;
    uint256 internal constant REP_REPORTER_OFF = 1504;
    uint256 internal constant REP_AMOUNT1_OFF = 1536;
    uint256 internal constant REP_AMOUNT2_OFF = 1568;
    uint256 internal constant REP_ALTCOMP_OFF = 1600;

    // ── execute() argument offsets ──────────────────────────────────────
    //   0     swapId          1 word
    //   32    MatchedSwap     29 words -> 928
    //   960   OracleGame      20 words -> 640
    //   1600  PreimageHelper  4 words  -> 128
    //   1728  looseTiming     bool
    uint256 internal constant EX_MATCHED_OFF = 32;
    uint256 internal constant EX_GAME_OFF = 960;
    uint256 internal constant EX_HELPER_OFF = 1600;
    uint256 internal constant EX_LOOSE_OFF = 1728;

    uint256 internal swapId;
    OpenPuntStorage.MatchedSwap internal active;
    OpenPuntStorage.MatcherPreimage internal preimage;

    function setUp() public {
        _setUpDirty();
        (swapId, active, preimage) = _openHeartbeatPosition();
    }

    // ── extended reconciliation ─────────────────────────────────────────

    struct ReportBook {
        Book book;
        uint128 execComp;
        uint256 reporterEth;
        uint256 reporterCollat;
    }

    function _reportBook(uint256 reportId) internal view returns (ReportBook memory rb) {
        rb.book = _book(swapId, active.collatToken);
        rb.execComp = punt.executionGasComp(reportId);
        rb.reporterEth = reporter.balance;
        rb.reporterCollat = _rawBalanceOf(active.collatToken, reporter);
    }

    function _assertReportBookUnchanged(ReportBook memory before, uint256 reportId, string memory w) internal view {
        _assertStateUnchanged(before.book, swapId, active.collatToken, w);
        require(punt.executionGasComp(reportId) == before.execComp, string.concat(w, ": execution comp moved"));
        require(reporter.balance == before.reporterEth, string.concat(w, ": reporter ETH moved"));
        require(
            _rawBalanceOf(active.collatToken, reporter) == before.reporterCollat,
            string.concat(w, ": reporter collateral moved")
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  report()
    // ══════════════════════════════════════════════════════════════════

    function _cleanReport() internal view returns (bytes memory) {
        return abi.encodeCall(
            puntLifecycle.report,
            (swapId, bytes32(0), active, preimage, _noTiming(), reporter, A1, A2_OPEN, REPORT_EXEC_COMP)
        );
    }

    function test_reportCalldataLayout() public view {
        assertEq(_cleanReport().length, 4 + 32 + 32 + 928 + 384 + 128 + 32 + 32 + 32 + 32, "report calldata length");
    }

    /// @dev Table-driven so all seven required report mutations share one reconciliation.
    function _rejectReport(uint256 absOffset, uint8 padByte, string memory what) internal {
        bytes memory clean = _cleanReport();
        bytes32 cleanWord = _readWord(clean, absOffset);

        // The clean payload reaches its transition.
        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(reporter, 0, clean);
        require(okClean, string.concat(what, ": clean report did not reach its transition"));
        vm.revertToState(snap);

        ReportBook memory before = _reportBook(oracle.nextReportId());

        bytes memory dirty = _copyBytes(clean);
        _writeByte(dirty, absOffset + padByte, 0x01);
        require(_readWord(dirty, absOffset) != cleanWord, string.concat(what, ": mutation was a no-op"));

        (bool ok, bytes memory ret) = _rawCallPunt(reporter, 0, dirty);
        _assertFailedClosed(ok, ret, what);
        _assertRevertedEmpty(ok, ret, what);
        _assertReportBookUnchanged(before, oracle.nextReportId(), what);
    }

    function test_report_nonzeroExpectedDutchHashWithoutAuctionHitsTheHashGate() public {
        bytes memory clean = _cleanReport();
        ReportBook memory before = _reportBook(oracle.nextReportId());
        bytes memory different = _withWord(clean, _argOffset(REP_DUTCH_HASH_OFF), bytes32(uint256(1)));

        (bool ok, bytes memory ret) = _rawCallPunt(reporter, 0, different);
        assertFalse(ok, "invented auction hash rejected");
        assertEq(bytes4(ret), PuntErrors.WrongHash.selector, "full-width bytes32 reaches the hash gate");
        _assertReportBookUnchanged(before, oracle.nextReportId(), "report/expectedDutchHash");
    }

    function test_report_dirtyMatchedSwapField() public {
        // MatchedSwap.notional is word 8
        _rejectReport(_argOffset(REP_MATCHED_OFF + 32 * 8), 15, "report/MatchedSwap.notional padding");
    }

    function test_report_dirtyMatcherPreimageField() public {
        // MatcherPreimage.initialLiquidity is word 0
        _rejectReport(_argOffset(REP_PREIMAGE_OFF + 32 * 0), 15, "report/MatcherPreimage.initialLiquidity padding");
    }

    function test_report_dirtyReporterAddress() public {
        _rejectReport(_argOffset(REP_REPORTER_OFF), 5, "report/reporter address padding");
    }

    function test_report_dirtyAmount1() public {
        _rejectReport(_argOffset(REP_AMOUNT1_OFF), 15, "report/amount1 padding");
    }

    function test_report_dirtyAmount2() public {
        _rejectReport(_argOffset(REP_AMOUNT2_OFF), 15, "report/amount2 padding");
    }

    function test_report_dirtyAltGasCompExec() public {
        _rejectReport(_argOffset(REP_ALTCOMP_OFF), 15, "report/altGasCompExec padding");
    }

    // ══════════════════════════════════════════════════════════════════
    //  execute()
    // ══════════════════════════════════════════════════════════════════

    struct Eligible {
        OpenPuntStorage.MatchedSwap swap;
        IOpenOracle2.OracleGame game;
        IOpenOracle2.PreimageHelper helper;
        uint256 reportId;
    }

    /// @dev A genuine settlement-eligible closing report on the live position.
    function _eligible() internal returns (Eligible memory e) {
        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);
        Matched memory mt =
            _reportOnPositionWithAmounts(swapId, _noDutch(), active, preimage, reporter, REPORT_EXEC_COMP, A1, A2_OPEN);
        e.swap = mt.swap;
        e.game = mt.game;
        e.helper = mt.helper;
        e.reportId = mt.reportId;
        _advanceToSettlementEligibility();
    }

    function _cleanExecute(Eligible memory e) internal view returns (bytes memory) {
        return abi.encodeCall(puntLifecycle.execute, (swapId, e.swap, e.game, e.helper, false));
    }

    function test_executeCalldataLayout() public {
        Eligible memory e = _eligible();
        assertEq(_cleanExecute(e).length, 4 + 32 + 928 + 640 + 128 + 32, "execute calldata length");
    }

    struct ExecBook {
        Book book;
        uint128 execComp;
        uint256 executorTemp;
        uint256 executorEth;
        bytes32 oracleHash;
    }

    function _execBook(Eligible memory e) internal view returns (ExecBook memory eb) {
        eb.book = _book(swapId, active.collatToken);
        eb.execComp = punt.executionGasComp(e.reportId);
        eb.executorTemp = punt.tempHolding(closeExecutor);
        eb.executorEth = closeExecutor.balance;
        eb.oracleHash = oracle.oracleGame(e.reportId);
    }

    /// @dev A rejected execution must not settle the report, pay compensation, clear
    ///      executionGasComp, delete or advance the position, delete the heartbeat, or move
    ///      collateral or oracle legs.
    function _assertExecBookUnchanged(ExecBook memory before, Eligible memory e, string memory w) internal view {
        _assertStateUnchanged(before.book, swapId, active.collatToken, w);
        require(punt.executionGasComp(e.reportId) == before.execComp, string.concat(w, ": executionGasComp cleared"));
        require(punt.tempHolding(closeExecutor) == before.executorTemp, string.concat(w, ": executor was paid"));
        require(closeExecutor.balance == before.executorEth, string.concat(w, ": executor ETH moved"));
        require(oracle.oracleGame(e.reportId) == before.oracleHash, string.concat(w, ": the report was settled"));
    }

    function _rejectExecute(bytes memory dirty, Eligible memory e, string memory what)
        internal
        returns (uint8 kind, bytes4 sel)
    {
        ExecBook memory before = _execBook(e);
        bool ok;
        bytes memory ret;
        (ok, ret) = _rawCallPunt(closeExecutor, 0, dirty);
        (kind, sel) = _assertFailedClosed(ok, ret, what);
        _assertExecBookUnchanged(before, e, what);
    }

    function test_execute_cleanControlSettlesTheReport() public {
        Eligible memory e = _eligible();
        (bool ok,) = _rawCallPunt(closeExecutor, 0, _cleanExecute(e));
        assertTrue(ok, "clean execute reaches its transition");
        assertEq(punt.executionGasComp(e.reportId), 0, "and it clears execution compensation");
    }

    function test_execute_dirtyMatchedSwapIsAnAbiDecodeFailure() public {
        Eligible memory e = _eligible();
        bytes memory clean = _cleanExecute(e);
        uint256 off = _argOffset(EX_MATCHED_OFF + 32 * 8); // MatchedSwap.notional
        (, bytes4 sel) = _rejectExecute(_withByte(clean, off + 15, 0x01), e, "execute/MatchedSwap.notional");
        assertEq(sel, bytes4(0), "rejected by the ABI decoder, with empty returndata");
    }

    function test_execute_dirtyOracleGameAddressIsAnAbiDecodeFailure() public {
        Eligible memory e = _eligible();
        bytes memory clean = _cleanExecute(e);
        uint256 off = _argOffset(EX_GAME_OFF + 32 * 5); // OracleGame.token1, an address
        _assertCleanWord(clean, off, bytes32(uint256(uint160(e.game.token1))), "OracleGame.token1");
        (uint8 kind,) = _rejectExecute(_withByte(clean, off + 3, 0x01), e, "execute/OracleGame.token1 padding");
        assertEq(kind, R_EMPTY, "the decoder rejects it during the memory copy, before any hash is computed");
    }

    function test_execute_dirtyOracleGameNarrowIntegerIsAnAbiDecodeFailure() public {
        Eligible memory e = _eligible();
        bytes memory clean = _cleanExecute(e);
        uint256 off = _argOffset(EX_GAME_OFF + 32 * 3); // OracleGame.reportTimestamp, a uint48
        (uint8 kind,) = _rejectExecute(_withByte(clean, off + 25, 0x01), e, "execute/OracleGame.reportTimestamp");
        assertEq(kind, R_EMPTY, "ABI decode failure");
    }

    function test_execute_dirtyPreimageHelperCreator() public {
        Eligible memory e = _eligible();
        bytes memory clean = _cleanExecute(e);
        uint256 off = _argOffset(EX_HELPER_OFF + 32 * 1); // PreimageHelper.creator
        _assertCleanWord(clean, off, bytes32(uint256(uint160(e.helper.creator))), "PreimageHelper.creator");
        (uint8 kind,) = _rejectExecute(_withByte(clean, off + 0, 0x01), e, "execute/PreimageHelper.creator padding");
        assertEq(kind, R_EMPTY, "ABI decode failure");
    }

    function test_execute_looseTimingTwo() public {
        Eligible memory e = _eligible();
        bytes memory clean = _cleanExecute(e);
        uint256 off = _argOffset(EX_LOOSE_OFF);
        _assertCleanWord(clean, off, bytes32(uint256(0)), "execute.looseTiming");
        (uint8 kind,) = _rejectExecute(_withWord(clean, off, bytes32(uint256(2))), e, "execute/looseTiming = 2");
        assertEq(kind, R_EMPTY, "a non-Boolean looseTiming is an ABI decode failure");
    }

    /**
     * @notice Distinguishes decode failure from commitment failure.
     *
     * @dev This case is what keeps the empty reverts above meaningful. A payload that is perfectly
     *      well-formed ABI but reconstructs a different oracle state gets past the decoder and must
     *      then be rejected by the commitment with `WrongOracleHash`. Without this pairing, the
     *      empty reverts alone could not distinguish a decoder rejection from an unused hash check.
     */
    function test_execute_cleanButDifferentOracleGameIsWrongOracleHash() public {
        Eligible memory e = _eligible();
        bytes memory clean = _cleanExecute(e);
        uint256 off = _argOffset(EX_GAME_OFF + 32 * 0); // OracleGame.currentAmount1, a uint128

        // Change the value inside its declared width, leaving the padding canonical.
        bytes memory different = _copyBytes(clean);
        _writeWord(different, off, bytes32(uint256(e.game.currentAmount1) + 1));

        (, bytes4 sel) = _rejectExecute(different, e, "execute/different but canonical currentAmount1");
        assertEq(sel, PuntErrors.WrongOracleHash.selector, "rejected by the oracle commitment");
    }

    function test_execute_truncatedOraclePayload() public {
        Eligible memory e = _eligible();
        bytes memory clean = _cleanExecute(e);

        // drop the final word, so the helper tail is incomplete
        (uint8 kind,) = _rejectExecute(_truncate(clean, clean.length - 32), e, "execute/truncated helper");
        assertEq(kind, R_EMPTY, "truncated calldata is an ABI decode failure");

        // and truncating inside the OracleGame span
        Eligible memory e2 = e;
        (uint8 kind2,) = _rejectExecute(_truncate(clean, _argOffset(EX_GAME_OFF) + 16), e2, "execute/mid-game cut");
        assertEq(kind2, R_EMPTY, "ABI decode failure");
    }

    // ══════════════════════════════════════════════════════════════════
    //  deployAndDistributeFeeReceiver()
    // ══════════════════════════════════════════════════════════════════

    struct FeeCase {
        bytes clean;
        address receiver;
        uint256 swapId;
        address collatToken;
    }

    function _feeCase() internal returns (FeeCase memory fc) {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _tokenCfg(address(tokenA), address(tokenB), address(collat), false);
        m.protocolFee = 100_000;
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);

        fc.clean = abi.encodeCall(
            puntLifecycle.deployAndDistributeFeeReceiver, (p.swapId, swapper, matcher, mt.game, mt.helper)
        );
        fc.receiver = mt.game.protocolFeeRecipient;
        fc.swapId = p.swapId;
        fc.collatToken = s.collatToken;
        assertTrue(fc.receiver != address(0), "fixture: a counterfactual receiver exists");
        assertEq(fc.receiver.code.length, 0, "fixture: and it is not yet deployed");
    }

    function _rejectFee(FeeCase memory fc, bytes memory dirty, string memory what) internal returns (uint8 kind) {
        Book memory before = _book(fc.swapId, fc.collatToken);
        bytes4 sel;
        bool ok;
        bytes memory ret;
        (ok, ret) = _rawCallPunt(outsider, 0, dirty);
        (kind, sel) = _assertFailedClosed(ok, ret, what);
        _assertStateUnchanged(before, fc.swapId, fc.collatToken, what);
        require(fc.receiver.code.length == 0, string.concat(what, ": the clone was DEPLOYED"));
        require(_spendable(fc.receiver, address(tokenA)) == 0, string.concat(what, ": token1 fees moved"));
        require(_spendable(fc.receiver, address(tokenB)) == 0, string.concat(what, ": token2 fees moved"));
    }

    function test_feeReceiver_cleanControlDeploysTheClone() public {
        FeeCase memory fc = _feeCase();
        (bool ok,) = _rawCallPunt(outsider, 0, fc.clean);
        assertTrue(ok, "clean call reaches its transition");
        assertGt(fc.receiver.code.length, 0, "and deploys the clone");
    }

    function test_feeReceiver_dirtyTopLevelSwapperAddress() public {
        FeeCase memory fc = _feeCase();
        uint256 off = _argOffset(32); // top-level swapper
        _assertCleanWord(fc.clean, off, bytes32(uint256(uint160(swapper))), "deployAndDistribute.swapper");
        assertEq(_rejectFee(fc, _withByte(fc.clean, off + 4, 0x01), "fee/swapper padding"), R_EMPTY, "decode failure");
    }

    function test_feeReceiver_dirtyTopLevelMatcherAddress() public {
        FeeCase memory fc = _feeCase();
        uint256 off = _argOffset(64); // top-level matcher
        _assertCleanWord(fc.clean, off, bytes32(uint256(uint160(matcher))), "deployAndDistribute.matcher");
        assertEq(_rejectFee(fc, _withByte(fc.clean, off + 4, 0x01), "fee/matcher padding"), R_EMPTY, "decode failure");
    }

    function test_feeReceiver_dirtyOracleTokenAddress() public {
        FeeCase memory fc = _feeCase();
        uint256 off = _argOffset(96 + 32 * 5); // OracleGame.token1
        assertEq(_rejectFee(fc, _withByte(fc.clean, off + 2, 0x01), "fee/token1 padding"), R_EMPTY, "decode failure");
    }

    function test_feeReceiver_dirtyFeeRecipientAddress() public {
        FeeCase memory fc = _feeCase();
        uint256 off = _argOffset(96 + 32 * 9); // OracleGame.protocolFeeRecipient
        _assertCleanWord(fc.clean, off, bytes32(uint256(uint160(fc.receiver))), "OracleGame.protocolFeeRecipient");
        assertEq(_rejectFee(fc, _withByte(fc.clean, off + 1, 0x01), "fee/recipient padding"), R_EMPTY, "decode failure");
    }

    function test_feeReceiver_dirtyNarrowOracleField() public {
        FeeCase memory fc = _feeCase();
        uint256 off = _argOffset(96 + 32 * 12); // OracleGame.numReports, a uint24
        assertEq(
            _rejectFee(fc, _withByte(fc.clean, off + 28, 0x01), "fee/numReports padding"), R_EMPTY, "decode failure"
        );
    }

    function test_feeReceiver_dirtyHelperCreator() public {
        FeeCase memory fc = _feeCase();
        uint256 off = _argOffset(96 + 20 * 32 + 32 * 1); // PreimageHelper.creator
        assertEq(_rejectFee(fc, _withByte(fc.clean, off + 6, 0x01), "fee/creator padding"), R_EMPTY, "decode failure");
    }
}
