// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {UniswapV4ERC20} from "../periphery/UniswapV4ERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

uint256 constant FIXED_POINT_SCALING = 100_0000;
uint256 constant INITIAL_LIQUIDITY = 100_000;

int24 constant MIN_TICK = -887220;
int24 constant MAX_TICK = -MIN_TICK;
int24 constant TICK_SPACING = 60;

struct CallbackData {
    address sender;
    PoolKey poolKey;
    IPoolManager.ModifyLiquidityParams[] modifyLiquidityParams;
}

struct InitParams {
    // a range width of 3 would mean that the narrow range liquidity is concentrated in a
    // (centerTick - halfRangeWidthInTickSpaces * TICK_SPACING, narrowRangeCenter + halfRangeWidthInTickSpaces * TICK_SPACING)
    // interval
    int24 halfRangeWidthInTickSpaces;
    // a rebalance width of 2 would mean the centerTick of the narrow range has to be within the interval of
    // (currentTick - halfRangeRebalanceWidthInTickSpaces * TICK_SPACING, currentTick + halfRangeRebalanceWidthInTickSpaces * TICK_SPACING)
    // and if it falls outside of that range, then rebalance is necessary
    int24 halfRangeRebalanceWidthInTickSpaces;
    // a ratio of 20 would mean the liquidity provided to the narrow range is 20 times the liquidity in the full range
    uint256 narrowToFullLiquidityRatio;
}

struct PoolInfo {
    bool hasAccruedFees;
    UniswapV4ERC20 vaultToken;
    int24 centerTick; // the center of the narrow range
    int24 halfRangeWidthInTickSpaces;
    int24 halfRangeRebalanceWidthInTickSpaces;
    uint256 narrowToFullLiquidityRatio;
    uint256 token0Balance;
    uint256 token1Balance;
}

struct AddLiquidityParams {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    uint256 vaultTokenAmount;
    address to;
    uint256 deadline;
}

struct RemoveLiquidityParams {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    uint256 vaultTokenAmount;
    uint256 deadline;
}
