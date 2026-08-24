// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AssetModeBase.t.sol";
import {OpenPuntFeeReceiver} from "../../src/levered-swaps/OpenPuntFeeReceiver.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/**
 * @notice Fixture for the counterfactual per-position fee receiver.
 *
 * @dev Fees are accrued through real `OpenOracle.dispute()` calls, and the post-dispute state
 *      fed into every later protocol call is decoded from the real packed `ReportDisputed`
 *      payload, never rebuilt locally.
 *
 *      Direct `oracle.deposit()` into a receiver is used only for isolated receiver mechanics such
 *      as the uint128 per-call ceiling. It is not used to prove protocol-fee routing.
 *
 *      Expected fee arithmetic, derived independently from the dispute direction:
 *          swapToken2 == false  ->  token1 fee = floor(oldAmount1 * protocolFee / 1e7)
 *          swapToken2 == true   ->  token2 fee = floor(oldAmount2 * protocolFee / 1e7)
 *      where swapToken2 is `newAmount2 * oldAmount1 > oldAmount2 * newAmount1`.
 *
 *      The receiver's raw oracle balance is fee + 1; the extra unit is OpenOracle's sentinel,
 *      so assertions use `_spendable`.
 */
abstract contract FeeReceiverBase is AssetModeBase {
    /// @dev 1% of the relevant leg. With 1e18 legs this is exactly 1e16 per dispute.
    uint24 internal constant PROTO_FEE = 100_000;
    uint128 internal constant FEE_PER_DISPUTE = 1e16; // 1e18 * 100_000 / 1e7

    /// @dev Forced dispute growth: newAmount1 == oldAmount1 * multiplier / 100, multiplier 110.
    uint128 internal constant A1_AFTER_ONE_DISPUTE = 11e17; // 1.1e18
    uint128 internal constant A1_AFTER_TWO_DISPUTES = 121e16; // 1.21e18

    address internal disputer = address(0x6001);
    address internal disputer2 = address(0x6002);

    function _setUpFees() internal {
        _setUpAssets();
        _armDisputer(disputer);
        _armDisputer(disputer2);
    }

    function _armDisputer(address who) internal {
        vm.deal(who, 100_000 ether);
        _mintAndDeposit(tokenA, who, 1_000_000e18);
        _mintAndDeposit(tokenB, who, 1_000_000e18);
        vm.startPrank(who);
        oracle.deposit{value: 10_000 ether}(address(0), 10_000 ether, who);
        vm.stopPrank();
    }

    // ── configuration ───────────────────────────────────────────────────

    /// @dev Fee-bearing position. The tolerance band is widened only so that a disputed opening
    ///      price does not trip the unrelated slippage rule.
    function _feeCfg(Legs legs, address collatToken, uint24 protocolFee)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _assetCfg(legs, collatToken, false);
        s.toleranceRange = 5e6;
        m.protocolFee = protocolFee;
    }

    function _defaultFeeCfg()
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        return _feeCfg(Legs.BothErc20, address(collat), PROTO_FEE);
    }

    // ── genuine dispute driver ──────────────────────────────────────────

    struct Game {
        uint256 reportId;
        IOpenOracle2.OracleGame game;
        IOpenOracle2.PreimageHelper helper;
    }

    function _gameOf(Matched memory mt) internal pure returns (Game memory g) {
        g.reportId = mt.reportId;
        g.game = mt.game;
        g.helper = mt.helper;
    }

    /// @dev Independently derived expected protocol fee and its token, from the dispute
    ///      direction rather than from any production helper.
    function _expectedFee(Game memory g, uint128 newA1, uint128 newA2)
        internal
        pure
        returns (bool swapToken2, address feeToken, uint256 fee)
    {
        uint256 oldA1 = g.game.currentAmount1;
        uint256 oldA2 = g.game.currentAmount2;
        swapToken2 = uint256(newA2) * oldA1 > oldA2 * uint256(newA1);
        if (swapToken2) {
            feeToken = g.game.token2;
            fee = oldA2 * g.game.protocolFee / 1e7;
        } else {
            feeToken = g.game.token1;
            fee = oldA1 * g.game.protocolFee / 1e7;
        }
    }

    /// @dev Advances into the dispute window, disputes for real, and returns the state decoded
    ///      from the packed ReportDisputed payload after proving it is the oracle's commitment.
    function _dispute(Game memory g, uint128 newA1, uint128 newA2, address who) internal returns (Game memory next) {
        // strictly after disputeDelay and strictly before settlement eligibility
        // In block mode, disputeDelay and settlementTime are block counts, and the game's
        // reportTimestamp field holds the report's block number.
        uint256 blocksSinceReport = vm.getBlockNumber() - g.game.reportTimestamp;
        require(blocksSinceReport < g.game.settlementTime, "fixture: dispute window already closed");
        if (blocksSinceReport <= g.game.disputeDelay) {
            uint256 hopBlocks = uint256(g.game.disputeDelay) - blocksSinceReport + 1;
            require(blocksSinceReport + hopBlocks < g.game.settlementTime, "fixture: hop overshoots the window");
            _advanceTimeAndBlocks(_secondsForBlocks(hopBlocks), hopBlocks);
        }

        vm.recordLogs();
        vm.prank(who);
        IOpenOracle2(address(oracle)).dispute(g.reportId, newA1, newA2, who, true, true, g.game, g.helper, _noTiming());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory l = _findLog(logs, address(oracle), OpenOracle.ReportDisputed.selector, g.reportId);
        next.reportId = g.reportId;
        next.game = PackedDecoder.decodeOracleGame(l.data);
        next.helper = PackedDecoder.decodeHelperTail(l.data, g.reportId);

        assertEq(
            oracle.oracleGame(next.reportId),
            keccak256(abi.encode(next.game, next.helper)),
            "the disputed state decoded from ReportDisputed is the oracle's commitment"
        );
        assertEq(next.game.currentAmount1, newA1, "decoded amount1");
        assertEq(next.game.currentAmount2, newA2, "decoded amount2");
        assertEq(next.game.currentReporter, who, "decoded reporter");
    }

    /// @dev One dispute that credits the fee in TOKEN1 (swapToken2 == false), asserting the
    ///      realised receiver credit equals the independently derived amount.
    function _disputeForToken1Fee(Game memory g, address who) internal returns (Game memory next, uint256 fee) {
        uint128 newA1 = uint128(uint256(g.game.currentAmount1) * g.game.multiplier / 100);
        uint128 newA2 = g.game.currentAmount2; // unchanged -> ratio falls -> swapToken2 false

        bool swapToken2;
        address feeToken;
        (swapToken2, feeToken, fee) = _expectedFee(g, newA1, newA2);
        assertFalse(swapToken2, "fixture: this dispute must take the token1 branch");
        assertEq(feeToken, g.game.token1, "fixture: fee is denominated in token1");

        address recipient = g.game.protocolFeeRecipient;
        uint256 before = _spendable(recipient, feeToken);
        next = _dispute(g, newA1, newA2, who);
        assertEq(_spendable(recipient, feeToken) - before, fee, "token1 protocol fee credited exactly");
    }

    /// @dev One dispute that credits the fee in TOKEN2 (swapToken2 == true).
    function _disputeForToken2Fee(Game memory g, address who) internal returns (Game memory next, uint256 fee) {
        uint128 newA1 = uint128(uint256(g.game.currentAmount1) * g.game.multiplier / 100);
        // push the token2/token1 ratio up past the growth factor so the other branch is taken
        uint128 newA2 = uint128(uint256(g.game.currentAmount2) * 2);

        bool swapToken2;
        address feeToken;
        (swapToken2, feeToken, fee) = _expectedFee(g, newA1, newA2);
        assertTrue(swapToken2, "fixture: this dispute must take the token2 branch");
        assertEq(feeToken, g.game.token2, "fixture: fee is denominated in token2");

        address recipient = g.game.protocolFeeRecipient;
        uint256 before = _spendable(recipient, feeToken);
        next = _dispute(g, newA1, newA2, who);
        assertEq(_spendable(recipient, feeToken) - before, fee, "token2 protocol fee credited exactly");
    }

    // ── counterfactual prediction, derived with LibClone directly ───────

    function _predict(
        uint256 swapId,
        address token1_,
        address token2_,
        address swapper_,
        address matcher_,
        address deployer
    ) internal view returns (address) {
        bytes memory args = abi.encodePacked(swapId, token1_, token2_, swapper_, matcher_);
        return LibClone.predictDeterministicAddress(punt.feeReceiverImpl(), args, bytes32(swapId), deployer);
    }

    function _predictForPosition(uint256 swapId, OpenPuntStorage.MatchedSwap memory s)
        internal
        view
        returns (address)
    {
        return _predict(swapId, s.oracleToken1, s.oracleToken2, s.swapper, s.matcher, address(punt));
    }

    // ── routed deploy-and-distribute ────────────────────────────────────

    function _deployAndDistribute(uint256 swapId, address swapper_, address matcher_, Game memory g, address caller)
        internal
        returns (address receiver, uint256 fees1, uint256 fees2, Vm.Log[] memory logs)
    {
        vm.recordLogs();
        vm.prank(caller);
        (receiver, fees1, fees2) =
            puntLifecycle.deployAndDistributeFeeReceiver(swapId, swapper_, matcher_, g.game, g.helper);
        logs = vm.getRecordedLogs();
    }

    /// @dev Calls `distribute()` straight on the clone: no core routing, no oracle preimages,
    ///      no position state. The clone is a standalone permissionless sweeper once deployed.
    function _distributeDirect(address receiver, address caller)
        internal
        returns (uint256 fees1, uint256 fees2, Vm.Log[] memory logs)
    {
        vm.recordLogs();
        vm.prank(caller);
        (fees1, fees2) = OpenPuntFeeReceiver(receiver).distribute();
        logs = vm.getRecordedLogs();
    }

    function _readFeesDistributed(Vm.Log[] memory logs, address receiver, uint256 swapId)
        internal
        pure
        returns (uint256 fees1, uint256 fees2)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != receiver) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != OpenPuntFeeReceiver.FeesDistributed.selector) continue;
            if (uint256(logs[i].topics[1]) != swapId) continue;
            return abi.decode(logs[i].data, (uint256, uint256));
        }
        revert("FeeReceiverBase: FeesDistributed not found");
    }

    function _hasFeesDistributed(Vm.Log[] memory logs, address receiver) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != receiver) continue;
            if (logs[i].topics.length < 1) continue;
            if (logs[i].topics[0] == OpenPuntFeeReceiver.FeesDistributed.selector) return true;
        }
        return false;
    }

    // ── per-token, per-owner reconciliation ─────────────────────────────

    /// @dev Every balance a distribution can touch, kept separate. An aggregate "beneficiaries
    ///      gained the total" check would hide reversed recipients, wrong rounding, or
    ///      cross-token accounting, so nothing here is summed.
    struct FeeBook {
        uint256 receiver1;
        uint256 receiver2;
        uint256 swapper1;
        uint256 swapper2;
        uint256 matcher1;
        uint256 matcher2;
        uint256 swapperRawEth;
        uint256 matcherRawEth;
        uint256 core1;
        uint256 core2;
        uint256 module1;
        uint256 module2;
    }

    function _feeBook(address receiver, address t1, address t2) internal view returns (FeeBook memory b) {
        b.receiver1 = _spendable(receiver, t1);
        b.receiver2 = _spendable(receiver, t2);
        b.swapper1 = _spendable(swapper, t1);
        b.swapper2 = _spendable(swapper, t2);
        b.matcher1 = _spendable(matcher, t1);
        b.matcher2 = _spendable(matcher, t2);
        b.swapperRawEth = swapper.balance;
        b.matcherRawEth = matcher.balance;
        b.core1 = _spendable(address(punt), t1);
        b.core2 = _spendable(address(punt), t2);
        b.module1 = _spendable(address(lifecycleModule), t1);
        b.module2 = _spendable(address(lifecycleModule), t2);
    }

    /// @dev Split with the remainder going to the matcher, written out rather than reused.
    function _split(uint256 collected) internal pure returns (uint256 swapperPiece, uint256 matcherPiece) {
        swapperPiece = collected / 2;
        matcherPiece = collected - swapperPiece;
    }

    /// @dev Full per-token reconciliation of one distribution.
    function _assertDistributed(
        FeeBook memory before,
        address receiver,
        address t1,
        address t2,
        uint256 fees1,
        uint256 fees2,
        string memory what
    ) internal view {
        (uint256 s1, uint256 m1) = _split(fees1);
        (uint256 s2, uint256 m2) = _split(fees2);

        assertEq(_spendable(swapper, t1) - before.swapper1, s1, string.concat(what, ": swapper token1 share"));
        assertEq(_spendable(matcher, t1) - before.matcher1, m1, string.concat(what, ": matcher token1 share"));
        assertEq(_spendable(swapper, t2) - before.swapper2, s2, string.concat(what, ": swapper token2 share"));
        assertEq(_spendable(matcher, t2) - before.matcher2, m2, string.concat(what, ": matcher token2 share"));

        assertEq(before.receiver1 - _spendable(receiver, t1), fees1, string.concat(what, ": receiver token1 drained"));
        assertEq(before.receiver2 - _spendable(receiver, t2), fees2, string.concat(what, ": receiver token2 drained"));

        // payouts are internal only
        assertEq(swapper.balance, before.swapperRawEth, string.concat(what, ": no raw ETH to the swapper"));
        assertEq(matcher.balance, before.matcherRawEth, string.concat(what, ": no raw ETH to the matcher"));

        // neither the core nor the module takes a cut
        assertEq(_spendable(address(punt), t1), before.core1, string.concat(what, ": core token1 untouched"));
        assertEq(_spendable(address(punt), t2), before.core2, string.concat(what, ": core token2 untouched"));
        assertEq(_spendable(address(lifecycleModule), t1), before.module1, string.concat(what, ": module token1"));
        assertEq(_spendable(address(lifecycleModule), t2), before.module2, string.concat(what, ": module token2"));
    }

    /// @dev After a full drain the receiver keeps exactly the one-unit sentinel per token.
    function _assertOnlySentinelsRemain(address receiver, address t1, address t2, string memory what) internal view {
        assertEq(oracle.tokenHolder(receiver, t1), 1, string.concat(what, ": token1 sentinel only"));
        assertEq(oracle.tokenHolder(receiver, t2), 1, string.concat(what, ": token2 sentinel only"));
        assertEq(_spendable(receiver, t1), 0, string.concat(what, ": token1 spendable zero"));
        assertEq(_spendable(receiver, t2), 0, string.concat(what, ": token2 spendable zero"));
    }
}
