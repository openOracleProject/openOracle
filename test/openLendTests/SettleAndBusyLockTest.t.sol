// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LendErrors} from "../../src/libraries/LendErrors.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import "./OpenLendingBase.t.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ---------------------------------------------------------------------------
// Helper: a contract that can call finalize but rejects incoming ETH
// (no receive / fallback). Used to exercise _payEth's WETH wrap fallback.
// ---------------------------------------------------------------------------
contract EthRejectorCaller {
    openLend public lending;

    constructor(address _lending) {
        lending = openLend(payable(_lending));
    }

    function callSettle(uint256 lendingId) external {
        lending.finalize(lendingId);
    }
    // No receive() / fallback() — direct ETH send fails, _payEth falls back to WETH.
}

contract ReentrantEthReceiver {
    openLend public lending;
    bytes public payload;
    bool public lastReentryReverted;
    bytes public lastReentryReason;

    constructor(address _lending) {
        lending = openLend(payable(_lending));
    }

    function setPayload(bytes calldata _payload) external {
        payload = _payload;
    }

    function callSettle(uint256 lendingId) external {
        lending.finalize(lendingId);
    }

    receive() external payable {
        if (payload.length > 0) {
            (bool ok, bytes memory ret) = address(lending).call(payload);
            lastReentryReverted = !ok;
            lastReentryReason = ret;
        }
    }
}

