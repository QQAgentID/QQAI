// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Binance Agent ID registry (BSC 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F).
interface IAgentRegistry {
    function handleOf(address owner) external view returns (string memory);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Minimal ERC-20 surface used by the QQAI contracts. USDT on BSC returns a bool
///         from transfer/transferFrom; callers must check it.
interface IERC20QQAI {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Chainlink price feed surface used by QQAINFT for live cross-currency
///         pricing (dual-currency mint, user decision 24 Nov 2026). The
///         production feed is the BNB/USD aggregator on BSC mainnet,
///         0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE (8 decimals).
interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Minimal PancakeSwap V2 factory surface used by QQAIPoolManager:
///         pair lookup after a router add-liquidity call.
interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/// @notice Minimal PancakeSwap V2 router surface used by QQAIPoolManager:
///         factory discovery plus addLiquidity (the router creates the pair
///         on the first add), plus the WBNB address and the ETH-in swap the
///         manager uses to convert escrow BNB into USDT before pooling
///         (dual-currency mint, user decision 24 Nov 2026).
interface IPancakeRouter {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    /// @notice V2 quote used by QQAIMint to size the buy-through swap's
    ///         min-out (PARAMS §0ab.10).
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256 amountOut);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
    /// @notice Token-in swap to native BNB used by QQAIToken for the
    ///         automatic trade-tax conversion (PARAMS §0ab.15): the
    ///         accrued QQAI tax is swapped through the pair and the BNB
    ///         lands at `to` (TREASURY). Declared WITHOUT a return value
    ///         on purpose — the live router returns an amounts array,
    ///         and callers measure the result by balance deltas instead.
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    /// @notice ETH-in liquidity add used by QQAIMint for the automatic
    ///         pool opening (PARAMS §0ab.5): wraps the BNB into WBNB,
    ///         creates the pair on the first add, LP goes to `to`.
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

/// @notice Minimal PancakeSwap V2 pair surface used by QQAIMint to read
///         the spot price for the post-pool mint pricing (PARAMS §0ab.5).
interface IPancakePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}
