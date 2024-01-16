// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {LiquidityLocking, FIXED_POINT_SCALING} from "../src/LiquidityLocking.sol";

import {MockERC20} from "@uniswap/v4-core/test/foundry-tests/utils/MockERC20.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {UniswapV4ERC20} from "@uniswap/periphery-next/contracts/libraries/UniswapV4ERC20.sol";

import {BaseHook} from "@uniswap/periphery-next/contracts/BaseHook.sol";

import {Test, console, console2} from "forge-std/Test.sol";

contract LiquidtyLockingTest is Deployers, Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LiquidityLocking liquidityLocking =
        LiquidityLocking(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG |
                        Hooks.BEFORE_MODIFY_POSITION_FLAG |
                        Hooks.BEFORE_SWAP_FLAG
                )
            )
        );

    using PoolIdLibrary for PoolKey;

    MockERC20 _token0;
    MockERC20 _token1;
    PoolManager _manager;
    PoolKey _poolKey;
    PoolId _poolId;
    UniswapV4ERC20 _rewardToken;

    address _charlie;

    int24 constant TICK_SPACING = 60;
    uint256 constant MAX_DEADLINE = 12329839823;
    uint256 constant INITIAL_BLOCK_TIMESTAMP = 100;
    uint256 constant REWARD_GENERATION_RATE = 2_000_000; // 2 rewards/liquidity/second
    uint24 WITHDRAWAL_PENALTY_PCT = 10_0000; // 10%

    function setUp() public {
        vm.warp(INITIAL_BLOCK_TIMESTAMP);

        _token0 = new MockERC20("TestA", "A", 18, 2 ** 128);
        _token1 = new MockERC20("TestB", "B", 18, 2 ** 128);
        _manager = new PoolManager(500000);

        deployCodeTo(
            "LiquidityLocking.sol",
            abi.encode(_manager),
            address(liquidityLocking)
        );

        _poolKey = createPoolKey(_token0, _token1);
        _poolId = _poolKey.toId();

        _token0.approve(address(liquidityLocking), type(uint256).max);
        _token1.approve(address(liquidityLocking), type(uint256).max);

        _manager.initialize(
            _poolKey,
            SQRT_RATIO_1_1,
            abi.encode(
                LiquidityLocking.InitParamsLiquidityLocking(
                    REWARD_GENERATION_RATE,
                    WITHDRAWAL_PENALTY_PCT
                )
            )
        );
        (, _rewardToken, , , ) = liquidityLocking.poolInfoLiquidityLocking(
            _poolId
        );

        _charlie = makeAddr("charlie");
        vm.startPrank(_charlie);
        _token0.mint(_charlie, 10000 ether);
        _token1.mint(_charlie, 10000 ether);
        _token0.approve(address(liquidityLocking), type(uint256).max);
        _token1.approve(address(liquidityLocking), type(uint256).max);
        liquidityLocking.addLiquidity(
            LiquidityLocking.AddLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                MAX_DEADLINE,
                block.timestamp + 100
            )
        );
        vm.stopPrank();
    }

    function createPoolKey(
        MockERC20 tokenA,
        MockERC20 tokenB
    ) internal view returns (PoolKey memory) {
        if (address(tokenA) > address(tokenB))
            (tokenA, tokenB) = (tokenB, tokenA);
        return
            PoolKey(
                Currency.wrap(address(tokenA)),
                Currency.wrap(address(tokenB)),
                3000,
                TICK_SPACING,
                liquidityLocking
            );
    }

    struct ContractState {
        uint256 hookBalance0;
        uint256 hookBalance1;
        uint256 managerBalance0;
        uint256 managerBalance1;
        uint256 totalLiquidityShares;
        LiquidityLocking.LockingInfo lockingInfo;
        uint256 totalRewardToken;
        uint256 userRewardToken;
    }

    function getContractState(
        address user
    ) internal view returns (ContractState memory contractState) {
        contractState.hookBalance0 = _poolKey.currency0.balanceOf(
            address(this)
        );
        contractState.hookBalance1 = _poolKey.currency1.balanceOf(
            address(this)
        );
        contractState.managerBalance0 = _poolKey.currency0.balanceOf(
            address(_manager)
        );
        contractState.managerBalance1 = _poolKey.currency1.balanceOf(
            address(_manager)
        );
        (, , , contractState.totalLiquidityShares, ) = liquidityLocking
            .poolInfoLiquidityLocking(_poolId);
        contractState.lockingInfo = liquidityLocking.poolUserInfo(
            _poolId,
            user
        );
        contractState.totalRewardToken = _rewardToken.totalSupply();
        contractState.userRewardToken = _rewardToken.balanceOf(user);
    }

    function testLiquidityLocking_withdrawEarlyWithPenalties() public {
        ContractState memory contractStateBeforeAdd = getContractState(
            address(this)
        );

        uint256 beforeLockExpires1 = INITIAL_BLOCK_TIMESTAMP + 49;
        uint256 lockedUntil = INITIAL_BLOCK_TIMESTAMP + 50;
        uint256 afterLockExpires1 = lockedUntil + 20;

        ////////// Adding liquidity to the pool ////////////

        // adding liquidity
        liquidityLocking.addLiquidity(
            LiquidityLocking.AddLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
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

        ////////// Remove partial liquidity from the pool, before the deadline ////////////
        vm.warp(beforeLockExpires1);

        // remove liquidity
        uint256 liquiditySharesToRemove = contractStateAfterAdd
            .lockingInfo
            .liquidityShare / 3;
        liquidityLocking.removeLiquidity(
            LiquidityLocking.RemoveLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                liquiditySharesToRemove,
                MAX_DEADLINE
            )
        );
        ContractState memory contractStateAfterPartialRemove = getContractState(
            address(this)
        );

        // checking total liquidty share decrease
        assertApproxEqRel(
            contractStateAfterAdd.totalLiquidityShares -
                liquiditySharesToRemove,
            contractStateAfterPartialRemove.totalLiquidityShares,
            1e15,
            "Total liquidity share mismatch after partial removal"
        );

        // checking user liquidity share decrease
        assertApproxEqRel(
            contractStateAfterAdd.lockingInfo.liquidityShare -
                liquiditySharesToRemove,
            contractStateAfterPartialRemove.lockingInfo.liquidityShare,
            1e15,
            "User liquidity share mismatch after partial removal"
        );

        // checking the total supply of reward token increase
        assertEq(
            contractStateAfterPartialRemove.totalRewardToken -
                contractStateAfterAdd.totalRewardToken,
            (REWARD_GENERATION_RATE *
                contractStateAfterAdd.lockingInfo.liquidityShare *
                (beforeLockExpires1 - INITIAL_BLOCK_TIMESTAMP)) /
                FIXED_POINT_SCALING,
            "Total reward token mismatch after partial removal"
        );

        // checking the user amount of reward token is the same as the cange in total supply
        assertEq(
            contractStateAfterPartialRemove.totalRewardToken -
                contractStateAfterAdd.totalRewardToken,
            contractStateAfterPartialRemove.userRewardToken -
                contractStateAfterAdd.userRewardToken,
            "User reward token mismatch after partial removal"
        );

        // checking if the withdrawal penalty is applied to the user's token balance
        assertApproxEqRel(
            contractStateAfterPartialRemove.hookBalance0 -
                contractStateAfterAdd.hookBalance0,
            uint256(((100e18 / 3) * 9) / 10),
            1e15,
            "Hook token0 balance mismatch after partial removal"
        );

        assertApproxEqRel(
            contractStateAfterPartialRemove.hookBalance1 -
                contractStateAfterAdd.hookBalance1,
            ((100e18 / 3) * 9) / 10,
            1e15,
            "Hook token1 balance mismatch after partial removal"
        );

        // checking if the withdrawal penalty is applied to the manager's balance
        assertApproxEqRel(
            contractStateAfterAdd.managerBalance0 -
                contractStateAfterPartialRemove.managerBalance0,
            uint256(100e18) / 3 - uint256(100e18) / 3 / 10,
            1e15,
            "Hook token0 balance mismatch after partial removal"
        );

        assertApproxEqRel(
            contractStateAfterAdd.managerBalance1 -
                contractStateAfterPartialRemove.managerBalance1,
            uint256(100e18) / 3 - uint256(100e18) / 3 / 10,
            1e15,
            "Hook token1 balance mismatch after partial removal"
        );

        ////////// Remove the rest of the liquidity from the pool at a future time ////////////

        vm.warp(afterLockExpires1);

        // remove rest of the liquidity
        liquiditySharesToRemove =
            contractStateAfterAdd.lockingInfo.liquidityShare -
            liquiditySharesToRemove;
        liquidityLocking.removeLiquidity(
            LiquidityLocking.RemoveLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                liquiditySharesToRemove,
                MAX_DEADLINE
            )
        );
        ContractState memory contractStateAfterFullRemove = getContractState(
            address(this)
        );

        // checking total liquidty share decrease
        assertApproxEqRel(
            contractStateAfterPartialRemove.totalLiquidityShares -
                liquiditySharesToRemove,
            contractStateAfterFullRemove.totalLiquidityShares,
            1e15,
            "Total liquidity share mismatch after full removal"
        );

        // checking user liquidity share decrease
        assertApproxEqRel(
            contractStateAfterPartialRemove.lockingInfo.liquidityShare -
                liquiditySharesToRemove,
            contractStateAfterFullRemove.lockingInfo.liquidityShare,
            1e15,
            "User liquidity share mismatch after full removal"
        );

        // checking the total supply of reward token increase
        assertEq(
            contractStateAfterFullRemove.totalRewardToken -
                contractStateAfterPartialRemove.totalRewardToken,
            (REWARD_GENERATION_RATE *
                liquiditySharesToRemove *
                (lockedUntil - beforeLockExpires1)) / FIXED_POINT_SCALING,
            "Total reward token mismatch after full removal"
        );

        // checking the user amount of reward token is the same as the cange in total supply
        assertEq(
            contractStateAfterFullRemove.totalRewardToken -
                contractStateAfterPartialRemove.totalRewardToken,
            contractStateAfterFullRemove.userRewardToken -
                contractStateAfterPartialRemove.userRewardToken,
            "User reward token mismatch after full removal"
        );

        // checking if the locking info is deleted
        assertEq(
            contractStateAfterFullRemove.lockingInfo.lockingTime,
            0,
            "Locking time is not 0 after full removal"
        );
        assertEq(
            contractStateAfterFullRemove.lockingInfo.lockedUntil,
            0,
            "Liquidity delta is not 0 after full removal"
        );
        assertEq(
            contractStateAfterFullRemove.lockingInfo.liquidityShare,
            0,
            "Liquidity share is not 0 after full removal"
        );

        // checking if hook balance is increased by the penalty amount
        assertApproxEqRel(
            contractStateBeforeAdd.hookBalance0 +
                uint256(100e18) /
                3 -
                uint256(100e18) /
                3 /
                10,
            contractStateAfterFullRemove.hookBalance0,
            1e15,
            "Hook balance for token0 has not been changed by the penalty amount"
        );
        assertApproxEqRel(
            contractStateBeforeAdd.hookBalance1 +
                uint256(100e18) /
                3 -
                uint256(100e18) /
                3 /
                10,
            contractStateAfterFullRemove.hookBalance1,
            1e15,
            "Hook balance for token0 has not been changed by the penalty amount"
        );
    }

    function testLiquidityLocking_withdrawAfterLockExpires() public {
        ContractState memory contractStateBeforeAdd = getContractState(
            address(this)
        );
        uint256 lockedUntil = INITIAL_BLOCK_TIMESTAMP + 50;
        uint256 afterLockExpires1 = lockedUntil + 20;
        uint256 afterLockExpires2 = afterLockExpires1 + 20;

        ////////// Adding liquidity to the pool ////////////

        // adding liquidity
        liquidityLocking.addLiquidity(
            LiquidityLocking.AddLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
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

        // checking total liquidty share increase
        assertApproxEqRel(
            contractStateBeforeAdd.totalLiquidityShares + 100e18,
            contractStateAfterAdd.totalLiquidityShares,
            1e15,
            "Total liquidity share mismatch after adding liquidity"
        );

        // checking user liquidity share increase
        assertApproxEqRel(
            contractStateBeforeAdd.lockingInfo.liquidityShare + 100e18,
            contractStateAfterAdd.lockingInfo.liquidityShare,
            1e15,
            "User liquidity share mismatch after adding liquidity"
        );

        // checking the total supply of reward token is unchanged
        assertEq(
            contractStateBeforeAdd.totalRewardToken,
            contractStateAfterAdd.totalRewardToken,
            "Total reward token mismatch after adding liquidity"
        );

        // checking the user amount of reward token is unchanged
        assertEq(
            contractStateBeforeAdd.userRewardToken,
            contractStateAfterAdd.userRewardToken,
            "User reward token mismatch after adding liquidity"
        );

        ////////// Remove partial liquidity from the pool ////////////
        vm.warp(afterLockExpires1);

        // remove liquidity
        uint256 liquiditySharesToRemove = contractStateAfterAdd
            .lockingInfo
            .liquidityShare / 3;
        liquidityLocking.removeLiquidity(
            LiquidityLocking.RemoveLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                liquiditySharesToRemove,
                MAX_DEADLINE
            )
        );
        ContractState memory contractStateAfterPartialRemove = getContractState(
            address(this)
        );

        // checking total liquidty share decrease
        assertApproxEqRel(
            contractStateAfterAdd.totalLiquidityShares -
                liquiditySharesToRemove,
            contractStateAfterPartialRemove.totalLiquidityShares,
            1e15,
            "Total liquidity share mismatch after partial removal"
        );

        // checking user liquidity share decrease
        assertApproxEqRel(
            contractStateAfterAdd.lockingInfo.liquidityShare -
                liquiditySharesToRemove,
            contractStateAfterPartialRemove.lockingInfo.liquidityShare,
            1e15,
            "User liquidity share mismatch after partial removal"
        );

        // checking the total supply of reward token increase
        assertEq(
            contractStateAfterPartialRemove.totalRewardToken -
                contractStateAfterAdd.totalRewardToken,
            (REWARD_GENERATION_RATE *
                contractStateAfterAdd.lockingInfo.liquidityShare *
                (lockedUntil - INITIAL_BLOCK_TIMESTAMP)) / FIXED_POINT_SCALING,
            "Total reward token mismatch after partial removal"
        );

        // checking the user amount of reward token is the same as the cange in total supply
        assertEq(
            contractStateAfterPartialRemove.totalRewardToken -
                contractStateAfterAdd.totalRewardToken,
            contractStateAfterPartialRemove.userRewardToken -
                contractStateAfterAdd.userRewardToken,
            "User reward token mismatch after partial removal"
        );

        ////////// Remove the rest of the liquidity from the pool at a future time ////////////

        vm.warp(afterLockExpires2);

        // remove rest of the liquidity
        liquiditySharesToRemove =
            contractStateAfterAdd.lockingInfo.liquidityShare -
            liquiditySharesToRemove;
        liquidityLocking.removeLiquidity(
            LiquidityLocking.RemoveLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                liquiditySharesToRemove,
                MAX_DEADLINE
            )
        );
        ContractState memory contractStateAfterFullRemove = getContractState(
            address(this)
        );

        // checking total liquidty share decrease
        assertApproxEqRel(
            contractStateAfterPartialRemove.totalLiquidityShares -
                liquiditySharesToRemove,
            contractStateAfterFullRemove.totalLiquidityShares,
            1e15,
            "Total liquidity share mismatch after full removal"
        );

        // checking user liquidity share decrease
        assertApproxEqRel(
            contractStateAfterPartialRemove.lockingInfo.liquidityShare -
                liquiditySharesToRemove,
            contractStateAfterFullRemove.lockingInfo.liquidityShare,
            1e15,
            "User liquidity share mismatch after full removal"
        );

        // checking the total supply of reward token increase
        assertEq(
            contractStateAfterFullRemove.totalRewardToken -
                contractStateAfterPartialRemove.totalRewardToken,
            0,
            "Total reward token mismatch after full removal"
        );

        // checking the user amount of reward token is the same as the cange in total supply
        assertEq(
            contractStateAfterFullRemove.totalRewardToken -
                contractStateAfterPartialRemove.totalRewardToken,
            contractStateAfterFullRemove.userRewardToken -
                contractStateAfterPartialRemove.userRewardToken,
            "User reward token mismatch after full removal"
        );

        // checking if the locking info is deleted
        assertEq(
            contractStateAfterFullRemove.lockingInfo.lockingTime,
            0,
            "Locking time is not 0 after full removal"
        );
        assertEq(
            contractStateAfterFullRemove.lockingInfo.lockedUntil,
            0,
            "Liquidity delta is not 0 after full removal"
        );
        assertEq(
            contractStateAfterFullRemove.lockingInfo.liquidityShare,
            0,
            "Liquidity share is not 0 after full removal"
        );

        // checking if hook balance is unchanged
        assertApproxEqRel(
            contractStateBeforeAdd.hookBalance0,
            contractStateAfterFullRemove.hookBalance0,
            1e15,
            "Hook balance for token0 changed"
        );
        assertApproxEqRel(
            contractStateBeforeAdd.hookBalance1,
            contractStateAfterFullRemove.hookBalance1,
            1e15,
            "Hook balance for token0 changed"
        );
    }

    function testLiquidityLocking_addingMoreLiquidityBeforeWithdraw() public {
        ContractState memory contractStateBeforeAdd = getContractState(
            address(this)
        );

        uint256 beforelockedUntil1 = INITIAL_BLOCK_TIMESTAMP + 20;
        uint256 beforelockedUntil2 = beforelockedUntil1 + 3;
        uint256 lockedUntil = INITIAL_BLOCK_TIMESTAMP + 50;
        uint256 afterlockedUntil1 = lockedUntil + 10;
        uint256 afterlockedUntil2 = afterlockedUntil1 + 5;
        uint256 afterlockedUntil3 = afterlockedUntil1 + 100;

        ////////// Adding liquidity to the pool ////////////

        // adding liquidity
        liquidityLocking.addLiquidity(
            LiquidityLocking.AddLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                MAX_DEADLINE,
                lockedUntil
            )
        );
        ContractState memory contractStateAfterFirstAdd = getContractState(
            address(this)
        );

        ////////// Adding liquidity to the pool before the deadline without changing the deadline ////////////

        // trying to shorten the duration of the liquidity that has already been locked
        vm.warp(beforelockedUntil1);
        vm.expectRevert(LiquidityLocking.ShorteninglockedUntil.selector);

        liquidityLocking.addLiquidity(
            LiquidityLocking.AddLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                MAX_DEADLINE,
                lockedUntil - 1
            )
        );

        // adding more liquidity before the deadline without changing the deadline
        liquidityLocking.addLiquidity(
            LiquidityLocking.AddLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                MAX_DEADLINE,
                lockedUntil
            )
        );
        ContractState memory contractStateAfterSecondAdd = getContractState(
            address(this)
        );

        // checking total liquidty share increase
        assertApproxEqRel(
            contractStateAfterSecondAdd.totalLiquidityShares,
            contractStateAfterFirstAdd.totalLiquidityShares + 100e18,
            1e15,
            "Total liquidity share mismatch after adding liquidity second time"
        );

        // checking user liquidity share increase
        assertApproxEqRel(
            contractStateAfterSecondAdd.lockingInfo.liquidityShare,
            contractStateAfterFirstAdd.lockingInfo.liquidityShare + 100e18,
            1e15,
            "User liquidity share mismatch after adding liquidity second time"
        );

        // checking the total supply of reward token increase
        assertEq(
            contractStateAfterSecondAdd.totalRewardToken -
                contractStateAfterFirstAdd.totalRewardToken,
            (REWARD_GENERATION_RATE *
                contractStateAfterFirstAdd.lockingInfo.liquidityShare *
                (beforelockedUntil1 - INITIAL_BLOCK_TIMESTAMP)) /
                FIXED_POINT_SCALING,
            "Total reward token mismatch after adding liquidity second time"
        );

        // checking the user amount of reward token is the same as the cange in total supply
        assertEq(
            contractStateAfterSecondAdd.totalRewardToken -
                contractStateAfterFirstAdd.totalRewardToken,
            contractStateAfterSecondAdd.userRewardToken -
                contractStateAfterFirstAdd.userRewardToken,
            "User reward token mismatch after adding liquidity second time"
        );

        // checking if the locking info is correct
        assertEq(
            contractStateAfterSecondAdd.lockingInfo.lockingTime,
            beforelockedUntil1,
            "Locking time mismatch after adding liquidity second time"
        );
        assertEq(
            contractStateAfterSecondAdd.lockingInfo.lockedUntil,
            lockedUntil,
            "Liquidity delta mismatch after adding liquidity second time"
        );
        assertApproxEqRel(
            contractStateAfterSecondAdd.lockingInfo.liquidityShare,
            2 * 100e18,
            1e15,
            "Liquidity share mismatch after adding liquidity second time"
        );

        ////////// Adding liquidity to the pool before the deadline and changing the deadline to a future date ////////////

        vm.warp(beforelockedUntil2);

        liquidityLocking.addLiquidity(
            LiquidityLocking.AddLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                MAX_DEADLINE,
                afterlockedUntil1
            )
        );
        ContractState memory contractStateAfterThirdAdd = getContractState(
            address(this)
        );

        // checking total liquidty share increase
        assertApproxEqRel(
            contractStateAfterThirdAdd.totalLiquidityShares,
            contractStateAfterSecondAdd.totalLiquidityShares + 100e18,
            1e15,
            "Total liquidity share mismatch after adding liquidity third time"
        );

        // checking user liquidity share increase
        assertApproxEqRel(
            contractStateAfterThirdAdd.lockingInfo.liquidityShare,
            contractStateAfterSecondAdd.lockingInfo.liquidityShare + 100e18,
            1e15,
            "User liquidity share mismatch after adding liquidity third time"
        );

        // checking the total supply of reward token increase
        assertEq(
            contractStateAfterThirdAdd.totalRewardToken -
                contractStateAfterSecondAdd.totalRewardToken,
            (REWARD_GENERATION_RATE *
                contractStateAfterSecondAdd.lockingInfo.liquidityShare *
                (beforelockedUntil2 - beforelockedUntil1)) /
                FIXED_POINT_SCALING,
            "Total reward token mismatch after adding liquidity third time"
        );

        // checking the user amount of reward token is the same as the cange in total supply
        assertEq(
            contractStateAfterThirdAdd.totalRewardToken -
                contractStateAfterSecondAdd.totalRewardToken,
            contractStateAfterThirdAdd.userRewardToken -
                contractStateAfterSecondAdd.userRewardToken,
            "User reward token mismatch after adding liquidity third time"
        );

        // checking if the locking info is correct
        assertEq(
            contractStateAfterThirdAdd.lockingInfo.lockingTime,
            beforelockedUntil2,
            "Locking time mismatch after adding liquidity third time"
        );
        assertEq(
            contractStateAfterThirdAdd.lockingInfo.lockedUntil,
            afterlockedUntil1,
            "Liquidity delta mismatch after adding liquidity third time"
        );
        assertApproxEqRel(
            contractStateAfterThirdAdd.lockingInfo.liquidityShare,
            3 * 100e18,
            1e15,
            "Liquidity share mismatch after adding liquidity third time"
        );

        //////// Adding liquidity to the pool after the deadline ////////////

        vm.warp(afterlockedUntil2);

        liquidityLocking.addLiquidity(
            LiquidityLocking.AddLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                MAX_DEADLINE,
                afterlockedUntil3
            )
        );
        ContractState memory contractStateAfterFourthAdd = getContractState(
            address(this)
        );

        // checking total liquidty share increase
        assertApproxEqRel(
            contractStateAfterFourthAdd.totalLiquidityShares,
            contractStateAfterThirdAdd.totalLiquidityShares + 100e18,
            1e15,
            "Total liquidity share mismatch after adding liquidity fourth time"
        );

        // checking user liquidity share increase
        assertApproxEqRel(
            contractStateAfterFourthAdd.lockingInfo.liquidityShare,
            contractStateAfterThirdAdd.lockingInfo.liquidityShare + 100e18,
            1e15,
            "User liquidity share mismatch after adding liquidity fourth time"
        );

        // checking the total supply of reward token increase
        assertEq(
            contractStateAfterFourthAdd.totalRewardToken -
                contractStateAfterThirdAdd.totalRewardToken,
            (REWARD_GENERATION_RATE *
                contractStateAfterThirdAdd.lockingInfo.liquidityShare *
                (afterlockedUntil1 - beforelockedUntil2)) / FIXED_POINT_SCALING,
            "Total reward token mismatch after adding liquidity fourth time"
        );

        // checking the user amount of reward token is the same as the cange in total supply
        assertEq(
            contractStateAfterFourthAdd.totalRewardToken -
                contractStateAfterThirdAdd.totalRewardToken,
            contractStateAfterFourthAdd.userRewardToken -
                contractStateAfterThirdAdd.userRewardToken,
            "User reward token mismatch after adding liquidity fourth time"
        );

        // checking if the locking info is correct
        assertEq(
            contractStateAfterFourthAdd.lockingInfo.lockingTime,
            afterlockedUntil2,
            "Locking time mismatch after adding liquidity fourth time"
        );
        assertEq(
            contractStateAfterFourthAdd.lockingInfo.lockedUntil,
            afterlockedUntil3,
            "Liquidity delta mismatch after adding liquidity fourth time"
        );
        assertApproxEqRel(
            contractStateAfterFourthAdd.lockingInfo.liquidityShare,
            4 * 100e18,
            1e15,
            "Liquidity share mismatch after adding liquidity fourth time"
        );

        ////////// Remove all of the liquidity ////////////

        vm.warp(afterlockedUntil3);

        // remove rest of the liquidity
        uint256 liquiditySharesToRemove = contractStateAfterFourthAdd
            .lockingInfo
            .liquidityShare;
        liquidityLocking.removeLiquidity(
            LiquidityLocking.RemoveLiquidityParams(
                _poolKey.currency0,
                _poolKey.currency1,
                3000,
                liquiditySharesToRemove,
                MAX_DEADLINE
            )
        );
        ContractState memory contractStateAfterFullRemove = getContractState(
            address(this)
        );

        // checking total liquidty share decrease
        assertApproxEqRel(
            contractStateAfterFourthAdd.totalLiquidityShares -
                liquiditySharesToRemove,
            contractStateAfterFullRemove.totalLiquidityShares,
            1e15,
            "Total liquidity share mismatch after full removal"
        );

        // checking user liquidity share decrease
        assertApproxEqRel(
            contractStateAfterFourthAdd.lockingInfo.liquidityShare -
                liquiditySharesToRemove,
            contractStateAfterFullRemove.lockingInfo.liquidityShare,
            1e15,
            "User liquidity share mismatch after full removal"
        );

        // checking the total supply of reward token increase
        assertEq(
            contractStateAfterFullRemove.totalRewardToken -
                contractStateAfterFourthAdd.totalRewardToken,
            (REWARD_GENERATION_RATE *
                liquiditySharesToRemove *
                (afterlockedUntil3 - afterlockedUntil2)) / FIXED_POINT_SCALING,
            "Total reward token mismatch after full removal"
        );

        // checking the user amount of reward token is the same as the cange in total supply
        assertEq(
            contractStateAfterFullRemove.totalRewardToken -
                contractStateAfterFourthAdd.totalRewardToken,
            contractStateAfterFullRemove.userRewardToken -
                contractStateAfterFourthAdd.userRewardToken,
            "User reward token mismatch after full removal"
        );

        // checking if the locking info is deleted
        assertEq(
            contractStateAfterFullRemove.lockingInfo.lockingTime,
            0,
            "Locking time is not 0 after full removal"
        );
        assertEq(
            contractStateAfterFullRemove.lockingInfo.lockedUntil,
            0,
            "Liquidity delta is not 0 after full removal"
        );
        assertEq(
            contractStateAfterFullRemove.lockingInfo.liquidityShare,
            0,
            "Liquidity share is not 0 after full removal"
        );

        // checking if hook balance is unchanged
        assertApproxEqRel(
            contractStateBeforeAdd.hookBalance0,
            contractStateAfterFullRemove.hookBalance0,
            1e15,
            "Hook balance for token0 changed"
        );
        assertApproxEqRel(
            contractStateBeforeAdd.hookBalance1,
            contractStateAfterFullRemove.hookBalance1,
            1e15,
            "Hook balance for token0 changed"
        );
    }
}
