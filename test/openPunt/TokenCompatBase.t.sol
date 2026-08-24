// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AssetModeBase.t.sol";
import {NoReturnERC20} from "./util/NoReturnERC20.sol";
import {RejectingSwapper} from "./util/RejectingSwapper.sol";

/**
 * @notice Fixture for supported-token shapes and failed-raw-ETH delivery.
 *
 * @dev These tests cover exactly three supported token shapes:
 *        1. ordinary Boolean-return ERC20s;
 *        2. USDT-style empty-return ERC20s;
 *        3. native ETH, including the documented fallback-credit behaviour.
 *      Fee-on-transfer, rebasing, ERC777/hook tokens, and anything whose balance can move
 *      without a corresponding transfer remain unsupported and are deliberately not
 *      exercised here, so that no passing test can be read as evidence for them.
 */
abstract contract TokenCompatBase is AssetModeBase {
    /// @dev Closing token2 leg 1% above the opening one. With notional 10_000e18 and 1e18 legs
    ///      this is exactly +100e18 of PnL for a long, so the terminal payouts become
    ///      1100e18 / 900e18 rather than a symmetric 1000e18 / 1000e18. Asymmetry is deliberate:
    ///      with equal payouts, swapping the swapper and matcher would be undetectable.
    uint128 internal constant A2_CLOSE_UP = OA2 + 1e16;
    uint128 internal constant EXPECTED_OWED_SWAPPER = 1100e18;
    uint128 internal constant EXPECTED_OWED_MATCHER = 900e18;

    NoReturnERC20 internal nrt; // stands in for collateral or an oracle leg
    RejectingSwapper internal rejector;
    address internal accepting = address(0x8101); // plain EOA that happily receives ETH

    function _setUpTokenCompat() internal {
        _setUpAssets();

        nrt = new NoReturnERC20("NoReturnUSD", "NRUSD");

        rejector = new RejectingSwapper();
        vm.deal(address(rejector), 100_000 ether);
        vm.deal(accepting, 1 ether);
    }

    // ── no-return token funding, all through real token calls ───────────

    function _nrtMint(address to, uint256 amount) internal {
        nrt.mint(to, amount);
    }

    function _nrtApprovePermit2(address who) internal {
        vm.prank(who);
        nrt.approve(PERMIT2, type(uint256).max);
    }

    function _nrtDeposit(address who, uint128 amount) internal {
        nrt.mint(who, amount);
        vm.startPrank(who);
        nrt.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(nrt), amount, who);
        vm.stopPrank();
    }

    function _nrtApproveInternal(address who) internal {
        vm.prank(who);
        oracle.approveInternal(address(punt), address(nrt), type(uint256).max);
    }

    // ── configuration with arbitrary tokens ─────────────────────────────

    /// @dev Flat, fee-free, funding-free position with explicit oracle tokens and collateral.
    function _tokenCfg(address token1_, address token2_, address collatToken, bool internalPos)
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_LONG;
        s.oracleToken1 = token1_;
        s.oracleToken2 = token2_;
        s.collatToken = collatToken;
        s.useInternalBalances = internalPos;
        s.priceTolerated = OPT; // both legs 1e18 -> price 1e30
        s.toleranceRange = 1e6;
        m.initialLiquidity = OA1;
        m.escalationHalt = 100 * OA1;
    }

    // ── rejecting-swapper drivers (the contract is the real caller) ──────

    function _rejectorPropose(
        OpenPuntStorage.ProposedSwap memory s,
        OpenPuntStorage.MatcherPreimage memory m,
        uint256 value
    ) internal returns (Proposal memory p) {
        bytes memory data = abi.encodeCall(openPunt.propose, (s, m, _emptyPermit2()));
        vm.recordLogs();
        bytes memory ret = rejector.exec{value: value}(address(punt), value, data);
        p.swapId = abi.decode(ret, (uint256));
        (p.swap, p.preimage) = _decodeSwapProposed(vm.getRecordedLogs(), p.swapId);
    }

    function _rejectorCall(address target, uint256 value, bytes memory data) internal returns (bytes memory) {
        return rejector.exec{value: value}(target, value, data);
    }

    // ── separated ETH claim accounting ──────────────────────────────────

    /// @dev The three ETH claims a rejecting recipient can end up holding are deliberately kept
    ///      apart: raw balance, OpenOracle internal credit, and OpenPunt tempHolding. They are
    ///      never summed, because a failed delivery must create exactly one of them.
    struct EthClaims {
        uint256 raw;
        uint256 oracleInternal;
        uint256 tempHolding;
    }

    function _ethClaims(address who) internal view returns (EthClaims memory c) {
        c.raw = who.balance;
        c.oracleInternal = _spendable(who, address(0));
        c.tempHolding = punt.tempHolding(who);
    }

    /// @dev Exactly one recoverable claim was created, of the expected kind and size.
    function _assertSingleClaim(
        EthClaims memory before,
        address who,
        uint256 expectedOracleDelta,
        uint256 expectedTempDelta,
        string memory what
    ) internal view {
        EthClaims memory now_ = _ethClaims(who);
        assertEq(now_.raw, before.raw, string.concat(what, ": no raw ETH was delivered"));
        assertEq(
            now_.oracleInternal - before.oracleInternal,
            expectedOracleDelta,
            string.concat(what, ": oracle internal credit")
        );
        assertEq(now_.tempHolding - before.tempHolding, expectedTempDelta, string.concat(what, ": tempHolding claim"));
    }

    /// @dev Nothing may be stranded on the delegatecalled module, ever.
    function _assertModuleHoldsNothing(address t1, address t2, string memory what) internal view {
        assertEq(address(lifecycleModule).balance, 0, string.concat(what, ": module raw ETH"));
        assertEq(_spendable(address(lifecycleModule), address(0)), 0, string.concat(what, ": module internal ETH"));
        assertEq(_spendable(address(lifecycleModule), t1), 0, string.concat(what, ": module token1"));
        assertEq(_spendable(address(lifecycleModule), t2), 0, string.concat(what, ": module token2"));
    }
}
