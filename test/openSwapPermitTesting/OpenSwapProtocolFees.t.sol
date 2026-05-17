// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";
import "../../src/oracleFeeReceiver.sol";

contract OpenSwapProtocolFeesTest is SlimTestBase {
    uint24 constant PROTO_FEE = 1000; // 0.01%

    function setUp() public {
        _setUpAll();
        // Mint extra so we can deposit directly into the feeReceiver as simulated fees
        sellToken.transfer(address(this), 1000e18);
        buyToken.transfer(address(this), 1000e18);
        sellToken.approve(address(oracle), type(uint256).max);
        buyToken.approve(address(oracle), type(uint256).max);
    }

    function _defaultOracleParams() internal view override returns (SwapCompat.OracleParams memory) {
        SwapCompat.OracleParams memory p = SwapCompat.OracleParams({
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlerReward: SETTLER_REWARD,
            settlementTime: SETTLEMENT_TIME,
            maxGameTime: MAX_GAME_TIME,
            disputeDelay: DISPUTE_DELAY,
            protocolFee: PROTO_FEE,
            multiplier: 110,
            blocksPerSecond: 500
        });
        return p;
    }

    function _proposeAndMatchWithFees()
        internal
        returns (uint256 swapId, openSwapV2.MatchedSwap memory sPost, address feeReceiver)
    {
        uint48 expiration;
        (swapId, expiration) = _propose();
        (uint128 reportId,, openSwapV2.MatchedSwap memory sP) = _match(swapId, 2000e18, expiration);
        sPost = sP;
        feeReceiver = sPost.feeRecipient;
        reportId; // silence
    }

    // ── Clone creation & metadata ──────────────────────────────────────

    function testProtocolFees_FeeReceiverDeployedWhenPositive() public {
        (, , address feeReceiver) = _proposeAndMatchWithFees();
        assertTrue(feeReceiver != address(0), "feeReceiver deployed");
        assertTrue(feeReceiver.code.length > 0, "feeReceiver is a contract");
    }

    function testProtocolFees_FeeReceiverNotDeployedWhenZero() public {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        op.protocolFee = 0;
        proposeTs = uint48(block.timestamp);
        vm.prank(swapper);
        uint256 swapId = SwapCompat.proposeRaw(swapContract, MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD, 
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), MATCHER_GAS_COMP, EXECUTOR_GAS_COMP,
            op, _defaultSlippage(), _defaultFulfillFee(), _emptyPermit2(), false
        );

        // Reconstruct preimage/swap with zero protocolFee, then match
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, uint48(block.timestamp + 1 hours));
        m.protocolFee = 0;
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        vm.prank(matcher);
        swapContract.matchSwap(swapId, 2000e18, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));

        openSwapV2.MatchedSwap memory sPost = _postMatchSwap(s, 1, STARTING_FEE, reportTs);
        assertEq(sPost.feeRecipient, address(0), "no clone when protocolFee = 0");
    }

    function testProtocolFees_FeeReceiverMetadata() public {
        (uint256 swapId, openSwapV2.MatchedSwap memory sPost, address frAddr) = _proposeAndMatchWithFees();
        oracleFeeReceiver fr = oracleFeeReceiver(frAddr);

        assertEq(uint256(fr.gameId()), swapId, "gameId = swapId");
        assertEq(address(fr.oracle()), address(oracle), "oracle reference");
        assertEq(fr.token1(), address(sellToken), "token1 = sellToken");
        assertEq(fr.token2(), address(buyToken), "token2 = buyToken");
        assertEq(fr.swapper(), swapper, "swapper");
        assertEq(fr.matcher(), matcher, "matcher");
        sPost; // silence
    }

    function testProtocolFees_EachSwapGetsUniqueFeeReceiver() public {
        (, , address fr1) = _proposeAndMatchWithFees();
        (, , address fr2) = _proposeAndMatchWithFees();
        assertTrue(fr1 != fr2, "different clones");
    }

    // ── Distribute mechanics (using direct deposit to simulate fees) ────

    function _simulateFees(address feeReceiver, uint128 sellAmount, uint128 buyAmount) internal {
        if (sellAmount > 0) oracle.deposit(address(sellToken), sellAmount, feeReceiver);
        if (buyAmount > 0) oracle.deposit(address(buyToken), buyAmount, feeReceiver);
    }

    function testProtocolFees_FiftyFiftySplit() public {
        (, , address feeReceiver) = _proposeAndMatchWithFees();
        uint128 fees = 100e18;
        _simulateFees(feeReceiver, fees, 0);

        uint256 swapperBefore = _spendable(swapper, address(sellToken));
        uint256 matcherBefore = _spendable(matcher, address(sellToken));

        oracleFeeReceiver(feeReceiver).distribute();

        assertEq(_spendable(swapper, address(sellToken)), swapperBefore + fees / 2, "swapper got half");
        assertEq(_spendable(matcher, address(sellToken)), matcherBefore + (fees - fees / 2), "matcher got half");
    }

    function testProtocolFees_BothTokensSplit() public {
        (, , address feeReceiver) = _proposeAndMatchWithFees();
        _simulateFees(feeReceiver, 100e18, 200e18);

        uint256 swapperSellBefore = _spendable(swapper, address(sellToken));
        uint256 swapperBuyBefore = _spendable(swapper, address(buyToken));
        uint256 matcherSellBefore = _spendable(matcher, address(sellToken));
        uint256 matcherBuyBefore = _spendable(matcher, address(buyToken));

        oracleFeeReceiver(feeReceiver).distribute();

        assertEq(_spendable(swapper, address(sellToken)), swapperSellBefore + 50e18, "swapper sell half");
        assertEq(_spendable(matcher, address(sellToken)), matcherSellBefore + 50e18, "matcher sell half");
        assertEq(_spendable(swapper, address(buyToken)), swapperBuyBefore + 100e18, "swapper buy half");
        assertEq(_spendable(matcher, address(buyToken)), matcherBuyBefore + 100e18, "matcher buy half");
    }

    function testProtocolFees_OddAmountRounding() public {
        (, , address feeReceiver) = _proposeAndMatchWithFees();
        _simulateFees(feeReceiver, 101, 0); // odd

        uint256 swapperBefore = _spendable(swapper, address(sellToken));
        uint256 matcherBefore = _spendable(matcher, address(sellToken));

        oracleFeeReceiver(feeReceiver).distribute();

        // 101 / 2 = 50 to swapper; 101 - 50 = 51 to matcher (matcher gets the remainder)
        assertEq(_spendable(swapper, address(sellToken)), swapperBefore + 50, "swapper got 50");
        assertEq(_spendable(matcher, address(sellToken)), matcherBefore + 51, "matcher got 51");
    }

    function testProtocolFees_ZeroFeesNoOp() public {
        (, , address feeReceiver) = _proposeAndMatchWithFees();
        // No simulated fees
        (uint256 f1, uint256 f2) = oracleFeeReceiver(feeReceiver).distribute();
        assertEq(f1, 0, "fees1 zero");
        assertEq(f2, 0, "fees2 zero");
    }

    function testProtocolFees_DoubleCallNoDoubleDistribution() public {
        (, , address feeReceiver) = _proposeAndMatchWithFees();
        _simulateFees(feeReceiver, 100e18, 0);

        oracleFeeReceiver(feeReceiver).distribute();

        uint256 swapperAfterFirst = _spendable(swapper, address(sellToken));

        // Second call drains nothing — balance left is just the sentinel
        (uint256 f1, uint256 f2) = oracleFeeReceiver(feeReceiver).distribute();
        assertEq(f1, 0, "second call distributes 0");
        assertEq(f2, 0, "second call distributes 0");
        assertEq(_spendable(swapper, address(sellToken)), swapperAfterFirst, "swapper unchanged");
    }

    function testProtocolFees_AnyoneCanDistribute() public {
        (, , address feeReceiver) = _proposeAndMatchWithFees();
        _simulateFees(feeReceiver, 100e18, 0);

        uint256 swapperBefore = _spendable(swapper, address(sellToken));
        uint256 matcherBefore = _spendable(matcher, address(sellToken));

        // Permissionless: any caller can trigger distribution
        vm.prank(address(0xDEAD));
        oracleFeeReceiver(feeReceiver).distribute();

        assertEq(_spendable(swapper, address(sellToken)), swapperBefore + 50e18, "swapper got half");
        assertEq(_spendable(matcher, address(sellToken)), matcherBefore + 50e18, "matcher got half");
    }

    /// @notice After a swap is terminal (hash deleted), distribute() still works on the
    ///         orphaned feeReceiver clone. Locks in the design that fee recovery does not
    ///         depend on swap-hash authentication.
    function testProtocolFees_DistributeWorksAfterTerminalDelete() public {
        // 1) Run full propose → match → settle → execute. execute internally calls
        //    grabOracleGameFees, but with no real disputes there are no fees yet.
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReportWithFeeRecipient(s, m, 2000e18, sPost.feeRecipient);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);
        address feeReceiver = sPost.feeRecipient;

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        _settle(reportId, og, ph);
        _execute(swapId, sPost, og, ph, address(0x99));

        // 2) Swap is terminal — hash deleted.
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted post-execute");

        // 3) Simulate fees arriving at the feeReceiver after terminal state (e.g. some
        //    late dispute or external accrual). distribute() should still partition them.
        _simulateFees(feeReceiver, 200e18, 0);
        uint256 swapperBefore = _spendable(swapper, address(sellToken));
        uint256 matcherBefore = _spendable(matcher, address(sellToken));

        // 4) Anyone can call distribute() directly on the clone — no swap hash needed.
        vm.prank(address(0xBEEF));
        oracleFeeReceiver(feeReceiver).distribute();

        assertEq(_spendable(swapper, address(sellToken)), swapperBefore + 100e18, "swapper got half post-terminal");
        assertEq(_spendable(matcher, address(sellToken)), matcherBefore + 100e18, "matcher got half post-terminal");

        // 5) Idempotent: second call returns zero, no double distribution.
        vm.prank(address(0xBEEF));
        (uint256 f1, uint256 f2) = oracleFeeReceiver(feeReceiver).distribute();
        assertEq(f1, 0, "second call no-ops");
        assertEq(f2, 0, "second call no-ops");
    }

    // ── Real dispute → fee receiver routing ────────────────────────────

    /// @notice End-to-end: a real oracle.dispute() must credit protocolFee to feeReceiver's
    ///         internal balance, and distribute() must split it 50/50 to swapper + matcher.
    function testProtocolFees_RealDisputeRoutesToFeeReceiver() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        (uint128 reportId,, openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);
        // OracleGame was committed with protocolFeeRecipient = clone address.
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReportWithFeeRecipient(s, m, 2000e18, sPost.feeRecipient);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);
        address feeReceiver = sPost.feeRecipient;

        // Set up a disputer with internal sellToken balance (paying the escalation)
        address disputer = address(0xD15);
        sellToken.transfer(disputer, 100e18);
        vm.startPrank(disputer);
        sellToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(sellToken), 100e18, disputer);
        vm.stopPrank();

        // Warp past disputeDelay (default 5s)
        vm.warp(block.timestamp + DISPUTE_DELAY + 1);
        vm.roll(block.number + 1);

        // Dispute: escalate token1 (sellToken) with multiplier=110 → newAmount1 = 1.1e18
        uint128 newAmount1 = uint128((uint256(INITIAL_LIQUIDITY) * 110) / 100);
        uint128 newAmount2 = 2000e18; // unchanged → no token2 swap
        vm.prank(disputer);
        IOpenOracle2(address(oracle)).dispute(
            reportId, address(sellToken), newAmount1, newAmount2, disputer,
            true, true, og, ph, IOpenOracle2.TimingBoundaries(0, 0, 0, 0)
        );

        // Verify protocolFee landed in feeReceiver
        uint256 expectedFee = (uint256(INITIAL_LIQUIDITY) * PROTO_FEE) / 1e7; // 1e18 * 1000 / 1e7 = 1e14
        assertEq(_spendable(feeReceiver, address(sellToken)), expectedFee, "feeReceiver got protocolFee");

        // Distribute — swapper + matcher get half each, credited to internal balance
        uint256 swapperSellBefore = _spendable(swapper, address(sellToken));
        uint256 matcherSellBefore = _spendable(matcher, address(sellToken));
        oracleFeeReceiver(feeReceiver).distribute();

        assertEq(_spendable(swapper, address(sellToken)), swapperSellBefore + expectedFee / 2, "swapper got half");
        assertEq(
            _spendable(matcher, address(sellToken)),
            matcherSellBefore + (expectedFee - expectedFee / 2),
            "matcher got half"
        );
        // feeReceiver drained to sentinel
        assertEq(_spendable(feeReceiver, address(sellToken)), 0, "feeReceiver drained");
    }

    // ── Internal-only ETH fee distribution (ETH-rejecter as matcher) ────

    /// @notice Real ERC20→ETH swap matched by an EthRejecter contract.
    ///         distribute() credits both swapper (EOA) and rejecter (contract without receive)
    ///         to their oracle internal balance — no external push, so rejecter is fine.
    function testProtocolFees_EthFeesCreditedInternally() public {
        EthRejecter rejecter = new EthRejecter();

        // Fund rejecter: ETH via vm.deal (bypasses receive), sellToken via direct transfer
        vm.deal(address(rejecter), 100 ether);
        sellToken.transfer(address(rejecter), 100e18);

        // Rejecter sets up its own oracle internal balances + approveInternal to openSwap
        rejecter.approveErc20(address(sellToken), address(oracle), type(uint256).max);
        rejecter.depositTokenToOracle(IOpenOracle2(address(oracle)), address(sellToken), 100e18);
        rejecter.depositEthToOracle{value: 50 ether}(IOpenOracle2(address(oracle)), 50 ether);
        rejecter.approveInternal(
            IOpenOracle2(address(oracle)), address(swapContract), address(sellToken), type(uint256).max
        );
        rejecter.approveInternal(
            IOpenOracle2(address(oracle)), address(swapContract), address(0), type(uint256).max
        );

        // Propose ERC20→ETH swap with tight, ratio-matched slippage so execute passes.
        // sellAmt=1e18, amount2=2e18 → price = 1e18 * 1e30 / 2e18 = 5e29.
        uint128 sellAmt = 1e18;
        uint128 minFulfill = 3 ether;
        uint96 mgc = 0.001 ether;
        uint96 egc = 0.001 ether;
        SwapCompat.SlippageParams memory slip =
            SwapCompat.SlippageParams({priceTolerated: 5e29, toleranceRange: 1e7 - 1});

        uint256 swapId = _proposeEthBuyWith(sellAmt, minFulfill, mgc, egc, slip);

        // Build the same Swap/MatcherPreimage that propose hashed
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildEthBuySwap(sellAmt, minFulfill, mgc, egc, slip);

        // Predict the feeReceiver clone
        address feeReceiver = vm.computeCreateAddress(address(swapContract), vm.getNonce(address(swapContract)));

        // Match — rejecter calls matchSwap directly
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        rejecter.doMatch(swapContract, swapId, uint128(2 ether), s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));

        // Sanity: feeReceiver records rejecter as matcher, and token2 is ETH (address(0))
        assertEq(oracleFeeReceiver(feeReceiver).matcher(), address(rejecter), "matcher = rejecter");
        assertEq(oracleFeeReceiver(feeReceiver).token2(), address(0), "token2 = ETH");

        // Simulate accrued ETH fees via a real oracle.deposit into feeReceiver's address(0) slot
        oracle.deposit{value: 1 ether}(address(0), 1 ether, feeReceiver);
        assertEq(_spendable(feeReceiver, address(0)), 1 ether, "ETH fees parked");

        // Distribute — both recipients get ETH credited to internal balance
        uint256 swapperInternalBefore = _spendable(swapper, address(0));
        uint256 rejecterInternalBefore = _spendable(address(rejecter), address(0));

        oracleFeeReceiver(feeReceiver).distribute();

        assertEq(
            _spendable(swapper, address(0)),
            swapperInternalBefore + 0.5 ether,
            "swapper got ETH credited internally"
        );
        assertEq(
            _spendable(address(rejecter), address(0)),
            rejecterInternalBefore + 0.5 ether,
            "rejecter got ETH credited internally"
        );
    }

    function _proposeEthBuyWith(
        uint128 sellAmt,
        uint128 minFulfill,
        uint96 mgc,
        uint96 egc,
        SwapCompat.SlippageParams memory slip
    ) internal returns (uint256 swapId) {
        proposeTs = uint48(block.timestamp);
        vm.prank(swapper);
        swapId = SwapCompat.proposeRaw(swapContract, uint256(mgc) + uint256(egc) + SETTLER_REWARD, 
            sellAmt, address(sellToken), 1, address(0), minFulfill,
            uint48(1 hours), mgc, egc,
            _defaultOracleParams(), slip, _defaultFulfillFee(), _emptyPermit2(), false
        );
    }

    function _buildEthBuySwap(
        uint128 sellAmt,
        uint128 minFulfill,
        uint96 mgc,
        uint96 egc,
        SwapCompat.SlippageParams memory slip
    ) internal view returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) {
        s.swapper = swapper;
        s.sellAmt = sellAmt;
        s.sellToken = address(sellToken);
        s.buyToken = address(0);
        s.minFulfillLiquidity = minFulfill;
        s.expiration = uint48(block.timestamp + 1 hours);
        s.maxGameTime = MAX_GAME_TIME;
        s.blocksPerSecond = 500;
        s.settlerReward = SETTLER_REWARD;
        s.priceTolerated = slip.priceTolerated;
        s.toleranceRange = slip.toleranceRange;
        s.matcherGasComp = mgc;
        s.executorGasComp = egc;

        SwapCompat.OracleParams memory op = _defaultOracleParams();
        m.initialLiquidity = op.initialLiquidity;
        m.escalationHalt = op.escalationHalt;
        m.settlementTime = op.settlementTime;
        m.disputeDelay = op.disputeDelay;
        m.protocolFee = op.protocolFee;
        m.multiplier = op.multiplier;
        m.startFulfillFeeIncrease = proposeTs;
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();
        m.maxFee = ff.maxFee;
        m.startingFee = ff.startingFee;
        m.roundLength = ff.roundLength;
        m.growthRate = ff.growthRate;
        m.maxRounds = ff.maxRounds;
    }
}

/// @notice Contract with no receive()/fallback — ETH transfers to it fail.
///         Implements minimal helpers so the test can set up its internal balances.
contract EthRejecter {
    function approveErc20(address token, address spender, uint256 amt) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amt));
        require(ok, "approve failed");
    }

    function depositTokenToOracle(IOpenOracle2 oracle, address token, uint128 amt) external {
        oracle.deposit(token, amt, address(this));
    }

    function depositEthToOracle(IOpenOracle2 oracle, uint128 amt) external payable {
        oracle.deposit{value: msg.value}(address(0), amt, address(this));
    }

    function approveInternal(IOpenOracle2 oracle, address spender, address token, uint256 amt) external {
        oracle.approveInternal(spender, token, amt);
    }

    function doMatch(
        openSwapV2 sc,
        uint256 swapId,
        uint128 amount2,
        openSwapV2.ProposedSwap calldata s,
        openSwapV2.MatcherPreimage calldata m,
        IOpenOracle2.TimingBoundaries calldata t
    ) external {
        sc.matchSwap(swapId, amount2, s, m, t);
    }

    // Deliberately no receive() / fallback — incoming ETH via .call{value:} reverts
}
