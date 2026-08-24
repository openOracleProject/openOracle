// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./FeeReceiverBase.t.sol";

/**
 * @notice The fee receiver's only asset-sensitive dimension: a native-ETH oracle leg, in both
 *         orientations, plus one shared collateral/oracle-token composition.
 *
 * @dev The full asset matrix is already covered elsewhere and is deliberately not repeated.
 *      When address(0) is an oracle leg it is also the fee denomination, so payouts land in the
 *      parties' internal ETH ledgers and raw ETH must not move.
 */
contract FeeReceiverAssetModesTest is FeeReceiverBase {
    function setUp() public {
        _setUpFees();
    }

    // ══════════════════════════════════════════════════════════════════
    //  ETH as token1, fee accrues in token1
    // ══════════════════════════════════════════════════════════════════

    function test_ethAsToken1AccruesAndDistributesTheFeeInEth() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _feeCfg(Legs.EthIsToken1, address(collat), PROTO_FEE);
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);

        // the counterfactual address uses address(0) in the token1 slot
        address predicted = _predict(p.swapId, address(0), address(tokenB), swapper, matcher, address(punt));
        assertEq(mt.swap.feeRecipient, predicted, "prediction with address(0) as token1");
        assertEq(mt.game.token1, address(0), "token1 really is native ETH");

        Game memory g = _gameOf(mt);
        uint256 fee;
        (g, fee) = _disputeForToken1Fee(g, disputer);

        assertEq(_spendable(predicted, address(0)), fee, "receiver's internal ETH gained exactly the fee");
        assertEq(oracle.tokenHolder(predicted, address(0)), fee + 1, "sentinel preserved");
        assertEq(_spendable(predicted, address(tokenB)), 0, "the ERC20 companion slot is independently zero");

        FeeBook memory before = _feeBook(predicted, address(0), address(tokenB));
        (address receiver, uint256 fees1, uint256 fees2,) =
            _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(receiver, predicted, "deployed at the predicted address");
        assertEq(fees1, fee, "ETH fee distributed");
        assertEq(fees2, 0, "no ERC20 fee");
        _assertDistributed(before, receiver, address(0), address(tokenB), fees1, fees2, "eth token1");
        _assertOnlySentinelsRemain(receiver, address(0), address(tokenB), "eth token1");
    }

    // ══════════════════════════════════════════════════════════════════
    //  ETH as token2, fee accrues in token2
    // ══════════════════════════════════════════════════════════════════

    function test_ethAsToken2AccruesAndDistributesTheFeeInEth() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _feeCfg(Legs.EthIsToken2, address(collat), PROTO_FEE);
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);

        address predicted = _predict(p.swapId, address(tokenA), address(0), swapper, matcher, address(punt));
        assertEq(mt.swap.feeRecipient, predicted, "prediction with address(0) as token2");
        assertEq(mt.game.token2, address(0), "token2 really is native ETH");

        Game memory g = _gameOf(mt);
        uint256 fee;
        (g, fee) = _disputeForToken2Fee(g, disputer);

        assertEq(_spendable(predicted, address(0)), fee, "receiver's internal ETH gained exactly the fee");
        assertEq(_spendable(predicted, address(tokenA)), 0, "the ERC20 companion slot is independently zero");

        FeeBook memory before = _feeBook(predicted, address(tokenA), address(0));
        (address receiver, uint256 fees1, uint256 fees2,) =
            _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(receiver, predicted, "deployed at the predicted address");
        assertEq(fees1, 0, "no ERC20 fee");
        assertEq(fees2, fee, "ETH fee distributed");
        _assertDistributed(before, receiver, address(tokenA), address(0), fees1, fees2, "eth token2");
        _assertOnlySentinelsRemain(receiver, address(tokenA), address(0), "eth token2");
    }

    /// @dev Both slots stay independently accountable when one is ETH and one is ERC20.
    function test_ethAndErc20FeeSlotsStayIndependent() public {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _feeCfg(Legs.EthIsToken1, address(collat), PROTO_FEE);
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);
        address predicted = _predictForPosition(p.swapId, mt.swap);

        Game memory g = _gameOf(mt);
        uint256 ethFee;
        uint256 erc20Fee;
        (g, ethFee) = _disputeForToken1Fee(g, disputer); // ETH side
        (g, erc20Fee) = _disputeForToken2Fee(g, disputer2); // ERC20 side

        assertEq(_spendable(predicted, address(0)), ethFee, "ETH slot holds only the ETH fee");
        assertEq(_spendable(predicted, address(tokenB)), erc20Fee, "ERC20 slot holds only the ERC20 fee");

        FeeBook memory before = _feeBook(predicted, address(0), address(tokenB));
        (address receiver, uint256 fees1, uint256 fees2,) =
            _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(fees1, ethFee, "ETH fee returned as fees1");
        assertEq(fees2, erc20Fee, "ERC20 fee returned as fees2");
        _assertDistributed(before, receiver, address(0), address(tokenB), fees1, fees2, "mixed slots");
        _assertOnlySentinelsRemain(receiver, address(0), address(tokenB), "mixed slots");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Shared collateral / oracle-token composition
    // ══════════════════════════════════════════════════════════════════

    /// @dev Collateral equal to oracle token1: the fee credit and the position margin pool share
    ///      one ledger slot per owner, so distribution must move only the fee claims.
    function test_collateralEqualToAnOracleTokenLeavesTheMarginPoolAlone() public {
        // the swapper funds its margin externally through Permit2, so it needs external tokenA
        tokenA.mint(swapper, 500_000e18);
        vm.prank(swapper);
        tokenA.approve(PERMIT2, type(uint256).max);
        _mintAndDeposit(tokenA, matcher, 500_000e18);

        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) =
            _feeCfg(Legs.BothErc20, address(tokenA), PROTO_FEE);
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);
        assertEq(mt.swap.collatToken, mt.swap.oracleToken1, "collateral IS oracle token1");

        address predicted = _predictForPosition(p.swapId, mt.swap);
        uint256 corePool = _spendable(address(punt), address(tokenA));
        assertEq(corePool, uint256(MARGIN_S) + MARGIN_M, "the core holds exactly both margins");

        Game memory g = _gameOf(mt);
        uint256 fee;
        (g, fee) = _disputeForToken1Fee(g, disputer);

        FeeBook memory before = _feeBook(predicted, address(tokenA), address(tokenB));
        (address receiver, uint256 fees1, uint256 fees2,) =
            _deployAndDistribute(p.swapId, swapper, matcher, g, outsider);

        assertEq(fees1, fee, "the fee is distributed");
        assertEq(fees2, 0, "nothing on the other leg");
        _assertDistributed(before, receiver, address(tokenA), address(tokenB), fees1, fees2, "shared slot");

        // The margin pool in the same token slot is untouched.
        assertEq(
            _spendable(address(punt), address(tokenA)),
            corePool,
            "fee distribution did not disturb the position margin pool"
        );
        _assertOnlySentinelsRemain(receiver, address(tokenA), address(tokenB), "shared slot");
    }
}
