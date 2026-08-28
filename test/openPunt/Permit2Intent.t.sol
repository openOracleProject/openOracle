// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";
import {RecordingPermit2} from "./util/RecordingPermit2.sol";

/**
 * @notice What OpenPunt/OpenOracle actually transmit to Permit2 on a proposal.
 *
 * @dev The installed Permit2 is a permissive recorder: it does not verify
 *      signatures, does not consume or reject nonces, and does not enforce deadlines.
 *      Nothing here may be read as evidence of signature validity, replay protection, or
 *      deadline enforcement — only that the intended values were transmitted. Those three
 *      properties require an integration test against the real Permit2 deployment.
 */
contract Permit2IntentTest is OpenPuntBase {
    bytes32 internal constant WITNESS_TYPEHASH =
        keccak256("Witness(address beneficiary,address relayer,address swapper,bytes32 intent)");

    string internal constant WITNESS_TYPE_STRING =
        "Witness witness)TokenPermissions(address token,uint256 amount)Witness(address beneficiary,address relayer,address swapper,bytes32 intent)";

    uint256 internal constant NONCE = 123_456;
    uint256 internal constant DEADLINE = 1_999_999_999;
    bytes internal SIGNATURE = hex"c0ffee0102030405060708090a0b0c0d0e0f";

    function setUp() public {
        _setUpAll();
        collat.mint(swapper, type(uint96).max);

        // a second, differently-addressed swapper for the "who signed" case
        collat.mint(outsider, 10_000e18);
        vm.prank(outsider);
        collat.approve(PERMIT2, type(uint256).max);
        vm.deal(outsider, 10 ether);
    }

    function _permitParams() internal view returns (OpenPuntStorage.Permit2Params memory) {
        return OpenPuntStorage.Permit2Params({nonce: NONCE, deadline: DEADLINE, signature: SIGNATURE});
    }

    // ── independent derivations ─────────────────────────────────────────

    /// @dev Rebuilds the intent exactly as a signer would have to: the caller's raw input,
    ///      with only the swapper override applied. The expiration is still the caller-supplied
    ///      duration and startFulfillFeeIncrease is still the required zero.
    function _expectedIntent(
        OpenPuntStorage.ProposedSwap memory rawSwap,
        OpenPuntStorage.MatcherPreimage memory rawPreimage,
        address actualCaller
    ) internal pure returns (bytes32) {
        OpenPuntStorage.ProposedSwap memory intentSwap = _copy(rawSwap);
        intentSwap.swapper = actualCaller;
        return keccak256(abi.encode(intentSwap, rawPreimage));
    }

    function _expectedWitness(bytes32 intent, address signer) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                WITNESS_TYPEHASH,
                address(punt), // beneficiary: collateral is credited to the core
                address(punt), // relayer: the core is what calls the oracle
                signer, // swapper: the account whose tokens move
                intent
            )
        );
    }

    function _proposeFrom(address who, OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
        internal
        returns (uint256 swapId)
    {
        uint256 value = uint256(s.matcherGasComp) + s.settlerReward + s.openExecutionComp;
        vm.prank(who);
        swapId = punt.propose{value: value}(s, m, _permitParams());
    }

    function _observedWitness() internal view returns (bytes32) {
        return _permit2().lastCall().witness;
    }

    // ══════════════════════════════════════════════════════════════════
    //  Exact transmitted payload
    // ══════════════════════════════════════════════════════════════════

    function test_transmittedPermitCallIsExact() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();

        uint256 calls0 = _permit2().callCount();
        uint256 oracleCustody0 = collat.balanceOf(address(oracle));
        _proposeFrom(swapper, s, m);

        RecordingPermit2.Call memory c = _permit2().lastCall();

        assertEq(_permit2().callCount(), calls0 + 1, "exactly one Permit2 call");
        assertTrue(c.hadWitness, "witness-bound variant used");
        assertEq(c.owner, swapper, "owner is the swapper");
        assertEq(c.permittedToken, address(collat), "permitted token");
        assertEq(c.permittedAmount, INITIAL_MARGIN_SWAPPER, "permitted amount");
        assertEq(c.requestedAmount, INITIAL_MARGIN_SWAPPER, "requested amount");
        // Tokens are pulled into the oracle, which then credits the core's internal ledger.
        // The core is the witness `beneficiary`, never the ERC20 transfer destination.
        assertEq(c.to, address(oracle), "transfer destination is the oracle custodian");
        assertEq(_spendable(address(punt), address(collat)), INITIAL_MARGIN_SWAPPER, "core credited internally");
        assertEq(
            collat.balanceOf(address(oracle)) - oracleCustody0,
            INITIAL_MARGIN_SWAPPER,
            "oracle custodies the pulled tokens"
        );
        assertEq(c.nonce, NONCE, "nonce forwarded verbatim");
        assertEq(c.deadline, DEADLINE, "deadline forwarded verbatim");
        assertEq(keccak256(c.signature), keccak256(SIGNATURE), "signature bytes forwarded verbatim");
        assertEq(
            keccak256(bytes(c.witnessTypeString)),
            keccak256(bytes(WITNESS_TYPE_STRING)),
            "witness type string forwarded verbatim"
        );
        assertEq(c.witness, _expectedWitness(_expectedIntent(s, m, swapper), swapper), "witness matches derivation");
    }

    // ══════════════════════════════════════════════════════════════════
    //  What the intent binds
    // ══════════════════════════════════════════════════════════════════

    function test_changedProposedSwapFieldChangesWitness() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();

        _proposeFrom(swapper, s, m);
        bytes32 baseline = _observedWitness();

        OpenPuntStorage.ProposedSwap memory s2 = _copy(s);
        s2.notional = s.notional + 1;
        _proposeFrom(swapper, s2, m);

        assertTrue(_observedWitness() != baseline, "notional change moves the witness");
        assertEq(
            _observedWitness(), _expectedWitness(_expectedIntent(s2, m, swapper), swapper), "and matches derivation"
        );
    }

    function test_maturityOnlyChangesTheWitness() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();

        _proposeFrom(swapper, s, m);
        bytes32 baseline = _observedWitness();

        OpenPuntStorage.ProposedSwap memory fixedMaturity = _copy(s);
        fixedMaturity.maturityOnly = true;
        _proposeFrom(swapper, fixedMaturity, m);

        assertTrue(_observedWitness() != baseline, "maturity-only mode moves the witness");
        assertEq(
            _observedWitness(),
            _expectedWitness(_expectedIntent(fixedMaturity, m, swapper), swapper),
            "and matches the independently derived intent"
        );
    }

    function test_changedMatcherPreimageFieldChangesWitness() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();

        _proposeFrom(swapper, s, m);
        bytes32 baseline = _observedWitness();

        OpenPuntStorage.MatcherPreimage memory m2 = _copy(m);
        m2.initialLiquidity = m.initialLiquidity + 1;
        _proposeFrom(swapper, s, m2);

        assertTrue(_observedWitness() != baseline, "preimage change moves the witness");
        assertEq(
            _observedWitness(), _expectedWitness(_expectedIntent(s, m2, swapper), swapper), "and matches derivation"
        );
    }

    function test_differentSwapperChangesWitness() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();

        _proposeFrom(swapper, s, m);
        bytes32 fromSwapper = _observedWitness();

        _proposeFrom(outsider, s, m);
        bytes32 fromOutsider = _observedWitness();

        assertTrue(fromSwapper != fromOutsider, "a different caller yields a different witness");
        assertEq(fromOutsider, _expectedWitness(_expectedIntent(s, m, outsider), outsider), "matches derivation");
        assertEq(_permit2().lastCall().owner, outsider, "owner tracks the actual caller");
    }

    /// @dev The signer commits to the relative duration they supplied, so changing it re-signs.
    function test_relativeExpirationDurationIsBound() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();

        _proposeFrom(swapper, s, m);
        bytes32 baseline = _observedWitness();

        OpenPuntStorage.ProposedSwap memory s2 = _copy(s);
        s2.expiration = s.expiration + 1; // still a duration at this point
        _proposeFrom(swapper, s2, m);

        assertTrue(_observedWitness() != baseline, "duration change moves the witness");
        assertEq(_observedWitness(), _expectedWitness(_expectedIntent(s2, m, swapper), swapper), "matches derivation");
    }

    /// @dev Identical raw input signed once must remain valid whenever it lands.
    function test_proposalTimestampDoesNotChangeWitness() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();

        _proposeFrom(swapper, s, m);
        bytes32 early = _observedWitness();

        _advanceChain(4 hours);

        _proposeFrom(swapper, s, m);
        bytes32 late = _observedWitness();

        assertEq(early, late, "witness is timestamp-independent for identical raw input");
    }

    /// @dev The two timestamp-derived overrides land in storage after the intent is fixed, so
    ///      neither may appear inside the signed intent.
    function test_runtimeOverridesAreNotSubstitutedIntoTheIntent() public {
        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();

        uint48 proposeTs = uint48(vm.getBlockTimestamp());
        vm.recordLogs();
        uint256 swapId = _proposeFrom(swapper, s, m);
        bytes32 observed = _observedWitness();

        (OpenPuntStorage.ProposedSwap memory emitted, OpenPuntStorage.MatcherPreimage memory emittedM) =
            _decodeSwapProposed(vm.getRecordedLogs(), swapId);

        // the overrides really did happen in the stored/emitted state
        assertEq(emitted.expiration, proposeTs + s.expiration, "expiration became absolute in storage");
        assertEq(emittedM.startFulfillFeeIncrease, proposeTs, "startFulfillFeeIncrease stamped in storage");

        // ...yet the intent is built from the pre-override values
        assertEq(observed, _expectedWitness(_expectedIntent(s, m, swapper), swapper), "intent uses raw input");

        // A witness computed with the absolute expiration is a different witness.
        OpenPuntStorage.ProposedSwap memory withAbsolute = _copy(s);
        withAbsolute.expiration = emitted.expiration;
        assertTrue(
            observed != _expectedWitness(_expectedIntent(withAbsolute, m, swapper), swapper),
            "absolute expiration is NOT substituted into the intent"
        );

        // ...and so is one computed with the stamped proposal timestamp
        OpenPuntStorage.MatcherPreimage memory withStamp = _copy(m);
        withStamp.startFulfillFeeIncrease = proposeTs;
        assertTrue(
            observed != _expectedWitness(_expectedIntent(s, withStamp, swapper), swapper),
            "proposal timestamp is NOT substituted into the intent"
        );

        // the swapper override, by contrast, IS inside the intent
        OpenPuntStorage.ProposedSwap memory withoutSwapper = _copy(s); // swapper still address(0)
        assertTrue(
            observed != _expectedWitness(keccak256(abi.encode(withoutSwapper, m)), swapper),
            "the swapper override IS part of the intent"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  When Permit2 must not be involved
    // ══════════════════════════════════════════════════════════════════

    function test_internalBalanceProposalSkipsPermit2() public {
        vm.startPrank(swapper);
        collat.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(collat), INITIAL_MARGIN_SWAPPER, swapper);
        oracle.approveInternal(address(punt), address(collat), type(uint256).max);
        vm.stopPrank();

        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.useInternalBalances = true;

        uint256 calls0 = _permit2().callCount();
        _proposeFrom(swapper, s, _defaultMatcherPreimage());

        assertEq(_permit2().callCount(), calls0, "internal-balance proposal never calls Permit2");
    }

    function test_nativeEthProposalSkipsPermit2() public {
        vm.deal(swapper, 10_000 ether);

        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        s.collatToken = address(0);

        uint256 calls0 = _permit2().callCount();
        uint256 value =
            uint256(s.matcherGasComp) + s.settlerReward + s.openExecutionComp + uint256(s.initialMarginSwapper);
        vm.prank(swapper);
        punt.propose{value: value}(s, _defaultMatcherPreimage(), _permitParams());

        assertEq(_permit2().callCount(), calls0, "native ETH proposal never calls Permit2");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Failed pull rolls everything back
    // ══════════════════════════════════════════════════════════════════

    function test_failedTokenPullRollsBackEverything() public {
        // revoke the ERC20 allowance Permit2 relies on; the pull inside propose must fail
        vm.prank(swapper);
        collat.approve(PERMIT2, 0);

        uint256 idBefore = punt.nextSwapId();
        uint256 puntEth = address(punt).balance;
        uint256 puntCollat = oracle.tokenHolder(address(punt), address(collat));
        uint256 swapperCollat = collat.balanceOf(swapper);
        uint256 calls0 = _permit2().callCount();

        OpenPuntStorage.ProposedSwap memory s = _defaultProposedSwap();
        uint256 value = uint256(s.matcherGasComp) + s.settlerReward + s.openExecutionComp;

        vm.prank(swapper);
        vm.expectRevert();
        punt.propose{value: value}(s, _defaultMatcherPreimage(), _permitParams());

        assertEq(punt.nextSwapId(), idBefore, "nextSwapId rolled back");
        assertEq(punt.swaps(idBefore), bytes32(0), "no swap hash stored");
        assertEq(address(punt).balance, puntEth, "no ETH retained by the core");
        assertEq(oracle.tokenHolder(address(punt), address(collat)), puntCollat, "no oracle credit to the core");
        assertEq(collat.balanceOf(swapper), swapperCollat, "swapper collateral untouched");
        assertEq(_permit2().callCount(), calls0, "recorded call rolled back with the revert");

        // and the proposal still works once the allowance is restored
        vm.prank(swapper);
        collat.approve(PERMIT2, type(uint256).max);
        uint256 swapId = _proposeFrom(swapper, s, _defaultMatcherPreimage());
        assertEq(swapId, idBefore, "the same swapId is issued after recovery");
        assertTrue(punt.swaps(swapId) != bytes32(0), "swap stored on the retry");
    }
}
