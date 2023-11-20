// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Utils} from "./utils/Utils.sol";

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {BaseHook} from "@uniswap/periphery-next/contracts/BaseHook.sol";
import {IDynamicFeeManager} from "@uniswap/v4-core/contracts/interfaces/IDynamicFeeManager.sol";
import {UniswapV4ERC20} from "@uniswap/periphery-next/contracts/libraries/UniswapV4ERC20.sol";
import {LiquidityAmounts} from "@uniswap/periphery-next/contracts/libraries/LiquidityAmounts.sol";
import {FixedPoint96} from "@uniswap/v4-core/contracts/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {console} from "forge-std/Test.sol";

// fee can only be increased, if the aggreageted volume is greater than FEE_INCREASE_TOKEN1_UNIT
// fee increase = aggregated volume / FEE_INCREASE_TOKEN1_UNIT * feeIncreasePerToken1Unit
uint256 constant FEE_INCREASE_TOKEN1_UNIT = 1e16;
// fee can only be decrased, if the elapsed time since the last fee decrease is greater than FEE_DECREASE_TIME_UNIT
// fee decrease = time elapsed since last decrease / FEE_DECREASE_TIME_UNIT * feeDecreasePerTimeUnit
uint256 constant FEE_DECREASE_TIME_UNIT = 100;
// the fee charged for swaps has to be always greater than MINIMUM_FEE
// represented in basis points
uint256 constant MINIMUM_FEE = 100;
// the fee charged for swaps has to be always less than MAXIMUM_FEE
// represented in basis points
uint256 constant MAXIMUM_FEE = 200000;
// fee changes will only be written to storage, if they are bigger than MINIMUM_FEE_THRESHOLD bps
uint256 constant MINIMUM_FEE_THRESHOLD = 100;
// swaps will revert, if the actual swap amount is less than SWAP_MISMATCH_PCT_THRESHOLD percent of the indicated swap amount
// this is needed to prevent swap volume manipulation, and artificially increase fees
// imagine an attacker wanting to swap 200e18 ether but set the sqrtPriceLimitX96 swap parameter to current price + 1
// without revering, he would be able to manipulate the volume, while the actual swap amount might just be 0.001 ether
// SWAP_MISMATCH_PCT_THRESHOLD is represented in fixed decimal point with precision of 4
uint256 constant SWAP_MISMATCH_PCT_THRESHOLD = 99_0000;

