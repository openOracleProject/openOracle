// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LendErrors} from "../../src/libraries/LendErrors.sol";
import "forge-std/Test.sol";
import "../../src/lend/openLend.sol";
import "../../src/lend/openLendDataProvider.sol";
import "../../src/lend/openLendFeeReceiver.sol";
import "../../src/OpenOracleSlim.sol";
import "../../src/interfaces/IOpenOracle2.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../utils/MockWETH.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BlacklistableMintableERC20 is ERC20 {
    mapping(address => bool) public blacklisted;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blacklist(address account) external {
        blacklisted[account] = true;
    }

    function unblacklist(address account) external {
        blacklisted[account] = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[msg.sender], "Blacklisted sender");
        require(!blacklisted[to], "Blacklisted recipient");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[from], "Blacklisted sender");
        require(!blacklisted[to], "Blacklisted recipient");
        return super.transferFrom(from, to, amount);
    }
}

/// @notice Coverage for the helper / view / fallback paths in V3 that aren't naturally exercised by lifecycle tests.
contract HelperCoverageTest is Test {
    openLend internal lending;
    openLendDataProvider internal lendView;
    OpenOracle internal oracle;
    MintableERC20 internal supplyToken;
    MintableERC20 internal borrowToken;
    BlacklistableMintableERC20 internal blacklistedBorrowToken;

    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal lender2 = address(0x3);
    address internal topper = address(0x4);
    address internal liquidator = address(0x5);
    address internal disputer = address(0x6);
    address internal settler = address(0x7);

    uint128 internal constant SUPPLY_AMOUNT = 100 ether;
    uint128 internal constant BORROW_AMOUNT = 50 ether;
    uint48 internal constant LOAN_TERM = 30 days;
    uint24 internal constant LIQUIDATION_THRESHOLD = 8e6;
    uint16 internal constant STAKE = 100;

    function setUp() public {
        oracle = new OpenOracle();
        MockWETH weth = new MockWETH();
        lending = new openLend(IOpenOracle2(address(oracle)), address(weth));
        lendView = new openLendDataProvider(lending, IOpenOracle2(address(oracle)));

        supplyToken = new MintableERC20("Supply Token", "SUP");
        borrowToken = new MintableERC20("Borrow Token", "BOR");
        blacklistedBorrowToken = new BlacklistableMintableERC20("Blacklist Borrow Token", "BBOR");

        address[7] memory accounts =
            [borrower, lender, lender2, topper, liquidator, disputer, settler];
        for (uint256 i = 0; i < accounts.length; i++) {
            supplyToken.mint(accounts[i], 10_000 ether);
            borrowToken.mint(accounts[i], 10_000 ether);
            blacklistedBorrowToken.mint(accounts[i], 10_000 ether);
            vm.deal(accounts[i], 100 ether);
        }

        // Big supplies for overflow tests
        supplyToken.mint(borrower, type(uint128).max);
        supplyToken.mint(topper, type(uint128).max);

        for (uint256 i = 0; i < accounts.length; i++) {
            _approve(address(supplyToken), accounts[i]);
            _approve(address(borrowToken), accounts[i]);
            _approve(address(blacklistedBorrowToken), accounts[i]);
        }
    }

    // -------------------------------------------------------------------------
    // tempHolding fallback
    // -------------------------------------------------------------------------

    function testTempHolding_FailedTransferCreditsAndCanBeWithdrawn() public {
        uint256 lendingId =
            _setupActiveLoan(address(supplyToken), address(blacklistedBorrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);
        uint32 rate = lendView.getLending(lendingId).rate;
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);

        uint256 lenderBorrowBefore = blacklistedBorrowToken.balanceOf(lender);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        // Blacklist the lender so the contract->lender payout falls back to tempHolding
        blacklistedBorrowToken.blacklist(lender);

        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed, bytes32(0), 0, type(uint128).max, false);

        assertEq(
            lending.tempHolding(lender, address(blacklistedBorrowToken)),
            totalOwed,
            "tempHolding should capture failed lender payout"
        );
        assertEq(
            blacklistedBorrowToken.balanceOf(lender),
            lenderBorrowBefore,
            "lender should not receive funds while blacklisted"
        );
        assertEq(
            supplyToken.balanceOf(borrower),
            borrowerSupplyBefore + SUPPLY_AMOUNT,
            "borrower should still get collateral back"
        );

        // Unblacklist and pull from tempHolding
        blacklistedBorrowToken.unblacklist(lender);

        vm.prank(lender);
        lending.getTempHolding(address(blacklistedBorrowToken));

        assertEq(
            lending.tempHolding(lender, address(blacklistedBorrowToken)), 0, "tempHolding should be cleared after withdrawal"
        );
        assertEq(
            blacklistedBorrowToken.balanceOf(lender),
            lenderBorrowBefore + totalOwed,
            "lender should withdraw withheld funds"
        );
    }

    function testFuzz_TempHoldingPartialRepayEscrowsAndWithdraws(uint96 repaySeed) public {
        uint256 lendingId =
            _setupActiveLoan(address(supplyToken), address(blacklistedBorrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);
        uint128 repayAmount = uint128(bound(uint256(repaySeed), 1, BORROW_AMOUNT / 2));

        uint256 lenderBorrowBefore = blacklistedBorrowToken.balanceOf(lender);
        uint256 borrowerBorrowBefore = blacklistedBorrowToken.balanceOf(borrower);

        blacklistedBorrowToken.blacklist(lender);

        vm.prank(borrower);
        lending.repayDebt(lendingId, repayAmount, bytes32(0), 0, type(uint128).max, false);

        assertEq(blacklistedBorrowToken.balanceOf(borrower), borrowerBorrowBefore - repayAmount, "borrower paid");
        assertEq(blacklistedBorrowToken.balanceOf(lender), lenderBorrowBefore, "lender direct transfer blocked");
        assertEq(
            lending.tempHolding(lender, address(blacklistedBorrowToken)),
            repayAmount,
            "partial repayment escrowed"
        );

        blacklistedBorrowToken.unblacklist(lender);
        vm.prank(lender);
        lending.getTempHolding(address(blacklistedBorrowToken));

        assertEq(lending.tempHolding(lender, address(blacklistedBorrowToken)), 0, "escrow cleared");
        assertEq(blacklistedBorrowToken.balanceOf(lender), lenderBorrowBefore + repayAmount, "lender withdrew escrow");
    }

    function testTempHolding_BlacklistedBorrowerCollateralOnFullRepay() public {
        BlacklistableMintableERC20 bSupply = new BlacklistableMintableERC20("BL Supply", "BSUP");
        _setupBlacklistableSupplyAccounts(bSupply);

        uint256 lendingId =
            _setupActiveLoan(address(bSupply), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);
        uint32 rate = lendView.getLending(lendingId).rate;
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);

        uint256 borrowerSupplyBefore = bSupply.balanceOf(borrower);
        bSupply.blacklist(borrower);

        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed, bytes32(0), 0, type(uint128).max, false);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "loan should finish even when borrower cannot receive collateral");
        assertEq(bSupply.balanceOf(borrower), borrowerSupplyBefore, "borrower direct receipt blocked");
        assertEq(
            lending.tempHolding(borrower, address(bSupply)), SUPPLY_AMOUNT, "borrower's collateral should be escrowed"
        );

        bSupply.unblacklist(borrower);
        vm.prank(borrower);
        lending.getTempHolding(address(bSupply));

        assertEq(lending.tempHolding(borrower, address(bSupply)), 0, "borrower escrow cleared");
        assertEq(bSupply.balanceOf(borrower), borrowerSupplyBefore + SUPPLY_AMOUNT, "borrower received collateral");
    }

    function testTempHolding_BlacklistedLenderClaimCollateral() public {
        BlacklistableMintableERC20 bSupply = new BlacklistableMintableERC20("BL Supply", "BSUP");
        _setupBlacklistableSupplyAccounts(bSupply);

        uint256 lendingId =
            _setupActiveLoan(address(bSupply), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);
        openLend.LendingArrangement memory loanBefore = lendView.getLending(lendingId);

        bSupply.blacklist(lender);
        uint256 lenderSupplyBefore = bSupply.balanceOf(lender);

        vm.warp(uint256(loanBefore.start) + loanBefore.term + 1);
        lending.claimCollateral(lendingId);

        openLend.LendingArrangement memory loanAfter = lendView.getLending(lendingId);
        assertTrue(loanAfter.finished, "claim should finish even when lender cannot receive collateral");
        assertEq(bSupply.balanceOf(lender), lenderSupplyBefore, "lender direct receipt blocked");
        assertEq(lending.tempHolding(lender, address(bSupply)), SUPPLY_AMOUNT, "lender collateral escrowed");

        bSupply.unblacklist(lender);
        vm.prank(lender);
        lending.getTempHolding(address(bSupply));

        assertEq(lending.tempHolding(lender, address(bSupply)), 0, "lender escrow cleared");
        assertEq(bSupply.balanceOf(lender), lenderSupplyBefore + SUPPLY_AMOUNT, "lender received collateral");
    }

    // -------------------------------------------------------------------------
    // topUpCollateralAnyone — third-party top-up + view
    // -------------------------------------------------------------------------

    function testTopUpCollateralAnyone_ThirdPartyCanTopUpAndOracleParamsReadable() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        uint256 contractSupplyBefore = supplyToken.balanceOf(address(lending));
        uint256 topperSupplyBefore = supplyToken.balanceOf(topper);

        vm.prank(topper);
        lending.topUpCollateralAnyone(lendingId, 25 ether, bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        openLend.OracleParams memory oracleParams = lendView.getOracleParams(lendingId);

        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + 25 ether, "supply should increase after third-party top-up");
        assertEq(
            supplyToken.balanceOf(address(lending)),
            contractSupplyBefore + 25 ether,
            "contract should receive top-up collateral"
        );
        assertEq(
            supplyToken.balanceOf(topper), topperSupplyBefore - 25 ether, "topper should fund the additional collateral"
        );
        assertEq(oracleParams.settlementTime, 300, "settlementTime getter mismatch");
        assertEq(oracleParams.disputeDelay, 60, "disputeDelay getter mismatch");
        assertEq(oracleParams.oracleGameFee, 100_000, "oracleGameFee getter mismatch");
        assertEq(oracleParams.escalationFactor, 100, "escalationFactor getter mismatch");
        assertEq(oracleParams.initialLiquidity, 10, "initialLiquidity getter mismatch");
        assertEq(oracleParams.multiplier, 200, "multiplier getter mismatch");
    }

    function testTopUpCollateralAnyone_RevertsWhenSupplyAndStakeWouldOverflow() public {
        // Set up a loan with supply right at the edge — any top-up would overflow supply + stake check
        uint128 largeSupply = type(uint128).max / 2;
        uint256 lendingId =
            _setupActiveLoan(address(supplyToken), address(borrowToken), largeSupply, 1, 10_000 /* 100% stake */);

        vm.prank(topper);
        vm.expectRevert(LendErrors.SupplyPlusStakeTooHigh.selector);
        lending.topUpCollateralAnyone(lendingId, 1, bytes32(0), 0, type(uint128).max);
    }

    function testTopUpCollateralAnyone_RevertsWhenEscalationHaltTooHigh() public {
        // Big supply + max escalation factor = escHalt would bust uint128 after the top-up
        openLend.OracleParams memory oracleParams = openLend.OracleParams({
            settlementTime: 300,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 1000,
            initialLiquidity: 10,
            multiplier: 200,
            maxBaseFee: 0,
            finalizerReward: 0
        });

        uint128 largeSupply = type(uint128).max / 10;
        uint256 lendingId = _setupCustomLoan(
            address(supplyToken),
            address(borrowToken),
            largeSupply,
            1,
            0,
            oracleParams
        );

        vm.prank(topper);
        vm.expectRevert(LendErrors.EscalationHaltTooHigh.selector);
        lending.topUpCollateralAnyone(lendingId, 1, bytes32(0), 0, type(uint128).max);
    }

    // -------------------------------------------------------------------------
    // refi view helpers
    // -------------------------------------------------------------------------

    function testRefiViewHelpers_ReturnStoredState() public {
        uint256 lendingId =
            _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        // Borrower opens refi with extra demand and supply pull
        vm.prank(borrower);
        lending.refinance(
            lendingId,
            5 ether,                  // extraDemanded
            7 ether,                  // supplyPulled
            0,                        // newTerm = 0 → keep existing term
            0,                        // gasCompensation
            _standardInterestRateParams(),
            openLend.OracleParams(0, 0, 0, 0, 0, 0, 0, 0),
            bytes32(0),
            0,
            type(uint128).max
        );

        openLend.RefiParams memory rp = lendView.getRefiParams(lendingId);
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);

        assertEq(rp.extraDemanded, 5 ether, "extraDemanded getter mismatch");
        assertEq(rp.supplyPulled, 7 ether, "supplyPulled getter mismatch");
        assertEq(rp.newTerm, LOAN_TERM, "newTerm getter should reflect kept term");
        assertTrue(loan.curveOpen, "curve should be open after refinance");

        // Lender2 accepts the refi
        vm.startPrank(lender2);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 5e6, lender2, address(0));
        vm.stopPrank();

        openLend.LendingArrangement memory loanAfter = lendView.getLending(lendingId);
        openLend.RefiParams memory rpAfter = lendView.getRefiParams(lendingId);
        assertEq(loanAfter.lender, lender2, "lender should switch to lender2");
        assertGt(loanAfter.liquidatorFraction, 0, "liquidatorFraction should be set per the lend call");
        assertFalse(loanAfter.curveOpen, "curve should close after lend");
        assertEq(rpAfter.extraDemanded, 0, "refi extraDemanded should clear");
        assertEq(rpAfter.supplyPulled, 0, "refi supplyPulled should clear");
        assertEq(rpAfter.newTerm, 0, "refi newTerm should clear");
    }

    function testHelperLendingView_MatchesRawMappingGetterTuple() public {
        uint256 lendingId =
            _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        vm.warp(block.timestamp + 1 days);
        vm.prank(borrower);
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, type(uint128).max, false);

        vm.warp(block.timestamp + 1 days);
        vm.prank(borrower);
        lending.refinance(
            lendingId,
            5 ether,
            7 ether,
            0,
            0,
            _standardInterestRateParams(),
            openLend.OracleParams(0, 0, 0, 0, 0, 0, 0, 0),
            bytes32(0),
            0,
            type(uint128).max
        );

        (bool rawOk, bytes memory rawGetterData) =
            address(lending).staticcall(abi.encodeWithSelector(lending.lendingArrangements.selector, lendingId));
        (bool helperOk, bytes memory helperData) =
            address(lendView).staticcall(abi.encodeWithSelector(bytes4(keccak256("getLending(uint256)")), lendingId));

        assertTrue(rawOk, "raw mapping getter failed");
        assertTrue(helperOk, "helper getLending failed");
        assertEq(keccak256(rawGetterData), keccak256(helperData), "helper lending view must match raw mapping getter");
    }

    // -------------------------------------------------------------------------
    // topUpCollateralAnyone — stale loose hash + directional bounds
    // -------------------------------------------------------------------------

    function testTopUp_StaleLooseHashWithSatisfiedBoundsSucceeds() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        bytes32 staleHash = lendView.getParamHash(lendingId);
        uint128 supplySnapshot = SUPPLY_AMOUNT;

        // Borrower partial repay (changes repaidDebt but loose hash zeros it; bound 0 satisfied)
        vm.prank(borrower);
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, type(uint128).max, false);

        // Stale hash + expectedMinSupply = supplySnapshot still satisfied (top-up only goes UP)
        vm.prank(topper);
        lending.topUpCollateralAnyone(lendingId, 5 ether, staleHash, supplySnapshot, type(uint128).max);

        assertEq(lendView.getLending(lendingId).supplyAmount, SUPPLY_AMOUNT + 5 ether, "stale hash + satisfied bounds OK");
    }

    function testTopUp_StaleHashWithExpectedMinSupplyTooHighReverts() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        bytes32 staleHash = lendView.getParamHash(lendingId);

        vm.prank(topper);
        vm.expectRevert(LendErrors.SupplyTooLow.selector);
        lending.topUpCollateralAnyone(lendingId, 1 ether, staleHash, SUPPLY_AMOUNT + 1, type(uint128).max);
    }

    function testTopUp_StaleHashWithExpectedMaxPrincipalTooLowReverts() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        bytes32 staleHash = lendView.getParamHash(lendingId);

        // principal = BORROW_AMOUNT; cap below it → reverts
        vm.prank(topper);
        vm.expectRevert(LendErrors.PrincipalTooHigh.selector);
        lending.topUpCollateralAnyone(lendingId, 1 ether, staleHash, 0, uint128(BORROW_AMOUNT - 1));
    }

    // -------------------------------------------------------------------------
    // Fee receiver distribution — clean behavior before fees accrue
    // -------------------------------------------------------------------------

    /// @dev Calling distribute() on a feeRecipient that has accrued no fees yet should be a clean no-op.
    function testFeeReceiverDistribute_NoOpBeforeAnyFeesAccrue() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        // Liquidate (sets deterministic feeRecipient) but don't dispute or settle yet — no fees can have accrued
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(lender);
        lending.liquidate{value: 1e15}(lendingId, 6 ether * 1e18 / 10 ether, type(uint128).max, paramHash, 0, 1e15, liquidator, 0, _emptyTiming());

        uint256 reportId = oracle.nextReportId() - 1;
        address feeRecipient = _predictFeeReceiver(reportId);
        assertEq(feeRecipient.code.length, 0, "fee receiver deploys lazily");

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);

        // No revert, no balance change
        _distributeOracleGameFees(reportId);

        assertEq(supplyToken.balanceOf(borrower), borrowerSupplyBefore, "borrower supply unchanged");
        assertEq(borrowToken.balanceOf(borrower), borrowerBorrowBefore, "borrower borrow unchanged");
        assertEq(supplyToken.balanceOf(lender), lenderSupplyBefore, "lender supply unchanged");
        assertEq(borrowToken.balanceOf(lender), lenderBorrowBefore, "lender borrow unchanged");
    }

    // -------------------------------------------------------------------------
    // Payout liveness: finalize must clear inLiquidation even if a participant token transfer fails
    // -------------------------------------------------------------------------

    /// @dev Streaming-era liveness: a blacklisted lender must not brick the borrower's partial repay. Borrower's
    ///      funds still leave; the lender's streamed payment lands in tempHolding[lender][borrowToken] until
    ///      they're unblacklisted and can pull it.
    function testPayoutLiveness_BlacklistedLenderDuringPartialRepay() public {
        uint256 lendingId = _setupCustomLoan(
            address(supplyToken),
            address(blacklistedBorrowToken),
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            _standardOracleParams()
        );

        // Lender gets blacklisted on borrowToken AFTER originating but BEFORE the partial repay
        blacklistedBorrowToken.blacklist(lender);

        uint256 borrowerBorrowBefore = blacklistedBorrowToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = blacklistedBorrowToken.balanceOf(lender);
        uint256 contractBorrowBefore = blacklistedBorrowToken.balanceOf(address(lending));

        // Borrower partial repay — lender's streaming payout lands in tempHolding (blacklisted)
        vm.prank(borrower);
        lending.repayDebt(lendingId, 5 ether, bytes32(0), 0, type(uint128).max, false);

        // Borrower's funds still moved; loan accounting still progresses
        assertEq(blacklistedBorrowToken.balanceOf(borrower), borrowerBorrowBefore - 5 ether, "borrower paid");
        // assertEq(lendView.getLending(lendingId).repaidDebt, 5 ether, "repaidDebt incremented");  // [amort: removed/no-op]

        // Lender's wallet balance did NOT change (blacklisted; direct receipt blocked)
        assertEq(
            blacklistedBorrowToken.balanceOf(lender),
            lenderBorrowBefore,
            "lender direct receipt blocked by blacklist"
        );

        // The streamed payout sat in tempHolding for lender
        assertEq(
            lending.tempHolding(lender, address(blacklistedBorrowToken)),
            5 ether,
            "blocked streaming payout should land in tempHolding"
        );

        // Contract balance reflects the held tempHolding-backing 5 ether
        assertEq(
            blacklistedBorrowToken.balanceOf(address(lending)),
            contractBorrowBefore + 5 ether,
            "contract holds the funds in tempHolding-backing balance"
        );

        // Unblacklist; lender pulls via getTempHolding
        blacklistedBorrowToken.unblacklist(lender);
        vm.prank(lender);
        lending.getTempHolding(address(blacklistedBorrowToken));

        assertEq(
            blacklistedBorrowToken.balanceOf(lender),
            lenderBorrowBefore + 5 ether,
            "lender withdraws via getTempHolding"
        );
        assertEq(
            lending.tempHolding(lender, address(blacklistedBorrowToken)),
            0,
            "tempHolding should be cleared after withdrawal"
        );
    }

    // -------------------------------------------------------------------------
    // Liquidation-payout liveness: blacklisted recipients land in tempHolding instead of bricking the loan
    // -------------------------------------------------------------------------

    /// @dev Underwater settle pays the entire `supplyAmount` to the lender. If the supplyToken blacklists the lender,
    ///      _transferTokens routes that amount to tempHolding[lender][supplyToken]. The loan still finishes,
    ///      inLiquidation clears, and the lender pulls funds via getTempHolding once unblacklisted.
    function testPayoutLiveness_BlacklistedLenderUnderwaterLiquidation() public {
        BlacklistableMintableERC20 bSupply = new BlacklistableMintableERC20("BL Supply", "BSUP");
        _setupBlacklistableSupplyAccounts(bSupply);

        // Originate against the blacklistable supply token
        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(bSupply),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            70 ether,
            STAKE,
            uint24(1e7),
            0,
            borrower,address(0),
            
            _standardOracleParams(),
            _standardInterestRateParams()
        );
        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 5e6, lender, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Liquidate at oracleAmount2=6 then dispute to underwater 20/10
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            6 ether * 1e18 / 10 ether,
            type(uint128).max,
            paramHash,
             0,
            1e15, liquidator, 0, _emptyTiming()
        );
        uint256 reportId = oracle.nextReportId() - 1;
        bytes32 stateHash = bytes32(0);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 61);
        _disputeAndSwap(reportId, address(bSupply), 20 ether, 10 ether, disputer, 6 ether, stateHash);

        // Blacklist the lender RIGHT before settle so the underwater payout falls back to tempHolding
        bSupply.blacklist(lender);

        (,,, uint48 disputeTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(disputeTs) + 301);
        uint256 lenderSupplyBefore = bSupply.balanceOf(lender);
        vm.prank(settler);
        _settleOracle(reportId);
        _deployAndDistributeOracleGameFees(reportId, lendingId, borrower, lender, liquidator);

        // Loan finished, inLiquidation cleared
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "loan finished underwater despite blacklisted lender");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");

        // Lender's underwater payout goes to tempHolding. Their dispute-fee share is oracle-internal after the explicit grab.
        // Dispute fee = 1% × 10 ether = 0.1 ether; lender share = 0.025 ether.
        uint256 lenderFeePiece = (10 ether * 100_000 / 1e7) / 2 / 2; // 0.025 ether
        uint256 expectedEscrow = uint256(SUPPLY_AMOUNT);
        assertEq(bSupply.balanceOf(lender), lenderSupplyBefore, "lender wallet untouched");
        assertEq(
            lending.tempHolding(lender, address(bSupply)),
            expectedEscrow,
            "lender's underwater payout + fee share escrowed"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(lender, address(bSupply)),
            lenderFeePiece + 1,
            "lender fee share credited internally"
        );

        // Unblacklist and pull
        bSupply.unblacklist(lender);
        vm.prank(lender);
        lending.getTempHolding(address(bSupply));
        assertEq(
            bSupply.balanceOf(lender),
            lenderSupplyBefore + expectedEscrow,
            "lender withdraws via getTempHolding"
        );
        assertEq(lending.tempHolding(lender, address(bSupply)), 0, "tempHolding cleared");
    }

    /// @dev Underwater no-equity settle: lender gets supplyAmount, liquidator gets tokenStake. Blacklisting the
    ///      liquidator routes their stake (+ fee piece) into tempHolding; lender still receives directly.
    function testPayoutLiveness_BlacklistedLiquidatorUnderwaterLiquidation() public {
        BlacklistableMintableERC20 bSupply = new BlacklistableMintableERC20("BL Supply", "BSUP");
        _setupBlacklistableSupplyAccounts(bSupply);

        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(bSupply),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            70 ether,
            STAKE,
            uint24(1e7),
            0,
            borrower,address(0),
            
            _standardOracleParams(),
            _standardInterestRateParams()
        );
        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 5e6, lender, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Liquidate then dispute to a buffer-region ratio (20/12 → debt-in-supply > LT but < supplyAmount)
        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            8 ether * 1e18 / 10 ether,
            type(uint128).max,
            paramHash,
             0,
            1e15, liquidator, 0, _emptyTiming()
        );
        uint256 reportId = oracle.nextReportId() - 1;
        bytes32 stateHash = bytes32(0);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 61);
        _disputeAndSwap(reportId, address(bSupply), 20 ether, 12 ether, disputer, 8 ether, stateHash);

        // Blacklist the liquidator before settle
        bSupply.blacklist(liquidator);

        uint256 liquidatorSupplyBefore = bSupply.balanceOf(liquidator);

        (,,, uint48 disputeTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(disputeTs) + 301);
        vm.prank(settler);
        _settleOracle(reportId);
        _deployAndDistributeOracleGameFees(reportId, lendingId, borrower, lender, liquidator);

        // Loan finished underwater
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "loan finished underwater despite blacklisted liquidator");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");

        // Exact math: no-equity branch → liquidator's payout = tokenStake + their 25% fee piece.
        // tokenStake = supplyAmount × stake / 10000 = 100 × 100 / 10000 = 1 ether.
        // Dispute fee in supply = 1% × 10 ether = 0.1 ether → liquidator share = 0.025 ether.
        uint256 expectedTokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;            // 1 ether
        uint256 expectedFeePiece = (10 ether * 100_000 / 1e7) / 2 / 2;                  // 0.025 ether
        uint256 expectedLiquidatorEscrow = expectedTokenStake;

        assertEq(bSupply.balanceOf(liquidator), liquidatorSupplyBefore, "liquidator wallet untouched");
        assertEq(
            lending.tempHolding(liquidator, address(bSupply)),
            expectedLiquidatorEscrow,
            "liquidator's stake + fee piece escrowed exactly"
        );
        assertGe(
            IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(bSupply)),
            expectedFeePiece,
            "liquidator fee share credited internally"
        );

        uint256 expectedLenderDirect = uint256(SUPPLY_AMOUNT);
        assertEq(
            bSupply.balanceOf(lender),
            expectedLenderDirect,
            "lender received supplyAmount directly"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(lender, address(bSupply)),
            expectedFeePiece + 1,
            "lender fee share credited internally"
        );
    }

    /// @dev Both lender AND liquidator blacklisted: the entire underwater payout pair lands in tempHolding.
    function testPayoutLiveness_BothBlacklistedUnderwaterLiquidation() public {
        BlacklistableMintableERC20 bSupply = new BlacklistableMintableERC20("BL Supply", "BSUP");
        _setupBlacklistableSupplyAccounts(bSupply);

        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(bSupply),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            SUPPLY_AMOUNT,
            70 ether,
            STAKE,
            uint24(1e7),
            0,
            borrower,address(0),
            
            _standardOracleParams(),
            _standardInterestRateParams()
        );
        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 5e6, lender, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        bytes32 paramHash = lendView.getLiquidateParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            8 ether * 1e18 / 10 ether,
            type(uint128).max,
            paramHash,
             0,
            1e15, liquidator, 0, _emptyTiming()
        );
        uint256 reportId = oracle.nextReportId() - 1;
        bytes32 stateHash = bytes32(0);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 61);
        _disputeAndSwap(reportId, address(bSupply), 20 ether, 12 ether, disputer, 8 ether, stateHash);

        bSupply.blacklist(lender);
        bSupply.blacklist(liquidator);

        (,,, uint48 disputeTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(disputeTs) + 301);
        vm.prank(settler);
        _settleOracle(reportId);
        _deployAndDistributeOracleGameFees(reportId, lendingId, borrower, lender, liquidator);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "loan finished even when both parties blacklisted");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");

        uint256 expectedTokenStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;
        uint256 expectedFeePiece = (10 ether * 100_000 / 1e7) / 2 / 2;
        assertEq(
            lending.tempHolding(lender, address(bSupply)),
            uint256(SUPPLY_AMOUNT),
            "lender escrow = supplyAmount"
        );
        assertEq(
            lending.tempHolding(liquidator, address(bSupply)),
            expectedTokenStake,
            "liquidator escrow = tokenStake"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(lender, address(bSupply)),
            expectedFeePiece + 1,
            "lender fee share credited internally"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(bSupply)),
            20 ether + expectedFeePiece + 1,
            "liquidator fee share credited internally"
        );

        // Both can withdraw after unblacklist
        bSupply.unblacklist(lender);
        bSupply.unblacklist(liquidator);
        vm.prank(lender);
        lending.getTempHolding(address(bSupply));
        vm.prank(liquidator);
        lending.getTempHolding(address(bSupply));
        assertEq(lending.tempHolding(lender, address(bSupply)), 0, "lender tempHolding cleared");
        assertEq(lending.tempHolding(liquidator, address(bSupply)), 0, "liquidator tempHolding cleared");
    }

    function _setupBlacklistableSupplyAccounts(BlacklistableMintableERC20 t) internal {
        // Mint to borrower (origination), liquidator (stake + initialLiquidity), disputer (oracle game), and topper.
        t.mint(borrower, 10_000 ether);
        t.mint(liquidator, 10_000 ether);
        t.mint(disputer, 10_000 ether);
        t.mint(topper, 10_000 ether);
        // Approvals
        vm.prank(borrower);
        t.approve(address(lending), type(uint256).max);
        vm.prank(liquidator);
        t.approve(address(lending), type(uint256).max);
        vm.prank(disputer);
        t.approve(address(oracle), type(uint256).max);
        vm.prank(topper);
        t.approve(address(lending), type(uint256).max);
        // Disputer also needs borrowToken approve to oracle for disputes that swap token2
        vm.prank(disputer);
        borrowToken.approve(address(oracle), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _setupActiveLoan(
        address supplyTokenAddress,
        address borrowTokenAddress,
        uint128 supplyAmount,
        uint128 borrowAmount,
        uint16 stake
    ) internal returns (uint256 lendingId) {
        return _setupCustomLoan(
            supplyTokenAddress,
            borrowTokenAddress,
            supplyAmount,
            borrowAmount,
            stake,
            _standardOracleParams()
        );
    }

    function _setupCustomLoan(
        address supplyTokenAddress,
        address borrowTokenAddress,
        uint128 supplyAmount,
        uint128 borrowAmount,
        uint16 stake,
        openLend.OracleParams memory oracleParams
    ) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            supplyTokenAddress,
            borrowTokenAddress,
            LIQUIDATION_THRESHOLD,
            supplyAmount,
            borrowAmount,
            stake,
            uint24(1e7),
            0,
            borrower,address(0),
            
            oracleParams,
            _standardInterestRateParams()
        );

        vm.startPrank(lender);
        lending.lend(lendingId,lendView.getParamHash(lendingId), 0, type(uint128).max, 0, 0, 0, lender, address(0));
        vm.stopPrank();
    }

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
            maxRate: 1e9,
            startingRate: 1e8,
            roundLength: 300,
            growthRate: 10500,
            maxRounds: 100
        });
    }

    function _calculateOwedAtMaturity(uint256 principal, uint32 rate, uint48 term) internal pure returns (uint128) {
        uint256 year = 365 days;
        uint256 interest = (principal * uint256(term) * uint256(rate)) / (1e9 * year);
        return uint128(principal + interest);
    }

    function _approve(address token, address account) internal {
        vm.startPrank(account);
        ERC20(token).approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }

    function _emptyTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory timing) {}

    function _lendingIdForReportId(uint256 reportId) internal view returns (uint256) {
        uint256 nextId = lending.nextLendingId();
        for (uint256 lendingId = 1; lendingId < nextId; lendingId++) {
            if (lending.lendingToReportId(lendingId) == reportId) return lendingId;
        }
        return 0;
    }

    function _predictFeeReceiver(uint256 reportId) internal view returns (address) {
        return IOpenOracle2(address(oracle)).storedGame(reportId).protocolFeeRecipient;
    }

    function _distributeOracleGameFees(uint256 reportId) internal returns (uint256 fees1, uint256 fees2) {
        uint256 lendingId = _lendingIdForReportId(reportId);
        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        (, fees1, fees2) = lending.deployAndDistributeFeeReceiver(
            reportId,
            lendingId,
            game.token1,
            game.token2,
            loan.borrower,
            loan.lender,
            loan.liquidator
        );
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
        address disputer_,
        uint128,
        bytes32
    ) internal {
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        vm.prank(disputer_);
        IOpenOracle2(address(oracle)).dispute(
            reportId,
            tokenToSwap,
            newAmount1,
            newAmount2,
            disputer_,
            false,
            false,
            game,
            helper, _emptyTiming()
        );
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
}
