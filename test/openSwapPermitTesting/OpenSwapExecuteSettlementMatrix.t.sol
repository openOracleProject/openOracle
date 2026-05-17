// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";

/// @notice Behavior matrix for openSwap.execute()'s oracle-state handling.
///
///         execute() must succeed across four "shapes" of caller-passed OracleGame
///         and reject the loose-timing variants when looseTiming=false:
///
///           1. PreSettleDirect      — oracle not yet settled; caller passes
///                                     pre-settle preimage (settlementTimestamp=0).
///                                     Direct hash match. execute settles internally.
///                                     looseTiming irrelevant.
///           2. PreSettleSameBlock   — settle was called earlier in the SAME block;
///                                     caller passes pre-settle preimage; hash
///                                     mismatch. Loose-timing branch at line 594
///                                     substitutes timestamp() and matches the
///                                     post-settle hash. Requires looseTiming=true.
///           3. PostSettleDirect     — oracle was settled in a prior block; caller
///                                     passes the post-settle preimage with the
///                                     real settlementTimestamp. Direct hash match.
///                                     looseTiming irrelevant.
///           4. PostSettleOffByTwo   — oracle settled in a prior block at T; caller
///                                     passes preimage with settlementTimestamp=T+2
///                                     (a stale "current block" estimate). Loose-(t-2)
///                                     branch at line 604 substitutes timestamp()-2.
///                                     Requires looseTiming=true.
///
///         For each loose path we also assert that looseTiming=false reverts with
///         WrongOracleHash().
contract OpenSwapExecuteSettlementMatrixTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    function _proposeMatch()
        internal
        returns (
            uint256 swapId,
            uint128 reportId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        )
    {
        uint48 expiration;
        (swapId, expiration) = _propose();
        (openSwapV2.ProposedSwap memory s0, openSwapV2.MatcherPreimage memory m0) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 rid, , openSwapV2.MatchedSwap memory sp) = _match(swapId, 2000e18, expiration);
        sp.feeRecipient = address(0); // protocolFee = 0 in defaults
        reportId = rid;
        sPost = sp;
        og = _buildOracleGameAtReport(s0, m0, 2000e18);
        ph = _buildPreimageHelper(rid);
    }

    // ── 1. Pre-settle direct path ──────────────────────────────────────────────

    function testExecute_PreSettleDirect_Succeeds() public {
        (
            uint256 swapId,
            ,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatch();

        // Warp past settlementTime but DON'T pre-settle. og.settlementTimestamp stays 0.
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);

        vm.prank(settler);
        swapContract.execute(swapId, sPost, og, ph, false); // looseTiming irrelevant
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap deleted");
    }

    // ── 2. Pre-settle same-block-loose ─────────────────────────────────────────

    function testExecute_PreSettleSameBlockLoose_RequiresLooseTiming() public {
        (
            uint256 swapId,
            uint128 reportId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatch();

        // Warp past settlementTime so the report can settle.
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);

        // Pre-settle in this block. og remains the pre-settle preimage (settlementTimestamp=0).
        _settle(reportId, og, ph);
        // Same block: block.timestamp unchanged.

        // looseTiming=false should fail (direct hash mismatch).
        vm.prank(settler);
        try swapContract.execute(swapId, sPost, og, ph, false) {
            revert("expected revert");
        } catch (bytes memory ret) {
            assertEq(bytes4(ret), bytes4(keccak256("WrongOracleHash()")), "no looseTiming -> WrongOracleHash");
        }

        // looseTiming=true should succeed via the same-block fallback.
        vm.prank(settler);
        swapContract.execute(swapId, sPost, og, ph, true);
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap deleted after loose-success");
    }

    // ── 3. Post-settle direct ──────────────────────────────────────────────────

    function testExecute_PostSettleDirect_Succeeds() public {
        (
            uint256 swapId,
            uint128 reportId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatch();

        uint48 settledAt = uint48(block.timestamp) + SETTLEMENT_TIME + 1;
        vm.warp(uint256(settledAt));
        _settle(reportId, og, ph);
        // Advance past the settle block. Use the captured settledAt (not re-reading
        // block.timestamp) to avoid the Solidity-optimizer caching issue across vm.warp.
        vm.warp(uint256(settledAt) + 10);

        // Build post-settle preimage with the exact settlementTimestamp.
        IOpenOracle2.OracleGame memory ogPost = og;
        ogPost.settlementTimestamp = settledAt;

        vm.prank(settler);
        swapContract.execute(swapId, sPost, ogPost, ph, false);
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap deleted");
    }

    // ── 4. Post-settle off-by-2 ────────────────────────────────────────────────

    function testExecute_PostSettleOffByTwo_RequiresLooseTiming() public {
        (
            uint256 swapId,
            uint128 reportId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatch();

        uint48 settledAt = uint48(block.timestamp) + SETTLEMENT_TIME + 1;
        vm.warp(uint256(settledAt));
        _settle(reportId, og, ph);

        // Advance exactly 2 seconds so the loose-(t-2) branch's substitution lands on settledAt.
        vm.warp(uint256(settledAt) + 2);

        // Caller's preimage uses the post-warp block.timestamp as their guess. Off-by-2 from actual.
        uint48 callerGuess = settledAt + 2;
        IOpenOracle2.OracleGame memory ogGuessed = og;
        ogGuessed.settlementTimestamp = callerGuess;
        assertTrue(callerGuess != settledAt, "test guess differs from actual");
        assertTrue(callerGuess > 2, "loose-t-2 only fires when settlementTimestamp > 2");

        // looseTiming=false: direct mismatch, no fallback → WrongOracleHash.
        vm.prank(settler);
        try swapContract.execute(swapId, sPost, ogGuessed, ph, false) {
            revert("expected revert");
        } catch (bytes memory ret) {
            assertEq(bytes4(ret), bytes4(keccak256("WrongOracleHash()")), "no looseTiming -> WrongOracleHash");
        }

        // looseTiming=true: loose-(t-2) substitutes timestamp()-2 = settledAt → matches.
        vm.prank(settler);
        swapContract.execute(swapId, sPost, ogGuessed, ph, true);
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap deleted after loose-(t-2) success");
    }

    // ── 5. Sanity: pre-settle path with stale preimage that doesn't match either loose form ──

    function testExecute_StalePostSettlePreimage_AlwaysReverts() public {
        (
            uint256 swapId,
            uint128 reportId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatch();

        uint48 settledAt = uint48(block.timestamp) + SETTLEMENT_TIME + 1;
        vm.warp(uint256(settledAt));
        _settle(reportId, og, ph);
        // Warp 1 hour — neither the same-block-loose nor (t-2) loose branch will match.
        vm.warp(uint256(settledAt) + 3600);

        IOpenOracle2.OracleGame memory ogStale = og;
        ogStale.settlementTimestamp = settledAt + 3600; // wildly off from the real settle ts

        // Both looseTiming variants revert because the substituted hashes don't match either.
        vm.prank(settler);
        try swapContract.execute(swapId, sPost, ogStale, ph, true) {
            revert("expected revert with looseTiming=true");
        } catch (bytes memory ret) {
            assertEq(bytes4(ret), bytes4(keccak256("WrongOracleHash()")), "looseTiming=true still wrong");
        }

        vm.prank(settler);
        try swapContract.execute(swapId, sPost, ogStale, ph, false) {
            revert("expected revert with looseTiming=false");
        } catch (bytes memory ret) {
            assertEq(bytes4(ret), bytes4(keccak256("WrongOracleHash()")), "looseTiming=false WrongOracleHash");
        }
    }
}
