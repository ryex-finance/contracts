// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IGmxPriceFeedProvider — GMX v2 ChainlinkPriceFeedProvider (view)
/// @notice Arbitrum Sepolia: 0xa76BF7f977E80ac0bff49BDC98a27b7b070a937d
interface IGmxPriceFeedProvider {
    /// @return min/max GMX 30-dec USD price per 1 index token unit (see GMX Oracle docs).
    function getOraclePrice(address token, bytes memory data)
        external
        view
        returns (address, uint256 min, uint256 max, uint256 timestamp, address provider);
}
