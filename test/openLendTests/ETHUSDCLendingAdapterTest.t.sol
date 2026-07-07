// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";
import {IOpenLend} from "../../src/interfaces/IOpenLend.sol";
import {openLendEthUsdcAdapter1} from "../../src/lend/ETHUSDCLendingAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "../utils/MockERC20.sol";

contract AdapterRejectingLender {
    function approveAndRequest(
        IERC20 token,
        openLendEthUsdcAdapter1 adapter,
        openLendEthUsdcAdapter1.BorrowParams calldata params
    ) external payable returns (uint256 lendingId) {
        token.approve(address(adapter), type(uint256).max);
        lendingId = adapter.requestBorrowAdapter{value: msg.value}(params);
    }

    function approveAndLend(
        IERC20 token,
        openLendEthUsdcAdapter1 adapter,
        openLendEthUsdcAdapter1.LendParams calldata params,
        uint128 amount
    ) external {
        token.approve(address(adapter), type(uint256).max);
        adapter.lendAdapter(params, amount);
    }

    function refinanceThroughAdapter(
        openLendEthUsdcAdapter1 adapter,
        openLendEthUsdcAdapter1.RefiAdapterParams calldata params
    ) external payable {
        adapter.refinanceAdapter{value: msg.value}(params);
    }
}

