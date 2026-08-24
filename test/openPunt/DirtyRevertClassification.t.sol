// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DirtyEntryPointsBase.t.sol";

/**
 * @notice One representative of every observed outcome class, asserted by category rather than
 *         by `assertFalse(ok)`, with full rollback proven in each case.
 *
 * @dev The six classes, and what produces each under solc 0.8.28 / via-IR / cancun / opt 190:
 *
 *        1. empty ABI decode revert   dirty padding in any struct the callee copies to memory
 *        2. WrongHash                 canonical but different value in a hash-committed struct
 *        3. WrongOracleHash           canonical but different value in the oracle preimage
 *        4. InvalidSelector           any selector outside the fallback's three-entry allowlist
 *        5. business-logic error      a canonical value the contract's own guard rejects
 *        6. accepted-but-ignored      lawful noncanonical encoding with no observable effect
 */
contract DirtyRevertClassificationTest is DirtyEntryPointsBase {
    uint256 internal swapId;
    OpenPuntStorage.MatchedSwap internal active;
    OpenPuntStorage.MatcherPreimage internal preimage;

    function setUp() public {
        _setUpDirty();
        (swapId, active, preimage) = _openHeartbeatPosition();
    }

    function _heartbeat() internal view returns (bytes memory) {
        return abi.encodeCall(punt.liquidationHeartbeat, (swapId, active));
    }

    // ── 1. empty ABI decode revert ──────────────────────────────────────

    function test_class1_emptyAbiDecodeRevert() public {
        bytes memory clean = _heartbeat();
        uint256 off = _argOffset(32 + 32 * 8); // MatchedSwap.notional padding
        Book memory before = _book(swapId, active.collatToken);

        (bool ok, bytes memory ret) = _rawCallPunt(outsider, 0, _withByte(clean, off + 15, 0x01));
        (uint8 kind, bytes4 sel) = _classify(ok, ret);
        assertEq(kind, R_EMPTY, "class 1: empty ABI decode revert");
        assertEq(sel, bytes4(0), "no selector");
        assertEq(ret.length, 0, "no returndata at all");
        _assertStateUnchanged(before, swapId, active.collatToken, "class 1");
    }

    // ── 2. WrongHash ────────────────────────────────────────────────────

    function test_class2_wrongHash() public {
        bytes memory clean = _heartbeat();
        uint256 off = _argOffset(32 + 32 * 8);
        Book memory before = _book(swapId, active.collatToken);

        (bool ok, bytes memory ret) =
            _rawCallPunt(outsider, 0, _withWord(clean, off, bytes32(uint256(active.notional) + 1)));
        (uint8 kind, bytes4 sel) = _classify(ok, ret);
        assertEq(kind, R_SELECTOR, "class 2: a custom error");
        assertEq(sel, PuntErrors.WrongHash.selector, "WrongHash");
        _assertStateUnchanged(before, swapId, active.collatToken, "class 2");
    }

    // ── 3. WrongOracleHash ──────────────────────────────────────────────

    /// @dev Generated from a canonical, correctly ABI-encoded OracleGame carrying a genuinely
    ///      different value. Dirty padding no longer produces this class — it belongs to class 1,
    ///      because `execute()` decodes the oracle structs into memory like every other path.
    function test_class3_wrongOracleHash() public {
        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);
        Matched memory mt =
            _reportOnPositionWithAmounts(swapId, _noDutch(), active, preimage, reporter, REPORT_EXEC_COMP, A1, A2_OPEN);
        _advanceToSettlementEligibility();

        bytes memory clean = abi.encodeCall(puntLifecycle.execute, (swapId, mt.swap, mt.game, mt.helper, false));
        uint256 off = _argOffset(960 + 32 * 0); // OracleGame.currentAmount1, a uint128
        _assertCleanWord(clean, off, bytes32(uint256(mt.game.currentAmount1)), "OracleGame.currentAmount1");
        Book memory before = _book(swapId, active.collatToken);

        // a value change inside the declared width, leaving the padding canonical
        bytes memory different = _withWord(clean, off, bytes32(uint256(mt.game.currentAmount1) + 1));
        (bool ok, bytes memory ret) = _rawCallPunt(closeExecutor, 0, different);
        (uint8 kind, bytes4 sel) = _classify(ok, ret);
        assertEq(kind, R_SELECTOR, "class 3: a custom error");
        assertEq(sel, PuntErrors.WrongOracleHash.selector, "WrongOracleHash");
        _assertStateUnchanged(before, swapId, active.collatToken, "class 3");
    }

    /// @dev The same field, mutated in its padding instead of its value, lands in class 1. This
    ///      pairing is what keeps the two classes distinguishable on the oracle path.
    function test_class3_dirtyPaddingOnTheSameFieldIsClass1() public {
        _advanceTimeAndBlocks(SETTLE_HOP_SECONDS, SETTLE_HOP_SECONDS / 2);
        Matched memory mt =
            _reportOnPositionWithAmounts(swapId, _noDutch(), active, preimage, reporter, REPORT_EXEC_COMP, A1, A2_OPEN);
        _advanceToSettlementEligibility();

        bytes memory clean = abi.encodeCall(puntLifecycle.execute, (swapId, mt.swap, mt.game, mt.helper, false));
        uint256 off = _argOffset(960 + 32 * 0); // OracleGame.currentAmount1 padding
        Book memory before = _book(swapId, active.collatToken);

        (bool ok, bytes memory ret) = _rawCallPunt(closeExecutor, 0, _withByte(clean, off + 15, 0x01));
        (uint8 kind,) = _classify(ok, ret);
        assertEq(kind, R_EMPTY, "dirty padding is an ABI decode failure, not WrongOracleHash");
        _assertStateUnchanged(before, swapId, active.collatToken, "class 3 padding variant");
    }

    // ── 4. InvalidSelector ──────────────────────────────────────────────

    function test_class4_invalidSelector() public {
        Book memory before = _book(swapId, active.collatToken);
        (bool ok, bytes memory ret) = _rawCallPunt(outsider, 0, abi.encodeWithSelector(bytes4(0xcafebabe)));
        (uint8 kind, bytes4 sel) = _classify(ok, ret);
        assertEq(kind, R_SELECTOR, "class 4: a custom error");
        assertEq(sel, PuntErrors.InvalidSelector.selector, "InvalidSelector");
        _assertStateUnchanged(before, swapId, active.collatToken, "class 4");
    }

    // ── 5. business-logic error ─────────────────────────────────────────

    function test_class5_businessLogicError() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _proposalCfg();
        bytes memory clean = abi.encodeCall(punt.propose, (s, m, _emptyPermit2()));
        uint256 value = _correctMsgValue(s);
        Book memory before = _book(0, address(collat));

        // a fully canonical, correctly-encoded nonzero swapper: the decoder is satisfied and the
        // contract's own guard is what rejects it
        (bool ok, bytes memory ret) =
            _rawCallPunt(swapper, value, _withWord(clean, _argOffset(0), bytes32(uint256(uint160(swapper)))));
        (uint8 kind, bytes4 sel) = _classify(ok, ret);
        assertEq(kind, R_SELECTOR, "class 5: a custom error");
        assertEq(sel, PuntErrors.MustBeZero.selector, "MustBeZero");
        _assertStateUnchanged(before, 0, address(collat), "class 5");
    }

    // ── 6. accepted-but-ignored noncanonical data ───────────────────────

    function test_class6_acceptedButIgnored() public {
        bytes memory clean = _heartbeat();

        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(outsider, 0, clean);
        assertTrue(okClean, "clean control");
        (uint128 idClean, uint48 tsClean) = punt.liquidationHeartbeats(swapId);
        bytes32 hashClean = punt.swaps(swapId);
        vm.revertToState(snap);

        (bool ok, bytes memory ret) = _rawCallPunt(outsider, 0, _append(clean, hex"deadbeef"));
        (uint8 kind,) = _classify(ok, ret);
        assertEq(kind, R_OK, "class 6: accepted");

        (uint128 idDirty, uint48 tsDirty) = punt.liquidationHeartbeats(swapId);
        assertEq(idDirty, idClean, "and the transition is identical");
        assertEq(tsDirty, tsClean, "and the transition is identical");
        assertEq(punt.swaps(swapId), hashClean, "stored hash excludes the suffix");
    }

    /// @dev The classes are genuinely distinct: byte-identical mutation shapes on two members of
    ///      the same struct can land in different classes, which is why the category is asserted
    ///      rather than merely `assertFalse(ok)`.
    function test_classesAreDistinguishable() public {
        bytes memory clean = _heartbeat();
        uint256 off = _argOffset(32 + 32 * 8);

        (bool okA, bytes memory retA) = _rawCallPunt(outsider, 0, _withByte(clean, off + 15, 0x01));
        (bool okB, bytes memory retB) =
            _rawCallPunt(outsider, 0, _withWord(clean, off, bytes32(uint256(active.notional) + 1)));

        (uint8 kindA,) = _classify(okA, retA);
        (uint8 kindB,) = _classify(okB, retB);
        assertTrue(kindA != kindB, "dirty padding and a different canonical value are NOT the same class");
    }
}
