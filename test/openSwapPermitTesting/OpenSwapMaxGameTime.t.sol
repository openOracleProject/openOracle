// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

contract OpenSwapMaxGameTimeTest is SlimTestBase {
    address internal randomUser = address(0x5005);

    function setUp() public {
        _setUpAll();
        vm.deal(randomUser, 1 ether);
    }

    function _runMatch()
        internal
        returns (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        )
    {
        uint48 expiration;
        (swapId, expiration) = _propose();
        (, , sPost) = _match(swapId, 2000e18, expiration);
        (og, ph) = _gameAtMatch(swapId, expiration, 2000e18, sPost);
    }

    function testMaxGameTime_AnyoneCanCallBailOut() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _runMatch();
        og = _disputePastMaxGameTime(og, ph, sPost);

        // randomUser (not swapper, not matcher) can call bailOut
        vm.prank(randomUser);
        swapContract.bailOut(swapId, sPost, og, ph);

        // randomUser gets the executor gas comp
        assertEq(swapContract.tempHolding(randomUser), EXECUTOR_GAS_COMP, "random user got executor comp");
    }

    function testMaxGameTime_SwapperAndMatcherBothGetRefunds() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _runMatch();
        og = _disputePastMaxGameTime(og, ph, sPost);

        // Disputes moved the matcher's report stake; measure only what bailOut returns.
        uint256 matcherSellInternalBefore = _spendable(matcher, address(sellToken));
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        swapContract.bailOut(swapId, sPost, og, ph);

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "swapper sellToken returned");
        assertEq(_spendable(matcher, address(sellToken)), matcherSellInternalBefore, "matcher sellToken unchanged");
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore + MIN_FULFILL_LIQUIDITY,
            "matcher minFulfillLiquidity returned"
        );
    }

    function testMaxGameTime_WorksWithUnsettledOracle() public {
        // bailOut does not depend on oracle.settle being called.
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _runMatch();
        og = _disputePastMaxGameTime(og, ph, sPost);

        assertEq(og.settlementTimestamp, 0, "oracle unsettled");
        assertEq(oracle.oracleGame(sPost.reportId), keccak256(abi.encode(og, ph)), "live game matches");

        swapContract.bailOut(swapId, sPost, og, ph);

        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-bailout");
    }

    function testMaxGameTime_NoDisputes_NeverEligible() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _runMatch();

        // Elapsed blocks do not count: without disputes eligibility stays at start + settlementTime.
        vm.roll(uint256(sPost.start) + uint256(MAX_GAME_TIME) * 2);
        vm.expectRevert(Errors.CantBailOutYet.selector);
        swapContract.bailOut(swapId, sPost, og, ph);
    }

    function testMaxGameTime_EligibleAsSoonAsDisputeCrossesLimit() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _runMatch();
        og = _disputePastMaxGameTime(og, ph, sPost);

        // Still inside the final round: the deadline block itself has not been reached.
        assertLt(block.number, uint256(sPost.start) + sPost.maxGameTime, "before start + maxGameTime");
        swapContract.bailOut(swapId, sPost, og, ph);
        assertEq(swapContract.swaps(swapId), bytes32(0), "bailed out early");
    }

    function testMaxGameTime_StaleOracleState_Reverts() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _runMatch();
        IOpenOracle2.OracleGame memory atMatch = abi.decode(abi.encode(og), (IOpenOracle2.OracleGame));
        og = _disputePastMaxGameTime(og, ph, sPost);

        // The match-time state no longer matches the stored oracle hash.
        vm.expectRevert(Errors.WrongOracleHash.selector);
        swapContract.bailOut(swapId, sPost, atMatch, ph);
    }

    function testMaxGameTime_ForgedReportTimestamp_Reverts() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _runMatch();

        // A caller cannot claim a later report than the oracle holds.
        og.reportTimestamp += uint48(MAX_GAME_TIME);
        vm.expectRevert(Errors.WrongOracleHash.selector);
        swapContract.bailOut(swapId, sPost, og, ph);
    }

    function testMaxGameTime_WorksWithSettledOracle() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _runMatch();
        og = _disputePastMaxGameTime(og, ph, sPost);

        vm.roll(uint256(og.reportTimestamp) + og.settlementTime);
        _settle(sPost.reportId, og, ph);
        og.settlementTimestamp = uint48(block.number);
        assertEq(oracle.oracleGame(sPost.reportId), keccak256(abi.encode(og, ph)), "settled game matches");

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        vm.prank(randomUser);
        swapContract.bailOut(swapId, sPost, og, ph);

        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-bailout");
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore + SELL_AMT, "swapper sellAmt returned");
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore + MIN_FULFILL_LIQUIDITY,
            "matcher minFulfillLiquidity returned"
        );
    }

    function testMaxGameTime_TamperedPreimageHelper_Reverts() public {
        (
            uint256 swapId,
            openSwapV2.MatchedSwap memory sPost,
            IOpenOracle2.OracleGame memory og,
            IOpenOracle2.PreimageHelper memory ph
        ) = _runMatch();
        og = _disputePastMaxGameTime(og, ph, sPost);
        bytes32 swapHash = swapContract.swaps(swapId);

        // Eligible game: only the helper hash check stands between each call and a bailout.
        for (uint256 i; i < 4; i++) {
            IOpenOracle2.PreimageHelper memory bad = abi.decode(abi.encode(ph), (IOpenOracle2.PreimageHelper));
            if (i == 0) bad.reportId += 1;
            else if (i == 1) bad.creator = randomUser;
            else if (i == 2) bad.blockTimestamp += 1;
            else bad.blockNumber += 1;

            vm.expectRevert(Errors.WrongOracleHash.selector);
            swapContract.bailOut(swapId, sPost, og, bad);
        }
        assertEq(swapContract.swaps(swapId), swapHash, "swap untouched");

        swapContract.bailOut(swapId, sPost, og, ph);
        assertEq(swapContract.swaps(swapId), bytes32(0), "genuine helper bails out");
    }

    function testMaxGameTime_OtherSwapsOracleState_Reverts() public {
        (
            uint256 swapIdA,
            openSwapV2.MatchedSwap memory sPostA,
            IOpenOracle2.OracleGame memory ogA,
            IOpenOracle2.PreimageHelper memory phA
        ) = _runMatch();
        (
            ,
            openSwapV2.MatchedSwap memory sPostB,
            IOpenOracle2.OracleGame memory ogB,
            IOpenOracle2.PreimageHelper memory phB
        ) = _runMatch();
        assertTrue(sPostA.reportId != sPostB.reportId, "distinct games");

        // B's game is genuine and past the limit; A's game is undisputed.
        ogB = _disputePastMaxGameTime(ogB, phB, sPostB);
        assertEq(oracle.oracleGame(sPostB.reportId), keccak256(abi.encode(ogB, phB)), "B game is live");
        bytes32 swapHashA = swapContract.swaps(swapIdA);

        vm.expectRevert(Errors.WrongOracleHash.selector);
        swapContract.bailOut(swapIdA, sPostA, ogB, phB);

        assertEq(swapContract.swaps(swapIdA), swapHashA, "swap A untouched");
        vm.expectRevert(Errors.CantBailOutYet.selector);
        swapContract.bailOut(swapIdA, sPostA, ogA, phA);
    }

    function _proposeWithMaxGameTime(uint24 maxGameTime) internal returns (uint256) {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.maxGameTime = maxGameTime;
        proposeBn = uint48(block.number);

        vm.prank(swapper);
        return SwapCompat.proposeRaw(swapContract, MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD,
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            op, _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), false
        );
    }

    function testMaxGameTime_ValidationOnPropose_TooLow() public {
        // one block less than settlementTime * 50 → revert
        vm.expectRevert(Errors.InvalidOracleParams.selector);
        _proposeWithMaxGameTime(uint24(SETTLEMENT_TIME) * 50 - 1);
    }

    function testMaxGameTime_ValidationOnPropose_AtMinimum_Succeeds() public {
        assertGt(_proposeWithMaxGameTime(uint24(SETTLEMENT_TIME) * 50), 0, "settlementTime * 50 accepted");
    }

    function testMaxGameTime_ValidationOnPropose_TooHigh() public {
        // exceeds 3,024,000 blocks (7 days of 200ms blocks)
        vm.expectRevert(Errors.InvalidOracleParams.selector);
        _proposeWithMaxGameTime(3_024_001);
    }

    function testMaxGameTime_ValidationOnPropose_AtMaximum_Succeeds() public {
        assertGt(_proposeWithMaxGameTime(3_024_000), 0, "3,024,000 blocks accepted");
    }
}
