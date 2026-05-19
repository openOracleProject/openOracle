// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract OpenSwapInternalBalancesTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
        _setupSwapperInternalBalance(swapper, address(sellToken), SELL_AMT);
    }

    // 1) Internal-balance propose succeeds
    function testInternal_ProposeSucceeds() public {
        uint256 swapperInternalBefore = _spendable(swapper, address(sellToken));
        uint256 openSwapInternalBefore = _spendable(address(swapContract), address(sellToken));

        (uint256 swapId,) = _proposeWith(true);

        assertEq(_spendable(swapper, address(sellToken)), swapperInternalBefore - SELL_AMT, "swapper internal debited");
        assertEq(
            _spendable(address(swapContract), address(sellToken)),
            openSwapInternalBefore + SELL_AMT,
            "openSwap internal credited"
        );
        assertTrue(swapContract.swaps(swapId) != bytes32(0), "swap hash stored");
    }

    // 2) Internal-balance propose reverts without approval
    function testInternal_ProposeNoApproval_Reverts() public {
        address other = address(0x5001);
        vm.deal(other, 10 ether);
        sellToken.transfer(other, SELL_AMT);
        vm.startPrank(other);
        sellToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(sellToken), SELL_AMT, other);
        // No approveInternal call.
        vm.stopPrank();

        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        uint256 nextId = swapContract.nextSwapId();
        vm.prank(other);
        vm.expectRevert(Errors.InsufficientInternalAllowance.selector);
        SwapCompat.proposeRaw(swapContract, ethToSend, 
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            _defaultOracleParams(), _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), true
        );
        assertEq(swapContract.swaps(nextId), bytes32(0), "no swap created on revert");
        assertEq(swapContract.nextSwapId(), nextId, "nextSwapId unchanged on revert");
    }

    // 3) Internal-balance propose reverts without balance
    function testInternal_ProposeShortBalance_Reverts() public {
        address other = address(0x5002);
        vm.deal(other, 10 ether);
        // approve but no deposit
        vm.startPrank(other);
        oracle.approveInternal(address(swapContract), address(sellToken), type(uint256).max);
        vm.stopPrank();

        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        uint256 nextId = swapContract.nextSwapId();
        vm.prank(other);
        vm.expectRevert(Errors.InsufficientInternalBalance.selector);
        SwapCompat.proposeRaw(swapContract, ethToSend, 
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            _defaultOracleParams(), _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), true
        );
        assertEq(swapContract.swaps(nextId), bytes32(0), "no swap created on revert");
        assertEq(swapContract.nextSwapId(), nextId, "nextSwapId unchanged on revert");
    }

    // Exact internal allowance: openSwap is the spender, exactly SELL_AMT is consumed.
    function testInternal_FiniteAllowance_ConsumedExactly() public {
        address tightSwapper = address(0x5101);
        sellToken.transfer(tightSwapper, SELL_AMT);
        vm.deal(tightSwapper, 1 ether);

        vm.startPrank(tightSwapper);
        sellToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(sellToken), SELL_AMT, tightSwapper);
        oracle.approveInternal(address(swapContract), address(sellToken), SELL_AMT);
        vm.stopPrank();

        assertEq(
            oracle.internalAllowance(tightSwapper, address(swapContract), address(sellToken)),
            SELL_AMT,
            "exact allowance set"
        );

        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        proposeTs = uint48(block.timestamp);
        proposeUseInternal = true;
        vm.prank(tightSwapper);
        uint256 swapId = SwapCompat.proposeRaw(swapContract, ethToSend, 
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            _defaultOracleParams(), _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), true
        );

        assertEq(
            oracle.internalAllowance(tightSwapper, address(swapContract), address(sellToken)),
            0,
            "allowance fully consumed by openSwap"
        );
        assertEq(_spendable(tightSwapper, address(sellToken)), 0, "swapper internal sellToken drained");
        assertEq(_spendable(address(swapContract), address(sellToken)), SELL_AMT, "openSwap received sellToken internally");
        assertTrue(swapContract.swaps(swapId) != bytes32(0), "swap hash stored");
    }

    // 4) ETH sellToken internal-balance propose: msg.value covers only extra ETH, not sellAmt + extra
    function testInternal_EthSell_MsgValueIsExtraOnly() public {
        uint128 ethSell = 1 ether;
        _setupSwapperInternalEth(swapper, ethSell);

        uint256 extra = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        proposeTs = uint48(block.timestamp);
        proposeUseInternal = true;

        uint256 swapperInternalEthBefore = _spendable(swapper, address(0));
        uint256 openSwapInternalEthBefore = _spendable(address(swapContract), address(0));

        vm.prank(swapper);
        uint256 swapId = SwapCompat.proposeRaw(swapContract, extra, 
            ethSell, address(0), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            _defaultOracleParams(), _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), true
        );

        assertEq(_spendable(swapper, address(0)), swapperInternalEthBefore - ethSell, "swapper internal ETH debited");
        assertEq(_spendable(address(swapContract), address(0)), openSwapInternalEthBefore + ethSell, "openSwap internal ETH credited");
        assertTrue(swapContract.swaps(swapId) != bytes32(0), "swap created");
    }

    // ETH sell with wrong msg.value (including sellAmt) reverts.
    function testInternal_EthSell_WrongMsgValueReverts() public {
        uint128 ethSell = 1 ether;
        _setupSwapperInternalEth(swapper, ethSell);

        uint256 extra = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        vm.prank(swapper);
        vm.expectRevert(Errors.InvalidMsgValue.selector);
        SwapCompat.proposeRaw(swapContract, ethSell + extra, 
            ethSell, address(0), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            _defaultOracleParams(), _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), true
        );
    }

    // 8) Internal-balance cancel: sellToken returns internally, gas comp + settler reward in tempHolding
    function testInternal_CancelByswapper_ReturnsInternally() public {
        uint256 swapperInternalBefore = _spendable(swapper, address(sellToken));
        uint256 swapperEthBefore = swapper.balance;

        (uint256 swapId, uint48 expiration) = _proposeWith(true);
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);

        assertEq(_spendable(swapper, address(sellToken)), swapperInternalBefore, "sellToken returned internally");
        assertEq(
            swapContract.tempHolding(swapper),
            uint256(MATCHER_GAS_COMP) + uint256(EXECUTOR_GAS_COMP) + uint256(SETTLER_REWARD),
            "gas comps + settler queued in tempHolding"
        );
        assertEq(swapper.balance, swapperEthBefore - uint256(MATCHER_GAS_COMP) - uint256(EXECUTOR_GAS_COMP) - uint256(SETTLER_REWARD), "no direct ETH refund");
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted");
    }

    // 9) Internal-balance bailout: refund returns assets internally; executor gets tempHolding gas comp.
    //    Note: bailOut only refunds the sellAmt and minFulfillLiquidity legs — the oracle-game stake
    //    (amount2 in buyToken) stays locked in the oracle.
    function testInternal_Bailout_RefundsInternally() public {
        uint256 swapperInternalSellBefore = _spendable(swapper, address(sellToken));
        uint256 matcherInternalBuyBefore = _spendable(matcher, address(buyToken));

        (uint256 swapId, uint48 expiration) = _proposeWith(true);
        uint128 amount2 = 2000e18;
        (,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, amount2, expiration);

        // After match: matcher's internal buyToken = before - amount2 (to oracle game) - minFulfillLiquidity (to openSwap).
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherInternalBuyBefore - amount2 - MIN_FULFILL_LIQUIDITY,
            "matcher buyToken debited at match"
        );

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        address executor = address(0x6001);
        vm.prank(executor);
        swapContract.bailOut(swapId, sPost);

        assertEq(_spendable(swapper, address(sellToken)), swapperInternalSellBefore, "swapper sellToken refunded internally");
        // amount2 remains locked in the oracle game; minFulfillLiquidity returns internally.
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherInternalBuyBefore - amount2,
            "matcher buyToken minFulfill refunded internally"
        );
        assertEq(swapContract.tempHolding(executor), EXECUTOR_GAS_COMP, "executor gas comp queued");
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted");
    }

    // Internal-balance third-party expired cancel: caller piece + swapper piece + settler reward
    // all go to tempHolding (no direct ETH push); sellToken returns internally.
    function testInternal_ThirdPartyCancelAfterExpiration() public {
        uint256 swapperInternalSellBefore = _spendable(swapper, address(sellToken));
        uint256 swapperEthBefore = swapper.balance;

        (uint256 swapId, uint48 expiration) = _proposeWith(true);
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        vm.warp(uint256(expiration) + 1);
        vm.roll(block.number + 1);

        address thirdParty = address(0x6010);
        vm.deal(thirdParty, 1 ether);
        uint256 thirdPartyEthBefore = thirdParty.balance;

        vm.prank(thirdParty);
        swapContract.cancelSwap(swapId, s, m);

        // Post-expire third-party cancel: caller takes matcherGasComp, swapper gets executorGasComp + reward.
        uint256 callerPiece = MATCHER_GAS_COMP;
        uint256 swapperPiece = EXECUTOR_GAS_COMP;

        assertEq(_spendable(swapper, address(sellToken)), swapperInternalSellBefore, "sellToken returned internally");
        assertEq(
            swapContract.tempHolding(swapper),
            swapperPiece + SETTLER_REWARD,
            "swapper got executorGasComp + settler reward queued"
        );
        assertEq(swapContract.tempHolding(thirdParty), callerPiece, "caller got matcherGasComp queued");
        assertEq(swapper.balance, swapperEthBefore - uint256(MATCHER_GAS_COMP) - uint256(EXECUTOR_GAS_COMP) - uint256(SETTLER_REWARD), "no direct ETH refund");
        assertEq(thirdParty.balance, thirdPartyEthBefore, "third party not paid directly");
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted");
    }

    // 10) Internal-balance execute success
    function testInternal_ExecuteSuccess_InternalDelivery() public {
        uint256 swapperInternalBuyBefore = _spendable(swapper, address(buyToken));
        uint256 swapperBuyExternalBefore = buyToken.balanceOf(swapper);
        uint256 matcherInternalSellBefore = _spendable(matcher, address(sellToken));

        (uint256 swapId, uint48 expiration) = _proposeWith(true);
        uint128 amount2 = 2000e18;
        (uint128 reportId, uint24 fulfillmentFee, openSwapV2.MatchedSwap memory sPost) =
            _match(swapId, amount2, expiration);

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, amount2);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(reportId, og, ph);

        address executor = address(0x6002);
        vm.deal(executor, 1 ether);
        _execute(swapId, sPost, og, ph, executor);

        uint256 fulfillAmt = (uint256(SELL_AMT) * amount2) / INITIAL_LIQUIDITY;
        fulfillAmt -= (fulfillAmt * fulfillmentFee) / 1e7;

        assertEq(buyToken.balanceOf(swapper), swapperBuyExternalBefore, "no external push to swapper");
        assertEq(_spendable(swapper, address(buyToken)), swapperInternalBuyBefore + fulfillAmt, "swapper buyToken internal");
        assertEq(
            _spendable(matcher, address(sellToken)),
            matcherInternalSellBefore + SELL_AMT,
            "matcher sellToken returned internally"
        );
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted");
    }
}
