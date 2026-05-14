// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";

contract OpenSwapHappyPathTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    function testHappyPath() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        uint256 matcherSellInternalBefore = _spendable(matcher, address(sellToken));
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        // 1) propose
        (uint256 swapId, uint48 expiration) = _propose();

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "swapper sellToken external");
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "openSwap external sellToken == 0");
        assertEq(_spendable(address(swapContract), address(sellToken)), SELL_AMT, "openSwap internal sellToken");

        // 2) match
        uint128 amount2 = 2000e18;
        (uint128 reportId, uint24 fulfillmentFee, openSwapV2.MatchedSwap memory sPost) =
            _match(swapId, amount2, expiration);

        assertEq(
            _spendable(matcher, address(sellToken)),
            matcherSellInternalBefore - INITIAL_LIQUIDITY,
            "matcher sellToken internal after match"
        );
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore - amount2 - MIN_FULFILL_LIQUIDITY,
            "matcher buyToken internal after match"
        );
        assertEq(
            _spendable(address(swapContract), address(buyToken)),
            MIN_FULFILL_LIQUIDITY,
            "openSwap buyToken internal == minFulfillLiquidity"
        );
        assertEq(swapContract.tempHolding(matcher), MATCHER_GAS_COMP, "matcher gas comp queued");

        // 3) settle
        (openSwapV2.ProposedSwap memory sPre, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(sPre, m, amount2);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        _settle(reportId, og, ph);

        assertEq(_spendable(settler, address(0)), SETTLER_REWARD, "settler reward queued");
        assertEq(_spendable(matcher, address(sellToken)), matcherSellInternalBefore, "matcher sellToken back after settle");
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore - MIN_FULFILL_LIQUIDITY,
            "matcher buyToken after settle"
        );

        // 4) execute
        address executor = address(0x99);
        vm.deal(executor, 1 ether);
        _execute(swapId, sPost, og, ph, executor);

        // Terminal: swap hash deleted
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-execute");

        uint256 fulfillAmt = (uint256(SELL_AMT) * amount2) / INITIAL_LIQUIDITY;
        fulfillAmt -= (fulfillAmt * fulfillmentFee) / 1e7;

        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + fulfillAmt, "swapper got buyToken externally");
        assertEq(
            _spendable(matcher, address(sellToken)),
            matcherSellInternalBefore + SELL_AMT,
            "matcher sellToken internal after execute"
        );
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore - fulfillAmt,
            "matcher buyToken internal after execute"
        );
        assertEq(_spendable(address(swapContract), address(sellToken)), 0, "openSwap sellToken drained");
        assertEq(_spendable(address(swapContract), address(buyToken)), 0, "openSwap buyToken drained");
        assertEq(swapContract.tempHolding(executor), EXECUTOR_GAS_COMP, "executor gas comp queued");
    }
}
