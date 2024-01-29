// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {LiquidityManager} from "../src/liquidityManager/LiquidityManager.sol";
import {InitParams, PoolInfo, AddLiquidityParams, RemoveLiquidityParams, FIXED_POINT_SCALING, INITIAL_LIQUIDITY} from "../src/liquidityManager/LiquidityManagerStructs.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {Test, console, console2} from "forge-std/Test.sol";

contract LiquidtyManagementTest is Deployers, Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LiquidityManager liquidityManager =
        LiquidityManager(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG |
                        Hooks.AFTER_SWAP_FLAG |
                        Hooks.ACCESS_LOCK_FLAG
                )
            )
        );

    using PoolIdLibrary for PoolKey;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    PoolId poolId;

    uint256 constant MAX_DEADLINE = 12329839823;

    event LiquidityRebalanced(
        int24 newCenterTick,
        int24 oldCenterTick,
        int24 oldPriceTick
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        deployCodeTo(
            "LiquidityManager.sol",
            abi.encode(manager, address(this)),
            address(liquidityManager)
        );

        (currency0, currency1) = deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));
        token0.approve(address(liquidityManager), type(uint256).max);
        token1.approve(address(liquidityManager), type(uint256).max);

        // create a pool with LiquidityManager hook
        (poolKey, poolId) = initPool(
            currency0,
            currency1,
            IHooks(liquidityManager),
            3000,
            SQRT_RATIO_1_1,
            abi.encode(InitParams(12, 5, 20 * FIXED_POINT_SCALING))
        );

        address charlie = makeAddr("charlie");
        vm.startPrank(charlie);
        token0.mint(charlie, 100000 ether);
        token1.mint(charlie, 100000 ether);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(liquidityManager), type(uint256).max);
        token1.approve(address(liquidityManager), type(uint256).max);

        // provide initial liquidity through the liquidityManager
        liquidityManager.addLiquidity(
            AddLiquidityParams({
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                fee: poolKey.fee,
                vaultTokenAmount: INITIAL_LIQUIDITY,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );

        // provide more liquidity through the liquidityManager
        liquidityManager.addLiquidity(
            AddLiquidityParams({
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                fee: poolKey.fee,
                vaultTokenAmount: 1 ether,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );

        // provide liquidty to the full range through a router contract
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                95240000000000000
            ),
            ZERO_BYTES
        );

        vm.stopPrank();
    }

    struct ContractState {
        uint256 poolManagerToken0Balance;
        uint256 poolManagerToken1Balance;
        uint256 fullRangeLiquidity;
        uint256 narrowRangeLiquidity;
        uint256 poolManagerFullRangeToken0Balance;
        uint256 poolManagerFullRangeToken1Balance;
        uint256 poolManagerNarrowRangeToken0Balance;
        uint256 poolManagerNarrowRangeToken1Balance;
        uint256 userToken0Balance;
        uint256 userToken1Balance;
        uint256 userVaultTokenBalance;
        uint256 vaultTokenSupply;
        PoolInfo poolInfo;
        uint256 poolSqrtCurrentPriceX96;
        int256 poolTick;
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
            PoolSwapTest.TestSettings(true, true, false),
            ZERO_BYTES
        );
    }

    function getContractState(
        address user
    ) internal view returns (ContractState memory contractState) {
        contractState.poolManagerToken0Balance = poolKey.currency0.balanceOf(
            address(manager)
        );
        contractState.poolManagerToken1Balance = poolKey.currency1.balanceOf(
            address(manager)
        );
        contractState.poolManagerToken0Balance = poolKey.currency0.balanceOf(
            address(manager)
        );
        contractState.poolManagerToken1Balance = poolKey.currency1.balanceOf(
            address(manager)
        );
        contractState.userToken0Balance = poolKey.currency0.balanceOf(
            address(user)
        );
        contractState.userToken1Balance = poolKey.currency1.balanceOf(
            address(user)
        );
        (
            contractState.poolInfo.hasAccruedFees,
            contractState.poolInfo.vaultToken,
            contractState.poolInfo.centerTick,
            contractState.poolInfo.halfRangeWidthInTickSpaces,
            contractState.poolInfo.halfRangeRebalanceWidthInTickSpaces,
            contractState.poolInfo.narrowToFullLiquidityRatio,
            contractState.poolInfo.token0Balance,
            contractState.poolInfo.token1Balance
        ) = liquidityManager.poolInfos(poolId);
        contractState.userVaultTokenBalance = contractState
            .poolInfo
            .vaultToken
            .balanceOf(user);
        contractState.vaultTokenSupply = contractState
            .poolInfo
            .vaultToken
            .totalSupply();
        (
            contractState.poolSqrtCurrentPriceX96,
            contractState.poolTick,

        ) = manager.getSlot0(poolId);

        (
            contractState.fullRangeLiquidity,
            contractState.narrowRangeLiquidity,
            contractState.poolManagerFullRangeToken0Balance,
            contractState.poolManagerFullRangeToken1Balance,
            contractState.poolManagerNarrowRangeToken0Balance,
            contractState.poolManagerNarrowRangeToken1Balance
        ) = liquidityManager.getAssetsInRanges(poolId);
    }

    function printContractState(
        ContractState memory contractState
    ) internal view {
        console.log("\n## Start contact state");
        console.log(
            "liquidityManagerToken0StoredBalance:",
            contractState.poolInfo.token0Balance
        );
        console.log(
            "liquidityManagerToken1StoredBalance:",
            contractState.poolInfo.token1Balance
        );
        console.log(
            "poolManagerToken0Balance:",
            contractState.poolManagerToken0Balance
        );
        console.log(
            "poolManagerToken1Balance:",
            contractState.poolManagerToken1Balance
        );
        console.log("fullRangeLiquidity:", contractState.fullRangeLiquidity);
        console.log(
            "narrowRangeLiquidity:",
            contractState.narrowRangeLiquidity
        );
        console.log(
            "poolManagerFullRangeToken0Balance:",
            contractState.poolManagerFullRangeToken0Balance
        );
        console.log(
            "poolManagerFullRangeToken1Balance:",
            contractState.poolManagerFullRangeToken1Balance
        );
        console.log(
            "poolManagerNarrowRangeToken0Balance:",
            contractState.poolManagerNarrowRangeToken0Balance
        );
        console.log(
            "poolManagerNarrowRangeToken1Balance:",
            contractState.poolManagerNarrowRangeToken1Balance
        );
        console.log("userToken0Balance:", contractState.userToken0Balance);
        console.log("userToken1Balance:", contractState.userToken1Balance);
        console.log(
            "userVaultTokenBalance:",
            contractState.userVaultTokenBalance
        );
        console.log("vaultTokenSupply:", contractState.vaultTokenSupply);
        console.log(
            "poolSqrtCurrentPriceX96:",
            contractState.poolSqrtCurrentPriceX96
        );
        console.log("poolTick:");
        console.logInt(contractState.poolTick);
        console.log("centerTick: ");
        console.logInt(contractState.poolInfo.centerTick);
        console.log("## End contact state\n");
    }

    function testLiquidityManager_testRebalanceToHigherPriceNotNeeded() public {
        swapExactTokensForTokens(poolKey, false, 0.00025 ether);
        ContractState memory contractState = getContractState(address(this));

        assertEq(contractState.poolInfo.centerTick, 0, "centerTick mismatch");
        assertEq(contractState.poolTick, 4, "poolTick mismatch");
        assertEq(
            contractState.poolInfo.token0Balance,
            0,
            "poolInfo token0Balance mismatch"
        );
        assertEq(
            contractState.poolInfo.token1Balance,
            0,
            "poolInfo token1Balance mismatch"
        );
        assertEq(
            contractState.poolInfo.hasAccruedFees,
            true,
            "hasAccruedFees mismatch"
        );
    }

    function testLiquidityManager_testRebalanceToLowerPriceNotNeeded() public {
        swapExactTokensForTokens(poolKey, true, 0.00025 ether);
        ContractState memory contractState = getContractState(address(this));

        assertEq(contractState.poolInfo.centerTick, 0, "centerTick mismatch");
        assertEq(contractState.poolTick, -5, "poolTick mismatch");
        assertEq(
            contractState.poolInfo.token0Balance,
            0,
            "poolInfo token0Balance mismatch"
        );
        assertEq(
            contractState.poolInfo.token1Balance,
            0,
            "poolInfo token1Balance mismatch"
        );
        assertEq(
            contractState.poolInfo.hasAccruedFees,
            true,
            "hasAccruedFees mismatch"
        );
    }

    function testLiquidityManager_testRebalanceToHigherPriceNarrowRangeStillHasBothTokens()
        public
    {
        vm.expectEmit(address(liquidityManager));
        emit LiquidityRebalanced(60, 0, 9);
        swapExactTokensForTokens(poolKey, false, 0.0005 ether);

        ContractState memory contractState = getContractState(address(this));
        assertEq(contractState.poolTick, 67, "poolTick mismatch");
        assertLt(
            (contractState.poolInfo.token0Balance * FixedPoint96.Q96) /
                contractState.poolManagerNarrowRangeToken0Balance,
            FixedPoint96.Q96 / 5,
            "uninvested token0 balance is more than 20% of the narrow range token holdings"
        );
        assertLt(
            (contractState.poolInfo.token1Balance * FixedPoint96.Q96) /
                contractState.poolManagerNarrowRangeToken0Balance,
            FixedPoint96.Q96 / 5,
            "uninvested token1 balance is more than 20% of the narrow range token holdings"
        );
    }

    function testLiquidityManager_testRebalanceToLowerPriceNarrowRangeStillHasBothTokens()
        public
    {
        vm.expectEmit(address(liquidityManager));
        emit LiquidityRebalanced(-60, 0, -10);
        swapExactTokensForTokens(poolKey, true, 0.0005 ether);
        ContractState memory contractState = getContractState(address(this));

        assertEq(contractState.poolTick, -68, "poolTick mismatch");
        assertLt(
            (contractState.poolInfo.token0Balance * FixedPoint96.Q96) /
                contractState.poolManagerNarrowRangeToken0Balance,
            FixedPoint96.Q96 / 5,
            "uninvested token0 balance is more than 20% of the narrow range token holdings"
        );
        assertLt(
            (contractState.poolInfo.token1Balance * FixedPoint96.Q96) /
                contractState.poolManagerNarrowRangeToken0Balance,
            FixedPoint96.Q96 / 5,
            "uninvested token1 balance is more than 20% of the narrow range token holdings"
        );
    }

    function testLiquidityManager_testRebalanceToHigherPriceNarrowRangeOnlyHasOneToken()
        public
    {
        vm.expectEmit(address(liquidityManager));
        emit LiquidityRebalanced(5880, 0, 1989);
        swapExactTokensForTokens(poolKey, false, 0.05 ether);
        ContractState memory contractState = getContractState(address(this));

        assertEq(contractState.poolTick, 5918, "poolTick mismatch");

        // uninvested token0 balance is more than 20% due to the crude algorithm that is used to calculate swap amount during rebalancing
        assertGt(
            (contractState.poolInfo.token0Balance * FixedPoint96.Q96) /
                contractState.poolManagerNarrowRangeToken0Balance,
            FixedPoint96.Q96 / 5,
            "uninvested token0 balance is more than 20% of the narrow range token holdings"
        );

        // couple of rebalancing will sort it out
        // rebalancing will be executed naturally as part of subsequent swaps, but rebalancing is called directly in this test
        liquidityManager.rebalanceIfNecessary(poolKey, true);
        liquidityManager.rebalanceIfNecessary(poolKey, true);
        liquidityManager.rebalanceIfNecessary(poolKey, true);
        contractState = getContractState(address(this));
        assertLt(
            (contractState.poolInfo.token0Balance * FixedPoint96.Q96) /
                contractState.poolManagerNarrowRangeToken0Balance,
            FixedPoint96.Q96 / 5,
            "uninvested token0 balance is more than 20% of the narrow range token holdings"
        );
        assertLt(
            (contractState.poolInfo.token1Balance * FixedPoint96.Q96) /
                contractState.poolManagerNarrowRangeToken0Balance,
            FixedPoint96.Q96 / 5,
            "uninvested token1 balance is more than 20% of the narrow range token holdings"
        );
    }

    function testLiquidityManager_testRebalanceToLowerPriceNarrowRangeOnlyHasOneToken()
        public
    {
        vm.expectEmit(address(liquidityManager));
        emit LiquidityRebalanced(-5880, 0, -1990);
        swapExactTokensForTokens(poolKey, true, 0.05 ether);
        ContractState memory contractState = getContractState(address(this));
        assertEq(contractState.poolTick, -5919, "poolTick mismatch");

        // uninvested token0 balance is more than 20% due to the crude algorithm that is used to calculate swap amount during rebalancing
        assertGt(
            (contractState.poolInfo.token1Balance * FixedPoint96.Q96) /
                contractState.poolManagerNarrowRangeToken1Balance,
            FixedPoint96.Q96 / 5,
            "uninvested token0 balance is more than 20% of the narrow range token holdings"
        );

        // couple of rebalancing will sort it out
        // rebalancing will be executed naturally as part of subsequent swaps, but rebalancing is called directly in this test
        liquidityManager.rebalanceIfNecessary(poolKey, true);
        liquidityManager.rebalanceIfNecessary(poolKey, true);
        liquidityManager.rebalanceIfNecessary(poolKey, true);
        contractState = getContractState(address(this));

        assertLt(
            (contractState.poolInfo.token0Balance * FixedPoint96.Q96) /
                contractState.poolManagerNarrowRangeToken0Balance,
            FixedPoint96.Q96 / 5,
            "uninvested token0 balance is more than 20% of the narrow range token holdings"
        );
        assertLt(
            (contractState.poolInfo.token1Balance * FixedPoint96.Q96) /
                contractState.poolManagerNarrowRangeToken0Balance,
            FixedPoint96.Q96 / 5,
            "uninvested token1 balance is more than 20% of the narrow range token holdings"
        );
    }

    function testLiquidityManager_testDepositWithNonZeroContractStoredTokenBalances()
        public
    {
        // swapping to accumulate fees
        swapExactTokensForTokens(poolKey, true, 0.0005 ether);
        swapExactTokensForTokens(poolKey, false, 0.0005 ether);

        // add zero liquidity to trigger fee collection
        liquidityManager.addLiquidity(
            AddLiquidityParams({
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                fee: poolKey.fee,
                vaultTokenAmount: 0 ether,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );

        // adding more liquidity
        ContractState
            memory contractStateBeforeAddingLiquidity = getContractState(
                address(this)
            );
        liquidityManager.addLiquidity(
            AddLiquidityParams({
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                fee: poolKey.fee,
                vaultTokenAmount: 0.5 ether,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );
        ContractState
            memory contractStateAfterAddingLiquidity = getContractState(
                address(this)
            );

        // liquidity manager updated its uninvested token balances
        assertApproxEqRel(
            contractStateAfterAddingLiquidity.poolInfo.token0Balance,
            (contractStateBeforeAddingLiquidity.poolInfo.token0Balance *
                contractStateAfterAddingLiquidity.vaultTokenSupply) /
                contractStateBeforeAddingLiquidity.vaultTokenSupply,
            1e16,
            "token0Balance mismatch"
        );
        assertApproxEqRel(
            contractStateAfterAddingLiquidity.poolInfo.token1Balance,
            (contractStateBeforeAddingLiquidity.poolInfo.token1Balance *
                contractStateAfterAddingLiquidity.vaultTokenSupply) /
                contractStateBeforeAddingLiquidity.vaultTokenSupply,
            1e16,
            "token1Balance mismatch"
        );
        // user transferred the right amount of tokens
        assertApproxEqRel(
            contractStateAfterAddingLiquidity
                .poolManagerNarrowRangeToken0Balance -
                contractStateBeforeAddingLiquidity
                    .poolManagerNarrowRangeToken0Balance +
                contractStateAfterAddingLiquidity
                    .poolManagerFullRangeToken0Balance -
                contractStateBeforeAddingLiquidity
                    .poolManagerFullRangeToken0Balance +
                contractStateAfterAddingLiquidity.poolInfo.token0Balance -
                contractStateBeforeAddingLiquidity.poolInfo.token0Balance,
            contractStateBeforeAddingLiquidity.userToken0Balance -
                contractStateAfterAddingLiquidity.userToken0Balance,
            1e2,
            "userToken0Balance mismatch"
        );
        assertApproxEqRel(
            contractStateAfterAddingLiquidity
                .poolManagerNarrowRangeToken1Balance -
                contractStateBeforeAddingLiquidity
                    .poolManagerNarrowRangeToken1Balance +
                contractStateAfterAddingLiquidity
                    .poolManagerFullRangeToken1Balance -
                contractStateBeforeAddingLiquidity
                    .poolManagerFullRangeToken1Balance +
                contractStateAfterAddingLiquidity.poolInfo.token1Balance -
                contractStateBeforeAddingLiquidity.poolInfo.token1Balance,
            contractStateBeforeAddingLiquidity.userToken1Balance -
                contractStateAfterAddingLiquidity.userToken1Balance,
            1e2,
            "userToken1Balance mismatch"
        );
    }

    function testLiquidityManager_testWithdrawalWithNonZeroContractStoredTokenBalances()
        public
    {
        // swapping to accumulate fees
        swapExactTokensForTokens(poolKey, true, 0.0005 ether);
        swapExactTokensForTokens(poolKey, false, 0.0005 ether);

        // add zero liquidity to trigger fee collection
        liquidityManager.addLiquidity(
            AddLiquidityParams({
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                fee: poolKey.fee,
                vaultTokenAmount: 0 ether,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );

        // adding more liquidity
        ContractState
            memory contractStateBeforeAddingLiquidity = getContractState(
                address(this)
            );
        liquidityManager.removeLiquidity(
            RemoveLiquidityParams({
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                fee: poolKey.fee,
                vaultTokenAmount: 0.3 ether,
                deadline: MAX_DEADLINE
            })
        );
        ContractState
            memory contractStateAfterAddingLiquidity = getContractState(
                address(this)
            );

        // liquidity manager updated its uninvested token balances
        assertApproxEqRel(
            contractStateAfterAddingLiquidity.poolInfo.token0Balance,
            (contractStateBeforeAddingLiquidity.poolInfo.token0Balance *
                contractStateAfterAddingLiquidity.vaultTokenSupply) /
                contractStateBeforeAddingLiquidity.vaultTokenSupply,
            1e16,
            "token0Balance mismatch"
        );
        assertApproxEqRel(
            contractStateAfterAddingLiquidity.poolInfo.token1Balance,
            (contractStateBeforeAddingLiquidity.poolInfo.token1Balance *
                contractStateAfterAddingLiquidity.vaultTokenSupply) /
                contractStateBeforeAddingLiquidity.vaultTokenSupply,
            1e16,
            "token1Balance mismatch"
        );

        // user transferred the right amount of tokens
        assertApproxEqRel(
            contractStateBeforeAddingLiquidity
                .poolManagerNarrowRangeToken0Balance -
                contractStateAfterAddingLiquidity
                    .poolManagerNarrowRangeToken0Balance +
                contractStateBeforeAddingLiquidity
                    .poolManagerFullRangeToken0Balance -
                contractStateAfterAddingLiquidity
                    .poolManagerFullRangeToken0Balance +
                contractStateBeforeAddingLiquidity.poolInfo.token0Balance -
                contractStateAfterAddingLiquidity.poolInfo.token0Balance,
            contractStateAfterAddingLiquidity.userToken0Balance -
                contractStateBeforeAddingLiquidity.userToken0Balance,
            1e2,
            "userToken0Balance mismatch"
        );
        assertApproxEqRel(
            contractStateBeforeAddingLiquidity
                .poolManagerNarrowRangeToken1Balance -
                contractStateAfterAddingLiquidity
                    .poolManagerNarrowRangeToken1Balance +
                contractStateBeforeAddingLiquidity
                    .poolManagerFullRangeToken1Balance -
                contractStateAfterAddingLiquidity
                    .poolManagerFullRangeToken1Balance +
                contractStateBeforeAddingLiquidity.poolInfo.token1Balance -
                contractStateAfterAddingLiquidity.poolInfo.token1Balance,
            contractStateAfterAddingLiquidity.userToken1Balance -
                contractStateBeforeAddingLiquidity.userToken1Balance,
            1e2,
            "userToken1Balance mismatch"
        );
    }
}
