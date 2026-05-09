// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {OpenOracleErrors} from "../../src/OpenOracleErrors.sol";

// Edge-case and regression coverage:
//   - mode-gating matrix (storage-mode reports reject calldata entrypoints
//     and vice versa)
//   - reversed-pair sentinel safety (dust(t2, t1) doesn't reset existing
//     tokenHolder balances)
//   - tampered-preimage reverts on disputeAndSwapCalldata and settleCalldata
//   - block-number-only timing rejection
//   - timeType=false (block-clock) lifecycle
contract OpenOracleGGEdgeCasesTest is BaseGGTest {
    uint256 constant ORACLE_FEE = 0.01 ether;
    uint96 constant SETTLER_REWARD = 0.001 ether;

    function setUp() public override {
        BaseGGTest.setUp();
    }

    // ----------------------------------------------------------------
    // Helpers (small subset of what the calldata-mode test file does;
    // duplicated here to keep this file self-contained)
    // ----------------------------------------------------------------
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
    }

    // =========================================================================
    // Mode-gating matrix
    // =========================================================================

    // Storage-mode report rejects all calldata entrypoints.
    function testStorageReport_RejectsCalldataSubmit() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);

        OpenOracleGG.OracleGame memory game;
        OpenOracleGG.PreimageHelper memory helper;

        vm.prank(bob);
        // helper.isStorageMode defaults to false, so the entrypoint check passes;
        // the hash check catches the mode mismatch (stored hash committed isStorageMode=true).
        vm.expectRevert(OpenOracleErrors.InvalidStateHash.selector);
        oracle.submitInitialReportCalldata(
            reportId, 1e18, 2000e18, bytes32(0), bob, false, false, game, helper, _emptyTiming()
        );
    }

    function testStorageReport_RejectsCalldataDispute() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, _emptyTiming());

        vm.warp(block.timestamp + 6);

        OpenOracleGG.OracleGame memory game;
        OpenOracleGG.PreimageHelper memory helper;

        vm.prank(charlie);
        // helper.isStorageMode defaults to false → entrypoint check passes;
        // hash check catches mode mismatch.
        vm.expectRevert(OpenOracleErrors.InvalidStateHash.selector);
        oracle.disputeAndSwapCalldata(
            reportId,
            address(token1),
            1.1e18,
            2100e18,
            charlie,
            2000e18,
            sh,
            false,
            false,
            game,
            helper,
            _emptyTiming()
        );
    }

    function testStorageReport_RejectsCalldataSettle() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, _emptyTiming());

        vm.warp(block.timestamp + 301);

        OpenOracleGG.OracleGame memory game;
        OpenOracleGG.PreimageHelper memory helper;

        vm.prank(charlie);
        // helper.isStorageMode defaults to false → entrypoint check passes;
        // hash check catches mode mismatch.
        vm.expectRevert(OpenOracleErrors.InvalidStateHash.selector);
        oracle.settleCalldata(reportId, game, helper);
    }

    // Calldata-mode report rejects storage entrypoints.
    function testCalldataReport_RejectsStorageDispute() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        OpenOracleGG.PreimageHelper memory helper = OpenOracleGG.PreimageHelper({
            reportId: 0,
            isStorageMode: false,
            creator: alice,
            blockTimestamp: 0,
            blockNumber: 0
        });
        OpenOracleGG.OracleGame memory game = _gameFromParams(p, ORACLE_FEE);

        vm.prank(alice);
        uint256 reportId = oracle.createAndReportCalldata{value: ORACLE_FEE}(
            p, false, 1e18, 2000e18, bob, false, false, game, helper, _emptyTiming()
        );

        vm.warp(block.timestamp + 6);

        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.InvalidMode.selector);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, bytes32(0), false, false, _emptyTiming()
        );
    }

    function testCalldataReport_RejectsStorageSettle() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        OpenOracleGG.PreimageHelper memory helper = OpenOracleGG.PreimageHelper({
            reportId: 0,
            isStorageMode: false,
            creator: alice,
            blockTimestamp: 0,
            blockNumber: 0
        });
        OpenOracleGG.OracleGame memory game = _gameFromParams(p, ORACLE_FEE);

        vm.prank(alice);
        uint256 reportId = oracle.createAndReportCalldata{value: ORACLE_FEE}(
            p, false, 1e18, 2000e18, bob, false, false, game, helper, _emptyTiming()
        );

        vm.warp(block.timestamp + 301);

        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.InvalidMode.selector);
        oracle.settle(reportId);
    }

    // =========================================================================
    // Reversed-pair sentinel safety
    // =========================================================================

    // If tokenHolder[user][token1] is already > 1 from a prior interaction,
    // calling dust(token2, token1) (reversed pair) must NOT clobber that
    // balance. The dust seed is conditional on slot == 0.
    function testReversedPairDust_DoesNotResetExistingBalance() public {
        // bob deposits 5 token1 and 7 token2; both slots seeded by depositTokens.
        vm.prank(bob);
        oracle.depositTokens(address(token1), 5e18);
        vm.prank(bob);
        oracle.depositTokens(address(token2), 7e18);

        uint256 t1Before = _heldTokens(bob, address(token1));
        uint256 t2Before = _heldTokens(bob, address(token2));
        assertEq(t1Before, 1 + 5e18, "token1 sentinel + deposit");
        assertEq(t2Before, 1 + 7e18, "token2 sentinel + deposit");

        // Reversed-pair dust call.
        vm.prank(bob);
        oracle.dust(address(token2), address(token1));

        // Balances must be unchanged — _dust only seeds slots that are 0.
        assertEq(_heldTokens(bob, address(token1)), t1Before, "token1 unchanged");
        assertEq(_heldTokens(bob, address(token2)), t2Before, "token2 unchanged");

        // Forward-pair dust call: also a no-op (still both nonzero).
        vm.prank(bob);
        oracle.dust(address(token1), address(token2));
        assertEq(_heldTokens(bob, address(token1)), t1Before, "token1 still unchanged");
        assertEq(_heldTokens(bob, address(token2)), t2Before, "token2 still unchanged");
    }

    // =========================================================================
    // Calldata preimage mismatch on dispute and settle
    // =========================================================================

    function _setupCalldataReportAndInitialReport()
        internal
        returns (
            uint256 reportId,
            OpenOracleGG.OracleGame memory game,
            OpenOracleGG.PreimageHelper memory helper,
            bytes32 currentHash
        )
    {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        uint256 expectedReportId = oracle.nextReportId();

        helper = OpenOracleGG.PreimageHelper({
            reportId: expectedReportId,
            isStorageMode: false,
            creator: alice,
            blockTimestamp: block.timestamp,
            blockNumber: block.number
        });
        game = _gameFromParams(p, ORACLE_FEE);
        bytes32 createHash = _hashOracle(game, helper);

        vm.prank(alice);
        reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, false);
        game.stateHash = createHash;

        vm.prank(bob);
        oracle.submitInitialReportCalldata(
            reportId, 1e18, 2000e18, createHash, bob, false, false, game, helper, _emptyTiming()
        );

        _applyInitialReport(game, 1e18, 2000e18, bob);
        currentHash = _hashOracle(game, helper);
        game.stateHash = currentHash;
    }

    function testDisputeCalldata_TamperedPreimage_Reverts() public {
        (
            uint256 reportId,
            OpenOracleGG.OracleGame memory game,
            OpenOracleGG.PreimageHelper memory helper,
            bytes32 currentHash
        ) = _setupCalldataReportAndInitialReport();

        vm.warp(block.timestamp + 6);

        // Tamper any field that's part of the hash. exactToken1Report is fine —
        // it's static and committed to the create-time hash.
        OpenOracleGG.OracleGame memory tampered = game;
        tampered.exactToken1Report = 999e18;

        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.InvalidStateHash.selector);
        oracle.disputeAndSwapCalldata(
            reportId,
            address(token1),
            1.1e18,
            2100e18,
            charlie,
            2000e18,
            currentHash,
            false,
            false,
            tampered,
            helper,
            _emptyTiming()
        );
    }

    function testSettleCalldata_TamperedPreimage_Reverts() public {
        (
            uint256 reportId,
            OpenOracleGG.OracleGame memory game,
            OpenOracleGG.PreimageHelper memory helper,
            /* currentHash */
        ) = _setupCalldataReportAndInitialReport();

        vm.warp(block.timestamp + 301);

        // Tamper the helper.creator — it commits to the hash.
        OpenOracleGG.PreimageHelper memory tamperedHelper = helper;
        tamperedHelper.creator = charlie;

        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.InvalidStateHash.selector);
        oracle.settleCalldata(reportId, game, tamperedHelper);
    }

    // Stale preimage — passing a preimage that's old (does not reflect the
    // most recent state mutation) should also fail because the stored hash
    // has rolled forward.
    function testSettleCalldata_StalePreimage_Reverts() public {
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
        bytes32 createHash = _hashOracle(game, helper);

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, false);
        game.stateHash = createHash;

        // Save the create-time game (which has currentAmount1 == 0).
        OpenOracleGG.OracleGame memory staleGame = game;

        // Submit advances the on-chain stateHash.
        vm.prank(bob);
        oracle.submitInitialReportCalldata(
            reportId, 1e18, 2000e18, createHash, bob, false, false, game, helper, _emptyTiming()
        );

        vm.warp(block.timestamp + 301);

        // Try to settle using the stale (pre-submit) game preimage.
        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.InvalidStateHash.selector);
        oracle.settleCalldata(reportId, staleGame, helper);
    }

    // =========================================================================
    // createAndReportCalldata with tampered preimages
    // =========================================================================

    // The combined entrypoint overrides reportId/blockTimestamp/blockNumber on
    // the helper before hashing, but creator and isStorageMode flow through
    // from the caller. A wrong creator therefore must cause the rolled-forward
    // hash to mismatch what was committed during create.
    function testCreateAndReportCalldata_TamperedHelperCreator_Reverts() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        OpenOracleGG.OracleGame memory game = _gameFromParams(p, ORACLE_FEE);
        OpenOracleGG.PreimageHelper memory helper = OpenOracleGG.PreimageHelper({
            reportId: 0,
            isStorageMode: false,
            creator: charlie, // WRONG — msg.sender will be alice
            blockTimestamp: 0,
            blockNumber: 0
        });

        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.InvalidStateHash.selector);
        oracle.createAndReportCalldata{value: ORACLE_FEE}(
            p, false, 1e18, 2000e18, bob, false, false, game, helper, _emptyTiming()
        );
    }

    // Tampering the OracleGame preimage's static fields (anything that
    // contributes to the create-time hash) must also revert.
    function testCreateAndReportCalldata_TamperedOracleGame_Reverts() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        OpenOracleGG.OracleGame memory game = _gameFromParams(p, ORACLE_FEE);
        // Tamper a static field that IS part of the create-time hash.
        game.exactToken1Report = 999e18;

        OpenOracleGG.PreimageHelper memory helper = OpenOracleGG.PreimageHelper({
            reportId: 0,
            isStorageMode: false,
            creator: alice,
            blockTimestamp: 0,
            blockNumber: 0
        });

        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.InvalidStateHash.selector);
        oracle.createAndReportCalldata{value: ORACLE_FEE}(
            p, false, 1e18, 2000e18, bob, false, false, game, helper, _emptyTiming()
        );
    }

    // =========================================================================
    // protocolFeeRecipient == address(0) (intended burn)
    // =========================================================================

    // Passing address(0) leaves oracle.protocolFeeRecipient as the zero address.
    // Protocol fees are credited to tokenHolder[address(0)][token], where they
    // are effectively burned (no one can prank as address(0) and call
    // getHeldTokens). Dispute must NOT revert in this case.
    function testProtocolFeeRecipient_ZeroAddress_BurnsFees() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.protocolFeeRecipient = address(0);

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, true);
        bytes32 sh = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, _emptyTiming());

        vm.warp(block.timestamp + 6);

        vm.prank(charlie);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, sh, false, false, _emptyTiming()
        );

        // Protocol fee was credited to address(0)'s slot (sentinel + fee).
        uint256 protoFee = (1e18 * 1000) / 1e7;
        assertEq(oracle.tokenHolder(address(0), address(token1)), 1 + protoFee, "fee at address(0)");

        // No real account got the fee.
        assertEq(oracle.tokenHolder(alice, address(token1)), 0, "alice no fee");
        assertEq(oracle.tokenHolder(charlie, address(token1)), 1, "charlie only sentinel");
        // bob got the previousReporter credit (2*oldA1 + fee), but no protocol fee.
        uint256 reporterFee = (1e18 * 3000) / 1e7;
        assertEq(
            oracle.tokenHolder(bob, address(token1)),
            1 + 2e18 + reporterFee,
            "bob only previousReporter credit, no protocol fee"
        );
    }

    // =========================================================================
    // Block-number-only timing rejection
    // =========================================================================

    // Even with a perfect block.timestamp match, a stale block.number must
    // cause _validateTiming to revert. Defends against regressions to the
    // block-clock branch of the validator.
    function testTimingBounds_RejectsStaleBlockNumber() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_defaultParams(), true);
        bytes32 sh = _stateHash(reportId);

        // Advance block.number a lot, but keep block.timestamp identical.
        vm.roll(block.number + 1000);

        OpenOracleGG.TimingBoundaries memory timing = OpenOracleGG.TimingBoundaries({
            blockNumber: block.number - 1000, // stale
            blockNumberBound: 5,
            blockTimestamp: block.timestamp,
            blockTimestampBound: 60
        });

        vm.prank(bob);
        vm.expectRevert(OpenOracleErrors.InvalidTiming.selector);
        _submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, timing);
    }

    // =========================================================================
    // timeType=false (block-clock) lifecycle
    // =========================================================================

    // Lifecycle with block-clock semantics: dispute delay and settlement time
    // are measured in blocks. Asserts the block-clock branch of the
    // dispute-too-early / settle-too-early checks works.
    function testBlockClockLifecycle() public {
        OpenOracleGG.CreateReportParams memory p = _defaultParams();
        p.timeType = false;
        p.settlementTime = 10; // 10 blocks
        p.disputeDelay = 2; // 2 blocks

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(p, true);
        bytes32 sh = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, _emptyTiming());

        // Immediate dispute reverts (blocks haven't advanced).
        vm.prank(charlie);
        vm.expectRevert(OpenOracleErrors.DisputeTooEarly.selector);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, sh, false, false, _emptyTiming()
        );

        // Roll past dispute delay.
        vm.roll(block.number + 3);

        vm.prank(charlie);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, sh, false, false, _emptyTiming()
        );

        // Settle attempt before settlement window elapses reverts.
        vm.prank(alice);
        vm.expectRevert(OpenOracleErrors.SettleTooEarly.selector);
        oracle.settle(reportId);

        // Roll past settlement window (10 blocks from last dispute).
        vm.roll(block.number + 11);

        vm.prank(alice);
        oracle.settle(reportId);

        // settlementTimestamp slot should be the current block.number.
        bytes32 base = keccak256(abi.encode(reportId, ORACLE_GAME_SLOT));
        bytes32 packed = vm.load(address(oracle), bytes32(uint256(base) + 2));
        uint48 settlementTimestamp = uint48(uint256(packed) >> 208);
        assertEq(uint256(settlementTimestamp), block.number, "settlement uses block.number");

        // currentReporter (charlie, the disputer) credited their final amounts.
        assertEq(_heldTokens(charlie, address(token1)), 1 + 1.1e18, "charlie token1 credited");
        assertEq(_heldTokens(charlie, address(token2)), 1 + 2100e18, "charlie token2 credited");
    }
}
