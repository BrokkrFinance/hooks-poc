// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Utils} from "./utils/Utils.sol";
import {BaseHook} from "./utils/BaseHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IDynamicFeeManager} from "@uniswap/v4-core/src/interfaces/IDynamicFeeManager.sol";
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

contract VolumeFee is Ownable, IDynamicFeeManager, BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
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

    IPoolManager public immutable poolManager;

    mapping(PoolId => PoolInfo) public poolInfos;

    bool internal skipBeforeAfterHooks;

    constructor(IPoolManager _poolManager, address _owner) Ownable(_owner) {
        poolManager = _poolManager;
    }

    modifier poolManagerOnly() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes memory data
    ) public virtual override poolManagerOnly returns (bytes4) {
        InitParams memory initParams = abi.decode(data, (InitParams));

        PoolInfo storage poolInfo = poolInfos[key.toId()];
        poolInfo.feeIncreasePerToken1Unit = initParams.feeIncreasePerToken1Unit;
        poolInfo.feeDecreasePerTimeUnit = initParams.feeDecreasePerTimeUnit;
        poolInfo.lastFeeDecreaseTime = block.timestamp;
        poolInfo.currentFee = initParams.initialFee;

        return IHooks.beforeInitialize.selector;
    }

    function getHooksPermissions()
        public
        pure
        virtual
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
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

    struct BeforeSwapLocals {
        PoolId poolId;
        uint256 lastFeeDecreaseTime;
        uint256 feeDecreasePerTimeUnit;
        uint256 feeDecrease;
        int256 feeChange;
        uint256 token1SoFar;
        uint256 feeIncrease;
        uint256 currentFee;
        uint256 newFee;
    }

    function beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata
    ) public virtual override poolManagerOnly returns (bytes4) {
        if (skipBeforeAfterHooks) return IHooks.beforeSwap.selector;

        BeforeSwapLocals memory beforeSwapLocals;

        beforeSwapLocals.poolId = poolKey.toId();
        PoolInfo storage poolInfo = poolInfos[beforeSwapLocals.poolId];

        // decreasing fees as time goes by
        beforeSwapLocals.lastFeeDecreaseTime = poolInfo.lastFeeDecreaseTime;
        beforeSwapLocals.feeDecreasePerTimeUnit = poolInfo
            .feeDecreasePerTimeUnit;
        beforeSwapLocals.feeDecrease =
            ((block.timestamp - beforeSwapLocals.lastFeeDecreaseTime) /
                FEE_DECREASE_TIME_UNIT) *
            beforeSwapLocals.feeDecreasePerTimeUnit;
        beforeSwapLocals.feeChange = -int256(beforeSwapLocals.feeDecrease);

        // increasing fees as volume increases
        beforeSwapLocals.token1SoFar = poolInfo.token1SoFar;
        if (swapParams.zeroForOne) {
            (uint160 sqrtPriceX96, , ) = poolManager.getSlot0(
                beforeSwapLocals.poolId
            );
            beforeSwapLocals.token1SoFar +=
                (((uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / (2 ** 96)) *
                    uint256(swapParams.amountSpecified)) /
                (2 ** 96);
        } else {
            beforeSwapLocals.token1SoFar += uint256(swapParams.amountSpecified);
        }
        beforeSwapLocals.feeIncrease = ((beforeSwapLocals.token1SoFar /
            FEE_INCREASE_TOKEN1_UNIT) * poolInfo.feeIncreasePerToken1Unit);
        beforeSwapLocals.feeChange += int256(beforeSwapLocals.feeIncrease);

        // changing the fees
        if (
            Utils.abs(beforeSwapLocals.feeChange) >
            uint256(MINIMUM_FEE_THRESHOLD)
        ) {
            if (beforeSwapLocals.feeDecrease != 0) {
                poolInfo.lastFeeDecreaseTime =
                    beforeSwapLocals.lastFeeDecreaseTime +
                    ((beforeSwapLocals.feeDecrease /
                        beforeSwapLocals.feeDecreasePerTimeUnit) *
                        FEE_DECREASE_TIME_UNIT);
            }
            poolInfo.token1SoFar =
                beforeSwapLocals.token1SoFar -
                (beforeSwapLocals.feeIncrease * FEE_INCREASE_TOKEN1_UNIT) /
                poolInfo.feeIncreasePerToken1Unit;

            beforeSwapLocals.currentFee = poolInfo.currentFee;
            beforeSwapLocals.newFee = uint256(
                Utils.max(
                    Utils.min(
                        int256(beforeSwapLocals.currentFee) +
                            beforeSwapLocals.feeChange,
                        int256(MAXIMUM_FEE)
                    ),
                    int256(MINIMUM_FEE)
                )
            );

            // if the currentFee was at the MAXIMUM_FEE or MINIMUM_FEE, then even when abs(feeChange) > 0
            // the storage write might be avoided
            if (beforeSwapLocals.newFee != beforeSwapLocals.currentFee) {
                poolInfo.currentFee = uint24(beforeSwapLocals.newFee);
                poolManager.updateDynamicSwapFee(poolKey);
            }
        } else {
            poolInfo.token1SoFar = beforeSwapLocals.token1SoFar;
        }
        return IHooks.beforeSwap.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta balanceDelta,
        bytes calldata
    ) public virtual override poolManagerOnly returns (bytes4) {
        if (skipBeforeAfterHooks) return IHooks.afterSwap.selector;

        // see the comments for SWAP_MISMATCH_PCT_THRESHOLD
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
        return IHooks.afterSwap.selector;
    }

    function getFee(
        address,
        PoolKey calldata key
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
