// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquidityLocking} from "./LiquidityLocking.sol";
import {VolumeFee} from "./VolumeFee.sol";
import {BaseHookNoState} from "./utils/BaseHookNoState.sol";

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "@uniswap/periphery-next/contracts/BaseHook.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {UniswapV4ERC20} from "@uniswap/periphery-next/contracts/libraries/UniswapV4ERC20.sol";
import {LiquidityAmounts} from "@uniswap/periphery-next/contracts/libraries/LiquidityAmounts.sol";
import {FixedPoint96} from "@uniswap/v4-core/contracts/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    function getHooksCalls()
        public
        pure
        override(LiquidityLocking, VolumeFee)
        returns (Hooks.Calls memory)
    {
        return
            Hooks.Calls({
                beforeInitialize: true,
                afterInitialize: false,
                beforeModifyPosition: true,
                afterModifyPosition: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
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
    ) public virtual override(VolumeFee, BaseHookNoState) returns (bytes4) {
        return VolumeFee.afterSwap(sender, key, params, delta, hookData);
    }

    function beforeModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        bytes calldata hookData
    ) public override(LiquidityLocking, BaseHookNoState) returns (bytes4) {
        return
            LiquidityLocking.beforeModifyPosition(
                sender,
                key,
                params,
                hookData
            );
    }

    function lockAcquired(
        bytes calldata rawData
    )
        public
        override(LiquidityLocking, BaseHookNoState)
        returns (bytes memory)
    {
        return LiquidityLocking.lockAcquired(rawData);
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
