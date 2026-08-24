// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";
import {Errors as OracleErrors} from "../../src/libraries/Errors.sol";

/**
 * @notice matchSwap(): hash gating, expiry boundary, oracle-game creation, and the
 *         adapter-shaped path where msg.sender funds a different designated matcher.
 */
contract MatchSwapTest is OpenPuntBase {
    /// @dev Designated counterparty starts with no oracle balances, so the
    ///      adapter path can only work if the funder's temporary transfers really happen.
    address internal designated = address(0x2001);

    function setUp() public {
        _setUpAll();
        collat.mint(swapper, 1_000_000e18);
        vm.deal(swapper, 100 ether);

        // designated matcher: approvals only, no balances of any kind
        vm.startPrank(designated);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        vm.stopPrank();

        // adapter/funder: real balances and approvals for both legs plus the matcher margin
        _mintAndDeposit(collat, adapter, 100_000e18);
        _mintAndDeposit(tokenA, adapter, 1_000e18);
        _mintAndDeposit(tokenB, adapter, 1_000_000e18);
        vm.startPrank(adapter);
        oracle.approveInternal(address(punt), address(collat), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Happy match
    // ══════════════════════════════════════════════════════════════════

    function test_matchSucceedsAndEmitsTheExactExpectedState() public {
        Proposal memory p = _propose();
        uint48 matchTs = uint48(vm.getBlockTimestamp());
        uint256 expectedReportId = oracle.nextReportId();

        Matched memory mt = _matchSwap(p);

        // hand-built expectation, field by field
        OpenPuntStorage.MatchedSwap memory want;
        want.swapper = swapper;
        want.matcher = matcher;
        want.collatToken = address(collat);
        want.oracleToken1 = address(tokenA);
        want.oracleToken2 = address(tokenB);
        want.initialMarginSwapper = INITIAL_MARGIN_SWAPPER;
        want.initialMarginMatcher = INITIAL_MARGIN_MATCHER;
        want.maintenanceMarginSwapper = MAINTENANCE_MARGIN;
        want.notional = NOTIONAL;
        want.swapperIsLong = true;
        want.fulfillmentFee = uint24(uint32(FEE_AUCTION_START)); // matched in the proposal's block
        want.fundingRate = 0;
        want.oracleAmount1 = 0;
        want.oracleAmount2 = 0;
        want.feeRecipient = address(0); // zero protocol fee
        want.matcherPreimageHash = keccak256(abi.encode(p.preimage));
        want.priceTolerated = PRICE_TOLERATED;
        want.toleranceRange = TOLERANCE_RANGE;
        want.millisecondsPerBlock = MS_PER_BLOCK;
        want.maxGameTime = MAX_GAME_TIME;
        want.maxExecutionLatency = MAX_EXECUTION_LATENCY;
        want.liquidationHeartbeatMin = 0;
        want.liquidationHeartbeatMax = 0;
        want.start = matchTs;
        want.maturity = 0;
        want.maturityWindow = MATURITY_WINDOW;
        want.active = false;
        want.openExecutionComp = OPEN_EXEC_COMP;
        want.useInternalBalances = false;

        assertEq(keccak256(abi.encode(mt.swap)), keccak256(abi.encode(want)), "emitted state matches expectation");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(want)), "stored hash matches expectation");
        assertEq(punt.swapIdToReportId(p.swapId), expectedReportId, "opening report stored in sidecar");
        assertEq(mt.game.currentReporter, matcher, "matcher reports the opening game");
        assertEq(mt.game.currentAmount1, INITIAL_LIQUIDITY, "opening leg1");
        assertEq(mt.game.currentAmount2, AMOUNT2, "opening leg2");
    }

    function test_reportIdsAreSequentialAcrossPositions() public {
        _mintAndDeposit(collat, matcher, 100_000e18);
        _mintAndDeposit(tokenA, matcher, 1_000e18);
        _mintAndDeposit(tokenB, matcher, 1_000_000e18);

        uint256 first = oracle.nextReportId();

        Proposal memory p1 = _propose();
        Proposal memory p2 = _propose();
        Proposal memory p3 = _propose();

        assertEq(_matchSwap(p1).reportId, first, "first reportId");
        assertEq(_matchSwap(p2).reportId, first + 1, "second reportId");
        assertEq(_matchSwap(p3).reportId, first + 2, "third reportId");

        assertTrue(p1.swapId != p2.swapId && p2.swapId != p3.swapId, "distinct swapIds");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Hash gating
    // ══════════════════════════════════════════════════════════════════

    function _assertMatchRejected(
        Proposal memory p,
        OpenPuntStorage.ProposedSwap memory s,
        OpenPuntStorage.MatcherPreimage memory m,
        address who,
        uint128 amount2,
        bytes4 err,
        string memory what
    ) internal {
        bytes32 storedBefore = punt.swaps(p.swapId);
        uint256 nextReportIdBefore = oracle.nextReportId();
        uint256 matcherCollat = _spendable(matcher, address(collat));
        uint256 matcherA = _spendable(matcher, address(tokenA));
        uint256 puntCollat = _spendable(address(punt), address(collat));
        uint256 tempBefore = punt.tempHolding(matcher);

        vm.prank(matcher);
        vm.expectRevert(err);
        punt.matchSwap(p.swapId, amount2, s, m, _noTiming(), who);

        assertEq(punt.swaps(p.swapId), storedBefore, string.concat(what, ": proposal phase preserved"));
        assertEq(oracle.nextReportId(), nextReportIdBefore, string.concat(what, ": no oracle game created"));
        assertEq(_spendable(matcher, address(collat)), matcherCollat, string.concat(what, ": matcher collat unchanged"));
        assertEq(_spendable(matcher, address(tokenA)), matcherA, string.concat(what, ": matcher leg1 unchanged"));
        assertEq(_spendable(address(punt), address(collat)), puntCollat, string.concat(what, ": core collat unchanged"));
        assertEq(punt.tempHolding(matcher), tempBefore, string.concat(what, ": no gas comp credited"));
    }

    function test_wrongProposalFieldRejects() public {
        Proposal memory p = _propose();
        OpenPuntStorage.ProposedSwap memory tampered = _copy(p.swap);
        tampered.notional += 1;

        _assertMatchRejected(
            p, tampered, p.preimage, matcher, AMOUNT2, PuntErrors.WrongHash.selector, "tampered proposal"
        );
    }

    function test_wrongPreimageFieldRejects() public {
        Proposal memory p = _propose();
        OpenPuntStorage.MatcherPreimage memory tampered = _copy(p.preimage);
        tampered.initialLiquidity += 1;

        _assertMatchRejected(p, p.swap, tampered, matcher, AMOUNT2, PuntErrors.WrongHash.selector, "tampered preimage");
    }

    function test_nonexistentSwapIdRejects() public {
        Proposal memory p = _propose();
        uint256 ghost = p.swapId + 999;

        vm.prank(matcher);
        vm.expectRevert(PuntErrors.WrongHash.selector);
        punt.matchSwap(ghost, AMOUNT2, p.swap, p.preimage, _noTiming(), matcher);

        assertEq(punt.swaps(ghost), bytes32(0), "ghost slot still empty");
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "real proposal untouched");
    }

    function test_cancelledProposalRejects() public {
        Proposal memory p = _propose();

        vm.prank(swapper);
        punt.cancelSwapOpen(p.swapId, p.swap, p.preimage);
        assertEq(punt.swaps(p.swapId), bytes32(0), "cancelled");

        _assertMatchRejected(p, p.swap, p.preimage, matcher, AMOUNT2, PuntErrors.WrongHash.selector, "cancelled");
    }

    function test_alreadyMatchedProposalRejects() public {
        Proposal memory p = _propose();
        Matched memory mt = _matchSwap(p);
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(mt.swap)), "now in matched phase");

        _assertMatchRejected(p, p.swap, p.preimage, matcher, AMOUNT2, PuntErrors.WrongHash.selector, "already matched");
    }

    function test_zeroMatcherRejects() public {
        Proposal memory p = _propose();
        _assertMatchRejected(
            p, p.swap, p.preimage, address(0), AMOUNT2, PuntErrors.AddressCannotBeZero.selector, "zero matcher"
        );
    }

    function test_coreCannotBeTheMatcher() public {
        Proposal memory p = _propose();
        _assertMatchRejected(
            p,
            p.swap,
            p.preimage,
            address(punt),
            AMOUNT2,
            PuntErrors.ContractCannotBeParticipant.selector,
            "core matcher"
        );
    }

    /// @dev OpenPunt does not screen amount2; the real oracle call rejects it and the whole
    ///      match, including the already-written matched hash, unwinds.
    function test_zeroAmount2RejectsThroughTheOracle() public {
        Proposal memory p = _propose();
        _assertMatchRejected(p, p.swap, p.preimage, matcher, 0, OracleErrors.InvalidAmount2.selector, "zero amount2");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Expiry boundary
    // ══════════════════════════════════════════════════════════════════

    function test_matchAtExactExpirationSucceeds() public {
        Proposal memory p = _propose();
        uint48 expiration = p.swap.expiration;

        _advanceChain(uint256(expiration) - vm.getBlockTimestamp());
        assertEq(vm.getBlockTimestamp(), expiration, "sitting exactly on expiration");

        Matched memory mt = _matchSwap(p);
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(mt.swap)), "matched at the boundary");
        assertEq(mt.swap.start, expiration, "start stamped at the boundary");
    }

    function test_matchOneSecondAfterExpirationRejects() public {
        Proposal memory p = _propose();
        uint48 expiration = p.swap.expiration;

        _advanceChain(uint256(expiration) - vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(vm.getBlockTimestamp(), uint256(expiration) + 1, "one second past expiration");

        _assertMatchRejected(p, p.swap, p.preimage, matcher, AMOUNT2, PuntErrors.Expired.selector, "expired");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Adapter-funded match
    // ══════════════════════════════════════════════════════════════════

    function test_adapterFundsMatchOnBehalfOfDesignatedMatcher() public {
        Proposal memory p = _propose();

        uint256 adapterCollat0 = _spendable(adapter, address(collat));
        uint256 adapterA0 = _spendable(adapter, address(tokenA));
        uint256 adapterB0 = _spendable(adapter, address(tokenB));
        uint256 puntCollat0 = _spendable(address(punt), address(collat));

        // the designated matcher genuinely has nothing to contribute
        assertEq(_spendable(designated, address(tokenA)), 0, "designated starts with no leg1");
        assertEq(_spendable(designated, address(tokenB)), 0, "designated starts with no leg2");
        assertEq(_spendable(designated, address(collat)), 0, "designated starts with no collateral");

        Matched memory mt = _matchSwapFrom(p, AMOUNT2, adapter, designated);

        // identity: the designated address is the counterparty and the oracle reporter
        assertEq(mt.swap.matcher, designated, "MatchedSwap.matcher is the designated matcher");
        assertEq(mt.game.currentReporter, designated, "oracle currentReporter is the designated matcher");

        // the funder supplied both legs and the matcher margin, exactly
        assertEq(_spendable(adapter, address(tokenA)), adapterA0 - INITIAL_LIQUIDITY, "funder supplied leg1");
        assertEq(_spendable(adapter, address(tokenB)), adapterB0 - AMOUNT2, "funder supplied leg2");
        assertEq(
            _spendable(adapter, address(collat)), adapterCollat0 - INITIAL_MARGIN_MATCHER, "funder supplied margin"
        );
        assertEq(
            _spendable(address(punt), address(collat)),
            puntCollat0 + INITIAL_MARGIN_MATCHER,
            "core received the matcher margin"
        );

        // gas comp accrues to the designated matcher, not the funder
        assertEq(punt.tempHolding(designated), MATCHER_GAS_COMP, "designated matcher credited the gas comp");
        assertEq(punt.tempHolding(adapter), 0, "funder credited nothing");

        // the pass-through left no residue on the designated matcher
        assertEq(_spendable(designated, address(tokenA)), 0, "no residual leg1 on the designated matcher");
        assertEq(_spendable(designated, address(tokenB)), 0, "no residual leg2 on the designated matcher");
        assertEq(_spendable(designated, address(collat)), 0, "no residual collateral on the designated matcher");
    }

    function test_adapterMissingAllowanceRevertsWholeMatch() public {
        Proposal memory p = _propose();
        bytes32 storedBefore = punt.swaps(p.swapId);
        uint256 nextReportIdBefore = oracle.nextReportId();
        uint256 adapterA0 = _spendable(adapter, address(tokenA));
        uint256 adapterCollat0 = _spendable(adapter, address(collat));

        // revoke only the collateral allowance; the legs still transfer before it is needed
        vm.prank(adapter);
        oracle.approveInternal(address(punt), address(collat), 0);

        vm.prank(adapter);
        vm.expectRevert(OracleErrors.InsufficientInternalAllowance.selector);
        punt.matchSwap(p.swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), designated);

        assertEq(punt.swaps(p.swapId), storedBefore, "proposal phase preserved");
        assertEq(oracle.nextReportId(), nextReportIdBefore, "oracle game rolled back");
        assertEq(_spendable(adapter, address(tokenA)), adapterA0, "leg1 transfer rolled back");
        assertEq(_spendable(adapter, address(collat)), adapterCollat0, "collateral untouched");
        assertEq(_spendable(designated, address(tokenA)), 0, "designated matcher holds nothing");
        assertEq(punt.tempHolding(designated), 0, "no gas comp credited");
    }

    function test_adapterMissingBalanceRevertsWholeMatch() public {
        // a funder with allowances but an empty ledger
        address brokeAdapter = address(0x2002);
        vm.startPrank(brokeAdapter);
        oracle.approveInternal(address(punt), address(collat), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        vm.stopPrank();

        Proposal memory p = _propose();
        bytes32 storedBefore = punt.swaps(p.swapId);
        uint256 nextReportIdBefore = oracle.nextReportId();

        vm.prank(brokeAdapter);
        vm.expectRevert(OracleErrors.InsufficientInternalBalance.selector);
        punt.matchSwap(p.swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), designated);

        assertEq(punt.swaps(p.swapId), storedBefore, "proposal phase preserved");
        assertEq(oracle.nextReportId(), nextReportIdBefore, "no oracle game created");
        assertEq(_spendable(designated, address(tokenA)), 0, "designated matcher holds nothing");
        assertEq(punt.tempHolding(designated), 0, "no gas comp credited");
    }

    /// @dev The designated matcher must still have granted the core an internal allowance:
    ///      the oracle pulls the legs from the *reporter*, not from the funder.
    function test_designatedMatcherWithoutAllowanceRevertsMatch() public {
        address unarmed = address(0x2003);
        Proposal memory p = _propose();
        bytes32 storedBefore = punt.swaps(p.swapId);

        vm.prank(adapter);
        vm.expectRevert(OracleErrors.InsufficientInternalBalance.selector);
        punt.matchSwap(p.swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), unarmed);

        assertEq(punt.swaps(p.swapId), storedBefore, "proposal phase preserved");
        assertEq(punt.tempHolding(unarmed), 0, "no gas comp credited");
    }
}
