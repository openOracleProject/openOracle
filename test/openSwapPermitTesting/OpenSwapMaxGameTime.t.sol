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

    function _runMatch() internal returns (uint256 swapId, openSwapV2.MatchedSwap memory sPost) {
        uint48 expiration;
        (swapId, expiration) = _propose();
        (, , sPost) = _match(swapId, 2000e18, expiration);
    }

    function testMaxGameTime_AnyoneCanCallBailOut() public {
        (uint256 swapId, openSwapV2.MatchedSwap memory sPost) = _runMatch();

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // randomUser (not swapper, not matcher) can call bailOut
        vm.prank(randomUser);
        swapContract.bailOut(swapId, sPost);

        // randomUser gets the executor gas comp
        assertEq(swapContract.tempHolding(randomUser), EXECUTOR_GAS_COMP, "random user got executor comp");
    }

    function testMaxGameTime_SwapperAndMatcherBothGetRefunds() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherSellInternalBefore = _spendable(matcher, address(sellToken));
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        (uint256 swapId, openSwapV2.MatchedSwap memory sPost) = _runMatch();

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        swapContract.bailOut(swapId, sPost);

        // Swapper sellToken refunded externally
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "swapper sellToken returned");
        // Matcher's initialLiquidity sellToken still in oracle game escrow (not released until oracle.settle).
        // Matcher's minFulfillLiquidity buyToken returned to internal balance via internalTransferFrom.
        // amount2 buyToken still in oracle game escrow.
        assertEq(
            _spendable(matcher, address(sellToken)),
            matcherSellInternalBefore - INITIAL_LIQUIDITY,
            "matcher sellToken minus initialLiquidity (still in oracle game)"
        );
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore - 2000e18, // amount2 still in oracle game
            "matcher buyToken: only amount2 missing"
        );
    }

    function testMaxGameTime_WorksWithUnsettledOracle() public {
        // Critical V3 property: bailOut after maxGameTime doesn't depend on oracle.settle being called.
        (uint256 swapId, openSwapV2.MatchedSwap memory sPost) = _runMatch();

        // Verify oracle is unsettled
        assertTrue(oracle.oracleGame(sPost.reportId) != bytes32(0), "oracle game exists");

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        swapContract.bailOut(swapId, sPost);

        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-bailout");
    }

    function testMaxGameTime_ValidationOnPropose_TooLow() public {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.maxGameTime = uint24(SETTLEMENT_TIME) * 10; // less than settlementTime * 20 → revert
        proposeTs = uint48(block.timestamp);

        vm.prank(swapper);
        vm.expectRevert(Errors.InvalidOracleParams.selector);
        SwapCompat.proposeRaw(swapContract, MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD, 
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            op, _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), false
        );
    }

    function testMaxGameTime_ValidationOnPropose_TooHigh() public {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.maxGameTime = uint24(604801); // exceeds 7 days
        proposeTs = uint48(block.timestamp);

        vm.prank(swapper);
        vm.expectRevert(Errors.InvalidOracleParams.selector);
        SwapCompat.proposeRaw(swapContract, MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD, 
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            op, _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), false
        );
    }
}
