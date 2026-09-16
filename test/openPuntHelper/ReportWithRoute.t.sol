// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Min, OpenPuntHelperBase} from "./OpenPuntHelperBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";
import {OpenPuntStorage} from "../../src/levered-swaps/OpenPuntStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice `reportWithRoute`: sourcing both active-report oracle legs and the native execution
 *         compensation, then opening a genuine report on a live position.
 *
 * @dev The third obligation is always ETH. `reportWithRoute` calls
 *      `_addAsset(funding, ETH, executionComp, route.suppliedAmount3)` unconditionally, so ETH is
 *      always an aggregated asset — even when both amounts are zero. Two consequences are pinned
 *      below: `assetCount` is 3 whenever neither oracle token is ETH, and ETH can never be a
 *      separate route input here, because `_containsToken` always finds it.
 *
 *      ETH routing is still fully reachable, just through that same entry:
 *          suppliedAmount3 = executionComp + routeBudget, inputToken = 0, maxSwapInput = routeBudget
 *      `_suppliedSurplus` then exposes only the amount above the execution compensation to the router.
 *
 *      Every success path decodes `PositionReportStarted`, reconstructs the stored swap hash from
 *      the emitted struct, settles the genuine report
 *      game, and executes it through the core — as either a reusable healthy report or a terminal
 *      close.
 */
