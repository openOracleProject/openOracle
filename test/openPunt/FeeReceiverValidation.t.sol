// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./FeeReceiverBase.t.sol";

/**
 * @notice CREATE2 isolation for `deployAndDistributeFeeReceiver` argument tuples.
 *
 * @dev The entry point deliberately does not authenticate position or oracle preimages. The receiver
 *      address commits its swap identifier, assets, and beneficiaries in the clone init code. A wrong
 *      tuple can therefore create only a distinct, empty clone; it cannot deploy or distribute from the
 *      receiver to which a genuine oracle game credited fees.
 */
contract FeeReceiverValidationTest is FeeReceiverBase {
    function setUp() public {
        _setUpFees();
    }

    struct Ctx {
        uint256 swapId;
        address receiver;
        Game g;
        uint256 fee;
    }

    function _accrued() internal returns (Ctx memory c) {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _defaultFeeCfg();
        (Proposal memory p, Matched memory mt) = _matchAsset(s, m);
        c.swapId = p.swapId;
        c.receiver = _predictForPosition(p.swapId, mt.swap);
        c.g = _gameOf(mt);
        (c.g, c.fee) = _disputeForToken1Fee(c.g, disputer);
    }

    function _deploy(
        uint256 swapId,
        address token1_,
        address token2_,
        address swapper_,
        address matcher_,
        address caller
    ) internal returns (address receiver, uint256 fees1, uint256 fees2) {
        vm.prank(caller);
        return puntLifecycle.deployAndDistributeFeeReceiver(swapId, token1_, token2_, swapper_, matcher_);
    }

    function _assertRealReceiverUntouched(Ctx memory c, string memory what) internal view {
        assertEq(c.receiver.code.length, 0, string.concat(what, ": genuine clone remains undeployed"));
        assertEq(_spendable(c.receiver, address(tokenA)), c.fee, string.concat(what, ": genuine fees remain"));
        assertEq(_spendable(c.receiver, address(tokenB)), 0, string.concat(what, ": token2 remains empty"));
    }

    function test_wrongSwapIdDeploysDistinctEmptyClone() public {
        Ctx memory c = _accrued();
        uint256 wrongId = c.swapId + 1;
        address expected = _predict(wrongId, address(tokenA), address(tokenB), swapper, matcher, address(punt));

        (address junk, uint256 fees1, uint256 fees2) =
            _deploy(wrongId, address(tokenA), address(tokenB), swapper, matcher, outsider);

        assertEq(junk, expected, "wrong tuple uses its own deterministic address");
        assertTrue(junk != c.receiver, "wrong tuple cannot alias the genuine receiver");
        assertGt(junk.code.length, 0, "empty junk clone may be deployed");
        assertEq(fees1, 0, "junk has no token1 fees");
        assertEq(fees2, 0, "junk has no token2 fees");
        _assertRealReceiverUntouched(c, "wrong swapId");
    }

    function test_wrongTokenDeploysDistinctEmptyClone() public {
        Ctx memory c = _accrued();
        address wrongToken2 = address(collat);
        address expected = _predict(c.swapId, address(tokenA), wrongToken2, swapper, matcher, address(punt));

        (address junk, uint256 fees1, uint256 fees2) =
            _deploy(c.swapId, address(tokenA), wrongToken2, swapper, matcher, outsider);

        assertEq(junk, expected, "wrong asset tuple uses its own deterministic address");
        assertTrue(junk != c.receiver, "wrong asset cannot alias the genuine receiver");
        assertEq(fees1, 0, "junk has no token1 fees");
        assertEq(fees2, 0, "junk has no token2 fees");
        _assertRealReceiverUntouched(c, "wrong token");
    }

    function test_wrongBeneficiariesDeployDistinctEmptyClones() public {
        Ctx memory c = _accrued();

        (address wrongSwapper,,) = _deploy(c.swapId, address(tokenA), address(tokenB), outsider, matcher, outsider);
        (address wrongMatcher,,) = _deploy(c.swapId, address(tokenA), address(tokenB), swapper, outsider, outsider);

        assertTrue(wrongSwapper != c.receiver, "wrong swapper is isolated");
        assertTrue(wrongMatcher != c.receiver, "wrong matcher is isolated");
        assertTrue(wrongSwapper != wrongMatcher, "each immutable tuple is isolated");
        _assertRealReceiverUntouched(c, "wrong beneficiaries");
    }

    function test_junkDeploymentCannotBlockTheCorrectReceiver() public {
        Ctx memory c = _accrued();
        _deploy(c.swapId + 1, address(tokenA), address(tokenB), swapper, matcher, outsider);
        _deploy(c.swapId, address(tokenA), address(collat), swapper, matcher, outsider);
        _deploy(c.swapId, address(tokenA), address(tokenB), outsider, matcher, outsider);

        (address receiver, uint256 fees1, uint256 fees2) =
            _deploy(c.swapId, address(tokenA), address(tokenB), swapper, matcher, outsider);

        assertEq(receiver, c.receiver, "correct tuple reaches the genuine receiver");
        assertEq(fees1, c.fee, "genuine token1 fees distributed");
        assertEq(fees2, 0, "no token2 fees");
        assertGt(receiver.code.length, 0, "genuine receiver deployed normally");
    }

    function test_crossPositionTupleDeploysOnlyAThirdEmptyReceiver() public {
        Ctx memory a = _accrued();
        Ctx memory b = _accrued();
        address crossed = _predict(b.swapId, address(tokenA), address(tokenB), swapper, outsider, address(punt));

        (address receiver, uint256 fees1, uint256 fees2) =
            _deploy(b.swapId, address(tokenA), address(tokenB), swapper, outsider, outsider);

        assertEq(receiver, crossed, "crossed tuple has its own address");
        assertTrue(receiver != a.receiver && receiver != b.receiver, "neither genuine receiver is reachable");
        assertEq(fees1, 0, "crossed receiver has no token1 fees");
        assertEq(fees2, 0, "crossed receiver has no token2 fees");
        _assertRealReceiverUntouched(a, "crossed tuple A");
        _assertRealReceiverUntouched(b, "crossed tuple B");
    }

    function test_rawModuleCallDeploysOnlyTheModuleRelativeReceiver() public {
        Ctx memory c = _accrued();
        address moduleReceiver =
            _predict(c.swapId, address(tokenA), address(tokenB), swapper, matcher, address(lifecycleModule));

        vm.prank(outsider);
        (address receiver, uint256 fees1, uint256 fees2) =
            lifecycleModule.deployAndDistributeFeeReceiver(c.swapId, address(tokenA), address(tokenB), swapper, matcher);

        assertEq(receiver, moduleReceiver, "raw call uses module as CREATE2 deployer");
        assertTrue(receiver != c.receiver, "module-relative clone cannot alias core-relative clone");
        assertEq(fees1, 0, "module-relative receiver has no token1 fees");
        assertEq(fees2, 0, "module-relative receiver has no token2 fees");
        _assertRealReceiverUntouched(c, "raw module call");
    }
}