contract MockDecimalsERC20 is ERC20 {
    uint8 internal immutable customDecimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        customDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AdapterOverpullOpenLend {
    IOpenLend.LendingArrangement internal loan;
    address public immutable WETH;

    constructor(address supplyToken, address borrowToken, address weth_) {
        WETH = weth_;
        loan = IOpenLend.LendingArrangement({
            supplyAmount: 100 ether,
            principal: 50 ether,
            interestAccrued: 0,
            interestRemainder: 0,
            lastTouch: 0,
            liquidatorFraction: 0,
            interestPaid: 0,
            commitmentInterest: 0,
            borrower: address(0xB01),
            term: 7 days,
            start: 0,
            lender: address(0),
            gasCompensation: 0,
            liquidator: address(0),
            liquidationStart: 0,
            gracePeriod: 0,
            supplyToken: supplyToken,
            requestStart: 1,
            liquidationThreshold: 8e6,
            commitmentFraction: 0,
            borrowToken: borrowToken,
            rate: 0,
            stake: 100,
            cancelled: false,
            active: false,
            inLiquidation: false,
            finished: false,
            curveOpen: true,
            refiParams: IOpenLend.RefiParams({
                extraDemanded: 0,
                supplyPulled: 0,
                newTerm: 0,
                oracleParams: IOpenLend.OracleParams({
                    settlementTime: 0,
                    disputeDelay: 0,
                    oracleGameFee: 0,
                    escalationFactor: 0,
                    initialLiquidity: 0,
                    multiplier: 0,
                    maxBaseFee: 0,
                    finalizerReward: 0
                })
            }),
            oracleParams: IOpenLend.OracleParams({
                settlementTime: 10 minutes,
                disputeDelay: 60,
                oracleGameFee: 100_000,
                escalationFactor: 100,
                initialLiquidity: 10,
                multiplier: 200,
                maxBaseFee: 0,
                finalizerReward: 0.001 ether
            }),
            interestRateParams: IOpenLend.InterestRateParams({
                maxRate: 2e8,
                startingRate: 5e7,
                roundLength: 60,
                growthRate: 10500,
                maxRounds: 20
            })
        });
    }

    function lendingArrangements(uint256) external view returns (IOpenLend.LendingArrangement memory) {
        return loan;
    }

    function lend(
        uint256,
        bytes32,
        uint128,
        uint128,
        uint128,
        uint32,
        uint24,
        address,
        address
    ) external {
        IERC20(loan.borrowToken).transferFrom(msg.sender, address(this), uint256(loan.principal) + 1);
    }
}

contract SameTokenOpenLend {
    IOpenLend.LendingArrangement internal loan;
    address public immutable WETH;

    constructor(address token, address weth_) {
        WETH = weth_;
        loan.supplyToken = token;
        loan.borrowToken = token;
        loan.term = 7 days;
        loan.liquidationThreshold = 8e6;
        loan.stake = 100;
        loan.curveOpen = true;
        loan.oracleParams = IOpenLend.OracleParams({
            settlementTime: 10 minutes,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 100,
            initialLiquidity: 10,
            multiplier: 200,
            maxBaseFee: 0,
            finalizerReward: 0.001 ether
        });
        loan.interestRateParams = IOpenLend.InterestRateParams({
            maxRate: 2e8,
            startingRate: 5e7,
            roundLength: 60,
            growthRate: 10500,
            maxRounds: 20
        });
    }

    function lendingArrangements(uint256) external view returns (IOpenLend.LendingArrangement memory) {
        return loan;
    }
}

contract AdapterWethBountyOpenLend {
    IOpenLend.LendingArrangement internal loan;

    address public immutable WETH;
    uint256 internal immutable bounty;

    constructor(address supplyToken, address weth, uint256 bounty_) payable {
        WETH = weth;
        bounty = bounty_;
        loan = IOpenLend.LendingArrangement({
            supplyAmount: 100 ether,
            principal: 50 ether,
            interestAccrued: 0,
            interestRemainder: 0,
            lastTouch: 0,
            liquidatorFraction: 0,
            interestPaid: 0,
            commitmentInterest: 0,
            borrower: address(0xB01),
            term: 7 days,
            start: 1,
            lender: address(0xB02),
            gasCompensation: 0,
            liquidator: address(0),
            liquidationStart: 0,
            gracePeriod: 0,
            supplyToken: supplyToken,
            requestStart: 1,
            liquidationThreshold: 8e6,
            commitmentFraction: 0,
            borrowToken: address(0),
            rate: 5e7,
            stake: 100,
            cancelled: false,
            active: true,
            inLiquidation: false,
            finished: false,
            curveOpen: true,
            refiParams: IOpenLend.RefiParams({
                extraDemanded: 0,
                supplyPulled: 0,
                newTerm: 7 days,
                oracleParams: IOpenLend.OracleParams({
                    settlementTime: 0,
                    disputeDelay: 0,
                    oracleGameFee: 0,
                    escalationFactor: 0,
                    initialLiquidity: 0,
                    multiplier: 0,
                    maxBaseFee: 0,
                    finalizerReward: 0
                })
            }),
            oracleParams: IOpenLend.OracleParams({
                settlementTime: 10 minutes,
                disputeDelay: 60,
                oracleGameFee: 100_000,
                escalationFactor: 100,
                initialLiquidity: 10,
                multiplier: 200,
                maxBaseFee: 0,
                finalizerReward: 0.001 ether
            }),
            interestRateParams: IOpenLend.InterestRateParams({
                maxRate: 2e8,
                startingRate: 5e7,
                roundLength: 60,
                growthRate: 10500,
                maxRounds: 20
            })
        });
    }

    function lendingArrangements(uint256) external view returns (IOpenLend.LendingArrangement memory) {
        return loan;
    }

    function lend(
        uint256,
        bytes32,
        uint128,
        uint128,
        uint128,
        uint32,
        uint24,
        address,
        address
    ) external {
        (bool ok,) = WETH.call{value: bounty}(abi.encodeWithSignature("deposit()"));
        require(ok, "deposit failed");
        IERC20(WETH).transfer(msg.sender, bounty);
    }

    function refinance(
        uint256,
        uint128,
        uint128,
        uint48,
        uint96,
        IOpenLend.InterestRateParams calldata,
        IOpenLend.OracleParams calldata,
        bytes32,
        uint128,
        uint128
    ) external payable {
        (bool ok,) = WETH.call{value: bounty}(abi.encodeWithSignature("deposit()"));
        require(ok, "deposit failed");
        IERC20(WETH).transfer(msg.sender, bounty);
    }

    receive() external payable {}
}

contract ETHUSDCLendingAdapterTest is OpenLendingBaseTest {
    openLendEthUsdcAdapter1 internal adapter;
    openLendEthUsdcAdapter1 internal nativeBorrowAdapter;
    openLendEthUsdcAdapter1 internal nativeSupplyAdapter;

    address internal borrower = address(0xB01);
    address internal lender = address(0xB02);
    address internal lender2 = address(0xB03);
    address internal lender3 = address(0xB04);
    address internal liquidator = address(0xB05);
    address internal disputer = address(0xB06);

    uint128 internal constant SUPPLY_AMOUNT = 100 ether;
    uint128 internal constant BORROW_AMOUNT = 50 ether;
    uint48 internal constant LOAN_TERM = 7 days;
    uint96 internal constant GAS_COMP = 0.01 ether;
    uint96 internal constant SETTLER_REWARD = 0.001 ether;

    function setUp() public {
        _deployCore("Collateral", "COL", "Debt", "DEBT");
        adapter = new openLendEthUsdcAdapter1(address(lending), address(supplyToken), address(borrowToken));
        nativeBorrowAdapter = new openLendEthUsdcAdapter1(address(lending), address(supplyToken), address(0));
        nativeSupplyAdapter = new openLendEthUsdcAdapter1(address(lending), address(0), address(borrowToken));

        address[] memory supplyAccounts = new address[](3);
        supplyAccounts[0] = borrower;
        supplyAccounts[1] = liquidator;
        supplyAccounts[2] = disputer;
        _fundSupply(supplyAccounts, 10_000 ether);

        address[] memory borrowAccounts = new address[](5);
        borrowAccounts[0] = lender;
        borrowAccounts[1] = lender2;
        borrowAccounts[2] = lender3;
        borrowAccounts[3] = liquidator;
        borrowAccounts[4] = disputer;
        _fundBorrow(borrowAccounts, 10_000 ether);

        address[] memory ethAccounts = new address[](6);
        ethAccounts[0] = borrower;
        ethAccounts[1] = lender;
        ethAccounts[2] = lender2;
        ethAccounts[3] = lender3;
        ethAccounts[4] = liquidator;
        ethAccounts[5] = disputer;
        _dealETH(ethAccounts, 100 ether);

        _approveLendingSupply(borrower);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);
        _approveAdapterSupply(borrower);
        _approveAdapterBorrow(lender);
        _approveAdapterBorrow(lender2);
        _approveAdapterBorrow(lender3);
        _approveNativeAdapterSupply(borrower);
    }

    function testRequestBorrowAdapter_PullsCollateralAndRecordsCallerBorrower() public {
        uint256 borrowerSupplyBefore = supplyToken.balanceOf(borrower);
        uint256 nextId = lending.nextLendingId();

        vm.prank(borrower);
        uint256 lendingId = adapter.requestBorrowAdapter{value: GAS_COMP}(_borrowParams(
            address(supplyToken),
            address(borrowToken),
            borrower,
            GAS_COMP
        ));

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(lendingId, nextId);
        assertEq(loan.borrower, borrower);
        assertEq(loan.supplyToken, address(supplyToken));
        assertEq(loan.borrowToken, address(borrowToken));
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT);
        assertEq(loan.principal, BORROW_AMOUNT);
        assertEq(supplyToken.balanceOf(borrower), borrowerSupplyBefore - SUPPLY_AMOUNT);
        assertEq(supplyToken.balanceOf(address(lending)), SUPPLY_AMOUNT);
        assertEq(supplyToken.balanceOf(address(adapter)), 0);
    }

    function testRequestBorrowAdapter_Erc20CollateralAndEthGasCompConserved() public {
        address[] memory actors = _actors3(borrower, address(adapter), address(lending));
        uint256 supplyBefore = _sumToken(supplyToken, actors);
        uint256 ethBefore = _sumEth(actors);

        vm.prank(borrower);
        adapter.requestBorrowAdapter{value: GAS_COMP}(_borrowParams(
            address(supplyToken),
            address(borrowToken),
            borrower,
            GAS_COMP
        ));

        assertEq(_sumToken(supplyToken, actors), supplyBefore);
        assertEq(_sumEth(actors), ethBefore);
        assertEq(supplyToken.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
    }

    function testRequestBorrowAdapter_RejectsBorrowerDifferentFromCaller() public {
        openLendEthUsdcAdapter1.BorrowParams memory params =
            _borrowParams(address(supplyToken), address(borrowToken), address(0xBAD), GAS_COMP);

        vm.prank(borrower);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.requestBorrowAdapter{value: GAS_COMP}(params);
    }

    function testRequestBorrowAdapter_NativeCollateralRequiresSupplyPlusGasComp() public {
        openLendEthUsdcAdapter1.BorrowParams memory params =
            _borrowParams(address(0), address(borrowToken), borrower, GAS_COMP);
        vm.deal(borrower, 200 ether);

        vm.prank(borrower);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        nativeSupplyAdapter.requestBorrowAdapter{value: SUPPLY_AMOUNT + GAS_COMP - 1}(params);

        uint256 borrowerEthBefore = borrower.balance;
        vm.prank(borrower);
        uint256 lendingId = nativeSupplyAdapter.requestBorrowAdapter{value: SUPPLY_AMOUNT + GAS_COMP}(params);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.borrower, borrower);
        assertEq(loan.supplyToken, address(0));
        assertEq(loan.borrowToken, address(borrowToken));
        assertEq(borrower.balance, borrowerEthBefore - SUPPLY_AMOUNT - GAS_COMP);
        assertEq(address(nativeSupplyAdapter).balance, 0);
    }

    function testRequestBorrowAdapter_NativeCollateralEthConserved() public {
        openLendEthUsdcAdapter1.BorrowParams memory params =
            _borrowParams(address(0), address(borrowToken), borrower, GAS_COMP);
        vm.deal(borrower, 200 ether);
        address[] memory actors = _actors3(borrower, address(nativeSupplyAdapter), address(lending));
        uint256 ethBefore = _sumEth(actors);

        vm.prank(borrower);
        nativeSupplyAdapter.requestBorrowAdapter{value: SUPPLY_AMOUNT + GAS_COMP}(params);

        assertEq(_sumEth(actors), ethBefore);
        assertEq(address(nativeSupplyAdapter).balance, 0);
    }

    function testRequestBorrowAdapter_AcceptsTightLowerPolicyBounds() public {
        openLendEthUsdcAdapter1.BorrowParams memory params =
            _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.term = 4 hours;
        params.liquidationThreshold = 7e6;
        params.stake = 10;
        params.oracleParams.oracleGameFee = 25_000;
        params.oracleParams.multiplier = 130;
        params.oracleParams.maxBaseFee = 0;
        params.oracleParams.finalizerReward = 0.0005 ether;
        params.interestRateParams.maxRate = 5e7;
        params.interestRateParams.startingRate = 5e7;
        params.interestRateParams.growthRate = 10100;
        params.interestRateParams.maxRounds = 1;

        vm.prank(borrower);
        uint256 lendingId = adapter.requestBorrowAdapter(params);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.borrower, borrower);
        assertEq(loan.term, 4 hours);
        assertEq(loan.stake, 10);
        assertEq(lendView.getOracleParams(lendingId).finalizerReward, 0.0005 ether);
    }

    function testRequestBorrowAdapter_AcceptsTightUpperPolicyBounds() public {
        openLendEthUsdcAdapter1.BorrowParams memory params =
            _borrowParams(address(supplyToken), address(borrowToken), borrower, 0.05 ether);
        params.term = 30 days;
        params.liquidationThreshold = 9.25e6;
        params.stake = 150;
        params.oracleParams.settlementTime = 1 hours;
        params.oracleParams.oracleGameFee = 300_000;
        params.oracleParams.escalationFactor = 250;
        params.oracleParams.initialLiquidity = 100;
        params.oracleParams.multiplier = 250;
        params.oracleParams.maxBaseFee = 0;
        params.oracleParams.finalizerReward = 0.01 ether;
        params.interestRateParams.maxRate = 3.5e8;
        params.interestRateParams.startingRate = 5e7;
        params.interestRateParams.roundLength = 5 minutes;
        params.interestRateParams.growthRate = 11000;
        params.interestRateParams.maxRounds = 100;

        vm.prank(borrower);
        uint256 lendingId = adapter.requestBorrowAdapter{value: 0.05 ether}(params);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.borrower, borrower);
        assertEq(loan.term, 30 days);
        assertEq(loan.stake, 150);
        assertEq(lendView.getOracleParams(lendingId).finalizerReward, 0.01 ether);
    }

    function testRequestBorrowAdapter_RejectsAdapterOnlyPolicyViolationsThatOpenLendAccepts() public {
        openLendEthUsdcAdapter1.BorrowParams memory params =
            _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);

        params.term = 31 days;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.liquidationThreshold = 9.5e6;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.stake = 5;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0.06 ether);
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.oracleParams.settlementTime = 2 hours;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.oracleParams.disputeDelay = 120;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.oracleParams.oracleGameFee = 500_000;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.oracleParams.escalationFactor = 500;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.oracleParams.initialLiquidity = 201;
        params.oracleParams.escalationFactor = 250;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.oracleParams.multiplier = 300;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.oracleParams.maxBaseFee = 5e9;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.oracleParams.finalizerReward = 0.0001 ether;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.oracleParams.finalizerReward = 0.02 ether;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.interestRateParams.maxRate = 4e8;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.interestRateParams.startingRate = 6e7;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.interestRateParams.roundLength = 11;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.interestRateParams.roundLength = 6 minutes;
        _assertDirectRequestAcceptedAdapterRejected(params);

        params = _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        params.interestRateParams.growthRate = 10050;
        _assertDirectRequestAcceptedAdapterRejected(params);
    }

    function testRequestBorrowAdapter_RejectsTokenOutsideConfiguredPair() public {
        MockERC20 otherToken = new MockERC20("Other", "OTHER");
        otherToken.transfer(borrower, 10_000 ether);

        openLendEthUsdcAdapter1.BorrowParams memory params =
            _borrowParams(address(otherToken), address(borrowToken), borrower, 0);

        vm.prank(borrower);
        otherToken.approve(address(lending), type(uint256).max);
        vm.prank(borrower);
        lending.requestBorrow(
            params.term,
            params.supplyToken,
            params.borrowToken,
            params.liquidationThreshold,
            params.supplyAmount,
            params.amountDemanded,
            params.stake,
            params.commitmentFraction,
            params.gasCompensation,
            borrower,address(0),
            
            _toOpenLendOracleParams(params.oracleParams),
            _toOpenLendInterestRateParams(params.interestRateParams)
        );

        vm.prank(borrower);
        otherToken.approve(address(adapter), type(uint256).max);
        vm.prank(borrower);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.requestBorrowAdapter(params);
    }

    function testRequestBorrowAdapter_RejectsSameSupplyAndBorrowToken() public {
        openLendEthUsdcAdapter1.BorrowParams memory params =
            _borrowParams(address(supplyToken), address(supplyToken), borrower, 0);

        vm.prank(borrower);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.requestBorrowAdapter(params);
    }

    function testLendAdapter_Erc20OriginationPullsFromCallerAndLeavesNoAdapterDust() public {
        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), GAS_COMP);
        uint256 borrowerBorrowBefore = borrowToken.balanceOf(borrower);
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);
        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, lender, 0);
        address[] memory actors = _actors4(borrower, lender, address(adapter), address(lending));
        uint256 borrowBefore = _sumToken(borrowToken, actors);

        vm.prank(lender);
        adapter.lendAdapter(params, BORROW_AMOUNT);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender);
        assertEq(loan.active, true);
        assertEq(loan.curveOpen, false);
        assertEq(borrowToken.balanceOf(borrower), borrowerBorrowBefore + BORROW_AMOUNT);
        assertEq(borrowToken.balanceOf(lender), lenderBorrowBefore - BORROW_AMOUNT);
        assertEq(_sumToken(borrowToken, actors), borrowBefore);
        assertEq(borrowToken.balanceOf(address(adapter)), 0);
    }

    function testLendAdapter_Erc20OriginationRejectsEthAndWrongAmount() public {
        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), GAS_COMP);
        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, lender, 0);

        vm.prank(lender);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.lendAdapter{value: 1 wei}(params, BORROW_AMOUNT);

        vm.prank(lender);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.lendAdapter(params, BORROW_AMOUNT - 1);
    }

    function testLendAdapter_RejectsZeroParamHashExpected() public {
        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), GAS_COMP);
        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, lender, 0);
        params.paramHashExpected = bytes32(0);

        vm.prank(lender);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.lendAdapter(params, BORROW_AMOUNT);
    }

    function testLendAdapter_NativeBorrowRequiresExactAmountAndMsgValue() public {
        uint256 lendingId = _requestThroughAdapter(nativeBorrowAdapter, address(supplyToken), address(0), GAS_COMP);
        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, lender, 0);

        vm.prank(lender);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        nativeBorrowAdapter.lendAdapter{value: BORROW_AMOUNT + 1}(params, BORROW_AMOUNT);

        uint256 borrowerEthBefore = borrower.balance;
        vm.prank(lender);
        nativeBorrowAdapter.lendAdapter{value: BORROW_AMOUNT}(params, BORROW_AMOUNT);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender);
        assertEq(loan.active, true);
        assertEq(borrower.balance, borrowerEthBefore + BORROW_AMOUNT);
        assertEq(address(nativeBorrowAdapter).balance, 0);
    }

    function testLendAdapter_NativeBorrowEthConserved() public {
        uint256 lendingId = _requestThroughAdapter(nativeBorrowAdapter, address(supplyToken), address(0), GAS_COMP);
        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, lender, 0);
        address[] memory actors = _actors4(borrower, lender, address(nativeBorrowAdapter), address(lending));
        uint256 ethBefore = _sumEth(actors);

        vm.prank(lender);
        nativeBorrowAdapter.lendAdapter{value: BORROW_AMOUNT}(params, BORROW_AMOUNT);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender);
        assertEq(loan.active, true);
        assertEq(_sumEth(actors), ethBefore);
        assertEq(address(nativeBorrowAdapter).balance, 0);
    }

    function testLendAdapter_SixDecimalUsdcCollateralNativeEthDebt() public {
        MockDecimalsERC20 usdc = new MockDecimalsERC20("USD Coin", "USDC", 6);
        openLendEthUsdcAdapter1 usdcEthAdapter =
            new openLendEthUsdcAdapter1(address(lending), address(usdc), address(0));
        uint128 usdcSupply = 100_000e6;
        uint128 ethBorrow = 50 ether;

        usdc.mint(borrower, usdcSupply);
        vm.prank(borrower);
        usdc.approve(address(usdcEthAdapter), type(uint256).max);

        openLendEthUsdcAdapter1.BorrowParams memory borrowParams =
            _borrowParams(address(usdc), address(0), borrower, 0);
        borrowParams.supplyAmount = usdcSupply;
        borrowParams.amountDemanded = ethBorrow;

        uint256 borrowerEthBefore = borrower.balance;
        address[] memory ethActors = _actors4(borrower, lender, address(usdcEthAdapter), address(lending));
        uint256 ethBefore = _sumEth(ethActors);

        vm.prank(borrower);
        uint256 lendingId = usdcEthAdapter.requestBorrowAdapter(borrowParams);

        openLendEthUsdcAdapter1.LendParams memory lendParams = _lendParams(lendingId, lender, 0);
        vm.prank(lender);
        usdcEthAdapter.lendAdapter{value: ethBorrow}(lendParams, ethBorrow);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(usdc.decimals(), 6);
        assertEq(loan.supplyToken, address(usdc));
        assertEq(loan.borrowToken, address(0));
        assertEq(loan.supplyAmount, usdcSupply);
        assertEq(loan.principal, ethBorrow);
        assertEq(loan.lender, lender);
        assertEq(usdc.balanceOf(address(lending)), usdcSupply);
        assertEq(usdc.balanceOf(address(usdcEthAdapter)), 0);
        assertEq(borrower.balance, borrowerEthBefore + ethBorrow);
        assertEq(_sumEth(ethActors), ethBefore);
        assertEq(address(usdcEthAdapter).balance, 0);
    }

    function testLendAdapter_RefiRefundsErc20OverfundToCaller() public {
        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), 0);
        openLendEthUsdcAdapter1.LendParams memory initialParams = _lendParams(lendingId, lender, 0);
        vm.prank(lender);
        adapter.lendAdapter(initialParams, BORROW_AMOUNT);

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOpenLendOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        uint256 lender2Before = borrowToken.balanceOf(lender2);
        uint256 prevLenderBefore = borrowToken.balanceOf(lender);
        uint128 amountSent = BORROW_AMOUNT + 1 ether;
        openLendEthUsdcAdapter1.LendParams memory refiParams = _lendParams(lendingId, lender2, 0);
        address[] memory actors = _actors5(borrower, lender, lender2, address(adapter), address(lending));
        uint256 borrowBefore = _sumToken(borrowToken, actors);

        vm.prank(lender2);
        adapter.lendAdapter(refiParams, amountSent);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender2);
        assertEq(borrowToken.balanceOf(lender), prevLenderBefore + BORROW_AMOUNT);
        assertEq(borrowToken.balanceOf(lender2), lender2Before - BORROW_AMOUNT);
        assertEq(_sumToken(borrowToken, actors), borrowBefore);
        assertEq(borrowToken.balanceOf(address(adapter)), 0);
    }

    function testLendAdapter_NoChangeOracleRefiAfterPriorChangedOracleParamsUsesCurrentParams() public {
        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), 0);
        openLendEthUsdcAdapter1.LendParams memory initialParams = _lendParams(lendingId, lender, 0);
        vm.prank(lender);
        adapter.lendAdapter(initialParams, BORROW_AMOUNT);

        openLend.OracleParams memory changed = _openLendOracleParams();
        changed.settlementTime = 20 minutes;

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            changed,
            bytes32(0),
            0,
            type(uint128).max
        );

        openLendEthUsdcAdapter1.LendParams memory firstRefiParams = _lendParams(lendingId, lender2, 0);
        vm.prank(lender2);
        adapter.lendAdapter(firstRefiParams, BORROW_AMOUNT);
        assertEq(lendView.getOracleParams(lendingId).settlementTime, 20 minutes);

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOpenLendOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        openLendEthUsdcAdapter1.LendParams memory secondRefiParams = _lendParams(lendingId, lender3, 0);
        vm.prank(lender3);
        adapter.lendAdapter(secondRefiParams, BORROW_AMOUNT);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender3);
        assertEq(lendView.getOracleParams(lendingId).settlementTime, 20 minutes);
    }

    function testValidateParamsLendingIds_SplitsLenderAndCurrentRefiPerspectives() public {
        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), 0);
        openLendEthUsdcAdapter1.LendParams memory initialParams = _lendParams(lendingId, lender, 0);
        vm.prank(lender);
        adapter.lendAdapter(initialParams, BORROW_AMOUNT);

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            31 days,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOpenLendOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        uint256[] memory ids = new uint256[](1);
        ids[0] = lendingId;
        (bool[] memory lenderOk, bool[] memory currentOk) = adapter.validateParamsLendingIds(ids, true, true);

        assertEq(lenderOk[0], false);
        assertEq(currentOk[0], true);
    }

    function testValidateParamsLendingIds_BadStagedRefiOracleParamsOnlyFailsLenderPerspective() public {
        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), 0);
        openLendEthUsdcAdapter1.LendParams memory initialParams = _lendParams(lendingId, lender, 0);
        vm.prank(lender);
        adapter.lendAdapter(initialParams, BORROW_AMOUNT);

        openLend.OracleParams memory staged = _openLendOracleParams();
        staged.settlementTime = 2 hours;

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            staged,
            bytes32(0),
            0,
            type(uint128).max
        );

        uint256[] memory ids = new uint256[](1);
        ids[0] = lendingId;
        (bool[] memory lenderOk, bool[] memory currentOk) = adapter.validateParamsLendingIds(ids, true, true);

        assertEq(lenderOk[0], false);
        assertEq(currentOk[0], true);

        openLendEthUsdcAdapter1.LendParams memory badStagedParams = _lendParams(lendingId, lender2, 0);
        vm.prank(lender2);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.lendAdapter(badStagedParams, BORROW_AMOUNT);
    }

    function testValidateParamsLendingIds_SameTokenLoanRejected() public {
        SameTokenOpenLend sameTokenOpenLend = new SameTokenOpenLend(address(supplyToken), address(weth));
        openLendEthUsdcAdapter1 sameTokenAdapter =
            new openLendEthUsdcAdapter1(address(sameTokenOpenLend), address(supplyToken), address(borrowToken));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        (bool[] memory lenderOk, bool[] memory currentOk) = sameTokenAdapter.validateParamsLendingIds(ids, true, true);

        assertEq(lenderOk[0], false);
        assertEq(currentOk[0], false);
    }

    function testLendAdapter_AutoFinalizeSweepsFinalizerRewardToCaller() public {
        (uint256 lendingId, uint64 finalizerReward) = _setupSettleableFailedLiquidationWithOpenRefi();
        uint256 lender2EthBefore = lender2.balance;
        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, lender2, 0);
        address[] memory ethActors = _actors3(lender2, address(adapter), address(lending));
        address[] memory borrowActors = _actors5(borrower, lender, lender2, address(adapter), address(lending));
        uint256 ethBefore = _sumEth(ethActors);
        uint256 borrowBefore = _sumToken(borrowToken, borrowActors);

        vm.prank(lender2);
        adapter.lendAdapter(params, BORROW_AMOUNT + 1 ether);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender2);
        assertEq(loan.inLiquidation, false);
        assertEq(loan.curveOpen, false);
        assertEq(lender2.balance - lender2EthBefore, finalizerReward);
        assertEq(_sumEth(ethActors), ethBefore);
        assertEq(_sumToken(borrowToken, borrowActors), borrowBefore);
        assertEq(address(adapter).balance, 0);
        assertEq(borrowToken.balanceOf(address(adapter)), 0);
    }

    function testLendAdapter_NativeBorrowRefiAutoFinalizeSweepsBountyAndRefundsOverpay() public {
        (uint256 lendingId, uint64 finalizerReward) = _setupNativeBorrowSettleableFailedLiquidationWithOpenRefi();
        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, lender2, 0);
        uint128 amountSent = BORROW_AMOUNT + 2 ether;
        address[] memory ethActors = _actors8(
            borrower,
            lender,
            lender2,
            liquidator,
            disputer,
            address(nativeBorrowAdapter),
            address(lending),
            address(oracle)
        );
        uint256 ethBefore = _sumEth(ethActors);
        uint256 lender2EthBefore = lender2.balance;
        uint256 prevLenderEthBefore = lender.balance;

        vm.prank(lender2);
        nativeBorrowAdapter.lendAdapter{value: amountSent}(params, amountSent);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(loan.lender, lender2);
        assertEq(loan.inLiquidation, false);
        assertEq(loan.curveOpen, false);
        assertEq(lender.balance - prevLenderEthBefore, loan.principal);
        assertEq(lender2EthBefore - lender2.balance, uint256(loan.principal) - finalizerReward);
        assertEq(_sumEth(ethActors), ethBefore);
        assertEq(address(nativeBorrowAdapter).balance, 0);
        assertEq(supplyToken.balanceOf(address(nativeBorrowAdapter)), 0);
    }

    function testLendAdapter_AutoFinalizeRewardSweepRevertsWhenCallerRejectsEth() public {
        (uint256 lendingId,) = _setupSettleableFailedLiquidationWithOpenRefi();
        AdapterRejectingLender rejecter = new AdapterRejectingLender();
        borrowToken.transfer(address(rejecter), BORROW_AMOUNT + 1 ether);

        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, address(rejecter), 0);

        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        rejecter.approveAndLend(IERC20(address(borrowToken)), adapter, params, BORROW_AMOUNT + 1 ether);
    }

    function testLendAdapter_DonationsAreNotSweptToNextCaller() public {
        (uint256 lendingId, uint64 finalizerReward) = _setupSettleableFailedLiquidationWithOpenRefi();
        uint256 ethDonation = 2 ether;
        uint256 tokenDonation = 3 ether;
        vm.deal(address(this), ethDonation);
        (bool ok,) = payable(address(adapter)).call{value: ethDonation}("");
        assertTrue(ok);
        borrowToken.transfer(address(adapter), tokenDonation);

        uint256 lender2EthBefore = lender2.balance;
        uint256 lender2BorrowBefore = borrowToken.balanceOf(lender2);
        uint256 prevLenderBorrowBefore = borrowToken.balanceOf(lender);
        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, lender2, 0);

        vm.prank(lender2);
        adapter.lendAdapter(params, BORROW_AMOUNT + 1 ether);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        uint256 lender2BorrowSpent = lender2BorrowBefore - borrowToken.balanceOf(lender2);
        assertEq(lender2.balance - lender2EthBefore, finalizerReward);
        assertEq(lender2BorrowSpent, loan.principal);
        assertEq(borrowToken.balanceOf(lender) - prevLenderBorrowBefore, loan.principal);
        assertEq(address(adapter).balance, ethDonation);
        assertEq(borrowToken.balanceOf(address(adapter)), tokenDonation);
    }

    function testLendAdapter_SweepsWethFallbackBountyToCallerWithoutSweepingDonation() public {
        uint256 bounty = 0.004 ether;
        uint256 donation = 0.7 ether;
        vm.deal(address(this), bounty + donation);
        AdapterWethBountyOpenLend mockOpenLend =
            new AdapterWethBountyOpenLend{value: bounty}(address(supplyToken), address(weth), bounty);
        openLendEthUsdcAdapter1 fallbackAdapter =
            new openLendEthUsdcAdapter1(address(mockOpenLend), address(supplyToken), address(0));

        weth.deposit{value: donation}();
        weth.transfer(address(fallbackAdapter), donation);

        openLendEthUsdcAdapter1.LendParams memory params = openLendEthUsdcAdapter1.LendParams({
            lendingId: 1,
            paramHashExpected: bytes32(uint256(1)),
            minLendAmount: 0,
            maxLendAmount: type(uint128).max,
            expectedMinSupply: 0,
            minRate: 0,
            liquidatorFraction: 0,
            lender: lender
        });
        uint256 ethBefore = address(mockOpenLend).balance + address(weth).balance;
        uint256 lenderWethBefore = weth.balanceOf(lender);

        vm.prank(lender);
        fallbackAdapter.lendAdapter(params, 0);

        assertEq(weth.balanceOf(lender) - lenderWethBefore, bounty);
        assertEq(weth.balanceOf(address(fallbackAdapter)), donation);
        assertEq(address(fallbackAdapter).balance, 0);
        assertEq(address(mockOpenLend).balance + address(weth).balance, ethBefore);
    }

    function testFuzzLendAdapter_AutoFinalizeOverfundAndRewardConserved(
        uint128 overfundSeed,
        uint64 finalizerRewardSeed
    ) public {
        uint128 overfund = uint128(bound(uint256(overfundSeed), 1 ether, 5 ether));
        uint64 finalizerReward = uint64(bound(uint256(finalizerRewardSeed), 0.0005 ether, 0.01 ether));
        (uint256 lendingId,) = _setupSettleableFailedLiquidationWithOpenRefi(finalizerReward);
        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, lender2, 0);
        address[] memory ethActors = _actors3(lender2, address(adapter), address(lending));
        address[] memory borrowActors = _actors5(borrower, lender, lender2, address(adapter), address(lending));
        uint256 ethBefore = _sumEth(ethActors);
        uint256 borrowBefore = _sumToken(borrowToken, borrowActors);
        uint256 lender2EthBefore = lender2.balance;

        vm.prank(lender2);
        adapter.lendAdapter(params, uint128(uint256(BORROW_AMOUNT) + overfund));

        assertEq(_sumEth(ethActors), ethBefore);
        assertEq(_sumToken(borrowToken, borrowActors), borrowBefore);
        assertEq(lender2.balance - lender2EthBefore, finalizerReward);
        assertEq(address(adapter).balance, 0);
        assertEq(borrowToken.balanceOf(address(adapter)), 0);
    }

    function testFuzzLendAdapter_DonationImmunityConserved(
        uint128 overfundSeed,
        uint64 finalizerRewardSeed,
        uint96 ethDonationSeed,
        uint128 tokenDonationSeed
    ) public {
        uint128 overfund = uint128(bound(uint256(overfundSeed), 1 ether, 5 ether));
        uint64 finalizerReward = uint64(bound(uint256(finalizerRewardSeed), 0.0005 ether, 0.01 ether));
        uint256 ethDonation = bound(uint256(ethDonationSeed), 1 wei, 5 ether);
        uint256 tokenDonation = bound(uint256(tokenDonationSeed), 1 wei, 5 ether);
        (uint256 lendingId,) = _setupSettleableFailedLiquidationWithOpenRefi(finalizerReward);

        vm.deal(address(this), ethDonation);
        (bool ok,) = payable(address(adapter)).call{value: ethDonation}("");
        assertTrue(ok);
        borrowToken.transfer(address(adapter), tokenDonation);

        openLendEthUsdcAdapter1.LendParams memory params = _lendParams(lendingId, lender2, 0);
        address[] memory ethActors = _actors3(lender2, address(adapter), address(lending));
        address[] memory borrowActors = _actors5(borrower, lender, lender2, address(adapter), address(lending));
        uint256 ethBefore = _sumEth(ethActors);
        uint256 borrowBefore = _sumToken(borrowToken, borrowActors);
        uint256 lender2EthBefore = lender2.balance;

        vm.prank(lender2);
        adapter.lendAdapter(params, uint128(uint256(BORROW_AMOUNT) + overfund));

        assertEq(_sumEth(ethActors), ethBefore);
        assertEq(_sumToken(borrowToken, borrowActors), borrowBefore);
        assertEq(lender2.balance - lender2EthBefore, finalizerReward);
        assertEq(address(adapter).balance, ethDonation);
        assertEq(borrowToken.balanceOf(address(adapter)), tokenDonation);
    }

    function testAdapter_SequenceLeavesNoResidualBalances() public {
        uint256 firstId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), GAS_COMP);
        openLendEthUsdcAdapter1.LendParams memory firstLendParams = _lendParams(firstId, lender, 0);
        vm.prank(lender);
        adapter.lendAdapter(firstLendParams, BORROW_AMOUNT);

        vm.prank(borrower);
        lending.refinance(
            firstId,
            0,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOpenLendOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        openLendEthUsdcAdapter1.LendParams memory refiParams = _lendParams(firstId, lender2, 0);
        vm.prank(lender2);
        adapter.lendAdapter(refiParams, BORROW_AMOUNT + 1 ether);

        uint256 secondId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), 0);
        openLendEthUsdcAdapter1.LendParams memory secondLendParams = _lendParams(secondId, lender3, 0);
        vm.prank(lender3);
        adapter.lendAdapter(secondLendParams, BORROW_AMOUNT);

        assertEq(address(adapter).balance, 0);
        assertEq(supplyToken.balanceOf(address(adapter)), 0);
        assertEq(borrowToken.balanceOf(address(adapter)), 0);
    }

    function testLendAdapter_OverpullingOpenLendRevertsWithoutBalanceChanges() public {
        AdapterOverpullOpenLend overpull =
            new AdapterOverpullOpenLend(address(supplyToken), address(borrowToken), address(weth));
        openLendEthUsdcAdapter1 hostileAdapter =
            new openLendEthUsdcAdapter1(address(overpull), address(supplyToken), address(borrowToken));
        borrowToken.transfer(address(hostileAdapter), 1);

        vm.prank(lender);
        borrowToken.approve(address(hostileAdapter), type(uint256).max);

        uint256 lenderBefore = borrowToken.balanceOf(lender);
        uint256 adapterBefore = borrowToken.balanceOf(address(hostileAdapter));
        uint256 overpullBefore = borrowToken.balanceOf(address(overpull));

        openLendEthUsdcAdapter1.LendParams memory params = openLendEthUsdcAdapter1.LendParams({
            lendingId: 1,
            paramHashExpected: bytes32(uint256(1)),
            minLendAmount: 0,
            maxLendAmount: type(uint128).max,
            expectedMinSupply: 0,
            minRate: 0,
            liquidatorFraction: 0,
            lender: lender
        });

        vm.prank(lender);
        vm.expectRevert();
        hostileAdapter.lendAdapter(params, BORROW_AMOUNT);

        assertEq(borrowToken.balanceOf(lender), lenderBefore);
        assertEq(borrowToken.balanceOf(address(hostileAdapter)), adapterBefore);
        assertEq(borrowToken.balanceOf(address(overpull)), overpullBefore);
    }

    function testValidateParamsLendingId_RevertsOnOpenLendInvalidInterestParams() public {
        IOpenLend.InterestRateParams memory bad = _adapterInterestParams();
        bad.maxRate = 0;

        openLendEthUsdcAdapter1.BorrowParams memory params =
            _borrowParams(address(supplyToken), address(borrowToken), borrower, GAS_COMP);
        params.interestRateParams = bad;

        vm.prank(borrower);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.requestBorrowAdapter{value: GAS_COMP}(params);
    }

    function testRefinanceAdapter_OpensRefiThroughAdapterDelegateAndLeavesNoBalances() public {
        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), GAS_COMP);
        openLendEthUsdcAdapter1.LendParams memory lendParams = _lendParams(lendingId, lender, 0);
        vm.prank(lender);
        adapter.lendAdapter(lendParams, BORROW_AMOUNT);

        openLendEthUsdcAdapter1.RefiAdapterParams memory refiParams = _refiAdapterParams(lendingId);
        refiParams.extraDemanded = 1 ether;
        refiParams.newTerm = LOAN_TERM + 1 days;
        refiParams.gasCompensation = GAS_COMP;
        address[] memory actors = _actors3(borrower, address(adapter), address(lending));
        uint256 ethBefore = _sumEth(actors);

        vm.prank(borrower);
        adapter.refinanceAdapter{value: GAS_COMP}(refiParams);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.curveOpen);
        assertEq(loan.refiParams.extraDemanded, 1 ether);
        assertEq(loan.refiParams.newTerm, LOAN_TERM + 1 days);
        assertEq(loan.gasCompensation, GAS_COMP);
        assertEq(_sumEth(actors), ethBefore);
        assertEq(address(adapter).balance, 0);
        assertEq(supplyToken.balanceOf(address(adapter)), 0);
        assertEq(borrowToken.balanceOf(address(adapter)), 0);
    }

    function testRefinanceAdapter_RejectsZeroHashAndBadCaller() public {
        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), 0);
        openLendEthUsdcAdapter1.LendParams memory lendParams = _lendParams(lendingId, lender, 0);
        vm.prank(lender);
        adapter.lendAdapter(lendParams, BORROW_AMOUNT);

        openLendEthUsdcAdapter1.RefiAdapterParams memory refiParams = _refiAdapterParams(lendingId);
        refiParams.expectedParamHash = bytes32(0);

        vm.prank(borrower);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.refinanceAdapter(refiParams);

        refiParams.expectedParamHash = lendView.getParamHash(lendingId);
        vm.prank(lender);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.refinanceAdapter(refiParams);
    }

    function testRefinanceAdapter_RejectsBadStagedOracleAndInterestParams() public {
        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), 0);
        openLendEthUsdcAdapter1.LendParams memory lendParams = _lendParams(lendingId, lender, 0);
        vm.prank(lender);
        adapter.lendAdapter(lendParams, BORROW_AMOUNT);

        openLendEthUsdcAdapter1.RefiAdapterParams memory refiParams = _refiAdapterParams(lendingId);
        refiParams.oracleParams = _adapterOracleParams();
        refiParams.oracleParams.settlementTime = 2 hours;

        vm.prank(borrower);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.refinanceAdapter(refiParams);

        refiParams = _refiAdapterParams(lendingId);
        refiParams.interestRateParams = _adapterInterestParams();
        refiParams.interestRateParams.roundLength = 6 minutes;

        vm.prank(borrower);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.refinanceAdapter(refiParams);
    }

    function testRefinanceAdapter_AutoFinalizeSweepsFinalizerRewardToBorrower() public {
        (uint256 lendingId, uint64 finalizerReward) = _setupSettleableFailedLiquidationNoRefi(uint64(0.004 ether));
        openLendEthUsdcAdapter1.RefiAdapterParams memory refiParams = _refiAdapterParams(lendingId);
        refiParams.extraDemanded = 1 ether;
        refiParams.newTerm = LOAN_TERM + 1 days;
        address[] memory ethActors = _actors3(borrower, address(adapter), address(lending));
        uint256 ethBefore = _sumEth(ethActors);
        uint256 borrowerEthBefore = borrower.balance;

        vm.prank(borrower);
        adapter.refinanceAdapter(refiParams);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation);
        assertTrue(loan.curveOpen);
        assertEq(loan.refiParams.extraDemanded, 1 ether);
        assertEq(loan.refiParams.newTerm, LOAN_TERM + 1 days);
        assertEq(borrower.balance - borrowerEthBefore, finalizerReward);
        assertEq(_sumEth(ethActors), ethBefore);
        assertEq(address(adapter).balance, 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
    }

    function testRefinanceAdapter_DonationsAreNotSweptToBorrower() public {
        (uint256 lendingId, uint64 finalizerReward) = _setupSettleableFailedLiquidationNoRefi(uint64(0.005 ether));
        uint256 ethDonation = 2 ether;
        uint256 wethDonation = 0.7 ether;
        vm.deal(address(this), ethDonation + wethDonation);
        (bool ok,) = payable(address(adapter)).call{value: ethDonation}("");
        assertTrue(ok);
        weth.deposit{value: wethDonation}();
        weth.transfer(address(adapter), wethDonation);

        openLendEthUsdcAdapter1.RefiAdapterParams memory refiParams = _refiAdapterParams(lendingId);
        address[] memory ethActors = _actors3(borrower, address(adapter), address(lending));
        uint256 ethBefore = _sumEth(ethActors);
        uint256 borrowerEthBefore = borrower.balance;

        vm.prank(borrower);
        adapter.refinanceAdapter(refiParams);

        assertEq(borrower.balance - borrowerEthBefore, finalizerReward);
        assertEq(_sumEth(ethActors), ethBefore);
        assertEq(address(adapter).balance, ethDonation);
        assertEq(weth.balanceOf(address(adapter)), wethDonation);
    }

    function testFuzzRefinanceAdapter_AutoFinalizeRewardGasCompAndDonationsConserved(
        uint64 finalizerRewardSeed,
        uint96 gasCompSeed,
        uint96 ethDonationSeed,
        uint96 wethDonationSeed
    ) public {
        uint64 finalizerReward = uint64(bound(uint256(finalizerRewardSeed), 0.0005 ether, 0.01 ether));
        uint96 gasCompensation = uint96(bound(uint256(gasCompSeed), 0, 0.05 ether));
        uint256 ethDonation = bound(uint256(ethDonationSeed), 0, 5 ether);
        uint256 wethDonation = bound(uint256(wethDonationSeed), 0, 5 ether);
        (uint256 lendingId,) = _setupSettleableFailedLiquidationNoRefi(finalizerReward);

        vm.deal(address(this), ethDonation + wethDonation);
        if (ethDonation > 0) {
            (bool ok,) = payable(address(adapter)).call{value: ethDonation}("");
            assertTrue(ok);
        }
        if (wethDonation > 0) {
            weth.deposit{value: wethDonation}();
            weth.transfer(address(adapter), wethDonation);
        }

        openLendEthUsdcAdapter1.RefiAdapterParams memory refiParams = _refiAdapterParams(lendingId);
        refiParams.gasCompensation = gasCompensation;
        address[] memory ethActors = _actors3(borrower, address(adapter), address(lending));
        uint256 ethBefore = _sumEth(ethActors);
        uint256 borrowerEthBefore = borrower.balance;

        vm.prank(borrower);
        adapter.refinanceAdapter{value: gasCompensation}(refiParams);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation);
        assertTrue(loan.curveOpen);
        assertEq(_sumEth(ethActors), ethBefore);
        assertEq(borrower.balance + gasCompensation, borrowerEthBefore + finalizerReward);
        assertEq(address(adapter).balance, ethDonation);
        assertEq(weth.balanceOf(address(adapter)), wethDonation);
    }

    function testRefinanceAdapter_SweepsWethFallbackBountyToCallerWithoutSweepingDonation() public {
        uint256 bounty = 0.004 ether;
        uint256 donation = 0.7 ether;
        vm.deal(address(this), bounty + donation);
        AdapterWethBountyOpenLend mockOpenLend =
            new AdapterWethBountyOpenLend{value: bounty}(address(supplyToken), address(weth), bounty);
        openLendEthUsdcAdapter1 fallbackAdapter =
            new openLendEthUsdcAdapter1(address(mockOpenLend), address(supplyToken), address(0));

        weth.deposit{value: donation}();
        weth.transfer(address(fallbackAdapter), donation);

        openLendEthUsdcAdapter1.RefiAdapterParams memory refiParams = openLendEthUsdcAdapter1.RefiAdapterParams({
            lendingId: 1,
            extraDemanded: 0,
            supplyPulled: 0,
            newTerm: LOAN_TERM,
            gasCompensation: 0,
            interestRateParams: _zeroAdapterInterestParams(),
            oracleParams: _zeroAdapterOracleParams(),
            expectedParamHash: bytes32(uint256(1)),
            expectedMinSupply: 0,
            expectedMaxPrincipal: type(uint128).max
        });
        uint256 ethBefore = address(mockOpenLend).balance + address(weth).balance;
        uint256 borrowerWethBefore = weth.balanceOf(borrower);

        vm.prank(borrower);
        fallbackAdapter.refinanceAdapter(refiParams);

        assertEq(weth.balanceOf(borrower) - borrowerWethBefore, bounty);
        assertEq(weth.balanceOf(address(fallbackAdapter)), donation);
        assertEq(address(fallbackAdapter).balance, 0);
        assertEq(address(mockOpenLend).balance + address(weth).balance, ethBefore);
    }

    function testRefinanceAdapter_AutoFinalizeRewardSweepRevertsWhenCallerRejectsEth() public {
        AdapterRejectingLender rejecter = new AdapterRejectingLender();
        supplyToken.transfer(address(rejecter), SUPPLY_AMOUNT);

        openLendEthUsdcAdapter1.BorrowParams memory borrowParams =
            _borrowParams(address(supplyToken), address(borrowToken), address(rejecter), 0);
        uint256 lendingId = rejecter.approveAndRequest(IERC20(address(supplyToken)), adapter, borrowParams);

        openLendEthUsdcAdapter1.LendParams memory lendParams = _lendParams(lendingId, lender, 0);
        vm.prank(lender);
        adapter.lendAdapter(lendParams, BORROW_AMOUNT);

        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;
        vm.startPrank(liquidator);
        lending.liquidate{value: uint256(SETTLER_REWARD) + finalizerReward}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            lendView.getLiquidateParamHash(lendingId),
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );
        vm.stopPrank();

        uint256 reportId = _latestReportId();
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);

        openLendEthUsdcAdapter1.RefiAdapterParams memory refiParams = _refiAdapterParams(lendingId);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        rejecter.refinanceThroughAdapter(adapter, refiParams);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.inLiquidation);
        assertFalse(loan.curveOpen);
        assertEq(address(adapter).balance, 0);
    }

    function testAdapter_FailedRequestAndLendDoNotChangeUserIndexes() public {
        uint256 borrowCountBefore = adapter.userBorrowCount(borrower);
        openLendEthUsdcAdapter1.BorrowParams memory badBorrow =
            _borrowParams(address(supplyToken), address(borrowToken), address(0xBAD), 0);

        vm.prank(borrower);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.requestBorrowAdapter(badBorrow);

        assertEq(adapter.userBorrowCount(borrower), borrowCountBefore);

        uint256 lendingId = _requestThroughAdapter(adapter, address(supplyToken), address(borrowToken), 0);
        uint256 lendCountBefore = adapter.userLendCount(lender);
        openLendEthUsdcAdapter1.LendParams memory badLend = _lendParams(lendingId, lender, 0);
        badLend.paramHashExpected = bytes32(0);

        vm.prank(lender);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.lendAdapter(badLend, BORROW_AMOUNT);

        assertEq(adapter.userLendCount(lender), lendCountBefore);
    }

    function _requestThroughAdapter(
        openLendEthUsdcAdapter1 targetAdapter,
        address supply,
        address borrow,
        uint96 gasCompensation
    ) internal returns (uint256 lendingId) {
        vm.prank(borrower);
        lendingId = targetAdapter.requestBorrowAdapter{value: gasCompensation}(_borrowParams(
            supply,
            borrow,
            borrower,
            gasCompensation
        ));
    }

    function _assertDirectRequestAcceptedAdapterRejected(openLendEthUsdcAdapter1.BorrowParams memory params) internal {
        uint256 ethRequired = params.supplyToken == address(0)
            ? uint256(params.supplyAmount) + params.gasCompensation
            : params.gasCompensation;

        vm.prank(borrower);
        lending.requestBorrow{value: ethRequired}(
            params.term,
            params.supplyToken,
            params.borrowToken,
            params.liquidationThreshold,
            params.supplyAmount,
            params.amountDemanded,
            params.stake,
            params.commitmentFraction,
            params.gasCompensation,
            params.borrower,address(0),
            
            _toOpenLendOracleParams(params.oracleParams),
            _toOpenLendInterestRateParams(params.interestRateParams)
        );

        vm.prank(borrower);
        vm.expectRevert(openLendEthUsdcAdapter1.InvalidParams.selector);
        adapter.requestBorrowAdapter{value: ethRequired}(params);
    }

    function _setupSettleableFailedLiquidationWithOpenRefi()
        internal
        returns (uint256 lendingId, uint64 finalizerReward)
    {
        return _setupSettleableFailedLiquidationWithOpenRefi(uint64(SETTLER_REWARD));
    }

    function _setupSettleableFailedLiquidationWithOpenRefi(uint64 requestedFinalizerReward)
        internal
        returns (uint256 lendingId, uint64 finalizerReward)
    {
        openLendEthUsdcAdapter1.BorrowParams memory borrowParams =
            _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        borrowParams.oracleParams.finalizerReward = requestedFinalizerReward;

        vm.prank(borrower);
        lendingId = adapter.requestBorrowAdapter(borrowParams);
        openLendEthUsdcAdapter1.LendParams memory initialParams = _lendParams(lendingId, lender, 0);

        vm.prank(lender);
        adapter.lendAdapter(initialParams, BORROW_AMOUNT);

        finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;

        vm.startPrank(liquidator);
        lending.liquidate{value: uint256(SETTLER_REWARD) + finalizerReward}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            lendView.getLiquidateParamHash(lendingId),
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );
        vm.stopPrank();

        uint256 reportId = _latestReportId();
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOpenLendOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);
    }

    function _setupSettleableFailedLiquidationNoRefi(uint64 requestedFinalizerReward)
        internal
        returns (uint256 lendingId, uint64 finalizerReward)
    {
        openLendEthUsdcAdapter1.BorrowParams memory borrowParams =
            _borrowParams(address(supplyToken), address(borrowToken), borrower, 0);
        borrowParams.oracleParams.finalizerReward = requestedFinalizerReward;

        vm.prank(borrower);
        lendingId = adapter.requestBorrowAdapter(borrowParams);
        openLendEthUsdcAdapter1.LendParams memory initialParams = _lendParams(lendingId, lender, 0);

        vm.prank(lender);
        adapter.lendAdapter(initialParams, BORROW_AMOUNT);

        finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;

        vm.startPrank(liquidator);
        lending.liquidate{value: uint256(SETTLER_REWARD) + finalizerReward}(
            lendingId,
            _priceRatioFor(6 ether),
            type(uint128).max,
            lendView.getLiquidateParamHash(lendingId),
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );
        vm.stopPrank();

        uint256 reportId = _latestReportId();
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);
        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);
    }

    function _setupNativeBorrowSettleableFailedLiquidationWithOpenRefi()
        internal
        returns (uint256 lendingId, uint64 finalizerReward)
    {
        openLendEthUsdcAdapter1.BorrowParams memory borrowParams =
            _borrowParams(address(supplyToken), address(0), borrower, 0);

        vm.prank(borrower);
        lendingId = nativeBorrowAdapter.requestBorrowAdapter(borrowParams);
        openLendEthUsdcAdapter1.LendParams memory initialParams = _lendParams(lendingId, lender, 0);

        vm.prank(lender);
        nativeBorrowAdapter.lendAdapter{value: BORROW_AMOUNT}(initialParams, BORROW_AMOUNT);

        finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;
        uint256 oracleAmount2 = 6 ether;

        vm.startPrank(liquidator);
        lending.liquidate{value: uint256(SETTLER_REWARD) + finalizerReward + oracleAmount2}(
            lendingId,
            _priceRatioFor(oracleAmount2),
            type(uint128).max,lendView.getLiquidateParamHash(lendingId),
            0,
            SETTLER_REWARD,
            liquidator,
            finalizerReward,
            _emptyTiming()
        );
        vm.stopPrank();

        uint256 reportId = _latestReportId();
        _disputeNativeBorrowToNonLiquidatingPrice(reportId, disputer);

        vm.prank(borrower);
        lending.refinance(
            lendingId,
            0,
            0,
            LOAN_TERM,
            0,
            _zeroOpenLendInterestParams(),
            _zeroOpenLendOracleParams(),
            bytes32(0),
            0,
            type(uint128).max
        );

        IOpenOracle2.OracleGame memory game = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(game.reportTimestamp) + game.settlementTime + 1);
    }

    function _disputeNativeBorrowToNonLiquidatingPrice(uint256 reportId, address disputeActor) internal {
        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        uint256 disputeReadyAt = uint256(o.reportTimestamp) + o.disputeDelay;
        if (block.timestamp < disputeReadyAt) vm.warp(disputeReadyAt);

        uint128 newAmount1 = uint128(uint256(o.currentAmount1) * o.multiplier / 100);
        uint128 newAmount2 = uint128(uint256(newAmount1) * 3 / 2);
        uint256 fee = uint256(o.currentAmount2) * o.feePercentage / 1e7;
        uint256 protocolFee = uint256(o.currentAmount2) * o.protocolFee / 1e7;
        uint256 ethRequired = uint256(newAmount2) + o.currentAmount2 + fee + protocolFee;

        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        vm.prank(disputeActor);
        IOpenOracle2(address(oracle)).dispute{value: ethRequired}(
            reportId,
            newAmount1,
            newAmount2,
            disputeActor,
            false,
            false,
            o,
            helper,
            _emptyTiming()
        );
    }

    function _priceRatioFor(uint256 oracleAmount2Target) internal pure returns (uint256) {
        uint256 initialLiquidity = uint256(SUPPLY_AMOUNT) * 10 / 100;
        return oracleAmount2Target * 1e18 / initialLiquidity;
    }

    function _sumToken(MockERC20 token, address[] memory actors) internal view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += token.balanceOf(actors[i]);
        }
    }

    function _sumEth(address[] memory actors) internal view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += actors[i].balance;
        }
    }

    function _actors3(address a, address b, address c) internal pure returns (address[] memory actors) {
        actors = new address[](3);
        actors[0] = a;
        actors[1] = b;
        actors[2] = c;
    }

    function _actors4(address a, address b, address c, address d) internal pure returns (address[] memory actors) {
        actors = new address[](4);
        actors[0] = a;
        actors[1] = b;
        actors[2] = c;
        actors[3] = d;
    }

    function _actors5(address a, address b, address c, address d, address e) internal pure returns (address[] memory actors) {
        actors = new address[](5);
        actors[0] = a;
        actors[1] = b;
        actors[2] = c;
        actors[3] = d;
        actors[4] = e;
    }

    function _actors8(address a, address b, address c, address d, address e, address f, address g, address h)
        internal
        pure
        returns (address[] memory actors)
    {
        actors = new address[](8);
        actors[0] = a;
        actors[1] = b;
        actors[2] = c;
        actors[3] = d;
        actors[4] = e;
        actors[5] = f;
        actors[6] = g;
        actors[7] = h;
    }

    function _borrowParams(address supply, address borrow, address recordedBorrower, uint96 gasCompensation)
        internal
        pure
        returns (openLendEthUsdcAdapter1.BorrowParams memory params)
    {
        params = openLendEthUsdcAdapter1.BorrowParams({
            term: LOAN_TERM,
            supplyToken: supply,
            borrowToken: borrow,
            liquidationThreshold: 8e6,
            supplyAmount: SUPPLY_AMOUNT,
            amountDemanded: BORROW_AMOUNT,
            stake: 100,
            commitmentFraction: 0,
            gasCompensation: gasCompensation,
            borrower: recordedBorrower,
            oracleParams: _adapterOracleParams(),
            interestRateParams: _adapterInterestParams()
        });
    }

    function _lendParams(uint256 lendingId, address recordedLender, uint24 liquidatorFraction)
        internal
        view
        returns (openLendEthUsdcAdapter1.LendParams memory params)
    {
        params = openLendEthUsdcAdapter1.LendParams({
            lendingId: lendingId,
            paramHashExpected: lendView.getParamHash(lendingId),
            minLendAmount: 0,
            maxLendAmount: type(uint128).max,
            expectedMinSupply: 0,
            minRate: 0,
            liquidatorFraction: liquidatorFraction,
            lender: recordedLender
        });
    }

    function _adapterOracleParams() internal pure returns (IOpenLend.OracleParams memory) {
        return IOpenLend.OracleParams({
            settlementTime: 10 minutes,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 100,
            initialLiquidity: 10,
            multiplier: 200,
            maxBaseFee: 0,
            finalizerReward: 0.001 ether
        });
    }

    function _adapterInterestParams() internal pure returns (IOpenLend.InterestRateParams memory) {
        return IOpenLend.InterestRateParams({
            maxRate: 2e8,
            startingRate: 5e7,
            roundLength: 60,
            growthRate: 10500,
            maxRounds: 20
        });
    }

    function _toOpenLendOracleParams(IOpenLend.OracleParams memory p)
        internal
        pure
        returns (openLend.OracleParams memory)
    {
        return openLend.OracleParams({
            settlementTime: p.settlementTime,
            disputeDelay: p.disputeDelay,
            oracleGameFee: p.oracleGameFee,
            escalationFactor: p.escalationFactor,
            initialLiquidity: p.initialLiquidity,
            multiplier: p.multiplier,
            maxBaseFee: p.maxBaseFee,
            finalizerReward: p.finalizerReward
        });
    }

    function _toOpenLendInterestRateParams(IOpenLend.InterestRateParams memory p)
        internal
        pure
        returns (openLend.InterestRateParams memory)
    {
        return openLend.InterestRateParams({
            maxRate: p.maxRate,
            startingRate: p.startingRate,
            roundLength: p.roundLength,
            growthRate: p.growthRate,
            maxRounds: p.maxRounds
        });
    }

    function _refiAdapterParams(uint256 lendingId)
        internal
        view
        returns (openLendEthUsdcAdapter1.RefiAdapterParams memory params)
    {
        params = openLendEthUsdcAdapter1.RefiAdapterParams({
            lendingId: lendingId,
            extraDemanded: 0,
            supplyPulled: 0,
            newTerm: LOAN_TERM,
            gasCompensation: 0,
            interestRateParams: _zeroAdapterInterestParams(),
            oracleParams: _zeroAdapterOracleParams(),
            expectedParamHash: lendView.getParamHash(lendingId),
            expectedMinSupply: 0,
            expectedMaxPrincipal: type(uint128).max
        });
    }

    function _zeroAdapterOracleParams() internal pure returns (IOpenLend.OracleParams memory) {
        return IOpenLend.OracleParams({
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

    function _zeroAdapterInterestParams() internal pure returns (IOpenLend.InterestRateParams memory) {
        return IOpenLend.InterestRateParams({
            maxRate: 0,
            startingRate: 0,
            roundLength: 0,
            growthRate: 0,
            maxRounds: 0
        });
    }

    function _openLendOracleParams() internal pure returns (openLend.OracleParams memory) {
        return openLend.OracleParams({
            settlementTime: 10 minutes,
            disputeDelay: 60,
            oracleGameFee: 100_000,
            escalationFactor: 100,
            initialLiquidity: 10,
            multiplier: 200,
            maxBaseFee: 0,
            finalizerReward: 0.001 ether
        });
    }

    function _zeroOpenLendOracleParams() internal pure returns (openLend.OracleParams memory) {
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

    function _zeroOpenLendInterestParams() internal pure returns (openLend.InterestRateParams memory) {
        return openLend.InterestRateParams({
            maxRate: 0,
            startingRate: 0,
            roundLength: 0,
            growthRate: 0,
            maxRounds: 0
        });
    }

    function _approveAdapterSupply(address account) internal {
        vm.prank(account);
        supplyToken.approve(address(adapter), type(uint256).max);
    }

    function _approveNativeAdapterSupply(address account) internal {
        vm.prank(account);
        supplyToken.approve(address(nativeBorrowAdapter), type(uint256).max);
    }

    function _approveAdapterBorrow(address account) internal {
        vm.prank(account);
        borrowToken.approve(address(adapter), type(uint256).max);
    }
}
