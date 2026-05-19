// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";

/// @notice ETH-pair swap tests. Either sellToken or buyToken is address(0).
contract OpenSwapETHTest is SlimTestBase {
    function setUp() public {
        _baseDeploy();
        _fundAccounts();

        vm.deal(matcher, 60_000 ether);
        vm.deal(swapper, 100 ether);

        // Swapper approves Permit2 for the ERC20 (used in Token→ETH tests).
        _setupSwapperPermit2(swapper, address(sellToken));
        // Matcher: pre-fund internal balance with both ERC20 tokens AND ETH.
        _setupMatcherInternalBalance(matcher, 100e18, 100_000e18);
        vm.startPrank(matcher);
        // Enough ETH internal balance for the default ratio: amount2 = 2000e18, minFulfill = 25000e18.
        oracle.deposit{value: 50_000 ether}(address(0), uint128(50_000 ether), matcher);
        oracle.approveInternal(address(swapContract), address(0), type(uint256).max);
        vm.stopPrank();
    }

    // ── ETH-sell helpers (sellToken = address(0), buyToken = buyToken) ──

    function _proposeEthSell() internal returns (uint256 swapId, uint48 expiration) {
        expiration = uint48(block.timestamp + 1 hours);
        proposeTs = uint48(block.timestamp);
        uint256 ethToSend = SELL_AMT + MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        vm.prank(swapper);
        swapId = SwapCompat.proposeRaw(swapContract, ethToSend, 
            SELL_AMT,
            address(0), // sellToken = ETH
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(), false
        );
    }

    function _buildEthSell(uint256 /*swapId*/, uint48 expiration)
        internal
        view
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        (s, m) = _buildSwapAndPreimage(0, expiration);
        s.sellToken = address(0); // override for ETH-sell
    }

    // ── Token→ETH helpers (sellToken = sellToken, buyToken = address(0)) ──

    function _proposeTokenToEth() internal returns (uint256 swapId, uint48 expiration) {
        expiration = uint48(block.timestamp + 1 hours);
        proposeTs = uint48(block.timestamp);
        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        vm.prank(swapper);
        swapId = SwapCompat.proposeRaw(swapContract, ethToSend, 
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(0), // buyToken = ETH
            MIN_FULFILL_LIQUIDITY,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(), false
        );
    }

    function _buildTokenToEth(uint256 /*swapId*/, uint48 expiration)
        internal
        view
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        (s, m) = _buildSwapAndPreimage(0, expiration);
        s.buyToken = address(0); // override for ETH-buy
    }

    // ── ETH → Token tests ──────────────────────────────────────────────

    function testETHToToken_Propose() public {
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = SELL_AMT + MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        (uint256 swapId,) = _proposeEthSell();

        assertEq(swapper.balance, swapperEthBefore - ethToSend, "swapper paid ETH");
        // sellAmt forwarded to oracle's internal balance for openSwap
        assertEq(_spendable(address(swapContract), address(0)), SELL_AMT, "openSwap ETH internal == sellAmt");
        // openSwap holds the gas comps as raw ETH
        assertEq(
            address(swapContract).balance,
            MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD,
            "openSwap raw ETH = gas comps + settler"
        );
        swapId; // silence
    }

    function testETHToToken_FullFlow() public {
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);
        uint256 matcherEthInternalBefore = _spendable(matcher, address(0));
        uint256 matcherBuyInternalBefore = _spendable(matcher, address(buyToken));

        (uint256 swapId, uint48 expiration) = _proposeEthSell();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildEthSell(swapId, expiration);

        IOpenOracle2.TimingBoundaries memory timing = IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        vm.prank(matcher);
        swapContract.matchSwap(swapId, 2000e18, s, m, timing);

        // Matcher's ETH internal goes down by initialLiquidity
        assertEq(
            _spendable(matcher, address(0)),
            matcherEthInternalBefore - INITIAL_LIQUIDITY,
            "matcher ETH -initialLiquidity"
        );
        // Matcher's buyToken internal goes down by amount2 + minFulfillLiquidity
        assertEq(
            _spendable(matcher, address(buyToken)),
            matcherBuyInternalBefore - 2000e18 - MIN_FULFILL_LIQUIDITY,
            "matcher buyToken -amount2 -minFulfillLiquidity"
        );

        openSwapV2.MatchedSwap memory sPost = _postMatchSwap(s, 1, STARTING_FEE, reportTs);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, 2000e18);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(1);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(1, og, ph);
        _execute(swapId, sPost, og, ph, address(0x99));

        uint256 fulfillAmt = (uint256(SELL_AMT) * 2000e18) / INITIAL_LIQUIDITY;
        fulfillAmt -= (fulfillAmt * STARTING_FEE) / 1e7;

        // Swapper got fulfillAmt of buyToken externally
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + fulfillAmt, "swapper got buyToken");
        // Matcher got sellAmt of ETH credited internally (executes routes through internalTransferFrom)
        assertEq(
            _spendable(matcher, address(0)),
            matcherEthInternalBefore + SELL_AMT,
            "matcher ETH internal +sellAmt"
        );
    }

    function testETHToToken_Cancel() public {
        uint256 swapperEthBefore = swapper.balance;
        (uint256 swapId, uint48 expiration) = _proposeEthSell();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildEthSell(swapId, expiration);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId, s, m);

        // sellAmt + all gas comp ETH returned. pushOrCredit pushes ETH externally; payEth sends the rest.
        assertEq(swapper.balance, swapperEthBefore, "swapper got all ETH back");
        assertEq(_spendable(address(swapContract), address(0)), 0, "openSwap ETH internal drained");
    }

    function testETHToToken_WrongMsgValue_Reverts() public {
        // propose for ETH-sell must have msg.value == sellAmt + extraEth
        uint256 wrongEth = SELL_AMT; // missing the gas comps
        vm.prank(swapper);
        vm.expectRevert(Errors.InvalidMsgValue.selector);
        SwapCompat.proposeRaw(swapContract, wrongEth, 
            SELL_AMT,
            address(0),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(), false
        );
    }

    // ── Token → ETH tests ──────────────────────────────────────────────

    function testTokenToETH_Propose() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        (uint256 swapId,) = _proposeTokenToEth();

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "swapper sent sellToken");
        // sellToken in oracle's internal balance for openSwap
        assertEq(_spendable(address(swapContract), address(sellToken)), SELL_AMT, "openSwap sellToken internal");
        swapId;
    }

    function _proposeTokenToEthSmall(uint128 minFulfill) internal returns (uint256 swapId, uint48 expiration) {
        expiration = uint48(block.timestamp + 1 hours);
        proposeTs = uint48(block.timestamp);
        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        // SlippageParams loose; minOut small
        vm.prank(swapper);
        swapId = SwapCompat.proposeRaw(swapContract, ethToSend, 
            SELL_AMT,
            address(sellToken),
            1,            // minOut tiny
            address(0),   // buyToken = ETH
            minFulfill,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(), false
        );
    }

    function testTokenToETH_FullFlow() public {
        uint256 matcherSellInternalBefore = _spendable(matcher, address(sellToken));
        uint256 matcherEthInternalBefore = _spendable(matcher, address(0));

        // Use the default ratio (price = amount1*1e30/amount2 = 5e26) so the loose slippage check passes.
        // sellAmt = 10e18 tokens, initialLiquidity = 1e18 tokens, amount2 = 2000e18 ETH.
        // fulfillAmt = 10e18 * 2000e18 / 1e18 = 20000e18 ETH, so minFulfill must fit that.
        uint128 minFulfill = 25000 ether;
        (uint256 swapId, uint48 expiration) = _proposeTokenToEthSmall(minFulfill);
        uint256 swapperEthBefore = swapper.balance; // snapshot AFTER propose deducted gas comps

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        s.buyToken = address(0);
        s.minFulfillLiquidity = minFulfill;

        IOpenOracle2.TimingBoundaries memory timing = IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        uint128 amount2 = 2000 ether;

        vm.prank(matcher);
        swapContract.matchSwap(swapId, amount2, s, m, timing);

        assertEq(
            _spendable(matcher, address(sellToken)),
            matcherSellInternalBefore - INITIAL_LIQUIDITY,
            "matcher sellToken -initialLiquidity"
        );
        assertEq(
            _spendable(matcher, address(0)),
            matcherEthInternalBefore - amount2 - minFulfill,
            "matcher ETH -amount2 -minFulfill"
        );
        // openSwap holds minFulfill ETH internally for swap payout
        assertEq(_spendable(address(swapContract), address(0)), minFulfill, "openSwap ETH internal = minFulfill");

        // Settle + execute
        openSwapV2.MatchedSwap memory sPost = _postMatchSwap(s, 1, STARTING_FEE, reportTs);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s, m, amount2);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(1);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(1, og, ph);
        _execute(swapId, sPost, og, ph, address(0x99));

        uint256 fulfillAmt = (uint256(SELL_AMT) * amount2) / INITIAL_LIQUIDITY;
        fulfillAmt -= (fulfillAmt * STARTING_FEE) / 1e7;

        // Swapper received fulfillAmt of ETH externally via pushOrCredit
        assertEq(swapper.balance, swapperEthBefore + fulfillAmt, "swapper got ETH");
    }

    // ── Reject msg.value on matchSwap ─────────────────────────────────

    function testMatchSwap_RejectsMsgValue() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        // matchSwap is not payable; sending ETH should revert at the EVM dispatcher level
        vm.prank(matcher);
        (bool ok,) = address(swapContract).call{value: 1 wei}(
            abi.encodeWithSelector(
                openSwapV2.matchSwap.selector,
                swapId,
                uint128(2000e18),
                s,
                m,
                IOpenOracle2.TimingBoundaries(0, 0, 0, 0)
            )
        );
        assertFalse(ok, "matchSwap should reject ETH");
    }
}
