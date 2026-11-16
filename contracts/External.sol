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

/// @notice Minimal PancakeSwap V2 pair surface used by QQAIClaim's mining
///         thermostat: reserve reads plus token ordering.
interface IPancakePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/// @notice Minimal PancakeSwap V2 factory surface used by QQAIPoolManager:
///         pair lookup after a router add-liquidity call.
interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/// @notice Minimal PancakeSwap V2 router surface used by QQAIPoolManager:
///         factory discovery plus addLiquidity (the router creates the pair
///         on the first add).
interface IPancakeRouter {
    function factory() external view returns (address);
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
}
