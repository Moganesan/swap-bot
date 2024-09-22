// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IMulticall.sol";
import "./Interfaces/IQuoter.sol";
import "./Interfaces/ISwapRouterV2.sol";
import "./Interfaces/ISwapRouterV3.sol";
import "./Interfaces/IFactoryV2.sol";
import "./Interfaces/IFactoryV3.sol";
import "./Interfaces/IPair.sol";

contract SwapBot is Ownable, ReentrancyGuard {
    uint256 public deadline = type(uint256).max;
    uint256 public fee = 1;
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
        address swap,
        address user,
        address factory,
        address quoter,
        address[] memory path,
        uint256 amount,
        uint256 slippage
    ) internal nonReentrant {
        address pairAddr = IUniswapV3Factory(factory).getPool(
            path[0],
            path[1],
            3000
        );
        (uint112 reserve0, uint112 reserve1, ) = IPair(pairAddr).getReserves();

        (uint256 ethAmt, uint256 tokenAmt) = (reserve0, reserve1);
        if (IPair(pairAddr).token0() != wtoken) {
            (ethAmt, tokenAmt) = (reserve1, reserve0);
        }

        // Get quote
        uint256 quoteAmountOut = IQuoter(quoter).quoteExactInputSingle(
            path[0],
            path[1],
            3000, // 0.3% fee
            amount,
            0
        );

        // Calculate minAmountOut with slippage tolerance
        uint256 minAmountOut = (quoteAmountOut * (10000 - slippage)) / 10000;

        ISwapRouterV3.ExactInputSingleParams memory params = ISwapRouterV3
            .ExactInputSingleParams({
                tokenIn: address(path[0]),
                tokenOut: address(path[1]),
                fee: 3000,
                recipient: user,
                deadline: block.timestamp + 15 minutes,
                amountIn: msg.value,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            ISwapRouterV3.exactInputSingle.selector,
            params
        );

        bytes[] memory results = IMulticall(address(ISwapRouterV3(swap)))
            .multicall{value: amount}(data);

        uint256 output = abi.decode(results[0], (uint256));

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

        internalBuy(
            wtoken,
            swap,
            payable(msg.sender),
            path,
            (amount * (100 - fee)) / (100),
            slippage
        );
    }

    function buyTokenV3(
        address wtoken,
        address swap,
        address factory,
        address quoter,
        address token,
        uint256 amount,
        uint256 slippage
    ) external payable {
        require(msg.value >= amount * (1 wei), "Insufficient ether amount");

        address[] memory path = new address[](2);
        path[0] = wtoken;
        path[1] = token;

        internalBuyV3(
            wtoken,
            swap,
            msg.sender,
            factory,
            quoter,
            path,
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
        user.transfer((output / 100) * (100 - fee));
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

    function estimateSellResult(
        address wtoken,
        address swap,
        address token,
        uint256 amount,
        address factoryAddr
    ) external view returns (uint256 output) {
        address pairAddr = IFactoryV2(factoryAddr).getPair(token, wtoken);
        (uint112 reserve0, uint112 reserve1, ) = IPair(pairAddr).getReserves();

        (uint256 ethAmt, uint256 tokenAmt) = (reserve0, reserve1);
        if (IPair(pairAddr).token0() != wtoken) {
            (ethAmt, tokenAmt) = (reserve1, reserve0);
        }

        output =
            (ISwapRouterV2(swap).getAmountOut(amount, tokenAmt, ethAmt) / 100) *
            (100 - fee);
    }

    function addLiquidity(
        address swapProtocol,
        address token,
        uint256 amountEthDesired,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to
    )
        external
        payable
        onlyOwner
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        require(
            msg.value >= amountEthDesired * (1 wei),
            "Insufficient ETH amount"
        );

        uint256 etherAmount = amountEthDesired * (1 wei);
        (amountToken, amountETH, liquidity) = ISwapRouterV2(swapProtocol)
            .addLiquidityETH{value: etherAmount}(
            token,
            amountTokenDesired,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );

        emit AddLiquidityETH(token, amountToken, amountETH, liquidity);
    }

    function setFee(uint256 _fee) external onlyOwner {
        fee = _fee;
    }

    function withdraw(
        uint256 _amount,
        address payable _receiver
    ) external onlyOwner {
        _receiver.transfer(_amount);
    }

    receive() external payable {}
    fallback() external payable {}
}
