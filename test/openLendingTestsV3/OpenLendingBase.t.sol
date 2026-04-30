// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/openLendV3.sol";
import "../../src/OpenOracle.sol";
import "../utils/MockERC20.sol";
import "../utils/MockWETH.sol";

abstract contract OpenLendingBaseTest is Test {
    openLend internal lending;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken;
    MockERC20 internal borrowToken;
    MockWETH internal weth;

    // ---------------- deployment ----------------

    function _deployCore(
        string memory supplyName,
        string memory supplySymbol,
        string memory borrowName,
        string memory borrowSymbol
    ) internal {
        oracle = new OpenOracle();
        weth = new MockWETH();
        lending = new openLend(IOpenOracle(address(oracle)), address(weth));
        supplyToken = new MockERC20(supplyName, supplySymbol);
        borrowToken = new MockERC20(borrowName, borrowSymbol);
    }

    // ---------------- funding / approvals ----------------

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

    // ---------------- standard parameter sets ----------------

    function _standardOracleParams() internal pure returns (openLend.OracleParams memory) {
        return openLend.OracleParams({
            settlementTime: 300,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 100,
            initialLiquidity: 10,
            multiplier: 200
        });
    }

    function _standardInterestRateParams() internal pure returns (openLend.InterestRateParams memory) {
        return openLend.InterestRateParams({
            maxRate: 1e9,        // 100% APR ceiling
            startingRate: 1e8,   // 10% APR
            roundLength: 300,    // 5 min per round
            growthRate: 10500,   // 1.05x per round
            maxRounds: 100
        });
    }

    // ---------------- lifecycle helpers ----------------

    /// @dev Borrower opens a borrow request with standard oracle + rate params, full-term commitment, no gasComp.
    function _requestBorrow(
        address borrower,
        uint128 supplyAmount,
        uint128 amountDemanded,
        uint48 term
    ) internal returns (uint256 lendingId) {
        return _requestBorrowFlex(borrower, supplyAmount, amountDemanded, term, 1e7, 0);
    }

    /// @dev Borrower opens a borrow request with explicit commitmentFraction + gasCompensation knobs.
    function _requestBorrowFlex(
        address borrower,
        uint128 supplyAmount,
        uint128 amountDemanded,
        uint48 term,
        uint24 commitmentFraction,
        uint96 gasCompensation
    ) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow{value: gasCompensation}(
            term,
            address(supplyToken),
            address(borrowToken),
            8e6,                 // 80% liquidation threshold
            supplyAmount,
            amountDemanded,
            100,                 // 1% liquidator stake
            commitmentFraction,
            gasCompensation,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    /// @dev Empty OracleParams struct used as the "keep current" sentinel on refinance.
    function _zeroOracleParams() internal pure returns (openLend.OracleParams memory) {
        return openLend.OracleParams({
            settlementTime: 0,
            disputeDelay: 0,
            oracleGameFee: 0,
            escalationFactor: 0,
            initialLiquidity: 0,
            multiplier: 0
        });
    }

    /// @dev Lender accepts the current rate on the curve. Skips paramHash and rate floor for simple test paths.
    function _lend(address lender, uint256 lendingId) internal {
        vm.prank(lender);
        lending.lend(
            lendingId,
            bytes32(0),          // skip paramHash
            0,                   // minLendAmount (refi-only, ignored on origination)
            type(uint128).max,   // maxLendAmount (refi-only, ignored on origination)
            0,                   // expectedMinSupply
            0,                   // minRate floor
            false                // allowAnyLiquidator
        );
    }

    /// @dev Convenience: requestBorrow + lend in one call. Returns the resulting lendingId.
    function _originateLoan(
        address borrower,
        address lender,
        uint128 supplyAmount,
        uint128 amountDemanded,
        uint48 term
    ) internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, supplyAmount, amountDemanded, term);
        _lend(lender, lendingId);
    }

    // ---------------- math helpers ----------------

    function _calculateOwedAtMaturity(uint256 principal, uint32 rate, uint48 term) internal pure returns (uint128) {
        uint256 year = 365 days;
        uint256 interest = (principal * uint256(term) * uint256(rate)) / (1e9 * year);
        return uint128(principal + interest);
    }
}
