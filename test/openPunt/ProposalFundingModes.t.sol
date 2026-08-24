// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./OpenPuntBase.t.sol";

/**
 * @notice The four proposal funding modes and their exact msg.value requirement.
 *
 *   collateral | funding selection       | required msg.value
 *   -----------+-------------------------+-------------------------------------
 *   ERC20      | Permit2                 | gas comps + rewards only
 *   ERC20      | oracle internal balance | gas comps + rewards only
 *   ETH        | external deposit        | margin + gas comps + rewards
 *   ETH        | oracle internal balance | gas comps + rewards only
 *
 * @dev A pranked call carrying value is debited from the pranked account, so payer-side ETH
 *      assertions below are genuinely about the swapper. `test_prankedValueIsDebitedFromSwapper`
 *      pins that behaviour down rather than leaving it assumed.
 */
contract ProposalFundingModesTest is OpenPuntBase {
    uint256 internal constant EXTRA_ETH = uint256(MATCHER_GAS_COMP) + SETTLER_REWARD + OPEN_EXEC_COMP;

    function setUp() public {
        _setUpAll();
        // native-ETH collateral is 1000e18 wei, so the swapper needs a real ETH balance
        vm.deal(swapper, 10_000 ether);

        // internal-balance modes: swapper pre-funds its own oracle ledger and lets the core spend it
        vm.startPrank(swapper);
        collat.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(collat), INITIAL_MARGIN_SWAPPER, swapper);
        oracle.deposit{value: INITIAL_MARGIN_SWAPPER}(address(0), INITIAL_MARGIN_SWAPPER, swapper);
        oracle.approveInternal(address(punt), address(collat), type(uint256).max);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();
    }

    function _erc20Permit2() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap(); // collat = ERC20, useInternalBalances = false
    }

    function _erc20Internal() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap();
        s.useInternalBalances = true;
    }

    function _ethExternal() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap();
        s.collatToken = address(0);
        s.useInternalBalances = false;
    }

    function _ethInternal() internal view returns (OpenPuntStorage.ProposedSwap memory s) {
        s = _defaultProposedSwap();
        s.collatToken = address(0);
        s.useInternalBalances = true;
    }

    /// @dev Asserts an off-by-one msg.value in either direction reverts and changes nothing.
    function _assertValueMustBeExact(OpenPuntStorage.ProposedSwap memory s, uint256 exact, string memory what)
        internal
    {
        OpenPuntStorage.MatcherPreimage memory m = _defaultMatcherPreimage();

        uint256 idBefore = punt.nextSwapId();
        uint256 puntEth = address(punt).balance;
        uint256 puntCollat = oracle.tokenHolder(address(punt), s.collatToken);
        uint256 swapperExt = collat.balanceOf(swapper);
        uint256 swapperCollatInt = oracle.tokenHolder(swapper, address(collat));
        uint256 swapperEthInt = oracle.tokenHolder(swapper, address(0));
        uint256 permitCalls = _permit2().callCount();

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.InvalidMsgValue.selector);
        punt.propose{value: exact - 1}(s, m, _emptyPermit2());

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.InvalidMsgValue.selector);
        punt.propose{value: exact + 1}(s, m, _emptyPermit2());

        assertEq(punt.nextSwapId(), idBefore, string.concat(what, ": nextSwapId unchanged"));
        assertEq(punt.swaps(idBefore), bytes32(0), string.concat(what, ": no swap stored"));
        assertEq(address(punt).balance, puntEth, string.concat(what, ": core ETH unchanged"));
        assertEq(
            oracle.tokenHolder(address(punt), s.collatToken), puntCollat, string.concat(what, ": core collat unchanged")
        );
        assertEq(collat.balanceOf(swapper), swapperExt, string.concat(what, ": swapper external collat unchanged"));
        assertEq(
            oracle.tokenHolder(swapper, address(collat)),
            swapperCollatInt,
            string.concat(what, ": swapper internal collat unchanged")
        );
        assertEq(
            oracle.tokenHolder(swapper, address(0)),
            swapperEthInt,
            string.concat(what, ": swapper internal ETH unchanged")
        );
        assertEq(_permit2().callCount(), permitCalls, string.concat(what, ": Permit2 untouched"));
    }

    // ── mode 1: ERC20 collateral via Permit2 ────────────────────────────

    function test_mode_erc20Permit2() public {
        OpenPuntStorage.ProposedSwap memory s = _erc20Permit2();

        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 permitCalls0 = _permit2().callCount();

        vm.prank(swapper);
        uint256 swapId = punt.propose{value: EXTRA_ETH}(s, _defaultMatcherPreimage(), _emptyPermit2());

        assertTrue(punt.swaps(swapId) != bytes32(0), "swap stored");
        assertEq(collat.balanceOf(swapper), swapperExt0 - INITIAL_MARGIN_SWAPPER, "swapper external collat debited");
        assertEq(_spendable(address(punt), address(collat)), INITIAL_MARGIN_SWAPPER, "core credited exact margin");
        assertEq(collat.balanceOf(address(punt)), 0, "core holds no external collat");
        assertEq(address(punt).balance, EXTRA_ETH, "core retains only gas comps and rewards");
        assertEq(_permit2().callCount(), permitCalls0 + 1, "Permit2 pulled the collateral");
    }

    function test_mode_erc20Permit2_valueMustBeExact() public {
        _assertValueMustBeExact(_erc20Permit2(), EXTRA_ETH, "erc20/permit2");
    }

    // ── mode 2: ERC20 collateral from the oracle internal ledger ────────

    function test_mode_erc20InternalBalance() public {
        OpenPuntStorage.ProposedSwap memory s = _erc20Internal();

        uint256 swapperExt0 = collat.balanceOf(swapper);
        uint256 swapperInt0 = _spendable(swapper, address(collat));
        uint256 permitCalls0 = _permit2().callCount();

        vm.prank(swapper);
        uint256 swapId = punt.propose{value: EXTRA_ETH}(s, _defaultMatcherPreimage(), _emptyPermit2());

        assertTrue(punt.swaps(swapId) != bytes32(0), "swap stored");
        assertEq(_spendable(swapper, address(collat)), swapperInt0 - INITIAL_MARGIN_SWAPPER, "swapper internal debited");
        assertEq(collat.balanceOf(swapper), swapperExt0, "swapper external collat untouched");
        assertEq(_spendable(address(punt), address(collat)), INITIAL_MARGIN_SWAPPER, "core credited exact margin");
        assertEq(address(punt).balance, EXTRA_ETH, "core retains only gas comps and rewards");
        assertEq(_permit2().callCount(), permitCalls0, "internal funding never calls Permit2");
    }

    function test_mode_erc20InternalBalance_valueMustBeExact() public {
        _assertValueMustBeExact(_erc20Internal(), EXTRA_ETH, "erc20/internal");
    }

    // ── mode 3: native ETH collateral deposited externally ──────────────

    function test_mode_ethExternalDeposit() public {
        OpenPuntStorage.ProposedSwap memory s = _ethExternal();
        uint256 exact = EXTRA_ETH + INITIAL_MARGIN_SWAPPER;

        uint256 swapperEth0 = swapper.balance; // pranked calls are debited from the pranked account
        uint256 oracleEth0 = address(oracle).balance;
        uint256 permitCalls0 = _permit2().callCount();

        vm.prank(swapper);
        uint256 swapId = punt.propose{value: exact}(s, _defaultMatcherPreimage(), _emptyPermit2());

        assertTrue(punt.swaps(swapId) != bytes32(0), "swap stored");
        assertEq(swapper.balance, swapperEth0 - exact, "swapper debited exactly msg.value");
        assertEq(address(oracle).balance, oracleEth0 + INITIAL_MARGIN_SWAPPER, "margin forwarded to the oracle");
        assertEq(_spendable(address(punt), address(0)), INITIAL_MARGIN_SWAPPER, "core credited exact ETH margin");
        assertEq(address(punt).balance, EXTRA_ETH, "core retains only gas comps and rewards");
        assertEq(_permit2().callCount(), permitCalls0, "native ETH never calls Permit2");
    }

    function test_mode_ethExternalDeposit_valueMustBeExact() public {
        _assertValueMustBeExact(_ethExternal(), EXTRA_ETH + INITIAL_MARGIN_SWAPPER, "eth/external");
    }

    /// @dev The gas-comps-only amount is the *wrong* value for this mode, and is rejected.
    function test_mode_ethExternal_rejectsGasCompsOnlyValue() public {
        OpenPuntStorage.ProposedSwap memory s = _ethExternal();
        uint256 idBefore = punt.nextSwapId();

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.InvalidMsgValue.selector);
        punt.propose{value: EXTRA_ETH}(s, _defaultMatcherPreimage(), _emptyPermit2());

        assertEq(punt.nextSwapId(), idBefore, "nextSwapId unchanged");
    }

    // ── mode 4: native ETH collateral from the oracle internal ledger ────

    function test_mode_ethInternalBalance() public {
        OpenPuntStorage.ProposedSwap memory s = _ethInternal();

        uint256 swapperEthInt0 = _spendable(swapper, address(0));
        uint256 swapperEth0 = swapper.balance;
        uint256 permitCalls0 = _permit2().callCount();

        vm.prank(swapper);
        uint256 swapId = punt.propose{value: EXTRA_ETH}(s, _defaultMatcherPreimage(), _emptyPermit2());

        assertTrue(punt.swaps(swapId) != bytes32(0), "swap stored");
        assertEq(
            _spendable(swapper, address(0)), swapperEthInt0 - INITIAL_MARGIN_SWAPPER, "swapper internal ETH debited"
        );
        assertEq(_spendable(address(punt), address(0)), INITIAL_MARGIN_SWAPPER, "core credited exact ETH margin");
        assertEq(swapper.balance, swapperEth0 - EXTRA_ETH, "swapper sent only gas comps and rewards");
        assertEq(address(punt).balance, EXTRA_ETH, "core retains only gas comps and rewards");
        assertEq(_permit2().callCount(), permitCalls0, "internal funding never calls Permit2");
    }

    function test_mode_ethInternalBalance_valueMustBeExact() public {
        _assertValueMustBeExact(_ethInternal(), EXTRA_ETH, "eth/internal");
    }

    /// @dev Every mode credits OpenPunt the identical margin regardless of how it was sourced.
    function test_allModesCreditIdenticalMargin() public {
        vm.prank(swapper);
        punt.propose{value: EXTRA_ETH}(_erc20Permit2(), _defaultMatcherPreimage(), _emptyPermit2());
        uint256 afterPermit2 = _spendable(address(punt), address(collat));

        vm.prank(swapper);
        punt.propose{value: EXTRA_ETH}(_erc20Internal(), _defaultMatcherPreimage(), _emptyPermit2());
        uint256 afterInternal = _spendable(address(punt), address(collat));

        assertEq(afterPermit2, INITIAL_MARGIN_SWAPPER, "permit2 route credits the margin");
        assertEq(afterInternal - afterPermit2, INITIAL_MARGIN_SWAPPER, "internal route credits the same margin");

        vm.prank(swapper);
        punt.propose{value: EXTRA_ETH + INITIAL_MARGIN_SWAPPER}(
            _ethExternal(), _defaultMatcherPreimage(), _emptyPermit2()
        );
        uint256 afterEthExternal = _spendable(address(punt), address(0));

        vm.prank(swapper);
        punt.propose{value: EXTRA_ETH}(_ethInternal(), _defaultMatcherPreimage(), _emptyPermit2());
        uint256 afterEthInternal = _spendable(address(punt), address(0));

        assertEq(afterEthExternal, INITIAL_MARGIN_SWAPPER, "eth external route credits the margin");
        assertEq(
            afterEthInternal - afterEthExternal, INITIAL_MARGIN_SWAPPER, "eth internal route credits the same margin"
        );

        assertEq(address(punt).balance, 4 * EXTRA_ETH, "core retains gas comps from all four proposals");
    }

    /// @dev Pins the harness assumption the payer-side assertions rest on.
    function test_prankedValueIsDebitedFromSwapper() public {
        uint256 swapperEth0 = swapper.balance;
        uint256 testEth0 = address(this).balance;

        vm.prank(swapper);
        punt.propose{value: EXTRA_ETH}(_erc20Permit2(), _defaultMatcherPreimage(), _emptyPermit2());

        assertEq(swapper.balance, swapperEth0 - EXTRA_ETH, "pranked account pays the msg.value");
        assertEq(address(this).balance, testEth0, "test contract pays nothing");
    }
}
