// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/openLend.sol";
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

contract HelperCoverageTest is Test {
    openLending internal lending;
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
    address internal caller = address(0x7);

    uint128 internal constant SUPPLY_AMOUNT = 100 ether;
    uint128 internal constant BORROW_AMOUNT = 50 ether;
    uint48 internal constant LOAN_TERM = 30 days;
    uint32 internal constant INTEREST_RATE = 1e8;
    uint24 internal constant LIQUIDATION_THRESHOLD = 8e6;
    uint128 internal constant STAKE = 100;

    function setUp() public {
        oracle = new OpenOracle();
        lending = new openLending(IOpenOracle(address(oracle)));

        supplyToken = new MintableERC20("Supply Token", "SUP");
        borrowToken = new MintableERC20("Borrow Token", "BOR");
        blacklistedBorrowToken = new BlacklistableMintableERC20("Blacklist Borrow Token", "BBOR");

        address[7] memory accounts = [borrower, lender, lender2, topper, liquidator, disputer, caller];
        for (uint256 i = 0; i < accounts.length; i++) {
            supplyToken.mint(accounts[i], 10_000 ether);
            borrowToken.mint(accounts[i], 10_000 ether);
            blacklistedBorrowToken.mint(accounts[i], 10_000 ether);
            vm.deal(accounts[i], 100 ether);
        }

        supplyToken.mint(borrower, type(uint128).max);
        supplyToken.mint(topper, type(uint128).max);
        borrowToken.mint(lender, 2);

        _approveLendingToken(address(supplyToken), borrower);
        _approveLendingToken(address(supplyToken), lender);
        _approveLendingToken(address(supplyToken), lender2);
        _approveLendingToken(address(supplyToken), topper);
        _approveLendingToken(address(supplyToken), liquidator);

        _approveLendingToken(address(borrowToken), borrower);
        _approveLendingToken(address(borrowToken), lender);
        _approveLendingToken(address(borrowToken), lender2);
        _approveLendingToken(address(borrowToken), topper);
        _approveLendingToken(address(borrowToken), liquidator);

        _approveLendingToken(address(blacklistedBorrowToken), borrower);
        _approveLendingToken(address(blacklistedBorrowToken), lender);
        _approveLendingToken(address(blacklistedBorrowToken), lender2);

        vm.startPrank(disputer);
        supplyToken.approve(address(oracle), type(uint256).max);
        borrowToken.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    function testTempHolding_FailedTransferCreditsAndCanBeWithdrawn() public {
        uint256 lendingId =
            _setupActiveLoan(address(supplyToken), address(blacklistedBorrowToken), false, _standardOracleParams());
        uint256 totalOwed = _calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM);

        uint256 lenderBorrowBefore = blacklistedBorrowToken.balanceOf(lender);
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);

        blacklistedBorrowToken.blacklist(lender);

        vm.prank(borrower);
        lending.repayDebt(lendingId, uint128(totalOwed));

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

        blacklistedBorrowToken.unblacklist(lender);

        vm.prank(lender);
        lending.getTempHolding(address(blacklistedBorrowToken));

        assertEq(
            lending.tempHolding(lender, address(blacklistedBorrowToken)),
            0,
            "tempHolding should be cleared after withdrawal"
        );
        assertEq(
            blacklistedBorrowToken.balanceOf(lender),
            lenderBorrowBefore + totalOwed,
            "lender should recover withheld funds"
        );
    }

    function testTopUpCollateralAnyone_ThirdPartyCanTopUpAndOracleParamsReadable() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), false, _standardOracleParams());

        uint256 contractSupplyBefore = supplyToken.balanceOf(address(lending));
        uint256 topperSupplyBefore = supplyToken.balanceOf(topper);

        vm.prank(topper);
        lending.topUpCollateralAnyone(lendingId, 25 ether);

        openLending.LendingView memory loan = lending.getLending(lendingId);
        openLending.OracleParams memory oracleParams = lending.getOracleParams(lendingId);

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
        uint128 largeSupply = type(uint128).max / 2;
        uint256 lendingId = _setupCustomLoan(
            address(supplyToken), address(borrowToken), largeSupply, 1, 10_000, false, _standardOracleParams()
        );

        vm.prank(topper);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "supply amount + stake"));
        lending.topUpCollateralAnyone(lendingId, 1);
    }

    function testTopUpCollateralAnyone_RevertsWhenEscalationHaltTooHigh() public {
        openLending.OracleParams memory oracleParams = openLending.OracleParams({
            settlementTime: 300,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 1000,
            initialLiquidity: 10,
            multiplier: 200
        });

        uint128 largeSupply = type(uint128).max / 10;
        uint256 lendingId =
            _setupCustomLoan(address(supplyToken), address(borrowToken), largeSupply, 1, 0, false, oracleParams);

        vm.prank(topper);
        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "escalation halt too high"));
        lending.topUpCollateralAnyone(lendingId, 1);
    }

    function testGrabOracleGameFeesAny_SweepsAccruedFeesAndExposesBeneficiaries() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), true, _standardOracleParams());
        openLending.LendingView memory loanBefore = lending.getLending(lendingId);

        vm.warp(block.timestamp + 10 days);

        vm.prank(liquidator);
        lending.liquidate{value: 1e15}(
            lendingId,
            uint128(loanBefore.supplyAmount),
            uint128(loanBefore.repaidDebt),
            8 ether,
            uint128(loanBefore.borrowAmount),
            loanBefore.start,
            loanBefore.supplyAmount * STAKE / 10000,
            uint128(loanBefore.supplyAmount / 10)
        );

        address feeRecipient = lending.getLending(lendingId).feeRecipient;
        openLending.Beneficiaries memory beneficiaries = lending.getBeneficiaries(lendingId, feeRecipient);
        assertEq(beneficiaries.borrower, borrower, "borrower beneficiary mismatch");
        assertEq(beneficiaries.lender, lender, "lender beneficiary mismatch");
        assertEq(beneficiaries.liquidator, liquidator, "liquidator beneficiary mismatch");

        uint256 reportId = oracle.nextReportId() - 1;
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);

        vm.warp(block.timestamp + 120);
        vm.prank(disputer);
        oracle.disputeAndSwap(reportId, address(supplyToken), 20 ether, 12 ether, disputer, 8 ether, stateHash);

        uint256 feeAccrued = oracle.protocolFees(feeRecipient, address(supplyToken));
        assertGt(feeAccrued, 0, "manual sweep test needs accrued fees");

        uint256 beneficiarySupplyBefore =
            supplyToken.balanceOf(borrower) + supplyToken.balanceOf(lender) + supplyToken.balanceOf(liquidator);

        vm.prank(caller);
        lending.grabOracleGameFeesAny(lendingId, feeRecipient);

        uint256 beneficiarySupplyAfter =
            supplyToken.balanceOf(borrower) + supplyToken.balanceOf(lender) + supplyToken.balanceOf(liquidator);

        assertEq(
            oracle.protocolFees(feeRecipient, address(supplyToken)), 0, "oracle protocol fees should be fully swept"
        );
        assertEq(
            beneficiarySupplyAfter - beneficiarySupplyBefore,
            feeAccrued,
            "beneficiaries should receive the swept fee amount"
        );
    }

    function testGrabOracleGameFeesAny_RevertsForWrongLendingId() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), false, _standardOracleParams());
        address feeRecipient = lending.getLending(lendingId).feeRecipient;

        vm.expectRevert(abi.encodeWithSelector(openLending.InvalidInput.selector, "feeRecipient not for lendingId"));
        lending.grabOracleGameFeesAny(lendingId + 1, feeRecipient);
    }

    function testRefiViewHelpers_ReturnStoredState() public {
        uint256 lendingId = _setupActiveLoan(address(supplyToken), address(borrowToken), false, _standardOracleParams());

        vm.prank(borrower);
        lending.changeRefiParams(lendingId, 5 ether, 7 ether);

        vm.prank(lender2);
        (uint256 refiOfferNumber, uint256 refiNonce) =
            lending.offerRefiBorrow(lendingId, INTEREST_RATE, true, 0, 5 ether, SUPPLY_AMOUNT - 7 ether);

        openLending.RefiLendingOffers memory refiOffer =
            lending.getRefiLendingOffer(lendingId, refiNonce, refiOfferNumber);

        uint256 expectedRefiAmount = _calculateOwedAtMaturity(BORROW_AMOUNT, INTEREST_RATE, LOAN_TERM) + 5 ether;

        assertEq(refiOffer.lender, lender2, "refi lender getter mismatch");
        assertEq(refiOffer.amount, expectedRefiAmount, "refi amount getter mismatch");
        assertEq(refiOffer.repaidDebtAtRefiOfferTime, 0, "refi repaidDebt snapshot mismatch");
        assertEq(refiOffer.rate, INTEREST_RATE, "refi rate getter mismatch");
        assertEq(refiOffer.allowAnyLiquidator, true, "refi allowAnyLiquidator getter mismatch");
        assertFalse(refiOffer.cancelled, "refi should not be cancelled");
        assertFalse(refiOffer.chosen, "refi should not be chosen before acceptance");
        assertFalse(lending.getRefiNonceAccepted(lendingId, refiNonce), "refi nonce should be unset before accept");

        vm.prank(borrower);
        lending.acceptRefiOffer(lendingId, refiOfferNumber, refiNonce);

        assertTrue(lending.getRefiNonceAccepted(lendingId, refiNonce), "refi nonce should be marked accepted");
    }

    function _setupActiveLoan(
        address supplyTokenAddress,
        address borrowTokenAddress,
        bool allowAnyLiquidator,
        openLending.OracleParams memory oracleParams
    ) internal returns (uint256 lendingId) {
        return _setupCustomLoan(
            supplyTokenAddress,
            borrowTokenAddress,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            allowAnyLiquidator,
            oracleParams
        );
    }

    function _setupCustomLoan(
        address supplyTokenAddress,
        address borrowTokenAddress,
        uint128 supplyAmount,
        uint128 borrowAmount,
        uint128 stake,
        bool allowAnyLiquidator,
        openLending.OracleParams memory oracleParams
    ) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            uint48(block.timestamp + 1 hours),
            supplyTokenAddress,
            borrowTokenAddress,
            LIQUIDATION_THRESHOLD,
            supplyAmount,
            borrowAmount,
            stake,
            oracleParams
        );

        vm.prank(lender);
        uint256 offerNumber = lending.offerBorrow(lendingId, borrowAmount, INTEREST_RATE, allowAnyLiquidator);

        vm.prank(borrower);
        lending.acceptOffer(lendingId, offerNumber);
    }

    function _standardOracleParams() internal pure returns (openLending.OracleParams memory) {
        return openLending.OracleParams({
            settlementTime: 300,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 100,
            initialLiquidity: 10,
            multiplier: 200
        });
    }

    function _calculateOwedAtMaturity(uint256 principal, uint32 rate, uint48 term) internal pure returns (uint256) {
        return principal + (principal * uint256(term) * uint256(rate)) / (1e9 * 365 days);
    }

    function _approveLendingToken(address token, address account) internal {
        vm.startPrank(account);
        ERC20(token).approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }
}
