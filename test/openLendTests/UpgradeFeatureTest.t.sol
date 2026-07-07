// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";
import {LendErrors} from "../../src/libraries/LendErrors.sol";

contract UpgradeFeatureTest is OpenLendingBaseTest {
    address internal borrower = address(0xB01);
    address internal lender = address(0xB02);
    address internal lender2 = address(0xB03);
    address internal refiDelegate = address(0xD01);
    address internal lenderDelegate = address(0xD02);
    address internal newDelegate = address(0xD03);
    address internal liquidator = address(0xB04);
    address internal disputer = address(0xB05);
    address internal caller = address(0xB06);

    uint128 internal constant SUPPLY_AMOUNT = 100 ether;
    uint128 internal constant BORROW_AMOUNT = 50 ether;
    uint48 internal constant LOAN_TERM = 7 days;
    uint96 internal constant SETTLER_REWARD = 0.001 ether;

    event LoanRefinanced(
        uint256 indexed lendingId,
        address indexed newLender,
        address indexed prevLender,
        uint256 principal,
        uint256 owedToPrevLender,
        uint256 rate,
        uint48 start,
        uint48 term,
        uint128 extraDemanded,
        uint128 supplyPulled,
        uint96 gasCompensation,
        uint24 liquidatorFraction,
        bool netted
    );

    function setUp() public {
        _deployCore("Collateral", "COL", "Debt", "DEBT");

        address[] memory supplyAccounts = new address[](4);
        supplyAccounts[0] = borrower;
        supplyAccounts[1] = liquidator;
        supplyAccounts[2] = disputer;
        supplyAccounts[3] = caller;
        _fundSupply(supplyAccounts, 10_000 ether);

        address[] memory borrowAccounts = new address[](7);
        borrowAccounts[0] = borrower;
        borrowAccounts[1] = lender;
        borrowAccounts[2] = lender2;
        borrowAccounts[3] = refiDelegate;
        borrowAccounts[4] = lenderDelegate;
        borrowAccounts[5] = liquidator;
        borrowAccounts[6] = disputer;
        _fundBorrow(borrowAccounts, 10_000 ether);

        address[] memory ethAccounts = new address[](7);
        ethAccounts[0] = borrower;
        ethAccounts[1] = lender;
        ethAccounts[2] = lender2;
        ethAccounts[3] = refiDelegate;
        ethAccounts[4] = lenderDelegate;
        ethAccounts[5] = liquidator;
        ethAccounts[6] = caller;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(lender2);
        _approveLendingBoth(refiDelegate);
        _approveLendingBoth(lenderDelegate);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);
    }

    function testRefiDelegate_InitialSetRevokeAndRefinanceAuth() public {
        uint256 lendingId = _requestWithRefiDelegate(refiDelegate);
        _lendWithDelegate(lendingId, lender, address(0));

        assertEq(lending.refiDelegation(lendingId), refiDelegate);

        vm.prank(caller);
        vm.expectRevert(LendErrors.MsgSender.selector);
        lending.setRefiDelegate(lendingId, newDelegate);

        vm.prank(refiDelegate);
        lending.refinance(
            lendingId,
            1 ether,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.curveOpen);
        assertEq(loan.refiParams.extraDemanded, 1 ether);

        vm.prank(borrower);
        lending.cancelRefinance(lendingId);

        vm.prank(borrower);
        lending.setRefiDelegate(lendingId, address(0));
        assertEq(lending.refiDelegation(lendingId), address(0));

        vm.prank(refiDelegate);
        vm.expectRevert(LendErrors.NotBorrower.selector);
        lending.refinance(
            lendingId,
            1 ether,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );
    }

    function testLenderDelegate_SetRevokeAndBatchGetter() public {
        uint256 lendingId = _requestWithRefiDelegate(refiDelegate);
        _lendWithDelegate(lendingId, lender, lenderDelegate);

        assertEq(lending.lenderDelegation(lendingId), lenderDelegate);

        vm.prank(caller);
        vm.expectRevert(LendErrors.MsgSender.selector);
        lending.setLenderDelegate(lendingId, newDelegate);

        vm.prank(lender);
        lending.setLenderDelegate(lendingId, newDelegate);
        assertEq(lending.lenderDelegation(lendingId), newDelegate);

        uint256[] memory ids = new uint256[](2);
        ids[0] = lendingId;
        ids[1] = lendingId + 1;
        (address[] memory refiDelegates, address[] memory lenderDelegates) = lendView.getDelegates(ids);
        assertEq(refiDelegates[0], refiDelegate);
        assertEq(lenderDelegates[0], newDelegate);
        assertEq(refiDelegates[1], address(0));
        assertEq(lenderDelegates[1], address(0));

        vm.prank(lender);
        lending.setLenderDelegate(lendingId, address(0));
        assertEq(lending.lenderDelegation(lendingId), address(0));
    }

    function testNettedRefi_Erc20BorrowOnlyPullsExtraFromAuthorizedDelegate() public {
        uint256 lendingId = _requestWithRefiDelegate(address(0));
        _lendWithDelegate(lendingId, lender, lenderDelegate);

        openLend.LendingArrangement memory beforeRefi = lendView.getLending(lendingId);
        uint256 owedToPrev = uint256(beforeRefi.principal) + beforeRefi.commitmentInterest;
        uint128 extraDemanded = 2 ether;

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            extraDemanded,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        uint256 delegateBefore = borrowToken.balanceOf(lenderDelegate);
        uint256 lenderBefore = borrowToken.balanceOf(lender);
        uint256 borrowerBefore = borrowToken.balanceOf(borrower);

        bytes32 refiHash = lendView.getParamHash(lendingId);
        vm.prank(lenderDelegate);
        lending.lend(
            lendingId,
            refiHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender,
            address(0)
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender);
        assertEq(loan.principal, owedToPrev + extraDemanded);
        assertEq(borrowToken.balanceOf(lenderDelegate), delegateBefore - extraDemanded);
        assertEq(borrowToken.balanceOf(lender), lenderBefore);
        assertEq(borrowToken.balanceOf(borrower), borrowerBefore + extraDemanded);
        assertEq(lending.lenderDelegation(lendingId), address(0));
    }

    function testNettedRefi_NativeBorrowOnlyRequiresExtraValue() public {
        uint256 lendingId = _requestNativeBorrow(lenderDelegate);

        openLend.LendingArrangement memory beforeRefi = lendView.getLending(lendingId);
        uint256 owedToPrev = uint256(beforeRefi.principal) + beforeRefi.commitmentInterest;
        uint128 extraDemanded = 1 ether;

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            extraDemanded,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        uint256 delegateBefore = lenderDelegate.balance;
        uint256 lenderBefore = lender.balance;
        uint256 borrowerBefore = borrower.balance;

        bytes32 refiHash = lendView.getParamHash(lendingId);
        vm.prank(lenderDelegate);
        lending.lend{value: extraDemanded}(
            lendingId,
            refiHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender,
            address(0)
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender);
        assertEq(loan.principal, owedToPrev + extraDemanded);
        assertEq(lenderDelegate.balance, delegateBefore - extraDemanded);
        assertEq(lender.balance, lenderBefore);
        assertEq(borrower.balance, borrowerBefore + extraDemanded);
    }

    function testNettedRefi_GiftThenNetSequencePaysVictimBeforeDelegateCanNet() public {
        uint256 lendingId = _originateWithDelegates(address(0), address(0));
        uint256 firstOwed = _residualFromSnapshot(lendView.getLending(lendingId));

        _openRefi(lendingId, 0);

        uint256 attackerBefore = borrowToken.balanceOf(lenderDelegate);
        uint256 victimBefore = borrowToken.balanceOf(lender);
        bytes32 giftHash = lendView.getParamHash(lendingId);
        vm.prank(lenderDelegate);
        lending.lend(
            lendingId,
            giftHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender,
            lenderDelegate
        );

        assertEq(borrowToken.balanceOf(lender), victimBefore + firstOwed);
        assertEq(borrowToken.balanceOf(lenderDelegate), attackerBefore - firstOwed);
        assertEq(lendView.getLending(lendingId).lender, lender);
        assertEq(lending.lenderDelegation(lendingId), lenderDelegate);

        uint128 extraDemanded = 1 ether;
        uint256 secondOwed = _residualFromSnapshot(lendView.getLending(lendingId));
        _openRefi(lendingId, extraDemanded);

        uint256 attackerBeforeNet = borrowToken.balanceOf(lenderDelegate);
        uint256 victimBeforeNet = borrowToken.balanceOf(lender);
        uint256 borrowerBeforeNet = borrowToken.balanceOf(borrower);
        bytes32 netHash = lendView.getParamHash(lendingId);
        vm.prank(lenderDelegate);
        lending.lend(
            lendingId,
            netHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender,
            lenderDelegate
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.principal, secondOwed + extraDemanded);
        assertEq(borrowToken.balanceOf(lenderDelegate), attackerBeforeNet - extraDemanded);
        assertEq(borrowToken.balanceOf(lender), victimBeforeNet);
        assertEq(borrowToken.balanceOf(borrower), borrowerBeforeNet + extraDemanded);
        assertEq(lending.lenderDelegation(lendingId), lenderDelegate);
    }

    function testNettedRefi_PureErc20RollRequiresNoApprovalOrTokenBalance() public {
        uint256 lendingId = _originateWithDelegates(address(0), newDelegate);
        uint256 owedToPrev = _residualFromSnapshot(lendView.getLending(lendingId));

        _openRefi(lendingId, 0);

        assertEq(borrowToken.balanceOf(newDelegate), 0);
        assertEq(borrowToken.allowance(newDelegate, address(lending)), 0);
        uint256 lenderBefore = borrowToken.balanceOf(lender);

        bytes32 refiHash = lendView.getParamHash(lendingId);
        vm.expectEmit(true, true, true, true, address(lending));
        emit LoanRefinanced(
            lendingId,
            lender,
            lender,
            owedToPrev,
            owedToPrev,
            1e8,
            uint48(block.timestamp),
            LOAN_TERM,
            0,
            0,
            0,
            0,
            true
        );

        vm.prank(newDelegate);
        lending.lend(
            lendingId,
            refiHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender,
            newDelegate
        );

        assertEq(lendView.getLending(lendingId).principal, owedToPrev);
        assertEq(borrowToken.balanceOf(newDelegate), 0);
        assertEq(borrowToken.balanceOf(lender), lenderBefore);
    }

    function testNettedRefi_PureNativeRollRequiresNoMsgValue() public {
        uint256 lendingId = _requestNativeBorrow(newDelegate);
        uint256 owedToPrev = _residualFromSnapshot(lendView.getLending(lendingId));

        _openRefi(lendingId, 0);

        vm.deal(newDelegate, 0);
        uint256 lenderBefore = lender.balance;
        uint256 borrowerBefore = borrower.balance;

        bytes32 refiHash = lendView.getParamHash(lendingId);
        vm.prank(newDelegate);
        lending.lend{value: 0}(
            lendingId,
            refiHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender,
            newDelegate
        );

        assertEq(lendView.getLending(lendingId).principal, owedToPrev);
        assertEq(newDelegate.balance, 0);
        assertEq(lender.balance, lenderBefore);
        assertEq(borrower.balance, borrowerBefore);
    }

    function testNettedRefi_DelegateNamingDifferentLenderDoesNotNet() public {
        uint256 lendingId = _originateWithDelegates(address(0), lenderDelegate);
        uint256 owedToPrev = _residualFromSnapshot(lendView.getLending(lendingId));

        _openRefi(lendingId, 0);

        uint256 delegateBefore = borrowToken.balanceOf(lenderDelegate);
        uint256 prevLenderBefore = borrowToken.balanceOf(lender);
        bytes32 refiHash = lendView.getParamHash(lendingId);

        vm.expectEmit(true, true, true, true, address(lending));
        emit LoanRefinanced(
            lendingId,
            lender2,
            lender,
            owedToPrev,
            owedToPrev,
            1e8,
            uint48(block.timestamp),
            LOAN_TERM,
            0,
            0,
            0,
            0,
            false
        );

        vm.prank(lenderDelegate);
        lending.lend(
            lendingId,
            refiHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender2,
            address(0)
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender2);
        assertEq(loan.principal, owedToPrev);
        assertEq(borrowToken.balanceOf(lenderDelegate), delegateBefore - owedToPrev);
        assertEq(borrowToken.balanceOf(lender), prevLenderBefore + owedToPrev);
    }

    function testNettedRefi_UnauthorizedCallerNamingPrevLenderDoesNotNet() public {
        uint256 lendingId = _originateWithDelegates(address(0), lenderDelegate);
        uint256 owedToPrev = _residualFromSnapshot(lendView.getLending(lendingId));

        _openRefi(lendingId, 0);

        uint256 funderBefore = borrowToken.balanceOf(lender2);
        uint256 prevLenderBefore = borrowToken.balanceOf(lender);
        bytes32 refiHash = lendView.getParamHash(lendingId);

        vm.prank(lender2);
        lending.lend(
            lendingId,
            refiHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender,
            address(0)
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender);
        assertEq(loan.principal, owedToPrev);
        assertEq(borrowToken.balanceOf(lender2), funderBefore - owedToPrev);
        assertEq(borrowToken.balanceOf(lender), prevLenderBefore + owedToPrev);
    }

    function testRefiDelegate_CannotCancelRefinance() public {
        uint256 lendingId = _requestWithRefiDelegate(refiDelegate);
        _lendWithDelegate(lendingId, lender, address(0));
        _openRefi(lendingId, 0);

        vm.prank(refiDelegate);
        vm.expectRevert(LendErrors.NotBorrower.selector);
        lending.cancelRefinance(lendingId);

        assertTrue(lendView.getLending(lendingId).curveOpen);
    }

    function testRepayDebt_MustCloseRejectsPartialAndAllowsFull() public {
        uint256 lendingId = _originateWithDelegates(address(0), address(0));
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        uint128 owed = uint128(uint256(loan.principal) + loan.commitmentInterest);
        uint256 lenderBefore = borrowToken.balanceOf(lender);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        vm.prank(borrower);
        vm.expectRevert(LendErrors.MustClose.selector);
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, type(uint128).max, true);

        assertEq(borrowToken.balanceOf(lender), lenderBefore);
        assertEq(supplyToken.balanceOf(borrower), borrowerSupplyBefore);
        assertEq(lendView.getLending(lendingId).principal, BORROW_AMOUNT);

        vm.prank(borrower);
        lending.repayDebt(lendingId, owed, bytes32(0), 0, type(uint128).max, true);

        assertTrue(lendView.getLending(lendingId).finished);
        assertEq(supplyToken.balanceOf(borrower), borrowerSupplyBefore + SUPPLY_AMOUNT);
    }

    function testRepayAnyDebt_MustCloseAllowsThirdPartyFullClose() public {
        uint256 lendingId = _originateWithDelegates(address(0), address(0));
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        uint128 owed = uint128(uint256(loan.principal) + loan.commitmentInterest);

        vm.prank(lender2);
        lending.repayAnyDebt(lendingId, owed, bytes32(0), 0, type(uint128).max, true);

        assertTrue(lendView.getLending(lendingId).finished);
        assertEq(supplyToken.balanceOf(borrower), 10_000 ether);
    }

    function testLendAndLiquidate_RejectZeroParamHash() public {
        uint256 lendingId = _requestWithRefiDelegate(address(0));

        vm.prank(lender);
        vm.expectRevert(LendErrors.Params.selector);
        lending.lend(
            lendingId,
            bytes32(0),
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender,
            address(0)
        );

        _lendWithDelegate(lendingId, lender, address(0));
        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;

        vm.prank(liquidator);
        vm.expectRevert(LendErrors.Params.selector);
        lending.liquidate{value: SETTLER_REWARD + finalizerReward}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            bytes32(0),
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );
    }

    function testParamHash_FailedAutoFinalizePreservesPreSettleHashForLendAndRepay() public {
        uint256 repayId = _originateWithDelegates(address(0), address(0));
        uint256 repayReport = _liquidateForUpgradeTest(repayId, 6 ether);
        _disputeToNonLiquidatingPrice(repayReport, address(supplyToken), disputer);
        IOpenOracle2.OracleGame memory repayGame = IOpenOracle2(address(oracle)).storedGame(repayReport);
        vm.warp(uint256(repayGame.reportTimestamp) + repayGame.settlementTime + 1);

        bytes32 repayHashBefore = lendView.getParamHash(repayId);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);
        vm.prank(borrower);
        lending.repayDebt(repayId, 1 ether, repayHashBefore, 0, type(uint128).max, false);
        assertEq(lendView.getParamHash(repayId), repayHashBefore);
        assertFalse(lendView.getLending(repayId).inLiquidation);
        assertEq(borrowToken.balanceOf(lender) - lenderBorrowBefore, 1 ether);

        uint256 lendId = _originateWithDelegates(address(0), address(0));
        _openRefi(lendId, 1 ether);
        uint256 lendReport = _liquidateForUpgradeTest(lendId, 6 ether);
        _disputeToNonLiquidatingPrice(lendReport, address(supplyToken), disputer);
        IOpenOracle2.OracleGame memory lendGame = IOpenOracle2(address(oracle)).storedGame(lendReport);
        vm.warp(uint256(lendGame.reportTimestamp) + lendGame.settlementTime + 1);

        bytes32 lendHashBefore = lendView.getParamHash(lendId);
        vm.prank(lender2);
        lending.lend(
            lendId,
            lendHashBefore,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender2,
            address(0)
        );
        assertEq(lendView.getLending(lendId).lender, lender2);
    }

    function testParamHash_FailedAutoFinalizeWithGracePreservesPreSettleHash() public {
        uint256 lendingId = _originateWithDelegates(address(0), address(0));
        openLend.LendingArrangement memory beforeLiq = lendView.getLending(lendingId);
        vm.warp(uint256(beforeLiq.start) + beforeLiq.term - 600);

        uint256 reportId = _liquidateForUpgradeTest(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);

        bytes32 hashBefore = lendView.getParamHash(lendingId);
        vm.prank(borrower);
        lending.repayDebt(lendingId, 1 ether, hashBefore, 0, type(uint128).max, false);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertGt(loan.gracePeriod, 0);
        assertEq(lendView.getParamHash(lendingId), hashBefore);
    }

    function testLiquidateParamHash_IgnoresRefiStagingAndCancelButRefiAcceptChanges() public {
        uint256 lendingId = _originateWithDelegates(address(0), address(0));

        bytes32 liquidateHashBefore = lendView.getLiquidateParamHash(lendingId);
        bytes32 normalHashBefore = lendView.getParamHash(lendingId);

        _openRefi(lendingId, 1 ether);
        assertEq(lendView.getLiquidateParamHash(lendingId), liquidateHashBefore);
        assertTrue(lendView.getParamHash(lendingId) != normalHashBefore);

        vm.prank(borrower);
        lending.cancelRefinance(lendingId);
        assertEq(lendView.getLiquidateParamHash(lendingId), liquidateHashBefore);

        _openRefi(lendingId, 1 ether);
        bytes32 refiHash = lendView.getParamHash(lendingId);
        vm.prank(lender2);
        lending.lend(
            lendingId,
            refiHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender2,
            address(0)
        );

        assertTrue(lendView.getLiquidateParamHash(lendingId) != liquidateHashBefore);
    }

    function testLiquidateParamHash_IgnoresRefiInterestRateParamMutationAndCancel() public {
        uint256 lendingId = _originateWithDelegates(address(0), address(0));
        bytes32 liquidateHashBefore = lendView.getLiquidateParamHash(lendingId);
        bytes32 normalHashBefore = lendView.getParamHash(lendingId);

        openLend.InterestRateParams memory hotRate = _standardInterestRateParams();
        hotRate.maxRate = 2e9;
        hotRate.startingRate = 2e8;
        hotRate.roundLength = 600;

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            LOAN_TERM,
            0,
            hotRate,
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        assertEq(lendView.getLiquidateParamHash(lendingId), liquidateHashBefore);
        assertTrue(lendView.getParamHash(lendingId) != normalHashBefore);

        vm.prank(borrower);
        lending.cancelRefinance(lendingId);
        assertEq(lendView.getLiquidateParamHash(lendingId), liquidateHashBefore);
        assertTrue(lendView.getParamHash(lendingId) != normalHashBefore);

        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD + finalizerReward}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            liquidateHashBefore,
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );

        assertTrue(lendView.getLending(lendingId).inLiquidation);
        assertEq(lending.lendingToReportId(lendingId), _latestReportId());
    }

    function testLiquidate_PreStagingHashSurvivesBorrowerRefiFrontRun() public {
        uint256 lendingId = _originateWithDelegates(address(0), address(0));
        bytes32 liquidateHashBefore = lendView.getLiquidateParamHash(lendingId);

        _openRefi(lendingId, 1 ether);

        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD + finalizerReward}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            liquidateHashBefore,
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );

        assertTrue(lendView.getLending(lendingId).inLiquidation);
        assertEq(lending.lendingToReportId(lendingId), _latestReportId());
    }

    function testClaimCollateral_AutoFinalizesFailedLiquidationThenClaims() public {
        uint256 lendingId = _originateWithDelegates(address(0), address(0));
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        uint256 start = loan.start;
        vm.warp(start + LOAN_TERM - 600);

        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD + finalizerReward}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );

        uint256 reportId = _latestReportId();
        uint256 liquidationStart = lendView.getLending(lendingId).liquidationStart;
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        uint48 grace = _failedLiqGracePeriod(reportId, liquidationStart);
        vm.warp(start + LOAN_TERM + grace);

        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        vm.prank(caller);
        lending.claimCollateral(lendingId);

        uint256 stake = uint256(SUPPLY_AMOUNT) * 100 / 10000;
        openLend.LendingArrangement memory afterClaim = lendView.getLending(lendingId);
        assertTrue(afterClaim.finished);
        assertEq(afterClaim.inLiquidation, false);
        assertEq(supplyToken.balanceOf(lender), lenderSupplyBefore + SUPPLY_AMOUNT + stake);
    }

    function testClaimCollateral_UnderwaterAutoFinalizeRevertsAndRollsBack() public {
        uint256 lendingId = _originateWithDelegates(address(0), address(0));
        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;

        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD + finalizerReward}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );

        uint256 reportId = _latestReportId();
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);

        vm.prank(caller);
        vm.expectRevert(LendErrors.Finished.selector);
        lending.claimCollateral(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.inLiquidation);
        assertFalse(loan.finished);
        assertEq(lending.lendingToReportId(lendingId), reportId);
    }

    function testParamHashHelper_BatchLendingOracleGamesStoredGamesAndDelegates() public {
        uint256 inactiveId = _requestWithRefiDelegate(refiDelegate);
        uint256 activeId = _originateWithDelegates(address(0), lenderDelegate);
        uint64 finalizerReward = lendView.getOracleParams(activeId).finalizerReward;

        bytes32 paramHash = lendView.getLiquidateParamHash(activeId);
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD + finalizerReward}(
            activeId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );
        uint256 reportId = _latestReportId();

        uint256[] memory ids = new uint256[](2);
        ids[0] = inactiveId;
        ids[1] = activeId;

        openLend.LendingArrangement[] memory byIds = lendView.getLending(ids);
        assertEq(byIds[0].borrower, borrower);
        assertEq(byIds[0].active, false);
        assertEq(byIds[1].lender, lender);
        assertTrue(byIds[1].inLiquidation);

        openLend.LendingArrangement[] memory byRange = lendView.getLending(inactiveId, 2);
        assertEq(byRange[0].borrower, borrower);
        assertEq(byRange[1].lender, lender);

        (address[] memory refiDelegates, address[] memory lenderDelegates) = lendView.getDelegates(ids);
        assertEq(refiDelegates[0], refiDelegate);
        assertEq(lenderDelegates[0], address(0));
        assertEq(refiDelegates[1], address(0));
        assertEq(lenderDelegates[1], lenderDelegate);

        (uint256[] memory reportIds, IOpenOracle2.OracleGame[] memory games) = lendView.getOracleGames(ids);
        assertEq(reportIds[0], 0);
        assertEq(games[0].currentAmount1, 0);
        assertEq(reportIds[1], reportId);
        assertEq(games[1].currentAmount1, IOpenOracle2(address(oracle)).storedGame(reportId).currentAmount1);

        uint256[] memory rawReportIds = new uint256[](2);
        rawReportIds[0] = 0;
        rawReportIds[1] = reportId;
        IOpenOracle2.OracleGame[] memory stored = lendView.getStoredGames(rawReportIds);
        assertEq(stored[0].currentAmount1, 0);
        assertEq(stored[1].currentAmount2, IOpenOracle2(address(oracle)).storedGame(reportId).currentAmount2);
    }

    function testDataProvider_FeeReceiverStateAndBatchReflectPendingFees() public {
        uint256 inactiveId = _requestWithRefiDelegate(refiDelegate);
        uint256 lendingId = _originateWithDelegates(address(0), address(0));
        uint256 reportId = _liquidateForUpgradeTest(lendingId, 6 ether);
        address feeRecipient = _predictFeeReceiver(reportId);

        openLendDataProvider.FeeReceiverState memory state = lendView.getFeeReceiver(lendingId);
        assertEq(state.feeReceiver, feeRecipient);
        assertEq(state.reportId, reportId);
        assertFalse(state.deployed);
        assertEq(state.fees1Pending, 0);
        assertEq(state.fees2Pending, 0);

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.disputeDelay + 1);
        uint256 expectedFee = uint256(game.currentAmount1) * game.protocolFee / 1e7;
        _disputeAndSwap(reportId, address(supplyToken), 20 ether, 12 ether, disputer, 0, bytes32(0));

        state = lendView.getFeeReceiver(lendingId);
        assertEq(state.fees1Pending, expectedFee);
        assertEq(state.fees2Pending, 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = inactiveId;
        ids[1] = lendingId;
        openLendDataProvider.FeeReceiverState[] memory states = lendView.getFeeReceivers(ids);
        assertEq(states[0].feeReceiver, address(0));
        assertEq(states[0].reportId, 0);
        assertFalse(states[0].deployed);
        assertEq(states[1].feeReceiver, feeRecipient);
        assertFalse(states[1].deployed);
        assertEq(states[1].fees1Pending, expectedFee);

        _distributeOracleGameFees(reportId);
        state = lendView.getFeeReceiver(lendingId);
        assertTrue(state.deployed);
        assertEq(state.fees1Pending, 0);
        assertEq(state.fees2Pending, 0);
    }

    function testDataProvider_PredictFeeReceiverWithArgsSurvivesRefiAndReliquidation() public {
        uint256 lendingId = _originateWithDelegates(address(0), address(0));
        uint256 reportId1 = _liquidateForUpgradeTest(lendingId, 6 ether);
        address feeRecipient1 = _predictFeeReceiver(reportId1);

        _disputeToNonLiquidatingPrice(reportId1, address(supplyToken), disputer);
        IOpenOracle2.OracleGame memory game1 = IOpenOracle2(address(oracle)).storedGame(reportId1);
        vm.warp(uint256(game1.reportTimestamp) + game1.settlementTime + 1);
        lending.finalize(lendingId);

        _openRefi(lendingId, 0);
        bytes32 refiHash = lendView.getParamHash(lendingId);
        vm.prank(lender2);
        lending.lend(
            lendingId,
            refiHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender2,
            address(0)
        );

        uint256 reportId2 = _liquidateForUpgradeTest(lendingId, 6 ether);
        address feeRecipient2 = _predictFeeReceiver(reportId2);

        assertEq(
            lendView.predictFeeReceiverWithArgs(
                reportId1,
                lendingId,
                address(supplyToken),
                address(borrowToken),
                borrower,
                lender,
                liquidator
            ),
            feeRecipient1
        );
        assertEq(
            lendView.predictFeeReceiverWithArgs(
                reportId2,
                lendingId,
                address(supplyToken),
                address(borrowToken),
                borrower,
                lender2,
                liquidator
            ),
            feeRecipient2
        );
        assertEq(lendView.getFeeReceiver(lendingId).feeReceiver, feeRecipient2);
        assertTrue(feeRecipient1 != feeRecipient2);
    }

    function testDataProvider_FinalizeStatePendingRestoreLiquidateAndBaseFeeGate() public {
        uint256 noneId = _originateWithDelegates(address(0), address(0));
        uint256 pendingId = _originateWithDelegates(address(0), address(0));
        uint256 pendingReport = _liquidateForUpgradeTest(pendingId, 6 ether);

        uint256[] memory ids = new uint256[](2);
        ids[0] = noneId;
        ids[1] = pendingId;
        openLendDataProvider.FinalizeState[] memory states = lendView.getFinalizeState(ids);
        _assertOutcome(states[0].outcome, openLendDataProvider.FinalizeOutcome.None);
        _assertOutcome(states[1].outcome, openLendDataProvider.FinalizeOutcome.Pending);
        IOpenOracle2.OracleGame memory pendingGame = IOpenOracle2(address(oracle)).storedGame(pendingReport);
        assertEq(states[1].settleableAt, uint256(pendingGame.reportTimestamp) + pendingGame.settlementTime);

        uint256 restoreId = _originateWithDelegates(address(0), address(0));
        openLend.LendingArrangement memory restoreLoan = lendView.getLending(restoreId);
        vm.warp(uint256(restoreLoan.start) + restoreLoan.term - 600);
        uint256 restoreReport = _liquidateForUpgradeTest(restoreId, 6 ether);
        uint256 liquidationStart = lendView.getLending(restoreId).liquidationStart;
        _disputeToNonLiquidatingPrice(restoreReport, address(supplyToken), disputer);
        uint48 expectedGrace = _failedLiqGracePeriod(restoreReport, liquidationStart);
        IOpenOracle2.OracleGame memory restoreGame = IOpenOracle2(address(oracle)).storedGame(restoreReport);
        vm.warp(uint256(restoreGame.reportTimestamp) + restoreGame.settlementTime + 1);

        ids = new uint256[](1);
        ids[0] = restoreId;
        states = lendView.getFinalizeState(ids);
        _assertOutcome(states[0].outcome, openLendDataProvider.FinalizeOutcome.Restore);
        assertEq(states[0].projectedGracePeriod, expectedGrace);
        lending.finalize(restoreId);
        openLend.LendingArrangement memory afterRestore = lendView.getLending(restoreId);
        assertFalse(afterRestore.inLiquidation);
        assertFalse(afterRestore.finished);
        assertEq(afterRestore.gracePeriod, expectedGrace);

        uint256 liquidateId = _originateWithDelegates(address(0), address(0));
        uint256 liquidateReport = _liquidateForUpgradeTest(liquidateId, 6 ether);
        IOpenOracle2.OracleGame memory liquidateGame = IOpenOracle2(address(oracle)).storedGame(liquidateReport);
        vm.warp(uint256(liquidateGame.reportTimestamp) + liquidateGame.settlementTime + 1);
        ids[0] = liquidateId;
        states = lendView.getFinalizeState(ids);
        _assertOutcome(states[0].outcome, openLendDataProvider.FinalizeOutcome.Liquidate);
        lending.finalize(liquidateId);
        assertTrue(lendView.getLending(liquidateId).finished);

        openLend.OracleParams memory cappedParams = _standardOracleParams();
        cappedParams.maxBaseFee = 100 gwei;
        uint256 cappedId = _requestWithOracleParams(cappedParams);
        _lendWithDelegate(cappedId, lender, address(0));
        uint256 cappedReport = _liquidateForUpgradeTest(cappedId, 6 ether);
        IOpenOracle2.OracleGame memory cappedGame = IOpenOracle2(address(oracle)).storedGame(cappedReport);
        vm.warp(uint256(cappedGame.reportTimestamp) + cappedGame.settlementTime + 1);
        vm.fee(101 gwei);
        ids[0] = cappedId;
        states = lendView.getFinalizeState(ids);
        _assertOutcome(states[0].outcome, openLendDataProvider.FinalizeOutcome.Restore);
        lending.finalize(cappedId);
        openLend.LendingArrangement memory afterCap = lendView.getLending(cappedId);
        assertFalse(afterCap.inLiquidation);
        assertFalse(afterCap.finished);
    }

    function testDataProvider_GetAmountOwedMirrorsLiveDebtAndZeroesInactiveOrFinished() public {
        uint256 inactiveId = _requestWithRefiDelegate(address(0));
        uint256 lendingId = _originateWithDelegates(address(0), address(0));

        uint256[] memory ids = new uint256[](2);
        ids[0] = inactiveId;
        ids[1] = lendingId;
        uint256[] memory owed = lendView.getAmountOwed(ids);
        assertEq(owed[0], 0);
        assertEq(owed[1], _residualFromSnapshot(lendView.getLending(lendingId)));

        vm.warp(block.timestamp + 1 days);
        owed = lendView.getAmountOwed(ids);
        uint256 owedBefore = owed[1];
        assertGt(owedBefore, BORROW_AMOUNT);

        vm.prank(borrower);
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, type(uint128).max, false);

        owed = lendView.getAmountOwed(ids);
        assertLt(owed[1], owedBefore);
        assertEq(owed[1], _residualFromSnapshot(lendView.getLending(lendingId)));

        uint128 closeAmount = uint128(owed[1]);
        vm.prank(borrower);
        lending.repayDebt(lendingId, closeAmount, bytes32(0), 0, type(uint128).max, true);

        owed = lendView.getAmountOwed(ids);
        assertEq(owed[0], 0);
        assertEq(owed[1], 0);
    }

    function _assertOutcome(
        openLendDataProvider.FinalizeOutcome actual,
        openLendDataProvider.FinalizeOutcome expected
    ) internal pure {
        assertEq(uint256(actual), uint256(expected));
    }

    function _requestWithOracleParams(openLend.OracleParams memory oracleParams) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            1e7,
            0,
            borrower,
            address(0),
            oracleParams,
            _standardInterestRateParams()
        );
    }

    function _liquidateForUpgradeTest(uint256 lendingId, uint256 oracleAmount2Target)
        internal
        returns (uint256 reportId)
    {
        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD + finalizerReward}(
            lendingId,
            _priceRatioFor(oracleAmount2Target),
            type(uint128).max,
            paramHash,
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );
        reportId = _latestReportId();
    }

    function _requestWithRefiDelegate(address delegate) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            1e7,
            0,
            borrower,
            delegate,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
    }

    function _lendWithDelegate(uint256 lendingId, address recordedLender, address delegate) internal {
        bytes32 paramHash = lendView.getParamHash(lendingId);
        vm.prank(recordedLender);
        lending.lend(
            lendingId,
            paramHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            recordedLender,
            delegate
        );
    }

    function _originateWithDelegates(address borrowDelegate, address lendDelegate) internal returns (uint256 lendingId) {
        lendingId = _requestWithRefiDelegate(borrowDelegate);
        _lendWithDelegate(lendingId, lender, lendDelegate);
    }

    function _requestNativeBorrow(address delegate) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(0),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            100,
            1e7,
            0,
            borrower,
            address(0),
            _standardOracleParams(),
            _standardInterestRateParams()
        );

        bytes32 paramHash = lendView.getParamHash(lendingId);
        vm.prank(lender);
        lending.lend{value: BORROW_AMOUNT}(
            lendingId,
            paramHash,
            0,
            type(uint128).max,
            0,
            0,
            0,
            lender,
            delegate
        );
    }

    function _openRefi(uint256 lendingId, uint128 extraDemanded) internal {
        vm.prank(borrower);
        lending.refinance(
            lendingId,
            extraDemanded,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );
    }

    function _residualFromSnapshot(openLend.LendingArrangement memory loan) internal pure returns (uint256) {
        uint256 interestClaim = loan.interestAccrued > loan.commitmentInterest
            ? uint256(loan.interestAccrued)
            : uint256(loan.commitmentInterest);
        uint256 unpaidInterest = interestClaim > loan.interestPaid ? interestClaim - loan.interestPaid : 0;
        return uint256(loan.principal) + unpaidInterest;
    }

    function _zeroOpenLendInterestParams() internal pure returns (openLend.InterestRateParams memory) {
        return openLend.InterestRateParams({
            maxRate: 0,
            startingRate: 0,
            roundLength: 0,
            growthRate: 0,
            maxRounds: 0
        });
    }

    function _priceRatioFor(uint256 oracleAmount2Target) internal pure returns (uint256) {
        uint256 initialLiquidity = uint256(SUPPLY_AMOUNT) * 10 / 100;
        return oracleAmount2Target * 1e18 / initialLiquidity;
    }
}
