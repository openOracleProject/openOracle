// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "../../src/openLendV3.sol";
import "../../src/OpenOracle.sol";
import "../../src/oracleFeeReceiver.sol";
import "../utils/MockERC20.sol";
import "../utils/MockWETH.sol";

/// @notice Invariant handler that exercises the lend → liquidate → settle path. Bounded action set:
///         createLoan / lendLoan / liquidate / settleLatest / advanceTime. No disputes (settle resolves to whatever
///         price the liquidator initially submitted) — keeps the state machine focused on lending lifecycle, not oracle internals.
contract LiquidationInvariantHandler is Test {
    openLend public immutable lending;
    OpenOracle public immutable oracle;
    MockERC20 public immutable supplyToken;
    MockERC20 public immutable borrowToken;

    address public immutable borrower = address(0x2001);
    address public immutable lender1 = address(0x2002);
    address public immutable lender2 = address(0x2003);
    address public immutable liquidator = address(0x2004);
    address public immutable settler = address(0x2005);

    uint256[] internal lendingIds;
    mapping(uint256 => uint256) public openReportId; // lendingId -> reportId or 0 if no in-flight

    uint48 internal constant LOAN_TERM = 30 days;
    uint24 internal constant LIQUIDATION_THRESHOLD = 8e6;
    uint16 internal constant STAKE = 100;

    constructor(openLend _lending, OpenOracle _oracle, MockERC20 _supplyToken, MockERC20 _borrowToken) {
        lending = _lending;
        oracle = _oracle;
        supplyToken = _supplyToken;
        borrowToken = _borrowToken;
    }

    function prime() external {
        address[5] memory accounts = [borrower, lender1, lender2, liquidator, settler];
        for (uint256 i = 0; i < accounts.length; i++) {
            supplyToken.transfer(accounts[i], 50_000 ether);
            borrowToken.transfer(accounts[i], 50_000 ether);
            vm.deal(accounts[i], 100 ether);
        }

        vm.startPrank(borrower);
        supplyToken.approve(address(lending), type(uint256).max);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lender1);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lender2);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(liquidator);
        supplyToken.approve(address(lending), type(uint256).max);
        borrowToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }

    function loanCount() external view returns (uint256) {
        return lendingIds.length;
    }

    function getLoanId(uint256 idx) external view returns (uint256) {
        return lendingIds[idx];
    }

    function createLoan(uint96 supplySeed, uint96 borrowSeed) external {
        if (lendingIds.length >= 6) return;

        uint128 supplyAmount = uint128(bound(supplySeed, 100 ether, 5_000 ether));
        uint128 maxBorrow = uint128((uint256(supplyAmount) * 70) / 100);
        if (maxBorrow == 0) return;
        uint128 borrowAmount = uint128(bound(borrowSeed, 1 ether, maxBorrow));

        vm.startPrank(borrower);
        try lending.requestBorrow(
            LOAN_TERM,
            address(supplyToken),
            address(borrowToken),
            LIQUIDATION_THRESHOLD,
            supplyAmount,
            borrowAmount,
            STAKE,
            uint24(1e7),
            0,
            _standardOracleParams(),
            _standardInterestRateParams()
        ) returns (uint256 lendingId) {
            lendingIds.push(lendingId);
        } catch {}
        vm.stopPrank();
    }

    function lendLoan(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (loan.cancelled || loan.active || loan.finished || !loan.curveOpen) return;

        vm.startPrank(lender1);
        try lending.lend(lendingId, bytes32(0), 0, type(uint128).max, 0, 0, 5e6) {} catch {}
        vm.stopPrank();
    }

    function liquidateLoan(uint256 loanSeed, uint96 priceSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        openLend.LendingArrangement memory loan = lending.getLending(lendingId);
        if (loan.cancelled || loan.finished || !loan.active || loan.inLiquidation) return;
        if (loan.gracePeriod != 0) return;
        if (block.timestamp > uint256(loan.start) + loan.term) return;

        // priceRatio in 1e18 fixed-point; bound between 0.5e18 and 2e18 for sane oracle states
        uint256 priceRatio = bound(uint256(priceSeed), 5e17, 2e18);
        bytes32 paramHash = lending.getParamHash(lendingId);

        vm.startPrank(liquidator);
        try lending.liquidate{value: 1e15}(lendingId, priceRatio, type(uint128).max, paramHash, 0, 1e15) {
            uint256 reportId = oracle.nextReportId() - 1;
            openReportId[lendingId] = reportId;
        } catch {}
        vm.stopPrank();
    }

    function settleLatest(uint256 loanSeed) external {
        if (lendingIds.length == 0) return;
        uint256 lendingId = lendingIds[loanSeed % lendingIds.length];
        uint256 reportId = openReportId[lendingId];
        if (reportId == 0) return;

        // Make sure we're past the settlement window
        vm.warp(block.timestamp + 400);

        vm.startPrank(settler);
        try oracle.settle(reportId) {
            openReportId[lendingId] = 0;
        } catch {}
        vm.stopPrank();
    }

    function advanceTime(uint32 timeSeed) external {
        uint256 jump = bound(uint256(timeSeed), 1 hours, 3 days);
        vm.warp(block.timestamp + jump);
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
}

