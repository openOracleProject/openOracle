// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LendErrors} from "../../src/libraries/LendErrors.sol";
import "./OpenLendingBase.t.sol";

contract MaxBaseFeeTest is OpenLendingBaseTest {
    event LiqFinishedUnderwater(uint256 indexed lendingId);
    event LiqUnsuccessful(uint256 indexed lendingId);

    address internal borrower = address(0xBEEF1);
    address internal lender = address(0xBEEF2);
    address internal liquidator = address(0xBEEF3);
    address internal disputer = address(0xBEEF4);
    address internal settler = address(0xBEEF5);

    uint128 internal constant SUPPLY_AMOUNT = 100 ether;
    uint128 internal constant BORROW_AMOUNT = 70 ether;
    uint48 internal constant LOAN_TERM = 30 days;
    uint16 internal constant STAKE = 100;
    uint96 internal constant SETTLER_REWARD = 1e15;

    uint256 internal constant BASE_CAP = 100 gwei;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accounts = new address[](4);
        accounts[0] = borrower;
        accounts[1] = lender;
        accounts[2] = liquidator;
        accounts[3] = disputer;
        _fundSupply(accounts, 10_000 ether);
        _fundBorrow(accounts, 10_000 ether);

        address[] memory ethAccounts = new address[](5);
        ethAccounts[0] = borrower;
        ethAccounts[1] = lender;
        ethAccounts[2] = liquidator;
        ethAccounts[3] = disputer;
        ethAccounts[4] = settler;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);
    }

    function testUnderwaterLiquidationBelowBaseFeeCapSucceeds() public {
        uint256 lendingId = _openLoanWithMaxBaseFee(uint48(BASE_CAP));
        uint256 reportId = _liquidate(lendingId, 6 ether);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);
        vm.fee(BASE_CAP);

        vm.expectEmit(true, false, false, true, address(lending));
        emit LiqFinishedUnderwater(lendingId);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "underwater liquidation succeeds below cap");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
    }

    function testUnderwaterLiquidationAboveBaseFeeCapFails() public {
        uint256 lendingId = _openLoanWithMaxBaseFee(uint48(BASE_CAP));
        uint256 reportId = _liquidate(lendingId, 6 ether);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);
        vm.fee(BASE_CAP + 1);

        vm.expectEmit(true, false, false, true, address(lending));
        emit LiqUnsuccessful(lendingId);
        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.finished, "high basefee converts liquidation to unsuccessful");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + 1 ether, "liquidator stake added to collateral");
    }

    function testDisputeEscalationScalesBaseFeeCap() public {
        uint256 lendingId = _openLoanWithMaxBaseFee(uint48(BASE_CAP));
        uint256 reportId = _liquidate(lendingId, 6 ether);

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.disputeDelay + 1);
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 12 ether, disputer, 0, bytes32(0));

        game = IOpenOracle2(address(oracle)).storedGame(reportId);
        assertEq(game.currentAmount1, 20 ether, "amount1 doubled");

        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);
        vm.fee(150 gwei);

        vm.expectEmit(true, false, false, true, address(lending));
        emit LiqFinishedUnderwater(lendingId);
        vm.prank(settler);
        _settleOracle(reportId);

        assertTrue(lendView.getLending(lendingId).finished, "scaled cap permits settlement");
    }

    function testZeroMaxBaseFeeIsUncapped() public {
        uint256 lendingId = _openLoanWithMaxBaseFee(0);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);
        vm.fee(10_000 gwei);

        vm.prank(settler);
        _settleOracle(reportId);

        assertTrue(lendView.getLending(lendingId).finished, "zero maxBaseFee leaves liquidation uncapped");
    }

    function testRefiPreservesThenUpdatesMaxBaseFee() public {
        uint256 lendingId = _openLoanWithMaxBaseFee(uint48(BASE_CAP));

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            0,
            0,
            _standardInterestRateParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        assertEq(lendView.getOracleParams(lendingId).maxBaseFee, BASE_CAP, "zero sentinel preserves maxBaseFee");

        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender, address(0));
        vm.stopPrank();
        assertEq(lendView.getOracleParams(lendingId).maxBaseFee, BASE_CAP, "accepting sentinel refi preserves");

        openLend.OracleParams memory updated = _oracleParamsWithMaxBaseFee(uint48(123 gwei));
        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            0,
            0,
            _standardInterestRateParams(),
            updated,
            bytes32(0),
            0,
            type(uint128).max
        );

        assertEq(lendView.getOracleParams(lendingId).maxBaseFee, BASE_CAP, "staged params not applied before lend");

        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender, address(0));
        vm.stopPrank();
        assertEq(lendView.getOracleParams(lendingId).maxBaseFee, 123 gwei, "refi acceptance updates maxBaseFee");
    }

    function testParamHashChangesWhenMaxBaseFeeChanges() public {
        uint256 lendingIdA = _requestLoanWithMaxBaseFee(uint48(BASE_CAP));
        uint256 lendingIdB = _requestLoanWithMaxBaseFee(uint48(BASE_CAP + 1));

        bytes32 hashA = lendView.getParamHash(lendingIdA);
        bytes32 hashB = lendView.getParamHash(lendingIdB);

        assertTrue(hashA != hashB, "maxBaseFee is part of param hash");
    }

    function testLiquidate_RevertsWhenFinalizerRewardNotFunded() public {
        uint256 lendingId = _openLoanWithOracleParams(_oracleParamsWithFinalizerReward(uint64(SETTLER_REWARD + 1)));
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);

        vm.prank(liquidator);
        vm.expectRevert(LendErrors.MsgValue.selector);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD, liquidator, uint64(SETTLER_REWARD + 1), _emptyTiming()
        );
    }

    function testLiquidate_RevertsWhenExpectedFinalizerRewardIsStale() public {
        uint256 lendingId = _openLoanWithOracleParams(_oracleParamsWithFinalizerReward(uint64(SETTLER_REWARD + 1)));
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);

        vm.prank(liquidator);
        vm.expectRevert(LendErrors.FinalizerRewardMismatch.selector);
        lending.liquidate{value: SETTLER_REWARD * 2 + 1}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD, liquidator, uint64(SETTLER_REWARD), _emptyTiming()
        );
    }

    function testLiquidate_AcceptsFinalizerRewardAndStoresSettlerReward() public {
        uint256 lendingId = _openLoanWithOracleParams(_oracleParamsWithFinalizerReward(uint64(SETTLER_REWARD)));
        uint256 reportId = _liquidate(lendingId, 6 ether);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        assertEq(o.settlerReward, SETTLER_REWARD, "settlerReward stored");
    }

    function testRefiPreservesThenUpdatesFinalizerReward() public {
        uint256 lendingId = _openLoanWithOracleParams(_oracleParamsWithFinalizerReward(uint64(SETTLER_REWARD)));

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            0,
            0,
            _standardInterestRateParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        assertEq(lendView.getOracleParams(lendingId).finalizerReward, SETTLER_REWARD, "zero sentinel preserves min");

        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender, address(0));
        vm.stopPrank();
        assertEq(lendView.getOracleParams(lendingId).finalizerReward, SETTLER_REWARD, "accepting sentinel preserves min");

        openLend.OracleParams memory updated = _oracleParamsWithFinalizerReward(uint64(SETTLER_REWARD * 2));
        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            0,
            0,
            _standardInterestRateParams(),
            updated,
            bytes32(0),
            0,
            type(uint128).max
        );

        assertEq(lendView.getOracleParams(lendingId).finalizerReward, SETTLER_REWARD, "staged min not applied before lend");

        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender, address(0));
        vm.stopPrank();
        assertEq(lendView.getOracleParams(lendingId).finalizerReward, SETTLER_REWARD * 2, "refi acceptance updates min");
    }

    function testParamHashChangesWhenFinalizerRewardChanges() public {
        uint256 lendingIdA = _requestLoanWithOracleParams(_oracleParamsWithFinalizerReward(uint64(SETTLER_REWARD)));
        uint256 lendingIdB = _requestLoanWithOracleParams(_oracleParamsWithFinalizerReward(uint64(SETTLER_REWARD + 1)));

        bytes32 hashA = lendView.getParamHash(lendingIdA);
        bytes32 hashB = lendView.getParamHash(lendingIdB);

        assertTrue(hashA != hashB, "finalizerReward is part of param hash");
    }

    function _openLoanWithMaxBaseFee(uint48 maxBaseFee) internal returns (uint256 lendingId) {
        lendingId = _requestLoanWithMaxBaseFee(maxBaseFee);
        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender, address(0));
        vm.stopPrank();
    }

    function _openLoanWithOracleParams(openLend.OracleParams memory oracleParams) internal returns (uint256 lendingId) {
        lendingId = _requestLoanWithOracleParams(oracleParams);
        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender, address(0));
        vm.stopPrank();
    }

    function _requestLoanWithMaxBaseFee(uint48 maxBaseFee) internal returns (uint256 lendingId) {
        lendingId = _requestLoanWithOracleParams(_oracleParamsWithMaxBaseFee(maxBaseFee));
    }

    function _requestLoanWithOracleParams(openLend.OracleParams memory oracleParams) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            0,
            0,
            borrower,address(0),
            
            oracleParams,
            _standardInterestRateParams()
        );
    }

    function _liquidate(uint256 lendingId, uint256 oracleAmount2Target) internal returns (uint256 reportId) {
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD + finalizerReward}(
            lendingId,
            _priceRatioFor(oracleAmount2Target),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD, liquidator, finalizerReward, _emptyTiming()
        );
        reportId = oracle.nextReportId() - 1;
    }

    function _priceRatioFor(uint256 oracleAmount2Target) internal pure returns (uint256) {
        return oracleAmount2Target * 1e18 / 10 ether;
    }

    function _oracleParamsWithMaxBaseFee(uint48 maxBaseFee) internal pure returns (openLend.OracleParams memory p) {
        p = _standardOracleParams();
        p.maxBaseFee = maxBaseFee;
    }

    function _oracleParamsWithFinalizerReward(uint64 finalizerReward)
        internal
        pure
        returns (openLend.OracleParams memory p)
    {
        p = _standardOracleParams();
        p.finalizerReward = finalizerReward;
    }
}
