// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import "../utils/PackedDecoder.sol";

/// @notice Layout-pinning round-trip tests for the packed SwapCreated and SwapMatched
///         events, plus matched-copy regression on swaps[swapId] hash.
///
///         High-entropy / distinct values for every narrow field in ProposedSwap,
///         MatcherPreimage, and MatchedSwap. If a field is shifted to a different
///         offset (or copy logic in matchSwap skips a field), the field-level
///         assertEq will surface the drift immediately.
contract OpenSwapPackedRoundTripTest is SlimTestBase {
    bytes32 internal constant SWAP_CREATED_SIG = keccak256("SwapCreated(uint256,address,bytes)");
    bytes32 internal constant SWAP_MATCHED_SIG = keccak256("SwapMatched(uint256,bytes)");

    // High-entropy distinct values that pass validation. Token amounts kept moderate so
    // existing actor balances (100 ether each) cover them.
    uint128 internal constant E_SELL_AMT             = 0.5 ether;          // 5e17
    uint128 internal constant E_MIN_FULFILL_LIQ      = 0.25 ether;         // 2.5e17
    uint96  internal constant E_SETTLER_REWARD       = uint96(0.001 ether);
    uint24  internal constant E_MAX_GAME_TIME        = uint24(0x056ce0);   // 354_528 sec, > 20*settlementTime
    uint16  internal constant E_BLOCKS_PER_SECOND    = uint16(0x01f4);     // 500
    uint96  internal constant E_MATCHER_GAS_COMP     = uint96(0.0005 ether);
    uint96  internal constant E_EXECUTOR_GAS_COMP    = uint96(0.00025 ether);
    uint48  internal constant E_EXPIRATION_OFFSET    = uint48(1 hours);
    uint232 internal constant E_PRICE_TOLERATED      = uint232(5e26);
    uint24  internal constant E_TOLERANCE_RANGE      = uint24(0x0f4240);   // 1_000_000 (10%)
    uint128 internal constant E_INITIAL_LIQUIDITY    = uint128(1 ether);
    uint128 internal constant E_ESCALATION_HALT      = uint128(20 ether);
    uint48  internal constant E_SETTLEMENT_TIME      = uint48(0x012c);     // 300
    uint24  internal constant E_DISPUTE_DELAY        = uint24(0x05);       // 5
    uint24  internal constant E_PROTOCOL_FEE         = uint24(0x00);       // 0 (avoid clone path)
    uint16  internal constant E_MULTIPLIER           = uint16(0x006e);     // 110
    uint24  internal constant E_MAX_FEE              = uint24(0x002710);   // 10_000
    uint24  internal constant E_STARTING_FEE         = uint24(0x002710);   // 10_000
    uint24  internal constant E_ROUND_LENGTH         = uint24(0x3c);       // 60
    uint16  internal constant E_GROWTH_RATE          = uint16(0x3a98);     // 15000
    uint16  internal constant E_MAX_ROUNDS           = uint16(0x0a);       // 10
    uint128 internal constant E_MIN_OUT              = uint128(0x010203040506);
    uint128 internal constant E_AMOUNT2              = uint128(0x0a0b0c0d0e0f1011);

    function setUp() public {
        _setUpAll();
    }

    function _highEntropyProposedSwap() internal view returns (openSwapV2.ProposedSwap memory s) {
        s.sellAmt              = E_SELL_AMT;
        s.minFulfillLiquidity  = E_MIN_FULFILL_LIQ;
        s.settlerReward        = E_SETTLER_REWARD;
        s.maxGameTime          = E_MAX_GAME_TIME;
        s.blocksPerSecond      = E_BLOCKS_PER_SECOND;
        s.buyToken             = address(buyToken);
        s.matcherGasComp       = E_MATCHER_GAS_COMP;
        s.sellToken            = address(sellToken);
        s.swapper              = address(0); // override → caller()
        s.executorGasComp      = E_EXECUTOR_GAS_COMP;
        s.useInternalBalances  = false;
        s.expiration           = E_EXPIRATION_OFFSET;
        s.priceTolerated       = E_PRICE_TOLERATED;
        s.toleranceRange       = E_TOLERANCE_RANGE;
    }

    function _highEntropyMatcherPreimage() internal pure returns (openSwapV2.MatcherPreimage memory m) {
        m.initialLiquidity         = E_INITIAL_LIQUIDITY;
        m.escalationHalt           = E_ESCALATION_HALT;
        m.settlementTime           = E_SETTLEMENT_TIME;
        m.disputeDelay             = E_DISPUTE_DELAY;
        m.protocolFee              = E_PROTOCOL_FEE;
        m.multiplier               = E_MULTIPLIER;
        m.startFulfillFeeIncrease  = 0; // override → block.timestamp
        m.maxFee                   = E_MAX_FEE;
        m.startingFee              = E_STARTING_FEE;
        m.roundLength              = E_ROUND_LENGTH;
        m.growthRate               = E_GROWTH_RATE;
        m.maxRounds                = E_MAX_ROUNDS;
    }

    function _findPackedLog(Vm.Log[] memory logs, bytes32 sig)
        internal
        pure
        returns (uint256 idx)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == sig) return i;
        }
        revert("packed event not found");
    }

    function testRoundTrip_SwapCreated_DecodesAllFields() public {
        openSwapV2.ProposedSwap memory s = _highEntropyProposedSwap();
        openSwapV2.MatcherPreimage memory m = _highEntropyMatcherPreimage();

        uint256 ethToSend = uint256(s.matcherGasComp) + uint256(s.executorGasComp) + uint256(s.settlerReward);

        vm.recordLogs();
        vm.prank(swapper);
        uint256 swapId =
            swapContract.propose{value: ethToSend}(s, m, _emptyPermit2(), E_MIN_OUT);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 idx = _findPackedLog(logs, SWAP_CREATED_SIG);
        assertEq(uint256(logs[idx].topics[1]), swapId, "topic swapId");
        assertEq(address(uint160(uint256(logs[idx].topics[2]))), swapper, "topic swapper");
        bytes memory packed = logs[idx].data;
        assertEq(packed.length, 237, "packed length");

        // Build expected: input + overrides.
        openSwapV2.ProposedSwap memory expected = s;
        expected.swapper = swapper;
        expected.expiration = uint48(block.timestamp + uint256(s.expiration));
        openSwapV2.MatcherPreimage memory expectedM = m;
        expectedM.startFulfillFeeIncrease = uint48(block.timestamp);

        openSwapV2.ProposedSwap memory ds = PackedDecoder.decodeProposedSwap(packed);
        assertEq(ds.sellAmt,             expected.sellAmt,             "sellAmt");
        assertEq(ds.minFulfillLiquidity, expected.minFulfillLiquidity, "minFulfillLiquidity");
        assertEq(ds.settlerReward,       expected.settlerReward,       "settlerReward");
        assertEq(ds.maxGameTime,         expected.maxGameTime,         "maxGameTime");
        assertEq(ds.blocksPerSecond,     expected.blocksPerSecond,     "blocksPerSecond");
        assertEq(ds.buyToken,            expected.buyToken,            "buyToken");
        assertEq(ds.matcherGasComp,      expected.matcherGasComp,      "matcherGasComp");
        assertEq(ds.sellToken,           expected.sellToken,           "sellToken");
        assertEq(ds.swapper,             expected.swapper,             "swapper (override = caller)");
        assertEq(ds.executorGasComp,     expected.executorGasComp,     "executorGasComp");
        assertEq(ds.useInternalBalances, expected.useInternalBalances, "useInternalBalances");
        assertEq(ds.expiration,          expected.expiration,          "expiration (override = absolute)");
        assertEq(ds.priceTolerated,      uint256(expected.priceTolerated), "priceTolerated");
        assertEq(ds.toleranceRange,      expected.toleranceRange,      "toleranceRange");

        openSwapV2.MatcherPreimage memory dm = PackedDecoder.decodeMatcherPreimage(packed);
        assertEq(dm.initialLiquidity,        expectedM.initialLiquidity,        "initialLiquidity");
        assertEq(dm.escalationHalt,          expectedM.escalationHalt,          "escalationHalt");
        assertEq(dm.settlementTime,          expectedM.settlementTime,          "settlementTime");
        assertEq(dm.disputeDelay,            expectedM.disputeDelay,            "disputeDelay");
        assertEq(dm.protocolFee,             expectedM.protocolFee,             "protocolFee");
        assertEq(dm.multiplier,              expectedM.multiplier,              "multiplier");
        assertEq(dm.startFulfillFeeIncrease, expectedM.startFulfillFeeIncrease, "startFulfillFeeIncrease (override = ts)");
        assertEq(dm.maxFee,                  expectedM.maxFee,                  "maxFee");
        assertEq(dm.startingFee,             expectedM.startingFee,             "startingFee");
        assertEq(dm.roundLength,             expectedM.roundLength,             "roundLength");
        assertEq(dm.growthRate,              expectedM.growthRate,              "growthRate");
        assertEq(dm.maxRounds,               expectedM.maxRounds,               "maxRounds");
    }

    function testRoundTrip_SwapMatched_DecodesAllFields_AndMatchedCopyRegression() public {
        openSwapV2.ProposedSwap memory s = _highEntropyProposedSwap();
        openSwapV2.MatcherPreimage memory m = _highEntropyMatcherPreimage();
        uint256 ethToSend = uint256(s.matcherGasComp) + uint256(s.executorGasComp) + uint256(s.settlerReward);

        vm.prank(swapper);
        uint256 swapId =
            swapContract.propose{value: ethToSend}(s, m, _emptyPermit2(), E_MIN_OUT);

        // Apply propose-side overrides to s/m so they reflect the on-chain stored swap.
        s.swapper = swapper;
        s.expiration = uint48(block.timestamp + uint256(E_EXPIRATION_OFFSET));
        m.startFulfillFeeIncrease = uint48(block.timestamp);

        // Match. Capture pre-match nextReportId for expected reportId.
        uint128 expectedReportId = uint128(oracle.nextReportId());
        uint48 expectedStart = uint48(block.timestamp);

        vm.recordLogs();
        vm.prank(matcher);
        swapContract.matchSwap(swapId, E_AMOUNT2, s, m, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 idx = _findPackedLog(logs, SWAP_MATCHED_SIG);
        assertEq(uint256(logs[idx].topics[1]), swapId, "topic swapId");
        bytes memory packed = logs[idx].data;
        assertEq(packed.length, 207, "packed length");

        // Expected MatchedSwap mirrors openSwap.matchSwap's MatchedSwap construction.
        openSwapV2.MatchedSwap memory expected;
        expected.sellAmt              = s.sellAmt;
        expected.minFulfillLiquidity  = s.minFulfillLiquidity;
        expected.maxGameTime          = s.maxGameTime;
        expected.blocksPerSecond      = s.blocksPerSecond;
        expected.buyToken             = s.buyToken;
        expected.sellToken            = s.sellToken;
        expected.swapper              = s.swapper;
        expected.executorGasComp      = s.executorGasComp;
        expected.useInternalBalances  = s.useInternalBalances;
        expected.reportId             = expectedReportId;
        expected.matcher              = matcher;
        expected.start                = expectedStart;
        expected.fulfillmentFee       = _calcFulfillFee();
        expected.feeRecipient         = address(0); // protocolFee == 0
        expected.priceTolerated       = s.priceTolerated;
        expected.toleranceRange       = s.toleranceRange;

        openSwapV2.MatchedSwap memory dm = PackedDecoder.decodeMatchedSwap(packed);
        assertEq(dm.sellAmt,              expected.sellAmt,              "sellAmt");
        assertEq(dm.minFulfillLiquidity,  expected.minFulfillLiquidity,  "minFulfillLiquidity");
        assertEq(dm.maxGameTime,          expected.maxGameTime,          "maxGameTime");
        assertEq(dm.blocksPerSecond,      expected.blocksPerSecond,      "blocksPerSecond");
        assertEq(dm.buyToken,             expected.buyToken,             "buyToken");
        assertEq(dm.sellToken,            expected.sellToken,            "sellToken");
        assertEq(dm.swapper,              expected.swapper,              "swapper");
        assertEq(dm.executorGasComp,      expected.executorGasComp,      "executorGasComp");
        assertEq(dm.useInternalBalances,  expected.useInternalBalances,  "useInternalBalances");
        assertEq(dm.reportId,             expected.reportId,             "reportId");
        assertEq(dm.matcher,              expected.matcher,              "matcher");
        assertEq(dm.start,                expected.start,                "start");
        assertEq(dm.fulfillmentFee,       expected.fulfillmentFee,       "fulfillmentFee");
        assertEq(dm.feeRecipient,         expected.feeRecipient,         "feeRecipient");
        assertEq(dm.priceTolerated,       uint256(expected.priceTolerated), "priceTolerated");
        assertEq(dm.toleranceRange,       expected.toleranceRange,       "toleranceRange");

        // Matched-copy regression: the stored swap hash must equal abi.encode of the
        // reconstructed MatchedSwap. Any silent copy skip / wrong field assignment in
        // matchSwap's MatchedSwap builder surfaces here.
        bytes32 expectedSwapHash = keccak256(abi.encode(expected));
        assertEq(swapContract.swaps(swapId), expectedSwapHash, "swaps[swapId] == keccak(expected MatchedSwap)");
    }
}
