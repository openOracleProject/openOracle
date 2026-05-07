// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./OpenLendingBase.t.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------------------
// Helper: a contract that can call settleLiquidation but rejects incoming ETH
// (no receive / fallback). Used to exercise _payEth's WETH wrap fallback.
// ---------------------------------------------------------------------------
contract EthRejectorCaller {
    openLend public lending;

    constructor(address _lending) {
        lending = openLend(payable(_lending));
    }

    function callSettle(uint256 lendingId) external {
        lending.settleLiquidation(lendingId);
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
        lending.settleLiquidation(lendingId);
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
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6);
    }

    function _liquidate(uint256 lendingId, uint256 oracleAmount2Target) internal returns (uint256 reportId) {
        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId,
            oracleAmount2Target * 1e18 / 10 ether,
            type(uint128).max,
            paramHash,
            0
        , SETTLER_REWARD);
        reportId = oracle.nextReportId() - 1;
    }

    // -------------------------------------------------------------------------
    // 1. settleLiquidation() happy path
    // -------------------------------------------------------------------------

    function testSettleLiquidation_HappyPath_ClearsStateAndPaysCaller() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        // Warp past settlement window
        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        uint256 callerEthBefore = randomCaller.balance;
        vm.prank(randomCaller);
        lending.settleLiquidation(lendingId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared");
        assertEq(randomCaller.balance - callerEthBefore, SETTLER_REWARD, "caller receives settler reward");
    }

    function testSettleLiquidation_NoOpWhenNotInLiquidation() public {
        uint256 lendingId = _setupLoan();
        // Loan never went to liquidation.
        uint256 callerEthBefore = randomCaller.balance;

        vm.prank(randomCaller);
        lending.settleLiquidation(lendingId); // no revert

        assertEq(randomCaller.balance, callerEthBefore, "no payout on no-op");
    }

    function testSettleLiquidation_NoOpWhenNotYetSettleable() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        _liquidate(lendingId, 6 ether);
        // Don't warp past settle window
        uint256 callerEthBefore = randomCaller.balance;

        vm.prank(randomCaller);
        lending.settleLiquidation(lendingId); // early return inside _settleHelper

        assertEq(randomCaller.balance, callerEthBefore, "no payout when not settleable");
        assertTrue(lending.getLending(lendingId).inLiquidation, "still in liquidation");
    }

    // -------------------------------------------------------------------------
    // 2. receive() / reward forwarding via WETH fallback
    // -------------------------------------------------------------------------

    function testSettleLiquidation_RewardForwardsAsWETHToEthRejecter() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        EthRejectorCaller rejecter = new EthRejectorCaller(address(lending));
        rejecter.callSettle(lendingId);

        // Direct ETH send to rejecter fails → _payEth falls back to WETH.
        assertEq(weth.balanceOf(address(rejecter)), SETTLER_REWARD, "rejecter receives settler reward as WETH");
        assertEq(address(rejecter).balance, 0, "no plain ETH at rejecter");
    }

    function testSettleLiquidation_EthRewardHookFallsBackToWethAndOuterCompletes() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 12 ether);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        ReentrantEthReceiver receiver = new ReentrantEthReceiver(address(lending));
        receiver.setPayload(abi.encodeWithSelector(lending.settleLiquidation.selector, lendingId));
        receiver.callSettle(lendingId);

        // The 40k ETH send cannot complete a useful reentry attempt, so _payEth falls back to WETH.
        assertEq(address(receiver).balance, 0, "direct ETH path failed");
        assertEq(weth.balanceOf(address(receiver)), SETTLER_REWARD, "receiver gets settler reward as WETH");
        assertFalse(lending.getLending(lendingId).inLiquidation, "outer settle completed");
    }

    /// @dev Pins the bug fix: even when staged gasCompensation > settlerReward, settler reward forwarding
    ///      uses meta.settlerReward (fixed) rather than balance delta (which would underflow).
    function testSettleLiquidation_GasCompMuchLargerThanSettlerReward_NoUnderflow() public {
        // Borrower opens a loan with a large gasCompensation (way bigger than the 1e15 settler reward).
        uint96 hugeGasComp = 1 ether; // 10000x the settler reward
        uint256 lendingId =
            _requestBorrowFlex(borrower, SUPPLY_AMOUNT, BORROW_AMOUNT, LOAN_TERM, uint24(1e7), hugeGasComp);
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6);

        // Borrower opens a refi mid-loan with another big gasComp staged for the next lender
        vm.prank(borrower);
        lending.refinance{value: hugeGasComp}(
            lendingId, 0, 0, 0, hugeGasComp, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max
        );

        // Liquidate; underwater settle will refund the staged gasComp via _sendGasComp.
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);
        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        uint256 borrowerEthBefore = borrower.balance;
        uint256 callerEthBefore = randomCaller.balance;

        vm.prank(randomCaller);
        lending.settleLiquidation(lendingId);

        // Caller gets exactly the settler reward (fixed amount from meta.settlerReward).
        assertEq(randomCaller.balance - callerEthBefore, SETTLER_REWARD, "caller gets meta.settlerReward exactly");
        // Borrower gets the staged gasComp refunded by onSettle's underwater branch.
        assertEq(borrower.balance - borrowerEthBefore, hugeGasComp, "borrower receives gasComp refund");
        // Loan is finished underwater
        assertTrue(lending.getLending(lendingId).finished, "loan finished");
    }

    /// @dev settleLiquidation should still pay the caller the settler reward and leave the loan in stuck-callback
    ///      state when onSettle reverts mid-callback. Then recover() executes the settled oracle outcome.
    function testSettleLiquidation_FailedCallback_PaysCallerAndLeavesStuckState() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        // Force the onSettle callback to revert. oracle.settle still proceeds and pays the settler reward
        // to msg.sender (= openLend) before the callback. _settleHelper's try/catch swallows the callback
        // failure; settled stays true; reward forwards to the caller.
        vm.mockCallRevert(
            address(lending), abi.encodeWithSelector(openLend.onSettle.selector), "callback bricked"
        );

        uint256 callerEthBefore = randomCaller.balance;

        vm.prank(randomCaller);
        lending.settleLiquidation(lendingId);

        vm.clearMockedCalls();

        // Caller received the settler reward via _payEth.
        assertEq(
            randomCaller.balance - callerEthBefore,
            SETTLER_REWARD,
            "caller receives settler reward despite callback failure"
        );

        // Loan is in stuck-callback state — oracle settled, but openLend's state is unchanged.
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.inLiquidation, "still in liquidation (onSettle reverted)");
        assertFalse(loan.finished, "not finished (onSettle didn't run)");
        assertEq(lending.reportIdToLending(reportId), lendingId, "reportIdToLending preserved");
        assertEq(lending.lendingToReportId(lendingId), reportId, "lendingToReportId preserved");

        (,,,, uint48 settlementTimestamp,,) = oracle.reportStatus(reportId);
        assertGt(settlementTimestamp, 0, "oracle marked the report settled");

        // recover() unsticks by executing the same underwater liquidation outcome.
        uint256 recoverCallerEthBefore = randomCaller.balance;
        vm.prank(randomCaller);
        lending.recover(reportId);

        openLend.LendingArrangement memory loanRecovered = lending.getLending(lendingId);
        assertFalse(loanRecovered.inLiquidation, "recover cleared inLiquidation");
        assertTrue(loanRecovered.finished, "recover finished underwater loan");
        assertEq(loanRecovered.liquidator, liquidator, "successful liquidation keeps liquidator breadcrumb");
        assertEq(lending.reportIdToLending(reportId), 0, "recover cleared reportIdToLending");
        assertEq(lending.lendingToReportId(lendingId), 0, "recover cleared lendingToReportId");
        // recover doesn't pay a settler reward — its own settler-reward forwarding only fires when settle
        // happened mid-recover (it didn't here).
        assertEq(randomCaller.balance, recoverCallerEthBefore, "recover doesn't double-pay settler reward");
    }

    // -------------------------------------------------------------------------
    // 3. Auto-settle failed liquidation then body succeeds
    // -------------------------------------------------------------------------

    function testAutoSettle_FailedLiq_RepayDebtSucceeds() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 12 ether); // favorable ratio → failed liq

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        // Borrower calls repayDebt. autoSettle modifier should:
        //   1. Trigger oracle.settle.
        //   2. onSettle's failed branch fires, clearing inLiquidation and adding stake to supplyAmount.
        //   3. _repayDebt's body runs with normal post-settle state.
        uint128 partialRepay = 5 ether;
        uint256 lenderBefore = borrowToken.balanceOf(lender);

        vm.prank(borrower);
        lending.repayDebt(lendingId, partialRepay, bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
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
        uint256 reportId = _liquidate(lendingId, 12 ether);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        vm.prank(borrower);
        lending.refinance(lendingId, 0, 0, 0, 0, _standardInterestRateParams(), _zeroOracleParams(), bytes32(0), 0, type(uint128).max);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
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

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        // Snapshot state BEFORE the auto-settle attempt
        bool inLiqBefore = lending.getLending(lendingId).inLiquidation;
        uint256 reportBefore = lending.lendingToReportId(lendingId);
        (,,,, uint48 settleTsBefore,,) = oracle.reportStatus(reportId);
        assertTrue(inLiqBefore, "in liquidation before");
        assertGt(reportBefore, 0, "mapping populated before");
        assertEq(settleTsBefore, 0, "report not settled before");

        // Borrower calls repayDebt. autoSettle settles underwater, marks finished. _repayDebt then reverts.
        // Whole tx reverts → all state including the settle should unwind.
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(openLend.InvalidInput.selector, "arrangement finished"));
        lending.repayDebt(lendingId, 1 ether, bytes32(0), 0, type(uint128).max);

        // Verify EVM rollback unwound everything: state matches pre-call snapshot.
        openLend.LendingArrangement memory loanAfter = lending.getLending(lendingId);
        assertTrue(loanAfter.inLiquidation, "still in liquidation (rolled back)");
        assertFalse(loanAfter.finished, "loan not finished (rolled back)");
        assertEq(lending.lendingToReportId(lendingId), reportBefore, "mapping intact (rolled back)");
        (,,,, uint48 settleTsAfter,,) = oracle.reportStatus(reportId);
        assertEq(settleTsAfter, 0, "oracle report not settled (rolled back)");
    }

    // -------------------------------------------------------------------------
    // 5. settleLiquidation() underwater persists (the standalone-path solves the rollback gap)
    // -------------------------------------------------------------------------

    function testSettleLiquidation_UnderwaterPersists() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether); // underwater

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        vm.prank(randomCaller);
        lending.settleLiquidation(lendingId);

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.finished, "loan finished underwater");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared");
    }

    // -------------------------------------------------------------------------
    // 6. Naked onSettle reentrancy — malicious supplyToken hooks fire during onSettle
    // -------------------------------------------------------------------------

    /// @dev During onSettle's underwater branch, malicious supplyToken's transfer hook attempts to reenter.
    ///      Since onSettle is naked, the loan's terminal state is what blocks repayDebt.
    function testOnSettle_ReentryFromOnSettleBlocked_RepayDebt() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        evil.setTarget(address(lending));
        evil.setPayload(abi.encodeWithSelector(
            lending.repayDebt.selector, lendingId, uint128(1 ether), bytes32(0), uint128(0), type(uint128).max
        ));

        vm.prank(settler);
        oracle.settle(reportId);

        assertTrue(evil.lastReentryReverted(), "reentry into repayDebt was rejected");
        assertTrue(_revertHasMessage(evil.lastReentryReason(), "not borrower"), "reverted because reentrant caller is not borrower");

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.finished, "outer settlement completed despite reentry attempt");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
    }

    function testOnSettle_ReentryFromOnSettle_SettleLiquidationNoOps() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        evil.setTarget(address(lending));
        evil.setPayload(abi.encodeWithSelector(lending.settleLiquidation.selector, lendingId));

        vm.prank(settler);
        oracle.settle(reportId);

        assertFalse(evil.lastReentryReverted(), "nested settleLiquidation no-ops");
        assertTrue(lending.getLending(lendingId).finished, "outer settle completed");
    }

    function testOnSettle_ReentryFromOnSettle_GrabFeesDoesNotBlockSettlement() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        evil.setTarget(address(lending));
        evil.setPayload(
            abi.encodeWithSelector(lending.grabOracleGameFeesAny.selector, lendingId, reportId)
        );

        vm.prank(settler);
        oracle.settle(reportId);

        assertFalse(evil.lastReentryReverted(), "nested fee grab does not block settlement");
        assertTrue(lending.getLending(lendingId).finished, "outer settle completed");
    }

    function testOnSettle_ReentryFromOnSettle_TopUpAnyoneBlockedByFinished() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
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
        oracle.settle(reportId);

        assertTrue(evil.lastReentryReverted(), "reentry into topUpCollateralAnyone was rejected");
        assertTrue(
            _revertHasMessage(evil.lastReentryReason(), "arrangement finished"),
            "reverted because underwater settlement already marked finished"
        );

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        assertTrue(loan.finished, "outer settlement completed");
        assertFalse(loan.inLiquidation, "inLiquidation cleared");
    }

    function testOnSettle_ReentryFromOnSettle_RefinanceRejectedForNonBorrower() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
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
        oracle.settle(reportId);

        assertTrue(evil.lastReentryReverted(), "reentry into refinance was rejected");
        assertTrue(_revertHasMessage(evil.lastReentryReason(), "not borrower"), "only borrower can refinance");
        assertTrue(lending.getLending(lendingId).finished, "outer settle completed");
    }

    function testOnSettle_ReentryFromFailedLiq_LendCannotStealRefiCurve() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);

        // Resolve a failed liquidation near maturity so the failed-liq branch performs an external
        // supplyToken transfer to the lender, giving the hook a chance to try `lend`.
        vm.warp(block.timestamp + LOAN_TERM - 900);
        uint256 reportId = _liquidateEvilAt(lendingId, 12 ether);

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

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
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
        oracle.settle(reportId);

        assertTrue(evil.lastReentryReverted(), "reentrant lend reverted");

        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
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
        uint256 reportId = _liquidateEvilAt(lendingId, 12 ether);
        address feeRecipient = _predictFeeReceiver(reportId);

        // Accrue a token1/supply fee to the fee receiver through a dispute.
        (bytes32 stateHash,,,,,,) = oracle.extraData(reportId);
        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 61);
        vm.prank(disputer);
        oracle.disputeAndSwap(reportId, address(evil), 20 ether, 30 ether, disputer, 12 ether, stateHash);

        uint256 borrowerBefore = evil.balanceOf(borrower);
        uint256 lenderBefore = evil.balanceOf(lender);
        uint256 liquidatorBefore = evil.balanceOf(liquidator);

        // During sweep(evil), the evil token tries to reenter collect() on the same fee receiver.
        // The receiver's own nonReentrant should reject that nested collect, while the outer sweep
        // still returns the exact amount distributed by openLend.
        evil.setTarget(feeRecipient);
        evil.setPayload(abi.encodeWithSignature("collect()"));
        evil.setAttackLimit(1);

        vm.prank(randomCaller);
        lending.grabOracleGameFeesAny(lendingId, reportId);

        assertTrue(evil.lastReentryReverted(), "fee receiver rejected nested collect during sweep");
        assertEq(evil.attackCount(), 1, "attack fired once during sweep");

        uint256 expectedFee = 10 ether * 100_000 / 1e7;
        uint256 borrowerPiece = expectedFee / 2;
        uint256 lenderPiece = borrowerPiece / 2;
        uint256 liquidatorPiece = expectedFee - borrowerPiece - lenderPiece;

        assertEq(evil.balanceOf(borrower) - borrowerBefore, borrowerPiece, "borrower fee piece once");
        assertEq(evil.balanceOf(lender) - lenderBefore, lenderPiece, "lender fee piece once");
        assertEq(evil.balanceOf(liquidator) - liquidatorBefore, liquidatorPiece, "liquidator fee piece once");
        assertEq(evil.balanceOf(feeRecipient), 0, "fee receiver fully swept");
        assertEq(oracle.protocolFees(feeRecipient, address(evil)), 0, "oracle protocol fee credit collected");
    }

    /// @dev Inverse direction: while `grabOracleGameFeesAny` is sweeping fees for loan A, an evil-supply-token
    ///      transfer hook settles loan B. Naked onSettle should finalize B instead of leaving it stuck.
    function testGrabFeesAllowsNestedOnSettleToFinalizeOtherLoan() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();

        // Two loans sharing the evil supply token: A drives the outer grabOracleGameFeesAny,
        // B is the would-be settle victim whose onSettle the inner reentry will try to fire.
        uint256 lendingIdA = _setupLoanWithEvilSupplyToken(evil);
        uint256 lendingIdB = _setupLoanWithEvilSupplyToken(evil);

        vm.warp(block.timestamp + 10 days);

        uint256 reportIdA = _liquidateEvil(lendingIdA, evil);
        uint256 reportIdB = _liquidateEvil(lendingIdB, evil);

        // Dispute A using evil-supply as the swap-in token to populate fees in receiverA. Evil hook is silent
        // here (no payload set yet).
        (bytes32 stateHashA,,,,,,) = oracle.extraData(reportIdA);
        (,,, uint48 reportTsA,,,) = oracle.reportStatus(reportIdA);
        vm.warp(uint256(reportTsA) + 61);
        vm.prank(disputer);
        oracle.disputeAndSwap(reportIdA, address(evil), 20 ether, 10 ether, disputer, 6 ether, stateHashA);

        // Warp past B's settlement window (B was never disputed, so its reportTs is the liquidation time).
        (,,, uint48 reportTsB,,,) = oracle.reportStatus(reportIdB);
        vm.warp(uint256(reportTsB) + 301);

        // Configure evil's hook to fire ONCE: target = oracle, payload = settle(reportIdB).
        evil.setTarget(address(oracle));
        evil.setPayload(abi.encodeWithSignature("settle(uint256)", reportIdB));
        evil.setAttackLimit(1);

        // Snapshot B before the attack
        assertTrue(lending.getLending(lendingIdB).inLiquidation, "B in liquidation pre-test");
        (,,,, uint48 settleTsBBefore,,) = oracle.reportStatus(reportIdB);
        assertEq(settleTsBBefore, 0, "B not settled pre-test");

        // Outer call runs _grabOracleGameFees on A. The fee-receiver sweep fires evil's transfer hook.
        // The hook calls oracle.settle(B); naked onSettle finalizes B.
        vm.prank(randomCaller);
        lending.grabOracleGameFeesAny(lendingIdA, reportIdA);

        assertFalse(evil.lastReentryReverted(), "nested oracle.settle completed");
        assertEq(evil.attackCount(), 1, "exactly one attack fired");

        (,,,, uint48 settleTsBAfter,,) = oracle.reportStatus(reportIdB);
        assertGt(settleTsBAfter, 0, "oracle marked B settled");

        openLend.LendingArrangement memory loanBAfter = lending.getLending(lendingIdB);
        assertFalse(loanBAfter.inLiquidation, "B inLiquidation cleared by nested onSettle");
        assertTrue(loanBAfter.finished, "B finished underwater");
        assertEq(lending.reportIdToLending(reportIdB), 0, "B reportId mapping cleared");
        assertEq(lending.lendingToReportId(lendingIdB), 0, "B reverse mapping cleared");
    }

    // -------------------------------------------------------------------------
    // 7. recover() nonReentrant — callback during recover's _transferTokens
    // -------------------------------------------------------------------------

    function testBusyLock_ReentryFromRecoverBlocked() public {
        ReentrantSupplyToken evil = new ReentrantSupplyToken();
        uint256 lendingId = _setupLoanWithEvilSupplyToken(evil);
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidateEvil(lendingId, evil);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        // Settle on oracle side but force callback to fail so recover() is the path forward.
        vm.mockCallRevert(
            address(lending), abi.encodeWithSelector(openLend.onSettle.selector), "callback bricked"
        );
        vm.prank(settler);
        oracle.settle(reportId);
        vm.clearMockedCalls();

        // Now configure malicious token to attempt reentry, then call recover().
        evil.setTarget(address(lending));
        evil.setPayload(abi.encodeWithSelector(
            lending.repayDebt.selector, lendingId, uint128(1 ether), bytes32(0), uint128(0), type(uint128).max
        ));

        // recover() does _transferTokens(supplyToken, this, liquidator, tokenStake) — fires hook.
        vm.prank(randomCaller);
        lending.recover(reportId);

        assertTrue(evil.lastReentryReverted(), "reentry into repayDebt during recover rejected");
        // recover() carries nonReentrant. The invariant we care about is rejection.

        assertFalse(lending.getLending(lendingId).inLiquidation, "inLiquidation cleared by recover");
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

    function testMappingLifecycle_SuccessfulOnSettleClearsBoth() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        vm.prank(settler);
        oracle.settle(reportId);

        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared");
    }

    function testMappingLifecycle_RecoverClearsBoth() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        // Force broken callback path
        vm.mockCallRevert(
            address(lending), abi.encodeWithSelector(openLend.onSettle.selector), "callback bricked"
        );
        vm.prank(settler);
        oracle.settle(reportId);
        vm.clearMockedCalls();

        // Both mappings still set since onSettle reverted
        assertEq(lending.reportIdToLending(reportId), lendingId, "still populated post-failed-callback");
        assertEq(lending.lendingToReportId(lendingId), reportId, "still populated post-failed-callback");

        vm.prank(randomCaller);
        lending.recover(reportId);

        assertEq(lending.reportIdToLending(reportId), 0, "reportIdToLending cleared by recover");
        assertEq(lending.lendingToReportId(lendingId), 0, "lendingToReportId cleared by recover");
    }

    function testMappingLifecycle_FailedCallbackBeforeRecoverLeavesBoth() public {
        uint256 lendingId = _setupLoan();
        vm.warp(block.timestamp + 10 days);
        uint256 reportId = _liquidate(lendingId, 6 ether);

        (,,, uint48 reportTs,,,) = oracle.reportStatus(reportId);
        vm.warp(uint256(reportTs) + 301);

        vm.mockCallRevert(
            address(lending), abi.encodeWithSelector(openLend.onSettle.selector), "callback bricked"
        );
        vm.prank(settler);
        oracle.settle(reportId);
        vm.clearMockedCalls();

        // BEFORE calling recover, mappings should still be set (the canary signaling stuck state).
        assertEq(lending.reportIdToLending(reportId), lendingId, "reportIdToLending preserved (stuck canary)");
        assertEq(lending.lendingToReportId(lendingId), reportId, "lendingToReportId preserved (stuck canary)");
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
            _standardOracleParams(),
            _standardInterestRateParams()
        );
        vm.prank(lender);
        lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6);
    }

    function _liquidateEvil(uint256 lendingId, ReentrantSupplyToken evil) internal returns (uint256 reportId) {
        evil;
        reportId = _liquidateEvilAt(lendingId, 6 ether);
    }

    function _liquidateEvilAt(uint256 lendingId, uint256 oracleAmount2Target) internal returns (uint256 reportId) {
        bytes32 paramHash = lending.getParamHash(lendingId);
        vm.prank(liquidator);
        lending.liquidate{value: SETTLER_REWARD}(
            lendingId,
            oracleAmount2Target * 1e18 / 10 ether,
            type(uint128).max,
            paramHash,
            0
        , SETTLER_REWARD);
        reportId = oracle.nextReportId() - 1;
    }

    /// @dev Decode whether a low-level call's returndata contains the given Error(string) message.
    function _revertHasMessage(bytes memory returndata, string memory expected) internal pure returns (bool) {
        // Error(string) selector = 0x08c379a0
        if (returndata.length < 4) return false;
        bytes4 selector;
        assembly {
            selector := mload(add(returndata, 0x20))
        }
        if (selector != 0x08c379a0) {
            // Could be a custom error (InvalidInput(string) = bytes4 of "InvalidInput(string)")
            // InvalidInput(string) selector
            bytes4 invInput = bytes4(keccak256("InvalidInput(string)"));
            if (selector != invInput) return false;
        }
        // Decode string from returndata[4:]
        bytes memory data = new bytes(returndata.length - 4);
        for (uint256 i = 0; i < data.length; i++) {
            data[i] = returndata[i + 4];
        }
        string memory reason = abi.decode(data, (string));
        return keccak256(bytes(reason)) == keccak256(bytes(expected));
    }
}
