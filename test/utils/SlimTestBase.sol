// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {openSwapV2} from "../../src/swap/OpenSwapSlim.sol";
import "../../src/interfaces/IOpenOracle2.sol";
import "../../src/interfaces/ISignatureTransfer.sol";
import "./MockERC20.sol";
import "./MockPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {SwapCompat} from "../openSwapPermitTesting/SwapCompat.sol";

abstract contract SlimTestBase is Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Contracts (deployed in _baseDeploy)
    OpenOracle internal oracle;
    openSwapV2 internal swapContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    // Actors — kept above precompile range so ETH `call{value:}` works without precompile quirks
    address internal swapper = address(0x1001);
    address internal matcher = address(0x1002);
    address internal settler = address(0x1004);

    // Defaults — override by changing the helper functions if needed
    uint96 constant SETTLER_REWARD = 0.001 ether;
    uint128 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant PROTOCOL_FEE = 0;
    uint24 constant MAX_GAME_TIME = uint24(SETTLEMENT_TIME) * 20;

    uint128 constant SELL_AMT = 10e18;
    uint128 constant MIN_OUT = 1e18;
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint96 constant MATCHER_GAS_COMP = 0.001 ether;
    uint96 constant EXECUTOR_GAS_COMP = 0.001 ether;

    uint24 constant MAX_FEE = 10000;
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000;
    uint16 constant MAX_ROUNDS = 10;

    // Captured at propose for MatcherPreimage reconstruction (startFulfillFeeIncrease)
    uint48 internal proposeTs;
    // Captured at match for oracle state reconstruction
    uint48 internal reportTs;
    uint48 internal reportBn;
    // Captured at propose so _buildSwapAndPreimage reproduces the stored hash shape.
    bool internal proposeUseInternal;

    // ── deployment & setup ──────────────────────────────────────────────

    function _baseDeploy() internal {
        MockPermit2 permit2 = new MockPermit2();
        vm.etch(PERMIT2, address(permit2).code);

        oracle = new OpenOracle();
        swapContract = new openSwapV2(address(oracle));

        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new MockERC20("BuyToken", "BUY");
    }

    function _fundAccounts() internal {
        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(matcher, 100e18);
        buyToken.transfer(matcher, 100_000e18);

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(settler, 1 ether);
    }

    function _setupSwapperPermit2(address who, address token) internal {
        vm.prank(who);
        IERC20(token).approve(PERMIT2, type(uint256).max);
    }

    /// @dev Swapper deposits internal-balance funds + approves openSwap to spend them (internal-balance mode).
    function _setupSwapperInternalBalance(address who, address token, uint128 amount) internal {
        vm.startPrank(who);
        IERC20(token).approve(address(oracle), type(uint256).max);
        oracle.deposit(token, amount, who);
        oracle.approveInternal(address(swapContract), token, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Same as above but for ETH sell.
    function _setupSwapperInternalEth(address who, uint128 amount) internal {
        vm.startPrank(who);
        oracle.deposit{value: amount}(address(0), amount, who);
        oracle.approveInternal(address(swapContract), address(0), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Matcher deposits internal-balance funds + approves openSwap to spend them.
    function _setupMatcherInternalBalance(address who, uint128 sellAmount, uint128 buyAmount) internal {
        vm.startPrank(who);
        sellToken.approve(address(oracle), type(uint256).max);
        buyToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(sellToken), sellAmount, who);
        oracle.deposit(address(buyToken), buyAmount, who);
        oracle.approveInternal(address(swapContract), address(sellToken), type(uint256).max);
        oracle.approveInternal(address(swapContract), address(buyToken), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Convenience: full base setup (deploy + fund + warm swapper + matcher).
    function _setUpAll() internal {
        _baseDeploy();
        _fundAccounts();
        _setupSwapperPermit2(swapper, address(sellToken));
        _setupMatcherInternalBalance(matcher, 100e18, 100_000e18);
    }

    // ── param builders ──────────────────────────────────────────────────

    function _defaultOracleParams() internal view virtual returns (SwapCompat.OracleParams memory) {
        return SwapCompat.OracleParams({
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlerReward: SETTLER_REWARD,
            settlementTime: SETTLEMENT_TIME,
            maxGameTime: MAX_GAME_TIME,
            disputeDelay: DISPUTE_DELAY,
            protocolFee: PROTOCOL_FEE,
            multiplier: 110,
            blocksPerSecond: 500
        });
    }

    function _swapCompatParams() internal view returns (SwapCompat.OracleParams memory) {
        return _defaultOracleParams();
    }

    function _defaultSlippage() internal view virtual returns (SwapCompat.SlippageParams memory) {
        return SwapCompat.SlippageParams({priceTolerated: 5e26, toleranceRange: 1e7 - 1});
    }

    function _defaultFulfillFee() internal view virtual returns (openSwapV2.FulfillFeeParams memory) {
        return openSwapV2.FulfillFeeParams({
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
    }

    function _emptyPermit2() internal pure returns (openSwapV2.Permit2Params memory) {
        return openSwapV2.Permit2Params({nonce: 0, deadline: type(uint256).max, signature: bytes("")});
    }

    // ── flow helpers ────────────────────────────────────────────────────

    function _propose() internal returns (uint256 swapId, uint48 expiration) {
        return _proposeWith(false);
    }

    function _proposeWith(bool useInternalBalances) internal returns (uint256 swapId, uint48 expiration) {
        uint48 currentTimestamp = uint48(vm.getBlockTimestamp());
        expiration = currentTimestamp + 1 hours;
        proposeTs = currentTimestamp;
        proposeUseInternal = useInternalBalances;
        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        vm.prank(swapper);
        swapId = SwapCompat.proposeRaw(
            swapContract,
            ethToSend,
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(),
            useInternalBalances
        );
    }

    function _match(uint256 swapId, uint128 amount2, uint48 expiration)
        internal
        returns (uint128 reportId, uint24 fulfillmentFee, openSwapV2.MatchedSwap memory sPost)
    {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);
        IOpenOracle2.TimingBoundaries memory timing = IOpenOracle2.TimingBoundaries(0, 0, 0, 0);

        reportTs = uint48(vm.getBlockTimestamp());
        reportBn = uint48(vm.getBlockNumber());
        reportId = uint128(oracle.nextReportId());

        address predictedClone = m.protocolFee > 0
            ? _predictSwapFeeReceiver(swapId, s.sellToken, s.buyToken, s.swapper, matcher)
            : address(0);

        vm.prank(matcher);
        swapContract.matchSwap(swapId, amount2, s, m, timing);

        fulfillmentFee = _calcFulfillFee();
        sPost = _postMatchSwap(s, reportId, fulfillmentFee, reportTs);
        sPost.feeRecipient = predictedClone;
    }

    function _predictSwapFeeReceiver(
        uint256 swapId,
        address token1,
        address token2,
        address receiverSwapper,
        address receiverMatcher
    ) internal view returns (address) {
        bytes memory args = abi.encodePacked(swapId, token1, token2, receiverSwapper, receiverMatcher);
        return LibClone.predictDeterministicAddress(
            swapContract.feeReceiverImpl(), args, bytes32(swapId), address(swapContract)
        );
    }

    /// @dev Mirror of openSwap's calcFee for tests that need to know what fee will be applied at match time.
    function _calcFulfillFee() internal view returns (uint24) {
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();
        uint256 timeDelta = (block.timestamp - proposeTs) / ff.roundLength;
        if (timeDelta > ff.maxRounds) timeDelta = ff.maxRounds;
        uint256 currentFee = ff.startingFee;
        for (uint256 i = 0; i < timeDelta; i++) {
            currentFee = (currentFee * ff.growthRate) / 10000;
            if (currentFee >= ff.maxFee) return uint24(ff.maxFee);
        }
        return uint24(currentFee);
    }

    function _settle(uint128 reportId, IOpenOracle2.OracleGame memory og, IOpenOracle2.PreimageHelper memory ph)
        internal
    {
        vm.prank(settler);
        IOpenOracle2(address(oracle)).settle(reportId, og, ph);
    }

    function _execute(
        uint256 swapId,
        openSwapV2.MatchedSwap memory sPost,
        IOpenOracle2.OracleGame memory og,
        IOpenOracle2.PreimageHelper memory ph,
        address executor
    ) internal {
        IOpenOracle2.OracleGame memory ogSettled = og;
        ogSettled.settlementTimestamp = uint48(block.timestamp);

        vm.prank(executor);
        swapContract.execute(swapId, sPost, ogSettled, ph, false);
    }

    // ── struct builders ─────────────────────────────────────────────────

    function _buildSwapAndPreimage(uint256 /*swapId*/, uint48 expiration)
        internal
        view
        virtual
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        s.swapper = swapper;
        s.sellAmt = SELL_AMT;
        s.sellToken = address(sellToken);
        s.buyToken = address(buyToken);
        s.minFulfillLiquidity = MIN_FULFILL_LIQUIDITY;
        s.expiration = expiration;
        s.maxGameTime = MAX_GAME_TIME;
        s.blocksPerSecond = 500;
        s.settlerReward = SETTLER_REWARD;
        SwapCompat.SlippageParams memory slip = _defaultSlippage();
        s.priceTolerated = slip.priceTolerated;
        s.toleranceRange = slip.toleranceRange;
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.executorGasComp = EXECUTOR_GAS_COMP;
        s.useInternalBalances = proposeUseInternal;

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

    function _postMatchSwap(
        openSwapV2.ProposedSwap memory s,
        uint128 reportId,
        uint24 fulfillmentFee,
        uint48 startTs
    ) internal view returns (openSwapV2.MatchedSwap memory sp) {
        sp.sellAmt = s.sellAmt;
        sp.minFulfillLiquidity = s.minFulfillLiquidity;
        sp.maxGameTime = s.maxGameTime;
        sp.blocksPerSecond = s.blocksPerSecond;
        sp.buyToken = s.buyToken;
        sp.sellToken = s.sellToken;
        sp.swapper = s.swapper;
        sp.executorGasComp = s.executorGasComp;
        sp.useInternalBalances = s.useInternalBalances;
        sp.priceTolerated = s.priceTolerated;
        sp.toleranceRange = s.toleranceRange;

        sp.matcher = matcher;
        sp.start = startTs;
        sp.fulfillmentFee = fulfillmentFee;
        sp.reportId = reportId;
    }

    function _buildOracleGameAtReport(
        openSwapV2.ProposedSwap memory s,
        openSwapV2.MatcherPreimage memory m,
        uint128 amount2
    ) internal view returns (IOpenOracle2.OracleGame memory) {
        return _buildOracleGameAtReportWithFeeRecipient(s, m, amount2, address(0));
    }

    function _buildOracleGameAtReportWithFeeRecipient(
        openSwapV2.ProposedSwap memory s,
        openSwapV2.MatcherPreimage memory m,
        uint128 amount2,
        address feeRecipient
    ) internal view returns (IOpenOracle2.OracleGame memory) {
        return IOpenOracle2.OracleGame({
            currentAmount1: m.initialLiquidity,
            currentAmount2: amount2,
            currentReporter: matcher,
            reportTimestamp: reportTs,
            settlementTimestamp: 0,
            token1: s.sellToken,
            lastReportOppoTime: reportBn,
            settlementTime: m.settlementTime,
            escalationHalt: m.escalationHalt,
            protocolFeeRecipient: feeRecipient,
            settlerReward: uint96(s.settlerReward),
            token2: s.buyToken,
            numReports: 0,
            disputeDelay: m.disputeDelay,
            feePercentage: 0,
            multiplier: m.multiplier,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: m.protocolFee,
            flags: 1
        });
    }

    function _buildPreimageHelper(uint256 reportId)
        internal
        view
        returns (IOpenOracle2.PreimageHelper memory)
    {
        return IOpenOracle2.PreimageHelper({
            reportId: reportId,
            creator: address(swapContract),
            blockTimestamp: reportTs,
            blockNumber: reportBn
        });
    }

    // ── assertions ──────────────────────────────────────────────────────

    function _spendable(address holder, address token) internal view returns (uint256) {
        uint256 raw = oracle.tokenHolder(holder, token);
        return raw == 0 ? 0 : raw - 1;
    }
}
