// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AssetModeBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Complete lifecycles where the collateral token is one of the oracle legs.
 *
 * @dev OpenPunt forbids the two oracle tokens from being equal, but nothing stops collateral
 *      from equalling one of them. When it does, position margin, oracle-game capital, the
 *      Dutch reward and (for ETH) the execution compensation all share one internal ledger
 *      slot per owner. Success alone proves nothing here — each test reconciles every owner's
 *      shared slot against the sum of its legitimate individual claims, and closes with a
 *      system-wide conservation check.
 */
contract SameTokenCompositionTest is AssetModeBase {
    uint128 internal constant DUTCH_START_R = 10e18;
    uint128 internal constant DUTCH_MAX_R = 100e18;
    uint128 internal constant ROUND_ONE = 15e18; // 10e18 * 15000 / 10000

    function setUp() public {
        _setUpAssets();

        // the shared-slot cases move real size through tokenA / tokenB as collateral
        _mintAndDeposit(tokenA, matcher, 100_000e18);
        _mintAndDeposit(tokenB, matcher, 100_000e18);
        _mintAndDeposit(tokenA, swapper, 100_000e18);
        _mintAndDeposit(tokenB, swapper, 100_000e18);
        tokenA.mint(swapper, 500_000e18); // external balance too, for Permit2-funded routes
        tokenB.mint(swapper, 500_000e18);
        vm.startPrank(swapper);
        tokenA.approve(PERMIT2, type(uint256).max);
        tokenB.approve(PERMIT2, type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Every claim on one owner's shared ledger slot, tracked separately.
    struct Claims {
        uint256 swapper;
        uint256 matcher;
        uint256 reporter;
        uint256 punt;
        uint256 closeExecutor;
    }

    function _claims(address token) internal view returns (Claims memory c) {
        c.swapper = _spendable(swapper, token);
        c.matcher = _spendable(matcher, token);
        c.reporter = _spendable(reporter, token);
        c.punt = _spendable(address(punt), token);
        c.closeExecutor = _spendable(closeExecutor, token);
    }

    function _total(Claims memory c) internal pure returns (uint256) {
        return c.swapper + c.matcher + c.reporter + c.punt + c.closeExecutor;
    }

    /**
     * @dev One full lifecycle with a shared collateral/oracle-leg token:
     *      open -> close auction -> report claiming the Dutch reward -> execute (healthy close).
     *      Reconciles the shared slot for every owner, by purpose.
     */
    function _runSharedToken(Legs legs, address sharedCollat, bool auctionInternal) internal {
        // The position is funded internally so margin in and margin out both stay
        // inside the ledger under reconciliation; external position routing is covered by
        // OpeningRefundModes and TerminalDeliveryAndRaces. The auction route still varies.
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _assetCfg(legs, sharedCollat, true);
        s.maturityWindow = MATURITY_LONG;

        // the shared token must genuinely be one of the oracle legs
        assertTrue(
            sharedCollat == s.oracleToken1 || sharedCollat == s.oracleToken2,
            "fixture: collateral really is an oracle leg"
        );
        assertTrue(s.oracleToken1 != s.oracleToken2, "oracle legs stay distinct");

        Claims memory before = _claims(sharedCollat);
        uint256 systemBefore = _total(before);
        uint256 swapperRawBefore = IERC20(sharedCollat).balanceOf(swapper);

        // ── open ────────────────────────────────────────────────────────
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openAsset(s, m);

        // both margins are now on the core; the matcher's oracle legs went out and came back
        assertEq(
            _spendable(address(punt), sharedCollat) - before.punt,
            uint256(MARGIN_S) + MARGIN_M,
            "core holds exactly both margins in the shared slot, no oracle capital"
        );
        assertEq(
            _spendable(matcher, sharedCollat),
            before.matcher - MARGIN_M,
            "matcher slot fell by its margin only: the opening leg was returned by settlement"
        );

        // ── close auction ───────────────────────────────────────────────
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        input.startingReward = DUTCH_START_R;
        input.maxReward = DUTCH_MAX_R;
        input.expiration = uint48(vm.getBlockTimestamp() + 1 hours);
        OpenPuntStorage.CloseDutch memory d = _startAuction(swapId, active, input, auctionInternal, CLOSE_COMP);

        assertEq(
            _spendable(address(punt), sharedCollat) - before.punt,
            uint256(MARGIN_S) + MARGIN_M + DUTCH_MAX_R,
            "core slot now holds both margins plus the Dutch escrow, and nothing else"
        );

        // ── report claims the reward at round 1 ─────────────────────────
        _advanceTimeAndBlocks(60, 30);
        Matched memory mt = _reportAsset(swapId, d, active, p.preimage, reporter, REPORTER_COMP);

        // At this instant the reporter has also posted the closing oracle leg out of the same
        // slot, and that leg has not settled back yet. Netting it out is exactly the separation
        // this test exists to prove.
        uint128 postedLeg = sharedCollat == s.oracleToken1 ? OA1 : OA2;
        assertEq(
            _spendable(reporter, sharedCollat) + postedLeg,
            before.reporter + ROUND_ONE,
            "reporter earned exactly round 1, net of the oracle leg it has posted but not yet recovered"
        );
        assertEq(
            _spendable(address(punt), sharedCollat) - before.punt,
            uint256(MARGIN_S) + MARGIN_M,
            "the escrow left the core; only the margins remain in the shared slot"
        );

        // ── execute: healthy close at a flat price ──────────────────────
        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);

        assertEq(owedS + owedM, uint256(MARGIN_S) + MARGIN_M, "payouts conserve the margin pool");
        assertEq(owedS, MARGIN_S, "flat price and zero fees: the swapper keeps its margin");
        assertEq(owedM, MARGIN_M, "and the matcher keeps its own");

        // ── reconcile every owner's shared slot by purpose ──────────────
        Claims memory afterC = _claims(sharedCollat);

        // Swapper margin left and returned inside the ledger, so only the auction shows.
        // Internally funded: escrow left the ledger, remainder came back => net -ROUND_ONE.
        // Externally funded: the ledger is unchanged and the raw wallet paid only ROUND_ONE net.
        if (auctionInternal) {
            assertEq(
                afterC.swapper,
                before.swapper - ROUND_ONE,
                "internally funded: swapper's slot lost exactly the reward it paid out"
            );
            assertEq(
                IERC20(sharedCollat).balanceOf(swapper), swapperRawBefore, "internally funded: raw wallet unchanged"
            );
        } else {
            assertEq(afterC.swapper, before.swapper, "externally funded: swapper's ledger slot is unchanged");
            assertEq(
                IERC20(sharedCollat).balanceOf(swapper),
                swapperRawBefore - ROUND_ONE,
                "externally funded: raw wallet paid exactly the claimed reward"
            );
        }

        // matcher: margin out and back, oracle legs out and back => unchanged
        assertEq(afterC.matcher, before.matcher, "matcher's shared slot returns to its starting value");

        // reporter: +reward, and its oracle legs were returned by settlement
        assertEq(afterC.reporter, before.reporter + ROUND_ONE, "reporter's shared slot gained exactly the reward");

        // core: nothing of its own
        assertEq(afterC.punt, before.punt, "core's shared slot returns to its starting value");
        assertEq(afterC.punt, 0, "and that starting value is zero");

        // System-wide conservation across the shared oracle slots and the swapper's raw wallet.
        assertEq(
            _total(afterC) + IERC20(sharedCollat).balanceOf(swapper),
            systemBefore + swapperRawBefore,
            "shared token conserved across raw and internal forms"
        );

        // terminal cleanliness
        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        assertEq(_storedDutchState(swapId), bytes32(0), "auction consumed");
        (uint128 pending,, bool intent) = _closeState(swapId);
        assertEq(pending, 0, "close state cleared");
        assertFalse(intent, "close state cleared");
        assertEq(punt.executionGasComp(mt.reportId), 0, "execution compensation drained");
    }

    // ══════════════════════════════════════════════════════════════════
    //  ERC20 collateral equal to an oracle leg
    // ══════════════════════════════════════════════════════════════════

    function test_collateralEqualsOracleToken1() public {
        _runSharedToken(Legs.BothErc20, address(tokenA), false);
    }

    function test_collateralEqualsOracleToken2() public {
        _runSharedToken(Legs.BothErc20, address(tokenB), false);
    }

    function test_collateralEqualsOracleToken1_internalAuctionFunding() public {
        _runSharedToken(Legs.BothErc20, address(tokenA), true);
    }

    // ══════════════════════════════════════════════════════════════════
    //  ETH collateral equal to the native-ETH oracle leg
    // ══════════════════════════════════════════════════════════════════

    /// @dev The hardest composition: address(0) is simultaneously the collateral, one oracle
    ///      leg, the Dutch reward denomination, the execution compensation and the settler
    ///      reward. The shared slot is reconciled per owner and per purpose, and the ETH-only
    ///      components (compensation and settler reward) are accounted for explicitly rather
    ///      than being allowed to disappear into the margin arithmetic.
    function test_ethCollateralEqualsTheNativeEthOracleLeg() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _assetCfg(Legs.EthIsToken1, address(0), false);
        s.maturityWindow = MATURITY_LONG;
        assertEq(s.collatToken, s.oracleToken1, "collateral IS the native-ETH oracle leg");

        Claims memory before = _claims(address(0));
        uint256 systemBefore = _total(before) + _spendable(executor, address(0));

        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p,) = _openAsset(s, m);

        // the opening settler reward landed with the opening executor, out of the same slot family
        uint256 openExecGain = _spendable(executor, address(0));
        assertEq(openExecGain, SETTLER_REWARD, "opening executor holds exactly the settler reward");

        // core holds both margins and nothing else
        assertEq(
            _spendable(address(punt), address(0)) - before.punt,
            uint256(MARGIN_S) + MARGIN_M,
            "core ETH slot holds exactly both margins"
        );

        // ── auction, funded internally so no raw ETH is involved ────────
        OpenPuntStorage.CloseDutch memory input = _dutchInput();
        input.startingReward = DUTCH_START_R;
        input.maxReward = DUTCH_MAX_R;
        input.expiration = uint48(vm.getBlockTimestamp() + 1 hours);
        OpenPuntStorage.CloseDutch memory d = _startAuction(swapId, active, input, true, CLOSE_COMP);

        assertEq(
            _spendable(address(punt), address(0)) - before.punt,
            uint256(MARGIN_S) + MARGIN_M + DUTCH_MAX_R + CLOSE_COMP,
            "core ETH slot holds margins + Dutch escrow + escrowed compensation, separately accountable"
        );

        _advanceTimeAndBlocks(60, 30);
        Matched memory mt = _reportAsset(swapId, d, active, p.preimage, reporter, REPORTER_COMP);

        // the reporter simultaneously received the reward, posted the ETH oracle leg, and
        // funded the compensation, all through one slot
        assertEq(
            _spendable(reporter, address(0)),
            before.reporter + ROUND_ONE - OA1 - REPORTER_COMP,
            "reporter slot nets reward minus the ETH leg posted minus the compensation funded"
        );

        Vm.Log[] memory logs = _executeReport(swapId, mt, closeExecutor);
        (uint256 owedS, uint256 owedM) = _readPositionClosed(logs, swapId);
        assertEq(owedS + owedM, uint256(MARGIN_S) + MARGIN_M, "payouts conserve the margin pool");

        Claims memory afterC = _claims(address(0));

        // per-owner, per-purpose reconciliation
        assertEq(afterC.swapper, before.swapper - ROUND_ONE - CLOSE_COMP, "swapper paid the reward and the comp");
        assertEq(afterC.matcher, before.matcher, "matcher slot back to its starting value");
        assertEq(afterC.reporter, before.reporter + ROUND_ONE - REPORTER_COMP, "reporter kept the reward, funded comp");
        assertEq(
            afterC.closeExecutor,
            before.closeExecutor + CLOSE_COMP + REPORTER_COMP,
            "closing executor holds exactly the accumulated compensation"
        );
        assertEq(afterC.punt, 0, "core retains no ETH of any purpose");

        // System-wide. Two raw-ETH inflows entered the ledger at propose: the swapper's ETH
        // margin and the oracle settler reward. The margin left again as the swapper's payout
        // (equal at a flat price with zero fees), so the ledger set nets exactly the settler
        // reward — which is now sitting with the opening executor.
        assertEq(
            _total(afterC) + _spendable(executor, address(0)),
            systemBefore + SETTLER_REWARD,
            "ETH conserved, net of the settler reward injected at propose"
        );

        assertEq(punt.swaps(swapId), bytes32(0), "position terminal");
        assertEq(punt.executionGasComp(mt.reportId), 0, "compensation drained");
    }
}
