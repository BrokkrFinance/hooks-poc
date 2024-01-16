// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Utils} from "../utils/Utils.sol";
import {BaseHookNoState} from "../utils/BaseHookNoState.sol";
import {LiquidityManagerLib} from "./LiquidityManagerLib.sol";
import {CallbackData, InitParams, PoolInfo, AddLiquidityParams, RemoveLiquidityParams, MIN_TICK, MAX_TICK, TICK_SPACING, FIXED_POINT_SCALING, INITIAL_LIQUIDITY} from "./LiquidityManagerStructs.sol";

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "@uniswap/periphery-next/contracts/BaseHook.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/contracts/libraries/FixedPoint96.sol";

import {UniswapV4ERC20} from "@uniswap/periphery-next/contracts/libraries/UniswapV4ERC20.sol";
import {LiquidityAmounts} from "@uniswap/periphery-next/contracts/libraries/LiquidityAmounts.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
   The LiquidtyManagement proof of concept (PoC) hook manages assets that are deployed on it. The hook divedes the deposited
   assets and use X percent of them to provide liquidity on the full range and uses 100-X percent
   as a narrow range liquidity around the current price. If the price of the pool moves, the narrow range liquidity might be
   automatically rebalanced to follow the new pool price. As it was implemented as a PoC, it has several limitations.

   - Only pools with 18 digits ERC20 tokens are allowed, native tokens are not supported.
   - Minting for others then the message sender is not implemented.
   - Slippage protection is not implemented.
   - The PoC is susceptible to sandwich attacks, as it moves the assets in the narrow range in one transaction.
   - Tick spacing of the pool is fixed at 60.
   - Although the liquidity ratio between the narrow and full range (specified by narrowToFullLiquidityRatio parameter)
     is kept during the first deposits to the pool, the ratio might change naturally as fees are collected and the narrow range moves.
     In the PoC we don't aim to bring back the ratio of narrow to full range, and let it diverge over time.
   - The condition when the price is reaching the extreme ends of uniswap price range is not handled.
   - More liquidity management specific events need to be emitted.
   - Reentrancy protection is not implemented.
   - More unit tests need to be written.
*/

