// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";
import "../utils/MockPermit2.sol";

/// @notice Coverage for the propose guards introduced with the assembly-hash refactor:
///   1. Override slots (s.swapper, m.startFulfillFeeIncrease) must be zero on input.
///   2. The Permit2 witness binds the user to runtime-independent inputs (permitIntent),
///      so the same signed inputs proposed at different timestamps yield identical witnesses
///      but distinct stored swapHashes.
contract OpenSwapProposeGuardsTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    /// @dev Build ProposedSwap / MatcherPreimage from defaults, mirroring SwapCompat.proposeRaw,
    ///      but exposed here so we can poison one slot at a time.
    function _buildInputs(uint48 expirationOffset, bool useInternalBalances)
        internal
        view
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        SwapCompat.SlippageParams memory slip = _defaultSlippage();
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();

        s.sellAmt = SELL_AMT;
        s.minFulfillLiquidity = MIN_FULFILL_LIQUIDITY;
        s.settlerReward = op.settlerReward;
        s.maxGameTime = op.maxGameTime;
        s.blocksPerSecond = op.blocksPerSecond;
        s.buyToken = address(buyToken);
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.sellToken = address(sellToken);
        s.executorGasComp = EXECUTOR_GAS_COMP;
        s.useInternalBalances = useInternalBalances;
        s.expiration = expirationOffset;
        s.priceTolerated = slip.priceTolerated;
        s.toleranceRange = slip.toleranceRange;

        m.initialLiquidity = op.initialLiquidity;
        m.escalationHalt = op.escalationHalt;
        m.settlementTime = op.settlementTime;
        m.disputeDelay = op.disputeDelay;
        m.protocolFee = op.protocolFee;
        m.multiplier = op.multiplier;
        m.maxFee = ff.maxFee;
        m.startingFee = ff.startingFee;
        m.roundLength = ff.roundLength;
        m.growthRate = ff.growthRate;
        m.maxRounds = ff.maxRounds;
    }

    function testPropose_RevertsDirtySwapper() public {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildInputs(uint48(1 hours), false);
        s.swapper = address(0xBEEF); // poison the override slot

        uint256 eth = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        vm.prank(swapper);
        vm.expectRevert(Errors.MustBeZero.selector);
        swapContract.propose{value: eth}(s, m, _emptyPermit2(), MIN_OUT);
    }

    function testPropose_RevertsDirtyStartFulfillFeeIncrease() public {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildInputs(uint48(1 hours), false);
        m.startFulfillFeeIncrease = uint48(1234); // poison the override slot

        uint256 eth = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        vm.prank(swapper);
        vm.expectRevert(Errors.MustBeZero.selector);
        swapContract.propose{value: eth}(s, m, _emptyPermit2(), MIN_OUT);
    }

    /// @notice The whole point of computing permitIntent before the timestamp overrides:
    ///         a user-signed Permit2 sig stays valid regardless of when the tx lands.
    ///         Same raw inputs → same permitIntent → same witness. The stored swapHash
    ///         differs because it commits to the canonical (msg.sender, absolute expiration,
    ///         block.timestamp-of-propose) which are runtime-derived.
    function testPropose_WitnessStableAcrossTimestamps() public {
        // First propose at T0.
        (uint256 swapId1,) = _propose();
        bytes32 witness1 = MockPermit2(PERMIT2).lastWitness();
        bytes32 swapHash1 = swapContract.swaps(swapId1);

        // Warp far enough that absolute expiration + startFulfillFeeIncrease shift.
        vm.warp(block.timestamp + 100 seconds);
        vm.roll(block.number + 50);

        // Second propose, same swapper, same defaults — same caller-signed inputs.
        (uint256 swapId2,) = _propose();
        bytes32 witness2 = MockPermit2(PERMIT2).lastWitness();
        bytes32 swapHash2 = swapContract.swaps(swapId2);

        // The Permit2 witness depends only on runtime-independent inputs → must match.
        assertEq(witness1, witness2, "witness must be stable across timestamps");
        // Stored swapHash bakes in the runtime overrides → must differ.
        assertTrue(swapHash1 != swapHash2, "swapHash must change with timestamp");
        // Confirm the swap was actually created at different IDs.
        assertEq(swapId2, swapId1 + 1, "next-swap-id incremented");
    }
}
