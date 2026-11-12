// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";

/// @notice Behavior matrix for openSwap.execute()'s oracle-state handling.
///
///         execute() must succeed across four "shapes" of caller-passed OracleGame
///         and reject the stale-settlement variants when settlementSearchDepth is too small:
///
///           1. PreSettleDirect      — oracle not yet settled; caller passes
///                                     pre-settle preimage (settlementTimestamp=0).
///                                     Direct hash match. execute settles internally.
///                                     settlementSearchDepth irrelevant.
///           2. PreSettleSameBlock   — settle was called earlier in the SAME block;
///                                     caller passes pre-settle preimage; hash
///                                     mismatch. The search tries block.number first
///                                     and matches the post-settle hash. Requires depth >= 1.
///           3. PostSettleDirect     — oracle was settled in a prior block; caller
///                                     passes the post-settle preimage with the
///                                     real settlementTimestamp. Direct hash match.
///                                     settlementSearchDepth irrelevant.
///           4. PreSettleEarlierBlock — oracle settled at block B; caller passes the
///                                     pre-settle preimage k blocks later. The search
///                                     reaches B only when depth > k.
///
///         For each recovered path we also assert that a too-small depth reverts with
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

    function _expectWrongOracleHash(
        uint256 swapId,
        openSwapV2.MatchedSwap memory sPost,
        IOpenOracle2.OracleGame memory og,
        IOpenOracle2.PreimageHelper memory ph,
        uint8 settlementSearchDepth,
        string memory label
    ) internal {
        vm.prank(settler);
        try swapContract.execute(swapId, sPost, og, ph, settlementSearchDepth) {
            revert(string.concat("expected revert: ", label));
        } catch (bytes memory ret) {
            assertEq(bytes4(ret), bytes4(keccak256("WrongOracleHash()")), label);
        }
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

        // Roll past settlementTime but DON'T pre-settle. og.settlementTimestamp stays 0.
        vm.roll(block.number + SETTLEMENT_TIME + 1);

        vm.prank(settler);
        swapContract.execute(swapId, sPost, og, ph, 0); // settlementSearchDepth irrelevant
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap deleted");
    }

    // ── 2. Pre-settle same block ───────────────────────────────────────────────

    function testExecute_PreSettleSameBlock_RequiresDepthOne() public {
        (
            uint256 swapId,
            uint128 reportId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatch();

        // Roll past settlementTime so the report can settle.
        vm.roll(block.number + SETTLEMENT_TIME + 1);

        // Pre-settle in this block. og remains the pre-settle preimage (settlementTimestamp=0).
        _settle(reportId, og, ph);

        _expectWrongOracleHash(swapId, sPost, og, ph, 0, "depth 0 -> WrongOracleHash");

        // Depth 1 tries the current block, which is the settle block.
        vm.prank(settler);
        swapContract.execute(swapId, sPost, og, ph, 1);
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap deleted after same-block recovery");
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

        uint48 settledAt = uint48(block.number) + SETTLEMENT_TIME + 1;
        vm.roll(uint256(settledAt));
        _settle(reportId, og, ph);
        // Advance past the settle block. Use the captured settledAt (not re-reading
        // block.number) to avoid the Solidity-optimizer caching issue across vm.roll.
        vm.roll(uint256(settledAt) + 10);

        // Build post-settle preimage with the exact settlementTimestamp.
        IOpenOracle2.OracleGame memory ogPost = og;
        ogPost.settlementTimestamp = settledAt;

        vm.prank(settler);
        swapContract.execute(swapId, sPost, ogPost, ph, 0);
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap deleted");
    }

    // ── 4. Pre-settle preimage, settled in an earlier block ────────────────────

    function testExecute_PreSettleEarlierBlock_RequiresDepthPastSettleBlock() public {
        (
            uint256 swapId,
            uint128 reportId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatch();

        uint48 settledAt = uint48(block.number) + SETTLEMENT_TIME + 1;
        vm.roll(uint256(settledAt));
        _settle(reportId, og, ph);

        // Caller's tx lands 2 blocks after the settle, built from the pre-settle state.
        vm.roll(uint256(settledAt) + 2);

        // Depth 2 tries settledAt+2 and settledAt+1 only.
        _expectWrongOracleHash(swapId, sPost, og, ph, 2, "depth 2 -> WrongOracleHash");

        // Depth 3 reaches settledAt.
        vm.prank(settler);
        swapContract.execute(swapId, sPost, og, ph, 3);
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap deleted after earlier-block recovery");
    }

    // ── 5. Sanity: preimages the search cannot recover ─────────────────────────

    function testExecute_StalePostSettlePreimage_AlwaysReverts() public {
        (
            uint256 swapId,
            uint128 reportId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _proposeMatch();

        uint48 settledAt = uint48(block.number) + SETTLEMENT_TIME + 1;
        vm.roll(uint256(settledAt));
        _settle(reportId, og, ph);
        // 300 blocks later: beyond the largest possible depth (255).
        vm.roll(uint256(settledAt) + 300);

        _expectWrongOracleHash(swapId, sPost, og, ph, type(uint8).max, "settle beyond max depth -> WrongOracleHash");

        // A wrong nonzero settlementTimestamp is never searched.
        IOpenOracle2.OracleGame memory ogStale = og;
        ogStale.settlementTimestamp = settledAt + 300;
        _expectWrongOracleHash(swapId, sPost, ogStale, ph, type(uint8).max, "wrong guess -> WrongOracleHash");
        _expectWrongOracleHash(swapId, sPost, ogStale, ph, 0, "wrong guess, depth 0 -> WrongOracleHash");
    }
}
