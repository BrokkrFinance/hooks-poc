# Proof of Concept Hooks for Uniswap V4

The following hooks were created as part of the Uniswap Foundation Grant. The purpose of the Grant was to showcase the new UniswapV4 Hooks feature and provide early feedback to the Uniswap Labs team.

## Liquidity Locking Hook

The Liquidity Locking Hook locks the liquidity into the pool for a specified amount of time.

1. In order to compensate the liquidity providers for locking their liquidity, the hook will mint and distribute rewards among the liquidity providers.
2. The more liquidity is provided the more reward token the liquidity provider is entitled to.
3. The longer time the liquidity is locked the more reward token the liquidity provider is entitled to.
4. If the liquidity provider would like to withdraw liquidity before the locking period expires, he will suffer a penalty.
5. The early withdrawl penalty is distributed evenly amongst the rest of the liquidity providers.

## Liquidity Management Hook

The Liquidity Management Hook will manage UniswapV4 ranges on behalf of the liquidity providers.

1. The liquidity provided to the hook is automatically split up into 2 ranges: the narrow and the wide range.
2. X% of the liquidity will be invested into the wide range which is currently the full Uniswap range.
3. 100-X% of the liquidity will be invested into the narrow range around the current price.
4. When the price moves as a result of a swap, the narrow range will automatically rebalances and follow the current price. This is done without involving any offchain component.

## Dynamic Fee Hook

The Dynamic Fee Hook automatically changes the swap fee based on the pool's volatility. During higher volatility periods, higher fees are charged.

1. Volume is used as a proxy for price volatility.
2. All swaps on the pool increases the aggregated volume.
3. As time goes on, the aggregated volume automatically decreases.
4. The swap fee is a function of the aggregated volume at the time of the swap.

## Combo Hook

Hook that combines the functionaility of the Liquidity Locking Hook and the Dynamic Fee Hook.