// ---------------------------------------------------------------------------
// Helper: ERC20 that fires arbitrary configurable calldata at a target contract
// during transfer / transferFrom. Used to trigger reentrancy attempts.
// ---------------------------------------------------------------------------
contract ReentrantSupplyToken is ERC20 {
    address public target;
    bytes public payload;
    bool public lastReentryReverted;
    bytes public lastReentryReason;
    uint256 public attackCount;
    uint256 public attackLimit = type(uint256).max;

    constructor() ERC20("Reentrant", "REENT") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setTarget(address _target) external {
        target = _target;
    }

    function setPayload(bytes calldata _payload) external {
        payload = _payload;
    }

    function clearPayload() external {
        delete payload;
    }

    function setAttackLimit(uint256 _limit) external {
        attackLimit = _limit;
        attackCount = 0;
    }

    function _maybeAttack() internal {
        if (payload.length > 0 && target != address(0) && attackCount < attackLimit) {
            attackCount++;
            (bool ok, bytes memory ret) = target.call(payload);
            lastReentryReverted = !ok;
            lastReentryReason = ret;
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _maybeAttack();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _maybeAttack();
        return super.transferFrom(from, to, amount);
    }
}

contract SettleAndBusyLockTest is OpenLendingBaseTest {
    event BountyPaid(uint256 indexed lendingId, address indexed finalizer, uint256 bounty);

    address internal borrower = address(0x1);
    address internal lender = address(0x2);
    address internal lender2 = address(0x3);
    address internal liquidator = address(0x4);
    address internal disputer = address(0x5);
    address internal settler = address(0x6);
    address internal randomCaller = address(0x7);

    uint128 constant SUPPLY_AMOUNT = 100 ether;
    uint128 constant BORROW_AMOUNT = 70 ether;
    uint48 constant LOAN_TERM = 30 days;
    uint16 constant STAKE = 100;
    uint96 constant SETTLER_REWARD = 1e15;
    uint64 constant FINALIZER_REWARD = 1e15;

    function setUp() public {
        _deployCore("Supply Token", "SUP", "Borrow Token", "BOR");

        address[] memory accounts = new address[](7);
        accounts[0] = borrower;
        accounts[1] = lender;
        accounts[2] = lender2;
        accounts[3] = liquidator;
        accounts[4] = disputer;
        accounts[5] = settler;
        accounts[6] = randomCaller;
        _fundSupply(accounts, 10_000 ether);
        _fundBorrow(accounts, 10_000 ether);
        _dealETH(accounts, 100 ether);

        _approveLendingBoth(borrower);
        _approveLendingBoth(lender);
        _approveLendingBoth(lender2);
        _approveLendingBoth(liquidator);
        _approveOracleBoth(disputer);
    }

    function _setupLoan() internal returns (uint256 lendingId) {
        lendingId = _requestBorrow(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);
    }

    function _setupLoanWithFinalizerReward(uint64 finalizerReward) internal returns (uint256 lendingId) {
        openLend.OracleParams memory params = _standardOracleParams();
        params.finalizerReward = finalizerReward;

        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            uint24(1e7),
            0,
            borrower,
            params,
            _standardInterestRateParams()
        );

        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);
    }

    function _liquidate(uint256 lendingId, uint256 oracleAmount2Target) internal returns (uint256 reportId) {
        bytes32 paramHash = lendView.getParamHash(lendingId);
        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD + finalizerReward}(
            lendingId,
            oracleAmount2Target * 1e18 / 10 ether,
            type(uint128).max,
            paramHash,
             0,
            SETTLER_REWARD, liquidator, finalizerReward, _emptyTiming()
        );
        reportId = oracle.nextReportId() - 1;
    }

    function _setupSettleableFailedLiquidationWithFinalizerReward()
        internal
        returns (uint256 lendingId, uint256 reportId)
    {
        lendingId = _setupLoanWithFinalizerReward(FINALIZER_REWARD);
        vm.warp(block.timestamp + 10 days);
        reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);
    }

    function _openRefiDuringLiquidation(uint256 lendingId) internal {
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
    }

    // -------------------------------------------------------------------------
    // 1. finalize() happy path
    // -------------------------------------------------------------------------

    function testFinalize_HappyPath_ClearsStateAndPaysCaller() public {
        uint256 lendingId = _setupLoanWithFinalizerReward(FINALIZER_REWARD);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        // Warp past settlement window
        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        uint256 callerEthBefore = randomCaller.balance;
        vm.expectEmit(true, true, false, true, address(lending));
        emit BountyPaid(lendingId, randomCaller, FINALIZER_REWARD);
        vm.prank(randomCaller);
        lending.finalize(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared");
        assertEq(randomCaller.balance - callerEthBefore, FINALIZER_REWARD, "caller receives finalizer reward");
    }

    function testAutoSettle_PaysFinalizerRewardToEntryCaller() public {
        (uint256 lendingId,) = _setupSettleableFailedLiquidationWithFinalizerReward();

        uint256 borrowerEthBefore = borrower.balance;
        vm.prank(borrower);
        lending.repayDebt(lendingId, 5 ether, bytes32(0), 0, type(uint128).max);

        assertEq(borrower.balance - borrowerEthBefore, FINALIZER_REWARD, "auto-finalize pays entry caller");
        assertFalse(lendView.getLending(lendingId).inLiquidation, "auto-finalize cleared liquidation");
    }

    function testAutoSettle_RepayAnyDebtPaysFinalizerRewardToEntryCaller() public {
        (uint256 lendingId,) = _setupSettleableFailedLiquidationWithFinalizerReward();

        uint256 callerEthBefore = lender2.balance;
        vm.prank(lender2);
        lending.repayAnyDebt(lendingId, 5 ether, bytes32(0), 0, type(uint128).max);

        assertEq(lender2.balance - callerEthBefore, FINALIZER_REWARD, "repayAnyDebt caller gets bounty");
        assertFalse(lendView.getLending(lendingId).inLiquidation, "auto-finalize cleared liquidation");
    }

    function testAutoSettle_TopUpCollateralPaysFinalizerRewardToEntryCaller() public {
        (uint256 lendingId,) = _setupSettleableFailedLiquidationWithFinalizerReward();

        uint256 borrowerEthBefore = borrower.balance;
        vm.prank(borrower);
        lending.topUpCollateral(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);

        assertEq(borrower.balance - borrowerEthBefore, FINALIZER_REWARD, "topUpCollateral caller gets bounty");
        assertFalse(lendView.getLending(lendingId).inLiquidation, "auto-finalize cleared liquidation");
    }

    function testAutoSettle_TopUpCollateralAnyonePaysFinalizerRewardToEntryCaller() public {
        (uint256 lendingId,) = _setupSettleableFailedLiquidationWithFinalizerReward();

        uint256 callerEthBefore = lender2.balance;
        vm.prank(lender2);
        lending.topUpCollateralAnyone(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);

        assertEq(lender2.balance - callerEthBefore, FINALIZER_REWARD, "topUpCollateralAnyone caller gets bounty");
        assertFalse(lendView.getLending(lendingId).inLiquidation, "auto-finalize cleared liquidation");
    }

    function testAutoSettle_RefinancePaysFinalizerRewardToEntryCaller() public {
        (uint256 lendingId,) = _setupSettleableFailedLiquidationWithFinalizerReward();

        uint256 borrowerEthBefore = borrower.balance;
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

        assertEq(borrower.balance - borrowerEthBefore, FINALIZER_REWARD, "refinance caller gets bounty");
        assertFalse(lendView.getLending(lendingId).inLiquidation, "auto-finalize cleared liquidation");
        assertTrue(lendView.getLending(lendingId).curveOpen, "refinance body still runs");
    }

    function testAutoSettle_CancelRefinancePaysFinalizerRewardToEntryCaller() public {
        uint256 lendingId = _setupLoanWithFinalizerReward(FINALIZER_REWARD);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);
        _openRefiDuringLiquidation(lendingId);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);

        uint256 borrowerEthBefore = borrower.balance;
        vm.prank(borrower);
        lending.cancelRefinance(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(borrower.balance - borrowerEthBefore, FINALIZER_REWARD, "cancelRefinance caller gets bounty");
        assertFalse(loan.inLiquidation, "auto-finalize cleared liquidation");
        assertFalse(loan.curveOpen, "cancel body still runs");
    }

    function testAutoSettle_LendPaysFinalizerRewardToEntryCaller() public {
        uint256 lendingId = _setupLoanWithFinalizerReward(FINALIZER_REWARD);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);
        _openRefiDuringLiquidation(lendingId);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);

        uint256 lenderEthBefore = lender2.balance;
        vm.prank(lender2);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender2);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertEq(lender2.balance - lenderEthBefore, FINALIZER_REWARD, "lend caller gets bounty");
        assertFalse(loan.inLiquidation, "auto-finalize cleared liquidation");
        assertEq(loan.lender, lender2, "lend body still runs");
    }

    function testFinalizerReward_EscrowsAndPaysAcrossRepeatedLiquidations() public {
        uint256 lendingId = _setupLoanWithFinalizerReward(FINALIZER_REWARD);
        uint256 baselineEth = address(lending).balance;

        vm.warp(block.timestamp + 10 days);
        uint256 reportId1 = _liquidate(lendingId, 6 ether);
        assertEq(address(lending).balance, baselineEth + FINALIZER_REWARD, "first bounty escrowed");

        _disputeToNonLiquidatingPrice(reportId1, address(supplyToken), disputer);
        IOpenOracle2.OracleGame memory o1 = IOpenOracle2(address(oracle)).storedGame(reportId1);
        vm.warp(uint256(o1.reportTimestamp) + o1.settlementTime + 1);

        uint256 caller1Before = randomCaller.balance;
        vm.prank(randomCaller);
        lending.finalize(lendingId);

        assertEq(randomCaller.balance - caller1Before, FINALIZER_REWARD, "first finalizer paid");
        assertEq(address(lending).balance, baselineEth, "first bounty fully paid out");
        assertFalse(lendView.getLending(lendingId).finished, "first failed liquidation keeps loan active");

        uint256 reportId2 = _liquidate(lendingId, 6 ether);
        assertEq(address(lending).balance, baselineEth + FINALIZER_REWARD, "second bounty escrowed");

        IOpenOracle2.OracleGame memory o2 = IOpenOracle2(address(oracle)).storedGame(reportId2);
        vm.warp(uint256(o2.reportTimestamp) + o2.settlementTime + 1);

        uint256 caller2Before = lender2.balance;
        vm.prank(lender2);
        lending.finalize(lendingId);

        assertEq(lender2.balance - caller2Before, FINALIZER_REWARD, "second finalizer paid");
        assertEq(address(lending).balance, baselineEth, "second bounty fully paid out");
        assertTrue(lendView.getLending(lendingId).finished, "second underwater liquidation finishes loan");
    }

    function testFinalize_RevertsWhenNotInLiquidation() public {
        uint256 lendingId = _setupLoan();
        uint256 callerEthBefore = randomCaller.balance;

        vm.prank(randomCaller);
        vm.expectRevert(LendErrors.NotInLiquidation.selector);
        lending.finalize(lendingId);

        assertEq(randomCaller.balance, callerEthBefore, "no payout on revert");
    }

    function testFinalize_RevertsWhenNotYetSettleable() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        _liquidate(lendingId, 6 ether);
        uint256 callerEthBefore = randomCaller.balance;

        vm.prank(randomCaller);
        vm.expectRevert(LendErrors.ReportStillDisputable.selector);
        lending.finalize(lendingId);

        assertEq(randomCaller.balance, callerEthBefore, "no payout on revert");
        assertTrue(lendView.getLending(lendingId).inLiquidation, "still in liquidation");
    }

    function testDisputeAndFinalizeBoundary_NoOverlapNoGap() public {
        uint256 lendingIdBefore = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportIdBefore = _liquidate(lendingIdBefore, 6 ether);

        IOpenOracle2.OracleGame memory beforeGame = IOpenOracle2(address(oracle)).storedGame(reportIdBefore);
        vm.warp(uint256(beforeGame.reportTimestamp) + beforeGame.settlementTime - 1);

        vm.prank(randomCaller);
        vm.expectRevert(LendErrors.ReportStillDisputable.selector);
        lending.finalize(lendingIdBefore);

        _disputeAndSwap(
            reportIdBefore,
            address(supplyToken),
            uint128(uint256(beforeGame.currentAmount1) * beforeGame.multiplier / 100),
            uint128(uint256(beforeGame.currentAmount2) * 2),
            disputer,
            0,
            bytes32(0)
        );
        assertEq(IOpenOracle2(address(oracle)).storedGame(reportIdBefore).currentReporter, disputer, "T-1 dispute succeeds");

        uint256 lendingIdAt = _setupLoan();
        uint256 reportIdAt = _liquidate(lendingIdAt, 6 ether);
        IOpenOracle2.OracleGame memory atGame = IOpenOracle2(address(oracle)).storedGame(reportIdAt);
        IOpenOracle2.PreimageHelper memory atHelper = _helperFor(reportIdAt);
        vm.warp(uint256(atGame.reportTimestamp) + atGame.settlementTime);

        vm.prank(disputer);
        vm.expectRevert(Errors.DisputeTooLate.selector);
        IOpenOracle2(address(oracle)).dispute(
            reportIdAt,
            address(supplyToken),
            uint128(uint256(atGame.currentAmount1) * atGame.multiplier / 100),
            uint128(uint256(atGame.currentAmount2) * 2),
            disputer,
            false,
            false,
            atGame,
            atHelper,
            _emptyTiming()
        );

        vm.prank(randomCaller);
        lending.finalize(lendingIdAt);
        assertFalse(lendView.getLending(lendingIdAt).inLiquidation, "T finalize succeeds");
    }

    // -------------------------------------------------------------------------
    // 2. receive() / reward forwarding via WETH fallback
    // -------------------------------------------------------------------------

    function testFinalize_RewardForwardsAsWETHToEthRejecter() public {
        uint256 lendingId = _setupLoanWithFinalizerReward(FINALIZER_REWARD);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        EthRejectorCaller rejecter = new EthRejectorCaller(address(lending));
        rejecter.callSettle(lendingId);

        assertEq(weth.balanceOf(address(rejecter)), FINALIZER_REWARD, "rejecter receives finalizer reward as WETH");
        assertEq(address(rejecter).balance, 0, "no plain ETH at rejecter");
    }

    function testFinalize_EthRewardHookFallsBackToWethAndOuterCompletes() public {
        uint256 lendingId = _setupLoanWithFinalizerReward(FINALIZER_REWARD);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        ReentrantEthReceiver receiver = new ReentrantEthReceiver(address(lending));
        receiver.setPayload(abi.encodeWithSelector(lending.finalize.selector, lendingId));
        receiver.callSettle(lendingId);

        assertEq(address(receiver).balance, 0, "receiver ETH hook exceeds capped send");
        assertEq(weth.balanceOf(address(receiver)), FINALIZER_REWARD, "receiver gets WETH fallback reward");
        assertEq(IOpenOracle2(address(oracle)).tokenHolder(address(receiver), address(0)), 0, "no internal ETH credit needed");
        assertFalse(lendView.getLending(lendingId).inLiquidation, "outer settle completed");
    }

    /// @dev Pins the bug fix: even when staged gasCompensation > finalizerReward, bounty forwarding
    ///      uses finalizerReward (fixed) rather than balance delta (which would underflow).
    function testFinalize_GasCompMuchLargerThanFinalizerReward_NoUnderflow() public {
        uint96 hugeGasComp = 1 ether;
        openLend.OracleParams memory params = _standardOracleParams();
        params.finalizerReward = FINALIZER_REWARD;

        vm.prank(borrower);
        uint256 lendingId = lending.requestBorrow{value: hugeGasComp}(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            uint24(1e7),
            hugeGasComp,
            borrower,
            params,
            _standardInterestRateParams()
        );
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);

        // Borrower opens a refi mid-loan with another big gasComp staged for the next lender
        vm.prank(borrower);
        lending.refinance{value: hugeGasComp}(
            lendingId, 0, 0, 0, hugeGasComp, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max
        );

        // Liquidate; underwater settle will refund the staged gasComp via _sendGasComp.
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);
        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        uint256 borrowerEthBefore = borrower.balance;
        uint256 callerEthBefore = randomCaller.balance;

        vm.prank(randomCaller);
        lending.finalize(lendingId);

        assertEq(randomCaller.balance - callerEthBefore, FINALIZER_REWARD, "caller gets finalizerReward exactly");
        assertEq(borrower.balance - borrowerEthBefore, hugeGasComp, "borrower receives gasComp refund");
        assertTrue(lendView.getLending(lendingId).finished, "loan finished");
    }

    function testFinalize_CompletesBeforeOracleSettleAndOracleSettlePaysOracleRewardLater() public {
        uint256 lendingId = _setupLoanWithFinalizerReward(FINALIZER_REWARD);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        uint256 callerEthBefore = randomCaller.balance;

        vm.prank(randomCaller);
        lending.finalize(lendingId);

        assertEq(randomCaller.balance - callerEthBefore, FINALIZER_REWARD, "caller receives finalizer reward");
        assertEq(
            IOpenOracle2(address(oracle)).storedGame(reportId).settlerReward,
            SETTLER_REWARD,
            "oracle settler reward remains stored"
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation, "finalize cleared inLiquidation");
        assertTrue(loan.finished, "finalize finished underwater loan");
        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared");

        (,,,, uint48 settlementTimestamp,,) = _reportStatus(reportId);
        assertEq(settlementTimestamp, 0, "oracle accounting not settled by finalize");

        uint256 oracleRewardBefore = IOpenOracle2(address(oracle)).tokenHolder(settler, address(0));
        IOpenOracle2.OracleGame memory oracleGame = IOpenOracle2(address(oracle)).storedGame(reportId);
        IOpenOracle2.PreimageHelper memory helper = _helperFor(reportId);
        vm.prank(settler);
        IOpenOracle2(address(oracle)).settle(
            reportId,
            oracleGame,
            helper
        );
        uint256 oracleRewardAfter = IOpenOracle2(address(oracle)).tokenHolder(settler, address(0));
        assertEq(
            IOpenOracle2(address(oracle)).storedGame(reportId).settlerReward,
            SETTLER_REWARD,
            "oracle settle keeps stored reward field"
        );

        (,,,, uint48 settledAt,,) = _reportStatus(reportId);
        assertGt(settledAt, 0, "oracle accounting settled later");
        assertEq(
            oracleRewardAfter - oracleRewardBefore,
            SETTLER_REWARD + (oracleRewardBefore == 0 ? 1 : 0),
            "oracle settle pays oracle settler reward"
        );
    }

    function testFinalize_AfterOracleSettleFirstStillResolvesLoan() public {
        uint256 lendingId = _setupLoanWithFinalizerReward(FINALIZER_REWARD);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);

        vm.startPrank(settler);
        _settleOracleWithoutFinalize(reportId);
        vm.stopPrank();

        assertTrue(lendView.getLending(lendingId).inLiquidation, "oracle settle alone leaves loan in liquidation");
        assertGt(IOpenOracle2(address(oracle)).storedGame(reportId).settlementTimestamp, 0, "oracle settled first");

        uint256 callerEthBefore = randomCaller.balance;
        vm.prank(randomCaller);
        lending.finalize(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation, "finalize clears after prior oracle settle");
        assertTrue(loan.finished, "underwater outcome still executes");
        assertEq(randomCaller.balance - callerEthBefore, FINALIZER_REWARD, "finalizer reward paid after prior oracle settle");
        assertEq(lending.reportIdToLending(reportId), 0, "report mapping cleared");
        assertEq(lending.lendingToReportId(lendingId), 0, "loan mapping cleared");
    }

    function testGetParamHashAndAutoFinalize_AfterOracleSettleFirst() public {
        uint256 lendingId = _setupLoanWithFinalizerReward(FINALIZER_REWARD);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        IOpenOracle2.OracleGame memory o = IOpenOracle2(address(oracle)).storedGame(reportId);
        vm.warp(uint256(o.reportTimestamp) + o.settlementTime + 1);

        vm.startPrank(settler);
        _settleOracleWithoutFinalize(reportId);
        vm.stopPrank();

        assertTrue(lendView.getLending(lendingId).inLiquidation, "loan still in liquidation after oracle-only settle");
        assertGt(IOpenOracle2(address(oracle)).storedGame(reportId).settlementTimestamp, 0, "oracle settled first");

        bytes32 projectedHash = lendView.getParamHash(lendingId);
        uint256 borrowerEthBefore = borrower.balance;
        uint256 lenderBorrowBefore = borrowToken.balanceOf(lender);

        vm.prank(borrower);
        lending.repayDebt(lendingId, 5 ether, projectedHash, 0, type(uint128).max);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation, "auto-finalize clears after prior oracle settle");
        assertFalse(loan.finished, "failed liquidation leaves loan active");
        assertEq(borrower.balance - borrowerEthBefore, FINALIZER_REWARD, "auto-finalizer gets bounty");
        assertEq(borrowToken.balanceOf(lender) - lenderBorrowBefore, 5 ether, "repay body still runs");
    }

    // -------------------------------------------------------------------------
    // 3. Auto-settle failed liquidation then body succeeds
    // -------------------------------------------------------------------------

    function testAutoSettle_FailedLiq_RepayDebtSucceeds() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        // Borrower calls repayDebt. auto-finalize should:
        //   1. Finalize the failed liquidation, clearing inLiquidation and adding stake to supplyAmount.
        //   2. Run _repayDebt's body with normal post-finalize state.
        uint128 partialRepay = 5 ether;
        uint256 lenderBefore = borrowToken.balanceOf(lender);

        vm.prank(borrower);
        lending.repayDebt(lendingId, partialRepay, bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation, "inLiquidation cleared by auto-settle");
        assertFalse(loan.finished, "loan still live (failed liq)");
        // assertEq(loan.repaidDebt, partialRepay, "partial repay applied");  // [amort: removed/no-op]
        // Stake forfeit added to supplyAmount during failed branch
        uint256 expectedStake = uint256(SUPPLY_AMOUNT) * STAKE / 10000;
        assertEq(loan.supplyAmount, SUPPLY_AMOUNT + expectedStake, "stake forfeit added to supply");
        // Lender received the streamed partial
        assertEq(borrowToken.balanceOf(lender) - lenderBefore, partialRepay, "lender streamed partial");
    }

    function testAutoSettle_FailedLiq_RefinanceSucceeds() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(supplyToken), disputer);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation, "inLiquidation cleared by auto-settle");
        assertTrue(loan.curveOpen, "refi curve opened");
    }

    // -------------------------------------------------------------------------
    // 4. Auto-settle underwater then body reverts and rolls back
    // -------------------------------------------------------------------------

    function testAutoSettle_UnderwaterRollsBack() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether); // underwater ratio

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        // Snapshot state BEFORE the auto-settle attempt
        bool inLiqBefore = lendView.getLending(lendingId).inLiquidation;
        uint256 reportBefore = lending.lendingToReportId(lendingId);
        (,,,, uint48 settleTsBefore,,) = _reportStatus(reportId);
        assertTrue(inLiqBefore, "in liquidation before");
        assertGt(reportBefore, 0, "mapping populated before");
        assertEq(settleTsBefore, 0, "report not settled before");

        // Borrower calls repayDebt. autoSettle settles underwater, marks finished. _repayDebt then reverts.
        // Whole tx reverts → all state including the settle should unwind.
        vm.prank(borrower);
        vm.expectRevert(LendErrors.Finished.selector);
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);

        // Verify EVM rollback unwound everything: state matches pre-call snapshot.
        openLend.LendingArrangement memory loanAfter = lendView.getLending(lendingId);
        assertTrue(loanAfter.inLiquidation, "still in liquidation (rolled back)");
        assertFalse(loanAfter.finished, "loan not finished (rolled back)");
        assertEq(lending.lendingToReportId(lendingId), reportBefore, "mapping intact (rolled back)");
        (,,,, uint48 settleTsAfter,,) = _reportStatus(reportId);
        assertEq(settleTsAfter, 0, "oracle report not settled (rolled back)");
    }

    // -------------------------------------------------------------------------
    // 5. finalize() underwater persists (the standalone-path solves the rollback gap)
    // -------------------------------------------------------------------------

    function testFinalize_UnderwaterPersists() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether); // underwater

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        vm.prank(randomCaller);
        lending.finalize(lendingId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "loan finished underwater");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared");
    }

    // -------------------------------------------------------------------------
    // 6. finalize reentrancy — malicious supplyToken hooks fire during liquidation transfers
    // -------------------------------------------------------------------------

    /// @dev During finalize's underwater branch, malicious supplyToken's transfer hook attempts to reenter.
    ///      finalize is nonReentrant, so the nested call is rejected while the outer finalization completes.
    function testFinalize_ReentryFromFinalizeBlocked_RepayDebt() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        evil.setTarget(address(lending));
        evil.setPayload(abi.encodeWithSelector(
            lending.repayDebt.selector, lendingId, uint128(1 ether), bytes32(0), uint128(0), type(uint128).max
        ));

        vm.prank(settler);
        _settleOracle(reportId);

        assertTrue(evil.lastReentryReverted(), "reentry into repayDebt was rejected");
        assertTrue(
            _revertHasSelector(evil.lastReentryReason(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "reverted by reentrancy guard"
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "outer settlement completed despite reentry attempt");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
    }

    function testFinalize_ReentryFromFinalizeNestedFinalizeBlocked() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        evil.setTarget(address(lending));
        evil.setPayload(abi.encodeWithSelector(lending.finalize.selector, lendingId));

        vm.prank(settler);
        _settleOracle(reportId);

        assertTrue(evil.lastReentryReverted(), "nested finalize rejected");
        assertTrue(
            _revertHasSelector(evil.lastReentryReason(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "nested finalize hit reentrancy guard"
        );
        assertTrue(lendView.getLending(lendingId).finished, "outer settle completed");
    }

    function testFinalize_ReentryFromFinalize_GrabFeesDoesNotBlockSettlement() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        evil.setTarget(address(lending));
        evil.setPayload(
            abi.encodeWithSelector(lending.grabOracleGameFeesAny.selector, lendingId, reportId)
        );

        vm.prank(settler);
        _settleOracle(reportId);

        assertTrue(evil.lastReentryReverted(), "nested fee grab rejected");
        assertTrue(
            _revertHasSelector(evil.lastReentryReason(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "nested fee grab hit reentrancy guard"
        );
        assertTrue(lendView.getLending(lendingId).finished, "outer settle completed");
    }

    function testFinalize_ReentryFromFinalize_TopUpAnyoneBlockedByFinished() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        evil.setTarget(address(lending));
        evil.setPayload(abi.encodeWithSelector(
            lending.topUpCollateralAnyone.selector,
            lendingId,
            uint128(1 ether),
            bytes32(0),
            uint128(0),
            type(uint128).max
        ));

        vm.prank(settler);
        _settleOracle(reportId);

        assertTrue(evil.lastReentryReverted(), "reentry into topUpCollateralAnyone was rejected");
        assertTrue(
            _revertHasSelector(evil.lastReentryReason(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "reverted by reentrancy guard"
        );

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "outer settlement completed");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
    }

    function testFinalize_ReentryFromFinalize_RefinanceRejectedForNonBorrower() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        evil.setTarget(address(lending));
        evil.setPayload(abi.encodeWithSelector(
            lending.refinance.selector,
            lendingId,
            uint128(0),
            uint128(0),
            uint48(0),
            uint96(0),
            _standardInterestRateParams(),
            _zeroOracleParams(),
            bytes32(0),
            uint128(0),
            type(uint128).max
        ));

        vm.prank(settler);
        _settleOracle(reportId);

        assertTrue(evil.lastReentryReverted(), "reentry into refinance was rejected");
        assertTrue(
            _revertHasSelector(evil.lastReentryReason(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "reverted by reentrancy guard"
        );
        assertTrue(lendView.getLending(lendingId).finished, "outer settle completed");
    }

    function testFuzz_Finalize_ReentryPayloadSelectionDoesNotBreakSettlement(uint8 actionSeed) public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        bytes memory payload;
        uint8 action = actionSeed % 7;
        if (action == 0) {
            payload = abi.encodeWithSelector(
                lending.repayDebt.selector, lendingId, uint128(1 ether), bytes32(0), uint128(0), type(uint128).max
            );
        } else if (action == 1) {
            payload = abi.encodeWithSelector(
                lending.topUpCollateralAnyone.selector, lendingId, uint128(1 ether), bytes32(0), uint128(0), type(uint128).max
            );
        } else if (action == 2) {
            payload = abi.encodeWithSelector(
                lending.refinance.selector,
                lendingId,
                uint128(0),
                uint128(0),
                uint48(0),
                uint96(0),
                _standardInterestRateParams(),
                _zeroOracleParams(),
                bytes32(0),
                uint128(0),
                type(uint128).max
            );
        } else if (action == 3) {
            payload = abi.encodeWithSelector(lending.grabOracleGameFeesAny.selector, lendingId, reportId);
        } else if (action == 4) {
            payload = abi.encodeWithSelector(lending.finalize.selector, lendingId);
        } else if (action == 5) {
            payload = abi.encodeWithSelector(lending.claimCollateral.selector, lendingId);
        } else {
            payload = abi.encodeWithSelector(lending.finalize.selector, lendingId);
        }

        evil.setTarget(address(lending));
        evil.setPayload(payload);

        vm.prank(settler);
        _settleOracle(reportId);

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertTrue(loan.finished, "outer settlement completed for every reentry payload");
        assertFalse(loan.inLiquidation, "outer settlement cleared liquidation");
        assertEq(lending.reportIdToLending(reportId), 0, "report mapping cleared");
    }

    function testFinalize_ReentryFromFailedLiq_LendCannotStealRefiCurve() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);

        // Resolve a failed liquidation near maturity so the failed-liq branch performs an external
        // supplyToken transfer to the lender, giving the hook a chance to try `lend`.
        vm.warp(block.timestamp + LOAN_TERM - 900);
        uint256 reportId = _liquidateEvilAt(lendingId, 6 ether);
        _disputeToNonLiquidatingPrice(reportId, address(evil), disputer);

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

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        uint48 expectedRequestStart = reportTs + 300;
        vm.warp(uint256(reportTs) + 301);

        evil.setTarget(address(lending));
        evil.setPayload(abi.encodeWithSelector(
            lending.lend.selector,
            lendingId,
            bytes32(0),
            uint128(0),
            type(uint128).max,
            uint128(0),
            uint32(0),
            uint24(5e6)
        ));

        vm.prank(settler);
        _settleOracle(reportId);

        assertTrue(evil.lastReentryReverted(), "reentrant lend reverted");

        openLend.LendingArrangement memory loan = lendView.getLending(lendingId);
        assertFalse(loan.inLiquidation, "outer failed-liq settlement cleared inLiquidation");
        assertFalse(loan.finished, "loan remains live after failed liq");
        assertTrue(loan.curveOpen, "reentrant lend did not steal or close the curve");
        assertEq(loan.lender, lender, "lender unchanged");
        assertEq(loan.requestStart, expectedRequestStart, "requestStart pinned by failed-liq settlement");
    }

    function testFeeReceiver_ReentrantCollectDuringSweepNoDoubleDistribution() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvilAt(lendingId, 6 ether);
        address feeRecipient = _predictFeeReceiver(reportId);

        // Accrue a token1/supply fee to the fee receiver through a dispute.
        bytes32 stateHash = bytes32(0);
        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 61);
        _disputeAndSwap(reportId, address(evil), 20 ether, 30 ether, disputer, 12 ether, stateHash);

        uint256 borrowerBefore = IOpenOracle2(address(oracle)).tokenHolder(borrower, address(evil));
        uint256 lenderBefore = IOpenOracle2(address(oracle)).tokenHolder(lender, address(evil));
        uint256 liquidatorBefore = IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(evil));
        uint256 feeRecipientBefore = IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(evil));

        // During sweep(evil), the evil token tries to reenter collect() on the same fee receiver.
        // The receiver's own nonReentrant should reject that nested collect, while the outer sweep
        // still returns the exact amount distributed by openLend.
        evil.setTarget(feeRecipient);
        evil.setPayload(abi.encodeWithSignature("collect()"));
        evil.setAttackLimit(1);

        vm.prank(randomCaller);
        lending.grabOracleGameFeesAny(lendingId, reportId);

        assertEq(evil.attackCount(), 0, "internal fee sweep should not fire token hook");

        uint256 feeRecipientAfter = IOpenOracle2(address(oracle)).tokenHolder(feeRecipient, address(evil));
        uint256 swept = feeRecipientBefore - feeRecipientAfter;
        uint256 borrowerPiece = swept / 2;
        uint256 lenderPiece = borrowerPiece / 2;
        uint256 liquidatorPiece = swept - borrowerPiece - lenderPiece;

        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(borrower, address(evil)) - borrowerBefore,
            borrowerPiece + (borrowerBefore == 0 ? 1 : 0),
            "borrower fee piece once"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(lender, address(evil)) - lenderBefore,
            lenderPiece + (lenderBefore == 0 ? 1 : 0),
            "lender fee piece once"
        );
        assertEq(
            IOpenOracle2(address(oracle)).tokenHolder(liquidator, address(evil)) - liquidatorBefore,
            liquidatorPiece + (liquidatorBefore == 0 ? 1 : 0),
            "liquidator fee piece once"
        );
        assertEq(evil.balanceOf(feeRecipient), 0, "fee receiver fully swept");
        assertLe(feeRecipientAfter, 1, "oracle protocol fee credit collected");
    }

    /// @dev Fee sweeping redistributes oracle-internal balances, so ERC20 transfer hooks should not fire.
    function testGrabFeesDoesNotTriggerNestedFinalizeOfOtherLoan() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();

        // Two loans sharing the evil supply token: A drives the outer grabOracleGameFeesAny,
        // B would be finalized by a token hook if fee sweeping used external token transfers.
        uint256 lendingIdA = _setupLoanWithEvilSupplyToken(evil);
        uint256 lendingIdB = _setupLoanWithEvilSupplyToken(evil);

        vm.warp(block.timestamp + 10 days);

        uint256 reportIdA = _liquidateEvil(lendingIdA, evil);
        uint256 reportIdB = _liquidateEvil(lendingIdB, evil);

        // Dispute A using evil-supply as the swap-in token to populate fees in receiverA. Evil hook is silent
        // here (no payload set yet).
        bytes32 stateHashA = bytes32(0);
        (,,, uint48 reportTsA,,,) = _reportStatus(reportIdA);
        vm.warp(uint256(reportTsA) + 61);
        _disputeAndSwap(reportIdA, address(evil), 20 ether, 10 ether, disputer, 6 ether, stateHashA);

        // Warp past B's settlement window (B was never disputed, so its reportTs is the liquidation time).
        (,,, uint48 reportTsB,,,) = _reportStatus(reportIdB);
        vm.warp(uint256(reportTsB) + 301);

        // Configure evil's hook to fire ONCE: target = oracle, payload = settle(reportIdB).
        evil.setTarget(address(oracle));
        evil.setPayload(abi.encodeWithSignature("settle(uint256)", reportIdB));
        evil.setAttackLimit(1);

        // Snapshot B before the attack
        assertTrue(lendView.getLending(lendingIdB).inLiquidation, "B in liquidation pre-test");
        (,,,, uint48 settleTsBBefore,,) = _reportStatus(reportIdB);
        assertEq(settleTsBBefore, 0, "B not settled pre-test");

        vm.prank(randomCaller);
        lending.grabOracleGameFeesAny(lendingIdA, reportIdA);

        assertEq(evil.attackCount(), 0, "fee sweep should not call token transfer hook");

        (,,,, uint48 settleTsBAfter,,) = _reportStatus(reportIdB);
        assertEq(settleTsBAfter, 0, "B remains unsettled");

        openLend.LendingArrangement memory loanBAfter = lendView.getLending(lendingIdB);
        assertTrue(loanBAfter.inLiquidation, "B remains in liquidation");
        assertFalse(loanBAfter.finished, "B not finalized");
        assertEq(lending.reportIdToLending(reportIdB), lendingIdB, "B reportId mapping unchanged");
        assertEq(lending.lendingToReportId(lendingIdB), reportIdB, "B reverse mapping unchanged");
    }

    // -------------------------------------------------------------------------
    // 7. finalize nonReentrant — token hook during finalize's _transferTokens
    // -------------------------------------------------------------------------

    function testBusyLock_ReentryFromFinalizeBlocked() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        evil.setTarget(address(lending));
        evil.setPayload(abi.encodeWithSelector(
            lending.repayDebt.selector, lendingId, uint128(1 ether), bytes32(0), uint128(0), type(uint128).max
        ));

        vm.prank(randomCaller);
        lending.finalize(lendingId);

        assertTrue(evil.lastReentryReverted(), "reentry into repayDebt during finalize rejected");
        assertTrue(
            _revertHasSelector(evil.lastReentryReason(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "reverted by reentrancy guard"
        );

        assertFalse(lendView.getLending(lendingId).inLiquidation, "inLiquidation cleared by finalize");
    }

    // -------------------------------------------------------------------------
    // 8. Mapping lifecycle
    // -------------------------------------------------------------------------

    function testMappingLifecycle_LiquidatePopulatesBothDirections() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 8 ether);

        assertEq(lending.reportIdToLending(reportId), lendingId, "reportIdToLending populated");
        assertEq(lending.lendingToReportId(lendingId), reportId, "lendingToReportId populated");
    }

    function testMappingLifecycle_SuccessfulFinalizeClearsBoth() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        vm.prank(settler);
        _settleOracle(reportId);

        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared");
    }

    function testMappingLifecycle_FinalizeClearsBoth() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        vm.prank(randomCaller);
        lending.finalize(lendingId);

        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared by finalize");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared by finalize");
    }

    function testMappingLifecycle_FinalizeClearsBeforeOracleSettle() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = _reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        vm.prank(randomCaller);
        lending.finalize(lendingId);

        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared");

        (,,,, uint48 settlementTimestamp,,) = _reportStatus(reportId);
        assertEq(settlementTimestamp, 0, "oracle accounting still unsettled");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev Originate a loan with a custom (potentially malicious) supplyToken instance.
    function _setupLoanWithEvilSupplyToken(ReentrantSupplyToken evil) internal returns (uint256 lendingId) {
        // Mint evil-supply to borrower + liquidator + disputer.
        evil.mint(borrower, 10_000 ether);
        evil.mint(liquidator, 10_000 ether);
        evil.mint(disputer, 10_000 ether);

        vm.prank(borrower);
        evil.approve(address(lending), type(uint256).max);
        vm.prank(liquidator);
        evil.approve(address(lending), type(uint256).max);
        vm.prank(disputer);
        evil.approve(address(oracle), type(uint256).max);

        // Reuse the existing borrowToken for the borrow side.
        vm.prank(borrower);
        lendingId = lending.requestBorrow(
            LOAN_TERM,
            address(evil),
            address(borrowToken),
            8e6,
            SUPPLY_AMOUNT,
            BORROW_AMOUNT,
            STAKE,
            uint24(1e7),
            0,
            borrower,
            _standardOracleParams(),
            _standardInterestRateParams()
        );
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6, lender);
    }

    function _liquidateEvil(uint256 lendingId, ReentrantSupplyToken evil) internal returns (uint256 reportId) {
        evil;
        reportId = _liquidateEvilAt(lendingId, 6 ether);
    }

    function _liquidateEvilAt(uint256 lendingId, uint256 oracleAmount2Target) internal returns (uint256 reportId) {
        bytes32 paramHash = lendView.getParamHash(lendingId);
        uint64 finalizerReward = lendView.getOracleParams(lendingId).finalizerReward;
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD + finalizerReward}(
            lendingId,
            oracleAmount2Target * 1e18 / 10 ether,
            type(uint128).max,
            paramHash,
             0,
            SETTLER_REWARD, liquidator, finalizerReward, _emptyTiming()
        );
        reportId = oracle.nextReportId() - 1;
    }

    /// @dev Decode whether a low-level call's returndata contains the given custom-error selector.
    function _revertHasSelector(bytes memory returndata, bytes4 expected) internal pure returns (bool) {
        if (returndata.length < 4) return false;
        bytes4 selector;
        assembly {
            selector := mload(add(returndata, 0x20))
        }
        return selector == expected;
    }
}