contract ReportWithRouteTest is OpenPuntHelperBase {
    uint256 internal swapId;
    OpenPuntStorage.MatchedSwap internal active;
    OpenPuntStorage.MatcherPreimage internal activePreimage;

    function setUp() public override {
        super.setUp();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));
        _approveReporterLegs(designatedReporter, address(tokenA), address(tokenB));
        _approveReporterLegs(attacker, address(tokenA), address(tokenB));

        // A real live position: propose -> match -> settle -> execute.
        Proposal memory p = _propose();
        activePreimage = p.preimage;
        Matched memory mt = _matchSwap(p);
        _advanceToSettlementEligibility();
        active = _executeOpening(mt, executor);
        swapId = p.swapId;
    }

    // ────────────────────────────────────────────────────────────────────
    //  no route
    // ────────────────────────────────────────────────────────────────────

    function test_fullySuppliedReportWithNoRoute() public {
        uint256 a0 = tokenA.balanceOf(funder);
        uint256 b0 = tokenB.balanceOf(funder);
        uint256 e0 = funder.balance;

        Matched memory rep = _report(
            designatedReporter, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, false), REPORT_EXEC_COMP
        );

        assertEq(a0 - tokenA.balanceOf(funder), INITIAL_LIQUIDITY, "oracle leg 1 debit");
        assertEq(b0 - tokenB.balanceOf(funder), AMOUNT2, "oracle leg 2 debit");
        assertEq(e0 - funder.balance, REPORT_EXEC_COMP, "execution compensation debit");
        assertEq(rep.game.currentReporter, designatedReporter, "the designated party must be the oracle reporter");
        _assertReportedAndExecutable(rep);
        _assertHelperClean();
    }

    /// @dev Excess ETH is accepted because report compensation always tracks ETH, then refunded.
    function test_reportRefundsExcessMsgValue() public {
        uint256 e0 = funder.balance;
        vm.prank(funder);
        helper.reportWithRoute{value: REPORT_EXEC_COMP + 1}(
            swapId,
            bytes32(0),
            active,
            activePreimage,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, false),
            router
        );

        assertEq(e0 - funder.balance, REPORT_EXEC_COMP, "excess ETH was not refunded");
        assertEq(address(helper).balance, 0, "helper retained excess ETH");
    }

    function test_reportRejectsInsufficientMsgValue() public {
        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMsgValue.selector);
        helper.reportWithRoute{value: REPORT_EXEC_COMP - 1}(
            swapId,
            bytes32(0),
            active,
            activePreimage,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, false),
            router
        );
    }

    /// @dev Reporting twice is rejected because the report sidecar is already live. Active reports
    ///      do not change the position hash, so the original active preimage remains canonical.
    function test_anExistingActiveReportBlocksASecondOne() public {
        Matched memory first = _report(
            designatedReporter, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, false), REPORT_EXEC_COMP
        );

        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("OracleGameInProgress()")));
        helper.reportWithRoute{value: REPORT_EXEC_COMP}(
            swapId,
            bytes32(0),
            first.swap,
            activePreimage,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _routeFunding(0, AMOUNT2, REPORT_EXEC_COMP, false, address(tokenC), 1e18, bytes(""), new bytes[](0)),
            router
        );
    }

    /// @dev A genuinely different position preimage fails the helper's stable position-hash check
    ///      before any report funding is sourced.
    function test_aTamperedPositionStructFailsTheHashCheck() public {
        OpenPuntStorage.MatchedSwap memory tampered = active;
        tampered.notional += 1;

        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("WrongHash()")));
        helper.reportWithRoute{value: REPORT_EXEC_COMP}(
            swapId,
            bytes32(0),
            tampered,
            activePreimage,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _routeFunding(0, AMOUNT2, REPORT_EXEC_COMP, false, address(tokenC), 1e18, bytes(""), new bytes[](0)),
            router
        );
    }

    function test_aTamperedMatcherPreimageFailsBeforeFunding() public {
        OpenPuntStorage.MatcherPreimage memory tampered = activePreimage;
        tampered.initialLiquidity += 1;

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.WrongHash.selector);
        helper.reportWithRoute{value: REPORT_EXEC_COMP}(
            swapId,
            bytes32(0),
            active,
            tampered,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _routeFunding(0, AMOUNT2, REPORT_EXEC_COMP, false, address(tokenC), 1e18, bytes(""), new bytes[](0)),
            router
        );
    }

    // ────────────────────────────────────────────────────────────────────
    //  routing
    // ────────────────────────────────────────────────────────────────────

    /// @dev One third token sources both oracle legs; compensation supplied directly.
    function test_oneRouteSourcesBothReportOracleLegs() public {
        uint256 maxIn = 6000e18;
        (bytes memory c1, bytes[] memory i1) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);
        (bytes memory c2, bytes[] memory i2) = _v2ExactOut(address(tokenC), address(tokenB), AMOUNT2, maxIn);
        (bytes memory cj, bytes[] memory ij) = _join(c1, i1, c2, i2);
        (bytes memory cmds, bytes[] memory ins) = _withSweep(cj, ij, address(tokenC));

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 b0 = tokenB.balanceOf(funder);

        Matched memory rep = _report(
            designatedReporter,
            _routeFunding(0, 0, REPORT_EXEC_COMP, false, address(tokenC), maxIn, cmds, ins),
            REPORT_EXEC_COMP
        );

        assertEq(tokenA.balanceOf(funder), a0, "leg 1 must have come from the route");
        assertEq(tokenB.balanceOf(funder), b0, "leg 2 must have come from the route");
        _assertReportedAndExecutable(rep);
        _assertHelperClean();
    }

    /// @dev The report path honors its own caller-selected router as well. The compatible router
    ///      receives exactly maxSwapInput, supplies the missing report leg, and leaves the chosen
    ///      reporter—not the capital supplier—as the owner of the resulting oracle report.
    function test_reportUsesCallerSelectedCompatibleRouter() public {
        uint256 maxIn = 5e18;
        ReportCompatibleRouter chosen = new ReportCompatibleRouter(address(tokenC), address(tokenA), INITIAL_LIQUIDITY);
        tokenA.mint(address(chosen), INITIAL_LIQUIDITY);

        bytes[] memory opaqueInputs = new bytes[](1);
        opaqueInputs[0] = hex"cafe";
        Matched memory rep = _reportWithRouter(
            attacker,
            _routeFunding(0, AMOUNT2, REPORT_EXEC_COMP, false, address(tokenC), maxIn, hex"beef", opaqueInputs),
            REPORT_EXEC_COMP,
            address(chosen)
        );

        assertEq(chosen.caller(), address(helper), "the selected report router was not called");
        assertEq(chosen.receivedInput(), maxIn, "the report router did not receive exactly maxSwapInput");
        assertEq(rep.game.currentReporter, attacker, "the designated reporter did not own the report");
        assertEq(tokenC.allowance(address(helper), address(chosen)), 0, "helper approved the report router");
        _assertReportedAndExecutable(rep);
        _assertHelperClean();
    }

    /// @dev ETH is already an aggregated asset because of the execution compensation, so a native
    ///      route budget must be declared inside
    ///      `suppliedAmount3`. `_suppliedSurplus` then hands the router only the amount above the
    ///      compensation — proving the compensation itself is reserved and never routed away.
    function test_ethRouteBudgetRidesOnTheCompensationSurplus() public {
        uint256 routeBudget = 3 ether;
        uint256 supplied3 = uint256(REPORT_EXEC_COMP) + routeBudget;

        // Wrap the surplus ETH, buy the token1 leg with it, unwrap the remainder back to the helper.
        bytes memory path = abi.encodePacked(address(tokenA), V3_FEE, address(weth));
        bytes memory cmds = abi.encodePacked(CMD_WRAP_ETH, CMD_V3_SWAP_EXACT_OUT, CMD_UNWRAP_WETH);
        bytes[] memory ins = new bytes[](3);
        ins[0] = abi.encode(router, routeBudget);
        ins[1] = abi.encode(address(helper), INITIAL_LIQUIDITY, routeBudget, path, false, _noHopPrices());
        ins[2] = abi.encode(address(helper), uint256(0));
        (cmds, ins) = _withSweep(cmds, ins, ETH_ASSET);

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 e0 = funder.balance;

        Matched memory rep = _report(
            designatedReporter,
            _routeFunding(0, AMOUNT2, supplied3, false, ETH_ASSET, routeBudget, cmds, ins),
            supplied3
        );

        assertEq(tokenA.balanceOf(funder), a0, "the token1 leg must have come from the ETH route");
        // The compensation is spent; the unspent part of the route budget comes back.
        uint256 netEth = e0 - funder.balance;
        assertGt(netEth, REPORT_EXEC_COMP, "the route must have consumed some ETH beyond the compensation");
        assertLt(netEth, supplied3, "the unspent ETH surplus was not refunded");
        _assertReportedAndExecutable(rep);
        _assertHelperClean();
    }

    /// @dev The compensation is reserved rather than routable: asking to route more than the surplus is
    ///      rejected, which is what stops a plan from spending the execution compensation.
    function test_theRouteCannotSpendTheExecutionCompensation() public {
        uint256 routeBudget = 3 ether;
        uint256 supplied3 = uint256(REPORT_EXEC_COMP) + routeBudget;

        bytes memory path = abi.encodePacked(address(tokenA), V3_FEE, address(weth));
        bytes memory cmds = abi.encodePacked(CMD_WRAP_ETH, CMD_V3_SWAP_EXACT_OUT, CMD_UNWRAP_WETH);
        bytes[] memory ins = new bytes[](3);
        ins[0] = abi.encode(router, routeBudget + 1);
        ins[1] = abi.encode(address(helper), INITIAL_LIQUIDITY, routeBudget + 1, path, false, _noHopPrices());
        ins[2] = abi.encode(address(helper), uint256(0));

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMaximumSwapInput.selector);
        helper.reportWithRoute{value: supplied3}(
            swapId,
            bytes32(0),
            active,
            activePreimage,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _routeFunding(0, AMOUNT2, supplied3, false, ETH_ASSET, routeBudget + 1, cmds, ins),
            router
        );
    }

    /// @dev ETH is never a separate route input on a report because the compensation slot always
    ///      registers it. Declaring a native budget outside `suppliedAmount3` therefore leaves the
    ///      surplus at zero and is rejected, rather than silently pulling extra ETH.
    function test_ethIsNeverASeparateRouteInputOnAReport() public {
        bytes memory path = abi.encodePacked(address(tokenA), V3_FEE, address(weth));
        bytes memory cmds = abi.encodePacked(CMD_WRAP_ETH, CMD_V3_SWAP_EXACT_OUT, CMD_UNWRAP_WETH);
        bytes[] memory ins = new bytes[](3);
        ins[0] = abi.encode(router, uint256(3 ether));
        ins[1] = abi.encode(address(helper), INITIAL_LIQUIDITY, uint256(3 ether), path, false, _noHopPrices());
        ins[2] = abi.encode(address(helper), uint256(0));

        // suppliedAmount3 covers only the compensation, so the ETH surplus is zero.
        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMaximumSwapInput.selector);
        helper.reportWithRoute{value: REPORT_EXEC_COMP}(
            swapId,
            bytes32(0),
            active,
            activePreimage,
            _noTiming(),
            designatedReporter,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _routeFunding(0, AMOUNT2, REPORT_EXEC_COMP, false, ETH_ASSET, 3 ether, cmds, ins),
            router
        );
    }

    // ────────────────────────────────────────────────────────────────────
    //  designation
    // ────────────────────────────────────────────────────────────────────

    /// @dev The oracle reporter is the designated party even though the funder paid.
    function test_designatedReporterDiffersFromTheFunder() public {
        Matched memory rep =
            _report(attacker, _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, false), REPORT_EXEC_COMP);
        assertEq(rep.game.currentReporter, attacker, "the designated reporter must own the oracle report");
        _assertReportedAndExecutable(rep);
    }

    /// @dev Without the reporter's internal allowances the call reverts on strict delegation, after
    ///      the helper has already pulled and deposited.
    function test_missingReporterApprovalRevertsLate() public {
        address unapproved = address(0x3009);

        uint256 a0 = tokenA.balanceOf(funder);
        bytes32 hashBefore = punt.swaps(swapId);

        vm.prank(funder);
        // Compensation is funded directly by the helper. The unapproved designated reporter fails
        // later when OpenOracle's strict delegated funding tries to consume the first oracle leg.
        vm.expectRevert(bytes4(keccak256("InsufficientInternalBalance()")));
        helper.reportWithRoute{value: REPORT_EXEC_COMP}(
            swapId,
            bytes32(0),
            active,
            activePreimage,
            _noTiming(),
            unapproved,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            _noRouteFunding(INITIAL_LIQUIDITY, AMOUNT2, REPORT_EXEC_COMP, false),
            router
        );

        assertEq(tokenA.balanceOf(funder), a0, "token1 was consumed by a reverted report");
        assertEq(punt.swaps(swapId), hashBefore, "the position hash moved");
    }

    // ────────────────────────────────────────────────────────────────────
    //  terminal execution and compensation
    // ────────────────────────────────────────────────────────────────────

    // Compensation delivery, consumption, and replay rejection are asserted for every report
    // success path by `_assertReportedAndExecutable`, rather than in one isolated test.

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    function _report(address who, OpenPuntHelper.RouteFunding memory route, uint256 value)
        internal
        returns (Matched memory rep)
    {
        return _reportWithRouter(who, route, value, router);
    }

    function _reportWithRouter(
        address who,
        OpenPuntHelper.RouteFunding memory route,
        uint256 value,
        address routerChoice
    ) internal returns (Matched memory rep) {
        vm.recordLogs();
        vm.prank(funder);
        helper.reportWithRoute{value: value}(
            swapId,
            bytes32(0),
            active,
            activePreimage,
            _noTiming(),
            who,
            INITIAL_LIQUIDITY,
            AMOUNT2,
            REPORT_EXEC_COMP,
            route,
            routerChoice
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        rep.swapId = swapId;
        rep.swap = _decodeSingleSwapState(logs, OpenPuntStorage.PositionReportStarted.selector, swapId);
        rep.reportId = punt.swapIdToReportId(swapId);
        (rep.game, rep.helper) = _decodeReportSubmitted(logs, rep.reportId);
    }

    /// @dev The emitted struct must reconstruct the stable position hash, and the genuine report
    ///      game must then settle and execute through the core. A reusable outcome clears only the
    ///      report sidecar. The helper-funded execution compensation must be delivered exactly once
    ///      and the settled game must not be replayable.
    function _assertReportedAndExecutable(Matched memory rep) internal {
        assertEq(
            punt.swaps(rep.swapId),
            keccak256(abi.encode(rep.swap)),
            "the emitted PositionReportStarted does not reconstruct swaps[swapId]"
        );
        assertTrue(rep.reportId != 0, "no report id was allocated");
        assertEq(rep.game.currentAmount1, INITIAL_LIQUIDITY, "report game leg 1");
        assertEq(rep.game.currentAmount2, AMOUNT2, "report game leg 2");
        assertEq(punt.executionGasComp(rep.reportId), REPORT_EXEC_COMP, "the funded compensation was not escrowed");

        _advanceToSettlementEligibility();

        uint256 execBefore = oracle.tokenHolder(closeExecutor, ETH_ASSET);
        uint256 funderBefore = oracle.tokenHolder(funder, ETH_ASSET);
        uint256 reporterBefore = oracle.tokenHolder(designatedReporter, ETH_ASSET);
        bytes32 hashBefore = punt.swaps(rep.swapId);

        vm.prank(closeExecutor);
        puntLifecycle.execute(rep.swapId, rep.swap, rep.game, rep.helper, 0);

        assertEq(punt.swaps(rep.swapId), hashBefore, "reusable execution changed the active position hash");
        assertEq(punt.swapIdToReportId(rep.swapId), 0, "reusable execution did not clear the report sidecar");
        // `_credit` seeds the oracle's 1-unit sentinel the first time a holder's slot is written,
        // so a first-ever ETH credit lands as `amount + 1`. That one wei is slot warming, not a
        // payout, and is added to the expectation rather than absorbed by a loose comparison.
        uint256 sentinel = execBefore == 0 ? 1 : 0;
        assertEq(
            oracle.tokenHolder(closeExecutor, ETH_ASSET) - execBefore,
            uint256(REPORT_EXEC_COMP) + sentinel,
            "the executor must receive exactly the funded compensation"
        );
        assertEq(oracle.tokenHolder(funder, ETH_ASSET), funderBefore, "the funder must not be compensated");
        assertEq(
            oracle.tokenHolder(designatedReporter, ETH_ASSET),
            reporterBefore,
            "the designated reporter must not receive the execution compensation"
        );
        assertEq(punt.executionGasComp(rep.reportId), 0, "the compensation was not consumed");

        // Replaying the same execution must fail because the report sidecar has been cleared.
        vm.prank(closeExecutor);
        vm.expectRevert(bytes4(keccak256("NoOracleGame()")));
        puntLifecycle.execute(rep.swapId, rep.swap, rep.game, rep.helper, 0);
    }

    function _assertHelperClean() internal view {
        assertEq(tokenA.balanceOf(address(helper)), 0, "helper retained token1");
        assertEq(tokenB.balanceOf(address(helper)), 0, "helper retained token2");
        assertEq(tokenC.balanceOf(address(helper)), 0, "helper retained route input");
        assertEq(address(helper).balance, 0, "helper retained ETH");
        assertLe(oracle.tokenHolder(address(helper), address(tokenA)), 1, "helper retained internal token1");
        assertLe(oracle.tokenHolder(address(helper), address(tokenB)), 1, "helper retained internal token2");
        assertLe(oracle.tokenHolder(address(helper), ETH_ASSET), 1, "helper retained internal ETH");
    }
}

contract ReportCompatibleRouter {
    IERC20Min internal immutable inputToken;
    IERC20Min internal immutable outputToken;
    uint256 internal immutable outputAmount;

    address public caller;
    uint256 public receivedInput;

    constructor(address inputToken_, address outputToken_, uint256 outputAmount_) {
        inputToken = IERC20Min(inputToken_);
        outputToken = IERC20Min(outputToken_);
        outputAmount = outputAmount_;
    }

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        caller = msg.sender;
        receivedInput = inputToken.balanceOf(address(this));
        require(outputToken.transfer(msg.sender, outputAmount), "output transfer");
    }
}
