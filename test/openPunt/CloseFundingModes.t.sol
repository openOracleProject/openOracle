// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./CloseBase.t.sol";

/**
 * @notice The four ways a close auction can be funded, and the exact msg.value each demands.
 *
 *   collateral | auction funding | required msg.value
 *   -----------+-----------------+---------------------------------------------
 *   ERC20      | external        | altGasCompExec       (reward via Permit2)
 *   ERC20      | internal        | 0                    (both from the ledger)
 *   ETH        | external        | maxReward + altGasCompExec
 *   ETH        | internal        | 0                    (combined, from the ledger)
 *
 * @dev The auction's funding mode is independent of the position's funding mode; these tests
 *      vary the former. Terminal payout routing (the latter) is covered separately.
 */
contract CloseFundingModesTest is CloseBase {
    function setUp() public {
        _setUpClose();
    }

    struct Before {
        uint256 swapperCollatExt;
        uint256 swapperCollatInt;
        uint256 swapperEth;
        uint256 swapperEthInt;
        uint256 puntCollatInt;
        uint256 puntEthInt;
        uint256 permitCalls;
        bytes32 positionHash;
    }

    function _before(address collatToken) internal view returns (Before memory b) {
        b.swapperCollatExt = collat.balanceOf(swapper);
        b.swapperCollatInt = _spendable(swapper, address(collat));
        b.swapperEth = swapper.balance;
        b.swapperEthInt = _spendable(swapper, address(0));
        b.puntCollatInt = _spendable(address(punt), collatToken);
        b.puntEthInt = _spendable(address(punt), address(0));
        b.permitCalls = _permit2().callCount();
    }

    /// @dev Shared post-conditions for a successfully created auction.
    function _assertAuctionShape(
        uint256 swapId,
        OpenPuntStorage.MatchedSwap memory active,
        OpenPuntStorage.CloseDutch memory emitted,
        uint128 comp,
        bytes32 positionHashBefore,
        uint48 startTs,
        bool auctionInternal
    ) internal view {
        // the emitted struct is exactly the canonical one and hashes to storage
        OpenPuntStorage.CloseDutch memory expected =
            _canonicalDutch(_dutchInput(), swapId, active.collatToken, auctionInternal, startTs);
        assertEq(keccak256(abi.encode(emitted)), keccak256(abi.encode(expected)), "emitted == canonical");
        assertEq(_storedAuctionHash(swapId, active), keccak256(abi.encode(emitted)), "event reconstructs the auction");

        (uint128 pending,, bool intent) = _closeState(swapId);
        assertTrue(intent, "close request is live");
        assertEq(pending, comp, "pending execution comp == altGasCompExec");

        assertEq(punt.swaps(swapId), positionHashBefore, "position hash unchanged");
    }

    // ══════════════════════════════════════════════════════════════════
    //  ERC20 collateral, externally funded
    // ══════════════════════════════════════════════════════════════════

    function test_erc20External() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        Before memory b = _before(active.collatToken);
        bytes32 positionHash = punt.swaps(swapId);
        uint48 startTs = uint48(vm.getBlockTimestamp());

        OpenPuntStorage.CloseDutch memory emitted = _startAuction(swapId, active, _dutchInput(), false, CLOSE_COMP);

        _assertAuctionShape(swapId, active, emitted, CLOSE_COMP, positionHash, startTs, false);

        // reward pulled externally through Permit2, comp arrived as msg.value
        assertEq(collat.balanceOf(swapper), b.swapperCollatExt - DUTCH_MAX, "reward pulled from external balance");
        assertEq(swapper.balance, b.swapperEth - CLOSE_COMP, "comp paid as msg.value");
        assertEq(_permit2().callCount(), b.permitCalls + 1, "Permit2 used once");

        // the internal route is untouched
        assertEq(_spendable(swapper, address(collat)), b.swapperCollatInt, "swapper ledger collat untouched");
        assertEq(_spendable(swapper, address(0)), b.swapperEthInt, "swapper ledger ETH untouched");

        // the core holds exactly what it owes
        assertEq(_spendable(address(punt), address(collat)) - b.puntCollatInt, DUTCH_MAX, "core holds the reward");
        assertEq(_spendable(address(punt), address(0)) - b.puntEthInt, CLOSE_COMP, "core holds the comp");
    }

    function test_erc20External_valueMustBeExact() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _assertValueExact(swapId, active, false, CLOSE_COMP, CLOSE_COMP, "erc20/external");
    }

    // ══════════════════════════════════════════════════════════════════
    //  ERC20 collateral, internally funded
    // ══════════════════════════════════════════════════════════════════

    function test_erc20Internal() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        Before memory b = _before(active.collatToken);
        bytes32 positionHash = punt.swaps(swapId);
        uint48 startTs = uint48(vm.getBlockTimestamp());

        OpenPuntStorage.CloseDutch memory emitted = _startAuction(swapId, active, _dutchInput(), true, CLOSE_COMP);

        _assertAuctionShape(swapId, active, emitted, CLOSE_COMP, positionHash, startTs, true);

        // both components came out of the swapper's oracle ledger
        assertEq(_spendable(swapper, address(collat)), b.swapperCollatInt - DUTCH_MAX, "reward from the ledger");
        assertEq(_spendable(swapper, address(0)), b.swapperEthInt - CLOSE_COMP, "comp from the ledger");

        // the external route is untouched
        assertEq(collat.balanceOf(swapper), b.swapperCollatExt, "external collat untouched");
        assertEq(swapper.balance, b.swapperEth, "raw ETH untouched");
        assertEq(_permit2().callCount(), b.permitCalls, "internal funding never calls Permit2");

        assertEq(_spendable(address(punt), address(collat)) - b.puntCollatInt, DUTCH_MAX, "core holds the reward");
        assertEq(_spendable(address(punt), address(0)) - b.puntEthInt, CLOSE_COMP, "core holds the comp");
    }

    function test_erc20Internal_valueMustBeZero() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openIdle();
        _assertValueExact(swapId, active, true, CLOSE_COMP, 0, "erc20/internal");
    }

    // ══════════════════════════════════════════════════════════════════
    //  ETH collateral, externally funded
    // ══════════════════════════════════════════════════════════════════

    function _openEthPosition()
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, Proposal memory p)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _positionCfg(true, false);
        (swapId, active, p) = _openAccounting(s, m);
        assertEq(active.collatToken, address(0), "ETH collateral position");
    }

    function test_ethExternal() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openEthPosition();
        Before memory b = _before(active.collatToken);
        bytes32 positionHash = punt.swaps(swapId);
        uint48 startTs = uint48(vm.getBlockTimestamp());

        OpenPuntStorage.CloseDutch memory emitted = _startAuction(swapId, active, _dutchInput(), false, CLOSE_COMP);

        _assertAuctionShape(swapId, active, emitted, CLOSE_COMP, positionHash, startTs, false);

        // one combined ETH payment covers reward and comp
        assertEq(swapper.balance, b.swapperEth - DUTCH_MAX - CLOSE_COMP, "reward and comp both paid as msg.value");
        assertEq(_spendable(swapper, address(0)), b.swapperEthInt, "swapper ETH ledger untouched");
        assertEq(collat.balanceOf(swapper), b.swapperCollatExt, "ERC20 balances irrelevant here");
        assertEq(_permit2().callCount(), b.permitCalls, "native ETH never calls Permit2");

        assertEq(
            _spendable(address(punt), address(0)) - b.puntEthInt,
            uint256(DUTCH_MAX) + CLOSE_COMP,
            "core holds reward plus comp as internal ETH"
        );
    }

    function test_ethExternal_valueMustBeExact() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openEthPosition();
        _assertValueExact(swapId, active, false, CLOSE_COMP, uint256(DUTCH_MAX) + CLOSE_COMP, "eth/external");
    }

    // ══════════════════════════════════════════════════════════════════
    //  ETH collateral, internally funded
    // ══════════════════════════════════════════════════════════════════

    function test_ethInternal() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openEthPosition();
        Before memory b = _before(active.collatToken);
        bytes32 positionHash = punt.swaps(swapId);
        uint48 startTs = uint48(vm.getBlockTimestamp());

        OpenPuntStorage.CloseDutch memory emitted = _startAuction(swapId, active, _dutchInput(), true, CLOSE_COMP);

        _assertAuctionShape(swapId, active, emitted, CLOSE_COMP, positionHash, startTs, true);

        assertEq(
            _spendable(swapper, address(0)),
            b.swapperEthInt - DUTCH_MAX - CLOSE_COMP,
            "combined amount taken from the ETH ledger"
        );
        assertEq(swapper.balance, b.swapperEth, "raw ETH untouched");
        assertEq(_permit2().callCount(), b.permitCalls, "internal funding never calls Permit2");
        assertEq(
            _spendable(address(punt), address(0)) - b.puntEthInt,
            uint256(DUTCH_MAX) + CLOSE_COMP,
            "core holds reward plus comp"
        );
    }

    function test_ethInternal_valueMustBeZero() public {
        (uint256 swapId, OpenPuntStorage.MatchedSwap memory active,) = _openEthPosition();
        _assertValueExact(swapId, active, true, CLOSE_COMP, 0, "eth/internal");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Shared exactness check
    // ══════════════════════════════════════════════════════════════════

    function _assertValueExact(
        uint256 swapId,
        OpenPuntStorage.MatchedSwap memory active,
        bool auctionInternal,
        uint128 comp,
        uint256 exact,
        string memory what
    ) internal {
        Snap memory before = _snap(swapId, active.collatToken);
        OpenPuntStorage.CloseDutch memory d = _dutchInput();

        if (exact > 0) {
            vm.prank(swapper);
            vm.expectRevert(PuntErrors.InvalidMsgValue.selector);
            punt.close{value: exact - 1}(
                swapId, d, active, auctionInternal, _emptyPermit2(), comp, _emptyOracleGame(), _emptyOracleHelper()
            );
        }

        vm.prank(swapper);
        vm.expectRevert(PuntErrors.InvalidMsgValue.selector);
        punt.close{value: exact + 1}(
            swapId, d, active, auctionInternal, _emptyPermit2(), comp, _emptyOracleGame(), _emptyOracleHelper()
        );

        _assertUnchanged(before, swapId, active.collatToken, what);

        // and the exact value works
        vm.prank(swapper);
        punt.close{value: exact}(
            swapId, d, active, auctionInternal, _emptyPermit2(), comp, _emptyOracleGame(), _emptyOracleHelper()
        );
        assertTrue(_storedDutchState(swapId) != bytes32(0), string.concat(what, ": exact value accepted"));
    }
}
