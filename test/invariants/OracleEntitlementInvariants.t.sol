// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {OracleEntitlementHandler} from "./OracleEntitlementHandler.sol";

/// @notice Per-actor entitlement campaign. The referee is the strongest of the three: for every
///         (actor, token), the withdrawable internal balance must EQUAL the spec-derived
///         entitlement the handler accrues from operation inputs. Locality proves value never
///         reaches a bystander; this proves each participant gets EXACTLY what the protocol spec
///         says — no party over-draws at another participant's expense, even though such a
///         redistribution conserves the global total and passes both conservation and locality.
///
///         NAMED SEAM — reentrancy × exact entitlement is NOT co-tested here. This campaign runs the
///         exact mirror on clean (non-reentrant) paths only; the armed-reentrancy campaign runs the
///         (mirror-free) solvency referee. This split is deliberate, not an oversight: the exact
///         per-actor mirror is intractable to maintain mid-reentry (a reentrant op mutates report
///         state behind the handler's back), AND it is unnecessary for the dispute split, because a
///         dispute applies its credit split and re-pins the state hash BEFORE any external call can
///         fire — there is no external call between the split and the hash commit, so a reentry
///         structurally cannot alter an in-progress split. "Exact split under reentrancy" therefore
///         rests on that CEI argument (and the deterministic landing-dispute witness in
///         OpenOracleArmedReentrancyTest), not on this fuzz campaign.
contract OracleEntitlementInvariantsTest is StdInvariant, Test {
    OpenOracle internal oracle;
    MockERC20 internal vanillaA;
    MockERC20 internal vanillaB;
    OracleEntitlementHandler internal handler;

    address[4] internal actorAddrs = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];

    function setUp() public {
        oracle = new OpenOracle();
        vanillaA = new MockERC20("VanillaA", "VAA");
        vanillaB = new MockERC20("VanillaB", "VAB");
        handler = new OracleEntitlementHandler(oracle, address(vanillaA), address(vanillaB));

        for (uint256 i = 0; i < actorAddrs.length; i++) {
            address a = actorAddrs[i];
            handler.addActor(a);
            vm.deal(a, 100 ether);
            vanillaA.transfer(a, 240_000e18);
            vanillaB.transfer(a, 240_000e18);
            vm.prank(a);
            vanillaA.approve(address(oracle), type(uint256).max);
            vm.prank(a);
            vanillaB.approve(address(oracle), type(uint256).max);
        }
        handler.initTokensAndHolders();

        targetContract(address(handler));
        // No actWarp: dispute/settle advance time via their own auto-warps, so reports stay inside
        // the dispute window instead of expiring under large random time jumps.
        bytes4[] memory sels = new bytes4[](7);
        sels[0] = OracleEntitlementHandler.actReport.selector;
        sels[1] = OracleEntitlementHandler.actDispute.selector;
        sels[2] = OracleEntitlementHandler.actDispute.selector; // bias toward the multi-party path
        sels[3] = OracleEntitlementHandler.actSettle.selector;
        sels[4] = OracleEntitlementHandler.actDeposit.selector;
        sels[5] = OracleEntitlementHandler.actWithdraw.selector;
        sels[6] = OracleEntitlementHandler.actInternalTransfer.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function _withdrawable(address holder, address token) internal view returns (uint256) {
        uint256 bal = oracle.tokenHolder(holder, token);
        return bal == 0 ? 0 : bal - 1;
    }

    /// forge-config: default.invariant.runs = 100
    /// forge-config: default.invariant.depth = 300
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_withdrawableEqualsEntitlement() public view {
        address[3] memory toks = [address(vanillaA), address(vanillaB), address(0)];
        uint256 n = handler.holderCount();
        for (uint256 h = 0; h < n; h++) {
            address holder = handler.holderAt(h);
            for (uint256 t = 0; t < toks.length; t++) {
                assertEq(
                    _withdrawable(holder, toks[t]),
                    handler.entitled(holder, toks[t]),
                    "withdrawable != spec entitlement (mis-attributed value)"
                );
            }
        }
    }

    function afterInvariant() public view {
        // Non-vacuity: the multi-party payout paths must actually have run.
        assertGt(handler.totalDisputes(), 0, "no disputes exercised");
        assertGt(handler.totalSettles(), 0, "no settles exercised");
    }

    /// @notice Deterministic ETH-on-one-side lifecycle: report (token1 = ETH), dispute swapping the
    ///         ETH side, then settle — and the per-actor entitlement equality must hold throughout,
    ///         including the ETH credits (previousReporter ETH payout, currentReporter ETH at
    ///         settle, settler ETH reward). Pins that ETH is mirrored exactly, not just ERC20.
    function test_EthSideLifecycle_EntitlementHolds() public {
        // pairSeed = 2 → token1 = ETH, token2 = vanillaA. Last arg = overpayment seed (1 ETH excess
        // to the reporter), so this also exercises the excess-credit branch under exact equality.
        handler.actReport(0, 2, 1e18, 5000e18, 1 ether);
        invariant_withdrawableEqualsEntitlement();

        // swapT1 = true → swap the ETH side; disputer = actor1, previousReporter = actor0.
        handler.actDispute(1, 0, true, 4000e18, 1 ether);
        assertEq(handler.totalDisputes(), 1, "ETH-side dispute executed");
        invariant_withdrawableEqualsEntitlement();

        handler.actSettle(0);
        assertEq(handler.totalSettles(), 1, "settle executed");
        invariant_withdrawableEqualsEntitlement();

        // ETH actually moved into the internal ledger (previousReporter ETH payout + settler reward).
        assertGt(handler.entitled(address(0xA1), address(0)), 0, "ETH entitlement accrued to previous reporter");
        assertGt(handler.entitled(address(handler), address(0)), 0, "settler ETH reward accrued");
    }

    /// @notice The equality referee must FIRE when withdrawable diverges from the spec entitlement.
    ///         Credit an actor directly (bypassing the handler's mirror) to simulate a
    ///         mis-attribution, then confirm the invariant reverts.
    function test_EntitlementRefereeHasTeeth() public {
        vm.deal(address(this), 1 ether);
        oracle.deposit{value: 1 ether}(address(0), 1 ether, address(0xA1)); // not mirrored into entitled
        vm.expectRevert();
        this.invariant_withdrawableEqualsEntitlement();
    }

    /// @notice The one excess-credit fact the fuzz can't reach: it always pranks reporter == caller,
    ///         so it never separates the relayer (msg.sender) from the designated reporter. On a
    ///         DELEGATED, ETH-side report the relayer pays the overpayment but the excess is credited
    ///         to the designated reporter — never the relayer. Pinned deterministically.
    function test_OverpaymentCreditsDesignatedParty_NotRelayer() public {
        address relayer = address(0xBEEF);
        address designated = address(0xA1); // a registered actor/holder, != relayer
        uint128 a1 = 1e18; // vanillaA leg, funded externally by the relayer
        uint128 a2 = 2e18; // ETH leg (wei)
        uint96 settlerReward = 0.001 ether;
        uint256 extra = 0.5 ether; // the overpayment

        vanillaA.transfer(relayer, 10e18);
        vm.prank(relayer);
        vanillaA.approve(address(oracle), type(uint256).max);
        vm.deal(relayer, 10 ether);

        OpenOracle.OracleGame memory g;
        g.currentAmount1 = a1;
        g.currentAmount2 = a2;
        g.currentReporter = designated;
        g.token1 = address(vanillaA);
        g.token2 = address(0); // ETH side
        g.settlementTime = 300;
        g.escalationHalt = type(uint128).max;
        g.protocolFeeRecipient = address(0);
        g.settlerReward = settlerReward;
        g.disputeDelay = 5;
        g.feePercentage = 0;
        g.multiplier = 110;
        g.protocolFee = 0;
        g.flags = 1; // FLAG_TIME_TYPE

        uint256 relayerEthBefore = oracle.tokenHolder(relayer, address(0));

        vm.prank(relayer);
        oracle.report{value: uint256(settlerReward) + a2 + extra}(
            g, false, false, OpenOracle.TimingBoundaries(0, 0, 0, 0)
        );

        // Excess landed on the designated reporter (seeded sentinel + extra), not the relayer.
        assertEq(oracle.tokenHolder(designated, address(0)), 1 + extra, "excess credited to designated reporter");
        assertEq(oracle.tokenHolder(relayer, address(0)), relayerEthBefore, "relayer received no ETH credit");
    }
}
