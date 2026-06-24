// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";
import {LendErrors} from "../../src/libraries/LendErrors.sol";

contract AdapterCompatibilityTest is OpenLendingBaseTest {
    event BorrowRequested(
        address indexed borrower,
        uint256 indexed lendingId,
        address supplyToken,
        address borrowToken,
        uint128 supplyAmount,
        uint128 amountDemanded,
        uint48 term,
        uint24 liquidationThreshold,
        uint16 stake,
        uint24 commitmentFraction,
        uint96 gasCompensation,
        openLend.OracleParams oracleParams,
        openLend.InterestRateParams interestRateParams
    );
    event LoanOriginated(
        uint256 indexed lendingId,
        address indexed lender,
        uint256 principal,
        uint256 rate,
        uint48 start,
        uint48 term,
        uint96 gasCompensation,
        uint24 liquidatorFraction
    );
    event RefiOpened(
        uint256 indexed lendingId,
        uint128 extraDemanded,
        uint128 supplyPulled,
        uint48 newTerm,
        uint96 gasCompensation,
        openLend.OracleParams oracleParams,
        openLend.InterestRateParams interestRateParams
    );

    address internal borrower = address(0xA11);
    address internal requestFunder = address(0xA12);
    address internal lender = address(0xA13);
    address internal lendFunder = address(0xA14);
    address internal recordedLender = address(0xA15);

    uint128 internal constant SUPPLY_AMOUNT = 100 ether;
    uint128 internal constant BORROW_AMOUNT = 50 ether;
    uint48 internal constant LOAN_TERM = 30 days;
    uint96 internal constant GAS_COMP = 0.01 ether;

    function setUp() public {
        _deployCore("Collateral", "COL", "Debt", "DEBT");

        address[] memory supplyAccounts = new address[](2);
        supplyAccounts[0] = borrower;
        supplyAccounts[1] = requestFunder;
        _fundSupply(supplyAccounts, 10_000 ether);

        address[] memory borrowAccounts = new address[](4);
        borrowAccounts[0] = borrower;
        borrowAccounts[1] = lender;
        borrowAccounts[2] = lendFunder;
        borrowAccounts[3] = recordedLender;
        _fundBorrow(borrowAccounts, 10_000 ether);

        address[] memory ethAccounts = new address[](5);
        ethAccounts[0] = borrower;
        ethAccounts[1] = requestFunder;
        ethAccounts[2] = lender;
        ethAccounts[3] = lendFunder;
        ethAccounts[4] = recordedLender;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingSupply(requestFunder);
        _approveLendingBorrow(lender);
        _approveLendingBorrow(lendFunder);
        _approveLendingBorrow(recordedLender);
    }

    function testRequestBorrow_SeparateFunderRecordsBorrowerAndCancelReturnsToBorrower() public {
        uint256 funderSupplyBefore = supplyToken.balanceOf(requestFunder);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 nextId = lending.nextLendingId();

        vm.expectEmit(true, true, false, true, address(lending));
        emit BorrowRequested(
            borrower,
            nextId,
            address(supplyToken),
            address(borrowToken),
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            LOAN_TERM,
            8e6,
            100,
            1e7,
            GAS_COMP,
            _standardOracleParams(),
            _standardInterestRateParams()
        );

        uint256 lendingId = _requestBorrowFrom(requestFunder, borrower, GAS_COMP);
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);

        assertEq(loan.borrower, borrower);
        assertEq(supplyToken.balanceOf(requestFunder), funderSupplyBefore - SUPPLY_AMOUNT);
        assertEq(supplyToken.balanceOf(borrower), borrowerSupplyBefore);
        assertEq(supplyToken.balanceOf(address(lending)), SUPPLY_AMOUNT);

        vm.prank(borrower);
        lending.cancelBorrowRequest(lendingId);

        assertEq(supplyToken.balanceOf(requestFunder), funderSupplyBefore - SUPPLY_AMOUNT);
        assertEq(supplyToken.balanceOf(borrower), borrowerSupplyBefore + SUPPLY_AMOUNT);
        assertEq(lendView.getLending(lendingId).cancelled, true);
    }

    function testRequestBorrow_RejectsZeroBorrower() public {
        vm.prank(requestFunder);
        vm.expectRevert(LendErrors.AddressCannotBeZero.selector);
        lending.requestBorrow{value: GAS_COMP}(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            1e7,
            GAS_COMP,
            address(0),
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    function testLend_SeparateFunderRecordsLenderAndPaysRecordedLender() public {
        uint256 lendingId = _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, 1e7, GAS_COMP);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 funderBorrowBefore = borrowToken.balanceOf(lendFunder);
        uint256 lenderEthBefore = recordedLender.balance;
        uint48 start = uint48(block.timestamp);

        vm.expectEmit(true, true, false, true, address(lending));
        emit LoanOriginated(lendingId, recordedLender, BORROW_AMOUNT, 1e8, start, LOAN_TERM, GAS_COMP, 0);

        vm.prank(lendFunder);
        lending.lend(
            lendingId,
            bytes32(0),
            0,
            type(uint128).max,
            0,
            0,
            0,
            recordedLender
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, recordedLender);
        assertEq(borrowToken.balanceOf(borrower), borrowerBorrowBefore + BORROW_AMOUNT);
        assertEq(borrowToken.balanceOf(lendFunder), funderBorrowBefore - BORROW_AMOUNT);
        assertEq(recordedLender.balance, lenderEthBefore + GAS_COMP);

        uint128 owed = _calculateOwedAtMaturity(BORROW_AMOUNT, loan.rate, LOAN_TERM);
        uint256 recordedLenderBorrowBefore = borrowToken.balanceOf(recordedLender);
        uint256 lendFunderBorrowBeforeRepay = borrowToken.balanceOf(lendFunder);

        vm.prank(borrower);
        lending.repayDebt(lendingId, owed, bytes32(0), 0, type(uint128).max);

        assertEq(borrowToken.balanceOf(recordedLender), recordedLenderBorrowBefore + owed);
        assertEq(borrowToken.balanceOf(lendFunder), lendFunderBorrowBeforeRepay);
        assertEq(lendView.getLending(lendingId).finished, true);
    }

    function testLend_RejectsZeroLender() public {
        uint256 lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);

        vm.prank(lendFunder);
        vm.expectRevert(LendErrors.AddressCannotBeZero.selector);
        lending.lend(
            lendingId,
            bytes32(0),
            0,
            type(uint128).max,
            0,
            0,
            0,
            address(0)
        );
    }

    function testRefinance_ZeroMaxRateKeepsExistingRateParamsThroughAcceptance() public {
        uint256 lendingId = _originateLoan(borrower, lender, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        openLend.InterestRateParams memory original = lendView.getRateParams(lendingId);
        openLend.InterestRateParams memory keepCurrent;
        uint48 newTerm = LOAN_TERM + 1 days;

        vm.expectEmit(true, false, false, true, address(lending));
        emit RefiOpened(lendingId, 0, 0, newTerm, 0, lendView.getOracleParams(lendingId), original);

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            newTerm,
            0,
            keepCurrent,
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        _assertRateParamsEq(lendView.getRateParams(lendingId), original);

        vm.prank(lendFunder);
        lending.lend(
            lendingId,
            bytes32(0),
            0,
            type(uint128).max,
            0,
            0,
            0,
            recordedLender
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, recordedLender);
        _assertRateParamsEq(lendView.getRateParams(lendingId), original);
    }

    function _requestBorrowFrom(address caller, address recordedBorrower, uint96 gasCompensation)
        internal
        returns (uint256 lendingId)
    {
        vm.prank(caller);
        lendingId = lending.requestBorrow{value: gasCompensation}(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            1e7,
            gasCompensation,
            recordedBorrower,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    function _assertRateParamsEq(
        openLend.InterestRateParams memory actual,
        openLend.InterestRateParams memory expected
    ) internal pure {
        assertEq(actual.maxRate, expected.maxRate);
        assertEq(actual.startingRate, expected.startingRate);
        assertEq(actual.roundLength, expected.roundLength);
        assertEq(actual.growthRate, expected.growthRate);
        assertEq(actual.maxRounds, expected.maxRounds);
    }
}
