// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {MockERC20} from "@uniswap/v4-core/test/foundry-tests/utils/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/foundry-tests/utils/SortTokens.sol";
import {FeeLibrary} from "@uniswap/v4-core/contracts/libraries/FeeLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";

library Utils {
    using FeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    function max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    function min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function deployTokens(
        uint8 count,
        uint256 totalSupply
    ) internal returns (MockERC20[] memory tokens) {
        tokens = new MockERC20[](count);
        for (uint8 i = 0; i < count; i++) {
            tokens[i] = new MockERC20("TEST", "TEST", 18, totalSupply);
        }
    }

    function createPool(
        PoolManager manager,
        IHooks hooks,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        bytes memory initData
    ) internal returns (PoolKey memory key, PoolId id) {
        MockERC20[] memory tokens = deployTokens(2, 2 ** 255);
        (Currency currency0, Currency currency1) = SortTokens.sort(
            tokens[0],
            tokens[1]
        );
        key = PoolKey(currency0, currency1, fee, tickSpacing, hooks);
        id = key.toId();
        manager.initialize(key, sqrtPriceX96, initData);
    }
}
