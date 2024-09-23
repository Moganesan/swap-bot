// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IMulticall.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "./Interfaces/IQuoter.sol";
import "./Interfaces/ISwapRouterV2.sol";
import "./Interfaces/ISwapRouterV3.sol";
import "./Interfaces/IUniswapV3Pool.sol";
import "./Interfaces/IFactoryV2.sol";
import "./Interfaces/IFactoryV3.sol";
import "./Interfaces/IPair.sol";

contract SwapBot is Ownable, ReentrancyGuard {
    uint256 public deadline = type(uint256).max;
    address admin;

    event AddLiquidityETH(
        address token,
        uint256 amountToken,
        uint256 amountETH,
        uint256 liquidity
    );

    event OnlyAdmin(address _caller, address _admin);

    constructor() Ownable(msg.sender) {
        admin = address(this);
    }

    function calculateExpectedOutputV3(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amountIn,
        uint24 fee
    ) internal pure returns (uint256) {
        uint256 virtualReserveIn = FullMath.mulDiv(
            liquidity,
            1 << 96,
            sqrtPriceX96
        );
        uint256 virtualReserveOut = FullMath.mulDiv(
            liquidity,
            sqrtPriceX96,
            1 << 96
        );

        uint256 amountInWithFee = amountIn * (1e6 - fee);
        uint256 numerator = amountInWithFee * virtualReserveOut;
        uint256 denominator = (virtualReserveIn * 1e6) + amountInWithFee;
        return numerator / denominator;
    }

    function internalBuy(
        address wtoken,
        address swap,
        address user,
        address[] memory path,
        uint256 amount,
        uint256 slippage
    ) internal nonReentrant {
        address factoryAddr = ISwapRouterV2(swap).factory();
        address pairAddr = IFactoryV2(factoryAddr).getPair(path[0], path[1]);
        (uint112 reserve0, uint112 reserve1, ) = IPair(pairAddr).getReserves();

        (uint256 ethAmt, uint256 tokenAmt) = (reserve0, reserve1);
        if (IPair(pairAddr).token0() != wtoken) {
            (ethAmt, tokenAmt) = (reserve1, reserve0);
        }

        uint256 output = ISwapRouterV2(swap).getAmountOut(
            amount,
            ethAmt,
            tokenAmt
        );
        uint256 expect = (amount * tokenAmt) / (ethAmt);

        require(
            expect > 0,
            "Expected output amount should be greater than zero"
        );
        uint256 differ = ((expect - output) * (100)) / (expect);

        require(
            differ < slippage,
            "Trade output is less than minimum expected"
        );

        uint256 ethAmount = amount * 1 wei;
        ISwapRouterV2(swap).swapExactETHForTokens{value: ethAmount}(
            0,
            path,
            user,
            deadline
        );
    }

    function internalBuyV3(
        address wtoken,
        address token,
        address swap,
        address factory,
        address user,
        uint24 fee,
        uint256 amount,
        uint256 slippage
    ) internal nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Get the pool for the token pair
        address poolAddress = IUniswapV3Factory(factory).getPool(
            wtoken,
            token,
            fee
        );
        require(poolAddress != address(0), "Pool does not exist");

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        // Get current price and liquidity from the pool
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint128 liquidity = pool.liquidity();

        // Calculate the expected output
        uint256 expectedOutput = calculateExpectedOutputV3(
            sqrtPriceX96,
            liquidity,
            amount,
            fee
        );

        // Calculate the minimum acceptable output based on slippage
        uint256 minOutput = (expectedOutput * (10000 - slippage)) / 10000;

        // Prepare the swap parameters
        ISwapRouterV3.ExactInputSingleParams memory params = ISwapRouterV3
            .ExactInputSingleParams({
                tokenIn: wtoken,
                tokenOut: token,
                fee: fee,
                recipient: user,
                deadline: block.timestamp + 15 minutes,
                amountIn: amount,
                amountOutMinimum: minOutput,
                sqrtPriceLimitX96: 0
            });

        // Execute the swap
        uint256 amountOut = ISwapRouterV3(swap).exactInputSingle{value: amount}(
            params
        );

        require(amountOut >= minOutput, "Output is less than minimum expected");
    }

    function buyToken(
        address wtoken,
        address swap,
        address token,
        uint256 amount,
        uint256 slippage
    ) external payable {
        require(msg.value >= amount * (1 wei), "Insufficient ether amount");

        address[] memory path = new address[](2);
        path[0] = wtoken;
        path[1] = token;

        internalBuy(wtoken, swap, payable(msg.sender), path, amount, slippage);
    }

    function buyTokenV3(
        address wtoken,
        address swap,
        address token,
        address factory,
        uint256 amount,
        uint256 slippage
    ) external payable {
        require(msg.value >= amount * (1 wei), "Insufficient ether amount");

        address[] memory path = new address[](2);
        path[0] = wtoken;
        path[1] = token;

        internalBuyV3(
            wtoken,
            token,
            swap,
            factory,
            msg.sender,
            3000,
            amount,
            slippage
        );
    }

    function internalSell(
        address wtoken,
        address swap,
        address payable user,
        address[] memory path,
        uint256 amount,
        uint256 slippage
    ) internal nonReentrant {
        address factoryAddr = ISwapRouterV2(swap).factory();
        address pairAddr = IFactoryV2(factoryAddr).getPair(path[0], path[1]);
        (uint112 reserve0, uint112 reserve1, ) = IPair(pairAddr).getReserves();

        IERC20(path[0]).approve(swap, amount);

        (uint256 ethAmt, uint256 tokenAmt) = (reserve0, reserve1);
        if (IPair(pairAddr).token0() != wtoken) {
            (ethAmt, tokenAmt) = (reserve1, reserve0);
        }

        uint256 output = ISwapRouterV2(swap).getAmountOut(
            amount,
            tokenAmt,
            ethAmt
        );
        uint256 expect = (amount * (ethAmt)) / (tokenAmt);

        require(
            expect > 0,
            "Expected output amount should be greater than zero"
        );
        uint256 differ = ((expect - output) * (100)) / (expect);

        require(
            differ < slippage,
            "Trade output is less than minimum expected"
        );

        ISwapRouterV2(swap).swapExactTokensForETH(
            amount,
            0,
            path,
            address(this),
            deadline
        );
        user.transfer(output);
    }

    function sellToken(
        address wtoken,
        address swap,
        address token,
        uint256 amount,
        uint256 slippage
    ) external payable {
        require(
            IERC20(token).balanceOf(msg.sender) >= amount,
            "Insufficient token balance"
        );

        IERC20(token).transferFrom(msg.sender, address(this), amount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = wtoken;

        internalSell(wtoken, swap, payable(msg.sender), path, amount, slippage);
    }

    function internalSellV3(
        address wtoken,
        address token,
        address swap,
        address factory,
        address payable user,
        uint24 poolFee,
        uint256 amount,
        uint256 slippage
    ) internal nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Get the pool for the token pair
        address poolAddress = IUniswapV3Factory(factory).getPool(
            token,
            wtoken,
            poolFee
        );
        require(poolAddress != address(0), "Pool does not exist");

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        // Get current price and liquidity from the pool
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint128 liquidity = pool.liquidity();

        // Calculate the expected output
        uint256 expectedOutput = calculateExpectedOutputV3(
            sqrtPriceX96,
            liquidity,
            amount,
            poolFee
        );

        // Calculate the minimum acceptable output based on slippage
        uint256 minOutput = (expectedOutput * (10000 - slippage)) / 10000;

        // Approve the router to spend tokens
        TransferHelper.safeApprove(token, address(swap), amount);

        // Prepare the swap parameters
        ISwapRouterV3.ExactInputSingleParams memory params = ISwapRouterV3
            .ExactInputSingleParams({
                tokenIn: token,
                tokenOut: wtoken,
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp + 15 minutes,
                amountIn: amount,
                amountOutMinimum: minOutput,
                sqrtPriceLimitX96: 0
            });

        // Execute the swap
        uint256 amountOut = ISwapRouterV3(swap).exactInputSingle(params);

        require(amountOut >= minOutput, "Output is less than minimum expected");

        // Transfer the ETH to the user, minus the fee
        uint256 amountToUser = amountOut;
        TransferHelper.safeTransferETH(user, amountToUser);
    }

    function sellTokenV3(
        address wtoken,
        address swap,
        address factory,
        address token,
        uint256 amount,
        uint256 slippage
    ) external {
        require(
            IERC20(token).balanceOf(msg.sender) >= amount,
            "Insufficient token balance"
        );

        IERC20(token).transferFrom(msg.sender, address(this), amount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = wtoken;

        internalSellV3(
            wtoken,
            token,
            swap,
            factory,
            payable(msg.sender),
            3000,
            amount,
            slippage
        );
    }

    receive() external payable {}
    fallback() external payable {}
}
