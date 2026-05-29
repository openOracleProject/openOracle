// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";

/// @notice Complements OpenSwapDirtyCalldata's per-field lockdown. That suite proves no dirty
///         calldata bit can survive into propose()'s committed swapHash (every field, including the
///         three overrides, reverts at strict ABI decode). This suite proves the dual property the
///         dirty-calldata tests do NOT assert: that propose() actually CLOBBERS the three overridden
///         fields with the runtime values, so the committed hash binds:
///
///           swapper                 → msg.sender (caller), not the (must-be-zero) input
///           expiration              → block.timestamp + input offset (absolute), not the relative input
///           startFulfillFeeIncrease → block.timestamp at propose, not the (must-be-zero) input
///
///         If an override used a too-narrow store (leaving raw calldata bits in the hashed buffer) or
///         was skipped, the committed hash would reconstruct from the raw inputs instead of the
///         overrides — caught here. Reconstruction uses keccak256(abi.encode(s, m)), the exact form
///         matchSwap/cancelSwap reconstruct against (OpenSwapSlim L369), so a match here is the
///         contract's own liveness check.
contract OpenSwapProposeOverrideFaithfulnessTest is SlimTestBase {
    address internal swapper2 = address(0x1003);
    uint48 internal constant EXP_OFFSET = uint48(1 hours);

    function setUp() public {
        _setUpAll();
        // A second proposer on the identical permit2 sell path, so two proposes differ ONLY by caller.
        sellToken.transfer(swapper2, 100e18);
        vm.deal(swapper2, 10 ether);
        _setupSwapperPermit2(swapper2, address(sellToken));
    }

    function _cleanInputs()
        internal
        view
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        SwapCompat.SlippageParams memory slip = _defaultSlippage();
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();

        s.sellAmt = SELL_AMT;
        s.minFulfillLiquidity = MIN_FULFILL_LIQUIDITY;
        s.settlerReward = op.settlerReward;
        s.maxGameTime = op.maxGameTime;
        s.blocksPerSecond = op.blocksPerSecond;
        s.buyToken = address(buyToken);
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.sellToken = address(sellToken);
        s.executorGasComp = EXECUTOR_GAS_COMP;
        s.useInternalBalances = false;
        s.expiration = EXP_OFFSET;
        s.priceTolerated = slip.priceTolerated;
        s.toleranceRange = slip.toleranceRange;
        // s.swapper left 0 (required by propose's MustBeZero guard)

        m.initialLiquidity = op.initialLiquidity;
        m.escalationHalt = op.escalationHalt;
        m.settlementTime = op.settlementTime;
        m.disputeDelay = op.disputeDelay;
        m.protocolFee = op.protocolFee;
        m.multiplier = op.multiplier;
        m.maxFee = ff.maxFee;
        m.startingFee = ff.startingFee;
        m.roundLength = ff.roundLength;
        m.growthRate = ff.growthRate;
        m.maxRounds = ff.maxRounds;
        // m.startFulfillFeeIncrease left 0 (required by propose's MustBeZero guard)
    }

    function _propose(address caller)
        internal
        returns (uint256 swapId, openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        (s, m) = _cleanInputs();
        uint256 eth = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        vm.prank(caller);
        swapId = swapContract.propose{value: eth}(s, m, _emptyPermit2(), MIN_OUT);
    }

    // ─── Faithful clobber: committed hash binds the OVERRIDE values ──────────

    function testCommittedHashUsesOverriddenValues() public {
        (uint256 swapId, openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _propose(swapper);

        // Apply the overrides propose() is specified to perform.
        s.swapper = swapper;
        s.expiration = uint48(block.timestamp) + EXP_OFFSET;
        m.startFulfillFeeIncrease = uint48(block.timestamp);

        assertEq(swapContract.swaps(swapId), keccak256(abi.encode(s, m)), "committed hash binds overridden values");
    }

    function testRawInputsDoNotReconstructHash() public {
        (uint256 swapId, openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _propose(swapper);
        // s/m are the RAW inputs (swapper=0, relative expiration, startFulfillFeeIncrease=0).
        assertTrue(
            swapContract.swaps(swapId) != keccak256(abi.encode(s, m)),
            "raw inputs must NOT reconstruct (proves clobber happened)"
        );
    }

    // ─── Per-override isolation: each override is the sole differentiator ─────

    function testSwapperOverride_BindsCaller_NotInput() public {
        (uint256 swapId, openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _propose(swapper);
        s.expiration = uint48(block.timestamp) + EXP_OFFSET;
        m.startFulfillFeeIncrease = uint48(block.timestamp);

        // swapper = caller → matches.
        s.swapper = swapper;
        assertEq(swapContract.swaps(swapId), keccak256(abi.encode(s, m)), "swapper bound to caller");

        // any other swapper → no match.
        s.swapper = swapper2;
        assertTrue(swapContract.swaps(swapId) != keccak256(abi.encode(s, m)), "wrong swapper must not match");
    }

    function testExpirationOverride_BindsAbsolute_NotRelative() public {
        (uint256 swapId, openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _propose(swapper);
        s.swapper = swapper;
        m.startFulfillFeeIncrease = uint48(block.timestamp);

        // absolute = block.timestamp + offset → matches.
        s.expiration = uint48(block.timestamp) + EXP_OFFSET;
        assertEq(swapContract.swaps(swapId), keccak256(abi.encode(s, m)), "expiration bound to absolute");

        // relative offset (the raw input) → no match.
        s.expiration = EXP_OFFSET;
        assertTrue(swapContract.swaps(swapId) != keccak256(abi.encode(s, m)), "relative expiration must not match");
    }

    function testStartFulfillFeeOverride_BindsProposeTimestamp() public {
        // Warp to a distinctive timestamp so "block.timestamp" is unmistakably the source.
        vm.warp(1_000_000);
        (uint256 swapId, openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _propose(swapper);
        s.swapper = swapper;
        s.expiration = uint48(block.timestamp) + EXP_OFFSET;

        m.startFulfillFeeIncrease = uint48(block.timestamp); // == 1_000_000
        assertEq(swapContract.swaps(swapId), keccak256(abi.encode(s, m)), "startFulfillFeeIncrease bound to propose ts");

        m.startFulfillFeeIncrease = 0; // the raw input
        assertTrue(swapContract.swaps(swapId) != keccak256(abi.encode(s, m)), "zero input must not match");
    }

    // ─── Caller is the only varying input across two otherwise-identical proposes ───

    function testTwoCallers_DifferOnlyBySwapper() public {
        (uint256 id1, openSwapV2.ProposedSwap memory s1, openSwapV2.MatcherPreimage memory m1) = _propose(swapper);
        (uint256 id2, openSwapV2.ProposedSwap memory s2, openSwapV2.MatcherPreimage memory m2) = _propose(swapper2);

        // Same block → identical expiration/startFulfill overrides; only the swapper differs.
        assertTrue(swapContract.swaps(id1) != swapContract.swaps(id2), "different callers -> different hashes");

        s1.swapper = swapper;
        s1.expiration = uint48(block.timestamp) + EXP_OFFSET;
        m1.startFulfillFeeIncrease = uint48(block.timestamp);
        assertEq(swapContract.swaps(id1), keccak256(abi.encode(s1, m1)), "caller-1 hash reconstructs with swapper1");

        s2.swapper = swapper2;
        s2.expiration = uint48(block.timestamp) + EXP_OFFSET;
        m2.startFulfillFeeIncrease = uint48(block.timestamp);
        assertEq(swapContract.swaps(id2), keccak256(abi.encode(s2, m2)), "caller-2 hash reconstructs with swapper2");
    }
}
