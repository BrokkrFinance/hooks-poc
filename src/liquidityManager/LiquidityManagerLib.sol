// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {LiquidityAmounts} from "../periphery/LiquidityAmounts.sol";
import {PoolInfo, MIN_TICK, MAX_TICK, TICK_SPACING} from "./LiquidityManagerStructs.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library LiquidityManagerLib {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    function handleDeltas(
        address sender,
        PoolKey memory poolKey,
        BalanceDelta delta,
        IPoolManager poolManager
    ) internal {
        handleDelta(sender, poolKey.currency0, delta.amount0(), poolManager);
        handleDelta(sender, poolKey.currency1, delta.amount1(), poolManager);
    }

    function handleDelta(
        address sender,
        Currency currency,
        int128 amount,
        IPoolManager poolManager
    ) internal {
        if (amount > 0) {
            settleDelta(sender, currency, uint128(amount), poolManager);
        } else if (amount < 0) {
            takeDelta(sender, currency, uint128(-amount), poolManager);
        }
    }

    function settleDelta(
        address sender,
        Currency currency,
        uint128 amount,
        IPoolManager poolManager
    ) internal {
        if (sender == address(this)) {
            currency.transfer(address(poolManager), amount);
        } else {
            IERC20(Currency.unwrap(currency)).safeTransferFrom(
                sender,
                address(poolManager),
                amount
            );
        }
        poolManager.settle(currency);
    }

    function takeDelta(
        address sender,
        Currency currency,
        uint256 amount,
        IPoolManager poolManager
    ) internal {
        poolManager.take(currency, sender, amount);
    }

    /* This is a very crude way of calculating the amount that needs to be swapped.
       1. It ignores fees taken during the swap.
       2. It ignores the price effect of the swap, and assumes we would be able to provide liquidity at the old pool price.
       3. It assumes that for a symmetric V3 range the correct ratio of token0 and token1 has to be
          token1/token0 = current pool price. The accuracy of this approximation can be seen here:
          https://www.desmos.com/calculator/zh37idwezb

       A more accurate (and gas intensive) way of calculating the amount we need to swap can be seen here:
       https://www.desmos.com/calculator/oiv0rti0ss

    */
    function calculateSwapAmount(
        uint256 token0Amount,
        uint256 token1Amount,
        uint160 sqrtPriceQ96
    ) internal pure returns (uint256 swapAmount, bool zeroForOne) {
        uint256 price = FullMath.mulDiv(
            sqrtPriceQ96,
            sqrtPriceQ96,
            FixedPoint96.Q96
        );

        if (token0Amount == 0) {
            zeroForOne = false;
            swapAmount = token1Amount / 2;
        } else if (
            FullMath.mulDiv(token1Amount, FixedPoint96.Q96, token0Amount) >
            price
        ) {
            zeroForOne = false;
            swapAmount =
                (token1Amount -
                    FullMath.mulDiv(token0Amount, price, FixedPoint96.Q96)) /
                2;
        } else {
            zeroForOne = true;
            swapAmount =
                (token0Amount / 2) -
                FullMath.mulDiv(token1Amount, FixedPoint96.Q96, 2 * price);
        }
    }

    function getAlignedTickFromTick(
        int24 tick,
        int24 tickSize
    ) internal pure returns (int24) {
        return (tick / tickSize) * tickSize;
    }

    function getAlignedTickFromSqrtPriceQ96(
        uint160 sqrtPriceQ96,
        int24 tickSize
    ) internal pure returns (int24) {
        return
            getAlignedTickFromTick(
                TickMath.getTickAtSqrtRatio(sqrtPriceQ96),
                tickSize
            );
    }

    function createModifyLiquidityParams(
        int256 fullRangeLiquidity,
        int256 narrowRangeLiquidity,
        PoolInfo storage poolInfo
    )
        internal
        view
        returns (
            IPoolManager.ModifyLiquidityParams[] memory modifyLiquidityParams
        )
    {
        modifyLiquidityParams = new IPoolManager.ModifyLiquidityParams[](2);

        modifyLiquidityParams[0] = IPoolManager.ModifyLiquidityParams({
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            liquidityDelta: fullRangeLiquidity
        });

        modifyLiquidityParams[1] = IPoolManager.ModifyLiquidityParams({
            tickLower: poolInfo.centerTick -
                TICK_SPACING *
                poolInfo.halfRangeWidthInTickSpaces,
            tickUpper: poolInfo.centerTick +
                TICK_SPACING *
                poolInfo.halfRangeWidthInTickSpaces,
            liquidityDelta: narrowRangeLiquidity
        });
    }

    function getAssetsInRanges(
        PoolId poolId,
        IPoolManager poolManager,
        PoolInfo storage poolInfo
    )
        internal
        view
        returns (
            uint256 fullRangeLiquidity,
            uint256 narrowRangeLiquidity,
            uint256 fullRangeToken0,
            uint256 fullRangeToken1,
            uint256 narrowRangeToken0,
            uint256 narrowRangeToken1
        )
    {
        (uint160 sqrtCurrentPriceX96, , ) = poolManager.getSlot0(poolId);

        fullRangeLiquidity = poolManager
            .getPosition(poolId, address(this), MIN_TICK, MAX_TICK)
            .liquidity;

        narrowRangeLiquidity = poolManager
            .getPosition(
                poolId,
                address(this),
                poolInfo.centerTick -
                    TICK_SPACING *
                    poolInfo.halfRangeWidthInTickSpaces,
                poolInfo.centerTick +
                    TICK_SPACING *
                    poolInfo.halfRangeWidthInTickSpaces
            )
            .liquidity;

        (fullRangeToken0, fullRangeToken1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtCurrentPriceX96,
                TickMath.getSqrtRatioAtTick(MIN_TICK),
                TickMath.getSqrtRatioAtTick(MAX_TICK),
                uint128(fullRangeLiquidity)
            );

        (narrowRangeToken0, narrowRangeToken1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtCurrentPriceX96,
                TickMath.getSqrtRatioAtTick(
                    poolInfo.centerTick -
                        TICK_SPACING *
                        poolInfo.halfRangeWidthInTickSpaces
                ),
                TickMath.getSqrtRatioAtTick(
                    poolInfo.centerTick +
                        TICK_SPACING *
                        poolInfo.halfRangeWidthInTickSpaces
                ),
                uint128(narrowRangeLiquidity)
            );
    }

    function getLiquidityInRanges(
        PoolId poolId,
        int24 centerTick,
        int24 halfRangeWidthInTickSpaces,
        IPoolManager poolManager
    )
        internal
        view
        returns (uint128 fullRangeLiquidity, uint128 narrowRangeLiquidity)
    {
        fullRangeLiquidity = poolManager
            .getPosition(poolId, address(this), MIN_TICK, MAX_TICK)
            .liquidity;

        narrowRangeLiquidity = poolManager
            .getPosition(
                poolId,
                address(this),
                centerTick - TICK_SPACING * halfRangeWidthInTickSpaces,
                centerTick + TICK_SPACING * halfRangeWidthInTickSpaces
            )
            .liquidity;
    }
}
