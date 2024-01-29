// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {VolumeFee, FEE_INCREASE_TOKEN1_UNIT, FEE_DECREASE_TIME_UNIT, MAXIMUM_FEE} from "../src/VolumeFee.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FeeLibrary} from "@uniswap/v4-core/src/libraries/FeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Test, console, console2} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

contract VolumeFeeTest is Test, Deployers, GasSnapshot {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    VolumeFee volumeFee =
        VolumeFee(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG |
                        Hooks.BEFORE_SWAP_FLAG |
                        Hooks.AFTER_SWAP_FLAG
                )
            )
        );

    using PoolIdLibrary for PoolKey;

    MockERC20 token0;
    MockERC20 token1;

    PoolKey poolKey;
    PoolId poolId;

    PoolKey gasComparisonPoolKey;
    PoolId gasComparisonPoolId;

    uint256 constant MAX_DEADLINE = 12329839823;
    uint256 constant INITIAL_BLOCK_TIMESTAMP = 100;
    uint24 constant FEE_INCREASE_PER_TOKEN1_UNIT = 5;
    uint24 constant FEE_DECREASE_PER_TIME_UNIT = 30;
    uint24 constant INITIAL_FEE = 2000;

    function setUp() public {
        vm.warp(INITIAL_BLOCK_TIMESTAMP);

        deployFreshManagerAndRouters();
        deployCodeTo(
            "VolumeFee.sol",
            abi.encode(manager, address(this)),
            address(volumeFee)
        );
        (currency0, currency1) = deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // create a pool with VolumeFee hook
        (poolKey, poolId) = initPool(
            currency0,
            currency1,
            IHooks(volumeFee),
            FeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_RATIO_1_2,
            abi.encode(
                VolumeFee.InitParams(
                    FEE_INCREASE_PER_TOKEN1_UNIT,
                    FEE_DECREASE_PER_TIME_UNIT,
                    INITIAL_FEE
                )
            )
        );

        // providing liquidity for the pool with VolumeFee hook
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                500000 ether
            ),
            ZERO_BYTES
        );

        // create a pool without any hooks for gas comparison
        (gasComparisonPoolKey, gasComparisonPoolId) = initPool(
            currency0,
            currency1,
            IHooks(address(0)),
            3000,
            SQRT_RATIO_1_2,
            ZERO_BYTES
        );

        // providing liquidity for the pool without any hooks
        modifyLiquidityRouter.modifyLiquidity(
            gasComparisonPoolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                500000 ether
            ),
            ZERO_BYTES
        );
    }

    struct ContractState {
        uint256 token1SoFar;
        uint256 lastFeeDecreaseTime;
        uint24 currentFee;
    }

    function getContractState()
        internal
        view
        returns (ContractState memory contractState)
    {
        (
            ,
            ,
            contractState.token1SoFar,
            contractState.lastFeeDecreaseTime,
            contractState.currentFee
        ) = volumeFee.poolInfos(poolId);
    }

    function swapExactTokensForTokens(
        PoolKey memory poolKey_,
        bool zeroForOne,
        int256 exactAmountIn,
        string memory testName
    ) private {
        snapStart(testName);
        swapRouter.swap(
            poolKey_,
            IPoolManager.SwapParams(
                zeroForOne,
                exactAmountIn,
                (zeroForOne)
                    ? TickMath.MIN_SQRT_RATIO + 1
                    : TickMath.MAX_SQRT_RATIO - 1
            ),
            PoolSwapTest.TestSettings(true, true, false),
            ZERO_BYTES
        );
        snapEnd();
    }

    function swapExactTokensForTokensUpToPricePoint(
        bool zeroForOne,
        int256 exactAmountIn,
        uint160 sqrtPriceLimitX96,
        string memory testName
    ) private {
        snapStart(testName);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams(
                zeroForOne,
                exactAmountIn,
                sqrtPriceLimitX96
            ),
            PoolSwapTest.TestSettings(true, true, false),
            ZERO_BYTES
        );
        snapEnd();
    }

    function checkState(
        ContractState memory expectedContractState,
        string memory message
    ) private {
        ContractState memory actualContractState = getContractState();

        assertEq(
            actualContractState.token1SoFar,
            expectedContractState.token1SoFar,
            string.concat("token1SoFarMismatch", message)
        );
        assertEq(
            actualContractState.lastFeeDecreaseTime,
            expectedContractState.lastFeeDecreaseTime,
            string.concat("lastFeeDecreaseTime", message)
        );
        assertEq(
            actualContractState.currentFee,
            expectedContractState.currentFee,
            string.concat("currentFee", message)
        );
    }

    function testVolumeFee_feeIncreaseTriggeredImmediatelySwapToken0() public {
        uint256 amountToSwap = 2 ether;
        swapExactTokensForTokens(
            poolKey,
            true,
            int256(amountToSwap),
            "testVolumeFee_feeIncreaseTriggeredImmediatelySwapToken0"
        );
        checkState(
            ContractState({
                token1SoFar: FEE_INCREASE_TOKEN1_UNIT - 1,
                lastFeeDecreaseTime: INITIAL_BLOCK_TIMESTAMP,
                currentFee: INITIAL_FEE +
                    uint24(
                        ((amountToSwap / 2 - 1) / FEE_INCREASE_TOKEN1_UNIT) *
                            FEE_INCREASE_PER_TOKEN1_UNIT
                    )
            }),
            ""
        );
    }

    function testVolumeFee_feeIncreaseTriggeredImmediatelySwapToken1() public {
        uint256 amountToSwap = 1 ether;
        swapExactTokensForTokens(
            poolKey,
            false,
            int256(amountToSwap),
            "testVolumeFee_feeIncreaseTriggeredImmediatelySwapToken1"
        );
        checkState(
            ContractState({
                token1SoFar: 0,
                lastFeeDecreaseTime: INITIAL_BLOCK_TIMESTAMP,
                currentFee: INITIAL_FEE +
                    uint24(
                        (FEE_INCREASE_PER_TOKEN1_UNIT * amountToSwap) /
                            FEE_INCREASE_TOKEN1_UNIT
                    )
            }),
            ""
        );
    }

    // attacker tries to manipulate volume by only swapping up to next price point
    function testVolumeFee_feeIncreaseTriggeredImmediatelySwapToken0WithVolumeManipulation()
        public
    {
        uint256 amountToSwap = 2 ether;

        vm.expectRevert(VolumeFee.SWAP_AMOUNT_MISMATCH_ERROR.selector);
        swapExactTokensForTokensUpToPricePoint(
            true,
            int256(amountToSwap),
            (FixedPointMathLib.sqrt(FixedPoint96.Q96 ** 2 / 2) - 1).toUint160(),
            "testVolumeFee_feeIncreaseTriggeredImmediatelySwapToken0WithVolumeManipulation"
        );
        checkState(
            ContractState({
                token1SoFar: 0,
                lastFeeDecreaseTime: INITIAL_BLOCK_TIMESTAMP,
                currentFee: INITIAL_FEE
            }),
            ""
        );
    }

    // attacker tries to manipulate volume by only swapping up to next price point
    function testVolumeFee_feeIncreaseTriggeredImmediatelySwapToken1WithVolumeManipulation()
        public
    {
        uint256 amountToSwap = 1 ether;

        vm.expectRevert(VolumeFee.SWAP_AMOUNT_MISMATCH_ERROR.selector);
        swapExactTokensForTokensUpToPricePoint(
            false,
            int256(amountToSwap),
            (FixedPointMathLib.sqrt(FixedPoint96.Q96 ** 2 / 2) + 1).toUint160(),
            "testVolumeFee_feeIncreaseTriggeredImmediatelySwapToken1WithVolumeManipulation"
        );
        checkState(
            ContractState({
                token1SoFar: 0,
                lastFeeDecreaseTime: INITIAL_BLOCK_TIMESTAMP,
                currentFee: INITIAL_FEE
            }),
            ""
        );
    }

    function testVolumeFee_feeIncreaseTriggeredForSecondSwapToken0GasComparison()
        public
    {
        uint256 amountToSwap = 0.36 ether;
        swapExactTokensForTokens(
            gasComparisonPoolKey,
            true,
            int256(amountToSwap),
            "testVolumeFee_feeIncreaseTriggeredForSecondSwapToken0GasComparisonFirst"
        );

        uint256 amountToSwapSecondTime = 0.08 ether;
        swapExactTokensForTokens(
            gasComparisonPoolKey,
            true,
            int256(amountToSwapSecondTime),
            "testVolumeFee_feeIncreaseTriggeredForSecondSwapToken0GasComparisonSecond"
        );
    }

    function testVolumeFee_feeIncreaseTriggeredForSecondSwapToken0() public {
        uint256 amountToSwap = 0.36 ether;
        swapExactTokensForTokens(
            poolKey,
            true,
            int256(amountToSwap),
            "testVolumeFee_feeIncreaseTriggeredForSecondSwapToken0First"
        );
        checkState(
            ContractState({
                token1SoFar: amountToSwap / 2 - 1,
                lastFeeDecreaseTime: INITIAL_BLOCK_TIMESTAMP,
                currentFee: INITIAL_FEE
            }),
            ""
        );

        uint256 amountToSwapSecondTime = 0.08 ether;
        swapExactTokensForTokens(
            poolKey,
            true,
            int256(amountToSwapSecondTime),
            "testVolumeFee_feeIncreaseTriggeredForSecondSwapToken0Second"
        );
        checkState(
            ContractState({
                token1SoFar: 9999959352139083,
                lastFeeDecreaseTime: INITIAL_BLOCK_TIMESTAMP,
                currentFee: INITIAL_FEE +
                    uint24(
                        (((amountToSwap + amountToSwapSecondTime) / 2 - 1) /
                            FEE_INCREASE_TOKEN1_UNIT) *
                            FEE_INCREASE_PER_TOKEN1_UNIT
                    )
            }),
            ""
        );
    }

    function testVolumeFee_feeIncreaseTriggeredForSecondSwapToken1() public {
        // increases the fee by 90bps
        uint256 amountToSwap = 0.18 ether;
        swapExactTokensForTokens(
            poolKey,
            false,
            int256(amountToSwap),
            "testVolumeFee_feeIncreaseTriggeredForSecondSwapToken1Frist"
        );
        checkState(
            ContractState({
                token1SoFar: amountToSwap,
                lastFeeDecreaseTime: INITIAL_BLOCK_TIMESTAMP,
                currentFee: INITIAL_FEE
            }),
            ""
        );

        uint256 amountToSwapSecondTime = 0.03 ether;
        swapExactTokensForTokens(
            poolKey,
            false,
            int256(amountToSwapSecondTime),
            "testVolumeFee_feeIncreaseTriggeredForSecondSwapToken1Second"
        );
        checkState(
            ContractState({
                token1SoFar: 0,
                lastFeeDecreaseTime: INITIAL_BLOCK_TIMESTAMP,
                currentFee: INITIAL_FEE +
                    uint24(
                        ((amountToSwap + amountToSwapSecondTime) /
                            FEE_INCREASE_TOKEN1_UNIT) *
                            FEE_INCREASE_PER_TOKEN1_UNIT
                    )
            }),
            ""
        );
    }

    function testVolumeFee_feeIncreaseTriggeredByTime() public {
        uint256 units_to_decrease_by = 4;
        uint256 spillover_time = 5;
        uint256 WARP_TIME = INITIAL_BLOCK_TIMESTAMP +
            FEE_DECREASE_TIME_UNIT *
            units_to_decrease_by +
            spillover_time;

        vm.warp(WARP_TIME);

        uint256 amountToSwap = 100 wei;
        swapExactTokensForTokens(
            poolKey,
            false,
            int256(amountToSwap),
            "testVolumeFee_feeIncreaseTriggeredByTime"
        );
        checkState(
            ContractState({
                token1SoFar: amountToSwap,
                lastFeeDecreaseTime: WARP_TIME - spillover_time,
                currentFee: uint24(
                    INITIAL_FEE -
                        ((WARP_TIME - INITIAL_BLOCK_TIMESTAMP) /
                            FEE_DECREASE_TIME_UNIT) *
                        FEE_DECREASE_PER_TIME_UNIT
                )
            }),
            ""
        );
    }

    function testVolumeFee_feeIncreaseTriggeredByTimeForSecondSwap() public {
        uint256 units_to_decrease_by1 = 3;
        uint256 spillover_time1 = 5;
        uint256 WARP_TIME1 = INITIAL_BLOCK_TIMESTAMP +
            FEE_DECREASE_TIME_UNIT *
            units_to_decrease_by1 +
            spillover_time1;

        uint256 units_to_decrease_by2 = 2;
        uint256 spillover_time2 = 6;
        uint256 WARP_TIME2 = WARP_TIME1 +
            FEE_DECREASE_TIME_UNIT *
            units_to_decrease_by2 +
            spillover_time2;

        vm.warp(WARP_TIME1);

        uint256 amountToSwap = 100 wei;
        swapExactTokensForTokens(
            poolKey,
            false,
            int256(amountToSwap),
            "testVolumeFee_feeIncreaseTriggeredByTimeForSecondSwapFirst"
        );
        checkState(
            ContractState({
                token1SoFar: amountToSwap,
                lastFeeDecreaseTime: INITIAL_BLOCK_TIMESTAMP,
                currentFee: INITIAL_FEE
            }),
            ""
        );

        vm.warp(WARP_TIME2);

        swapExactTokensForTokens(
            poolKey,
            false,
            int256(amountToSwap),
            "testVolumeFee_feeIncreaseTriggeredByTimeForSecondSwapSecond"
        );
        checkState(
            ContractState({
                token1SoFar: amountToSwap * 2,
                lastFeeDecreaseTime: WARP_TIME2 -
                    spillover_time1 -
                    spillover_time2,
                currentFee: uint24(
                    INITIAL_FEE -
                        ((WARP_TIME2 - INITIAL_BLOCK_TIMESTAMP) /
                            FEE_DECREASE_TIME_UNIT) *
                        FEE_DECREASE_PER_TIME_UNIT
                )
            }),
            ""
        );
    }

    function testVolumeFee_feeIncreaseMaximumFeeReached() public {
        uint256 amountToSwap = (MAXIMUM_FEE * 1e18) * 2;
        swapExactTokensForTokens(
            poolKey,
            false,
            int256(amountToSwap),
            "testVolumeFee_feeIncreaseMaximumFeeReached"
        );
        checkState(
            ContractState({
                token1SoFar: 0,
                lastFeeDecreaseTime: INITIAL_BLOCK_TIMESTAMP,
                currentFee: uint24(MAXIMUM_FEE)
            }),
            ""
        );
    }

    function testVolumeFee_feeIncreaseAndDecreaseAtSameSwap() public {
        uint256 units_to_decrease_by = 10;
        uint256 spillover_time = 5;
        uint256 WARP_TIME = INITIAL_BLOCK_TIMESTAMP +
            FEE_DECREASE_TIME_UNIT *
            units_to_decrease_by +
            spillover_time;

        vm.warp(WARP_TIME);

        uint256 amountToSwap = 0.2 ether;
        swapExactTokensForTokens(
            poolKey,
            false,
            int256(amountToSwap),
            "testVolumeFee_feeIncreaseAndDecreaseAtSameSwap"
        );
        checkState(
            ContractState({
                token1SoFar: amountToSwap -
                    (amountToSwap / FEE_INCREASE_TOKEN1_UNIT) *
                    FEE_INCREASE_TOKEN1_UNIT,
                lastFeeDecreaseTime: WARP_TIME - spillover_time,
                currentFee: uint24(
                    INITIAL_FEE -
                        (((WARP_TIME - INITIAL_BLOCK_TIMESTAMP) /
                            FEE_DECREASE_TIME_UNIT) *
                            FEE_DECREASE_PER_TIME_UNIT) +
                        ((amountToSwap) / FEE_INCREASE_TOKEN1_UNIT) *
                        FEE_INCREASE_PER_TOKEN1_UNIT
                )
            }),
            ""
        );
    }
}
