// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {RYieldLensPack} from "../types/Types.sol";

/// @title IRYieldVaultSource — RYieldRegistry·RYieldViews 전용 raw storage 표면.
/// @dev factory·owner·oracle 등 public 상태는 IRYieldVaultMeta cast로 조회(볼트 implements 금지).
interface IRYieldVaultSource {
    function marketId() external view returns (bytes32);
    function rToken() external view returns (address);

    function ryieldPack() external view returns (RYieldLensPack memory);

    function sharesOf(address user) external view returns (uint256);
    function redeemSharesOf(address user) external view returns (uint256);
    function redeemReqEpoch(address user) external view returns (uint256);
    function epochPayoutUsdc(uint256 epoch) external view returns (uint256);
    function epochRedeemShares(uint256 epoch) external view returns (uint256);

    function lensGmxEquityUsdWad() external view returns (uint256);
    function usdcBalance() external view returns (uint256);
    function rTokenBalance() external view returns (uint256);
}
