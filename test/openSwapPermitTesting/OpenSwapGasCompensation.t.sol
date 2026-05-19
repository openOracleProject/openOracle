// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";

contract OpenSwapGasCompensationTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    function _fullFlowToExecute(address executor) internal {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(reportId, og, ph);
        _execute(swapId, sPost, og, ph, executor);
    }

    function _bailoutFlow(address bailer) internal {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);
        vm.prank(bailer);
        swapContract.bailOut(swapId, sPost);
    }

    function testGasComp_ZeroIsValid() public {
        proposeTs = uint48(block.timestamp);
        vm.prank(swapper);
        uint256 swapId = SwapCompat.proposeRaw(swapContract, SETTLER_REWARD, 
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), 0, 0,
            _defaultOracleParams(), _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), false
        );
        assertGt(swapId, 0, "zero gas comps OK");
    }

    function testGasComp_HighValueIsValid() public {
        proposeTs = uint48(block.timestamp);
        vm.prank(swapper);
        uint256 swapId = SwapCompat.proposeRaw(swapContract, 2 ether + SETTLER_REWARD, 
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), 1 ether, 1 ether,
            _defaultOracleParams(), _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), false
        );
        assertGt(swapId, 0, "high gas comps OK");
    }

    function testGasComp_PaidToMatcherOnMatch() public {
        (uint256 swapId, uint48 expiration) = _propose();
        _match(swapId, 2000e18, expiration);
        assertEq(swapContract.tempHolding(matcher), MATCHER_GAS_COMP, "matcher got matcherGasComp");
    }

    function testGasComp_ExecutorGetsCompOnExecute() public {
        address executor = address(0x9999);
        _fullFlowToExecute(executor);
        assertEq(swapContract.tempHolding(executor), EXECUTOR_GAS_COMP, "executor got gas comp");
    }

    function testGasComp_BailerGetsExecutorCompOnBailout() public {
        address bailer = address(0x9001);
        _bailoutFlow(bailer);
        assertEq(swapContract.tempHolding(bailer), EXECUTOR_GAS_COMP, "bailer got executor comp");
    }

    function testGasComp_MatcherKeepsCompAfterBailout() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        uint256 matcherBefore = swapContract.tempHolding(matcher);

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);
        swapContract.bailOut(swapId, sPost);

        assertEq(swapContract.tempHolding(matcher), matcherBefore, "matcher comp untouched");
    }

    function testGasComp_ReturnedOnCancel() public {
        uint256 swapperEthBefore = swapper.balance;
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);

        assertEq(swapper.balance, swapperEthBefore, "swapper got full refund");
    }

    function testGasComp_PropagatesIntoSwapHash() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        s.matcherGasComp = MATCHER_GAS_COMP + 1; // tamper

        vm.prank(matcher);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
    }

    function testGasComp_RevertsOnWrongMsgValue() public {
        // msg.value != mgc + egc + settler should revert
        proposeTs = uint48(block.timestamp);
        vm.prank(swapper);
        vm.expectRevert(Errors.InvalidMsgValue.selector);
        SwapCompat.proposeRaw(swapContract, MATCHER_GAS_COMP,  // missing executor + settler
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            _defaultOracleParams(), _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), false
        );
    }
}
