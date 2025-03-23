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

import "forge-std/console.sol";

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
        // Total liquidity recviced
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

   function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        view
        override
        returns (bytes memory, uint256 liquidity)
    {
        liquidity = FullMath.mulDiv(params.liquidity, poolManager.getLiquidity(poolKey.toId()), totalSupply());

        return (
            abi.encode(
                IPoolManager.ModifyLiquidityParams({
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: -liquidity.toInt256(),
                    salt: 0
                })
            ),
            liquidity
        );
    }

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