contract LiquidationInvariantsTest is StdInvariant, Test {
    openLend internal lending;
    OpenOracle internal oracle;
    MockERC20 internal supplyToken;
    MockERC20 internal borrowToken;
    LiquidationInvariantHandler internal handler;

    function setUp() public {
        oracle = new OpenOracle();
        MockWETH weth = new MockWETH();
        lending = new openLend(IOpenOracle(address(oracle)), address(weth));
        supplyToken = new MockERC20("Supply Token", "SUP");
        borrowToken = new MockERC20("Borrow Token", "BOR");

        handler = new LiquidationInvariantHandler(lending, oracle, supplyToken, borrowToken);
        supplyToken.transfer(address(handler), 300_000 ether);
        borrowToken.transfer(address(handler), 300_000 ether);
        handler.prime();
        targetContract(address(handler));
    }

    /// @notice After settlement the loan must NOT remain in `inLiquidation`.
    function invariant_settlementClearsInLiquidation() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            if (handler.openReportId(lendingId) == 0) {
                // No in-flight liq tracked for this loan → must not be inLiquidation
                assertFalse(loan.inLiquidation, "no tracked report but inLiquidation == true");
            }
        }
    }

    /// @notice A finished loan must not have an in-flight oracle report tracked.
    function invariant_finishedHasNoOpenReport() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            if (loan.finished) {
                assertEq(handler.openReportId(lendingId), 0, "finished loan should have no tracked report");
            }
        }
    }

    /// @notice The contract's supply balance always covers active-loan supplyAmounts plus in-flight liquidator stakes.
    function invariant_contractSupplyCoversActiveLoansAndStakes() public view {
        uint256 count = handler.loanCount();
        uint256 required;
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            if (!loan.cancelled && !loan.finished) {
                required += loan.supplyAmount;
                if (loan.inLiquidation) {
                    required += (uint256(loan.supplyAmount) * loan.stake) / 10000;
                }
            }
        }
        assertEq(
            supplyToken.balanceOf(address(lending)),
            required,
            "contract supplyToken balance should reconcile to active loans + in-flight stakes"
        );
    }

    /// @notice Amortization-state invariant for loans driven through the liquidation handler:
    ///         interestPaid is bounded by the lender's interest claim (`max(commitmentInterest, interestAccrued)`)
    ///         and lastTouch never advances past `start + term`. Note: `principal + interestAccrued` is NOT a lower
    ///         bound on `interestPaid` — borrowers can prepay into the floor surplus, which is why
    ///         `_liquidationOwed` clamps explicitly at 0.
    function invariant_amortStateConsistent() public view {
        uint256 count = handler.loanCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 lendingId = handler.getLoanId(i);
            openLend.LendingArrangement memory loan = lending.getLending(lendingId);
            if (loan.principal == 0 && loan.commitmentInterest == 0) continue;

            uint256 interestClaim = loan.interestAccrued > loan.commitmentInterest
                ? uint256(loan.interestAccrued)
                : uint256(loan.commitmentInterest);
            assertLe(uint256(loan.interestPaid), interestClaim,
                "interestPaid <= max(commitmentInterest, interestAccrued)");

            if (loan.start != 0 && loan.term != 0) {
                uint256 termEnd = uint256(loan.start) + uint256(loan.term);
                assertLe(uint256(loan.lastTouch), termEnd, "lastTouch never exceeds start + term");
            }
        }
    }
}
