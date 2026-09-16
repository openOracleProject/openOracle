// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase, IV2Factory} from "./DisputeHelperBase.t.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";

/**
 * @notice `tryInternalBalances`: sourcing each declared funding budget from the caller's OpenOracle
 *         internal balance before touching their wallet.
 *
 * @dev THE MECHANISM. For each declared budget — `suppliedAmount1`, `suppliedAmount2`, and
 *      `maxSwapInput` when the route input is a third asset — the helper takes
 *      `min(declared, spendable, allowance)` from the caller's internal balance via one
 *      `internalTransferFrom`, withdraws it to itself, and pulls only the remainder externally.
 *      `spendable` excludes the oracle's 1-unit sentinel.
 *
 *      WHY THE FINAL DISPUTE STILL PASSES `false, false`. NOT because the oracle would read the
 *      wrong account: `_tryInternalBalanceFull(disputer, ...)` does draw on the DISPUTER's ledger
 *      and honours `internalAllowance[disputer][helper]`. The reason is that delegated internal
 *      funding is STRICT -- when the caller is not the owner, the oracle reverts with
 *      `InsufficientInternalBalance` unless the disputer's balance and allowance cover the ENTIRE
 *      contribution:
 *
 *          if (tib && owner != msg.sender && fromInternal < amount) revert InsufficientInternalBalance();
 *
 *      By the time the helper disputes it is holding a MIXTURE -- part drawn internally, part pulled
 *      from the wallet, part produced by the router -- all already sitting in its own external
 *      balance. The strict path cannot combine a ledger balance with assets the helper already
 *      holds, so it would reject every partially-internal call. Sourcing everything up front and
 *      then disputing externally is what makes partial internal funding possible at all.
 *
 *      WHAT MSG.VALUE MEANS NOW. Only the EXTERNAL ETH remainder. Any ETH sourced internally
 *      arrives by withdrawal, not by call value, so the two must not be double counted.
 *
 *      EVERY INTERNAL BALANCE HERE IS REAL. Balances come from `deposit()` and allowances from
 *      `approveInternal()`; no storage is written and no ledger is mocked. The oracle credits
 *      `amount + 1` on a first deposit, so a deposit of X leaves exactly X spendable.
 *
 *      SHARED DERIVATION. token1 = tokenA, token2 = tokenB, oldAmount1 = 1e18, oldAmount2 = 1000e18,
 *      newAmount1 = 1.1e18, newAmount2 = 900e18. requiredToken1 = 1.1e18 + 1e18 + 3e14 + 1e14
 *      = 2.1004e18, requiredToken2 = 0.
 */
