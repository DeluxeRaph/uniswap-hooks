// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BaseCustomCurve} from "src/base/BaseCustomCurve.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";


import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract BaseCustomCurveMock is BaseCustomCurve, ERC20 {
    constructor(IPoolManager _manager) BaseCustomCurve(_manager) ERC20("Mock", "MOCK") {}
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    bool public nativeRefund;

    function _getUnspecifiedAmount(IPoolManager.SwapParams calldata params)
        internal
        virtual
        override
        returns (uint256 unspecifiedAmount)
    {
        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) = (params.zeroForOne == exactInput)
            ? (poolKey.currency0, poolKey.currency1)
            : (poolKey.currency1, poolKey.currency0);
        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        Currency input = exactInput ? specified : unspecified;
        Currency output = exactInput ? unspecified : specified;

        return exactInput
            ? _getAmountOutFromExactInput(specifiedAmount, input, output, params.zeroForOne)
            : _getAmountInForExactOutput(specifiedAmount, input, output, params.zeroForOne);
    }

    function _getAmountOutFromExactInput(uint256 amountIn, Currency, Currency, bool)
        internal
        pure
        returns (uint256 amountOut)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountOut = amountIn;
    }

    function _getAmountInForExactOutput(uint256 amountOut, Currency, Currency, bool)
        internal
        pure
        returns (uint256 amountIn)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountIn = amountOut;
    }

    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        view
        override
        returns (bytes memory modify, uint256 liquidity)
    {
        // Find total liquidity corresponding to the amounts
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
           params.amount0Desired,
           params.amount1Desired
        );

        return (
            abi.encode(
                IPoolManager.ModifyLiquidityParams({
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: liquidity.toInt256(),
                    salt: 0
                })
            ),
            liquidity
        );
    }

    // /**
    //  * @notice Removes liquidity from the hook's pool.
    //  *
    //  * @dev `msg.sender` should have already given the hook allowance of at least liquidity on the pool.
    //  *
    //  * NOTE: The `amount0Min` and `amount1Min` parameters are relative to the principal delta, which
    //  * excludes fees accrued from the liquidity modification delta.
    //  *
    //  * @param params The parameters for the liquidity removal.
    //  * @return delta The principal delta of the liquidity removal.
    //  */
    // function removeLiquidity(RemoveLiquidityParams calldata params)
    //     external
    //     virtual
    //     override
    //     ensure(params.deadline)
    //     returns (BalanceDelta delta)
    // {
    //     (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

    //     if (sqrtPriceX96 == 0) revert PoolNotInitialized();

    //     // Get the liquidity modification parameters and the amount of liquidity shares to burn
    //     (bytes memory modifyParams, uint256 shares) = _getRemoveLiquidity(params);

    //     // Apply the liquidity modification
    //     (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modifyLiquidity(modifyParams);

    //     // Burn the liquidity shares from the sender
    //     _burn(params, callerDelta, feesAccrued, shares);

    //     // Get the principal delta by subtracting the fee delta from the caller delta (-= is not supported)
    //     delta = callerDelta - feesAccrued;

    //     // Check for slippage
    //     if (uint128(delta.amount0()) < params.amount0Min || uint128(delta.amount1()) < params.amount1Min) {
    //         revert TooMuchSlippage();
    //     }
    // }

    function _getAmountIn(AddLiquidityParams memory params)
        internal
        pure
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        liquidity = (amount0 + amount1) / 2;
    }

    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        pure
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        amount0 = params.liquidity / 2;
        amount1 = params.liquidity / 2;
        liquidity = params.liquidity;
    }

    function _mint(AddLiquidityParams memory params, BalanceDelta, BalanceDelta, uint256 liquidity) internal override {
        _mint(params.to, liquidity);
    }

    function _burn(RemoveLiquidityParams memory, BalanceDelta, BalanceDelta, uint256 liquidity) internal override {
        _burn(msg.sender, liquidity);
    }

    // Exclude from coverage report
    function test() public {}
}
