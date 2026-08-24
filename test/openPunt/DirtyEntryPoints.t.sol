// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DirtyEntryPointsBase.t.sol";

/**
 * @notice One decisive dirty-argument test per state-changing core entry point, plus the
 *         top-level narrow arguments that no struct sweep reaches.
 *
 * @dev Each case follows the same five steps: prove the clean raw payload reaches its intended
 *      transition, restore the genuine pre-call state, submit a dirty variant, prove it cannot
 *      make that transition, and reconcile the phase hash and every balance the function could
 *      have touched.
 */
contract DirtyEntryPointsTest is DirtyEntryPointsBase {
    function setUp() public {
        _setUpDirty();
    }

    // ══════════════════════════════════════════════════════════════════
    //  propose
    // ══════════════════════════════════════════════════════════════════

    function test_propose_dirtyCollatTokenPadding() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _proposalCfg();
        bytes memory clean = abi.encodeCall(punt.propose, (s, m, _emptyPermit2()));
        uint256 value = _correctMsgValue(s);

        // ProposedSwap begins at argument offset 0; collatToken is word 1.
        uint256 off = _argOffset(32 * 1);
        _assertCleanWord(clean, off, bytes32(uint256(uint160(s.collatToken))), "ProposedSwap.collatToken");

        _proveCleanThenDirty(
            clean,
            _withByte(clean, off + 5, 0x01), // a padding byte of the address
            swapper,
            value,
            0,
            address(collat),
            "propose/collatToken padding"
        );
    }

    function test_propose_dirtyIsLongBoolean() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _proposalCfg();
        bytes memory clean = abi.encodeCall(punt.propose, (s, m, _emptyPermit2()));
        uint256 value = _correctMsgValue(s);

        uint256 off = _argOffset(32 * 8); // ProposedSwap.isLong
        _assertCleanWord(clean, off, bytes32(uint256(1)), "ProposedSwap.isLong");

        _proveCleanThenDirty(
            clean, _withWord(clean, off, bytes32(uint256(2))), swapper, value, 0, address(collat), "propose/isLong = 2"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  matchSwap — including the top-level amount2 and matcher arguments
    // ══════════════════════════════════════════════════════════════════

    function test_matchSwap_dirtyAmount2Padding() public {
        Proposal memory p = _propose();
        bytes memory clean =
            abi.encodeCall(punt.matchSwap, (p.swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), matcher));

        uint256 off = _argOffset(32 * 1); // top-level uint128 amount2
        _assertCleanWord(clean, off, bytes32(uint256(AMOUNT2)), "matchSwap.amount2");

        // amount2 is uint128: bytes 0..15 of its word are padding
        _proveCleanThenDirty(
            clean,
            _withByte(clean, off + 15, 0x01),
            matcher,
            0,
            p.swapId,
            p.swap.collatToken,
            "matchSwap/amount2 padding"
        );
    }

    function test_matchSwap_dirtyMatcherAddressPadding() public {
        Proposal memory p = _propose();
        bytes memory clean =
            abi.encodeCall(punt.matchSwap, (p.swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), matcher));

        uint256 off = _argOffset(64 + 25 * 32 + 12 * 32 + 4 * 32); // top-level address matcher
        _assertCleanWord(clean, off, bytes32(uint256(uint160(matcher))), "matchSwap.matcher");

        _proveCleanThenDirty(
            clean,
            _withByte(clean, off + 11, 0x01), // last padding byte before the 20 address bytes
            matcher,
            0,
            p.swapId,
            p.swap.collatToken,
            "matchSwap/matcher padding"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  liquidationHeartbeat
    // ══════════════════════════════════════════════════════════════════

    function test_liquidationHeartbeat_dirtyFeeRecipientPadding() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openHeartbeatPosition();
        bytes memory clean = abi.encodeCall(punt.liquidationHeartbeat, (swapId, active));

        uint256 off = _argOffset(32 + 32 * 14); // MatchedSwap.feeRecipient
        _assertCleanWord(clean, off, bytes32(uint256(uint160(active.feeRecipient))), "MatchedSwap.feeRecipient");

        _proveCleanThenDirty(
            clean,
            _withByte(clean, off + 11, 0x01),
            outsider,
            0,
            swapId,
            active.collatToken,
            "liquidationHeartbeat/feeRecipient padding"
        );

        (uint128 hbId, uint48 hbTs) = punt.liquidationHeartbeats(swapId);
        assertEq(hbTs, 0, "no heartbeat was set by the rejected call");
        assertEq(hbId, 0, "no heartbeat report binding either");
    }

    // ══════════════════════════════════════════════════════════════════
    //  close — including useInternalBalances and altGasCompExec
    // ══════════════════════════════════════════════════════════════════

    function test_close_dirtyUseInternalBalancesBoolean() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        bytes memory clean = abi.encodeCall(punt.close, (swapId, input, active, false, _emptyPermit2(), CLOSE_COMP));

        uint256 off = _argOffset(CLOSE_USE_INTERNAL_OFF);
        _assertCleanWord(clean, off, bytes32(uint256(0)), "close.useInternalBalances");

        _proveCleanThenDirty(
            clean,
            _withWord(clean, off, bytes32(uint256(2))),
            swapper,
            CLOSE_COMP,
            swapId,
            active.collatToken,
            "close/useInternalBalances = 2"
        );
        assertEq(_storedDutchState(swapId), bytes32(0), "no auction stored by the rejected call");
    }

    function test_close_dirtyAltGasCompExecPadding() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        bytes memory clean = abi.encodeCall(punt.close, (swapId, input, active, false, _emptyPermit2(), CLOSE_COMP));

        uint256 off = _argOffset(CLOSE_ALT_COMP_OFF);
        _assertCleanWord(clean, off, bytes32(uint256(CLOSE_COMP)), "close.altGasCompExec");

        _proveCleanThenDirty(
            clean,
            _withByte(clean, off + 15, 0x01), // uint128 padding
            swapper,
            CLOSE_COMP,
            swapId,
            active.collatToken,
            "close/altGasCompExec padding"
        );
        assertEq(_storedDutchState(swapId), bytes32(0), "no auction stored");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "no execution compensation recorded");
        assertFalse(intent, "no close intent recorded");
    }

    // ══════════════════════════════════════════════════════════════════
    //  cancelCloseAuction
    // ══════════════════════════════════════════════════════════════════

    function test_cancelCloseAuction_dirtyInitialMarginSwapperPadding() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory live = _startAuction(swapId, active, _dutchInput(), false, CLOSE_COMP);
        _advanceChain(uint256(live.expiration) - vm.getBlockTimestamp() + 2);

        bytes memory clean = abi.encodeCall(punt.cancelCloseAuction, (swapId, active));
        uint256 off = _argOffset(32 + 32 * 5); // MatchedSwap.initialMarginSwapper
        _assertCleanWord(clean, off, bytes32(uint256(active.initialMarginSwapper)), "MatchedSwap.initialMarginSwapper");

        bytes32 dutchBefore = _storedDutchState(swapId);
        _proveCleanThenDirty(
            clean,
            _withByte(clean, off + 15, 0x01),
            swapper,
            0,
            swapId,
            active.collatToken,
            "cancelCloseAuction/initialMarginSwapper padding"
        );
        assertEq(_storedDutchState(swapId), dutchBefore, "the live auction survives the rejected cancel");
    }

    // ══════════════════════════════════════════════════════════════════
    //  cancelSwapOpen
    // ══════════════════════════════════════════════════════════════════

    function test_cancelSwapOpen_dirtySettlerRewardPadding() public {
        Proposal memory p = _propose();
        bytes memory clean = abi.encodeCall(punt.cancelSwapOpen, (p.swapId, p.swap, p.preimage));

        uint256 off = _argOffset(32 + 32 * 21); // ProposedSwap.settlerReward, a uint96
        _assertCleanWord(clean, off, bytes32(uint256(p.swap.settlerReward)), "ProposedSwap.settlerReward");

        _proveCleanThenDirty(
            clean,
            _withByte(clean, off + 19, 0x01), // last padding byte before the 12 value bytes
            swapper,
            0,
            p.swapId,
            p.swap.collatToken,
            "cancelSwapOpen/settlerReward padding"
        );
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the proposal survives the rejected cancel");
    }

    // ══════════════════════════════════════════════════════════════════
    //  bailOut
    // ══════════════════════════════════════════════════════════════════

    function test_bailOut_dirtyStartPadding() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory matched, uint256 maxGameTime) = _matchedAwaitingBailout();
        bytes memory clean = abi.encodeCall(punt.bailOut, (swapId, matched));

        uint256 off = _argOffset(32 + 32 * 23); // MatchedSwap.start, a uint48
        _assertCleanWord(clean, off, bytes32(uint256(matched.start)), "MatchedSwap.start");

        _advanceChain(maxGameTime + 2); // make the clean bailout genuinely eligible

        _proveCleanThenDirty(
            clean, _withByte(clean, off + 25, 0x01), outsider, 0, swapId, matched.collatToken, "bailOut/start padding"
        );
        assertTrue(punt.swaps(swapId) != bytes32(0), "the position survives the rejected bailout");
    }

    // ══════════════════════════════════════════════════════════════════
    //  dust
    // ══════════════════════════════════════════════════════════════════

    function test_dust_dirtyRecipientAddressPadding() public {
        address target = address(0xD05701);
        bytes memory clean = abi.encodeCall(punt.dust, (target));
        uint256 off = _argOffset(0);
        _assertCleanWord(clean, off, bytes32(uint256(uint160(target))), "dust._to");

        uint256 before = punt.tempHolding(target);

        // clean control: reaches its transition
        uint256 snap = vm.snapshotState();
        (bool okClean,) = _rawCallPunt(outsider, 1, clean);
        assertTrue(okClean, "clean dust succeeds");
        assertEq(punt.tempHolding(target), before + 1, "clean dust seeds the sentinel");
        vm.revertToState(snap);

        // dirty: a nonzero byte in the address padding
        uint256 puntEthBefore = address(punt).balance;
        (bool ok, bytes memory ret) = _rawCallPunt(outsider, 1, _withByte(clean, off + 3, 0x01));
        _assertRevertedEmpty(ok, ret, "dust/_to padding");
        assertEq(punt.tempHolding(target), before, "no sentinel seeded");
        assertEq(punt.tempHolding(address(uint160(uint256(_readWord(clean, off))))), before, "nor on the low bits");
        assertEq(address(punt).balance, puntEthBefore, "and the 1 wei never landed");
    }

    // ══════════════════════════════════════════════════════════════════
    //  withdraw — including the top-level _to and leaveOne arguments
    // ══════════════════════════════════════════════════════════════════

    function test_withdraw_dirtyRecipientAddressPadding() public {
        address target = address(0xADD1);
        _seedTempHolding(target, 5);

        bytes memory clean = abi.encodeCall(punt.withdraw, (target, true));
        uint256 off = _argOffset(0);
        _assertCleanWord(clean, off, bytes32(uint256(uint160(target))), "withdraw._to");

        uint256 held = punt.tempHolding(target);
        uint256 targetEth = target.balance;
        uint256 puntEth = address(punt).balance;

        (bool ok, bytes memory ret) = _rawCallPunt(outsider, 0, _withByte(clean, off + 0, 0x01));
        _assertRevertedEmpty(ok, ret, "withdraw/_to padding");
        assertEq(punt.tempHolding(target), held, "credit untouched");
        assertEq(target.balance, targetEth, "recipient not paid");
        assertEq(address(punt).balance, puntEth, "core ETH untouched");

        // and the clean call still works afterwards
        (bool ok2,) = _rawCallPunt(outsider, 0, clean);
        assertTrue(ok2, "clean withdraw succeeds");
        assertEq(punt.tempHolding(target), 1, "sentinel preserved");
    }

    function test_withdraw_dirtyLeaveOneBoolean() public {
        address target = address(0xADD2);
        _seedTempHolding(target, 5);

        bytes memory clean = abi.encodeCall(punt.withdraw, (target, true));
        uint256 off = _argOffset(32);
        _assertCleanWord(clean, off, bytes32(uint256(1)), "withdraw.leaveOne");

        uint256 held = punt.tempHolding(target);
        uint256 targetEth = target.balance;

        (bool ok, bytes memory ret) = _rawCallPunt(outsider, 0, _withWord(clean, off, bytes32(uint256(2))));
        _assertRevertedEmpty(ok, ret, "withdraw/leaveOne = 2");
        assertEq(punt.tempHolding(target), held, "credit untouched");
        assertEq(target.balance, targetEth, "recipient not paid");

        // Canonical false is a different legal value and decodes, proving that 2 was rejected
        // is about the value, not about the argument being unreadable
        (bool okFalse,) = _rawCallPunt(target, 0, abi.encodeCall(punt.withdraw, (target, false)));
        assertTrue(okFalse, "canonical false decodes and executes");
        assertEq(punt.tempHolding(target), 0, "leaveOne == false drains the slot entirely");
    }
}
