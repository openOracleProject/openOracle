// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
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
        openSwapV2.OracleParams memory op = _defaultOracleParams();
        openSwapV2.SlippageParams memory slip = _defaultSlippage();
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();

        bytes32 intent = keccak256(
            abi.encode(
                MIN_OUT,
                address(buyToken),
                MIN_FULFILL_LIQUIDITY,
                uint48(1 hours),
                MATCHER_GAS_COMP,
                EXECUTOR_GAS_COMP,
                op,
                slip,
                ff,
                useInternalBalances
            )
        );

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
