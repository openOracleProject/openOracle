// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import "../utils/ReentrantHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Reentrancy matrix completion: rows where execute() or bailOut() is the
///         OUTER call. Both require an ETH-side swap to trigger pushOrCredit's
///         50k-gas ETH callback on the hook=swapper:
///
///           OUTER=execute -> buyToken=ETH; success path calls pushOrCredit(buyToken,
///                           swapper, fulfillAmt) which fires receive() on the hook
///                           AFTER `delete swaps[swapId]`.
///           OUTER=bailOut -> sellToken=ETH; refund calls pushOrCredit(sellToken,
///                           swapper, sellAmt) which fires receive() AFTER delete.
///
///         Expected revert reasons per inner call:
///
///           execute is NOT nonReentrant — relies on terminal deletion. Reentrant
///           calls to execute/cancel/bailOut all hit WrongHash() since swaps[swapId]
///           is already zero.
///
///           bailOut IS nonReentrant. Reentrant cancel/bailOut hit
///           ReentrancyGuardReentrantCall (OZ guard, lock held by outer bailOut).
///           Reentrant execute is NOT guarded, so it proceeds past the guard and
///           hits WrongHash() (deleted by outer bailOut).
contract OpenSwapReentrancyMatrixTest is SlimTestBase {
    ReentrantHook internal hook;
    bytes4 internal constant WRONG_HASH = bytes4(keccak256("WrongHash()"));
    bytes4 internal constant REENTRANCY = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    // Smaller-than-default amounts so the ETH-side balances fit.
    uint128 internal constant SELL_TINY            = uint128(1e15);    // 0.001 sellToken
    uint128 internal constant MIN_OUT_LOW          = uint128(1);
    uint128 internal constant MIN_FULFILL_ETH      = uint128(5e18);    // 5 ETH (matcher posts at match)
    uint128 internal constant MIN_FULFILL_TOK      = uint128(5e18);
    uint128 internal constant AMOUNT2_BUY_ETH      = uint128(2000e18); // oracle amount2 (ETH-side)
    uint128 internal constant AMOUNT2_BUY_TOK      = uint128(2000e18);

    function setUp() public {
        _baseDeploy();
        _fundAccounts();

        // Matcher needs deep internal balances for both ETH-side and ERC20-side swaps:
        //   - amount2 of buyToken (2000 ETH OR 2000 ERC20)
        //   - amount1=initialLiquidity of sellToken (1 token OR 1 ETH)
        //   - minFulfillLiquidity transferred at matchSwap
        vm.deal(matcher, 5000 ether);
        vm.startPrank(matcher);
        oracle.deposit{value: 4000 ether}(address(0), 4000 ether, matcher);
        oracle.approveInternal(address(swapContract), address(0), type(uint256).max);
        sellToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(sellToken), 100e18, matcher);
        oracle.approveInternal(address(swapContract), address(sellToken), type(uint256).max);
        buyToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(buyToken), 100_000e18, matcher);
        oracle.approveInternal(address(swapContract), address(buyToken), type(uint256).max);
        vm.stopPrank();

        // Hook = swapper. Holds sellToken (ERC20) for execute-reentry and ETH for bailOut-reentry.
        hook = new ReentrantHook();
        sellToken.transfer(address(hook), 100e18);
        vm.deal(address(hook), 1000 ether);
        vm.prank(address(hook));
        IERC20(address(sellToken)).approve(PERMIT2, type(uint256).max);
    }

    // ─── shared propose / match helpers for ETH-buy (execute reentry path) ────

    function _proposeBuyEth() internal returns (uint256 swapId, uint48 expiration) {
        expiration = uint48(block.timestamp + 1 hours);
        proposeTs = uint48(block.timestamp);
        proposeUseInternal = false;
        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        vm.prank(address(hook));
        swapId = SwapCompat.proposeRaw(
            swapContract,
            ethToSend,
            SELL_TINY,
            address(sellToken),    // sellToken = ERC20
            MIN_OUT_LOW,
            address(0),            // buyToken = ETH
            MIN_FULFILL_ETH,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(),
            false
        );
    }

    function _buildSwapBuyEth(uint256 /*swapId*/, uint48 expiration)
        internal
        view
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        s.swapper             = address(hook);
        s.sellAmt             = SELL_TINY;
        s.sellToken           = address(sellToken);
        s.buyToken            = address(0);
        s.minFulfillLiquidity = MIN_FULFILL_ETH;
        s.expiration          = expiration;
        s.maxGameTime         = MAX_GAME_TIME;
        s.blocksPerSecond     = 500;
        s.settlerReward       = SETTLER_REWARD;
        SwapCompat.SlippageParams memory slip = _defaultSlippage();
        s.priceTolerated      = slip.priceTolerated;
        s.toleranceRange      = slip.toleranceRange;
        s.matcherGasComp      = MATCHER_GAS_COMP;
        s.executorGasComp     = EXECUTOR_GAS_COMP;
        s.useInternalBalances = false;

        SwapCompat.OracleParams memory op = _defaultOracleParams();
        m.initialLiquidity        = op.initialLiquidity;
        m.escalationHalt          = op.escalationHalt;
        m.settlementTime          = op.settlementTime;
        m.disputeDelay            = op.disputeDelay;
        m.protocolFee             = op.protocolFee;
        m.multiplier              = op.multiplier;
        m.startFulfillFeeIncrease = proposeTs;
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();
        m.maxFee      = ff.maxFee;
        m.startingFee = ff.startingFee;
        m.roundLength = ff.roundLength;
        m.growthRate  = ff.growthRate;
        m.maxRounds   = ff.maxRounds;
    }

    function _matchHookBuyEth(uint256 swapId, uint48 expiration)
        internal
        returns (uint128 reportId, openSwapV2.MatchedSwap memory sPost)
    {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapBuyEth(swapId, expiration);
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        reportId = uint128(oracle.nextReportId());

        vm.prank(matcher);
        swapContract.matchSwap(swapId, AMOUNT2_BUY_ETH, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));

        sPost = _postMatchSwap(s, reportId, _calcFulfillFee(), reportTs);
        sPost.feeRecipient = address(0); // default protocolFee = 0
    }

    // ─── shared propose / match helpers for ETH-sell (bailOut reentry path) ───

    function _proposeSellEth() internal returns (uint256 swapId, uint48 expiration) {
        expiration = uint48(block.timestamp + 1 hours);
        proposeTs = uint48(block.timestamp);
        proposeUseInternal = false;
        // sellToken=ETH path: msg.value = sellAmt + matcherGasComp + executorGasComp + settlerReward
        uint256 ethToSend = SELL_TINY + MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        vm.prank(address(hook));
        swapId = SwapCompat.proposeRaw(
            swapContract,
            ethToSend,
            SELL_TINY,
            address(0),            // sellToken = ETH
            MIN_OUT_LOW,
            address(buyToken),     // buyToken = ERC20
            MIN_FULFILL_TOK,
            uint48(1 hours),
            MATCHER_GAS_COMP,
            EXECUTOR_GAS_COMP,
            _defaultOracleParams(),
            _defaultSlippage(),
            _defaultFulfillFee(),
            _emptyPermit2(),
            false
        );
    }

    function _buildSwapSellEth(uint256 /*swapId*/, uint48 expiration)
        internal
        view
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        s.swapper             = address(hook);
        s.sellAmt             = SELL_TINY;
        s.sellToken           = address(0);
        s.buyToken            = address(buyToken);
        s.minFulfillLiquidity = MIN_FULFILL_TOK;
        s.expiration          = expiration;
        s.maxGameTime         = MAX_GAME_TIME;
        s.blocksPerSecond     = 500;
        s.settlerReward       = SETTLER_REWARD;
        SwapCompat.SlippageParams memory slip = _defaultSlippage();
        s.priceTolerated      = slip.priceTolerated;
        s.toleranceRange      = slip.toleranceRange;
        s.matcherGasComp      = MATCHER_GAS_COMP;
        s.executorGasComp     = EXECUTOR_GAS_COMP;
        s.useInternalBalances = false;

        SwapCompat.OracleParams memory op = _defaultOracleParams();
        m.initialLiquidity        = op.initialLiquidity;
        m.escalationHalt          = op.escalationHalt;
        m.settlementTime          = op.settlementTime;
        m.disputeDelay            = op.disputeDelay;
        m.protocolFee             = op.protocolFee;
        m.multiplier              = op.multiplier;
        m.startFulfillFeeIncrease = proposeTs;
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();
        m.maxFee      = ff.maxFee;
        m.startingFee = ff.startingFee;
        m.roundLength = ff.roundLength;
        m.growthRate  = ff.growthRate;
        m.maxRounds   = ff.maxRounds;
    }

    function _matchHookSellEth(uint256 swapId, uint48 expiration)
        internal
        returns (uint128 reportId, openSwapV2.MatchedSwap memory sPost)
    {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapSellEth(swapId, expiration);
        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        reportId = uint128(oracle.nextReportId());

        vm.prank(matcher);
        swapContract.matchSwap(swapId, AMOUNT2_BUY_TOK, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));

        sPost = _postMatchSwap(s, reportId, _calcFulfillFee(), reportTs);
        sPost.feeRecipient = address(0);
    }

    // ─── OUTER = execute ─────────────────────────────────────────────────────
    // Drive a successful execute() on a buyToken=ETH swap. The success branch's
    // pushOrCredit(buyToken=ETH, swapper=hook, fulfillAmt) -> hook.receive() fires
    // AFTER `delete swaps[swapId]`. All reentry attempts must hit WrongHash().

    function _lastReentryRevertSelector() internal returns (bytes4) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReentryResult(bool,bytes)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (l.topics.length >= 1 && l.topics[0] == sig) {
                (, bytes memory data) = abi.decode(l.data, (bool, bytes));
                if (data.length >= 4) return bytes4(data);
                return bytes4(0);
            }
        }
        revert("no ReentryResult event");
    }

    function _executeOuter(bytes memory reentryPayload) internal returns (uint256 swapId) {
        uint48 expiration;
        (swapId, expiration) = _proposeBuyEth();
        (uint128 reportId, openSwapV2.MatchedSwap memory sPost) = _matchHookBuyEth(swapId, expiration);
        (openSwapV2.ProposedSwap memory s0, openSwapV2.MatcherPreimage memory m0) =
            _buildSwapBuyEth(swapId, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(s0, m0, AMOUNT2_BUY_ETH);
        IOpenOracle2.PreimageHelper memory ph = _buildPreimageHelper(reportId);

        // Advance time + blocks so settlement + impliedBlocksPerSecond pass.
        // 500 / 1000 blocks per second = 0.5 -> 302 sec needs ~151 blocks for the bps check.
        uint48 settledAt = uint48(block.timestamp) + SETTLEMENT_TIME + 1;
        vm.warp(uint256(settledAt));
        vm.roll(block.number + 151);

        hook.arm(address(swapContract), reentryPayload);
        vm.recordLogs();
        vm.prank(settler);
        // Pre-settle OracleGame; execute settles internally, then completes success path.
        swapContract.execute(swapId, sPost, og, ph, false);
    }

    function testReentry_ExecuteOuter_CannotExecute() public {
        openSwapV2.MatchedSwap memory dummyMatched;
        IOpenOracle2.OracleGame memory dummyOg;
        IOpenOracle2.PreimageHelper memory dummyPh;
        bytes memory payload = abi.encodeCall(
            swapContract.execute, (0, dummyMatched, dummyOg, dummyPh, false)
        );
        uint256 swapId = _executeOuter(payload);

        assertEq(swapContract.swaps(swapId), bytes32(0), "outer execute deleted hash");
        assertTrue(hook.attempted(), "reentry attempted");
        assertFalse(hook.attemptOk(), "reentry failed");
        assertEq(_lastReentryRevertSelector(), WRONG_HASH, "execute->execute = WrongHash");
    }

    function testReentry_ExecuteOuter_CannotCancel() public {
        openSwapV2.ProposedSwap memory dummyProposed;
        openSwapV2.MatcherPreimage memory dummyM;
        bytes memory payload = abi.encodeCall(swapContract.cancelSwap, (0, dummyProposed, dummyM));
        uint256 swapId = _executeOuter(payload);

        assertEq(swapContract.swaps(swapId), bytes32(0), "outer execute deleted hash");
        assertTrue(hook.attempted(), "reentry attempted");
        assertFalse(hook.attemptOk(), "reentry failed");
        // execute is NOT nonReentrant -> cancel acquires lock fine, then hits WrongHash.
        assertEq(_lastReentryRevertSelector(), WRONG_HASH, "execute->cancel = WrongHash");
    }

    function testReentry_ExecuteOuter_CannotBailOut() public {
        openSwapV2.MatchedSwap memory dummyMatched;
        bytes memory payload = abi.encodeCall(swapContract.bailOut, (0, dummyMatched));
        uint256 swapId = _executeOuter(payload);

        assertEq(swapContract.swaps(swapId), bytes32(0), "outer execute deleted hash");
        assertTrue(hook.attempted(), "reentry attempted");
        assertFalse(hook.attemptOk(), "reentry failed");
        assertEq(_lastReentryRevertSelector(), WRONG_HASH, "execute->bailOut = WrongHash");
    }

    // ─── OUTER = bailOut ─────────────────────────────────────────────────────
    // Drive a bailOut on a sellToken=ETH swap. refund -> pushOrCredit(sellToken=ETH,
    // swapper=hook, sellAmt) -> hook.receive() fires AFTER `delete swaps[swapId]`.
    // bailOut IS nonReentrant; cancel/bailOut reentries hit the OZ guard;
    // execute reentry passes the guard (execute is unguarded) and hits WrongHash.

    function _bailOutOuter(bytes memory reentryPayload) internal returns (uint256 swapId) {
        uint48 expiration;
        (swapId, expiration) = _proposeSellEth();
        (, openSwapV2.MatchedSwap memory sPost) = _matchHookSellEth(swapId, expiration);

        // Warp past maxGameTime so bailOut is eligible.
        vm.warp(block.timestamp + uint256(MAX_GAME_TIME) + 1);

        hook.arm(address(swapContract), reentryPayload);
        vm.recordLogs();
        vm.prank(matcher);
        swapContract.bailOut(swapId, sPost);
    }

    function testReentry_BailOutOuter_CannotExecute() public {
        openSwapV2.MatchedSwap memory dummyMatched;
        IOpenOracle2.OracleGame memory dummyOg;
        IOpenOracle2.PreimageHelper memory dummyPh;
        bytes memory payload = abi.encodeCall(
            swapContract.execute, (0, dummyMatched, dummyOg, dummyPh, false)
        );
        uint256 swapId = _bailOutOuter(payload);

        assertEq(swapContract.swaps(swapId), bytes32(0), "outer bailOut deleted hash");
        assertTrue(hook.attempted(), "reentry attempted");
        assertFalse(hook.attemptOk(), "reentry failed");
        assertEq(_lastReentryRevertSelector(), WRONG_HASH, "bailOut->execute = WrongHash");
    }

    function testReentry_BailOutOuter_CannotCancel() public {
        openSwapV2.ProposedSwap memory dummyProposed;
        openSwapV2.MatcherPreimage memory dummyM;
        bytes memory payload = abi.encodeCall(swapContract.cancelSwap, (0, dummyProposed, dummyM));
        uint256 swapId = _bailOutOuter(payload);

        assertEq(swapContract.swaps(swapId), bytes32(0), "outer bailOut deleted hash");
        assertTrue(hook.attempted(), "reentry attempted");
        assertFalse(hook.attemptOk(), "reentry failed");
        assertEq(_lastReentryRevertSelector(), REENTRANCY, "bailOut->cancel = ReentrancyGuard");
    }

    function testReentry_BailOutOuter_CannotBailOut() public {
        openSwapV2.MatchedSwap memory dummyMatched;
        bytes memory payload = abi.encodeCall(swapContract.bailOut, (0, dummyMatched));
        uint256 swapId = _bailOutOuter(payload);

        assertEq(swapContract.swaps(swapId), bytes32(0), "outer bailOut deleted hash");
        assertTrue(hook.attempted(), "reentry attempted");
        assertFalse(hook.attemptOk(), "reentry failed");
        assertEq(_lastReentryRevertSelector(), REENTRANCY, "bailOut->bailOut = ReentrancyGuard");
    }
}
