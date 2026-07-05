// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/lend/openLend.sol";
import "../../src/lend/openLendDataProvider.sol";
import "../../src/lend/openLendFeeReceiver.sol";
import "../../src/OpenOracleSlim.sol";
import "../../src/interfaces/IOpenOracle2.sol";
import "../utils/MockERC20.sol";
import "../utils/MockWETH.sol";
import {LibClone} from "solady/utils/LibClone.sol";

abstract contract OpenLendingBaseTest is Test {
    openLend internal lending;
    openLendDataProvider internal lendView;
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
        lending = new openLend(IOpenOracle2(address(oracle)), address(weth));
        lendView = new openLendDataProvider(lending, IOpenOracle2(address(oracle)));
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
            multiplier: 200,
            maxBaseFee: 0,
            finalizerReward: 0
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
            borrower,address(0),
            
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
            multiplier: 0,
            maxBaseFee: 0,
            finalizerReward: 0
        });
    }

    /// @dev Lender accepts the current rate on the curve. Uses the current paramHash and skips the rate floor for simple test paths.
    ///      Defaults `liquidatorFraction = 0` (lender keeps all of any post-settlement equity buffer).
    function _lend(address lender, uint256 lendingId) internal {
        _lendWithFraction(lender, lendingId, 0);
    }

    /// @dev Same as `_lend` but allows specifying `liquidatorFraction` (1e7 fixed-point).
    function _lendWithFraction(address lender, uint256 lendingId, uint24 liquidatorFraction) internal {
        bytes32 paramHash = lendView.getParamHash(lendingId);
        vm.prank(lender);
        lending.lend(
            lendingId,
            paramHash,
            0,                   // minLendAmount (refi-only, ignored on origination)
            type(uint128).max,   // maxLendAmount (refi-only, ignored on origination)
            0,                   // expectedMinSupply
            0,                   // minRate floor
            liquidatorFraction,
            lender,
            address(0)
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

    /// @dev Predicts the deterministic fee-receiver clone address for a report after `liquidate` has linked it.
    function _predictFeeReceiver(uint256 reportId) internal view returns (address) {
        uint256 lendingId = _lendingIdForReportId(reportId);
        if (lendingId == 0) return IOpenOracle2(address(oracle)).storedGame(reportId).protocolFeeRecipient;
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        return _predictFeeReceiver(reportId, lendingId, loan.liquidator);
    }

    /// @dev Predicts the deterministic fee-receiver clone address before liquidation has written report links.
    function _predictFeeReceiver(uint256 reportId, uint256 lendingId, address liquidator)
        internal
        view
        returns (address)
    {
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        bytes memory args =
            abi.encodePacked(lendingId, loan.supplyToken, loan.borrowToken, loan.borrower, loan.lender, liquidator);
        return LibClone.predictDeterministicAddress(
            lending.feeReceiverImpl(),
            args,
            bytes32(reportId),
            address(lending)
        );
    }

    /// @dev Returns the latest reportId (use right after a liquidate() call).
    function _latestReportId() internal view returns (uint256) {
        return oracle.nextReportId() - 1;
    }

    function _lendingIdForReportId(uint256 reportId) internal view returns (uint256) {
        uint256 nextId = lending.nextLendingId();
        for (uint256 lendingId = 1; lendingId < nextId; lendingId++) {
            if (lending.lendingToReportId(lendingId) == reportId) return lendingId;
        }
        return 0;
    }

    function _distributeOracleGameFees(uint256 reportId) internal returns (uint256 fees1, uint256 fees2) {
        uint256 lendingId = _lendingIdForReportId(reportId);
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        (, fees1, fees2) =
            _deployAndDistributeOracleGameFees(reportId, lendingId, loan.borrower, loan.lender, loan.liquidator);
    }

    function _deployAndDistributeOracleGameFees(
        uint256 reportId,
        uint256 lendingId,
        address borrower_,
        address lender_,
        address liquidator_
    ) internal returns (address feeReceiver, uint256 fees1, uint256 fees2) {
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        return lending.deployAndDistributeFeeReceiver(
            reportId,
            lendingId,
            game.token1,
            game.token2,
            borrower_,
            lender_,
            liquidator_
        );
    }

    function _emptyTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory timing) {}

    function _helperFor(uint256 reportId) internal view returns (IOpenOracle2.PreimageHelper memory ph) {
        IOpenOracle2.StoredHelper memory sh = IOpenOracle2(address(oracle)).storedHelper(reportId);
        ph.reportId = reportId;
        ph.creator = sh.creator;
        ph.blockTimestamp = sh.blockTimestamp;
        ph.blockNumber = sh.blockNumber;
    }

    function _settleOracle(uint256 reportId) internal {
        uint256 lendingId = _lendingIdForReportId(reportId);
        if (lendingId != 0 && lendView.getLending(lendingId).inLiquidation) {
            lending.finalize(lendingId);
        }
        _settleOracleWithoutFinalize(reportId);
    }

    function _settleOracleWithoutFinalize(uint256 reportId) internal {
        IOpenOracle2(address(oracle)).settle(
            reportId,
            IOpenOracle2(address(oracle)).storedGame(reportId),
            _helperFor(reportId)
        );
    }

    function _disputeAndSwap(
        uint256 reportId,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        address disputer,
        uint128,
        bytes32
    ) internal {
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        vm.prank(disputer);
        IOpenOracle2(address(oracle)).dispute(
            reportId,
            tokenToSwap,
            newAmount1,
            newAmount2,
            disputer,
            false,
            false,
            game,
            helper, _emptyTiming()
        );
    }

    function _disputeToNonLiquidatingPrice(uint256 reportId, address tokenToSwap, address disputer) internal {
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        uint256 disputeReadyAt = uint256(o.reportTimestamp) + o.disputeDelay;
        if (block.timestamp < disputeReadyAt) vm.warp(disputeReadyAt);

        uint128 newAmount1 = uint128(uint256(o.currentAmount1) * o.multiplier / 100);
        uint128 newAmount2 = uint128(uint256(newAmount1) * 3 / 2);
        _disputeAndSwap(reportId, tokenToSwap, newAmount1, newAmount2, disputer, 0, bytes32(0));
    }

    function _failedLiqGracePeriod(uint256 reportId, uint256 liquidationStart) internal view returns (uint48) {
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        return uint48(1800 + (uint256(o.reportTimestamp) + o.settlementTime - liquidationStart));
    }

    function _reportStatus(uint256 reportId)
        internal
        view
        returns (
            uint128 currentAmount1,
            uint128 currentAmount2,
            address payable currentReporter,
            uint48 reportTimestamp,
            uint48 settlementTimestamp,
            address payable initialReporter,
            uint48 lastReportOppoTime
        )
    {
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        return (
            o.currentAmount1,
            o.currentAmount2,
            payable(o.currentReporter),
            o.reportTimestamp,
            o.settlementTimestamp,
            payable(o.currentReporter),
            o.lastReportOppoTime
        );
    }

    function _reportMeta(uint256 reportId)
        internal
        view
        returns (
            uint128 exactToken1Report,
            uint128 escalationHalt,
            uint96 fee,
            uint96 settlerReward,
            address token1,
            uint48 settlementTime,
            address token2,
            bool timeType,
            uint24 feePercentage,
            uint24 protocolFee,
            uint16 multiplier,
            uint24 disputeDelay
        )
    {
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        return (
            o.currentAmount1,
            o.escalationHalt,
            0,
            o.settlerReward,
            o.token1,
            o.settlementTime,
            o.token2,
            true,
            o.feePercentage,
            o.protocolFee,
            o.multiplier,
            o.disputeDelay
        );
    }
}
