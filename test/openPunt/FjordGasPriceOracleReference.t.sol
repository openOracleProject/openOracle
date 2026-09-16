// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {FjordGasPriceOracleReference} from "./util/FjordGasPriceOracleReference.sol";

/**
 * @notice Golden-vector and behavior checks for the local Fjord implementation used by OpenPunt
 *         tests in place of Base's predeploy.
 */
contract FjordGasPriceOracleReferenceTest is Test {
    // All values were read at Base block 51,288,793. The expected result was read independently
    // from 0x420000000000000000000000000000000000000F at that same block.
    uint256 internal constant L1_BASE_FEE = 55_429_468;
    uint256 internal constant BLOB_BASE_FEE = 2_977_470;
    uint32 internal constant BASE_FEE_SCALAR = 2_269;
    uint32 internal constant BLOB_BASE_FEE_SCALAR = 1_055_762;
    uint256 internal constant EXPECTED_SIZE_320_FEE = 1_527_135_261;

    FjordGasPriceOracleReference internal oracleReference;

    function setUp() public {
        oracleReference = new FjordGasPriceOracleReference();
        oracleReference.setFeeParameters(L1_BASE_FEE, BLOB_BASE_FEE, BASE_FEE_SCALAR, BLOB_BASE_FEE_SCALAR);
    }

    function test_size320MatchesPinnedBasePredeploy() public view {
        assertEq(oracleReference.getL1FeeUpperBound(320), EXPECTED_SIZE_320_FEE);
    }

    function test_feeRespondsToEveryInputAndTransactionSize() public {
        uint256 baseline = oracleReference.getL1FeeUpperBound(320);
        assertGt(oracleReference.getL1FeeUpperBound(321), baseline, "size is part of the calculation");

        oracleReference.setFeeParameters(L1_BASE_FEE + 1, BLOB_BASE_FEE, BASE_FEE_SCALAR, BLOB_BASE_FEE_SCALAR);
        assertGt(oracleReference.getL1FeeUpperBound(320), baseline, "L1 base fee is part of the calculation");

        oracleReference.setFeeParameters(L1_BASE_FEE, BLOB_BASE_FEE + 1, BASE_FEE_SCALAR, BLOB_BASE_FEE_SCALAR);
        assertGt(oracleReference.getL1FeeUpperBound(320), baseline, "blob base fee is part of the calculation");

        oracleReference.setFeeParameters(L1_BASE_FEE, BLOB_BASE_FEE, BASE_FEE_SCALAR + 1, BLOB_BASE_FEE_SCALAR);
        assertGt(oracleReference.getL1FeeUpperBound(320), baseline, "base-fee scalar is part of the calculation");

        oracleReference.setFeeParameters(L1_BASE_FEE, BLOB_BASE_FEE, BASE_FEE_SCALAR, BLOB_BASE_FEE_SCALAR + 1);
        assertGt(oracleReference.getL1FeeUpperBound(320), baseline, "blob-fee scalar is part of the calculation");
    }
}
