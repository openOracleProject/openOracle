// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/openLendV3.sol";
import "../../src/OpenOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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
    OpenOracle internal oracle;
    MintableERC20 internal supplyToken;
    MintableERC20 internal borrowToken;
    BlacklistableMintableERC20 internal blacklistedBorrowToken;

    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal lender2 = address(0x3);
    address internal topper = address(0x4);

    uint128 internal constant SUPPLY_AMOUNT = 100 ether;
    uint128 internal constant BORROW_AMOUNT = 50 ether;
    uint48 internal constant LOAN_TERM = 30 days;
    uint24 internal constant LIQUIDATION_THRESHOLD = 8e6;
    uint16 internal constant STAKE = 100;

    function setUp() public {
        oracle = new OpenOracle();
        lending = new openLend(IOpenOracle(address(oracle)));

        supplyToken = new MintableERC20("Supply Token", "SUP");
        borrowToken = new MintableERC20("Borrow Token", "BOR");
        blacklistedBorrowToken = new BlacklistableMintableERC20("Blacklist Borrow Token", "BBOR");

        address[4] memory accounts = [borrower, lender, lender2, topper];
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
        uint32 rate = lending.getLending(lendingId).rate;
        uint128 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, rate, LOAN_TERM);

        uint256 lenderBorrowBefore = blacklistedBorrowToken.balanceOf(lender);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        // Blacklist the lender so the contract->lender payout falls back to tempHolding
        blacklistedBorrowToken.blacklist(lender);

        vm.prank(borrower);
        lending.repayDebt(lendingId, totalOwed, bytes32(0), 0, 0);

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
            "lender should recover withheld funds"
        );
    }

    // -------------------------------------------------------------------------
    // topUpCollateralAnyone — third-party top-up + view
    // -------------------------------------------------------------------------

    function testTopUpCollateralAnyone_ThirdPartyCanTopUpAndOracleParamsReadable() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        uint256 contractSupplyBefore = supplyToken.balanceOf(address(lending));
        uint256 topperSupplyBefore = supplyToken.balanceOf(topper);

        vm.prank(topper);
        lending.topUpCollateralAnyone(lendingId, 25 ether, bytes32(0), 0, 0);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        openLend.OracleParams memory oracleParams = lending.getOracleParams(lendingId);

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
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "supply amount + stake"));
        lending.topUpCollateralAnyone(lendingId, 1, bytes32(0), 0, 0);
    }

    function testTopUpCollateralAnyone_RevertsWhenEscalationHaltTooHigh() public {
        // Big supply + max escalation factor = escHalt would bust uint128 after the top-up
        openLend.OracleParams memory oracleParams = openLend.OracleParams({
            settlementTime: 300,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 1000,
            initialLiquidity: 10,
            multiplier: 200
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
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "escalation halt too high"));
        lending.topUpCollateralAnyone(lendingId, 1, bytes32(0), 0, 0);
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
            _standardInterestRateParams(),
            bytes32(0),
            0,
            0
        );

        openLend.RefiParams memory rp = lending.getRefiParams(lendingId);
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);

        assertEq(rp.extraDemanded, 5 ether, "extraDemanded getter mismatch");
        assertEq(rp.supplyPulled, 7 ether, "supplyPulled getter mismatch");
        assertEq(rp.newTerm, LOAN_TERM, "newTerm getter should reflect kept term");
        assertTrue(loan.curveOpen, "curve should be open after refinance");

        // Lender2 accepts the refi
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, true);

        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        openLend.RefiParams memory rpAfter = lending.getRefiParams(lendingId);
        assertEq(loanAfter.lender, lender2, "lender should switch to lender2");
        assertTrue(loanAfter.allowAnyLiquidator, "allowAnyLiquidator should be set per the lend call");
        assertFalse(loanAfter.curveOpen, "curve should close after lend");
        assertEq(rpAfter.extraDemanded, 0, "refi extraDemanded should clear");
        assertEq(rpAfter.supplyPulled, 0, "refi supplyPulled should clear");
        assertEq(rpAfter.newTerm, 0, "refi newTerm should clear");
    }

    // -------------------------------------------------------------------------
    // topUpCollateralAnyone — stale loose hash + directional bounds
    // -------------------------------------------------------------------------

    function testTopUp_StaleLooseHashWithSatisfiedBoundsSucceeds() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        bytes32 staleHash = lending.getParamHash(lendingId);
        uint128 supplySnapshot = SUPPLY_AMOUNT;

        // Borrower partial repay (changes repaidDebt but loose hash zeros it; bound 0 satisfied)
        vm.prank(borrower);
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, 0);

        // Stale hash + expectedMinSupply = supplySnapshot still satisfied (top-up only goes UP)
        vm.prank(topper);
        lending.topUpCollateralAnyone(lendingId, 5 ether, staleHash, supplySnapshot, 0);

        assertEq(lending.getLending(lendingId).supplyAmount, SUPPLY_AMOUNT + 5 ether, "stale hash + satisfied bounds OK");
    }

    function testTopUp_StaleHashWithExpectedMinSupplyTooHighReverts() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        bytes32 staleHash = lending.getParamHash(lendingId);

        vm.prank(topper);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "supply too low"));
        lending.topUpCollateralAnyone(lendingId, 1 ether, staleHash, SUPPLY_AMOUNT + 1, 0);
    }

    function testTopUp_StaleHashWithExpectedRepaidDebtMinTooHighReverts() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        bytes32 staleHash = lending.getParamHash(lendingId);

        // No repayments yet, so repaidDebt = 0; require 1 → reverts
        vm.prank(topper);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "repaid debt too low"));
        lending.topUpCollateralAnyone(lendingId, 1 ether, staleHash, 0, 1);
    }

    // -------------------------------------------------------------------------
    // grabOracleGameFeesAny — clean behavior before fees accrue
    // -------------------------------------------------------------------------

    /// @dev Calling grabOracleGameFeesAny on a feeRecipient that has accrued no fees yet should be a clean no-op.
    function testGrabOracleGameFeesAny_NoOpBeforeAnyFeesAccrue() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), SUPPLY_AMOUNT, BORROW_AMOUNT, STAKE);

        // Liquidate (deploys feeRecipient) but don't dispute or settle yet — no fees can have accrued
        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(lender);
        lending.liquidate{value: 1e15}(lendingId, 8 ether * 1e18 / 10 ether, type(uint128).max, paramHash, 0);

        address feeRecipient = lending.getLending(lendingId).feeRecipient;
        assertTrue(feeRecipient != address(0), "fee receiver deployed by liquidate");

        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderSupplyBefore = supplyToken.balanceOf(lender);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);

        // No revert, no balance change
        lending.grabOracleGameFeesAny(lendingId, feeRecipient);

        assertEq(supplyToken.balanceOf(borrower), borrowerSupplyBefore, "borrower supply unchanged");
        assertEq(borrowToken.balanceOf(borrower), borrowerBorrowBefore, "borrower borrow unchanged");
        assertEq(supplyToken.balanceOf(lender), lenderSupplyBefore, "lender supply unchanged");
        assertEq(borrowToken.balanceOf(lender), lenderBorrowBefore, "lender borrow unchanged");
    }

    // -------------------------------------------------------------------------
    // Callback liveness: onSettle must clear inLiquidation even if a participant token transfer fails
    // -------------------------------------------------------------------------

    /// @dev openOracle uses a low-level call on `onSettle` and DOES NOT revert settlement on callback failure.
    ///      So onSettle's internal _transferTokens must be liveness-safe: a blacklisted recipient should not brick
    ///      the loan in `inLiquidation` forever. The blacklisted recipient's payout lands in tempHolding instead.
    function testCallbackLiveness_BlacklistedLenderUnderwaterLiq() public {
        // Set up a loan where lender is the blacklist-token recipient
        // Borrower funds: supplyToken collateral; loan is borrowToken-denominated.
        // For this test we make borrowToken the blacklisted one so the lender's repaidDebt payout fails.
        // Origination loan in (supplyToken supply, blacklistedBorrowToken borrow):
        address disputer = address(0xD15);
        supplyToken.mint(disputer, 10_000 ether);
        blacklistedBorrowToken.mint(disputer, 10_000 ether);
        vm.prank(disputer);
        blacklistedBorrowToken.approve(address(oracle), type(uint256).max);
        vm.prank(disputer);
        supplyToken.approve(address(oracle), type(uint256).max);

        uint256 lendingId = _setupCustomLoan(
            address(supplyToken),
            address(blacklistedBorrowToken),
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            _standardOracleParams()
        );

        // Borrower pays a partial debt so lender has a payout to receive in onSettle's underwater branch
        vm.prank(borrower);
        lending.repayDebt(lendingId, 5 ether, bytes32(0), 0, 0);

        vm.warp(block.timestamp + 10 days);

        // Liquidate
        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(lender);
        lending.liquidate{value: 1e15}(
            lendingId,
            6 ether * 1e18 / 10 ether, // priceRatio targeting oracleAmount2 = 6
            type(uint128).max,
            paramHash,
            0
        );

        // Drive to underwater via dispute
        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);
        vm.warp(block.timestamp + 60 + 1);
        vm.prank(disputer);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 10 ether, disputer, 6 ether, stateHash);

        // Blacklist the lender BEFORE settlement so the borrowToken payout (repaidDebt) to lender fails
        blacklistedBorrowToken.blacklist(lender);

        // Settle — onSettle MUST clear inLiquidation even though the lender's repaidDebt transfer fails
        vm.warp(block.timestamp + 300 + 1);
        vm.prank(address(0xCAFE));
        oracle.settle(reportId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertFalse(loan.inLiquidation, "onSettle must clear inLiquidation despite failing recipient transfer");
        assertTrue(loan.finished, "underwater liq should still finish the loan");

        // The failed repaidDebt payout lands in tempHolding for the lender
        assertEq(
            lending.tempHolding(lender, address(blacklistedBorrowToken)),
            5 ether,
            "blocked repaidDebt payout should land in tempHolding"
        );

        // After unblacklisting, lender can pull it
        blacklistedBorrowToken.unblacklist(lender);
        vm.prank(lender);
        lending.getTempHolding(address(blacklistedBorrowToken));
        assertEq(
            blacklistedBorrowToken.balanceOf(lender) > 0,
            true,
            "lender should recover funds via getTempHolding"
        );
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
            oracleParams,
            _standardInterestRateParams()
        );

        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, false);
    }

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
}
