// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/openLendV2.sol";
import "../../src/OpenOracle.sol";
import "../utils/MockERC20.sol";

abstract contract OpenLendingBaseTest is Test {
    openLending internal lending;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken;
    MockERC20 internal borrowToken;

    function _deployCore(
        string memory supplyName,
        string memory supplySymbol,
        string memory borrowName,
        string memory borrowSymbol
    ) internal {
        oracle = new OpenOracle();
        lending = new openLending(IOpenOracle(address(oracle)));
        supplyToken = new MockERC20(supplyName, supplySymbol);
        borrowToken = new MockERC20(borrowName, borrowSymbol);
    }

    function _fundSupply(address[] memory accounts, uint256 amount) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            supplyToken.transfer(accounts[i], amount);
        }
    }

    function _fundBorrow(address[] memory accounts, uint256 amount) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            borrowToken.transfer(accounts[i], amount);
        }
    }

    function _dealETH(address[] memory accounts, uint256 amount) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            vm.deal(accounts[i], amount);
        }
    }

    function _approveLendingSupply(address account) internal {
        vm.prank(account);
        supplyToken.approve(address(lending), type(uint256).max);
    }

    function _approveLendingBorrow(address account) internal {
        vm.prank(account);
        borrowToken.approve(address(lending), type(uint256).max);
    }

    function _approveLendingBoth(address account) internal {
        _approveLendingSupply(account);
        _approveLendingBorrow(account);
    }

    function _approveOracleBoth(address account) internal {
        vm.prank(account);
        supplyToken.approve(address(oracle), type(uint256).max);
        vm.prank(account);
        borrowToken.approve(address(oracle), type(uint256).max);
    }

    function _seedUnrelated(uint256 unrelatedSupply, uint256 unrelatedBorrow) internal {
        supplyToken.transfer(address(lending), unrelatedSupply);
        borrowToken.transfer(address(lending), unrelatedBorrow);
    }

    function _standardOracleParams() internal pure returns (openLending.OracleParams memory) {
        return openLending.OracleParams(300, 60, 100_000, 100, 10, 200);
    }

    function _calculateOwedAtMaturity(uint256 principal, uint32 rate, uint48 term) internal pure returns (uint128) {
        uint256 year = 365 days;
        uint256 interest = (principal * uint256(term) * uint256(rate)) / (1e9 * year);
        return uint128(principal + interest);
    }
}
