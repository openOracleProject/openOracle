// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AssetModeBase.t.sol";

/**
 * @notice All four close-auction funding combinations, carried end to end through both a
 *         rewarded claim and an expired zero-reward claim.
 *
 * @dev The reporter's claimed reward always lands in the oracle ledger. The swapper's unspent
 *      remainder follows the funding route recorded in the canonical
 *      Dutch struct. The geometric ladder itself stays canonical in
 *      DutchRewardDiscovery — here the report always lands on round 1, a single hand-derived
 *      value, so only the asset and route vary.
 */
contract DutchFundingModesEndToEndTest is AssetModeBase {
    uint128 internal constant AUCTION_START_REWARD = 10e18;
    uint128 internal constant AUCTION_MAX_REWARD = 100e18;
    // round 1 of a x1.5 curve: 10e18 * 15000 / 10000
    uint128 internal constant ROUND_ONE_REWARD = 15e18;
    uint128 internal constant ROUND_ONE_REMAINDER = AUCTION_MAX_REWARD - ROUND_ONE_REWARD;

    function setUp() public {
        _setUpAssets();
    }

    function _auctionInput() internal view returns (OpenPuntStorage.CloseDutch memory d) {
        d = _dutchInput();
        d.startingReward = AUCTION_START_REWARD;
        d.maxReward = AUCTION_MAX_REWARD;
        d.expiration = uint48(vm.getBlockTimestamp() + 1 hours);
    }

    function _openForAuction(address collatToken)
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _assetCfg(Legs.BothErc20, collatToken, false);
        (swapId, active, p,) = _openAsset(s, m);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Claimed path — the remainder follows the canonical funding route
    // ══════════════════════════════════════════════════════════════════

    function _runClaimed(address collatToken, bool auctionInternal) internal {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openForAuction(collatToken);

        OpenPuntStorage.CloseDutch memory input = _auctionInput();
        input.expiration = uint48(vm.getBlockTimestamp() + 1 hours);
        OpenPuntStorage.CloseDutch memory d = _startAuction(swapId, active, input, auctionInternal, CLOSE_COMP);

        uint256 reporterLedger = _spendable(reporter, collatToken);
        uint256 swapperLedger = _spendable(swapper, collatToken);
        uint256 swapperRaw = collatToken == address(0) ? swapper.balance : collat.balanceOf(swapper);

        _advanceTimeAndBlocks(60, 30); // exactly one Dutch round
        Matched memory mt = _reportAsset(swapId, d, active, p.preimage, reporter, REPORTER_COMP);

        // When collateral is ETH the reporter's reward and compensation share
        // one ledger slot, so the compensation is added back before comparing. That separation is
        // the whole point: a naive delta would silently net the two together.
        uint256 compInSameSlot = collatToken == address(0) ? uint256(REPORTER_COMP) : 0;

        // The reporter's earned reward always lands in the oracle ledger.
        assertEq(
            _spendable(reporter, collatToken) + compInSameSlot - reporterLedger,
            ROUND_ONE_REWARD,
            "reporter reward in the ledger"
        );
        assertEq(ROUND_ONE_REWARD + ROUND_ONE_REMAINDER, AUCTION_MAX_REWARD, "reward plus remainder is the escrow");

        // The unspent remainder returns through the route that funded the auction.
        if (auctionInternal) {
            assertEq(
                _spendable(swapper, collatToken) - swapperLedger,
                ROUND_ONE_REMAINDER,
                "internally funded remainder returned to the ledger"
            );
            if (collatToken == address(0)) {
                assertEq(swapper.balance, swapperRaw, "internal route pushed no raw ETH");
            } else {
                assertEq(collat.balanceOf(swapper), swapperRaw, "internal route pushed no external tokens");
            }
        } else {
            assertEq(_spendable(swapper, collatToken), swapperLedger, "external route left the ledger alone");
            if (collatToken == address(0)) {
                assertEq(swapper.balance - swapperRaw, ROUND_ONE_REMAINDER, "remainder pushed as raw ETH");
            } else {
                assertEq(
                    collat.balanceOf(swapper) - swapperRaw, ROUND_ONE_REMAINDER, "remainder pushed as external tokens"
                );
            }
        }

        // compensation migrated and the hash is gone
        assertEq(_storedDutchState(swapId), bytes32(0), "dutch hash deleted");
        (uint128 pending,,) = _closeState(swapId);
        assertEq(pending, 0, "pending compensation zeroed");
        assertEq(
            punt.executionGasComp(mt.reportId),
            uint256(CLOSE_COMP) + REPORTER_COMP,
            "pending plus reporter-supplied compensation migrated"
        );

        // ── terminal assertions, shared by all four claimed modes ───────
        uint256 closeExecEth0 = _spendable(closeExecutor, address(0));
        uint256 reporterAfterClaim = _spendable(reporter, collatToken);
        uint256 owedToExecutor = uint256(CLOSE_COMP) + REPORTER_COMP;

        _executeReport(swapId, mt, closeExecutor);

        assertEq(
            _spendable(closeExecutor, address(0)) - closeExecEth0,
            owedToExecutor,
            "executor gained exactly the escrowed plus reporter-supplied compensation"
        );
        assertEq(punt.executionGasComp(mt.reportId), 0, "execution compensation drained");
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        (uint128 finalPending,, bool finalIntent) = _closeState(swapId);
        assertEq(finalPending, 0, "close state cleared");
        assertFalse(finalIntent, "close state cleared");

        assertEq(_spendable(address(punt), collatToken), 0, "core retains no collateral");
        assertEq(_spendable(address(punt), address(0)), 0, "core retains no internal ETH");

        // the reward was paid once, at report time; execution adds nothing further
        assertEq(_spendable(reporter, collatToken), reporterAfterClaim, "reporter received no second reward");
        assertEq(ROUND_ONE_REWARD + ROUND_ONE_REMAINDER, AUCTION_MAX_REWARD, "reward plus remainder still the escrow");
    }

    function test_claimed_erc20External() public {
        _runClaimed(address(collat), false);
    }

    function test_claimed_erc20Internal() public {
        _runClaimed(address(collat), true);
    }

    function test_claimed_ethExternal() public {
        _runClaimed(address(0), false);
    }

    function test_claimed_ethInternal() public {
        _runClaimed(address(0), true);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Expired path — the full maximum is returned through the canonical route
    // ══════════════════════════════════════════════════════════════════

    function _runExpired(address collatToken, bool auctionInternal) internal {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p) = _openForAuction(collatToken);

        OpenPuntStorage.CloseDutch memory input = _auctionInput();
        input.expiration = uint48(vm.getBlockTimestamp() + 120);
        OpenPuntStorage.CloseDutch memory d = _startAuction(swapId, active, input, auctionInternal, CLOSE_COMP);
        assertEq(d.useInternalBalances, auctionInternal, "canonical struct records the funding route");

        uint256 reporterLedger = _spendable(reporter, collatToken);
        uint256 swapperLedger = _spendable(swapper, collatToken);
        uint256 swapperRaw = collatToken == address(0) ? swapper.balance : collat.balanceOf(swapper);
        uint256 swapperEthRaw = swapper.balance;

        _advanceTimeAndBlocks(120, 60);
        Matched memory mt = _reportAsset(swapId, _noDutch(), active, p.preimage, reporter, REPORTER_COMP);
        uint256 owedToExecutor = uint256(CLOSE_COMP) + REPORTER_COMP;

        uint256 compInSameSlot = collatToken == address(0) ? uint256(REPORTER_COMP) : 0;

        assertEq(_storedDutchState(swapId), bytes32(0), "expired auction consumed");
        assertEq(
            _spendable(reporter, collatToken) + compInSameSlot,
            reporterLedger,
            "reporter took no reward; only the compensation it funded left the slot"
        );
        assertEq(punt.executionGasComp(mt.reportId), owedToExecutor, "compensation migrated to the report");

        // report() returns the full maximum through the route encoded in the auction.
        if (auctionInternal) {
            assertEq(
                _spendable(swapper, collatToken) - swapperLedger, AUCTION_MAX_REWARD, "reward returned to the ledger"
            );
            if (collatToken == address(0)) {
                assertEq(swapper.balance, swapperEthRaw, "internal route pushed no raw ETH");
            } else {
                assertEq(collat.balanceOf(swapper), swapperRaw, "internal route pushed nothing externally");
            }
        } else {
            if (collatToken == address(0)) {
                assertEq(swapper.balance - swapperEthRaw, AUCTION_MAX_REWARD, "reward pushed as raw ETH");
            } else {
                assertEq(collat.balanceOf(swapper) - swapperRaw, AUCTION_MAX_REWARD, "reward pushed externally");
            }
            assertEq(_spendable(swapper, collatToken), swapperLedger, "external route left the ledger alone");
        }

        _executeReport(swapId, mt, closeExecutor);
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        assertEq(_spendable(closeExecutor, address(0)), owedToExecutor, "executor paid exactly once");
        assertEq(_spendable(address(punt), collatToken), 0, "core fully drained");
    }

    function test_expired_erc20External() public {
        _runExpired(address(collat), false);
    }

    function test_expired_erc20Internal() public {
        _runExpired(address(collat), true);
    }

    function test_expired_ethExternal() public {
        _runExpired(address(0), false);
    }

    function test_expired_ethInternal() public {
        _runExpired(address(0), true);
    }
}