contract LiquidityManager is Ownable, BaseHookNoState {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using SafeERC20 for IERC20;

    event LiquidityRebalanced(
        int24 newCenterTick, // the new center of the narrow range after rebalancing
        int24 oldCenterTick, // the old center of the narrow range, before the swap happened
        int24 oldPriceTick // the price tick after the swap which swap triggered the rebalance
    );

    error PoolNotInitialized();
    error InsufficientInitialLiquidity();
    error SenderMustBeHook();
    error ExpiredPastDeadline();

    bytes internal constant ZERO_BYTES = bytes("");

    // prevents multiple rebalances in the same transaction
    bool rebalanceInProgress;

    IPoolManager public immutable poolManager;

    mapping(PoolId => PoolInfo) public poolInfos;

    constructor(IPoolManager _poolManager, address owner) Ownable(owner) {
        poolManager = _poolManager;
    }

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        bytes calldata data
    ) external override poolManagerOnly(poolManager) returns (bytes4) {
        InitParams memory initParams = abi.decode(data, (InitParams));
        PoolId poolId = key.toId();

        string memory tokenSymbol = string(
            abi.encodePacked(
                "UniV4",
                "-",
                IERC20Metadata(Currency.unwrap(key.currency0)).symbol(),
                "-",
                IERC20Metadata(Currency.unwrap(key.currency1)).symbol(),
                "-",
                Strings.toString(uint256(key.fee))
            )
        );
        UniswapV4ERC20 poolToken = new UniswapV4ERC20(tokenSymbol, tokenSymbol);

        poolInfos[poolId] = PoolInfo({
            hasAccruedFees: false,
            vaultToken: poolToken,
            centerTick: LiquidityManagerLib.getAlignedTickFromSqrtPriceQ96(
                sqrtPriceX96,
                TICK_SPACING
            ),
            halfRangeWidthInTickSpaces: initParams.halfRangeWidthInTickSpaces,
            halfRangeRebalanceWidthInTickSpaces: initParams
                .halfRangeRebalanceWidthInTickSpaces,
            narrowToFullLiquidityRatio: initParams.narrowToFullLiquidityRatio,
            token0Balance: 0,
            token1Balance: 0
        });

        return IHooks.beforeInitialize.selector;
    }

    function addLiquidity(
        AddLiquidityParams calldata params
    ) external ensure(params.deadline) {
        PoolKey memory poolKey = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });

        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        PoolInfo storage poolInfo = poolInfos[poolId];

        uint256 vaultTokenTotalSupply = poolInfo.vaultToken.totalSupply();
        if (vaultTokenTotalSupply == 0) {
            // first time deposits are made to the pool through the hook
            if (params.vaultTokenAmount != INITIAL_LIQUIDITY) {
                revert InsufficientInitialLiquidity();
            }

            uint256 fullRangeLiquidity = FullMath.mulDivRoundingUp(
                INITIAL_LIQUIDITY,
                FIXED_POINT_SCALING,
                (poolInfo.narrowToFullLiquidityRatio + FIXED_POINT_SCALING)
            );

            uint256 narrowRangeLiquidity = INITIAL_LIQUIDITY -
                fullRangeLiquidity;

            // add liquidity to the pool based on the liquidity ratio specified by the narrowToFullLiquidityRatio parameter
            modifyPosition(
                poolKey,
                LiquidityManagerLib.createModifyPositionParams(
                    fullRangeLiquidity.toInt256(),
                    narrowRangeLiquidity.toInt256(),
                    poolInfo
                )
            );

            poolInfo.vaultToken.mint(address(0), INITIAL_LIQUIDITY);
        } else {
            (
                uint128 fullRangeLiquidity,
                uint128 narrowRangeLiquidity
            ) = getLiquidityInRanges(
                    poolId,
                    poolInfo.centerTick,
                    poolInfo.halfRangeWidthInTickSpaces
                );

            // add liquidity to the pool while respecting the existing asset ratio of the assets that are managed by the hook
            modifyPosition(
                poolKey,
                LiquidityManagerLib.createModifyPositionParams(
                    FullMath
                        .mulDivRoundingUp(
                            fullRangeLiquidity,
                            params.vaultTokenAmount,
                            vaultTokenTotalSupply
                        )
                        .toInt256(),
                    int256(
                        FullMath
                            .mulDivRoundingUp(
                                narrowRangeLiquidity,
                                params.vaultTokenAmount,
                                vaultTokenTotalSupply
                            )
                            .toInt256()
                    ),
                    poolInfo
                )
            );

            // transferring extra token0 and token1 from the user to match the existing
            // poolInfo.token0Balance and poolInfo.token1Balance balances which variables store the uninvested
            // token holdings
            uint256 expectedToken0BalanceIncrease = FullMath.mulDivRoundingUp(
                poolInfo.token0Balance,
                params.vaultTokenAmount,
                vaultTokenTotalSupply
            );
            if (expectedToken0BalanceIncrease != 0) {
                IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                    msg.sender,
                    address(poolManager),
                    expectedToken0BalanceIncrease
                );
                poolInfo.token0Balance += expectedToken0BalanceIncrease;
            }

            uint256 expectedToken1BalanceIncrease = FullMath.mulDivRoundingUp(
                poolInfo.token1Balance,
                params.vaultTokenAmount,
                vaultTokenTotalSupply
            );
            if (expectedToken1BalanceIncrease != 0) {
                IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                    msg.sender,
                    address(poolManager),
                    expectedToken1BalanceIncrease
                );
                poolInfo.token1Balance += expectedToken1BalanceIncrease;
            }

            poolInfo.vaultToken.mint(params.to, params.vaultTokenAmount);
        }
    }

    function removeLiquidity(
        RemoveLiquidityParams calldata params
    ) public virtual ensure(params.deadline) {
        PoolKey memory poolKey = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
        PoolId poolId = poolKey.toId();
        PoolInfo storage poolInfo = poolInfos[poolId];
        uint256 vaultTokenTotalSupply = poolInfo.vaultToken.totalSupply();

        (
            uint128 fullRangeLiquidity,
            uint128 narrowRangeLiquidity
        ) = getLiquidityInRanges(
                poolId,
                poolInfo.centerTick,
                poolInfo.halfRangeWidthInTickSpaces
            );

        modifyPosition(
            poolKey,
            LiquidityManagerLib.createModifyPositionParams(
                -FullMath
                    .mulDivRoundingUp(
                        fullRangeLiquidity,
                        params.vaultTokenAmount,
                        vaultTokenTotalSupply
                    )
                    .toInt256(),
                -FullMath
                    .mulDivRoundingUp(
                        narrowRangeLiquidity,
                        params.vaultTokenAmount,
                        vaultTokenTotalSupply
                    )
                    .toInt256(),
                poolInfo
            )
        );

        // transferring extra token0 and token1 to the user from the uninvested balance (proportionally to the tokens burnt)
        uint256 expectedToken0BalanceDecrease = FullMath.mulDivRoundingUp(
            poolInfo.token0Balance,
            params.vaultTokenAmount,
            vaultTokenTotalSupply
        );
        if (expectedToken0BalanceDecrease != 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(
                msg.sender,
                expectedToken0BalanceDecrease
            );
            poolInfo.token0Balance -= expectedToken0BalanceDecrease;
        }

        uint256 expectedToken1BalanceDecrease = FullMath.mulDivRoundingUp(
            poolInfo.token1Balance,
            params.vaultTokenAmount,
            vaultTokenTotalSupply
        );
        if (expectedToken1BalanceDecrease != 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(
                msg.sender,
                expectedToken1BalanceDecrease
            );
            poolInfo.token1Balance -= expectedToken1BalanceDecrease;
        }

        poolInfo.vaultToken.burn(msg.sender, params.vaultTokenAmount);
    }

    function modifyLiquidityCallback(
        CallbackData memory callbackData
    ) internal returns (BalanceDelta delta) {
        collectFees(callbackData.poolKey);
        uint256 modifyPositionParamsLength = callbackData
            .modifyPositionParams
            .length;
        for (uint256 i; i < modifyPositionParamsLength; i++) {
            delta =
                delta +
                poolManager.modifyPosition(
                    callbackData.poolKey,
                    callbackData.modifyPositionParams[i],
                    ZERO_BYTES
                );
        }

        LiquidityManagerLib.handleDeltas(
            callbackData.sender,
            callbackData.poolKey,
            delta,
            poolManager
        );
    }

    /* Rebalance can be necessary if any of the following 3 condition is satisfied
       1. The current price of the pool drifted too far from center of the narrow range liquidity.
       2. The uninvested token balances on the hook became sufficiently large due to either fees collected or inaccurate rebalancing.
       3. The manager of the hook forces rebalancing.

       Rebalancing for condition 1 and 2 can happen after each swap.
    */
    function isRebalanceNecessary(
        PoolKey memory poolKey,
        bool forceRebalance
    ) public view returns (bool) {
        PoolId poolId = poolKey.toId();
        PoolInfo storage poolInfo = poolInfos[poolId];
        (, int24 currentTick, , ) = poolManager.getSlot0(poolId);

        bool isNarrowRangeCenterTooFar = (Utils.abs(
            currentTick - poolInfo.centerTick
        ) > uint256(int256(poolInfo.halfRangeRebalanceWidthInTickSpaces)));

        // for PoC we ignore this condition
        bool isContractTokenBalanceTooLarge = false;

        bool shouldForceRebalance = msg.sender == owner() && forceRebalance;

        return
            !rebalanceInProgress &&
            (isNarrowRangeCenterTooFar ||
                isContractTokenBalanceTooLarge ||
                shouldForceRebalance);
    }

    function rebalanceIfNecessary(
        PoolKey memory poolKey,
        bool forceRebalance
    ) public {
        PoolId poolId = poolKey.toId();
        PoolInfo storage poolInfo = poolInfos[poolId];

        // rebalance if necessary
        if (isRebalanceNecessary(poolKey, forceRebalance)) {
            rebalanceInProgress = true;
            modifyPosition(poolKey, new IPoolManager.ModifyPositionParams[](0));
            rebalanceInProgress = false;
            poolInfo.hasAccruedFees = true;
        }
    }

    struct RebalanceVars {
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        int24 newTickLower;
        int24 newTickUpper;
        uint128 narrowRangeLiquidity;
        uint256 token0Available;
        uint256 token1Available;
        uint160 sqrtPriceCurrentX96;
        int24 currentTick;
        int24 oldTick;
        BalanceDelta removeLiquidityDelta;
        BalanceDelta swapDelta;
        BalanceDelta addLiquidityDelta;
        uint256 swapAmount;
        bool zeroForOne;
    }

    /* Rebalancing is a 3 step process.

       1. Remoe all liquidity from the narrow range.
       2. Swap the sufficient amount between token0 and token1 to be able to provide maximum liquidity at the current price (this swap will change the current price)
       3. Add back as much liquidity as possible to the narrow range and keep track of all the tokens the hook was not able to invest.
    */
    function rebalanceCallback(
        CallbackData memory callbackData
    ) internal returns (BalanceDelta totalDelta) {
        collectFees(callbackData.poolKey);

        RebalanceVars memory vars;
        vars.poolId = callbackData.poolKey.toId();
        PoolInfo storage poolInfo = poolInfos[vars.poolId];

        // 1. withdraw all liquidity from the narrow range
        vars.tickLower =
            poolInfo.centerTick -
            TICK_SPACING *
            poolInfo.halfRangeWidthInTickSpaces;

        vars.tickUpper =
            poolInfo.centerTick +
            TICK_SPACING *
            poolInfo.halfRangeWidthInTickSpaces;

        vars.narrowRangeLiquidity = poolManager
            .getPosition(
                vars.poolId,
                address(this),
                vars.tickLower,
                vars.tickUpper
            )
            .liquidity;

        vars.removeLiquidityDelta = poolManager.modifyPosition(
            callbackData.poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: vars.tickLower,
                tickUpper: vars.tickUpper,
                liquidityDelta: -vars.narrowRangeLiquidity.toInt128()
            }),
            ZERO_BYTES
        );

        vars.token0Available = uint256(
            int256(poolInfo.token0Balance) - vars.removeLiquidityDelta.amount0()
        );
        vars.token1Available = uint256(
            int256(poolInfo.token1Balance) - vars.removeLiquidityDelta.amount1()
        );

        // 2. swap sufficient amount
        (vars.sqrtPriceCurrentX96, vars.oldTick, , ) = poolManager.getSlot0(
            vars.poolId
        );
        (vars.swapAmount, vars.zeroForOne) = LiquidityManagerLib
            .calculateSwapAmount(
                vars.token0Available,
                vars.token1Available,
                vars.sqrtPriceCurrentX96
            );
        vars.swapDelta = poolManager.swap(
            callbackData.poolKey,
            IPoolManager.SwapParams({
                zeroForOne: vars.zeroForOne,
                amountSpecified: int256(vars.swapAmount),
                sqrtPriceLimitX96: (vars.zeroForOne)
                    ? TickMath.MIN_SQRT_RATIO + 1
                    : TickMath.MAX_SQRT_RATIO - 1
            }),
            ZERO_BYTES
        );

        // 3. adding back liquidity to the narrow range
        (vars.sqrtPriceCurrentX96, vars.currentTick, , ) = poolManager.getSlot0(
            vars.poolId
        );

        vars.currentTick = LiquidityManagerLib.getAlignedTickFromTick(
            vars.currentTick,
            TICK_SPACING
        );

        vars.newTickLower =
            vars.currentTick -
            poolInfo.halfRangeWidthInTickSpaces *
            TICK_SPACING;

        vars.newTickUpper =
            vars.currentTick +
            poolInfo.halfRangeWidthInTickSpaces *
            TICK_SPACING;

        totalDelta = vars.removeLiquidityDelta + vars.swapDelta;

        uint128 liquidityToProvide = LiquidityAmounts.getLiquidityForAmounts(
            vars.sqrtPriceCurrentX96,
            TickMath.getSqrtRatioAtTick(vars.newTickLower),
            TickMath.getSqrtRatioAtTick(vars.newTickUpper),
            uint256(
                int256(poolInfo.token0Balance) - int256(totalDelta.amount0())
            ),
            uint256(
                int256(poolInfo.token1Balance) - int256(totalDelta.amount1())
            )
        );

        vars.addLiquidityDelta = poolManager.modifyPosition(
            callbackData.poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: vars.newTickLower,
                tickUpper: vars.newTickUpper,
                liquidityDelta: int256(int128(liquidityToProvide))
            }),
            ZERO_BYTES
        );

        totalDelta = totalDelta + vars.addLiquidityDelta;

        // updating contract variables
        emit LiquidityRebalanced(
            vars.currentTick,
            poolInfo.centerTick,
            vars.oldTick
        );

        poolInfo.centerTick = vars.currentTick;
        poolInfo.token0Balance = uint256(
            uint128(
                int128(uint128(poolInfo.token0Balance)) - totalDelta.amount0()
            )
        );
        poolInfo.token1Balance = uint256(
            uint128(
                int128(uint128(poolInfo.token1Balance)) - totalDelta.amount1()
            )
        );
        LiquidityManagerLib.handleDeltas(
            address(this),
            callbackData.poolKey,
            totalDelta,
            poolManager
        );
    }

    function modifyPosition(
        PoolKey memory key,
        IPoolManager.ModifyPositionParams[] memory params
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.lock(abi.encode(CallbackData(msg.sender, key, params))),
            (BalanceDelta)
        );
    }

    function lockAcquired(
        bytes calldata rawData
    ) external override poolManagerOnly(poolManager) returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(rawData, (CallbackData));

        BalanceDelta delta;
        if (callbackData.modifyPositionParams.length == 0) {
            delta = rebalanceCallback(callbackData);
        } else {
            delta = modifyLiquidityCallback(callbackData);
        }
        return abi.encode(delta);
    }

    // Collect fees both on the narrow and the full range, leave them uninvested until the next rebalance.
    function collectFees(PoolKey memory poolKey) public {
        PoolId poolId = poolKey.toId();
        PoolInfo storage poolInfo = poolInfos[poolId];
        if (poolInfo.hasAccruedFees) {
            BalanceDelta delta;
            IPoolManager.ModifyPositionParams[]
                memory modifyPositionParams = LiquidityManagerLib
                    .createModifyPositionParams(0, 0, poolInfo);
            uint256 modifyPositionParamsLength = modifyPositionParams.length;
            for (uint256 i; i < modifyPositionParamsLength; i++) {
                delta =
                    delta +
                    poolManager.modifyPosition(
                        poolKey,
                        modifyPositionParams[i],
                        ZERO_BYTES
                    );
            }
            poolInfo.token0Balance += uint256(uint128(-delta.amount0()));
            poolInfo.token1Balance += uint256(uint128(-delta.amount1()));
            poolInfo.hasAccruedFees = false;
            LiquidityManagerLib.handleDeltas(
                address(this),
                poolKey,
                delta,
                poolManager
            );
        }
    }

    function getLiquidityInRanges(
        PoolId poolId,
        int24 centerTick,
        int24 halfRangeWidthInTickSpaces
    )
        public
        view
        returns (uint128 fullRangeLiquidity, uint128 narrowRangeLiquidity)
    {
        return
            LiquidityManagerLib.getLiquidityInRanges(
                poolId,
                centerTick,
                halfRangeWidthInTickSpaces,
                poolManager
            );
    }

    function getAssetsInRanges(
        PoolId poolId
    )
        external
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
        PoolInfo storage poolInfo = poolInfos[poolId];

        return
            LiquidityManagerLib.getAssetsInRanges(
                poolId,
                poolManager,
                poolInfo
            );
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: true,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external virtual override poolManagerOnly(poolManager) returns (bytes4) {
        PoolId poolId = poolKey.toId();
        PoolInfo storage poolInfo = poolInfos[poolId];

        poolInfo.hasAccruedFees = true;

        rebalanceIfNecessary(poolKey, false);

        return IHooks.afterSwap.selector;
    }
}
