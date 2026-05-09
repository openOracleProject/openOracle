// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {OpenOracleErrors} from "../../src/OpenOracleErrors.sol";

// Calldata-mode port of the lifecycle baseline tests. In calldata mode the
// contract only stores the stateHash; every mutating call must pass the full
// OracleGame + PreimageHelper preimages, and the local copy must be advanced
// to track on-chain state (since the stored stateHash rolls forward each call).
contract OpenOracleGGCalldataModeTest is BaseGGTest {
    uint256 constant ORACLE_FEE = 0.01 ether;
    uint256 constant SETTLER_REWARD = 0.001 ether;

    function setUp() public override {
        BaseGGTest.setUp();
    }

    // Build the OracleGame mirror that the contract assembles inside
    // _createReportInstance. Mirrors all the conditional fields in
    // OpenOracleGasGolfing._createReportInstance.
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
        if (msgValue > p.settlerReward) {
            reporterFee = uint96(msgValue) - p.settlerReward;
        }
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

    // Mirror the contract-side mutations performed during initial report submit.
    function _applyInitialReport(
        OpenOracleGG.OracleGame memory game,
        uint128 amount1,
        uint128 amount2,
        address reporter
    ) internal view {
        game.currentAmount1 = amount1;
        game.currentAmount2 = amount2;
        game.currentReporter = payable(reporter);
        game.initialReporter = payable(reporter);
        game.reportTimestamp = game.timeType ? uint48(block.timestamp) : uint48(block.number);
        game.lastReportOppoTime = game.timeType ? uint48(block.number) : uint48(block.timestamp);
        if (game.trackDisputes) {
            game.numReports = 1;
        }
    }

    // Mirror the contract-side mutations performed during dispute.
    function _applyDispute(
        OpenOracleGG.OracleGame memory game,
        uint128 newAmount1,
        uint128 newAmount2,
        address disputer
    ) internal view {
        game.currentAmount1 = newAmount1;
        game.currentAmount2 = newAmount2;
        game.currentReporter = payable(disputer);
        game.reportTimestamp = game.timeType ? uint48(block.timestamp) : uint48(block.number);
        game.lastReportOppoTime = game.timeType ? uint48(block.number) : uint48(block.timestamp);
        if (game.trackDisputes) {
            game.numReports += 1;
        }
    }

    function _applySettle(OpenOracleGG.OracleGame memory game) internal view {
        game.settlementTimestamp = game.timeType ? uint48(block.timestamp) : uint48(block.number);
    }

    // -------------------------------------------------------------------------
    // Section: Calldata-mode lifecycle
    // -------------------------------------------------------------------------

    function testOracleLifecycle_CalldataMode() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();

        uint256 expectedReportId = oracle.nextReportId();

        // Build expected preimages BEFORE create so we can predict the stateHash.
        OpenOracleGG.PreimageHelper memory helper = OpenOracleGG.PreimageHelper({
            reportId: expectedReportId,
            isStorageMode: false,
            creator: alice,
            blockTimestamp: block.timestamp,
            blockNumber: block.number
        });
        OpenOracleGG.OracleGame memory game = _gameFromParams(p, ORACLE_FEE);

        bytes32 expectedStateHash = _hashOracle(game, helper);

        // Create in calldata mode.
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, false);
        assertEq(reportId, expectedReportId, "reportId predicted");

        bytes32 storedHash = _stateHash(reportId);
        assertEq(storedHash, expectedStateHash, "stored hash matches local computation");

        game.stateHash = expectedStateHash;

        // Submit initial report via calldata variant.
        vm.prank(bob);
        oracle.submitInitialReportCalldata(
            reportId,
            1e18,
            2000e18,
            expectedStateHash,
            bob,
            false,
            false,
            game,
            helper,
            _emptyTiming()
        );

        // Advance our local copy and verify the new stored hash matches.
        _applyInitialReport(game, 1e18, 2000e18, bob);
        bytes32 afterReportHash = _hashOracle(game, helper);
        game.stateHash = afterReportHash;
        assertEq(_stateHash(reportId), afterReportHash, "hash advanced after initial report");

        // Token holdings: bob's tokens pulled, dust seeded.
        assertEq(_heldTokens(bob, address(token1)), 1, "bob token1 dust");
        assertEq(_heldTokens(bob, address(token2)), 1, "bob token2 dust");

        // Wait for dispute delay.
        vm.warp(block.timestamp + 6);

        // Dispute via calldata variant.
        vm.prank(alice);
        oracle.disputeAndSwapCalldata(
            reportId,
            address(token1),
            1.1e18,
            2100e18,
            alice,
            2000e18,
            afterReportHash,
            false,
            false,
            game,
            helper,
            _emptyTiming()
        );

        _applyDispute(game, 1.1e18, 2100e18, alice);
        bytes32 afterDisputeHash = _hashOracle(game, helper);
        game.stateHash = afterDisputeHash;
        assertEq(_stateHash(reportId), afterDisputeHash, "hash advanced after dispute");

        uint256 fee = (1e18 * 3000) / 1e7;
        assertEq(_heldTokens(bob, address(token1)), 1 + 2e18 + fee, "bob internal token1 after dispute");

        // Wait for settlement.
        vm.warp(block.timestamp + 300);

        // Settle via calldata variant.
        vm.prank(charlie);
        oracle.settleCalldata(reportId, game, helper);

        _applySettle(game);
        bytes32 afterSettleHash = _hashOracle(game, helper);
        assertEq(_stateHash(reportId), afterSettleHash, "hash advanced after settle");

        // Charlie's settler reward credited to ethHolder (sentinel + reward).
        assertEq(oracle.ethHolder(charlie), 1 + SETTLER_REWARD, "settler reward credited");
        // Bob (initial reporter) gets the reporter fee.
        assertEq(oracle.ethHolder(bob), 1 + ORACLE_FEE - SETTLER_REWARD, "initial reporter fee credited");
        // Alice (current reporter at settle) credited final amounts.
        assertEq(_heldTokens(alice, address(token1)), 1 + 1.1e18, "alice internal token1");
        assertEq(_heldTokens(alice, address(token2)), 1 + 2100e18, "alice internal token2");

        // In calldata mode, currentAmount1/2 and settlementTimestamp are not
        // persisted to storage — the contract only stores the rolling stateHash.
        // Callers needing the settled price must keep the final preimage off-chain.
    }

    // Wrong preimage (mismatched stateHash) reverts.
    function testCalldataMode_PreimageMismatch_Reverts() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        uint256 expectedReportId = oracle.nextReportId();

        OpenOracleGG.PreimageHelper memory helper = OpenOracleGG.PreimageHelper({
            reportId: expectedReportId,
            isStorageMode: false,
            creator: alice,
            blockTimestamp: block.timestamp,
            blockNumber: block.number
        });
        OpenOracleGG.OracleGame memory game = _gameFromParams(p, ORACLE_FEE);
        bytes32 stateHash = _hashOracle(game, helper);

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, false);
        game.stateHash = stateHash;

        // Tamper with the local game to mismatch.
        OpenOracleGG.OracleGame memory tampered = game;
        tampered.exactToken1Report = 999e18;

        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.InvalidStateHash.selector);
        oracle.submitInitialReportCalldata(
            reportId, 1e18, 2000e18, stateHash, bob, false, false, tampered, helper, _emptyTiming()
        );
    }

    // Calling a storage-mode entrypoint on a calldata-mode report reverts InvalidMode.
    function testCalldataMode_StorageEntrypoint_RevertsInvalidMode() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, false);

        // Storage-mode entrypoint reverts because _isStorageMode reads
        // exactToken1Report from storage and finds 0.
        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.InvalidMode.selector);
        _submitInitialReport(reportId, 1e18, 2000e18, bytes32(0), false, false, _emptyTiming());
    }

    // Read DisputeRecord struct fields from the disputeHistory mapping.
    function _readDispute(uint256 reportId, uint256 index)
        internal
        view
        returns (uint128 amount1, uint128 amount2, address tokenToSwap, uint48 reportTimestamp)
    {
        return oracle.disputeHistory(reportId, index);
    }

    // ----------------------------------------------------------------
    // Calldata-mode trackDisputes: history is recorded across calldata
    // initial report and dispute, and the local game's numReports must
    // also advance so the rolling stateHash matches storage.
    // ----------------------------------------------------------------
    function testCalldataMode_TrackDisputes() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.trackDisputes = true;

        uint256 expectedReportId = oracle.nextReportId();

        OpenOracleGG.PreimageHelper memory helper = OpenOracleGG.PreimageHelper({
            reportId: expectedReportId,
            isStorageMode: false,
            creator: alice,
            blockTimestamp: block.timestamp,
            blockNumber: block.number
        });
        OpenOracleGG.OracleGame memory game = _gameFromParams(p, ORACLE_FEE);
        bytes32 createdHash = _hashOracle(game, helper);

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, false);
        assertEq(reportId, expectedReportId, "reportId predicted");
        assertEq(_stateHash(reportId), createdHash, "create hash matches");

        game.stateHash = createdHash;

        // Initial report (calldata variant).
        vm.prank(bob);
        oracle.submitInitialReportCalldata(
            reportId, 1e18, 2000e18, createdHash, bob, false, false, game, helper, _emptyTiming()
        );

        // Index 0 = initial report; tokenToSwap is unset on the initial entry.
        (uint128 a1_0, uint128 a2_0, address tok_0, uint48 ts_0) = _readDispute(reportId, 0);
        assertEq(a1_0, 1e18, "init record amount1");
        assertEq(a2_0, 2000e18, "init record amount2");
        assertEq(tok_0, address(0), "init record tokenToSwap unset");
        assertEq(ts_0, uint48(block.timestamp), "init record reportTimestamp");

        // Advance our local game (mirrors what _submitInitialReport wrote).
        _applyInitialReport(game, 1e18, 2000e18, bob);
        bytes32 afterReportHash = _hashOracle(game, helper);
        game.stateHash = afterReportHash;
        assertEq(_stateHash(reportId), afterReportHash, "hash advanced after submit");

        // Dispute (calldata variant).
        vm.warp(block.timestamp + 6);
        uint256 disputeTimestamp = block.timestamp;

        vm.prank(alice);
        oracle.disputeAndSwapCalldata(
            reportId,
            address(token1),
            1.1e18,
            2100e18,
            alice,
            2000e18,
            afterReportHash,
            false,
            false,
            game,
            helper,
            _emptyTiming()
        );

        // Index 1 = first dispute.
        (uint128 a1_1, uint128 a2_1, address tok_1, uint48 ts_1) = _readDispute(reportId, 1);
        assertEq(a1_1, 1.1e18, "dispute record amount1");
        assertEq(a2_1, 2100e18, "dispute record amount2");
        assertEq(tok_1, address(token1), "dispute record tokenToSwap");
        assertEq(uint256(ts_1), disputeTimestamp, "dispute record reportTimestamp");

        // Advance local game to match dispute and verify hash progression.
        _applyDispute(game, 1.1e18, 2100e18, alice);
        bytes32 afterDisputeHash = _hashOracle(game, helper);
        assertEq(_stateHash(reportId), afterDisputeHash, "hash advanced after dispute");
        assertEq(game.numReports, 2, "local numReports == 2");
    }
}
