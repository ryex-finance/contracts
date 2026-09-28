// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {VaultSnapshot, GmxPositionData} from "../types/Types.sol";

/// @title IVaultLens — PositionVault 조회 전용 (impl bytecode offload).
interface IVaultLens {
    function collateralValueUsdWad(address vault) external view returns (uint256);
    function debtValueUsdWad(address vault) external view returns (uint256);
    function currentLTV(address vault) external view returns (uint256);
    function lltvBps(address vault) external view returns (uint256);
    function rltBps(address vault) external view returns (uint256);
    function effectiveMaxLtvBps(address vault) external view returns (uint256);
    function healthFactor(address vault) external view returns (uint256);
    function isRedeemable(address vault) external view returns (bool);
    function isLiquidatable(address vault) external view returns (bool);
    function pendingFeesUsdc(address vault) external view returns (uint256);
    /// @notice 마켓별 borrow/stability fee APR (bps). 마켓마다 다를 수 있음(owner setBorrowAprBps).
    function borrowAprBps(address vault) external view returns (uint256);
    function gmxPosition(address vault) external view returns (GmxPositionData memory);
    function vaultInfo(address vault) external view returns (VaultSnapshot memory);

    // ── RLT 상환존 (인덱서용 — 후보 vault만 isRedeemable 필터) ──
    function filterRedeemableVaults(address[] calldata vaults) external view returns (address[] memory redeemable);
    function redeemableCount() external view returns (uint256);
    function totalRedeemableDebt() external view returns (uint256);
    function avgHealthRedeemable() external view returns (uint256);

    /// @notice vault on-chain USDC 잔액 (6dec).
    function residualUsdc(address vault) external view returns (uint256);
    /// @notice rToken 부채의 oracle USDC 환산 (6dec).
    function debtUsdc(address vault) external view returns (uint256);
    /// @notice withdraw 시 owner에게 전달될 USDC 예상치 (6dec). pending·Settling 중이면 0.
    function previewWithdrawUsdc(address vault) external view returns (uint256);
    function canWithdraw(address vault) external view returns (bool);
}
