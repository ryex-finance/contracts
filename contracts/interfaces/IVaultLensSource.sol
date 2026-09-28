// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";
import {VaultState, PendingOrder, GmxOrder} from "../types/Types.sol";

/// @title IVaultLensSource — VaultLens가 읽는 최소 vault 표면.
/// @dev lensGmxSnapshot은 clone 배포 시점 4필드 ABI 유지. GMX liquidationPrice는 Lens가 채움.
interface IVaultLensSource {
    function owner() external view returns (address);
    function collateral() external view returns (uint256);
    function debt() external view returns (uint256);
    function state() external view returns (VaultState);
    function marketId() external view returns (bytes32);
    function leverage() external view returns (uint8);
    function isLong() external view returns (bool);
    function posKey() external view returns (bytes32);
    function oracle() external view returns (IPriceOracle);
    function pending() external view returns (PendingOrder memory);
    function accruedFeesUsdc() external view returns (uint256);
    function accruedBorrowFeeUsdc() external view returns (uint256);
    function lastAccrual() external view returns (uint256);
    function tpOrderKey() external view returns (bytes32);
    function slOrderKey() external view returns (bytes32);
    function slTriggerPrice8() external view returns (uint256);
    /// @dev exists, sizeInUsd, collateralAmount, entryPrice8 (liquidationPrice 없음)
    function lensGmxSnapshot()
        external
        view
        returns (bool exists, uint256 sizeInUsd, uint256 collateralAmount, uint256 entryPrice8);
    function lensGmxEquityUsdWad() external view returns (uint256);
    /// @dev pending 주문(RYex orderKey)의 GMX 담보 증가분 조회용. 없는 키 조회 시 zero-struct 반환.
    function gmxOrders(bytes32 orderKey) external view returns (GmxOrder memory);
}
