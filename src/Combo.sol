// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidityLocking} from "./LiquidityLocking.sol";
import {VolumeFee} from "./VolumeFee.sol";
import {BaseHook} from "./utils/BaseHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {console} from "forge-std/Test.sol";

contract Combo is LiquidityLocking, VolumeFee {
    struct InitParamsCombo {
        bytes volumeFeeData;
        bytes liquidityLockingData;
    }

    constructor(
        IPoolManager _poolManager,
        address _owner
    ) LiquidityLocking(_poolManager) VolumeFee(_poolManager, _owner) {}

    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        bytes memory data
    ) public override(LiquidityLocking, VolumeFee) returns (bytes4) {
        InitParamsCombo memory initParamsCombo = abi.decode(
            data,
            (InitParamsCombo)
        );

        LiquidityLocking.beforeInitialize(
            sender,
            key,
            sqrtPriceX96,
            initParamsCombo.liquidityLockingData
        );

        VolumeFee.beforeInitialize(
            sender,
            key,
            sqrtPriceX96,
            initParamsCombo.volumeFeeData
        );

        return IHooks.beforeInitialize.selector;
    }

    function getHooksPermissions()
        public
        pure
        override(LiquidityLocking, VolumeFee)
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                noOp: false,
                accessLock: false
            });
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) public override(LiquidityLocking, VolumeFee) returns (bytes4) {
        LiquidityLocking.beforeSwap(sender, key, params, hookData);
        VolumeFee.beforeSwap(sender, key, params, hookData);

        return IHooks.beforeSwap.selector;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) public virtual override(VolumeFee, BaseHook) returns (bytes4) {
        return VolumeFee.afterSwap(sender, key, params, delta, hookData);
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) public override(LiquidityLocking, BaseHook) returns (bytes4) {
        return
            LiquidityLocking.beforeAddLiquidity(sender, key, params, hookData);
    }

    function lockAcquired(
        address lockCaller,
        bytes calldata rawData
    ) public override returns (bytes memory) {
        return LiquidityLocking.lockAcquired(lockCaller, rawData);
    }

    function removeLiquidity(
        RemoveLiquidityParams calldata params
    ) public virtual override returns (BalanceDelta delta) {
        // Removing the liquidity from the pool triggers rebalancing.
        // During rebalancing a swap occures with amountSpecified = MAX_INT.
        // This would cause overflow and revert in the VolumeFee hook, so we will skip executing them.
        skipBeforeAfterHooks = true;
        delta = LiquidityLocking.removeLiquidity(params);
        skipBeforeAfterHooks = false;
    }
}
