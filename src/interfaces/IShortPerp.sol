// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IShortPerp — funding-bearing short perp boundary (rYield hedge funding leg).
/// @notice Demo = MockShortPerp; swap for a real venue adapter (GMX/Hyperliquid/Ostium)
///         behind the same interface. The caller is the position owner.
interface IShortPerp {
    function openShort(uint256 marginUsdc, uint256 sizeUsdc) external returns (bytes32 key);
    function claimFunding(bytes32 key) external returns (uint256 amount);
    function closeShort(bytes32 key) external returns (uint256 payout);
    function accruedFunding(bytes32 key) external view returns (uint256);
    function positionValueUsdc(bytes32 key) external view returns (uint256);
}
