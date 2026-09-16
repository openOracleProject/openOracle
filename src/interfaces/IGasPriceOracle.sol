// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IGasPriceOracle {
    function getL1FeeUpperBound(uint256 unsignedTxSize)
        external view returns (uint256);
}
