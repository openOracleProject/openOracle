// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ReentrancyBase.t.sol";

/**
 * @notice Reentrancy at the unused-opening-fee refund, which is the final operation of matchSwap().
 * @dev Hook collateral supplies an unbounded callback. Every probe authenticates with the exact
 *      matched preimage so the asserted rejection comes from the matched-but-inactive state, not
 *      from an accidentally stale hash.
 */
contract ReentrancyMatchSwapRefundTest is ReentrancyBase {
    uint128 internal constant ACTUAL_FEE = 10e18;
    uint128 internal constant MAXIMUM_FEE = 20e18;
    uint128 internal constant FEE_REFUND = MAXIMUM_FEE - ACTUAL_FEE;

    function setUp() public {
        _setUpReentrancy();
    }

    function _feeAuctionCfg()
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _hookCfg();
        s.auctionFunding = false;
        s.fulfillmentFee = 0;
        m.auctionStart = FEE_AUCTION_START;
        m.auctionEnd = FEE_AUCTION_END;
        m.growthRate = FEE_GROWTH_RATE;
        m.roundLength = FEE_ROUND_LENGTH;
        m.maxRounds = FEE_MAX_ROUNDS;
    }

    function _expectedMatched(Proposal memory p) internal view returns (OpenPuntStorage.MatchedSwap memory s) {
        s.swapper = address(actor);
        s.matcher = matcher;
        s.collatToken = address(hookToken);
        s.oracleToken1 = p.swap.oracleToken1;
        s.oracleToken2 = p.swap.oracleToken2;
        s.initialMarginSwapper = p.swap.initialMarginSwapper - FEE_REFUND;
        s.initialMarginMatcher = p.swap.initialMarginMatcher;
        s.maintenanceMarginSwapper = p.swap.maintenanceMarginSwapper;
        s.notional = p.swap.notional;
        s.swapperIsLong = p.swap.isLong;
        s.pnlUsesToken1PerToken2 = p.swap.pnlUsesToken1PerToken2;
        s.fulfillmentFee = uint24(uint32(FEE_AUCTION_START));
        s.fundingRate = p.swap.fundingRate;
        s.feeRecipient = address(0);
        s.matcherPreimageHash = keccak256(abi.encode(p.preimage));
        s.priceTolerated = p.swap.priceTolerated;
        s.toleranceRange = p.swap.toleranceRange;
        s.millisecondsPerBlock = p.swap.millisecondsPerBlock;
        s.maxGameTime = p.swap.maxGameTime;
        s.maxExecutionLatency = p.swap.maxExecutionLatency;
        s.liquidationHeartbeatMin = p.swap.liquidationHeartbeatMin;
        s.liquidationHeartbeatMax = p.swap.liquidationHeartbeatMax;
        s.start = uint48(vm.getBlockTimestamp());
        s.maturityWindow = p.swap.maturityWindow;
        s.openExecutionComp = p.swap.openExecutionComp;
        s.useInternalBalances = p.swap.useInternalBalances;
        s.maturityOnly = p.swap.maturityOnly;
    }

    function _assertHookReverted(bytes4 expected, string memory what) internal view {
        assertFalse(hookToken.lastHookOk(), string.concat(what, ": inner call unexpectedly succeeded"));
        assertEq(hookToken.lastHookSelector(), expected, string.concat(what, ": wrong revert selector"));
    }

    function test_callbackCannotCloseTheMatchedButInactivePosition() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _feeAuctionCfg();
        Proposal memory preview = _actorPropose(actor, s, m);
        OpenPuntStorage.MatchedSwap memory expected = _expectedMatched(preview);

        hookToken.resetHook();
        hookToken.armHook(
            address(actor),
            abi.encodeCall(
                actor.exec,
                (
                    address(punt),
                    0,
                    abi.encodeCall(
                        punt.close,
                        (
                            preview.swapId,
                            _dutchInput(),
                            expected,
                            false,
                            _emptyPermit2(),
                            0,
                            _emptyOracleGame(),
                            _emptyOracleHelper(),
                            0
                        )
                    )
                )
            )
        );
        Matched memory mt = _matchSwapWith(preview, OA2, matcher);
        hookToken.disarmHook();

        assertEq(hookToken.hookCount(), 1, "the refund called back");
        _assertHookReverted(PuntErrors.NotActive.selector, "nested close");
        assertEq(punt.swaps(preview.swapId), keccak256(abi.encode(expected)), "matched state survived");
        assertEq(punt.swapIdToReportId(preview.swapId), mt.reportId, "opening report survived");
    }

    function test_callbackCannotBailOutInTheMatchingTimestamp() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _feeAuctionCfg();
        Proposal memory p = _actorPropose(actor, s, m);
        OpenPuntStorage.MatchedSwap memory expected = _expectedMatched(p);
        bytes memory payload = abi.encodeCall(punt.bailOutOpen, (p.swapId, expected));

        hookToken.resetHook();
        hookToken.armHook(address(actor), abi.encodeCall(actor.exec, (address(punt), 0, payload)));
        Matched memory mt = _matchSwapWith(p, OA2, matcher);
        hookToken.disarmHook();

        assertEq(hookToken.hookCount(), 1, "the refund called back");
        _assertHookReverted(PuntErrors.CantBailOutYet.selector, "nested opening bailout");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(expected)), "matched state survived");
        assertEq(punt.swapIdToReportId(p.swapId), mt.reportId, "opening report survived");
    }

    function test_callbackCannotStartASecondReport() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _feeAuctionCfg();
        Proposal memory p = _actorPropose(actor, s, m);
        OpenPuntStorage.MatchedSwap memory expected = _expectedMatched(p);
        bytes memory payload = abi.encodeCall(
            puntLifecycle.report, (p.swapId, bytes32(0), expected, p.preimage, _noTiming(), address(actor), OA1, OA2, 0)
        );

        hookToken.resetHook();
        hookToken.armHook(address(actor), abi.encodeCall(actor.exec, (address(punt), 0, payload)));
        Matched memory mt = _matchSwapWith(p, OA2, matcher);
        hookToken.disarmHook();

        assertEq(hookToken.hookCount(), 1, "the refund called back");
        _assertHookReverted(PuntErrors.OracleGameInProgress.selector, "nested report");
        assertEq(punt.swaps(p.swapId), keccak256(abi.encode(expected)), "matched state survived");
        assertEq(punt.swapIdToReportId(p.swapId), mt.reportId, "only the opening report exists");
    }
}
