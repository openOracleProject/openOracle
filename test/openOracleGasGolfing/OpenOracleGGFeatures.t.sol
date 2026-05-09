// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {OpenOracleErrors} from "../../src/OpenOracleErrors.sol";

// New-feature tests for OpenOracleGasGolfing.
// Storage-mode happy path, calldata-mode happy path, and preimage-mismatch
// reverts are covered in the lifecycle test files; this file focuses on the
// genuinely new mechanics that don't exist in the legacy OpenOracle.
contract OpenOracleGGFeaturesTest is BaseGGTest {
    uint256 constant ORACLE_FEE = 0.01 ether;
    uint96 constant SETTLER_REWARD = 0.001 ether;

    function setUp() public override {
        BaseGGTest.setUp();
    }

    // -------------------------------------------------------------------------
    // Helpers for calldata-mode preimage construction (subset of what
    // OpenOracleGGCalldataMode.t.sol uses; duplicated here for isolation).
    // -------------------------------------------------------------------------
    function _gameFromParams(OpenOracleGG.CreateReportParams memory p, uint256 msgValue)
        internal
        pure
        returns (OpenOracleGG.OracleGame memory game)
    {
        game.token1 = p.token1Address;
        game.token2 = p.token2Address;
        game.exactToken1Report = p.exactToken1Report;
        if (p.feePercentage > 0) game.feePercentage = p.feePercentage;
        game.multiplier = p.multiplier;
        game.settlementTime = p.settlementTime;
        uint96 reporterFee;
        if (msgValue > p.settlerReward) reporterFee = uint96(msgValue) - p.settlerReward;
        game.fee = reporterFee;
        game.escalationHalt = p.escalationHalt;
        if (p.disputeDelay > 0) game.disputeDelay = p.disputeDelay;
        if (p.protocolFee > 0) game.protocolFee = p.protocolFee;
        game.settlerReward = p.settlerReward;
        game.timeType = p.timeType;
        game.callbackContract = p.callbackContract;
        game.callbackSelector = p.callbackSelector;
        if (p.trackDisputes) game.trackDisputes = p.trackDisputes;
        game.callbackGasLimit = p.callbackGasLimit;
        if (p.protocolFeeRecipient != address(0)) game.protocolFeeRecipient = p.protocolFeeRecipient;
    }

    // =========================================================================
    // createAndReport (storage mode)
    // =========================================================================

    function testCreateAndReport_StorageMode() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        uint256 expectedReportId = oracle.nextReportId();

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        uint256 aliceToken2Before = token2.balanceOf(alice);
        uint256 aliceETHBefore = alice.balance;

        // alice creates and bob is the reporter; alice (msg.sender) pays the
        // tokens too. bob is just the address credited at refund time.
        vm.prank(alice);
        uint256 returnedId = oracle.createAndReport{value: ORACLE_FEE}(
            p, true, 1e18, 2000e18, bob, false, false, _emptyTiming()
        );
        assertEq(returnedId, expectedReportId, "createAndReport returns reportId");

        // ETH consumed by alice, oracle holds it.
        assertEq(alice.balance, aliceETHBefore - ORACLE_FEE, "alice paid oracle fee");
        assertEq(address(oracle).balance, ORACLE_FEE, "oracle holds fee");

        // Payer semantics: tokens come from msg.sender (alice), not from reporter (bob).
        assertEq(token1.balanceOf(alice), aliceToken1Before - 1e18, "alice paid token1");
        assertEq(token2.balanceOf(alice), aliceToken2Before - 2000e18, "alice paid token2");
        assertEq(token1.balanceOf(bob), bobToken1Before, "bob external token1 unchanged");
        assertEq(token2.balanceOf(bob), bobToken2Before, "bob external token2 unchanged");

        // bob's sentinel slots seeded; nothing else.
        assertEq(_heldTokens(bob, address(token1)), 1, "bob token1 sentinel");
        assertEq(_heldTokens(bob, address(token2)), 1, "bob token2 sentinel");

        // verify state was populated.
        bytes32 sh = _stateHash(expectedReportId);
        assertTrue(sh != bytes32(0), "stateHash set");

        // Read currentAmount1/2 directly.
        bytes32 base = keccak256(abi.encode(expectedReportId, ORACLE_GAME_SLOT));
        bytes32 packed = vm.load(address(oracle), bytes32(uint256(base) + 1));
        assertEq(uint128(uint256(packed)), 1e18, "currentAmount1");
        assertEq(uint128(uint256(packed) >> 128), 2000e18, "currentAmount2");
    }

    // createAndReport with isStorageMode=false reverts InvalidMode (the storage
    // entrypoint requires storage mode).
    function testCreateAndReport_RejectsCalldataMode() public {
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.InvalidMode.selector);
        oracle.createAndReport{value: ORACLE_FEE}(
            _defaultParams(), false, 1e18, 2000e18, bob, false, false, _emptyTiming()
        );
    }

    // =========================================================================
    // createAndReportCalldata
    // =========================================================================

    function testCreateAndReportCalldata() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        uint256 expectedReportId = oracle.nextReportId();

        // Build the OracleGame the contract will assemble in _createReportInstance.
        OpenOracleGG.OracleGame memory game = _gameFromParams(p, ORACLE_FEE);

        // PreimageHelper: contract overrides reportId/blockTimestamp/blockNumber,
        // so we just supply creator (must equal msg.sender) and isStorageMode=false.
        OpenOracleGG.PreimageHelper memory helper = OpenOracleGG.PreimageHelper({
            reportId: 0,
            isStorageMode: false,
            creator: alice,
            blockTimestamp: 0,
            blockNumber: 0
        });

        vm.prank(alice);
        uint256 returnedId = oracle.createAndReportCalldata{value: ORACLE_FEE}(
            p, false, 1e18, 2000e18, bob, false, false, game, helper, _emptyTiming()
        );
        assertEq(returnedId, expectedReportId, "createAndReportCalldata returns reportId");

        // Verify final stored stateHash matches what we'd compute locally after submit.
        // To verify, reconstruct: helper now has reportId=expectedReportId, blockTimestamp=block.timestamp,
        // blockNumber=block.number. game has the create-time stateHash, then mutates.
        helper.reportId = expectedReportId;
        helper.blockTimestamp = block.timestamp;
        helper.blockNumber = block.number;

        bytes32 createdHash = _hashOracle(game, helper);
        game.stateHash = createdHash;
        // Apply initial-report mutations.
        game.currentAmount1 = 1e18;
        game.currentAmount2 = 2000e18;
        game.currentReporter = payable(bob);
        game.initialReporter = payable(bob);
        game.reportTimestamp = uint48(block.timestamp);
        game.lastReportOppoTime = uint48(block.number);

        bytes32 expectedHash = _hashOracle(game, helper);
        assertEq(_stateHash(expectedReportId), expectedHash, "stateHash matches predicted");
    }

    function testCreateAndReportCalldata_RejectsStorageMode() public {
        OpenOracleGG.OracleGame memory game;
        OpenOracleGG.PreimageHelper memory helper;
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.InvalidMode.selector);
        oracle.createAndReportCalldata{value: ORACLE_FEE}(
            _defaultParams(), true, 1e18, 2000e18, bob, false, false, game, helper, _emptyTiming()
        );
    }

    // =========================================================================
    // Internal balance funding for initial report
    // =========================================================================

    // bob pre-deposits and pre-dusts, then submits using internal balance.
    // tokens come from internal balance, not from external transferFrom.
    function testInitialReport_FundedByInternalBalance() public {
        // Pre-dust bob so that subsequent _getDustAmounts returns 0.
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));

        // Pre-deposit 5 token1 + 5000 token2 to bob's internal balance.
        vm.prank(bob);
        oracle.depositTokens(address(token1), 5e18);
        vm.prank(bob);
        oracle.depositTokens(address(token2), 5000e18);

        // Deposit credits go on top of dust sentinel (1).
        assertEq(_heldTokens(bob, address(token1)), 1 + 5e18, "bob token1 internal");
        assertEq(_heldTokens(bob, address(token2)), 1 + 5000e18, "bob token2 internal");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        uint256 bobExt1Before = token1.balanceOf(bob);
        uint256 bobExt2Before = token2.balanceOf(bob);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, sh, true, true, _emptyTiming());

        // External balances unchanged: funding came from internal balance.
        assertEq(token1.balanceOf(bob), bobExt1Before, "bob external token1 unchanged");
        assertEq(token2.balanceOf(bob), bobExt2Before, "bob external token2 unchanged");

        // Internal balances reduced by the report amounts.
        assertEq(_heldTokens(bob, address(token1)), 1 + 5e18 - 1e18, "bob token1 internal decremented");
        assertEq(_heldTokens(bob, address(token2)), 1 + 5000e18 - 2000e18, "bob token2 internal decremented");
    }

    // bob deposits but doesn't have enough; tib=true falls back to external pull.
    function testInitialReport_FallbackToPullWhenInternalInsufficient() public {
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));

        // Only 0.5 token1 internal — not enough for 1e18 report.
        vm.prank(bob);
        oracle.depositTokens(address(token1), 0.5e18);
        // Token2 has plenty.
        vm.prank(bob);
        oracle.depositTokens(address(token2), 5000e18);

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        uint256 bobExt1Before = token1.balanceOf(bob);
        uint256 bobExt2Before = token2.balanceOf(bob);
        uint256 internalT1Before = _heldTokens(bob, address(token1));
        uint256 internalT2Before = _heldTokens(bob, address(token2));

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, sh, true, true, _emptyTiming());

        // token1: insufficient internal -> full amount pulled externally; internal unchanged.
        assertEq(token1.balanceOf(bob), bobExt1Before - 1e18, "token1 pulled externally");
        assertEq(_heldTokens(bob, address(token1)), internalT1Before, "token1 internal unchanged");

        // token2: sufficient internal -> spent from internal; external unchanged.
        assertEq(token2.balanceOf(bob), bobExt2Before, "token2 external unchanged");
        assertEq(_heldTokens(bob, address(token2)), internalT2Before - 2000e18, "token2 internal decremented");
    }

    // bob authorizes alice via approveInternal; alice submits on bob's behalf, drawing from bob's internal balance.
    function testInitialReport_DelegatedFundingViaApproveInternal() public {
        // bob is the reporter (gets refund). alice is msg.sender.
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        vm.prank(bob);
        oracle.depositTokens(address(token1), 5e18);
        vm.prank(bob);
        oracle.depositTokens(address(token2), 5000e18);

        // bob authorizes alice to spend his internal balance.
        vm.prank(bob);
        oracle.approveInternal(alice, address(token1), 1e18);
        vm.prank(bob);
        oracle.approveInternal(alice, address(token2), 2000e18);

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        uint256 aliceExt1Before = token1.balanceOf(alice);
        uint256 bobExt1Before = token1.balanceOf(bob);

        // alice (msg.sender) calls submit-with-reporter overload, naming bob as reporter.
        vm.prank(alice);
        oracle.submitInitialReport(
            reportId, 1e18, 2000e18, sh, bob, true, true, _emptyTiming()
        );

        // Neither alice nor bob loses tokens externally.
        assertEq(token1.balanceOf(alice), aliceExt1Before, "alice external unchanged");
        assertEq(token1.balanceOf(bob), bobExt1Before, "bob external unchanged");

        // bob's internal balance decreased.
        assertEq(_heldTokens(bob, address(token1)), 1 + 5e18 - 1e18, "bob internal token1 spent");

        // Allowance fully consumed.
        assertEq(oracle.internalAllowance(bob, alice, address(token1)), 0, "alice's allowance consumed");
        assertEq(oracle.internalAllowance(bob, alice, address(token2)), 0, "alice's t2 allowance consumed");
    }

    // approveInternal with type(uint256).max: allowance not decremented.
    function testApproveInternal_InfiniteAllowance_NotDecremented() public {
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        vm.prank(bob);
        oracle.depositTokens(address(token1), 5e18);
        vm.prank(bob);
        oracle.depositTokens(address(token2), 5000e18);

        vm.prank(bob);
        oracle.approveInternal(alice, address(token1), type(uint256).max);
        vm.prank(bob);
        oracle.approveInternal(alice, address(token2), type(uint256).max);

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        vm.prank(alice);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, sh, bob, true, true, _emptyTiming());

        // bob's internal balance was spent.
        assertEq(_heldTokens(bob, address(token1)), 1 + 5e18 - 1e18, "internal spent");
        // But allowance is still infinite.
        assertEq(oracle.internalAllowance(bob, alice, address(token1)), type(uint256).max, "infinite allowance preserved");
    }

    // Insufficient allowance -> falls back to external pull from msg.sender.
    function testInitialReport_FallbackWhenAllowanceInsufficient() public {
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        vm.prank(bob);
        oracle.depositTokens(address(token1), 5e18);
        vm.prank(bob);
        oracle.depositTokens(address(token2), 5000e18);

        // Approve alice to spend less than the full report amount.
        vm.prank(bob);
        oracle.approveInternal(alice, address(token1), 0.5e18);

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        uint256 aliceExt1Before = token1.balanceOf(alice);
        uint256 bobInternal1Before = _heldTokens(bob, address(token1));

        vm.prank(alice);
        // tib1=true but allowance < amount -> falls back to external pull from alice (msg.sender).
        // tib2=false: token2 is pulled externally from msg.sender (alice) directly.
        oracle.submitInitialReport(reportId, 1e18, 2000e18, sh, bob, true, false, _emptyTiming());

        // alice paid token1 externally (since allowance was insufficient).
        assertEq(token1.balanceOf(alice), aliceExt1Before - 1e18, "alice paid token1 externally");
        // bob's internal token1 unchanged.
        assertEq(_heldTokens(bob, address(token1)), bobInternal1Before, "bob internal unchanged");
        // allowance unchanged (we never spent from it).
        assertEq(oracle.internalAllowance(bob, alice, address(token1)), 0.5e18, "allowance untouched");
    }

    // =========================================================================
    // Internal balance funding for disputes
    // =========================================================================

    function _setupReportAndInitial(address reporter)
        internal
        returns (uint256 reportId, bytes32 stateHash)
    {
        vm.prank(alice);
        reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        stateHash = _stateHash(reportId);

        vm.prank(reporter);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash, false, false, _emptyTiming());
    }

    function testDispute_FundedByInternalBalance() public {
        (uint256 reportId, bytes32 sh) = _setupReportAndInitial(bob);

        // Charlie pre-dusts and pre-funds.
        vm.prank(charlie);
        oracle.dust(address(token1), address(token2));
        vm.prank(charlie);
        oracle.depositTokens(address(token1), 5e18);
        vm.prank(charlie);
        oracle.depositTokens(address(token2), 5000e18);

        vm.warp(block.timestamp + 6);

        uint256 charlieExt1Before = token1.balanceOf(charlie);
        uint256 internalT1Before = _heldTokens(charlie, address(token1));

        // Charlie disputes (token1 swap), funded internally.
        vm.prank(charlie);
        oracle.disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, sh, true, true, _emptyTiming()
        );

        // External token1 unchanged.
        assertEq(token1.balanceOf(charlie), charlieExt1Before, "charlie external token1 unchanged");

        // Internal token1 decremented by (newA1 + oldA1 + fee + protocolFee).
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protoFee = (1e18 * 1000) / 1e7;
        uint256 expectedSpend = 1.1e18 + 1e18 + fee + protoFee;
        assertEq(
            _heldTokens(charlie, address(token1)),
            internalT1Before - expectedSpend,
            "charlie internal decremented"
        );
    }

    function testDispute_DelegatedFundingViaApproveInternal() public {
        (uint256 reportId, bytes32 sh) = _setupReportAndInitial(bob);

        vm.prank(charlie);
        oracle.dust(address(token1), address(token2));
        vm.prank(charlie);
        oracle.depositTokens(address(token1), 5e18);
        vm.prank(charlie);
        oracle.depositTokens(address(token2), 5000e18);

        // Charlie authorizes alice to spend his internal balance.
        vm.prank(charlie);
        oracle.approveInternal(alice, address(token1), type(uint256).max);
        vm.prank(charlie);
        oracle.approveInternal(alice, address(token2), type(uint256).max);

        vm.warp(block.timestamp + 6);

        // Use the disputer-arg overload so disputer is set to charlie explicitly.
        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, charlie, 2000e18, sh, true, true, _emptyTiming()
        );

        // Charlie's internal balance decremented.
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protoFee = (1e18 * 1000) / 1e7;
        uint256 expectedSpend = 1.1e18 + 1e18 + fee + protoFee;
        assertEq(
            _heldTokens(charlie, address(token1)),
            1 + 5e18 - expectedSpend,
            "charlie internal token1 spent"
        );
    }

    function testDispute_FallbackWhenInternalInsufficient() public {
        (uint256 reportId, bytes32 sh) = _setupReportAndInitial(bob);

        // Charlie has tib enabled but only 0.5 token1 internal — needs ~2.104.
        vm.prank(charlie);
        oracle.dust(address(token1), address(token2));
        vm.prank(charlie);
        oracle.depositTokens(address(token1), 0.5e18);

        vm.warp(block.timestamp + 6);

        uint256 charlieExt1Before = token1.balanceOf(charlie);

        vm.prank(charlie);
        oracle.disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, sh, true, false, _emptyTiming()
        );

        // Insufficient internal -> external pull.
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protoFee = (1e18 * 1000) / 1e7;
        uint256 expectedExternalSpend = 1.1e18 + 1e18 + fee + protoFee;
        assertEq(
            token1.balanceOf(charlie),
            charlieExt1Before - expectedExternalSpend,
            "charlie paid token1 externally"
        );
    }

    // =========================================================================
    // Self-dispute netting
    // =========================================================================

    // Bob is initial reporter and disputer. tokenToSwap = token1.
    // Expected: bob pays only (newA1 - oldA1 + protocolFee), keeps fee.
    function testSelfDispute_Token1_Netting() public {
        (uint256 reportId, bytes32 sh) = _setupReportAndInitial(bob);

        vm.warp(block.timestamp + 6);

        // newPrice must be outside fee boundary. oldPrice = 5e14.
        // Choose newAmount2 = 1900e18 -> newPrice ~5.789e14, well above boundary.
        uint256 bobExt1Before = token1.balanceOf(bob);
        uint256 bobExt2Before = token2.balanceOf(bob);
        uint256 bobInternal1Before = _heldTokens(bob, address(token1));
        uint256 bobInternal2Before = _heldTokens(bob, address(token2));

        vm.prank(bob);
        oracle.disputeAndSwap(
            reportId, address(token1), 1.1e18, 1900e18, 2000e18, sh, false, false, _emptyTiming()
        );

        uint256 protoFee = (1e18 * 1000) / 1e7;
        // Self-dispute: bob pays only newA1 - oldA1 + protocolFee on token1.
        assertEq(
            token1.balanceOf(bob),
            bobExt1Before - (0.1e18 + protoFee),
            "bob token1 ext: only delta + protocolFee"
        );

        // bob's internal token1 NOT credited the standard 2*oldA1 + fee (which would
        // only apply on the non-self path).
        assertEq(_heldTokens(bob, address(token1)), bobInternal1Before, "bob internal token1 unchanged");

        // token2: newA2 < oldA2 so net2Receive = 100e18 credited internally.
        // External token2 unchanged.
        assertEq(token2.balanceOf(bob), bobExt2Before, "bob token2 ext unchanged");
        assertEq(
            _heldTokens(bob, address(token2)),
            bobInternal2Before + 100e18,
            "bob internal token2 += refund"
        );

        // Protocol fee credited; recipient's slot was 0 → sentinel-seeded then incremented.
        assertEq(_heldTokens(protocolFeeRecipient, address(token1)), 1 + protoFee, "protocol fee accrued");
    }

    // tokenToSwap = token2. Self-dispute, with a price move that requires bob
    // to ADD token2 (newA2 + protocolFee >= oldA2).
    function testSelfDispute_Token2_Netting_PaysExternal() public {
        (uint256 reportId, bytes32 sh) = _setupReportAndInitial(bob);
        vm.warp(block.timestamp + 6);

        // Choose newA2 = 2100, protocolFee = 0.001*oldA2 = 2e18. token2Needed = 2102e18.
        // 2102e18 >= 2000e18 -> bob pays (2102 - 2000) = 102e18 token2 externally.

        uint256 bobExt2Before = token2.balanceOf(bob);
        uint256 bobInternal2Before = _heldTokens(bob, address(token2));

        vm.prank(bob);
        oracle.disputeAndSwap(
            reportId, address(token2), 1.1e18, 2100e18, 2000e18, sh, false, false, _emptyTiming()
        );

        uint256 protoFee = (2000e18 * 1000) / 1e7; // 2e18
        uint256 token2Needed = 2100e18 + protoFee;
        uint256 token2ExternalPay = token2Needed - 2000e18;

        assertEq(
            token2.balanceOf(bob),
            bobExt2Before - token2ExternalPay,
            "bob paid token2Needed - oldA2"
        );
        // Internal token2 unchanged (no credit on self-dispute when paying externally).
        assertEq(_heldTokens(bob, address(token2)), bobInternal2Before, "internal token2 unchanged");
        // Protocol fee credited in token2 (slot was 0 → sentinel-seeded).
        assertEq(_heldTokens(protocolFeeRecipient, address(token2)), 1 + protoFee, "protocol fee in token2");
    }

    // tokenToSwap = token2. Self-dispute where token2Needed < oldA2 -> bob receives refund credit.
    function testSelfDispute_Token2_Netting_ReceivesRefund() public {
        // Use a smaller protocolFee to make token2Needed < oldA2 feasible without
        // crossing the fee boundary in the wrong direction.
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.protocolFee = 0;
        p.feePercentage = 0; // no fee boundary check
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, true);
        bytes32 sh = _stateHash(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, _emptyTiming());

        vm.warp(block.timestamp + 6);

        // newA2 = 1500. token2Needed = 1500 + 0 = 1500 < 2000.
        // Refund = 2000 - 1500 = 500e18 credited internally.
        uint256 bobInternal2Before = _heldTokens(bob, address(token2));

        vm.prank(bob);
        oracle.disputeAndSwap(
            reportId, address(token2), 1.1e18, 1500e18, 2000e18, sh, false, false, _emptyTiming()
        );

        assertEq(_heldTokens(bob, address(token2)), bobInternal2Before + 500e18, "refund credited");
    }

    // Self-dispute requires BOTH disputer == previousReporter AND msg.sender == previousReporter.
    // Carol calls dispute with disputer=bob (= previousReporter); msg.sender (carol) != bob.
    // -> Non-self path applies.
    function testSelfDispute_OnlyWhenBothConditions() public {
        (uint256 reportId, bytes32 sh) = _setupReportAndInitial(bob);
        vm.warp(block.timestamp + 6);

        // Charlie has approval for nothing here; he's just msg.sender.
        // This call runs the non-self path because msg.sender != previousReporter.
        uint256 bobInternal1Before = _heldTokens(bob, address(token1));

        vm.prank(charlie);
        oracle.disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, bob, 2000e18, sh, false, false, _emptyTiming()
        );

        // Non-self path: previousReporter (bob) credited 2*oldA1 + fee internally.
        uint256 fee = (1e18 * 3000) / 1e7;
        assertEq(
            _heldTokens(bob, address(token1)),
            bobInternal1Before + 2e18 + fee,
            "bob credited as previousReporter (non-self path)"
        );
    }

    // Self-dispute funded entirely from internal balance: external token
    // balances unchanged; internal token1 decreases by only (newA1 - oldA1
    // + protocolFee); internal token2 INCREASES by the refund credit.
    function testSelfDispute_Token1_FundedByInternalBalance() public {
        // bob is initial reporter and self-disputes. Pre-fund his internal balance.
        vm.prank(bob);
        oracle.depositTokens(address(token1), 5e18);
        vm.prank(bob);
        oracle.depositTokens(address(token2), 5000e18);

        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, true);
        bytes32 sh = _stateHash(reportId);

        // Bob submits with tib=true so the initial 1e18 + 2000e18 also come internally.
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, sh, true, true, _emptyTiming());

        // Snapshot internal balances before self-dispute.
        uint256 bobInternal1 = _heldTokens(bob, address(token1));
        uint256 bobInternal2 = _heldTokens(bob, address(token2));
        uint256 bobExt1Before = token1.balanceOf(bob);
        uint256 bobExt2Before = token2.balanceOf(bob);

        vm.warp(block.timestamp + 6);

        // Self-dispute, token1 swap, newA2 < oldA2 (refund credit on token2).
        // newPrice = 1.1e18 / 1900e18 ≈ 5.789e14, well outside fee boundary around 5e14.
        vm.prank(bob);
        oracle.disputeAndSwap(
            reportId, address(token1), 1.1e18, 1900e18, 2000e18, sh, true, true, _emptyTiming()
        );

        uint256 protoFee = (1e18 * 1000) / 1e7;

        // Externals unchanged — internal balance covered everything.
        assertEq(token1.balanceOf(bob), bobExt1Before, "token1 ext unchanged");
        assertEq(token2.balanceOf(bob), bobExt2Before, "token2 ext unchanged");

        // token1 internal: spent only delta + protocolFee on the self-dispute path.
        assertEq(
            _heldTokens(bob, address(token1)),
            bobInternal1 - (0.1e18 + protoFee),
            "token1 internal: -delta -protoFee"
        );

        // token2 internal: refunded (oldA2 - newA2 = 100e18) on top.
        assertEq(
            _heldTokens(bob, address(token2)),
            bobInternal2 + 100e18,
            "token2 internal: += refund"
        );

        // Protocol fee credited.
        assertEq(_heldTokens(protocolFeeRecipient, address(token1)), 1 + protoFee, "fee credited");
    }

    // Delegated dispute with EXACT finite allowance: after the call, the
    // allowance should be zero (consumed entirely).
    function testDispute_DelegatedFiniteAllowance_DecrementsToZero() public {
        (uint256 reportId, bytes32 sh) = _setupReportAndInitial(bob);

        vm.prank(charlie);
        oracle.dust(address(token1), address(token2));
        vm.prank(charlie);
        oracle.depositTokens(address(token1), 5e18);
        vm.prank(charlie);
        oracle.depositTokens(address(token2), 5000e18);

        // Computed dispute spend (token1 swap):
        //   token1 = newA1 + oldA1 + fee + protocolFee = 1.1e18 + 1e18 + 3e15 + 1e15 = 2.104e18
        //   token2 = netContribution = newA2 - oldA2 = 100e18
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protoFee = (1e18 * 1000) / 1e7;
        uint256 expectedToken1Spend = 1.1e18 + 1e18 + fee + protoFee;
        uint256 expectedToken2Spend = 100e18;

        vm.prank(charlie);
        oracle.approveInternal(alice, address(token1), expectedToken1Spend);
        vm.prank(charlie);
        oracle.approveInternal(alice, address(token2), expectedToken2Spend);

        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, charlie, 2000e18, sh, true, true, _emptyTiming()
        );

        // Charlie's internal balances spent exactly.
        assertEq(_heldTokens(charlie, address(token1)), 1 + 5e18 - expectedToken1Spend, "charlie t1 spent");
        assertEq(_heldTokens(charlie, address(token2)), 1 + 5000e18 - expectedToken2Spend, "charlie t2 spent");

        // Allowances fully consumed.
        assertEq(oracle.internalAllowance(charlie, alice, address(token1)), 0, "t1 allowance consumed");
        assertEq(oracle.internalAllowance(charlie, alice, address(token2)), 0, "t2 allowance consumed");
    }

    // =========================================================================
    // Timing bounds
    // =========================================================================

    function testTimingBounds_AcceptsWithinTolerance() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        OpenOracleGG.TimingBoundaries memory timing = OpenOracleGG.TimingBoundaries({
            blockNumber: block.number,
            blockNumberBound: 5,
            blockTimestamp: block.timestamp,
            blockTimestampBound: 60
        });

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, timing);
    }

    function testTimingBounds_RejectsStaleTimestamp() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        // Capture timing referencing the current block, then warp far ahead.
        OpenOracleGG.TimingBoundaries memory timing = OpenOracleGG.TimingBoundaries({
            blockNumber: block.number,
            blockNumberBound: 5,
            blockTimestamp: block.timestamp,
            blockTimestampBound: 60
        });

        vm.warp(block.timestamp + 200); // 200s elapsed, bound is 60.

        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.InvalidTiming.selector);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, timing);
    }

    function testTimingBounds_ZeroSkipsValidation() public {
        // Already exercised throughout the suite; this test makes the contract
        // explicit: blockTimestamp == 0 means timing is not validated even if
        // the rest of the struct holds nonsense.
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        OpenOracleGG.TimingBoundaries memory timing = OpenOracleGG.TimingBoundaries({
            blockNumber: 99999,
            blockNumberBound: 0,
            blockTimestamp: 0, // sentinel: skip validation
            blockTimestampBound: 0
        });

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, timing);
    }

    function testTimingBounds_OnDispute() public {
        (uint256 reportId, bytes32 sh) = _setupReportAndInitial(bob);
        vm.warp(block.timestamp + 6);

        OpenOracleGG.TimingBoundaries memory timing = OpenOracleGG.TimingBoundaries({
            blockNumber: block.number,
            blockNumberBound: 5,
            blockTimestamp: block.timestamp,
            blockTimestampBound: 60
        });

        vm.warp(block.timestamp + 200);

        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.InvalidTiming.selector);
        oracle.disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, sh, false, false, timing
        );
    }

    // =========================================================================
    // Dust sentinel
    // =========================================================================

    function testDust_SeedsSentinelOnFirstCall() public {
        // Before any interaction, slot is zero.
        assertEq(_heldTokens(bob, address(token1)), 0);
        assertEq(_heldTokens(bob, address(token2)), 0);

        uint256 b1 = token1.balanceOf(bob);
        uint256 b2 = token2.balanceOf(bob);

        vm.prank(bob);
        oracle.dust(address(token1), address(token2));

        // Virtual sentinel: NO tokens pulled. Storage slots set to 1 only.
        assertEq(token1.balanceOf(bob), b1, "no token1 pulled");
        assertEq(token2.balanceOf(bob), b2, "no token2 pulled");
        assertEq(_heldTokens(bob, address(token1)), 1, "sentinel seeded");
        assertEq(_heldTokens(bob, address(token2)), 1, "sentinel seeded");

        // Subsequent calls are no-ops (dustedPair set).
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        assertEq(token1.balanceOf(bob), b1, "still no pull");
        assertEq(_heldTokens(bob, address(token1)), 1, "still 1");
    }

    function testDust_CannotWithdrawBelowSentinel() public {
        vm.prank(bob);
        oracle.depositTokens(address(token1), 10e18);
        // depositTokens seeds the virtual sentinel (1) before adding the deposit.
        assertEq(_heldTokens(bob, address(token1)), 1 + 10e18);

        uint256 b = token1.balanceOf(bob);

        vm.prank(bob);
        oracle.getHeldTokens(address(token1));
        // Withdraw leaves 1 sentinel; bob recovers the full deposit.
        assertEq(token1.balanceOf(bob), b + 10e18, "full deposit withdrawn");
        assertEq(_heldTokens(bob, address(token1)), 1, "1 sentinel left");

        // Second withdrawal: balance == 1 -> no-op.
        b = token1.balanceOf(bob);
        vm.prank(bob);
        oracle.getHeldTokens(address(token1));
        assertEq(token1.balanceOf(bob), b, "no further withdrawal");
        assertEq(_heldTokens(bob, address(token1)), 1, "sentinel still 1");
    }

    function testDust_InternalSpendCannotGoBelowSentinel() public {
        // bob has internal balance of exactly 1 (the sentinel) — cannot spend it.
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        assertEq(_heldTokens(bob, address(token1)), 1);

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        // tib1=true, but internal balance is only the sentinel; falls back to external pull.
        uint256 bobExt1Before = token1.balanceOf(bob);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, sh, true, false, _emptyTiming());

        // External pulled 1e18 (sentinel was preserved).
        assertEq(token1.balanceOf(bob), bobExt1Before - 1e18, "external pull when only sentinel");
        assertEq(_heldTokens(bob, address(token1)), 1, "sentinel preserved");
    }

    function testGetHeldEth_LeavesSentinel() public {
        vm.deal(bob, 5 ether);
        vm.prank(bob);
        oracle.depositETH{value: 1 ether}();
        // depositETH seeds the virtual sentinel before adding the deposit.
        assertEq(oracle.ethHolder(bob), 1 + 1 ether);

        uint256 bobEthBefore = bob.balance;
        vm.prank(bob);
        uint256 amt = oracle.getHeldEth();
        assertEq(amt, 1 ether, "withdrew full deposit (sentinel virtual)");
        assertEq(bob.balance, bobEthBefore + 1 ether, "balance reflects full deposit");
        assertEq(oracle.ethHolder(bob), 1, "1 wei sentinel left");

        // Second call is a no-op.
        vm.prank(bob);
        amt = oracle.getHeldEth();
        assertEq(amt, 0, "no further withdrawal");
    }

    // =========================================================================
    // depositTokensAny / depositETHAny
    // =========================================================================

    function testDepositTokensAny_CreditsBeneficiary() public {
        // charlie's slot is 0; depositTokensAny seeds sentinel (1) then adds amount.
        assertEq(_heldTokens(charlie, address(token1)), 0);

        vm.prank(alice);
        oracle.depositTokensAny(address(token1), 5e18, charlie);

        assertEq(_heldTokens(charlie, address(token1)), 1 + 5e18, "sentinel + deposit");
    }

    function testDepositETHAny_CreditsBeneficiary() public {
        // charlie's slot is 0; depositETHAny seeds sentinel then adds amount.
        assertEq(oracle.ethHolder(charlie), 0);

        vm.prank(alice);
        oracle.depositETHAny{value: 0.5 ether}(charlie);

        assertEq(oracle.ethHolder(charlie), 1 + 0.5 ether, "sentinel + deposit");
    }

    function testDepositAny_RevertsZeroBeneficiary() public {
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.AddressCannotBeZero.selector);
        oracle.depositTokensAny(address(token1), 5e18, address(0));

        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.AddressCannotBeZero.selector);
        oracle.depositETHAny{value: 1 wei}(address(0));
    }

    function testApproveInternal_RevertsZeroSpender() public {
        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.AddressCannotBeZero.selector);
        oracle.approveInternal(address(0), address(token1), 1);
    }
}
