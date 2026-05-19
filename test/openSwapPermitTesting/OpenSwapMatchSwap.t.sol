// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";

contract OpenSwapMatchSwapTest is SlimTestBase {
    address internal matcher2 = address(0xA2);

    function setUp() public {
        _setUpAll();
        // Set up a second matcher with internal balance + approval
        sellToken.transfer(matcher2, 100e18);
        buyToken.transfer(matcher2, 100_000e18);
        vm.deal(matcher2, 1 ether);
        _setupMatcherInternalBalance(matcher2, 100e18, 100_000e18);
    }

    // ── Hash-state assertions ───────────────────────────────────────────

    function testMatchSwap_StoresPostMatchHash() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        // The contract stored keccak256(abi.encode(sPost))
        assertEq(swapContract.swaps(swapId), keccak256(abi.encode(sPost)), "post-match hash");
        assertEq(sPost.matcher, matcher, "matcher set (non-zero means matched)");
        assertEq(sPost.start, uint48(block.timestamp), "start set");
        assertEq(sPost.fulfillmentFee, STARTING_FEE, "fulfillmentFee set to startingFee at t=0");
        assertEq(sPost.reportId, 1, "reportId = 1 (first oracle game)");
    }

    function testMatchSwap_SetsStartTimestamp() public {
        (uint256 swapId, uint48 expiration) = _propose();

        // Warp before matching
        vm.warp(block.timestamp + 100);
        vm.roll(block.number + 50);
        uint48 matchTs = uint48(block.timestamp);

        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        assertEq(sPost.start, matchTs, "start = block.timestamp at match");
    }

    // ── Internal-balance shuffles ──────────────────────────────────────

    function testMatchSwap_DebitsMatcherInternalBalances() public {
        uint256 matcherSellBefore = _spendable(matcher, address(sellToken));
        uint256 matcherBuyBefore = _spendable(matcher, address(buyToken));

        (uint256 swapId, uint48 expiration) = _propose();
        _match(swapId, 2000e18, expiration);

        // matcher pays initialLiquidity (sellToken) + amount2 (buyToken) + minFulfillLiquidity (buyToken)
        assertEq(
            _spendable(matcher, address(sellToken)),
            matcherSellBefore - INITIAL_LIQUIDITY,
            "matcher sellToken: -initialLiquidity"
        );
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyBefore - 2000e18 - MIN_FULFILL_LIQUIDITY,
            "matcher buyToken: -amount2 -minFulfillLiquidity"
        );
    }

    function testMatchSwap_CreditsOpenSwapBuyToken() public {
        uint256 swapContractBuyBefore = _spendable(address(swapContract), address(buyToken));
        (uint256 swapId, uint48 expiration) = _propose();
        _match(swapId, 2000e18, expiration);

        // internalTransferFrom routes minFulfillLiquidity from matcher → openSwap
        assertEq(
            _spendable(address(swapContract), address(buyToken)),
            swapContractBuyBefore + MIN_FULFILL_LIQUIDITY,
            "openSwap gained minFulfillLiquidity buyToken"
        );
    }

    function testMatchSwap_SellTokenStaysInOracle() public {
        // sellToken (swapper's sellAmt) was deposited to oracle in propose, not openSwap.
        // matchSwap doesn't move it.
        uint256 oracleSellBefore = _spendable(address(swapContract), address(sellToken));
        (uint256 swapId, uint48 expiration) = _propose();
        assertEq(
            _spendable(address(swapContract), address(sellToken)),
            oracleSellBefore + SELL_AMT,
            "openSwap sellToken internal == sellAmt after propose"
        );

        _match(swapId, 2000e18, expiration);

        // After match, sellToken internal balance for openSwap is unchanged
        assertEq(
            _spendable(address(swapContract), address(sellToken)),
            oracleSellBefore + SELL_AMT,
            "openSwap sellToken internal unchanged by match"
        );
        // External openSwap balance is still zero (everything lives in oracle internal balance)
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "openSwap external sellToken == 0");
    }

    // ── Oracle game side ────────────────────────────────────────────────

    function testMatchSwap_CreatesOracleReport() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (uint128 reportId,,) = _match(swapId, 2000e18, expiration);

        // Oracle stored the game hash for this reportId
        assertTrue(oracle.oracleGame(reportId) != bytes32(0), "oracle game hash exists");
        assertEq(reportId, 1, "first reportId == 1");
    }

    function testMatchSwap_OracleHashMatchesReconstruction() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,,) = _match(swapId, 2000e18, expiration);

        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        // Token addresses pinned by the OracleGame struct
        assertEq(og.token1, address(sellToken), "token1 = sellToken");
        assertEq(og.token2, address(buyToken), "token2 = buyToken");

        // Reconstructed hash matches oracle's stored hash exactly
        assertEq(oracle.oracleGame(reportId), keccak256(abi.encode(og, ph)), "oracle hash matches");
    }

    function testMatchSwap_MatcherGasCompCredited() public {
        (uint256 swapId, uint48 expiration) = _propose();
        uint256 tempBefore = swapContract.tempHolding(matcher);
        _match(swapId, 2000e18, expiration);

        assertEq(
            swapContract.tempHolding(matcher),
            tempBefore + MATCHER_GAS_COMP,
            "matcher gas comp queued in tempHolding"
        );
    }

    // ── Multi-swap concurrency ──────────────────────────────────────────

    function testMatchSwap_DifferentMatchersForDifferentSwaps() public {
        (uint256 swapId1, uint48 exp1) = _propose();
        (uint256 swapId2, uint48 exp2) = _propose();

        // matcher matches swap1, matcher2 matches swap2
        (openSwapV2.ProposedSwap memory s1, openSwapV2.MatcherPreimage memory m1) =
            _buildSwapAndPreimage(swapId1, exp1);
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        vm.prank(matcher);
        swapContract.matchSwap(swapId1, 2000e18, s1, m1, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));

        (openSwapV2.ProposedSwap memory s2, openSwapV2.MatcherPreimage memory m2) =
            _buildSwapAndPreimage(swapId2, exp2);
        vm.prank(matcher2);
        swapContract.matchSwap(swapId2, 2000e18, s2, m2, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));

        // Build post-match swaps for each and verify stored hash matches expected matcher
        openSwapV2.MatchedSwap memory s1Post = _postMatchSwap(s1, 1, STARTING_FEE, reportTs);
        openSwapV2.MatchedSwap memory s2Post = _postMatchSwap(s2, 2, STARTING_FEE, reportTs);
        s2Post.matcher = matcher2;

        assertEq(swapContract.swaps(swapId1), keccak256(abi.encode(s1Post)), "swap1 post hash with matcher");
        assertEq(swapContract.swaps(swapId2), keccak256(abi.encode(s2Post)), "swap2 post hash with matcher2");
    }

    function testMatchSwap_ReportIdsAreSequential() public {
        (uint256 swapId1, uint48 exp1) = _propose();
        (uint256 swapId2, uint48 exp2) = _propose();

        (uint128 reportId1,,) = _match(swapId1, 2000e18, exp1);
        (openSwapV2.ProposedSwap memory s2, openSwapV2.MatcherPreimage memory m2) =
            _buildSwapAndPreimage(swapId2, exp2);
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        vm.prank(matcher);
        swapContract.matchSwap(swapId2, 2000e18, s2, m2, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));

        assertEq(reportId1, 1, "first reportId");
        assertEq(uint256(oracle.nextReportId()), 3, "nextReportId after 2 matches");
    }

    // ── Failure modes ────────────────────────────────────────────────────

    function testMatchSwap_RevertOnWrongHash() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        // Tamper with one of the fields
        s.sellAmt = SELL_AMT + 1;

        vm.prank(matcher);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }

    function testMatchSwap_RevertOnExpired() public {
        (uint256 swapId, uint48 expiration) = _propose();

        // Warp past expiration
        vm.warp(uint256(expiration) + 1);
        vm.roll(block.number + 1);

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(matcher);
        vm.expectRevert(Errors.Expired.selector);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }

    function testMatchSwap_RevertOnDoubleMatch() public {
        (uint256 swapId, uint48 expiration) = _propose();
        _match(swapId, 2000e18, expiration);

        // Try to match again with pre-match struct; hash check fails
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        vm.prank(matcher);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }
}