contract InternalBalanceFundingTest is DisputeHelperBase {
    uint128 internal constant NEW_AMOUNT_1 = 1.1e18;
    uint256 internal constant REQUIRED_1 = 2.1004e18;
    uint256 internal constant REQUIRED_2_AT_1050 = 50e18; // 1050e18 - 1000e18

    // ────────────────────────────────────────────────────────────────────
    //  the flag is opt-in
    // ────────────────────────────────────────────────────────────────────

    /// @dev With the flag false, a fully funded internal balance is ignored entirely and the whole
    ///      requirement is pulled from the wallet. This is the guarantee that adding the option
    ///      changed nothing for existing callers.
    function test_flagFalseIgnoresAFullyFundedInternalBalance() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenA), REQUIRED_1);
        _approveInternal(disputer, address(tokenA), type(uint256).max);

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 i0 = oracle.tokenHolder(disputer, address(tokenA));

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), REQUIRED_1, "the wallet should have paid in full");
        assertEq(oracle.tokenHolder(disputer, address(tokenA)), i0, "the internal balance must be untouched");
    }

    // ────────────────────────────────────────────────────────────────────
    //  token1 and token2, full and partial
    // ────────────────────────────────────────────────────────────────────

    function test_token1FundedEntirelyFromTheInternalBalance() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenA), REQUIRED_1);
        _approveInternal(disputer, address(tokenA), type(uint256).max);

        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, true, address(tokenA), 0, c, i, 0);

        assertEq(tokenA.balanceOf(disputer), a0, "no external token1 should have been pulled");
        assertEq(oracle.tokenHolder(disputer, address(tokenA)), 1, "the sentinel and nothing more should remain");
        _assertNothingStranded(address(tokenA), address(tokenB));
    }

    /// @dev Spendable is 1e18 against a 2.1004e18 requirement, so 1.1004e18 must come externally.
    function test_token1PartiallyFundedFromTheInternalBalance() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenA), 1e18);
        _approveInternal(disputer, address(tokenA), type(uint256).max);

        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, true, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), REQUIRED_1 - 1e18, "only the remainder should come from the wallet");
        assertEq(
            oracle.tokenHolder(disputer, address(tokenA)), 1, "the internal balance should be drained to the sentinel"
        );
        _assertNothingStranded(address(tokenA), address(tokenB));
    }

    /// @dev newAmount2 = 1050e18 makes requiredToken2 = 50e18, so both legs draw internally.
    function test_bothLegsFundedFromInternalBalances() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenA), REQUIRED_1);
        _depositInternal(disputer, address(tokenB), REQUIRED_2_AT_1050);
        _approveInternal(disputer, address(tokenA), type(uint256).max);
        _approveInternal(disputer, address(tokenB), type(uint256).max);

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 b0 = tokenB.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 1050e18, REQUIRED_1, REQUIRED_2_AT_1050, true, address(tokenA), 0, c, i, 0);

        assertEq(tokenA.balanceOf(disputer), a0, "token1 should have cost the wallet nothing");
        assertEq(tokenB.balanceOf(disputer), b0, "token2 should have cost the wallet nothing");
        assertEq(oracle.tokenHolder(disputer, address(tokenA)), 1, "token1 sentinel");
        assertEq(oracle.tokenHolder(disputer, address(tokenB)), 1, "token2 sentinel");
        _assertNothingStranded(address(tokenA), address(tokenB));
    }

    /// @dev token2 partially internal on the swapToken2 branch, where token2 carries the fees.
    ///      requiredToken2 = 1200e18 + 1000e18 + 3e17 + 1e17 = 2200.4e18, requiredToken1 = 1e17.
    function test_token2PartiallyFundedOnTheSwapToken2Branch() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenB), 200e18);
        _approveInternal(disputer, address(tokenB), type(uint256).max);

        uint256 b0 = tokenB.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 1200e18, 1e17, 2200.4e18, true, address(tokenA), 0, c, i, 0);

        assertEq(b0 - tokenB.balanceOf(disputer), 2200.4e18 - 200e18, "wallet pays only the remainder");
        assertEq(oracle.tokenHolder(disputer, address(tokenB)), 1, "token2 internal drained to the sentinel");
    }

    // ────────────────────────────────────────────────────────────────────
    //  allowance and balance are independent ceilings
    // ────────────────────────────────────────────────────────────────────

    /// @dev Allowance below balance: the allowance is what binds.
    function test_allowanceSmallerThanBalanceCapsTheInternalDraw() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenA), 5e18);
        _approveInternal(disputer, address(tokenA), 0.5e18);

        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, true, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), REQUIRED_1 - 0.5e18, "only the allowance may be drawn internally");
        assertEq(_spendable(disputer, address(tokenA)), 5e18 - 0.5e18, "the rest of the balance must remain");
        assertEq(
            oracle.internalAllowance(disputer, address(helper), address(tokenA)), 0, "the allowance should be consumed"
        );
    }

    /// @dev Balance below allowance: the balance is what binds, and the allowance is only
    ///      decremented by what was actually taken.
    function test_balanceSmallerThanAllowanceCapsTheInternalDraw() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenA), 0.5e18);
        _approveInternal(disputer, address(tokenA), 5e18);

        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, true, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), REQUIRED_1 - 0.5e18, "only the balance may be drawn internally");
        assertEq(oracle.tokenHolder(disputer, address(tokenA)), 1, "drained to the sentinel");
        assertEq(
            oracle.internalAllowance(disputer, address(helper), address(tokenA)),
            5e18 - 0.5e18,
            "the allowance should fall by exactly what was taken"
        );
    }

    /// @dev No allowance at all means no internal draw, even with a large balance. The flag is not
    ///      a licence to spend an unapproved internal balance.
    function test_withoutAnAllowanceNothingIsDrawnInternally() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenA), 100e18);

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 i0 = oracle.tokenHolder(disputer, address(tokenA));

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, true, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), REQUIRED_1, "the wallet must pay in full");
        assertEq(oracle.tokenHolder(disputer, address(tokenA)), i0, "the internal balance must be untouched");
    }

    /// @dev A balance of exactly the sentinel is not spendable.
    function test_theSentinelAloneIsNotSpendable() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenA), 0);
        _approveInternal(disputer, address(tokenA), type(uint256).max);
        assertEq(oracle.tokenHolder(disputer, address(tokenA)), 1, "precondition: sentinel only");

        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, true, address(tokenA), 0, c, i, 0);

        assertEq(a0 - tokenA.balanceOf(disputer), REQUIRED_1, "the wallet must pay in full");
        assertEq(oracle.tokenHolder(disputer, address(tokenA)), 1, "the sentinel must survive");
    }

    // ────────────────────────────────────────────────────────────────────
    //  a distinct ERC20 route input
    // ────────────────────────────────────────────────────────────────────

    /// @dev token1 is NOT supplied, so the whole requirement has to come out of the pool. The
    ///      entire route budget is internal, which means the swap is paid for with tokens that only
    ///      existed in the oracle's ledger when the call began.
    ///
    ///      The pool-reserve assertions are what make this test about ROUTING. An earlier version
    ///      supplied token1 outright, so `shortfall1` was zero, `_executeRoute` was never reached
    ///      and the router calldata was inert -- it silently proved only that internal tokenC could
    ///      be withdrawn and refunded. Deleting the route now moves no reserves and fails here.
    function test_thirdErc20RouteInputFundedEntirelyInternally() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5e18;
        _depositInternal(disputer, address(tokenC), maxIn);
        _approveInternal(disputer, address(tokenC), type(uint256).max);

        (bytes memory sc, bytes[] memory si) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);
        (bytes memory c, bytes[] memory i) = _withSweep(sc, si, address(tokenC));

        address pair = IV2Factory(v2Factory).getPair(address(tokenC), address(tokenA));
        uint256 pairC0 = tokenC.balanceOf(pair);
        uint256 pairA0 = tokenA.balanceOf(pair);
        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 c0 = tokenC.balanceOf(disputer);

        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, 0, 0, true, address(tokenC), maxIn, c, i, 0);

        assertGt(tokenC.balanceOf(pair), pairC0, "the pool never received the route input");
        assertLt(tokenA.balanceOf(pair), pairA0, "the pool never paid out token1");
        assertEq(tokenA.balanceOf(disputer), a0, "token1 must have come from the route, not the wallet");
        assertEq(oracle.tokenHolder(disputer, address(tokenC)), 1, "route input drained to the sentinel");
        // The unspent part of an INTERNAL budget comes back externally, not as a re-deposit.
        assertGt(tokenC.balanceOf(disputer), c0, "the swept remainder should be refunded to the wallet");
        _assertNothingStranded(address(tokenA), address(tokenB));
        assertEq(tokenC.balanceOf(address(helper)), 0, "route input stranded in the helper");
    }

    /// @dev Half the route budget internal, half external.
    function test_thirdErc20RouteInputFundedPartiallyInternally() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5e18;
        _depositInternal(disputer, address(tokenC), 2e18);
        _approveInternal(disputer, address(tokenC), type(uint256).max);

        (bytes memory sc, bytes[] memory si) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, maxIn);
        (bytes memory c, bytes[] memory i) = _withSweep(sc, si, address(tokenC));

        uint256 c0 = tokenC.balanceOf(disputer);

        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, 0, 0, true, address(tokenC), maxIn, c, i, 0);

        // 3e18 pulled externally, and whatever the route did not spend comes back.
        uint256 netExternal = c0 - tokenC.balanceOf(disputer);
        assertLt(netExternal, 3e18, "the unused input should have been refunded on top");
        assertEq(oracle.tokenHolder(disputer, address(tokenC)), 1, "internal route budget drained to the sentinel");
        _assertNothingStranded(address(tokenA), address(tokenB));
    }

    // ────────────────────────────────────────────────────────────────────
    //  the route input IS an oracle token, and its surplus is internal
    // ────────────────────────────────────────────────────────────────────

    /// @dev `separateRouteInput == false`, so the routing budget is NOT a separate pull: it has to
    ///      come out of the supplied surplus for that same token. This composition is what the
    ///      direct-leg tests above never reach — `_sourceDeclaredAmount` fills ONE budget covering
    ///      both the requirement and the surplus, and `_executeRoute` then caps the swap at
    ///      `suppliedAmount1 - requiredToken1`.
    ///
    ///      newAmount2 = 1050e18 makes requiredToken1 = 2.1004e18 and requiredToken2 = 50e18. The
    ///      caller supplies token1 only, entirely from the internal ledger, and the token2 leg is
    ///      bought with the surplus.
    function test_token1SurplusRoutedToToken2IsFundedInternally() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 surplus = 60e18;
        uint256 supplied1 = REQUIRED_1 + surplus;

        _depositInternal(disputer, address(tokenA), supplied1);
        _approveInternal(disputer, address(tokenA), type(uint256).max);

        (bytes memory sc, bytes[] memory si) =
            _v2ExactOut(address(tokenA), address(tokenB), REQUIRED_2_AT_1050, surplus);
        (bytes memory c, bytes[] memory i) = _withSweep(sc, si, address(tokenA));

        address pair = IV2Factory(v2Factory).getPair(address(tokenA), address(tokenB));
        uint256 pairA0 = tokenA.balanceOf(pair);
        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 b0 = tokenB.balanceOf(disputer);

        _callDisputeWith(ctx, NEW_AMOUNT_1, 1050e18, supplied1, 0, true, address(tokenA), surplus, c, i, 0);

        assertGt(tokenA.balanceOf(pair), pairA0, "the pool never received the routed surplus");
        assertEq(tokenB.balanceOf(disputer), b0, "the token2 leg must have come from the route");
        assertEq(oracle.tokenHolder(disputer, address(tokenA)), 1, "the whole budget was internal");
        // The unspent surplus is swept back and refunded externally.
        assertGt(tokenA.balanceOf(disputer), a0, "the unspent surplus should return to the wallet");
        _assertNothingStranded(address(tokenA), address(tokenB));
    }

    /// @dev The same shape with only PART of the budget internal: the requirement and the surplus
    ///      are filled from one mixed pull, so a mis-split shows up as a wrong wallet debit.
    ///      Internal 40e18, so the wallet must provide supplied1 - 40e18 before any refund.
    function test_token1SurplusRoutedToToken2IsFundedPartiallyInternally() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 surplus = 60e18;
        uint256 supplied1 = REQUIRED_1 + surplus;

        _depositInternal(disputer, address(tokenA), 40e18);
        _approveInternal(disputer, address(tokenA), type(uint256).max);

        (bytes memory sc, bytes[] memory si) =
            _v2ExactOut(address(tokenA), address(tokenB), REQUIRED_2_AT_1050, surplus);
        (bytes memory c, bytes[] memory i) = _withSweep(sc, si, address(tokenA));

        uint256 a0 = tokenA.balanceOf(disputer);
        uint256 b0 = tokenB.balanceOf(disputer);

        _callDisputeWith(ctx, NEW_AMOUNT_1, 1050e18, supplied1, 0, true, address(tokenA), surplus, c, i, 0);

        // The 40e18 internal draw already covers the whole 2.1004e18 requirement, so the wallet's
        // pull of supplied1 - 40e18 = 22.1004e18 funds the rest of the routing surplus. Part of that
        // comes back as the swept remainder, leaving a net debit strictly between the two.
        uint256 netA = a0 - tokenA.balanceOf(disputer);
        assertLt(netA, supplied1 - 40e18, "the unspent surplus should have come back on top");
        assertGt(netA, 0, "the wallet must still have funded part of the surplus");
        assertEq(tokenB.balanceOf(disputer), b0, "the token2 leg must have come from the route");
        assertEq(oracle.tokenHolder(disputer, address(tokenA)), 1, "internal balance drained to the sentinel");
        _assertNothingStranded(address(tokenA), address(tokenB));
    }

    /// @dev The mirror image on the swapToken2 branch: token2 is the supplied side and its surplus
    ///      buys the short token1 leg. requiredToken2 = 2200.4e18, requiredToken1 = 1e17.
    function test_token2SurplusRoutedToToken1IsFundedInternally() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 surplus = 200e18;
        uint256 supplied2 = 2200.4e18 + surplus;

        tokenB.mint(disputer, supplied2);
        _depositInternal(disputer, address(tokenB), supplied2);
        _approveInternal(disputer, address(tokenB), type(uint256).max);

        (bytes memory sc, bytes[] memory si) = _v2ExactOut(address(tokenB), address(tokenA), 1e17, surplus);
        (bytes memory c, bytes[] memory i) = _withSweep(sc, si, address(tokenB));

        address pair = IV2Factory(v2Factory).getPair(address(tokenA), address(tokenB));
        uint256 pairB0 = tokenB.balanceOf(pair);
        uint256 a0 = tokenA.balanceOf(disputer);

        _callDisputeWith(ctx, NEW_AMOUNT_1, 1200e18, 0, supplied2, true, address(tokenB), surplus, c, i, 0);

        assertGt(tokenB.balanceOf(pair), pairB0, "the pool never received the routed surplus");
        assertEq(tokenA.balanceOf(disputer), a0, "the token1 leg must have come from the route");
        assertEq(oracle.tokenHolder(disputer, address(tokenB)), 1, "the whole budget was internal");
        _assertNothingStranded(address(tokenA), address(tokenB));
    }

    /// @dev The surplus cap still binds when the budget was sourced internally: asking to route
    ///      more than `suppliedAmount1 - requiredToken1` is rejected, and the internal ledger is
    ///      restored.
    function test_routingMoreThanAnInternallySourcedSurplusIsRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 surplus = 60e18;
        uint256 supplied1 = REQUIRED_1 + surplus;

        _depositInternal(disputer, address(tokenA), supplied1);
        _approveInternal(disputer, address(tokenA), type(uint256).max);

        Ledger memory before = _ledger(ctx);

        (bytes memory c, bytes[] memory i) =
            _v2ExactOut(address(tokenA), address(tokenB), REQUIRED_2_AT_1050, surplus + 1);

        vm.expectRevert(OracleDisputeHelper.InvalidMaximumSwapInput.selector);
        _callDisputeWith(ctx, NEW_AMOUNT_1, 1050e18, supplied1, 0, true, address(tokenA), surplus + 1, c, i, 0);

        _assertLedgerRestored(ctx, before);
    }

    // ────────────────────────────────────────────────────────────────────
    //  a distinct ETH route input
    // ────────────────────────────────────────────────────────────────────

    /// @dev Fully internal ETH route budget: msg.value must be ZERO, because the ETH arrives by
    ///      withdrawal rather than with the call.
    function test_thirdAssetEthRouteInputFundedEntirelyInternallyTakesNoMsgValue() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5 ether;
        _depositInternal(disputer, ETH, maxIn);
        _approveInternal(disputer, ETH, type(uint256).max);

        (bytes memory c, bytes[] memory i) = _ethRoute(address(tokenA), REQUIRED_1, maxIn);

        uint256 e0 = disputer.balance;
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, 0, 0, true, ETH, maxIn, c, i, 0);

        assertGt(disputer.balance, e0, "the unspent ETH remainder should be refunded externally");
        assertEq(oracle.tokenHolder(disputer, ETH), 1, "internal ETH drained to the sentinel");
        _assertNothingStranded(address(tokenA), address(tokenB));
    }

    /// @dev Half internal, so msg.value must be exactly the other half.
    function test_thirdAssetEthRouteInputFundedPartiallyInternally() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5 ether;
        _depositInternal(disputer, ETH, 2 ether);
        _approveInternal(disputer, ETH, type(uint256).max);

        (bytes memory c, bytes[] memory i) = _ethRoute(address(tokenA), REQUIRED_1, maxIn);

        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, 0, 0, true, ETH, maxIn, c, i, 3 ether);

        assertEq(oracle.tokenHolder(disputer, ETH), 1, "internal ETH drained to the sentinel");
        _assertNothingStranded(address(tokenA), address(tokenB));
    }

    function test_thirdAssetEthRefundsOneWeiOverTheExternalRemainder() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5 ether;
        _depositInternal(disputer, ETH, 2 ether);
        _approveInternal(disputer, ETH, type(uint256).max);

        (bytes memory c, bytes[] memory i) = _ethRoute(address(tokenA), REQUIRED_1, maxIn);

        uint256 e0 = disputer.balance;
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, 0, 0, true, ETH, maxIn, c, i, 3 ether + 1);

        assertGt(disputer.balance, e0 - (3 ether + 1), "excess msg.value was not refunded");
    }

    function test_thirdAssetEthRejectsOneWeiUnderTheExternalRemainder() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 maxIn = 5 ether;
        _depositInternal(disputer, ETH, 2 ether);
        _approveInternal(disputer, ETH, type(uint256).max);

        (bytes memory c, bytes[] memory i) = _ethRoute(address(tokenA), REQUIRED_1, maxIn);

        vm.expectRevert(OracleDisputeHelper.InvalidMsgValue.selector);
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, 0, 0, true, ETH, maxIn, c, i, 3 ether - 1);
    }

    // ────────────────────────────────────────────────────────────────────
    //  ETH as an ORACLE token
    // ────────────────────────────────────────────────────────────────────

    /// @dev token2 == ETH, requirement 0.5 ether, funded entirely internally: msg.value must be 0.
    function test_ethOracleLegFundedEntirelyInternallyTakesNoMsgValue() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);
        _depositInternal(disputer, ETH, 0.5 ether);
        _approveInternal(disputer, ETH, type(uint256).max);

        uint256 e0 = disputer.balance;

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 0.5 ether, true, address(tokenA), 0, c, i, 0);

        assertEq(disputer.balance, e0, "no external ETH should have moved");
        assertEq(oracle.tokenHolder(disputer, ETH), 1, "internal ETH drained to the sentinel");
        _assertNothingStranded(address(tokenA), ETH);
    }

    /// @dev Partially internal ETH oracle leg: msg.value is the remainder only.
    function test_ethOracleLegFundedPartiallyInternally() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);
        _depositInternal(disputer, ETH, 0.2 ether);
        _approveInternal(disputer, ETH, type(uint256).max);

        uint256 e0 = disputer.balance;

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(
            ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 0.5 ether, true, address(tokenA), 0, c, i, 0.3 ether
        );

        assertEq(e0 - disputer.balance, 0.3 ether, "only the external remainder should leave the wallet");
        assertEq(oracle.tokenHolder(disputer, ETH), 1, "internal ETH drained to the sentinel");
        _assertNothingStranded(address(tokenA), ETH);
    }

    function test_ethOracleLegRefundsTheOldFullValueExcess() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);
        _depositInternal(disputer, ETH, 0.5 ether);
        _approveInternal(disputer, ETH, type(uint256).max);

        (bytes memory c, bytes[] memory i) = _noRoute();
        uint256 e0 = disputer.balance;
        _callDisputeWith(
            ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 0.5 ether, true, address(tokenA), 0, c, i, 0.5 ether
        );

        assertEq(disputer.balance, e0, "tracked excess ETH was not refunded");
    }

    // ────────────────────────────────────────────────────────────────────
    //  the uint128 ceiling on a single internal transfer
    // ────────────────────────────────────────────────────────────────────

    /// @dev `internalTransferFrom` takes a uint128, so an internal draw above that is rejected
    ///      rather than silently truncated. Reaching it needs a balance above uint128.max, which
    ///      takes two deposits because `deposit` itself takes a uint128.
    function test_anInternalDrawAboveUint128MaxIsRejected() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 huge = uint256(type(uint128).max);
        tokenA.mint(disputer, 2 * huge);
        _depositInternal(disputer, address(tokenA), huge);
        _depositInternal(disputer, address(tokenA), huge);
        _approveInternal(disputer, address(tokenA), type(uint256).max);

        assertGt(_spendable(disputer, address(tokenA)), huge, "precondition: spendable must exceed uint128.max");

        (bytes memory c, bytes[] memory i) = _noRoute();
        vm.expectRevert(OracleDisputeHelper.InvalidMaximumSwapInput.selector);
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, 2 * huge, 0, true, address(tokenA), 0, c, i, 0);
    }

    /// @dev Exactly uint128.max is still allowed — the boundary is inclusive.
    function test_anInternalDrawOfExactlyUint128MaxIsAllowed() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        uint256 huge = uint256(type(uint128).max);
        tokenA.mint(disputer, 2 * huge);
        _depositInternal(disputer, address(tokenA), huge);
        _depositInternal(disputer, address(tokenA), huge);
        _approveInternal(disputer, address(tokenA), type(uint256).max);

        uint256 a0 = tokenA.balanceOf(disputer);

        (bytes memory c, bytes[] memory i) = _noRoute();
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, huge, 0, true, address(tokenA), 0, c, i, 0);

        assertEq(tokenA.balanceOf(disputer), a0 + huge - REQUIRED_1, "the oversupply beyond the requirement returns");
    }

    function test_internalWithdrawalMustReturnTheExactRequestedAmount() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenA), REQUIRED_1);
        _approveInternal(disputer, address(tokenA), type(uint256).max);

        Ledger memory before = _ledger(ctx);
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IOpenOracle2.withdrawTo, (address(tokenA), REQUIRED_1, address(helper))),
            abi.encode(REQUIRED_1 - 1)
        );

        (bytes memory c, bytes[] memory i) = _noRoute();
        vm.expectRevert(OracleDisputeHelper.InternalWithdrawalShortfall.selector);
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, true, address(tokenA), 0, c, i, 0);

        vm.clearMockedCalls();
        _assertLedgerRestored(ctx, before);
    }

    // ────────────────────────────────────────────────────────────────────
    //  atomicity — a failure restores the internal ledger too
    // ────────────────────────────────────────────────────────────────────

    struct Ledger {
        uint256 internalA;
        uint256 internalC;
        uint256 internalEth;
        uint256 allowanceA;
        uint256 allowanceB;
        uint256 allowanceC;
        uint256 allowanceEth;
        uint256 walletA;
        uint256 walletC;
        uint256 walletEth;
        uint256 helperA;
        uint256 helperC;
        uint256 helperEth;
        bytes32 stateHash;
    }

    function _ledger(Game memory ctx) internal view returns (Ledger memory l) {
        l.internalA = oracle.tokenHolder(disputer, address(tokenA));
        l.internalC = oracle.tokenHolder(disputer, address(tokenC));
        l.internalEth = oracle.tokenHolder(disputer, ETH);
        l.allowanceA = oracle.internalAllowance(disputer, address(helper), address(tokenA));
        l.allowanceB = oracle.internalAllowance(disputer, address(helper), address(tokenB));
        l.allowanceC = oracle.internalAllowance(disputer, address(helper), address(tokenC));
        l.allowanceEth = oracle.internalAllowance(disputer, address(helper), ETH);
        l.walletA = tokenA.balanceOf(disputer);
        l.walletC = tokenC.balanceOf(disputer);
        l.walletEth = disputer.balance;
        l.helperA = tokenA.balanceOf(address(helper));
        l.helperC = tokenC.balanceOf(address(helper));
        l.helperEth = address(helper).balance;
        l.stateHash = oracle.oracleGame(ctx.reportId);
    }

    function _assertLedgerRestored(Game memory ctx, Ledger memory before) internal view {
        Ledger memory now_ = _ledger(ctx);
        assertEq(now_.internalA, before.internalA, "internal token1 balance moved");
        assertEq(now_.internalC, before.internalC, "internal route-token balance moved");
        assertEq(now_.internalEth, before.internalEth, "internal ETH balance moved");
        assertEq(now_.allowanceA, before.allowanceA, "internal token1 allowance moved");
        assertEq(now_.allowanceB, before.allowanceB, "internal token2 allowance moved");
        assertEq(now_.allowanceC, before.allowanceC, "internal route-token allowance moved");
        assertEq(now_.allowanceEth, before.allowanceEth, "internal ETH allowance moved");
        assertEq(now_.walletA, before.walletA, "external token1 balance moved");
        assertEq(now_.walletC, before.walletC, "external route-token balance moved");
        assertEq(now_.walletEth, before.walletEth, "external ETH balance moved");
        assertEq(now_.helperA, before.helperA, "helper token1 balance moved");
        assertEq(now_.helperC, before.helperC, "helper route-token balance moved");
        assertEq(now_.helperEth, before.helperEth, "helper ETH balance moved");
        assertEq(now_.stateHash, before.stateHash, "oracle state moved");
    }

    /// @dev The selected router consumes the input but produces the wrong asset. The final funding
    ///      assertion must unwind the route and the internal draw together.
    function test_anUnproductiveRouteRestoresTheInternalLedger() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenC), 5e18);
        _approveInternal(disputer, address(tokenC), type(uint256).max);

        Ledger memory before = _ledger(ctx);

        bytes[] memory junk = new bytes[](1);
        junk[0] = abi.encode(address(tokenC), address(helper), uint256(0));

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDisputeWith(
            ctx, NEW_AMOUNT_1, 900e18, 0, 0, true, address(tokenC), 5e18, abi.encodePacked(CMD_TRANSFER), junk, 0
        );

        _assertLedgerRestored(ctx, before);
    }

    /// @dev The route runs but delivers too little.
    function test_underDeliveryRestoresTheInternalLedger() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        _depositInternal(disputer, address(tokenC), 1e18);
        _approveInternal(disputer, address(tokenC), type(uint256).max);

        Ledger memory before = _ledger(ctx);

        (bytes memory c, bytes[] memory i) = _v2ExactIn(address(tokenC), address(tokenA), 1e18, 1);

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, 0, 0, true, address(tokenC), 1e18, c, i, 0);

        _assertLedgerRestored(ctx, before);
    }

    /// @dev A stale preimage is rejected before any internal draw or route interaction.
    function test_aStalePreimageRestoresTheInternalLedger() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));

        // Move the game on so the local preimage is stale.
        (bytes memory nc, bytes[] memory ni) = _noRoute();
        _callDispute(ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, address(tokenA), 0, nc, ni, 0);

        _depositInternal(disputer, address(tokenC), 5e18);
        _approveInternal(disputer, address(tokenC), type(uint256).max);

        Ledger memory before = _ledger(ctx);

        (bytes memory sc, bytes[] memory si) = _v2ExactOut(address(tokenC), address(tokenA), REQUIRED_1, 5e18);
        (bytes memory c, bytes[] memory i) = _withSweep(sc, si, address(tokenC));

        vm.expectRevert(OracleDisputeHelper.WrongHash.selector);
        _callDisputeWith(ctx, NEW_AMOUNT_1, 900e18, 0, 0, true, address(tokenC), 5e18, c, i, 0);

        _assertLedgerRestored(ctx, before);
    }

    /// @dev An insufficient msg.value fails after the internal draw has already happened, which is
    ///      the ordering that makes this rollback worth pinning explicitly.
    function test_anIncorrectMsgValueRestoresTheInternalLedger() public {
        Game memory ctx = _newGame(address(tokenA), ETH, MULTIPLIER, OLD_AMOUNT_1, 10 ether);
        _depositInternal(disputer, ETH, 0.2 ether);
        _approveInternal(disputer, ETH, type(uint256).max);

        Ledger memory before = _ledger(ctx);

        (bytes memory c, bytes[] memory i) = _noRoute();
        vm.expectRevert(OracleDisputeHelper.InvalidMsgValue.selector);
        _callDisputeWith(
            ctx, NEW_AMOUNT_1, 10.5 ether, REQUIRED_1, 0.5 ether, true, address(tokenA), 0, c, i, 0.3 ether - 1
        );

        _assertLedgerRestored(ctx, before);
    }

    // ────────────────────────────────────────────────────────────────────
    //  helpers
    // ────────────────────────────────────────────────────────────────────

    /// @dev The helper must end holding nothing externally, and nothing internally beyond the
    ///      1-unit sentinel that an internal withdrawal necessarily leaves behind.
    function _assertNothingStranded(address a, address b) internal view {
        _assertHelperHoldsNothing(_tokens(a, b));
        assertLe(oracle.tokenHolder(address(helper), a), 1, "helper retained an internal balance");
        assertLe(oracle.tokenHolder(address(helper), b), 1, "helper retained an internal balance");
        assertLe(oracle.tokenHolder(address(helper), address(tokenC)), 1, "helper retained an internal balance");
        assertLe(oracle.tokenHolder(address(helper), ETH), 1, "helper retained an internal ETH balance");
    }

    function _withSweep(bytes memory commands, bytes[] memory inputs, address token)
        internal
        view
        returns (bytes memory, bytes[] memory)
    {
        bytes[] memory sweepInput = new bytes[](1);
        sweepInput[0] = _sweep(token, address(helper), 0);
        return _join(commands, inputs, abi.encodePacked(CMD_SWEEP), sweepInput);
    }

    /// @dev WRAP_ETH -> V3 exact-out WETH->tokenOut -> UNWRAP_WETH back to the helper.
    function _ethRoute(address tokenOut, uint256 amountOut, uint256 maxIn)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes memory path = abi.encodePacked(tokenOut, V3_FEE, address(weth));

        commands = abi.encodePacked(CMD_WRAP_ETH, CMD_V3_SWAP_EXACT_OUT, CMD_UNWRAP_WETH);
        inputs = new bytes[](3);
        inputs[0] = abi.encode(router, maxIn);
        inputs[1] = abi.encode(address(helper), amountOut, maxIn, path, false, _noHopPrices());
        inputs[2] = abi.encode(address(helper), uint256(0));
    }
}
