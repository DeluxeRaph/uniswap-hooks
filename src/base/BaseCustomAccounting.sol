// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/base/BaseCustomAccounting.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import "forge-std/console.sol";


/**
 * @dev Base implementation for custom accounting and hook-owned liquidity.
 *
 * To enable hook-owned liquidity, tokens must be deposited via the hook to allow control and flexibility
 * over the liquidity. The implementation inheriting this hook must implement the respective functions
 * to calculate the liquidity modification parameters and the amount of liquidity shares to mint or burn.
 *
 * Additionally, the implementer must consider that the hook is the sole owner of the liquidity and
 * manage fees over liquidity shares accordingly.
 *
 * NOTE: This base hook is designed to work with a single pool key. If you want to use the same custom
 * accounting hook for multiple pools, you must have multiple storage instances of this contract and
 * initialize them via the `PoolManager` with their respective pool keys.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseCustomAccounting is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /**
     * @dev A liquidity modification order was attempted to be executed after the deadline.
     */
    error ExpiredPastDeadline();

    /**
     * @dev Pool was not initialized.
     */
    error PoolNotInitialized();

    /**
     * @dev Principal delta of liquidity modification resulted in too much slippage.
     */
    error TooMuchSlippage();

    /**
     * @dev Liquidity was attempted to be added or removed via the `PoolManager` instead of the hook.
     */
    error LiquidityOnlyViaHook();

    /**
     * @dev Native currency was not sent with the correct amount.
     */
    error InvalidNativeValue();

    /**
     * @dev Hook was already initialized.
     */
    error AlreadyInitialized();

    struct AddLiquidityParams {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    struct RemoveLiquidityParams {
        uint256 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    struct CallbackData {
        address sender;
        IPoolManager.ModifyLiquidityParams params;
    }

    /**
     * @notice The hook's pool key.
     */
    PoolKey public poolKey;

    /**
     * @dev Ensure the deadline of a liquidity modification request is not expired.
     *
     * @param deadline Deadline of the request, passed in by the caller.
     */
    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    /**
     * @dev Set the pool `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @notice Adds liquidity to the hook's pool.
     *
     * @dev To cover all possible scenarios, `msg.sender` should have already given the hook an allowance
     * of at least amount0Desired/amount1Desired on token0/token1. Always adds assets at the ideal ratio,
     * according to the price when the transaction is executed.
     *
     * NOTE: The `amount0Min` and `amount1Min` parameters are relative to the principal delta, which excludes
     * fees accrued from the liquidity modification delta.
     *
     * @param params The parameters for the liquidity addition.
     * @return delta The principal delta of the liquidity addition.
     */
    function addLiquidity(AddLiquidityParams calldata params)
        external
        payable
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Revert if msg.value is non-zero but currency0 is not native, or if currency0 is native but msg.value doesn't match
        bool isNative = poolKey.currency0.isAddressZero();
        if (!isNative) {
            if (msg.value > 0) revert InvalidNativeValue();
        } else if (msg.value != params.amount0Desired) {
            revert InvalidNativeValue();
        }

        // Get the liquidity modification parameters and the amount of liquidity shares to mint
        (bytes memory modifyParams, uint256 shares) = _getAddLiquidity(sqrtPriceX96, params);

        // Apply the liquidity modification using callerDelta directly
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modifyLiquidity(modifyParams);

        // Calculate the principal delta only once here (excluding fees)
        delta = callerDelta - feesAccrued;

        // Perform slippage check using principal delta
        uint128 amount0 = uint128(-delta.amount0());
        uint128 amount1 = uint128(-delta.amount1());

        // Mint the liquidity shares to the `params.to` address
        _mint(params, callerDelta, feesAccrued, shares);

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert TooMuchSlippage();
        }

        // If the currency0 is native, refund any remaining amount if the amount received is less than the amount desired.
        if (isNative && amount0 < params.amount0Desired) {
            poolKey.currency0.transfer(msg.sender, params.amount0Desired - amount0);
        }
    }

    /**
     * @notice Removes liquidity from the hook's pool.
     *
     * @dev `msg.sender` should have already given the hook allowance of at least liquidity on the pool.
     *
     * NOTE: The `amount0Min` and `amount1Min` parameters are relative to the principal delta, which
     * excludes fees accrued from the liquidity modification delta.
     *
     * @param params The parameters for the liquidity removal.
     * @return delta The principal delta of the liquidity removal.
     */
    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Get the liquidity modification parameters and the amount of liquidity shares to burn
        (bytes memory modifyParams, uint256 shares) = _getRemoveLiquidity(params);

        // Apply the liquidity modification using callerDelta directly
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modifyLiquidity(modifyParams);

        // Calculate the principal delta only once here (excluding fees)
        delta = callerDelta - feesAccrued;

        // Perform slippage check using principal delta
        uint128 amount0 = uint128(-delta.amount0());
        uint128 amount1 = uint128(-delta.amount1());

        // Burn the liquidity shares from the sender
        _burn(params, callerDelta, feesAccrued, shares);

        // Check for slippage
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    /**
     * @dev Calls the `PoolManager` to unlock and call back the hook's `_unlockCallback` function.
     *
     * @param params The encoded parameters for the liquidity modification based on the `ModifyLiquidityParams` struct.
     * @return callerDelta The balance delta from the liquidity modification. This is the total of both principal and fee deltas.
     * @return feesAccrued The balance delta of the fees generated in the liquidity range.
     */
    // slither-disable-next-line dead-code
    function _modifyLiquidity(bytes memory params)
        internal
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
     * @dev Callback from the `PoolManager` when liquidity is modified, either adding or removing.
     *
     * @param rawData The encoded `CallbackData` struct.
     * @return returnData The encoded caller and fees accrued deltas.
     */
    function unlockCallback(bytes calldata rawData)
        external
        override
        virtual
        onlyPoolManager
        returns (bytes memory returnData)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolKey memory key = poolKey;

        // Get liquidity modification deltas
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, data.params, "");

        // Handle each currency amount based on its sign
        if (callerDelta.amount0() < 0) {
            // If amount0 is negative, send tokens from the sender to the pool
            key.currency0.settle(poolManager, data.sender, uint256(int256(-callerDelta.amount0())), false);
        } else {
            // If amount0 is positive, send tokens from the pool to the sender
            key.currency0.take(poolManager, data.sender, uint256(int256(callerDelta.amount0())), false);
        }

        if (callerDelta.amount1() < 0) {
            // If amount1 is negative, send tokens from the sender to the pool
            key.currency1.settle(poolManager, data.sender, uint256(int256(-callerDelta.amount1())), false);
        } else {
            // If amount1 is positive, send tokens from the pool to the sender
            key.currency1.take(poolManager, data.sender, uint256(int256(callerDelta.amount1())), false);
        }

        // Return both deltas so that slippage checks can be done on the principal delta
        return abi.encode(callerDelta, feesAccrued);
    }

    /**
     * @dev Initialize the hook's pool key. The stored key should act immutably so that
     * it can safely be used across the hook's functions.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // Check if the pool key is already initialized
        if (address(poolKey.hooks) != address(0)) revert AlreadyInitialized();

        // Store the pool key to be used in other functions
        poolKey = key;
        return this.beforeInitialize.selector;
    }

    /**
     * @dev Revert when liquidity is attempted to be added via the `PoolManager`.
     */
    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert LiquidityOnlyViaHook();
    }

    /**
     * @dev Revert when liquidity is attempted to be removed via the `PoolManager`.
     */
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        revert LiquidityOnlyViaHook();
    }

    /**
     * @dev Get the liquidity modification to apply for a given liquidity addition,
     * and the amount of liquidity shares would be minted to the sender.
     *
     * @param sqrtPriceX96 The current square root price of the pool.
     * @param params The parameters for the liquidity addition.
     * @return modify The encoded parameters for the liquidity addition, which must follow the
     * same encoding structure as in `_getRemoveLiquidity` and `_modifyLiquidity`.
     * @return shares The liquidity shares to mint.
     *
     * IMPORTANT: The returned `modify` must contain a unique salt for each liquidity provider and
     * specified salt combination, according to the `ModifyLiquidityParams` struct in the default
     * implementation, to prevent unauthorized withdrawals of their liquidity position and accrued fees.
     *
     * NOTE: The returned `ModifyLiquidityParams` struct encoded in `modify` should never return
     * parameters which when passed to `PoolManager.modifyLiquidity` cause the `delta.amount0` to be
     * greater than `params.amount0Desired`.
     */
    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 shares);

    /**
     * @dev Get the liquidity modification to apply for a given liquidity removal,
     * and the amount of liquidity shares would be burned from the sender.
     *
     * @param params The parameters for the liquidity removal.
     * @return modify The encoded parameters for the liquidity removal, which must follow the
     * same encoding structure as in `_getAddLiquidity` and `_modifyLiquidity`.
     * @return shares The liquidity shares to burn.
     *
     * IMPORTANT: The returned `modify` must contain a unique salt for each liquidity provider and
     * specified salt combination, according to the `ModifyLiquidityParams` struct in the default
     * implementation, to prevent unauthorized withdrawals of their liquidity position and accrued fees.
     */
    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 shares);

    /**
     * @dev Mint liquidity shares to the sender.
     *
     * @param params The parameters for the liquidity addition.
     * @param callerDelta The balance delta from the liquidity addition. This is the total of both principal and fee delta.
     * @param feesAccrued The balance delta of the fees generated in the liquidity range.
     * @param shares The liquidity shares to mint.
     */
    function _mint(AddLiquidityParams memory params, BalanceDelta callerDelta, BalanceDelta feesAccrued, uint256 shares)
        internal
        virtual;

    /**
     * @dev Burn liquidity shares from the sender.
     *
     * @param params The parameters for the liquidity removal.
     * @param callerDelta The balance delta from the liquidity removal. This is the total of both principal and fee delta.
     * @param feesAccrued The balance delta of the fees generated in the liquidity range.
     * @param shares The liquidity shares to burn.
     */
    function _burn(
        RemoveLiquidityParams memory params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        uint256 shares
    ) internal virtual;

    /**
     * @dev Set the hook permissions, specifically `beforeInitialize`, `beforeAddLiquidity` and `beforeRemoveLiquidity`.
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
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
