// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @dev scripts/setup/v3/*
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);

    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}
