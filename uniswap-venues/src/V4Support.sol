// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Test support contracts that must live in the V4 compilation unit.
//
// v4-core pins solc 0.8.26 and OracleDisputeHelper pins 0.8.28, so a single file cannot import
// both. Anything that needs v4-core's types (PoolKey, IPoolManager, the unlock callback) is
// therefore built here at 0.8.26 and placed by the 0.8.28 tests with `vm.deployCode`, then driven
// through a hand-written minimal interface. Nothing here is a mock of code under test: the
// PoolManager, the router, and the helper are all the real implementations.

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/// @notice Initializes real V4 pools and seeds them with real liquidity through the real
///         PoolManager unlock/settle flow. Used only to build venue state, never asserted on.
contract V4LiquidityHelper is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(address poolManager) {
        manager = IPoolManager(poolManager);
    }

    receive() external payable {}

    function initializePool(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    ) external {
        manager.initialize(_key(currency0, currency1, fee, tickSpacing, hooks), sqrtPriceX96);
    }

    function addLiquidity(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) external payable {
        manager.unlock(
            abi.encode(_key(currency0, currency1, fee, tickSpacing, hooks), tickLower, tickUpper, liquidityDelta)
        );
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
            abi.decode(data, (PoolKey, int24, int24, int256));

        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    /// @dev Negative delta is owed to the pool; positive is owed to us.
    function _settle(Currency currency, int128 amount) internal {
        if (amount == 0) return;

        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), owed);
                manager.settle();
            }
        } else {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    function _key(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
    }
}

/// @notice A real V4 hook whose beforeSwap re-enters an arbitrary target. Used to prove that a
///         hostile hook inside an opaque V4 plan cannot re-enter disputeWithRoute.
contract ReentrantV4Hook {
    address public target;
    bytes public payload;
    bool public fired;
    bool public reenterSucceeded;
    bytes public reenterReturndata;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        fired = false;
        reenterSucceeded = false;
    }

    /// @dev beforeSwap selector; the flags encoded in this contract's address decide whether the
    ///      PoolManager actually calls it, so the deploy site must mine a matching address.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        returns (bytes4, int256, uint24)
    {
        if (!fired && target != address(0)) {
            fired = true;
            (bool ok, bytes memory ret) = target.call(payload);
            reenterSucceeded = ok;
            reenterReturndata = ret;
        }
        return (this.beforeSwap.selector, int256(0), uint24(0));
    }

    fallback() external {}
}
