// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IVaultFactory} from "./IVaultFactory.sol";
import {IPriceOracle} from "./IPriceOracle.sol";
import {RYieldState, RYieldVaultSummary, RYieldUserSummary, RYieldFundingSummary} from "../types/Types.sol";

/// @title IRYieldRegistry — rYield 마켓 레지스트리 + vault view 1:1 조회(marketId 진입).
interface IRYieldRegistry {
    event RYieldVaultRegistered(
        bytes32 indexed marketId, address indexed vault, address indexed distributor, address rToken
    );
    event RYieldVaultUnregistered(bytes32 indexed marketId, address indexed vault, address rToken);
    event RYieldVaultReplaced(
        bytes32 indexed marketId,
        address indexed oldVault,
        address indexed newVault,
        address distributor,
        address rToken
    );

    function factory() external view returns (IVaultFactory);

    function register(bytes32 marketId, address vault, address distributor) external;
    function unregister(bytes32 marketId) external;
    function replaceVault(bytes32 marketId, address vault, address distributor) external;

    function vaultOf(bytes32 marketId) external view returns (address);
    function distributorOf(bytes32 marketId) external view returns (address);
    function vaultByRToken(address rToken) external view returns (address);
    function marketIdOfVault(address vault) external view returns (bytes32);
    function isRYieldVault(address vault) external view returns (bool);
    function totalVaults() external view returns (uint256);
    function vaultAt(uint256 index) external view returns (address);

    // ── identity (marketId) ─────────────────────────────────────────────────────
    function assetName(bytes32 marketId) external view returns (string memory);
    function rToken(bytes32 marketId) external view returns (address);
    function oracle(bytes32 marketId) external view returns (IPriceOracle);
    function owner(bytes32 marketId) external view returns (address);
    function treasury(bytes32 marketId) external view returns (address);

    // ── vault views (marketId) — RYieldVault에서 이전된 1:1 조회 ───────────────
    function execFee(bytes32 marketId) external view returns (uint256);
    function execFeeBalance(bytes32 marketId) external view returns (uint256);
    function totalShares(bytes32 marketId) external view returns (uint256);
    function ryieldState(bytes32 marketId) external view returns (RYieldState);
    function pendingOrderKey(bytes32 marketId) external view returns (bytes32);
    function pendingCreatedAt(bytes32 marketId) external view returns (uint256);
    function depositCap(bytes32 marketId) external view returns (uint256);
    function perfFeeBps(bytes32 marketId) external view returns (uint16);
    function maxPriceImpactBps(bytes32 marketId) external view returns (uint16);
    function maxExitDiscountBps(bytes32 marketId) external view returns (uint16);
    function targetLeverage(bytes32 marketId) external view returns (uint8);
    function hwmAssetsPerShareWad(bytes32 marketId) external view returns (uint256);
    function longRTokenBalance(bytes32 marketId) external view returns (uint256);
    function longValueUsdc(bytes32 marketId) external view returns (uint256);
    function shortEquityUsdc(bytes32 marketId) external view returns (uint256);
    function totalAssetsUsdc(bytes32 marketId) external view returns (uint256);
    function pricePerShareWad(bytes32 marketId) external view returns (uint256);
    function idleUsdc(bytes32 marketId) external view returns (uint256);
    function ammPrice8(bytes32 marketId) external view returns (uint256);
    function currentGapBps(bytes32 marketId) external view returns (int256);
    function entryGapBps(bytes32 marketId) external view returns (int256);
    function hedgedNotionalUsdc(bytes32 marketId) external view returns (uint256);
    function minDeposit(bytes32 marketId) external view returns (uint256);
    function gapCheckEnabled(bytes32 marketId) external view returns (bool);
    function pool(bytes32 marketId) external view returns (address);
    function twapWindow(bytes32 marketId) external view returns (uint32);
    function hedgedAssetsUsdc(bytes32 marketId) external view returns (uint256);
    function totalRedeemShares(bytes32 marketId) external view returns (uint256);
    function reservedClaimableUsdc(bytes32 marketId) external view returns (uint256);
    function fundingSettlePending(bytes32 marketId) external view returns (bool);
    function vaultAccruedFundingGmx(bytes32 marketId) external view returns (uint256 longAmount, uint256 shortAmount);
    function settlingRemainingShares(bytes32 marketId) external view returns (uint256);
    function settlingEpoch(bytes32 marketId) external view returns (uint256);

    // ── user views (marketId, user) ─────────────────────────────────────────────
    function sharesOf(bytes32 marketId, address user) external view returns (uint256);
    function fundingSharesOf(bytes32 marketId, address user) external view returns (uint256);
    function assetsOf(bytes32 marketId, address user) external view returns (uint256);
    function accountAssets(bytes32 marketId, address user)
        external
        view
        returns (uint256 depositedUsdc, uint256 hedgedUsdc, uint256 idleShareUsdc);
    function maxWithdrawableUsdc(bytes32 marketId, address user) external view returns (uint256);
    function redeemSharesOf(bytes32 marketId, address user) external view returns (uint256);
    function claimableUsdc(bytes32 marketId, address user) external view returns (uint256);

    // ── funding distributor views (marketId, user) ──────────────────────────────
    function claimableAll(bytes32 marketId, address user)
        external
        view
        returns (
            uint256 longConfirmed,
            uint256 longPending,
            uint256 shortConfirmed,
            uint256 shortPending,
            uint256 longAccrued,
            uint256 shortAccrued
        );
    function vaultClaimableGmx(bytes32 marketId) external view returns (uint256 longAmount, uint256 shortAmount);

    // ── 집계 스냅샷 (편의) ──────────────────────────────────────────────────────
    function vaultSummary(bytes32 marketId) external view returns (RYieldVaultSummary memory);
    function userSummary(bytes32 marketId, address user) external view returns (RYieldUserSummary memory);
    function fundingSummary(bytes32 marketId, address user) external view returns (RYieldFundingSummary memory);
}
