// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";
import "../utils/MockPermit2.sol";

/// @notice Lock down that useInternalBalances is part of the Permit2 witness binding.
///         openSwap's `intent` hash includes useInternalBalances, and the oracle wraps
///         that intent into a typed witness passed to Permit2. If a relayer reused the
///         same Permit2 signature with the opposite useInternalBalances flag, the
///         oracle would still compute a witness with the flag baked in — so the
///         resulting witness differs and the signature would not verify on real Permit2.
contract OpenSwapPermit2WitnessTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    function _expectedWitness(bool useInternalBalances) internal view returns (bytes32) {
        // Build the ProposedSwap and MatcherPreimage exactly as the contract's assembly does
        // when computing permitIntent:
        //   - s with swapper = msg.sender (this test's `swapper` EOA), expiration = raw offset
        //   - m with startFulfillFeeIncrease = 0
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        SwapCompat.SlippageParams memory slip = _defaultSlippage();
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();

        openSwapV2.ProposedSwap memory s;
        s.sellAmt = SELL_AMT;
        s.minFulfillLiquidity = MIN_FULFILL_LIQUIDITY;
        s.settlerReward = op.settlerReward;
        s.maxGameTime = op.maxGameTime;
        s.blocksPerSecond = op.blocksPerSecond;
        s.buyToken = address(buyToken);
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.sellToken = address(sellToken);
        s.swapper = swapper; // contract-overridden to msg.sender
        s.executorGasComp = EXECUTOR_GAS_COMP;
        s.useInternalBalances = useInternalBalances;
        s.expiration = uint48(1 hours); // raw offset; NOT the absolute-time override
        s.priceTolerated = slip.priceTolerated;
        s.toleranceRange = slip.toleranceRange;

        openSwapV2.MatcherPreimage memory m;
        m.initialLiquidity = op.initialLiquidity;
        m.escalationHalt = op.escalationHalt;
        m.settlementTime = op.settlementTime;
        m.disputeDelay = op.disputeDelay;
        m.protocolFee = op.protocolFee;
        m.multiplier = op.multiplier;
        // m.startFulfillFeeIncrease = 0 (caller-signed value, contract-overridden after hash)
        m.maxFee = ff.maxFee;
        m.startingFee = ff.startingFee;
        m.roundLength = ff.roundLength;
        m.growthRate = ff.growthRate;
        m.maxRounds = ff.maxRounds;

        bytes32 intent = keccak256(abi.encode(s, m, MIN_OUT));

        bytes32 WITNESS_TYPEHASH = keccak256(
            "Witness(address beneficiary,address relayer,address swapper,bytes32 intent)"
        );
        // beneficiary = openSwap (where funds land); relayer = oracle's msg.sender = openSwap; swapper = swapper.
        return keccak256(abi.encode(WITNESS_TYPEHASH, address(swapContract), address(swapContract), swapper, intent));
    }

    function testPermit2_WitnessIncludesUseInternalBalancesFlag() public {
        // Run external-mode propose; MockPermit2 captures the witness it was called with.
        (uint256 swapId,) = _propose();
        swapId; // silence
        bytes32 captured = MockPermit2(PERMIT2).lastWitness();
        bytes32 expectedFalse = _expectedWitness(false);
        bytes32 expectedTrue = _expectedWitness(true);

        assertEq(captured, expectedFalse, "witness matches useInternalBalances=false intent");
        assertTrue(captured != expectedTrue, "witness differs when flag flipped");
    }

    function testPermit2_WitnessTypeStringRecorded() public {
        _propose();
        string memory expected = "Witness witness)TokenPermissions(address token,uint256 amount)Witness(address beneficiary,address relayer,address swapper,bytes32 intent)";
        assertEq(MockPermit2(PERMIT2).lastWitnessTypeString(), expected, "witness type string");
    }
}
