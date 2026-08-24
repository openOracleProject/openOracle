// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice Branch-by-branch coverage of `propose()` validation, each with its accepted
 *         boundary and its first rejected value.
 *
 * @dev Accepted cases are real proposals that store a real hash. Rejected cases assert the
 *      call reverted with the exact error and that nothing moved: nextSwapId, the swap slot,
 *      OpenPunt's ETH, OpenPunt's internal collateral, the swapper's collateral, and the
 *      Permit2 call count are all re-checked. Since every validation branch precedes the
 *      funding block, a rejection must never reach Permit2.
 */
contract ProposeValidationTest is OpenPuntBase {
    function setUp() public {
        _setUpAll();
        // headroom for the many real proposals below, minted through the token's own mint()
        collat.mint(swapper, type(uint128).max);
    }

    // ── harness ─────────────────────────────────────────────────────────

    function _s() internal view returns (OpenPuntStorage.ProposedSwap memory) {
        return _defaultProposedSwap();
    }

    function _m() internal view returns (OpenPuntStorage.MatcherPreimage memory) {
        return _defaultMatcherPreimage();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Margin
    // ══════════════════════════════════════════════════════════════════

    function test_margin_maintenanceBelowInitialAccepted() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.maintenanceMarginSwapper = s.initialMarginSwapper - 1;
        // buffer of 1 wei needs a fee ceiling below it, so shrink the notional accordingly
        s.notional = 1;
        _proposeOk(s, _m(), "maintenance = initial - 1");
    }

    function test_margin_maintenanceEqualInitialRejects() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.maintenanceMarginSwapper = s.initialMarginSwapper;
        _proposeBad(s, _m(), PuntErrors.InvalidMargin.selector, "maintenance == initial");
    }

    function test_margin_maintenanceAboveInitialRejects() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.maintenanceMarginSwapper = s.initialMarginSwapper + 1;
        _proposeBad(s, _m(), PuntErrors.InvalidMargin.selector, "maintenance > initial");
    }

    function test_margin_sumAtUint128MaxAccepted() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.initialMarginMatcher = 1;
        s.initialMarginSwapper = type(uint128).max - 1; // sum == uint128.max exactly
        s.maintenanceMarginSwapper = 0;
        s.notional = 1e7; // fee ceiling = auctionEnd = 20_000, far below the buffer

        collat.mint(swapper, s.initialMarginSwapper);
        _proposeOk(s, _m(), "margin sum == uint128.max");
    }

    function test_margin_sumOneAboveUint128MaxRejects() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.initialMarginMatcher = 2;
        s.initialMarginSwapper = type(uint128).max - 1; // sum == uint128.max + 1
        s.maintenanceMarginSwapper = 0;
        s.notional = 1e7;
        _proposeBad(s, _m(), PuntErrors.InvalidMargin.selector, "margin sum == uint128.max + 1");
    }

    /// @dev A zero swapper margin can only be reached with maintenance == 0, which trips the
    ///      ordering check first. The `initialMarginSwapper == 0` arm of the ZeroAmount check
    ///      is therefore unreachable through propose.
    function test_margin_zeroSwapperMarginRejectsAsInvalidMargin() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.initialMarginSwapper = 0;
        s.maintenanceMarginSwapper = 0;
        _proposeBad(s, _m(), PuntErrors.InvalidMargin.selector, "zero swapper margin");
    }

    function test_margin_zeroMatcherMarginRejects() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.initialMarginMatcher = 0;
        _proposeBad(s, _m(), PuntErrors.ZeroAmount.selector, "zero matcher margin");
    }

    function test_margin_zeroNotionalRejects() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.notional = 0;
        _proposeBad(s, _m(), PuntErrors.ZeroAmount.selector, "zero notional");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Assets and timing
    // ══════════════════════════════════════════════════════════════════

    function test_assets_identicalOracleTokensReject() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.oracleToken2 = s.oracleToken1;
        _proposeBad(s, _m(), PuntErrors.TokensCannotBeSame.selector, "identical oracle tokens");
    }

    function test_expiration_boundaries() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.expiration = 1;
        _proposeOk(s, _m(), "expiration 1");

        s = _s();
        s.expiration = 30 days;
        _proposeOk(s, _m(), "expiration 30 days");

        s = _s();
        s.expiration = 0;
        _proposeBad(s, _m(), PuntErrors.InvalidExpiration.selector, "expiration 0");

        s = _s();
        s.expiration = 30 days + 1;
        _proposeBad(s, _m(), PuntErrors.InvalidExpiration.selector, "expiration 30 days + 1");
    }

    function test_maturityWindow_boundaries() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.maturityWindow = 1;
        _proposeOk(s, _m(), "maturity 1");

        s = _s();
        s.maturityWindow = 30 days;
        _proposeOk(s, _m(), "maturity 30 days");

        s = _s();
        s.maturityWindow = 0;
        _proposeBad(s, _m(), PuntErrors.InvalidMaturity.selector, "maturity 0");

        s = _s();
        s.maturityWindow = 30 days + 1;
        _proposeBad(s, _m(), PuntErrors.InvalidMaturity.selector, "maturity 30 days + 1");
    }

    function test_maxExecutionLatency_boundaries() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.maxExecutionLatency = 0; // disabled
        _proposeOk(s, _m(), "latency 0");

        s = _s();
        s.maxExecutionLatency = 60;
        _proposeOk(s, _m(), "latency 60");

        s = _s();
        s.maxExecutionLatency = 3600;
        _proposeOk(s, _m(), "latency 3600");

        s = _s();
        s.maxExecutionLatency = 59;
        _proposeBad(s, _m(), PuntErrors.InvalidExecutionLatency.selector, "latency 59");

        s = _s();
        s.maxExecutionLatency = 3601;
        _proposeBad(s, _m(), PuntErrors.InvalidExecutionLatency.selector, "latency 3601");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Liquidation heartbeat
    // ══════════════════════════════════════════════════════════════════

    function test_heartbeat_acceptedConfigurations() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        (s.liquidationHeartbeatMin, s.liquidationHeartbeatMax) = (0, 0);
        _proposeOk(s, _m(), "heartbeat disabled");

        s = _s();
        (s.liquidationHeartbeatMin, s.liquidationHeartbeatMax) = (30, 300);
        _proposeOk(s, _m(), "heartbeat min 30 / max 300");

        s = _s();
        (s.liquidationHeartbeatMin, s.liquidationHeartbeatMax) = (30, 31);
        _proposeOk(s, _m(), "heartbeat max just above min");
    }

    function test_heartbeat_rejectedConfigurations() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        (s.liquidationHeartbeatMin, s.liquidationHeartbeatMax) = (0, 300);
        _proposeBad(s, _m(), PuntErrors.InvalidLiquidationHeartbeat.selector, "min zero, max set");

        s = _s();
        (s.liquidationHeartbeatMin, s.liquidationHeartbeatMax) = (30, 0);
        _proposeBad(s, _m(), PuntErrors.InvalidLiquidationHeartbeat.selector, "min set, max zero");

        s = _s();
        (s.liquidationHeartbeatMin, s.liquidationHeartbeatMax) = (29, 300);
        _proposeBad(s, _m(), PuntErrors.InvalidLiquidationHeartbeat.selector, "min 29");

        s = _s();
        (s.liquidationHeartbeatMin, s.liquidationHeartbeatMax) = (30, 301);
        _proposeBad(s, _m(), PuntErrors.InvalidLiquidationHeartbeat.selector, "max 301");

        s = _s();
        (s.liquidationHeartbeatMin, s.liquidationHeartbeatMax) = (30, 30);
        _proposeBad(s, _m(), PuntErrors.InvalidLiquidationHeartbeat.selector, "min == max");

        s = _s();
        (s.liquidationHeartbeatMin, s.liquidationHeartbeatMax) = (100, 50);
        _proposeBad(s, _m(), PuntErrors.InvalidLiquidationHeartbeat.selector, "max < min");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Price protection
    // ══════════════════════════════════════════════════════════════════

    function test_priceProtection_boundaries() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.priceTolerated = 1;
        _proposeOk(s, _m(), "priceTolerated 1");

        s = _s();
        s.priceTolerated = 0;
        _proposeBad(s, _m(), PuntErrors.InvalidSlippage.selector, "priceTolerated 0");

        s = _s();
        s.toleranceRange = 1;
        _proposeOk(s, _m(), "toleranceRange 1");

        s = _s();
        s.toleranceRange = 1e7;
        _proposeOk(s, _m(), "toleranceRange 1e7");

        s = _s();
        s.toleranceRange = 0;
        _proposeBad(s, _m(), PuntErrors.InvalidSlippage.selector, "toleranceRange 0");

        s = _s();
        s.toleranceRange = 1e7 + 1;
        _proposeBad(s, _m(), PuntErrors.InvalidSlippage.selector, "toleranceRange 1e7 + 1");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Oracle parameters
    // ══════════════════════════════════════════════════════════════════

    function test_settlementTime_boundaries() public {
        OpenPuntStorage.MatcherPreimage memory m = _m();
        OpenPuntStorage.ProposedSwap memory s = _s();
        m.settlementTime = 1;
        m.disputeDelay = 0; // must stay strictly below settlementTime
        _proposeOk(s, m, "settlementTime 1");

        // The 4-hour ceiling is on settlementTime * millisecondsPerBlock, so in block units the
        // boundary is 14_400_000 ms / 2_000 ms-per-block = 7_200 blocks. The required game time is
        // 20x the settlement duration in seconds: 14_400 * 20 = 288_000, within the 604_800 cap.
        m = _m();
        s = _s();
        m.settlementTime = 7200;
        s.maxGameTime = 288_000;
        _proposeOk(s, m, "settlementTime 7200 blocks == exactly 4 hours");

        m = _m();
        m.settlementTime = 0;
        _proposeBad(_s(), m, PuntErrors.InvalidOracleParams.selector, "settlementTime 0");

        m = _m();
        s = _s();
        m.settlementTime = 7201;
        s.maxGameTime = 288_040;
        _proposeBad(s, m, PuntErrors.InvalidOracleParams.selector, "settlementTime 7201 blocks exceeds 4 hours");
    }

    function test_initialLiquidityAndMillisecondsPerBlock_boundaries() public {
        OpenPuntStorage.MatcherPreimage memory m = _m();
        m.initialLiquidity = 1;
        _proposeOk(_s(), m, "initialLiquidity 1");

        m = _m();
        m.initialLiquidity = 0;
        _proposeBad(_s(), m, PuntErrors.InvalidOracleParams.selector, "initialLiquidity 0");

        OpenPuntStorage.ProposedSwap memory s = _s();
        s.millisecondsPerBlock = 1;
        _proposeOk(s, _m(), "millisecondsPerBlock 1");

        s = _s();
        s.millisecondsPerBlock = 0;
        _proposeBad(s, _m(), PuntErrors.InvalidOracleParams.selector, "millisecondsPerBlock 0");
    }

    function test_disputeDelay_boundaries() public {
        OpenPuntStorage.MatcherPreimage memory m = _m();
        m.disputeDelay = 0;
        _proposeOk(_s(), m, "disputeDelay 0");

        m = _m();
        m.disputeDelay = uint24(SETTLEMENT_BLOCKS) - 1;
        _proposeOk(_s(), m, "disputeDelay settlementTime - 1");

        m = _m();
        m.disputeDelay = uint24(SETTLEMENT_BLOCKS);
        _proposeBad(_s(), m, PuntErrors.InvalidOracleParams.selector, "disputeDelay == settlementTime");

        m = _m();
        m.disputeDelay = uint24(SETTLEMENT_BLOCKS) + 1;
        _proposeBad(_s(), m, PuntErrors.InvalidOracleParams.selector, "disputeDelay > settlementTime");
    }

    function test_escalationHaltAndProtocolFee_boundaries() public {
        OpenPuntStorage.MatcherPreimage memory m = _m();
        m.escalationHalt = m.initialLiquidity;
        _proposeOk(_s(), m, "escalationHalt == initialLiquidity");

        m = _m();
        m.escalationHalt = m.initialLiquidity - 1;
        _proposeBad(_s(), m, PuntErrors.InvalidOracleParams.selector, "escalationHalt < initialLiquidity");

        m = _m();
        m.protocolFee = 1e7 - 1;
        _proposeOk(_s(), m, "protocolFee 1e7 - 1");

        m = _m();
        m.protocolFee = 1e7;
        _proposeBad(_s(), m, PuntErrors.InvalidOracleParams.selector, "protocolFee 1e7");
    }

    function test_maxGameTime_boundaries() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        // The floor is 20x the settlement duration in seconds, not 20x the block count.
        s.maxGameTime = uint24(SETTLEMENT_SECONDS) * 20; // exact floor
        _proposeOk(s, _m(), "maxGameTime == settlementDurationSeconds * 20");

        s = _s();
        s.maxGameTime = uint24(SETTLEMENT_SECONDS) * 20 - 1;
        _proposeBad(s, _m(), PuntErrors.InvalidOracleParams.selector, "maxGameTime one below floor");

        s = _s();
        s.maxGameTime = 604800;
        _proposeOk(s, _m(), "maxGameTime 604800");

        s = _s();
        s.maxGameTime = 604801;
        _proposeBad(s, _m(), PuntErrors.InvalidOracleParams.selector, "maxGameTime 604801");
    }

    function test_multiplier_boundaries() public {
        OpenPuntStorage.MatcherPreimage memory m = _m();
        m.multiplier = 100;
        _proposeOk(_s(), m, "multiplier 100");

        m = _m();
        m.multiplier = 99;
        _proposeBad(_s(), m, PuntErrors.InvalidOracleParams.selector, "multiplier 99");
    }

    function test_auctionRoundParameters_boundaries() public {
        OpenPuntStorage.MatcherPreimage memory m = _m();
        m.maxRounds = 1;
        _proposeOk(_s(), m, "maxRounds 1");

        m = _m();
        m.maxRounds = 200;
        _proposeOk(_s(), m, "maxRounds 200");

        m = _m();
        m.maxRounds = 0;
        _proposeBad(_s(), m, PuntErrors.InvalidFulfillFeeParams.selector, "maxRounds 0");

        m = _m();
        m.maxRounds = 201;
        _proposeBad(_s(), m, PuntErrors.InvalidFulfillFeeParams.selector, "maxRounds 201");

        m = _m();
        m.roundLength = 0;
        _proposeBad(_s(), m, PuntErrors.InvalidFulfillFeeParams.selector, "roundLength 0");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Runtime-override inputs must be zero
    // ══════════════════════════════════════════════════════════════════

    function test_overrides_nonZeroSwapperRejects() public {
        OpenPuntStorage.ProposedSwap memory s = _s();
        s.swapper = swapper;
        _proposeBad(s, _m(), PuntErrors.MustBeZero.selector, "swapper preset");

        s = _s();
        s.swapper = outsider;
        _proposeBad(s, _m(), PuntErrors.MustBeZero.selector, "swapper preset to a third party");
    }

    function test_overrides_nonZeroStartFulfillFeeIncreaseRejects() public {
        OpenPuntStorage.MatcherPreimage memory m = _m();
        m.startFulfillFeeIncrease = 1;
        _proposeBad(_s(), m, PuntErrors.MustBeZero.selector, "startFulfillFeeIncrease preset");

        m = _m();
        m.startFulfillFeeIncrease = uint48(vm.getBlockTimestamp());
        _proposeBad(_s(), m, PuntErrors.MustBeZero.selector, "startFulfillFeeIncrease preset to now");
    }
}
