// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../OpenPuntBase.t.sol";
import {OpenPuntHandler} from "./OpenPuntHandler.sol";

/**
 * @notice Shared deployment and invariant assertions for the OpenPunt stateful campaigns.
 *
 * @dev The real core, lifecycle module, oracle, tokens and fee-receiver implementation are deployed
 *      by `OpenPuntBase._setUpAll()`. The handler drives them through genuine calls only.
 *
 *      The assertions compare the handler's independent event-derived
 *      shadow state against storage, and compare a separately maintained obligation counter against
 *      the core's real spendable collateral. They never recompute production arithmetic.
 */
abstract contract OpenPuntInvariantBase is OpenPuntBase {
    OpenPuntHandler internal handler;

    function _deployHandler() internal {
        address[6] memory actors = [swapper, matcher, reporter, executor, outsider, settler];
        handler = new OpenPuntHandler(punt, oracle, collat, tokenA, tokenB, actors);

        // fund the handler's actors through real mints, approvals and deposits
        vm.deal(address(handler), 1_000_000 ether);
        for (uint256 i = 0; i < actors.length; i++) {
            vm.deal(actors[i], 1_000_000 ether);
            collat.mint(actors[i], 10_000_000e18);
            tokenA.mint(actors[i], 10_000e18);
            tokenB.mint(actors[i], 100_000_000e18);
            vm.startPrank(actors[i]);
            collat.approve(PERMIT2, type(uint256).max);
            collat.approve(address(oracle), type(uint256).max);
            tokenA.approve(address(oracle), type(uint256).max);
            tokenB.approve(address(oracle), type(uint256).max);
            oracle.deposit(address(collat), 5_000_000e18, actors[i]);
            oracle.deposit(address(tokenA), 5_000e18, actors[i]);
            oracle.deposit(address(tokenB), 50_000_000e18, actors[i]);
            oracle.deposit{value: 100 ether}(address(0), 100 ether, actors[i]);
            _approveIfUnset(actors[i], address(collat));
            _approveIfUnset(actors[i], address(tokenA));
            _approveIfUnset(actors[i], address(tokenB));
            _approveIfUnset(actors[i], address(0));
            vm.stopPrank();
        }
        vm.txGasPrice(1 gwei); // heartbeats reject forced transactions
        handler.snapshotBaselines([swapper, matcher, reporter, executor, outsider, settler]);
    }

    /**
     * @dev Seeds one genuinely opened position through the same handler actions the fuzzer calls,
     *      so every campaign starts with a live position and cannot be vacuous. Deterministic
     *      reachability tests separately cover each action.
     */
    function _seedOnePosition() internal {
        handler.propose(1);
        handler.matchSwap(1);
        handler.clockToEligibility(1);
        handler.executeOpening(1);
        require(handler.count("executeOpeningSuccess") == 1, "seed: position did not open");
    }

    /**
     * @dev Restricts the fuzzer to plain EOA senders.
     *
     *      Foundry draws invariant senders from its address dictionary, which includes contracts
     *      deployed during setUp, and it funds each sender. Left unrestricted, the lifecycle module
     *      is eventually selected as a sender and receives ETH it has no payable entry point to
     *      accept — making `_assertModuleClean`'s raw-balance check fail for a reason that has
     *      nothing to do with the protocol. The handler pranks internally, so sender identity is
     *      irrelevant to what the protocol sees.
     */
    function _restrictSenders() internal {
        targetSender(address(0xEE01));
        targetSender(address(0xEE02));
        targetSender(address(0xEE03));
    }

    /// @dev `_setUpAll` already granted some of these; the oracle refuses to overwrite a nonzero
    ///      internal allowance, so only the unset ones are granted here.
    function _approveIfUnset(address who, address token) internal {
        if (oracle.internalAllowance(who, address(punt), token) == 0) {
            oracle.approveInternal(address(punt), token, type(uint256).max);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. Lifecycle and hash invariants
    // ══════════════════════════════════════════════════════════════════

    function _assertLifecycle() internal view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            OpenPuntHandler.Pos memory q = handler.get(id);
            bytes32 stored = punt.swaps(id);

            if (q.phase == OpenPuntHandler.Phase.Finalized) {
                assertEq(stored, bytes32(0), "terminal position must have no live hash");
                continue;
            }

            if (q.phase == OpenPuntHandler.Phase.Proposed) {
                assertEq(
                    stored,
                    keccak256(abi.encode(q.proposed, q.preimage)),
                    "proposed hash reconstructs from the emitted structs"
                );
                assertEq(q.matched.matcher, address(0), "a proposal has no matcher");
                assertEq(q.reportId, 0, "a proposal has no report");
                continue;
            }

            // every matched phase commits the MatchedSwap alone
            assertEq(stored, keccak256(abi.encode(q.matched)), "matched hash reconstructs from the emitted struct");

            if (q.phase == OpenPuntHandler.Phase.OpeningReport) {
                assertTrue(q.matched.matcher != address(0), "opening report has a matcher");
                assertFalse(q.matched.active, "opening report is not yet active");
                assertTrue(q.reportId != 0, "opening report carries exactly one report id");
                assertEq(punt.swapIdToReportId(id), q.reportId, "and the sidecar holds the modeled one");
            } else if (q.phase == OpenPuntHandler.Phase.ActiveReport) {
                assertTrue(q.matched.active, "active-report position is active");
                assertEq(punt.swapIdToReportId(id), q.reportId, "sidecar carries exactly the modeled report id");
                assertTrue(q.reportId != 0, "and it is nonzero");
            } else {
                assertTrue(q.matched.active, "active-idle/auction position is active");
                assertEq(punt.swapIdToReportId(id), 0, "and holds no report");
            }
        }
    }

    /// @dev 9. The oracle's commitment for a live report reconstructs from the event-derived
    ///      OracleGame and PreimageHelper, accounting for a settlement that really happened.
    function _assertOracleCommitment() internal view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            OpenPuntHandler.Pos memory q = handler.get(id);
            if (q.reportId == 0) continue;
            if (q.phase != OpenPuntHandler.Phase.OpeningReport && q.phase != OpenPuntHandler.Phase.ActiveReport) {
                continue;
            }
            assertEq(
                oracle.oracleGame(q.reportId),
                keccak256(abi.encode(q.game, q.helper)),
                "oracle commitment reconstructs from the event-derived preimage"
            );
            if (q.phase == OpenPuntHandler.Phase.ActiveReport) {
                assertEq(q.game.flags, 1 << 4, "active report stores settlement eligibility");
                assertEq(
                    oracle.settlementEligibility(q.reportId),
                    q.game.reportTimestamp + q.game.settlementTime,
                    "active report eligibility matches the modeled game"
                );
            } else {
                assertEq(q.game.flags, 0, "opening report uses no stored eligibility");
                assertEq(oracle.settlementEligibility(q.reportId), 0, "opening report has no eligibility sidecar");
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  7. Collateral conservation
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice The core's spendable collateral equals the independently modeled obligation.
     *
     * @dev The model counts position margins and Dutch rewards separately and adds them; it never
     *      derives either from the contract. Fee-receiver balances live on their own oracle slots
     *      and are therefore excluded by construction.
     */
    function _assertCollateralConservation() internal view {
        uint256 held = _spendable(address(punt), address(collat));
        assertEq(held, handler.expectedCollat(), "core collateral equals the modeled obligation");

        // and the two components are tracked apart
        uint256 margins;
        uint256 dutch;
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            OpenPuntHandler.Pos memory q = handler.get(handler.ids(i));
            margins += q.marginPool;
            dutch += q.dutchHeld;
            if (q.phase == OpenPuntHandler.Phase.Finalized) {
                assertEq(q.marginPool, 0, "a finalized position contributes no margin obligation");
            }
        }
        assertEq(margins + dutch, handler.expectedCollat(), "margins and Dutch rewards are counted separately");
    }

    /**
     * @notice 4/5. Terminal payouts distribute exactly the pre-terminal margin pool, once, and to
     *         the right recipients.
     *
     * @dev Event-derived amounts are kept, but are not treated as proof that production
     *      transferred anything: the per-actor book below reconciles the actors' real collateral
     *      balances against independently accumulated deliveries. `preTerminalPool` is captured
     *      before the transition, so this proves conservation rather than restating the model.
     */
    function _assertTerminalPayouts() internal view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            OpenPuntHandler.Pos memory q = handler.get(handler.ids(i));
            if (!q.paidOut) continue;
            assertTrue(q.phase == OpenPuntHandler.Phase.Finalized, "payouts only on terminal positions");
            assertEq(
                q.owedToSwapper + q.owedToMatcher,
                q.preTerminalPool,
                "terminal payouts conserve the pre-terminal margin pool"
            );
        }
        _assertActorCollateralBooks();
    }

    /**
     * @notice The actors' real collateral balances agree with independently accumulated deliveries.
     *
     * @dev The matcher only touches collateral through margins and terminal payouts, so its book
     *      closes on its own. The swapper and reporter share a claimed Dutch reward, which
     *      production splits with `calcFee` — cloning that is explicitly out of scope — so those
     *      two are reconciled jointly. Each actor's measurement includes raw collateral and oracle
     *      credit, covering both the external push-or-credit and internal-return auction routes.
     */
    function _assertActorCollateralBooks() internal view {
        int256 matcherDelta = int256(handler.actorCollat(matcher)) - int256(handler.collatBaseline(matcher));
        assertEq(matcherDelta, handler.modelMatcherCollat(), "matcher collateral matches the modeled deliveries");

        int256 pairDelta = int256(handler.actorCollat(swapper)) + int256(handler.actorCollat(reporter))
            - int256(handler.collatBaseline(swapper)) - int256(handler.collatBaseline(reporter));
        assertEq(
            pairDelta,
            handler.modelSwapperPlusReporterCollat(),
            "swapper plus reporter collateral matches the modeled deliveries"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  8. Execution compensation
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Two ETH books, kept strictly apart.
     *
     *      (a) the core's raw ETH equals every modeled `tempHolding` obligation plus the raw
     *          compensation a proposed or opening position still reserves;
     *      (b) the core's spendable ETH in the oracle ledger equals pending Dutch execution
     *          compensation plus compensation assigned to live reports.
     *
     * @dev Each claimant is modeled separately and the two books are never added together.
     */
    function _assertEthBooks() internal view {
        address[6] memory claimants = [swapper, matcher, reporter, executor, outsider, settler];
        uint256 owedRaw;
        for (uint256 i = 0; i < claimants.length; i++) {
            uint256 modeled = handler.modelTemp(claimants[i]);
            assertEq(punt.tempHolding(claimants[i]), modeled, "tempHolding matches the model for this claimant");
            owedRaw += modeled;
        }
        assertEq(
            address(punt).balance,
            owedRaw + handler.reservedRawEth(),
            "raw core ETH equals modeled tempHolding obligations plus reserved compensation"
        );

        uint256 owedLedger;
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            OpenPuntHandler.Pos memory q = handler.get(handler.ids(i));
            owedLedger += uint256(q.pendingComp) + uint256(q.assignedComp);
        }
        assertEq(
            _spendable(address(punt), address(0)),
            owedLedger,
            "core oracle ETH equals pending plus assigned execution compensation"
        );
    }

    function _assertCompensation() internal view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            OpenPuntHandler.Pos memory q = handler.get(id);
            (uint128 pending, uint48 requestedAt, bool intent) = _closeState(id);

            assertEq(pending, q.pendingComp, "stored auction compensation matches the model");
            assertEq(requestedAt, q.closeRequestBlock, "close-request block matches the model");
            assertEq(intent, q.closeIntent, "close-request presence matches the model");

            if (q.reportId != 0) {
                assertEq(punt.executionGasComp(q.reportId), q.assignedComp, "assigned tranche matches the model");
            }
        }
        _assertEthBooks();
    }

    // ══════════════════════════════════════════════════════════════════
    //  9. Dutch auction
    // ══════════════════════════════════════════════════════════════════

    function _assertDutch() internal view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            OpenPuntHandler.Pos memory q = handler.get(id);
            bytes32 stored = _storedAuctionHash(id, q.matched);

            if (q.dutchStatus == OpenPuntHandler.DutchStatus.Live) {
                assertEq(stored, keccak256(abi.encode(q.dutch)), "a live Dutch hash reconstructs from the event");
                assertEq(stored, q.dutchHash, "and equals the indexed topic the event carried");
                assertEq(q.dutchHeld, q.dutch.maxReward, "its reward is held by the core");
            } else if (q.dutchStatus == OpenPuntHandler.DutchStatus.Consumed) {
                assertEq(stored, bytes32(0), "a consumed auction is deleted");
                assertEq(q.dutchHeld, 0, "and its reward has left the core");
            } else if (q.dutchStatus == OpenPuntHandler.DutchStatus.Cancelled) {
                assertEq(stored, bytes32(0), "a cancelled auction is cleared");
                assertEq(q.dutchHeld, 0, "and its reward has been returned");
            } else {
                assertEq(stored, bytes32(0), "no auction");
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  10. Heartbeat
    // ══════════════════════════════════════════════════════════════════

    /// @dev Model-versus-production disagreements recorded by the handler must be zero. These are
    ///      recorded rather than reverted because a revert inside a handler action is discarded by
    ///      the fuzzer, which would leave the check silently unenforced.
    function _assertNoModelViolations() internal view {
        assertEq(handler.modelViolations(), 0, handler.lastViolation());
    }

    function _assertHeartbeat() internal view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            OpenPuntHandler.Pos memory q = handler.get(id);
            (uint128 hid, uint48 hts) = punt.liquidationHeartbeats(id);

            assertEq(hid, q.hbReportId, "heartbeat report id matches the model");
            assertEq(hts, q.hbTimestamp, "heartbeat timestamp matches the model");

            if (q.matched.liquidationHeartbeatMax == 0 && q.phase != OpenPuntHandler.Phase.Proposed) {
                assertEq(hts, 0, "disabled mode never creates a heartbeat");
            }
            if (hid != 0) {
                assertEq(uint256(hid), q.reportId, "a bound heartbeat names the position's current report");
            }
            if (q.phase == OpenPuntHandler.Phase.Finalized) {
                assertEq(hts, 0, "terminal outcomes delete heartbeat state");
                assertEq(hid, 0, "terminal outcomes delete heartbeat state");
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  11. Close state
    // ══════════════════════════════════════════════════════════════════

    function _assertCloseState() internal view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            OpenPuntHandler.Pos memory q = handler.get(id);
            (,, bool intent) = _closeState(id);

            if (q.phase == OpenPuntHandler.Phase.Finalized) {
                assertFalse(intent, "terminal close or liquidation clears the close request");
            } else {
                assertEq(intent, q.closeIntent, "close request matches the model");
            }
        }
    }

    /// @dev The module never holds funds or position state of its own.
    function _assertModuleClean() internal view {
        assertEq(address(lifecycleModule).balance, 0, "module raw ETH");
        assertEq(_spendable(address(lifecycleModule), address(collat)), 0, "module collateral");
        assertEq(_spendable(address(lifecycleModule), address(0)), 0, "module oracle ETH");
        assertEq(punt.tempHolding(address(lifecycleModule)), 0, "module tempHolding");
    }
}
