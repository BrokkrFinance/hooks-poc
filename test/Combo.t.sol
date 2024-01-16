// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {LiquidityLocking, FIXED_POINT_SCALING} from "../src/LiquidityLocking.sol";

import {VolumeFee, FEE_INCREASE_TOKEN1_UNIT, FEE_DECREASE_TIME_UNIT, MINIMUM_FEE, MAXIMUM_FEE} from "../src/VolumeFee.sol";
import {Combo} from "../src/Combo.sol";
import {Utils} from "../src/utils/Utils.sol";

import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {FeeLibrary} from "@uniswap/v4-core/contracts/libraries/FeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {MockERC20} from "@uniswap/v4-core/test/foundry-tests/utils/MockERC20.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {UniswapV4ERC20} from "@uniswap/periphery-next/contracts/libraries/UniswapV4ERC20.sol";
import {FixedPoint96} from "@uniswap/v4-core/contracts/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {BaseHook} from "@uniswap/periphery-next/contracts/BaseHook.sol";

import {Test, console, console2} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

contract ComboTest is Test, Deployers, GasSnapshot {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    Combo combo =
        Combo(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG |
                        Hooks.BEFORE_SWAP_FLAG |
                        Hooks.AFTER_SWAP_FLAG |
                        Hooks.BEFORE_MODIFY_POSITION_FLAG
                )
            )
        );

    using PoolIdLibrary for PoolKey;

    PoolManager poolManager;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    PoolId poolId;
    UniswapV4ERC20 rewardToken;

    PoolSwapTest swapRouter;

    uint256 constant MAX_DEADLINE = 12329839823;
    uint256 constant INITIAL_BLOCK_TIMESTAMP = 100;
    uint24 constant FEE_INCREASE_PER_TOKEN1_UNIT = 5;
    uint24 constant FEE_DECREASE_PER_TIME_UNIT = 30;
    uint24 constant INITIAL_FEE = 2000;

    int24 constant TICK_SPACING = 60;
    uint256 constant REWARD_GENERATION_RATE = 2_000_000; // 2 rewards/liquidity/second
    uint24 WITHDRAWAL_PENALTY_PCT = 10_0000; // 10%

    function setUp() public {
        vm.warp(INITIAL_BLOCK_TIMESTAMP);

        poolManager = Deployers.createFreshManager();
        deployCodeTo(
            "Combo.sol",
            abi.encode(poolManager, address(this)),
            address(combo)
        );

        // create a pool with VolumeFee hook
        (poolKey, poolId) = Utils.createPool(
            poolManager,
            IHooks(address(combo)),
            FeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            SQRT_RATIO_1_1,
            abi.encode(
                Combo.InitParamsCombo(
                    abi.encode(
                        VolumeFee.InitParams(
                            FEE_INCREASE_PER_TOKEN1_UNIT,
                            FEE_DECREASE_PER_TIME_UNIT,
                            INITIAL_FEE
                        )
                    ),
                    abi.encode(
                        LiquidityLocking.InitParamsLiquidityLocking(
                            REWARD_GENERATION_RATE,
                            WITHDRAWAL_PENALTY_PCT
                        )
                    )
                )
            )
        );
        swapRouter = new PoolSwapTest(poolManager);
        token0 = MockERC20(Currency.unwrap(poolKey.currency0));
        token1 = MockERC20(Currency.unwrap(poolKey.currency1));
        token0.mint(address(this), 1000000 ether);
        token1.mint(address(this), 1000000 ether);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        token0.approve(address(combo), type(uint256).max);
        token1.approve(address(combo), type(uint256).max);

        address charlie = makeAddr("charlie");
        vm.startPrank(charlie);
        token0.mint(charlie, 10000 ether);
        token1.mint(charlie, 10000 ether);
        token0.approve(address(combo), type(uint256).max);
        token1.approve(address(combo), type(uint256).max);
        combo.addLiquidity(
            LiquidityLocking.AddLiquidityParams(
                poolKey.currency0,
                poolKey.currency1,
                FeeLibrary.DYNAMIC_FEE_FLAG,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                MAX_DEADLINE,
                block.timestamp + 100
            )
        );
        vm.stopPrank();

        (, rewardToken, , , ) = combo.poolInfoLiquidityLocking(poolId);
    }

    struct ContractStateLiquidityLocking {
        uint256 hookBalance0;
        uint256 hookBalance1;
        uint256 managerBalance0;
        uint256 managerBalance1;
        uint256 totalLiquidityShares;
        LiquidityLocking.LockingInfo lockingInfo;
        uint256 totalRewardToken;
        uint256 userRewardToken;
    }

    function getContractStateLiquidityLocking(
        address user
    )
        private
        view
        returns (
            ContractStateLiquidityLocking memory contractStateLiquidityLocking
        )
    {
        contractStateLiquidityLocking.hookBalance0 = poolKey
            .currency0
            .balanceOf(address(this));
        contractStateLiquidityLocking.hookBalance1 = poolKey
            .currency1
            .balanceOf(address(this));
        contractStateLiquidityLocking.managerBalance0 = poolKey
            .currency0
            .balanceOf(address(poolManager));
        contractStateLiquidityLocking.managerBalance1 = poolKey
            .currency1
            .balanceOf(address(poolManager));
        (, , , contractStateLiquidityLocking.totalLiquidityShares, ) = combo
            .poolInfoLiquidityLocking(poolId);
        contractStateLiquidityLocking.lockingInfo = combo.poolUserInfo(
            poolId,
            user
        );
        contractStateLiquidityLocking.totalRewardToken = rewardToken
            .totalSupply();
        contractStateLiquidityLocking.userRewardToken = rewardToken.balanceOf(
            user
        );
    }

    struct ContractStateVolumeFee {
        uint256 token1SoFar;
        uint256 lastFeeDecreaseTime;
        uint24 currentFee;
    }

    function getContractStateVolumeFee()
        internal
        view
        returns (ContractStateVolumeFee memory contractStateVolumeFee)
    {
        (
            ,
            ,
            contractStateVolumeFee.token1SoFar,
            contractStateVolumeFee.lastFeeDecreaseTime,
            contractStateVolumeFee.currentFee
        ) = combo.poolInfos(poolId);
    }

    struct ContractState {
        ContractStateLiquidityLocking liquidityLocking;
        ContractStateVolumeFee volumeFee;
    }

    function getContractState(
        address user
    ) internal view returns (ContractState memory contractState) {
        contractState.liquidityLocking = getContractStateLiquidityLocking(user);
        contractState.volumeFee = getContractStateVolumeFee();
    }

    function swapExactTokensForTokens(
        PoolKey memory poolKeyParam,
        bool zeroForOne,
        int256 exactAmountIn
    ) private {
        swapRouter.swap(
            poolKeyParam,
            IPoolManager.SwapParams(
                zeroForOne,
                exactAmountIn,
                (zeroForOne)
                    ? TickMath.MIN_SQRT_RATIO + 1
                    : TickMath.MAX_SQRT_RATIO - 1
            ),
            PoolSwapTest.TestSettings(true, true),
            ZERO_BYTES
        );
    }

    function swapExactTokensForTokensUpToPricePoint(
        PoolKey memory poolKeyParam,
        bool zeroForOne,
        int256 exactAmountIn,
        uint160 sqrtPriceLimitX96
    ) private {
        swapRouter.swap(
            poolKeyParam,
            IPoolManager.SwapParams(
                zeroForOne,
                exactAmountIn,
                sqrtPriceLimitX96
            ),
            PoolSwapTest.TestSettings(true, true),
            ZERO_BYTES
        );
    }

    function testCombo_addLiquidityWaitForExpiryAndWithdraw() public {
        uint256 lockedUntil = INITIAL_BLOCK_TIMESTAMP + 50;
        ContractState memory contractStateBeforeAdd = getContractState(
            address(this)
        );

        // add liquidity
        combo.addLiquidity(
            LiquidityLocking.AddLiquidityParams(
                poolKey.currency0,
                poolKey.currency1,
                FeeLibrary.DYNAMIC_FEE_FLAG,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                MAX_DEADLINE,
                lockedUntil
            )
        );
        ContractState memory contractStateAfterAdd = getContractState(
            address(this)
        );

        // check state after adding liquidity

        // checking total liquidty share increase
        assertApproxEqRel(
            contractStateBeforeAdd.liquidityLocking.totalLiquidityShares +
                100e18,
            contractStateAfterAdd.liquidityLocking.totalLiquidityShares,
            1e15,
            "Total liquidity share mismatch after adding liquidity"
        );

        // checking user liquidity share increase
        assertApproxEqRel(
            contractStateBeforeAdd.liquidityLocking.lockingInfo.liquidityShare +
                100e18,
            contractStateAfterAdd.liquidityLocking.lockingInfo.liquidityShare,
            1e15,
            "User liquidity share mismatch after adding liquidity"
        );

        // checking the total supply of reward token is unchanged
        assertEq(
            contractStateBeforeAdd.liquidityLocking.totalRewardToken,
            contractStateAfterAdd.liquidityLocking.totalRewardToken,
            "Total reward token mismatch after adding liquidity"
        );

        // checking the user amount of reward token is unchanged
        assertEq(
            contractStateBeforeAdd.liquidityLocking.userRewardToken,
            contractStateAfterAdd.liquidityLocking.userRewardToken,
            "User reward token mismatch after adding liquidity"
        );

        // remove liquidity
        uint256 liquiditySharesToRemove = contractStateAfterAdd
            .liquidityLocking
            .lockingInfo
            .liquidityShare;

        vm.warp(lockedUntil + 1);
        combo.removeLiquidity(
            LiquidityLocking.RemoveLiquidityParams(
                poolKey.currency0,
                poolKey.currency1,
                FeeLibrary.DYNAMIC_FEE_FLAG,
                liquiditySharesToRemove,
                MAX_DEADLINE
            )
        );
        ContractState memory contractStateAfterRemove = getContractState(
            address(this)
        );

        // checking total liquidty share decrease
        assertApproxEqRel(
            contractStateAfterAdd.liquidityLocking.totalLiquidityShares -
                liquiditySharesToRemove,
            contractStateAfterRemove.liquidityLocking.totalLiquidityShares,
            1e15,
            "Total liquidity share mismatch after full removal"
        );

        // checking user liquidity share decrease
        assertApproxEqRel(
            contractStateAfterAdd.liquidityLocking.lockingInfo.liquidityShare -
                liquiditySharesToRemove,
            contractStateAfterRemove
                .liquidityLocking
                .lockingInfo
                .liquidityShare,
            1e15,
            "User liquidity share mismatch after full removal"
        );

        // checking the total supply of reward token increase
        assertEq(
            contractStateAfterRemove.liquidityLocking.totalRewardToken -
                contractStateAfterAdd.liquidityLocking.totalRewardToken,
            (REWARD_GENERATION_RATE *
                liquiditySharesToRemove *
                (lockedUntil - INITIAL_BLOCK_TIMESTAMP)) / FIXED_POINT_SCALING,
            "Total reward token mismatch after full removal"
        );

        // checking the user amount of reward token is the same as the cange in total supply
        assertEq(
            contractStateAfterRemove.liquidityLocking.totalRewardToken -
                contractStateAfterAdd.liquidityLocking.totalRewardToken,
            contractStateAfterRemove.liquidityLocking.userRewardToken -
                contractStateAfterAdd.liquidityLocking.userRewardToken,
            "User reward token mismatch after full removal"
        );

        // checking if the locking info is deleted
        assertEq(
            contractStateAfterRemove.liquidityLocking.lockingInfo.lockingTime,
            0,
            "Locking time is not 0 after full removal"
        );
        assertEq(
            contractStateAfterRemove.liquidityLocking.lockingInfo.lockedUntil,
            0,
            "Liquidity delta is not 0 after full removal"
        );
        assertEq(
            contractStateAfterRemove
                .liquidityLocking
                .lockingInfo
                .liquidityShare,
            0,
            "Liquidity share is not 0 after full removal"
        );
    }
}
