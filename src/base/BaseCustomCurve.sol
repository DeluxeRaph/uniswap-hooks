// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/base/BaseCustomCurve.sol)

pragma solidity ^0.8.24;

import {BaseCustomAccounting} from "src/base/BaseCustomAccounting.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

import "forge-std/console.sol";

/**
 * @dev Base implementation for custom curves, inheriting from {BaseCustomAccounting}.
 *
 * This hook allows to implement a custom curve (or any logic) for swaps, which overrides the default v3-like
 * concentrated liquidity implementation of the `PoolManager`. During a swap, the hook calls the
 * {_getUnspecifiedAmount} function to get the amount of tokens to be sent to the receiver. The return delta
 * created from this calculation is then consumed and applied by the `PoolManager`.
 *
 * NOTE: This hook by default does not include a fee mechanism, which can be implemented by inheriting
 * contracts if needed.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseCustomCurve is BaseCustomAccounting {
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    /**
     * @dev Set the pool `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseCustomAccounting(_poolManager) {}

    /**
     * @dev Overides the default swap logic of the `PoolManager` and calls the {_getUnspecifiedAmount}
     * to get the amount of tokens to be sent to the receiver.
     *
     * NOTE: In order to take and settle tokens from the pool, the hook must hold the liquidity added
     * via the {addLiquidity} function.
     */
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Determine if the swap is exact input or exact output
        bool exactInput = params.amountSpecified < 0;

        // Determine which currency is specified and which is unspecified
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        // Get the positive specified amount
        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Get the amount of the unspecified currency to be taken or settled
        uint256 unspecifiedAmount = _getUnspecifiedAmount(params);

        // New delta must be returned, so store in memory
        BeforeSwapDelta returnDelta;

        if (exactInput) {
            // For exact input swaps:
            // 1. Take the specified input (user-given) amount from this contract's balance in the pool
            specified.take(poolManager, address(this), specifiedAmount, true);
            // 2. Send the calculated output amount to this contract's balance in the pool
            unspecified.settle(poolManager, address(this), unspecifiedAmount, true);

            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        } else {
            // For exact output swaps:
            // 1. Take the calculated input amount from this contract's balance in the pool
            unspecified.take(poolManager, address(this), unspecifiedAmount, true);
            // 2. Send the specified (user-given) output amount to this contract's balance in the pool
            specified.settle(poolManager, address(this), specifiedAmount, true);

            returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
        }

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    /**
     * @dev Overides the custom accounting logic to support the custom curve integer amounts.
     *
     * @param params The parameters for the liquidity modification, encoded in the
     * {_getAddLiquidity} or {_getRemoveLiquidity} function.
     * @return callerDelta The balance delta from the liquidity modification. This is the total of both principal and fee deltas.
     * @return feesAccrued The balance delta of the fees generated in the liquidity range.
     */
    function _modifyLiquidity(bytes memory params)
        internal
        override
        virtual
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        (callerDelta, feesAccrued) = abi.decode(
            poolManager.unlock(
                abi.encode(CallbackData(msg.sender, abi.decode(params, (IPoolManager.ModifyLiquidityParams))))
            ),
            (BalanceDelta, BalanceDelta)
        );
    }

    /**
     * @dev Decodes the callback data and applies the liquidity modifications, overriding the custom
     * accounting logic to mint and burn ERC-6909 claim tokens which are used in swaps.
     *
     * @param rawData The callback data encoded in the {_modifyLiquidity} function.
     * @return returnData The encoded caller and fees accrued deltas.
     */
    function unlockCallback(bytes calldata rawData)
    external
    virtual
    override
    onlyPoolManager
    returns (bytes memory returnData)
{
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolKey memory key = poolKey;

        // Get liquidity modification deltas
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, data.params, "");

        // Handle each currency amount based on its sign
        if (callerDelta.amount0() < 0) { // callerDelta -10000000000000000000
            key.currency0.settle(poolManager, data.sender, uint256(int256(-callerDelta.amount0())), false); // -callerDelta 10000000000000000000
        } else {
            key.currency0.take(poolManager, data.sender, uint256(int256(callerDelta.amount0())), true); // 
        }

        if (callerDelta.amount1() < 0) {
            key.currency1.settle(poolManager, data.sender, uint256(int256(-callerDelta.amount1())), false);
        } else {
            key.currency1.take(poolManager, data.sender, uint256(int256(callerDelta.amount1())), true);
        }

        // Return both deltas so that slippage checks can be done on the principal delta
        return abi.encode(callerDelta, feesAccrued);
    }


    /**
     * @dev Calculate the amount of the unspecified currency to be taken or settled from the swapper, depending on the swap
     * direction.
     *
     * @param params The swap parameters.
     * @return unspecifiedAmount The amount of the unspecified currency to be taken or settled.
     */
    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata params)
        internal
        virtual
        returns (uint256 unspecifiedAmount);

    /**
     * @dev Calculate the amount of tokens to use and liquidity shares to burn for a remove liquidity request.
     * @return amount0 The amount of token0 to be received by the liquidity provider.
     * @return amount1 The amount of token1 to be received by the liquidity provider.
     * @return shares The amount of liquidity shares to be burned by the liquidity provider.
     */
    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1, uint256 shares);

    /**
     * @dev Calculate the amount of tokens to use and liquidity shares to mint for an add liquidity request.
     * @return amount0 The amount of token0 to be sent by the liquidity provider.
     * @return amount1 The amount of token1 to be sent by the liquidity provider.
     * @return shares The amount of liquidity shares to be minted by the liquidity provider.
     */
    function _getAmountIn(AddLiquidityParams memory params)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1, uint256 shares);

    /**
     * @dev Set the hook permissions, specifically `beforeInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`,
     * `beforeSwap`, and `beforeSwapReturnDelta`
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
