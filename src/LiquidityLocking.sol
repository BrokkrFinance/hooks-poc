// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

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

uint256 constant FIXED_POINT_SCALING = 1_000_000;

contract LiquidityLocking is BaseHook, ILockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using Math for uint256;
    using SafeCast for uint128;

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();
    error TickSpacingNotDefault();
    error LiquidityDoesntMeetMinimum();
    error SenderMustBeHook();
    error ExpiredPastDeadline();
    error ExpiredPastlockedUntil();
    error ShorteninglockedUntil();
    error EarlyWithdrawal();
    error TooMuchSlippage();

    bytes internal constant ZERO_BYTES = bytes("");

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    int256 internal constant MAX_INT = type(int256).max;
    uint16 internal constant MINIMUM_LIQUIDITY = 1000;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
        bool applyEarlyWithdrawalPenalty;
    }

    struct LockingInfo {
        uint256 lockingTime;
        uint256 lockedUntil;
        uint256 liquidityShare;
    }

    struct PoolInfo {
        bool hasAccruedFees;
        UniswapV4ERC20 rewardToken;
        // reward token amount gained per liquidity provided per seconds, scaled by FIXED_POINT_SCALING
        uint256 rewardGenerationRate;
        uint256 totalLiquidityShares;
        uint24 earlyWithdrawalPenaltyPct; // scaled by FIXED_POINT_SCALING, 50000 would be 5%
        mapping(address => LockingInfo) lockingInfos;
    }

    struct InitParams {
        uint256 rewardGenerationRate;
        uint24 earlyWithdrawalPenaltyPct;
    }

    struct AddLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        uint256 lockedUntil;
    }

    struct RemoveLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 liquidity;
        uint256 deadline;
    }

    mapping(PoolId => PoolInfo) public poolInfo;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    function poolUserInfo(
        PoolId poolId,
        address user
    ) external view returns (LockingInfo memory) {
        return poolInfo[poolId].lockingInfos[user];
    }

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata data
    ) external override poolManagerOnly returns (bytes4) {
        if (key.tickSpacing != 60) revert TickSpacingNotDefault();

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
        InitParams memory initParams = abi.decode(data, (InitParams));

        PoolInfo storage poolInfoToInit = poolInfo[poolId];
        poolInfoToInit.hasAccruedFees = false;
        poolInfoToInit.rewardToken = new UniswapV4ERC20(
            tokenSymbol,
            tokenSymbol
        );
        poolInfoToInit.rewardGenerationRate = initParams.rewardGenerationRate;
        poolInfoToInit.earlyWithdrawalPenaltyPct = initParams
            .earlyWithdrawalPenaltyPct;

        return LiquidityLocking.beforeInitialize.selector;
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: true,
                afterInitialize: false,
                beforeModifyPosition: true,
                afterModifyPosition: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function addLiquidity(
        AddLiquidityParams calldata params
    ) external ensure(params.deadline) returns (uint128 liquidity) {
        if (params.lockedUntil <= block.timestamp) {
            revert ExpiredPastlockedUntil();
        }

        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        PoolInfo storage pool = poolInfo[poolId];

        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(MIN_TICK),
            TickMath.getSqrtRatioAtTick(MAX_TICK),
            params.amount0Desired,
            params.amount1Desired
        );

        if (poolLiquidity == 0 && liquidity <= MINIMUM_LIQUIDITY) {
            revert LiquidityDoesntMeetMinimum();
        }
        BalanceDelta addedDelta = modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256()
            }),
            false
        );

        pool.totalLiquidityShares += liquidity;

        if (poolLiquidity == 0) {
            // permanently lock the first MINIMUM_LIQUIDITY tokens
            liquidity -= MINIMUM_LIQUIDITY;
            LockingInfo storage zeroAddressLockingInfo = pool.lockingInfos[
                address(0)
            ];
            zeroAddressLockingInfo.lockedUntil = type(uint256).max;
            zeroAddressLockingInfo.lockingTime = block.timestamp;
            zeroAddressLockingInfo.liquidityShare = MINIMUM_LIQUIDITY;
        }

        LockingInfo storage lockingInfo = pool.lockingInfos[msg.sender];
        // lockedUntil supplied as a parameter has to be at least as far in the future as the existing lockedUntil
        if (params.lockedUntil < lockingInfo.lockedUntil) {
            revert ShorteninglockedUntil();
        }

        // 1. users can add more liquidity to their existing locked liquidity
        // 2. reward tokens are minted for the time period of [lockingTime, min(block.timestamp, lockedUntil)]
        // 3. reward tokens earned are proportional to the length of the time period above and also proportional to the locked liquidity
        uint256 tokensToMint = (pool.rewardGenerationRate *
            lockingInfo.liquidityShare *
            (Math.min(block.timestamp, lockingInfo.lockedUntil) -
                lockingInfo.lockingTime)) / FIXED_POINT_SCALING;
        if (tokensToMint != 0) {
            pool.rewardToken.mint(msg.sender, tokensToMint);
        }

        // updating the locking structure for the user after generating the reward tokens
        lockingInfo.lockingTime = block.timestamp;
        lockingInfo.lockedUntil = params.lockedUntil;
        lockingInfo.liquidityShare += liquidity;

        if (
            uint128(addedDelta.amount0()) < params.amount0Min ||
            uint128(addedDelta.amount1()) < params.amount1Min
        ) {
            revert TooMuchSlippage();
        }
    }

    function removeLiquidity(
        RemoveLiquidityParams calldata params
    ) public virtual ensure(params.deadline) returns (BalanceDelta delta) {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();

        PoolInfo storage pool = poolInfo[poolId];

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        LockingInfo storage lockingInfo = pool.lockingInfos[msg.sender];

        delta = modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(params.liquidity.toInt256())
            }),
            block.timestamp < lockingInfo.lockedUntil // penalities will be applied for early withdrawals
        );

        // 1. users can remove part of their liquidity (or all of it) either before the lockedUntil passed (penalties will be applied) or
        //    after the lockedUntil period passed (no penalties will be applied)
        // 2. rewards are minted for the time period of [lockingTime, min(block.timestamp, lockedUntil)]
        // 3. rewards earned are proportional to the length of the time period and to the locked liquidity
        uint256 newLockingTime = Math.min(
            block.timestamp,
            lockingInfo.lockedUntil
        );
        uint256 tokensToMint = (pool.rewardGenerationRate *
            lockingInfo.liquidityShare *
            (newLockingTime - lockingInfo.lockingTime)) / FIXED_POINT_SCALING;
        if (tokensToMint > 0) {
            pool.rewardToken.mint(msg.sender, tokensToMint);
        }

        lockingInfo.liquidityShare -= params.liquidity;
        if (lockingInfo.liquidityShare == 0) {
            lockingInfo.lockedUntil = 0;
            lockingInfo.lockingTime = 0;
        } else {
            // potentially setting the lockingTime to lockingInfo.lockedUntil,
            // as no more rewards should be generated after the lockedUntil passed
            lockingInfo.lockingTime = newLockingTime;
        }
        pool.totalLiquidityShares -= params.liquidity;
    }

    function modifyPosition(
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params,
        bool applyEarlyWithdrawalPenalty
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.lock(
                abi.encode(
                    CallbackData(
                        msg.sender,
                        key,
                        params,
                        applyEarlyWithdrawalPenalty
                    )
                )
            ),
            (BalanceDelta)
        );
    }

    function lockAcquired(
        bytes calldata rawData
    )
        external
        override(ILockCallback, BaseHook)
        poolManagerOnly
        returns (bytes memory)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            delta = _removeLiquidity(data.key, data.params);
            if (data.applyEarlyWithdrawalPenalty) {
                // For early withdrawals a flat percentage of penalty will be applied on the withdrawn assets (not on the full amount of assets
                // that the user locked). Assets taken as penalties will be donated to the pool.
                int128 earlyWithdrawalPenaltyPct = int128(
                    uint128(poolInfo[data.key.toId()].earlyWithdrawalPenaltyPct)
                );
                int128 token0AmountToDonate = (-delta.amount0() *
                    earlyWithdrawalPenaltyPct) /
                    int128(int256(FIXED_POINT_SCALING));
                int128 token1AmountToDonate = (-delta.amount1() *
                    earlyWithdrawalPenaltyPct) /
                    int128(int256(FIXED_POINT_SCALING));

                delta =
                    delta +
                    toBalanceDelta(token0AmountToDonate, token1AmountToDonate);
                poolManager.donate(
                    data.key,
                    uint256(uint128(token0AmountToDonate)),
                    uint256(uint128(token1AmountToDonate)),
                    ZERO_BYTES
                );
            }
            _takeDeltas(data.sender, data.key, delta);
        } else {
            delta = poolManager.modifyPosition(
                data.key,
                data.params,
                ZERO_BYTES
            );
            _settleDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    function _removeLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params
    ) internal returns (BalanceDelta delta) {
        PoolId poolId = key.toId();
        PoolInfo storage pool = poolInfo[poolId];

        if (pool.hasAccruedFees) {
            _rebalance(key);
        }

        uint256 liquidityToRemove = FullMath.mulDiv(
            uint256(-params.liquidityDelta),
            poolManager.getLiquidity(poolId),
            pool.totalLiquidityShares
        );

        params.liquidityDelta = -(liquidityToRemove.toInt256());
        delta = poolManager.modifyPosition(key, params, ZERO_BYTES);
        pool.hasAccruedFees = false;
    }

    function _settleDeltas(
        address sender,
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        _settleDelta(sender, key.currency0, uint128(delta.amount0()));
        _settleDelta(sender, key.currency1, uint128(delta.amount1()));
    }

    function _settleDelta(
        address sender,
        Currency currency,
        uint128 amount
    ) internal {
        if (currency.isNative()) {
            poolManager.settle{value: amount}(currency);
        } else {
            if (sender == address(this)) {
                currency.transfer(address(poolManager), amount);
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(
                    sender,
                    address(poolManager),
                    amount
                );
            }
            poolManager.settle(currency);
        }
    }

    function _takeDeltas(
        address sender,
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        poolManager.take(
            key.currency0,
            sender,
            uint256(uint128(-delta.amount0()))
        );
        poolManager.take(
            key.currency1,
            sender,
            uint256(uint128(-delta.amount1()))
        );
    }

    function _rebalance(PoolKey memory key) public {
        PoolId poolId = key.toId();
        BalanceDelta balanceDelta = poolManager.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(poolManager.getLiquidity(poolId).toInt256())
            }),
            ZERO_BYTES
        );

        uint160 newSqrtPriceX96 = (FixedPointMathLib.sqrt(
            FullMath.mulDiv(
                uint128(-balanceDelta.amount1()),
                FixedPoint96.Q96,
                uint128(-balanceDelta.amount0())
            )
        ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)).toUint160();

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

        poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                amountSpecified: MAX_INT,
                sqrtPriceLimitX96: newSqrtPriceX96
            }),
            ZERO_BYTES
        );

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            newSqrtPriceX96,
            TickMath.getSqrtRatioAtTick(MIN_TICK),
            TickMath.getSqrtRatioAtTick(MAX_TICK),
            uint256(uint128(-balanceDelta.amount0())),
            uint256(uint128(-balanceDelta.amount1()))
        );

        BalanceDelta balanceDeltaAfter = poolManager.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256()
            }),
            ZERO_BYTES
        );

        // Donate any "dust" from the sqrtRatio change as fees
        uint128 donateAmount0 = uint128(
            -balanceDelta.amount0() - balanceDeltaAfter.amount0()
        );
        uint128 donateAmount1 = uint128(
            -balanceDelta.amount1() - balanceDeltaAfter.amount1()
        );

        poolManager.donate(key, donateAmount0, donateAmount1, ZERO_BYTES);
    }

    function beforeModifyPosition(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyPositionParams calldata,
        bytes calldata
    ) external view override poolManagerOnly returns (bytes4) {
        if (sender != address(this)) revert SenderMustBeHook();

        return LiquidityLocking.beforeModifyPosition.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();

        if (!poolInfo[poolId].hasAccruedFees) {
            PoolInfo storage pool = poolInfo[poolId];
            pool.hasAccruedFees = true;
        }

        return IHooks.beforeSwap.selector;
    }
}
