// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import "../utils/PackedDecoder.sol";
import {MockPermit2} from "../utils/MockPermit2.sol";

/// @notice End-to-end "bots can drive every next call from packed logs alone" tests,
///         plus permit2 witness invariance.
///
///         1. testIntegration_FullLifecycle_FromPackedLogsOnly — drives propose →
///            match → settle → execute using ONLY values reconstructed from the
///            emitted packed event payloads. Validates that the decoder + layout +
///            override semantics agree end-to-end.
///         2. testPermitIntent_ChangesOnMinOut — two proposals identical except for
///            minOut produce different witnesses.
///         3. testPermitIntent_StableAcrossRuntimeOverrides — two proposals where
///            only the contract's runtime overrides (expiration absolute,
///            startFulfillFeeIncrease) differ must produce the SAME witness, while
///            stored swap hash differs.
contract OpenSwapLogsAsPreimageTest is SlimTestBase {
    bytes32 internal constant SWAP_CREATED_SIG     = keccak256("SwapCreated(uint256,address,bytes)");
    bytes32 internal constant SWAP_MATCHED_SIG     = keccak256("SwapMatched(uint256,bytes)");
    bytes32 internal constant REPORT_SUBMITTED_SIG = keccak256("ReportSubmitted(uint256,bytes)");

    uint128 internal constant TEST_MIN_OUT = uint128(0x010203040506);
    uint128 internal constant TEST_AMOUNT2 = uint128(0x0a0b0c0d0e0f1011);

    function setUp() public {
        _setUpAll();
    }

    function _build()
        internal
        view
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        s.sellAmt              = 0.5 ether;
        s.minFulfillLiquidity  = 0.25 ether;
        s.settlerReward        = uint96(0.001 ether);
        s.maxGameTime          = MAX_GAME_TIME;
        s.blocksPerSecond      = 500;
        s.buyToken             = address(buyToken);
        s.matcherGasComp       = uint96(0.0005 ether);
        s.sellToken            = address(sellToken);
        s.swapper              = address(0);
        s.executorGasComp      = uint96(0.00025 ether);
        s.useInternalBalances  = false;
        s.expiration           = uint48(1 hours);
        s.priceTolerated       = 5e26;
        s.toleranceRange       = 1_000_000;

        m.initialLiquidity         = 1 ether;
        m.escalationHalt           = 20 ether;
        m.settlementTime           = 300;
        m.disputeDelay             = 5;
        m.protocolFee              = 0;
        m.multiplier               = 110;
        m.startFulfillFeeIncrease  = 0;
        m.maxFee                   = 10_000;
        m.startingFee              = 10_000;
        m.roundLength              = 60;
        m.growthRate               = 15_000;
        m.maxRounds                = 10;
    }

    function _findLogByTopic(Vm.Log[] memory logs, bytes32 sig)
        internal
        pure
        returns (Vm.Log memory)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == sig) return logs[i];
        }
        revert("log not found");
    }

    function testIntegration_FullLifecycle_FromPackedLogsOnly() public {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _build();
        uint256 eth = uint256(s.matcherGasComp) + uint256(s.executorGasComp) + uint256(s.settlerReward);

        // ── propose ──
        vm.recordLogs();
        vm.prank(swapper);
        uint256 swapId = swapContract.propose{value: eth}(s, m, _emptyPermit2(), TEST_MIN_OUT);
        Vm.Log memory swapCreatedLog = _findLogByTopic(vm.getRecordedLogs(), SWAP_CREATED_SIG);

        // Decode from log only → reconstruct ProposedSwap + MatcherPreimage for matchSwap.
        openSwapV2.ProposedSwap memory sFromLog = PackedDecoder.decodeProposedSwap(swapCreatedLog.data);
        openSwapV2.MatcherPreimage memory mFromLog = PackedDecoder.decodeMatcherPreimage(swapCreatedLog.data);

        // ── match using decoded values only ──
        vm.recordLogs();
        vm.prank(matcher);
        swapContract.matchSwap(swapId, TEST_AMOUNT2, sFromLog, mFromLog, IOpenOracle2.TimingBoundaries(0, 0, 0, 0));
        Vm.Log[] memory matchLogs = vm.getRecordedLogs();
        Vm.Log memory swapMatchedLog = _findLogByTopic(matchLogs, SWAP_MATCHED_SIG);
        Vm.Log memory reportSubmittedLog = _findLogByTopic(matchLogs, REPORT_SUBMITTED_SIG);

        // Decode the post-match struct + the oracle's OracleGame from logs only.
        openSwapV2.MatchedSwap memory matchedFromLog = PackedDecoder.decodeMatchedSwap(swapMatchedLog.data);
        uint256 reportIdFromLog = uint256(reportSubmittedLog.topics[1]);
        IOpenOracle2.OracleGame memory ogFromLog = PackedDecoder.decodeOracleGame(reportSubmittedLog.data);
        IOpenOracle2.PreimageHelper memory phFromLog =
            PackedDecoder.decodeHelperTail(reportSubmittedLog.data, reportIdFromLog);

        // ── settle using decoded OracleGame + helper ──
        vm.warp(block.timestamp + uint256(ogFromLog.settlementTime) + 1);
        vm.prank(settler);
        IOpenOracle2(address(oracle)).settle(reportIdFromLog, ogFromLog, phFromLog);

        // ── execute using decoded MatchedSwap + post-settle OracleGame ──
        IOpenOracle2.OracleGame memory ogSettled = ogFromLog;
        ogSettled.settlementTimestamp = uint48(block.timestamp);

        vm.prank(settler);
        swapContract.execute(swapId, matchedFromLog, ogSettled, phFromLog, false);

        // Post-lifecycle: swap hash deleted. Oracle hash remains (updated to the settled-state
        // hash, not zeroed — settle mutates settlementTimestamp and rehashes rather than deleting).
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap hash deleted after execute");
        assertTrue(oracle.oracleGame(reportIdFromLog) != bytes32(0), "oracle hash still present (post-settle state)");
    }

    function testPermitIntent_ChangesOnMinOut() public {
        MockPermit2 mockP2 = MockPermit2(PERMIT2);

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _build();
        uint256 eth = uint256(s.matcherGasComp) + uint256(s.executorGasComp) + uint256(s.settlerReward);

        // Propose A with minOut = X.
        vm.prank(swapper);
        swapContract.propose{value: eth}(s, m, _emptyPermit2(), uint128(0x010203040506));
        bytes32 witnessA = mockP2.lastWitness();

        // Propose B with minOut = Y, otherwise identical signed inputs.
        vm.prank(swapper);
        swapContract.propose{value: eth}(s, m, _emptyPermit2(), uint128(0xfffefdfcfbfa));
        bytes32 witnessB = mockP2.lastWitness();

        assertTrue(witnessA != bytes32(0), "witnessA must be set");
        assertTrue(witnessA != witnessB, "witness must change when minOut changes");
    }

    function testPermitIntent_StableAcrossRuntimeOverrides() public {
        MockPermit2 mockP2 = MockPermit2(PERMIT2);

        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _build();
        uint256 eth = uint256(s.matcherGasComp) + uint256(s.executorGasComp) + uint256(s.settlerReward);

        // Propose A.
        vm.prank(swapper);
        uint256 swapIdA = swapContract.propose{value: eth}(s, m, _emptyPermit2(), TEST_MIN_OUT);
        bytes32 witnessA = mockP2.lastWitness();
        bytes32 hashA = swapContract.swaps(swapIdA);

        // Move block.timestamp forward — this changes the runtime overrides (absolute
        // expiration and startFulfillFeeIncrease) WITHOUT changing any signed input.
        vm.warp(block.timestamp + 3600);

        // Propose B with identical user-signed inputs.
        vm.prank(swapper);
        uint256 swapIdB = swapContract.propose{value: eth}(s, m, _emptyPermit2(), TEST_MIN_OUT);
        bytes32 witnessB = mockP2.lastWitness();
        bytes32 hashB = swapContract.swaps(swapIdB);

        // Witness identical (permitIntent excludes timestamp-derived overrides).
        assertEq(witnessA, witnessB, "permit witness must NOT change across runtime overrides");
        // Stored swap hash differs (it includes the overrides).
        assertTrue(hashA != hashB, "stored swap hash must differ across runtime overrides");
    }
}
