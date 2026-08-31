// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";
import {RecordingPermit2} from "./util/RecordingPermit2.sol";
import {MintableERC20} from "./util/MintableERC20.sol";

/**
 * @notice What close() transmits to Permit2 when an ERC20 reward is funded externally.
 *
 * @dev Like the proposal-side transmission tests, this uses a
 *      permissive recorder. It proves the transmitted values only — never signature
 *      validity, nonce consumption, replay rejection, or deadline enforcement.
 *
 *      The close intent binds the canonical Dutch struct: caller input with swapper,
 *      collatToken, swapId and useInternalBalances already stamped, and `start` still zero.
 *      The absolute start timestamp is applied only afterwards.
 */
contract ClosePermit2IntentTest is CloseBase {
    bytes32 internal constant WITNESS_TYPEHASH =
        keccak256("Witness(address beneficiary,address relayer,address swapper,bytes32 intent)");
    string internal constant WITNESS_TYPE_STRING =
        "Witness witness)TokenPermissions(address token,uint256 amount)Witness(address beneficiary,address relayer,address swapper,bytes32 intent)";

    uint256 internal constant NONCE = 987_654;
    uint256 internal constant DEADLINE = 1_888_888_888;
    bytes internal SIGNATURE = hex"beef0102030405060708090a0b0c0d0e0f10";

    MintableERC20 internal collat2;
    address internal swapper2 = address(0x3001);

    function setUp() public {
        _setUpClose();

        collat2 = new MintableERC20("Collateral2", "COL2");
        collat2.mint(swapper, 1_000_000e18);
        vm.prank(swapper);
        collat2.approve(PERMIT2, type(uint256).max);

        // a second swapper able to run the identical lifecycle
        collat.mint(swapper2, 1_000_000e18);
        vm.deal(swapper2, 10_000 ether);
        vm.prank(swapper2);
        collat.approve(PERMIT2, type(uint256).max);
    }

    function _permitParams() internal view returns (OpenPuntStorage.Permit2Params memory) {
        return OpenPuntStorage.Permit2Params({nonce: NONCE, deadline: DEADLINE, signature: SIGNATURE});
    }

    // ── independent derivation ──────────────────────────────────────────

    /// @dev The intent a signer must produce: canonical Dutch with start still zero.
    function _closeIntent(
        OpenPuntStorage.CloseDutch memory input,
        uint256 swapId,
        address collatToken,
        address positionSwapper
    ) internal pure returns (bytes32) {
        OpenPuntStorage.CloseDutch memory d = _copy(input);
        d.swapper = positionSwapper;
        d.collatToken = collatToken;
        d.swapId = swapId;
        d.useInternalBalances = false; // Permit2 funding is external by definition
        d.start = 0; // stamped only after the intent is fixed
        return keccak256(abi.encode(d));
    }

    function _closeWitness(bytes32 intent, address signer) internal view returns (bytes32) {
        return keccak256(abi.encode(WITNESS_TYPEHASH, address(punt), address(punt), signer, intent));
    }

    function _closeWithPermit(
        uint256 swapId,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.CloseDutch memory input,
        address who
    ) internal {
        vm.prank(who);
        punt.close{value: CLOSE_COMP}(
            swapId, input, active, false, _permitParams(), CLOSE_COMP, _emptyOracleGame(), _emptyOracleHelper(), 0
        );
    }

    function _observedWitness() internal view returns (bytes32) {
        return _permit2().lastCall().witness;
    }

    // ══════════════════════════════════════════════════════════════════
    //  Exact transmitted payload
    // ══════════════════════════════════════════════════════════════════

    function test_closePermitCallIsExact() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory input = _dutchInput();

        uint256 calls0 = _permit2().callCount();
        uint256 custody0 = collat.balanceOf(address(oracle));
        uint256 coreCollat0 = _spendable(address(punt), address(collat));

        _closeWithPermit(swapId, active, input, swapper);

        RecordingPermit2.Call memory c = _permit2().lastCall();

        assertEq(_permit2().callCount(), calls0 + 1, "exactly one Permit2 call");
        assertTrue(c.hadWitness, "witness-bound variant used");
        assertEq(c.owner, swapper, "owner is the swapper");
        assertEq(c.permittedToken, address(collat), "permitted token is the position collateral");
        assertEq(c.permittedAmount, DUTCH_MAX, "permitted amount is maxReward");
        assertEq(c.requestedAmount, DUTCH_MAX, "requested amount is maxReward");
        assertEq(c.to, address(oracle), "tokens land with the oracle custodian");
        assertEq(c.nonce, NONCE, "nonce forwarded verbatim");
        assertEq(c.deadline, DEADLINE, "deadline forwarded verbatim");
        assertEq(keccak256(c.signature), keccak256(SIGNATURE), "signature forwarded verbatim");
        assertEq(keccak256(bytes(c.witnessTypeString)), keccak256(bytes(WITNESS_TYPE_STRING)), "type string verbatim");

        // beneficiary and relayer are both the core, and the intent is the canonical Dutch
        bytes32 intent = _closeIntent(input, swapId, address(collat), swapper);
        assertEq(c.witness, _closeWitness(intent, swapper), "witness matches the independent derivation");

        assertEq(collat.balanceOf(address(oracle)) - custody0, DUTCH_MAX, "oracle custodies the reward");
        assertEq(
            _spendable(address(punt), address(collat)) - coreCollat0, DUTCH_MAX, "core credited the reward internally"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  What the close intent binds
    // ══════════════════════════════════════════════════════════════════

    function test_swapIdIsBoundIntoTheIntent() public {
        (uint256 swapIdA, OpenPuntStorage.MatchedSwap memory activeA,) = _openIdle();
        (uint256 swapIdB, OpenPuntStorage.MatchedSwap memory activeB,) = _openIdle();
        OpenPuntStorage.CloseDutch memory input = _dutchInput();

        _closeWithPermit(swapIdA, activeA, input, swapper);
        bytes32 wA = _observedWitness();

        _closeWithPermit(swapIdB, activeB, input, swapper);
        bytes32 wB = _observedWitness();

        assertTrue(swapIdA != swapIdB, "two distinct positions");
        assertTrue(wA != wB, "the same reward curve on a different position is a different intent");
        assertEq(wA, _closeWitness(_closeIntent(input, swapIdA, address(collat), swapper), swapper), "A derivation");
        assertEq(wB, _closeWitness(_closeIntent(input, swapIdB, address(collat), swapper), swapper), "B derivation");
    }

    function test_expirationAndRewardCurveAreBound() public {
        (uint256 swapId1, OpenPuntStorage.MatchedSwap memory a1,) = _openIdle();
        (uint256 swapId2, OpenPuntStorage.MatchedSwap memory a2,) = _openIdle();
        (uint256 swapId3, OpenPuntStorage.MatchedSwap memory a3,) = _openIdle();
        (uint256 swapId4, OpenPuntStorage.MatchedSwap memory a4,) = _openIdle();

        OpenPuntStorage.CloseDutch memory base = _dutchInput();
        _closeWithPermit(swapId1, a1, base, swapper);
        bytes32 baseline = _observedWitness();

        OpenPuntStorage.CloseDutch memory diffExpiry = _copy(base);
        diffExpiry.expiration = base.expiration + 1;
        _closeWithPermit(swapId2, a2, diffExpiry, swapper);
        assertTrue(_observedWitness() != baseline, "expiration is bound");

        OpenPuntStorage.CloseDutch memory diffMax = _copy(base);
        diffMax.maxReward = base.maxReward + 1;
        _closeWithPermit(swapId3, a3, diffMax, swapper);
        assertTrue(_observedWitness() != baseline, "maxReward is bound");

        OpenPuntStorage.CloseDutch memory diffCurve = _copy(base);
        diffCurve.growthRate = base.growthRate + 1;
        _closeWithPermit(swapId4, a4, diffCurve, swapper);
        assertTrue(_observedWitness() != baseline, "growth rate is bound");
        assertEq(
            _observedWitness(),
            _closeWitness(_closeIntent(diffCurve, swapId4, address(collat), swapper), swapper),
            "and matches the derivation"
        );
    }

    function test_collateralTokenIsBound() public {
        (uint256 swapIdA, OpenPuntStorage.MatchedSwap memory activeA,) = _openIdle();

        // an otherwise identical position collateralised in a different ERC20
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _positionCfg(false, false);
        s.collatToken = address(collat2);
        vm.startPrank(matcher);
        collat2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
        collat2.mint(matcher, 1_000_000e18);
        vm.startPrank(matcher);
        oracle.deposit(address(collat2), 500_000e18, matcher);
        oracle.approveInternal(address(punt), address(collat2), type(uint256).max);
        vm.stopPrank();

        (uint256 swapIdB, OpenPuntStorage.MatchedSwap memory activeB,) = _openAccounting(s, m);

        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        _closeWithPermit(swapIdA, activeA, input, swapper);
        bytes32 wA = _observedWitness();
        _closeWithPermit(swapIdB, activeB, input, swapper);
        bytes32 wB = _observedWitness();

        assertTrue(wA != wB, "a different collateral token is a different intent");
        assertEq(_permit2().lastCall().permittedToken, address(collat2), "the second pull used the other token");
        assertEq(wB, _closeWitness(_closeIntent(input, swapIdB, address(collat2), swapper), swapper), "derivation");
    }

    function test_swapperIsBound() public {
        (uint256 swapIdA, OpenPuntStorage.MatchedSwap memory activeA,) = _openIdle();

        // an identical position owned by a different swapper
        address savedSwapper = swapper;
        swapper = swapper2;
        (uint256 swapIdB, OpenPuntStorage.MatchedSwap memory activeB,) = _openIdle();
        swapper = savedSwapper;

        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        _closeWithPermit(swapIdA, activeA, input, swapper);
        bytes32 wA = _observedWitness();
        _closeWithPermit(swapIdB, activeB, input, swapper2);
        bytes32 wB = _observedWitness();

        assertTrue(wA != wB, "a different swapper is a different intent");
        assertEq(_permit2().lastCall().owner, swapper2, "owner tracks the position swapper");
        assertEq(wB, _closeWitness(_closeIntent(input, swapIdB, address(collat), swapper2), swapper2), "derivation");
    }

    /// @dev The runtime `start` stamp lands in storage but must not appear in the signed intent.
    function test_absoluteStartIsNotSubstitutedIntoTheIntent() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        OpenPuntStorage.CloseDutch memory input = _dutchInput();

        uint48 startTs = uint48(vm.getBlockTimestamp());
        vm.recordLogs();
        _closeWithPermit(swapId, active, input, swapper);
        bytes32 observed = _observedWitness();

        OpenPuntStorage.CloseDutch memory stored = _decodeCloseAuctionStarted(vm.getRecordedLogs(), swapId);
        assertEq(stored.start, startTs, "the stored auction really does carry the timestamp");

        // the intent was built with start == 0
        assertEq(observed, _closeWitness(_closeIntent(input, swapId, address(collat), swapper), swapper), "start zero");

        // An intent computed with the stamped start is a different witness.
        OpenPuntStorage.CloseDutch memory withStart = _copy(input);
        withStart.start = startTs;
        OpenPuntStorage.CloseDutch memory canon = _copy(withStart);
        canon.swapper = swapper;
        canon.collatToken = address(collat);
        canon.swapId = swapId;
        assertTrue(
            observed != _closeWitness(keccak256(abi.encode(canon)), swapper),
            "the absolute start is NOT substituted into the intent"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  When Permit2 must not be involved
    // ══════════════════════════════════════════════════════════════════

    function test_internalAndNativeEthCloseFundingSkipPermit2() public {
        (uint256 swapIdA, OpenPuntStorage.MatchedSwap memory activeA,) = _openIdle();
        uint256 calls0 = _permit2().callCount();

        vm.prank(swapper);
        punt.close{value: 0}(
            swapIdA,
            _dutchInput(),
            activeA,
            true,
            _permitParams(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );
        assertEq(_permit2().callCount(), calls0, "internal auction funding never calls Permit2");

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _positionCfg(true, false);
        (uint256 swapIdB, OpenPuntStorage.MatchedSwap memory activeB,) = _openAccounting(s, m);

        vm.prank(swapper);
        punt.close{value: uint256(DUTCH_MAX) + CLOSE_COMP}(
            swapIdB,
            _dutchInput(),
            activeB,
            false,
            _permitParams(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );
        assertEq(_permit2().callCount(), calls0, "native ETH auction funding never calls Permit2");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Failed pull rolls back every close-state mutation
    // ══════════════════════════════════════════════════════════════════

    function test_failedRewardPullRollsBackAllCloseState() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        Snap memory before = _snap(swapId, active.collatToken);
        assertFalse(before.intent, "no intent before");
        assertEq(before.dutchHash, bytes32(0), "no auction before");

        vm.prank(swapper);
        collat.approve(PERMIT2, 0); // the pull cannot succeed

        vm.prank(swapper);
        vm.expectRevert();
        punt.close{value: CLOSE_COMP}(
            swapId,
            _dutchInput(),
            active,
            false,
            _permitParams(),
            CLOSE_COMP,
            _emptyOracleGame(),
            _emptyOracleHelper(),
            0
        );

        _assertUnchanged(before, swapId, active.collatToken, "failed reward pull");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "pending execution comp rolled back");
        assertFalse(intent, "close intent rolled back");
        assertEq(_storedDutchState(swapId), bytes32(0), "auction hash rolled back");

        // and it works once the allowance is restored
        vm.prank(swapper);
        collat.approve(PERMIT2, type(uint256).max);
        OpenPuntStorage.CloseDutch memory d = _startDefaultAuction(swapId, active);
        assertEq(_storedAuctionHash(swapId, active), keccak256(abi.encode(d)), "auction created on the retry");
    }
}
