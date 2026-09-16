// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase, IV2Factory, IV2Pair, IV3Factory, IERC20Like} from "./DisputeHelperBase.t.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";

/// @notice Proves the fixture placed AUTHENTIC Uniswap venues and that they actually trade. If any
///         of these fail, every routing assertion in this folder is meaningless.
contract FixtureSmokeTest is DisputeHelperBase {
    function test_helperStoresOnlyTheOracleDeploymentDependency() public view {
        assertEq(address(helper.oracle()), address(oracle), "wrong oracle immutable");
    }

    function test_zeroOracleAddressIsRejected() public {
        vm.expectRevert(OracleDisputeHelper.AddressCannotBeZero.selector);
        new OracleDisputeHelper(address(0));
    }

    function test_venuesArePlacedWithRealCode() public view {
        assertGt(v2Factory.code.length, 0, "v2 factory has no code");
        assertGt(v3Factory.code.length, 0, "v3 factory has no code");
        assertGt(poolManager.code.length, 0, "v4 pool manager has no code");
        assertGt(router.code.length, 0, "universal router has no code");
        assertGt(PERMIT2.code.length, 0, "permit2 not deployed");
    }

    function test_v2PairIsSeededAtOneToOne() public view {
        address pair = IV2Factory(v2Factory).getPair(address(tokenC), address(tokenA));
        assertTrue(pair != address(0), "pair not created");
        assertEq(IERC20Like(address(tokenC)).balanceOf(pair), POOL_LIQUIDITY, "tokenC reserve");
        assertEq(IERC20Like(address(tokenA)).balanceOf(pair), POOL_LIQUIDITY, "tokenA reserve");
    }

    function test_v3PoolIsCreatedAtTheAddressTheRouterWillDerive() public view {
        address pool = IV3Factory(v3Factory).getPool(address(tokenC), address(tokenA), V3_FEE);
        assertTrue(pool != address(0), "v3 pool not created");
        assertGt(pool.code.length, 0, "v3 pool has no code");
    }

    /// @dev Drives the REAL router directly, with the router paying from its own balance — the
    ///      exact funding shape the helper relies on.
    function test_routerSwapsV2FromItsOwnBalance() public {
        _mintTo(address(tokenC), router, 100e18);

        (bytes memory commands, bytes[] memory inputs) = _v2ExactIn(address(tokenC), address(tokenA), 100e18, 1);

        uint256 before = tokenA.balanceOf(address(helper));
        IUniversalRouterLike(router).execute(commands, inputs, block.timestamp + 1);

        assertGt(tokenA.balanceOf(address(helper)) - before, 0, "no v2 output delivered");
    }

    function test_routerSwapsV3FromItsOwnBalance() public {
        _mintTo(address(tokenC), router, 100e18);

        (bytes memory commands, bytes[] memory inputs) = _v3ExactIn(address(tokenC), address(tokenA), 100e18, 1);

        uint256 before = tokenA.balanceOf(address(helper));
        IUniversalRouterLike(router).execute(commands, inputs, block.timestamp + 1);

        assertGt(tokenA.balanceOf(address(helper)) - before, 0, "no v3 output delivered");
    }

    /// @dev V4's TAKE_ALL credits the router's OWN caller rather than an explicit recipient, so
    ///      here the output lands on this test contract. In production the helper is the caller,
    ///      which is exactly why the encoding is safe for it — proven in the routing suites.
    function test_routerSwapsV4FromItsOwnBalance() public {
        _mintTo(address(tokenC), router, 100e18);

        (bytes memory commands, bytes[] memory inputs) =
            _v4ExactInSingle(address(tokenC), address(tokenA), 100e18, 1, address(0));

        uint256 before = tokenA.balanceOf(address(this));
        IUniversalRouterLike(router).execute(commands, inputs, block.timestamp + 1);

        assertGt(tokenA.balanceOf(address(this)) - before, 0, "no v4 output delivered");
    }

    function test_oracleGameIsCreatedByARealReport() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        assertTrue(oracle.oracleGame(ctx.reportId) != bytes32(0), "no game stored");
        assertEq(
            oracle.oracleGame(ctx.reportId),
            keccak256(abi.encode(ctx.game, ctx.helper)),
            "reconstructed preimage does not hash to the stored state"
        );
    }
}

interface IUniversalRouterLike {
    function execute(bytes calldata, bytes[] calldata, uint256) external payable;
}