contract VolumeFee is BaseHook, Ownable, IDynamicFeeManager {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using Math for uint256;
    using SafeCast for uint128;

    error SWAP_AMOUNT_MISMATCH_ERROR();

    struct PoolInfo {
        // fee increase in basis points per token1 units.
        // 0.05 percent is represented as 500.
        uint24 feeIncreasePerToken1Unit;
        // fee decrease in basis point per second
        // 0.01 fee decrease per time unit is represented as 100
        uint24 feeDecreasePerTimeUnit;
        // the current aggregated swap volume for which no fee increase has yet been accounted for
        uint256 token1SoFar;
        // the last time the fee was decreased, represented in unixtime
        uint256 lastFeeDecreaseTime;
        // the current fee that is used to charge swappers
        uint24 currentFee;
    }

    struct InitParams {
        uint24 feeIncreasePerToken1Unit;
        uint24 feeDecreasePerTimeUnit;
        uint24 initialFee;
    }

    mapping(PoolId => PoolInfo) public poolInfos;

    constructor(
        IPoolManager _poolManager,
        address _owner
    ) BaseHook(_poolManager) Ownable(_owner) {}

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata data
    ) external override poolManagerOnly returns (bytes4) {
        InitParams memory initParams = abi.decode(data, (InitParams));

        PoolInfo storage poolInfo = poolInfos[key.toId()];
        poolInfo.feeIncreasePerToken1Unit = initParams.feeIncreasePerToken1Unit;
        poolInfo.feeDecreasePerTimeUnit = initParams.feeDecreasePerTimeUnit;
        poolInfo.lastFeeDecreaseTime = block.timestamp;
        poolInfo.currentFee = initParams.initialFee;

        return VolumeFee.beforeInitialize.selector;
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: true,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata
    ) external virtual override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();
        PoolInfo storage poolInfo = poolInfos[poolId];

        // decreasing fees as time goes by
        uint256 lastFeeDecreaseTime = poolInfo.lastFeeDecreaseTime;
        uint256 feeDecreasePerTimeUnit = poolInfo.feeDecreasePerTimeUnit;
        uint256 feeDecrease = ((block.timestamp - lastFeeDecreaseTime) /
            FEE_DECREASE_TIME_UNIT) * feeDecreasePerTimeUnit;
        int256 feeChange = -int256(feeDecrease);

        // increasing fees as volume increases
        uint256 token1SoFar = poolInfo.token1SoFar;
        if (swapParams.zeroForOne) {
            (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
            token1SoFar +=
                (((uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / (2 ** 96)) *
                    uint256(swapParams.amountSpecified)) /
                (2 ** 96);
        } else {
            token1SoFar += uint256(swapParams.amountSpecified);
        }
        uint256 feeIncrease = ((token1SoFar / FEE_INCREASE_TOKEN1_UNIT) *
            poolInfo.feeIncreasePerToken1Unit);
        feeChange += int256(feeIncrease);

        // changing the fees
        if (Utils.abs(feeChange) > uint256(MINIMUM_FEE_THRESHOLD)) {
            if (feeDecrease != 0) {
                poolInfo.lastFeeDecreaseTime =
                    lastFeeDecreaseTime +
                    ((feeDecrease / feeDecreasePerTimeUnit) *
                        FEE_DECREASE_TIME_UNIT);
            }

            poolInfo.token1SoFar =
                token1SoFar -
                (feeIncrease * FEE_INCREASE_TOKEN1_UNIT) /
                poolInfo.feeIncreasePerToken1Unit;

            uint256 currentFee = poolInfo.currentFee;
            uint256 newFee = uint256(
                Utils.max(
                    Utils.min(
                        int256(currentFee) + feeChange,
                        int256(MAXIMUM_FEE)
                    ),
                    int256(MINIMUM_FEE)
                )
            );

            // if the currentFee was at the MAXIMUM_FEE or MINIMUM_FEE, then even when abs(feeChange) > 0
            // the storage write might be avoided
            if (newFee != currentFee) {
                poolInfo.currentFee = uint24(newFee);
            }
        } else {
            poolInfo.token1SoFar = token1SoFar;
        }

        return VolumeFee.beforeSwap.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta balanceDelta,
        bytes calldata
    ) external virtual override poolManagerOnly returns (bytes4) {
        if (
            (uint256(
                uint128(
                    Utils.abs(
                        (swapParams.zeroForOne)
                            ? BalanceDeltaLibrary.amount0(balanceDelta)
                            : BalanceDeltaLibrary.amount1(balanceDelta)
                    )
                )
            ) * 100_0000) /
                uint256(swapParams.amountSpecified) <
            SWAP_MISMATCH_PCT_THRESHOLD
        ) {
            revert SWAP_AMOUNT_MISMATCH_ERROR();
        }
        return VolumeFee.afterSwap.selector;
    }

    function getFee(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external view returns (uint24) {
        PoolInfo storage poolInfo = poolInfos[key.toId()];
        return poolInfo.currentFee;
    }

    function setPoolParameters(
        PoolId poolId,
        uint24 feeIncreasePerToken1Unit,
        uint24 feeDecreasePerTimeUnit
    ) external onlyOwner {
        PoolInfo storage poolInfo = poolInfos[poolId];
        poolInfo.feeIncreasePerToken1Unit = feeIncreasePerToken1Unit;
        poolInfo.feeDecreasePerTimeUnit = feeDecreasePerTimeUnit;
    }
}
