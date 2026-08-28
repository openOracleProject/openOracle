// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DirtyEntryPointsBase.t.sol";

/**
 * @notice Hash canonicalization versus commitment rejection, and the fields OpenPunt
 *         overrides or deliberately ignores.
 *
 * @dev Under solc 0.8.28 / via-IR / cancun / optimizer 190, every commitment-bearing
 *      calldata struct is copied into memory before it is hashed:
 *
 *      `MatchedSwap memory s = swapState`, `CloseDutch memory d = dutch`, and in `execute()`
 *      `IOpenOracle2.OracleGame memory oracleStateMem = oracleState` together with its
 *      PreimageHelper counterpart. The decoder validates each sub-256-bit member during that copy
 *      and reverts with empty returndata, so dirty bytes never reach a hash.
 *
 *      Exactly one rejection category therefore remains for malformed input (empty decode revert),
 *      and one for well-formed input that reconstructs the wrong state (`WrongHash` /
 *      `WrongOracleHash`). Each test asserts which of the two occurs rather than merely that a
 *      call failed.
 *
 *      No path exists where dirty input is canonicalized into a state transition that differs from
 *      the clean one.
 */
contract DirtyCommitmentTest is DirtyEntryPointsBase {
    function setUp() public {
        _setUpDirty();
    }

    // ══════════════════════════════════════════════════════════════════
    //  7. Paired: clean reconstructs, dirty cannot authenticate
    // ══════════════════════════════════════════════════════════════════

    function test_cleanStructCalldataReconstructsTheStoredPositionHash() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openHeartbeatPosition();
        assertEq(punt.swaps(swapId), keccak256(abi.encode(active)), "clean struct rebuilds the stored hash");

        bytes memory clean = abi.encodeCall(punt.liquidationHeartbeat, (swapId, active));
        (bool ok,) = _rawCallPunt(outsider, 0, clean);
        assertTrue(ok, "and authenticates through the real entry point");
    }

    /// @dev The paired negative: identical semantic low bits, one dirty high byte. If the
    ///      compiler canonicalized while copying to memory this would authenticate, because the
    ///      masked value is the committed one. It does not.
    function test_sameLowBitsWithDirtyPaddingCannotAuthenticate() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openHeartbeatPosition();
        bytes memory clean = abi.encodeCall(punt.liquidationHeartbeat, (swapId, active));

        uint256 off = _argOffset(32 + 32 * 8); // MatchedSwap.notional, uint128
        _assertCleanWord(clean, off, bytes32(uint256(active.notional)), "MatchedSwap.notional");

        bytes memory dirty = _withByte(clean, off + 15, 0x01);

        // The low 128 bits are unchanged; only the padding differs.
        uint256 dirtyLow = uint256(_readWord(dirty, off)) & type(uint128).max;
        assertEq(dirtyLow, active.notional, "the semantic value is identical");
        assertTrue(_readWord(dirty, off) != _readWord(clean, off), "only the padding differs");

        Book memory before = _book(swapId, active.collatToken);
        (bool ok, bytes memory ret) = _rawCallPunt(outsider, 0, dirty);
        _assertRevertedEmpty(ok, ret, "dirty padding with identical low bits");
        _assertStateUnchanged(before, swapId, active.collatToken, "dirty padding with identical low bits");
    }

    /// @dev The mechanism occurs at decode time, so the WrongHash guard is never reached. Proven by
    ///      contrast: a canonical-but-different value gets WrongHash, dirty padding gets nothing.
    function test_decodeRejectionHappensBeforeTheCommitmentIsChecked() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openHeartbeatPosition();
        bytes memory clean = abi.encodeCall(punt.liquidationHeartbeat, (swapId, active));
        uint256 off = _argOffset(32 + 32 * 8);

        (bool okDirty, bytes memory retDirty) = _rawCallPunt(outsider, 0, _withByte(clean, off + 15, 0x01));
        _assertRevertedEmpty(okDirty, retDirty, "dirty padding");

        (bool okDiff, bytes memory retDiff) =
            _rawCallPunt(outsider, 0, _withWord(clean, off, bytes32(uint256(active.notional) + 1)));
        assertFalse(okDiff, "a different canonical value must not authenticate");
        assertEq(bytes4(retDiff), PuntErrors.WrongHash.selector, "and it is the COMMITMENT that rejects it");
    }

    // ══════════════════════════════════════════════════════════════════
    //  7b. execute()'s loose-timing branch: the one canonicalizing word
    // ══════════════════════════════════════════════════════════════════

    function _sameBlockRace()
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory pos, Matched memory mt)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _tokenCfg(address(tokenA), address(tokenB), address(collat), false);
        Proposal memory p;
        (p, mt) = _matchAsset(s, m);
        swapId = p.swapId;
        pos = mt.swap;
        _advanceToSettlementEligibility();
        _settleDirect(mt, settler); // settle lands in the SAME block as the execute below
    }

    /**
     * @notice The loose-timing retry rewrites `settlementTimestamp` on the memory copy before
     *         re-hashing, so it is the one branch where dirty bytes could conceivably have been
     *         erased rather than committed. They cannot be: the whole struct is decoder-validated
     *         during the copy, so a dirty payload never reaches the branch at all.
     *
     * @dev This was the outcome flagged as needing the most scrutiny — dirty input canonicalized
     *      into a successful authenticated transition. It does not occur. Rejection happens
     *      strictly before loose timing can canonicalize or re-hash anything, which is why the
     *      assertions below check the position hash, the oracle state and the compensation as well
     *      as the revert category.
     */
    function test_looseTimingCannotEraseDirtyBytesInTheOverwrittenWord() public {
        // ── clean control: the loose branch really is reachable ──────────
        uint256 snap = vm.snapshotState();
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory pos, Matched memory mt) = _sameBlockRace();
        bytes memory clean = abi.encodeCall(puntLifecycle.execute, (swapId, pos, mt.game, mt.helper, true));

        (bool okClean,) = _rawCallPunt(executor, 0, clean);
        assertTrue(okClean, "clean loose execute opens the position through the rescue branch");
        vm.revertToState(snap);

        // ── every padding byte of the rewritten member ───────────────────
        (swapId, pos, mt) = _sameBlockRace();
        clean = abi.encodeCall(puntLifecycle.execute, (swapId, pos, mt.game, mt.helper, true));
        uint256 stOff = _argOffset(1024 + 32 * 4); // OracleGame.settlementTimestamp, a uint48
        _assertCleanWord(clean, stOff, bytes32(uint256(0)), "OracleGame.settlementTimestamp is the stale zero");

        bytes32 storedBefore = punt.swaps(swapId);
        uint256 tempBefore = punt.tempHolding(executor);
        bytes32 oracleBefore = oracle.oracleGame(mt.reportId);

        for (uint256 p = 0; p < 26; p++) {
            uint256 s2 = vm.snapshotState();
            (bool ok, bytes memory ret) = _rawCallPunt(executor, 0, _withByte(clean, stOff + p, 0x01));
            _assertRevertedEmpty(ok, ret, "looseTiming/settlementTimestamp padding");
            assertEq(punt.swaps(swapId), storedBefore, "position unchanged");
            assertEq(punt.tempHolding(executor), tempBefore, "executor uncompensated");
            assertEq(oracle.oracleGame(mt.reportId), oracleBefore, "oracle state unchanged");
            vm.revertToState(s2);
        }
    }

    /**
     * @notice Under looseTiming, dirty padding anywhere in OracleGame or PreimageHelper is
     *         rejected during the memory copy — uniformly, with no member-by-member exceptions.
     *
     * @dev Sweeps every paddable word of both structs while the loose-timing rescue branch is
     *      armed, which is the most permissive configuration `execute()` has. Every one fails
     *      closed with an empty decode revert, and the position hash, the stored oracle state and
     *      the executor's compensation are reconciled on every iteration.
     */
    function test_looseTimingRejectsDirtyPaddingInEveryOracleWord() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory pos, Matched memory mt) = _sameBlockRace();
        bytes memory clean = abi.encodeCall(puntLifecycle.execute, (swapId, pos, mt.game, mt.helper, true));

        bytes32 storedBefore = punt.swaps(swapId);
        uint256 tempBefore = punt.tempHolding(executor);
        bytes32 oracleBefore = oracle.oracleGame(mt.reportId);

        uint256 rejected;
        rejected += _sweepOracleStruct(
            clean, 1024, _oracleGameFields(), "OracleGame", swapId, mt.reportId, storedBefore, tempBefore, oracleBefore
        );
        rejected += _sweepOracleStruct(
            clean,
            1024 + 20 * 32,
            _preimageHelperFields(),
            "PreimageHelper",
            swapId,
            mt.reportId,
            storedBefore,
            tempBefore,
            oracleBefore
        );

        // 437 OracleGame padding bytes + 12 PreimageHelper padding bytes
        assertEq(rejected, 449, "every padding byte of both oracle structs rejected under looseTiming");
    }

    function _sweepOracleStruct(
        bytes memory clean,
        uint256 structArgOffset,
        Field[] memory f,
        string memory name,
        uint256 swapId,
        uint256 reportId,
        bytes32 storedBefore,
        uint256 tempBefore,
        bytes32 oracleBefore
    ) internal returns (uint256 probed) {
        for (uint256 i = 0; i < f.length; i++) {
            uint256 pad = 32 - f[i].width;
            uint256 off = _argOffset(structArgOffset + 32 * i);
            for (uint256 p = 0; p < pad; p++) {
                uint256 s2 = vm.snapshotState();
                (bool ok, bytes memory ret) = _rawCallPunt(executor, 0, _withByte(clean, off + p, 0x01));
                _assertRevertedEmpty(ok, ret, string.concat(name, ".", f[i].name));
                assertEq(punt.swaps(swapId), storedBefore, "position unchanged");
                assertEq(punt.tempHolding(executor), tempBefore, "executor uncompensated");
                assertEq(oracle.oracleGame(reportId), oracleBefore, "oracle state unchanged");
                vm.revertToState(s2);
                probed++;
            }
        }
    }

    /**
     * @notice Canonical loose-timing input still behaves exactly as before the hashing change.
     *
     * @dev Guards the rewrite itself: the rescue branch must still open the position, still pay
     *      the executor, and still leave the settler reward with the actual settler rather than
     *      with the executor who merely rescued the stale preimage. Paired with a
     *      canonical but different oracle value, which must still reach `WrongOracleHash` rather
     *      than being rejected by the decoder.
     */
    function test_canonicalLooseTimingStillOpensThePositionAndStillRejectsWrongState() public {
        uint256 snap = vm.snapshotState();
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory pos, Matched memory mt) = _sameBlockRace();
        bytes memory clean = abi.encodeCall(puntLifecycle.execute, (swapId, pos, mt.game, mt.helper, true));

        (bool okClean,) = _rawCallPunt(executor, 0, clean);
        assertTrue(okClean, "canonical loose-timing input still opens the position");
        assertTrue(punt.swaps(swapId) != bytes32(0), "position still stored");
        assertEq(punt.tempHolding(executor), pos.openExecutionComp, "executor still compensated");
        // The reward belongs to whoever actually settled, not to the executor who rescued the
        // stale preimage through the loose branch; both ledgers are checked separately
        assertEq(_spendable(settler, address(0)), SETTLER_REWARD, "settler keeps the settler reward");
        assertEq(_spendable(executor, address(0)), 0, "the executor is not paid the settler reward");
        vm.revertToState(snap);

        // A well-formed but different oracle value still fails through the commitment.
        (swapId, pos, mt) = _sameBlockRace();
        clean = abi.encodeCall(puntLifecycle.execute, (swapId, pos, mt.game, mt.helper, true));
        uint256 off = _argOffset(1024 + 32 * 0); // OracleGame.currentAmount1, a uint128

        bytes32 storedBefore = punt.swaps(swapId);
        (bool ok, bytes memory ret) =
            _rawCallPunt(executor, 0, _withWord(clean, off, bytes32(uint256(mt.game.currentAmount1) + 1)));
        assertFalse(ok, "a different canonical value must not authenticate");
        assertEq(bytes4(ret), PuntErrors.WrongOracleHash.selector, "rejected by the commitment, not the decoder");
        assertEq(punt.swaps(swapId), storedBefore, "position unchanged");
    }

    // ══════════════════════════════════════════════════════════════════
    //  8. Overridden fields: dirty bits must not bypass MustBeZero
    // ══════════════════════════════════════════════════════════════════

    /// @dev `propose()` requires `s.swapper == address(0)`. A word whose low 160 bits are zero but
    ///      whose high 96 bits are dirty would pass a masked comparison. It must not be accepted.
    function test_proposalSwapperDirtyHighBitsDoNotBypassMustBeZero() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _proposalCfg();
        bytes memory clean = abi.encodeCall(punt.propose, (s, m, _emptyPermit2()));
        uint256 value = _correctMsgValue(s);
        uint256 off = _argOffset(0); // ProposedSwap.swapper
        _assertCleanWord(clean, off, bytes32(uint256(0)), "ProposedSwap.swapper is the required zero");

        // high bits dirty, low 160 bits still zero
        bytes memory dirty = _withByte(clean, off + 2, 0x01);
        assertEq(uint256(_readWord(dirty, off)) & type(uint160).max, 0, "the masked address is still zero");

        Book memory before = _book(0, address(collat));
        (bool ok, bytes memory ret) = _rawCallPunt(swapper, value, dirty);
        _assertRevertedEmpty(ok, ret, "propose/swapper dirty high bits");
        _assertStateUnchanged(before, 0, address(collat), "propose/swapper dirty high bits");

        // A canonical nonzero swapper is rejected by the guard itself.
        (bool ok2, bytes memory ret2) =
            _rawCallPunt(swapper, value, _withWord(clean, off, bytes32(uint256(uint160(swapper)))));
        assertFalse(ok2, "a nonzero swapper is rejected");
        assertEq(bytes4(ret2), PuntErrors.MustBeZero.selector, "by MustBeZero");
    }

    function test_matcherPreimageStartFulfillFeeIncreaseMustBeZero() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _proposalCfg();
        bytes memory clean = abi.encodeCall(punt.propose, (s, m, _emptyPermit2()));
        uint256 value = _correctMsgValue(s);
        uint256 off = _argOffset(PROPOSE_PREIMAGE_OFF + 32 * 11); // startFulfillFeeIncrease, uint48
        _assertCleanWord(clean, off, bytes32(uint256(0)), "startFulfillFeeIncrease is the required zero");

        Book memory before = _book(0, address(collat));

        // dirty high bits above the 48-bit field
        (bool ok, bytes memory ret) = _rawCallPunt(swapper, value, _withByte(clean, off + 10, 0x01));
        _assertRevertedEmpty(ok, ret, "startFulfillFeeIncrease dirty high bits");
        _assertStateUnchanged(before, 0, address(collat), "startFulfillFeeIncrease dirty high bits");

        // canonical nonzero, inside the declared width
        (bool ok2, bytes memory ret2) = _rawCallPunt(swapper, value, _withWord(clean, off, bytes32(uint256(1))));
        assertFalse(ok2, "a nonzero startFulfillFeeIncrease is rejected");
        assertEq(bytes4(ret2), PuntErrors.MustBeZero.selector, "by MustBeZero");
    }

    /// @dev CloseDutch has five override fields. `swapId` and the addresses have different
    ///      padding shapes, so both are covered.
    function test_closeDutchOverrideFieldsMustBeZero() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        bytes memory clean = abi.encodeCall(
            punt.close,
            (swapId, input, active, false, _emptyPermit2(), CLOSE_COMP, _emptyOracleGame(), _emptyOracleHelper())
        );

        Book memory before = _book(swapId, active.collatToken);

        // CloseDutch.swapper: dirty high bits with a zero masked value
        uint256 swOff = _argOffset(CLOSE_DUTCH_OFF + 32 * 0);
        _assertCleanWord(clean, swOff, bytes32(uint256(0)), "CloseDutch.swapper");
        (bool ok, bytes memory ret) = _rawCallPunt(swapper, CLOSE_COMP, _withByte(clean, swOff + 1, 0x01));
        _assertRevertedEmpty(ok, ret, "CloseDutch.swapper dirty high bits");
        _assertStateUnchanged(before, swapId, active.collatToken, "CloseDutch.swapper dirty high bits");

        // CloseDutch.swapId is a full uint256, so it has no padding region and the only
        // way to perturb it is a real value, which MustBeZero catches
        uint256 idOff = _argOffset(CLOSE_DUTCH_OFF + 32 * 2);
        _assertCleanWord(clean, idOff, bytes32(uint256(0)), "CloseDutch.swapId");
        (bool ok2, bytes memory ret2) = _rawCallPunt(swapper, CLOSE_COMP, _withWord(clean, idOff, bytes32(uint256(1))));
        assertFalse(ok2, "a nonzero swapId is rejected");
        assertEq(bytes4(ret2), PuntErrors.MustBeZero.selector, "by MustBeZero");
        _assertStateUnchanged(before, swapId, active.collatToken, "CloseDutch.swapId nonzero");

        // CloseDutch.start
        uint256 stOff = _argOffset(CLOSE_DUTCH_OFF + 32 * 8);
        (bool ok3, bytes memory ret3) = _rawCallPunt(swapper, CLOSE_COMP, _withWord(clean, stOff, bytes32(uint256(1))));
        assertFalse(ok3, "a nonzero start is rejected");
        assertEq(bytes4(ret3), PuntErrors.MustBeZero.selector, "by MustBeZero");
        _assertStateUnchanged(before, swapId, active.collatToken, "CloseDutch.start nonzero");
    }

    // ══════════════════════════════════════════════════════════════════
    //  8b. close() on a live report: Dutch and Permit2 are ignored
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice On the live-report branch, `close()` never reads the Dutch curve or the Permit2
     *         params — it only records the intent and tops up compensation.
     *
     * @dev "Ignored" does not mean "not decoded": Solidity's external ABI decoder validates every
     *      typed argument before the function body chooses a branch. Dirty ignored data is
     *      therefore still rejected.
     */
    function test_liveReportBranchStillDecodesTheIgnoredDutchStruct() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, OpenPuntStorage.MatcherPreimage memory pre) =
            _openHeartbeatPosition();

        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);
        Matched memory mt =
            _reportOnPositionWithAmounts(swapId, _noDutch(), active, pre, reporter, REPORT_EXEC_COMP, A1, A2_OPEN);
        OpenPuntStorage.MatchedSwap memory reporting = mt.swap;
        assertEq(punt.swapIdToReportId(swapId), mt.reportId, "fixture: a live report exists");

        // A different Dutch curve is accepted on this branch because the branch ignores it.
        OpenPuntStorage.CloseDutch memory junk;
        junk.maxReward = type(uint128).max;
        junk.startingReward = 12345;
        junk.roundLength = 7;
        junk.growthRate = 65535;
        junk.maxRounds = 99;
        junk.expiration = type(uint48).max;

        bytes memory clean = abi.encodeCall(
            punt.close,
            (swapId, junk, reporting, false, _emptyPermit2(), CLOSE_COMP, _emptyOracleGame(), _emptyOracleHelper())
        );

        uint256 oracleCustodyBefore = _rawBalanceOf(active.collatToken, address(oracle));
        uint256 swapperCollatBefore = _rawBalanceOf(active.collatToken, swapper);

        (bool ok,) = _rawCallPunt(swapper, CLOSE_COMP, clean);
        assertTrue(ok, "ignored Dutch content is accepted on the live-report branch");

        // Only the intent and requested compensation changed.
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertTrue(intent, "close intent set");
        assertEq(pending, 0, "live-report close creates no pending auction escrow");
        assertEq(
            punt.executionGasComp(mt.reportId),
            REPORT_EXEC_COMP + CLOSE_EXEC_COMP,
            "compensation added to the live report"
        );
        assertEq(_storedDutchState(swapId), bytes32(0), "NO auction was stored from the junk curve");
        assertEq(
            _rawBalanceOf(active.collatToken, swapper), swapperCollatBefore, "no reward was pulled from the swapper"
        );
        assertEq(_rawBalanceOf(active.collatToken, address(oracle)), oracleCustodyBefore, "oracle custody unchanged");

        // Dirty bytes in that same ignored struct are still rejected by the decoder.
        uint256 off = _argOffset(CLOSE_DUTCH_OFF + 32 * 3); // junk.maxReward padding
        (bool ok2, bytes memory ret2) = _rawCallPunt(swapper, CLOSE_COMP, _withByte(clean, off + 15, 0x01));
        _assertRevertedEmpty(ok2, ret2, "dirty bytes in the IGNORED Dutch struct");
    }

    /// @dev The expected auction hash is a full-width bytes32, so it has no padding to dirty.
    ///      A different canonical value reaches the hash gate and is rejected there.
    function test_reportNonzeroExpectedHashWithoutAuctionIsRejectedByHashGate() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, OpenPuntStorage.MatcherPreimage memory pre) =
            _openHeartbeatPosition();
        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);

        bytes memory clean = abi.encodeCall(
            puntLifecycle.report,
            (swapId, bytes32(0), active, pre, _noTiming(), reporter, A1, A2_OPEN, REPORT_EXEC_COMP)
        );

        Book memory before = _book(swapId, active.collatToken);
        uint256 off = _argOffset(32); // expectedDutchHash
        _assertCleanWord(clean, off, bytes32(0), "zero expected hash");

        (bool ok, bytes memory ret) = _rawCallPunt(reporter, 0, _withWord(clean, off, bytes32(uint256(1))));
        assertFalse(ok, "invented auction hash rejected");
        assertEq(bytes4(ret), PuntErrors.WrongHash.selector, "rejected by the auction hash gate");
        _assertStateUnchanged(before, swapId, active.collatToken, "invented auction hash");
    }
}
