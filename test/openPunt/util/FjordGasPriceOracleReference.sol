// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @notice Deterministic implementation of the OP Stack Fjord
 *         `getL1FeeUpperBound(uint256)` calculation used by Base.
 *
 * @dev This is not a constant-return mock. The constants and arithmetic mirror the production
 *      GasPriceOracle implementation, while the four L1Block inputs remain configurable so tests
 *      can exercise changing L1-data costs without forking Base.
 */
contract FjordGasPriceOracleReference {
    int256 internal constant COST_INTERCEPT = -42_585_600;
    uint256 internal constant COST_FASTLZ_COEF = 836_500;
    uint256 internal constant MIN_TRANSACTION_SIZE_SCALED = 100 * 1e6;
    uint256 internal constant FEE_DENOMINATOR = 1e12;

    uint256 public l1BaseFee;
    uint256 public blobBaseFee;
    uint32 public baseFeeScalar;
    uint32 public blobBaseFeeScalar;

    function setFeeParameters(
        uint256 l1BaseFee_,
        uint256 blobBaseFee_,
        uint32 baseFeeScalar_,
        uint32 blobBaseFeeScalar_
    ) external {
        l1BaseFee = l1BaseFee_;
        blobBaseFee = blobBaseFee_;
        baseFeeScalar = baseFeeScalar_;
        blobBaseFeeScalar = blobBaseFeeScalar_;
    }

    function getL1FeeUpperBound(uint256 unsignedTxSize) external view returns (uint256) {
        // Production adds 68 bytes for the fields absent from an unsigned transaction, then uses
        // this practical FastLZ upper bound before applying the Fjord Brotli regression.
        uint256 txSize = unsignedTxSize + 68;
        uint256 flzUpperBound = txSize + txSize / 255 + 16;

        int256 estimatedSizeSigned = COST_INTERCEPT + int256(COST_FASTLZ_COEF * flzUpperBound);
        uint256 estimatedSize = estimatedSizeSigned < int256(MIN_TRANSACTION_SIZE_SCALED)
            ? MIN_TRANSACTION_SIZE_SCALED
            : uint256(estimatedSizeSigned);

        uint256 feeScaled = uint256(baseFeeScalar) * 16 * l1BaseFee + uint256(blobBaseFeeScalar) * blobBaseFee;
        return estimatedSize * feeScaled / FEE_DENOMINATOR;
    }
}
