// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IRYieldVaultSource} from "../interfaces/IRYieldVaultSource.sol";
import {IRYieldVaultMeta} from "../interfaces/IRYieldVaultMeta.sol";
import {IRYieldVaultShares} from "../interfaces/IRYieldVaultShares.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {AmmTwap} from "./AmmTwap.sol";
import {Units} from "./Units.sol";
import {RYieldLensPack} from "../types/Types.sol";

/// @title RYieldViews — rYield vault UI 조회 로직 (RYieldRegistry 전용 external 라이브러리).
library RYieldViews {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    function execFee(address vault) external view returns (uint256) {
        return IVaultFactory(IRYieldVaultMeta(vault).factory()).gmxInfra().execFee;
    }

    function execFeeBalance(address vault) external view returns (uint256) {
        return vault.balance;
    }

    function totalShares(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).ryieldPack().totalShares;
    }

    function sharesOf(address vault, address user) external view returns (uint256) {
        return IRYieldVaultSource(vault).sharesOf(user);
    }

    function fundingSharesOf(address vault, address user) external view returns (uint256) {
        return IRYieldVaultShares(vault).fundingSharesOf(user);
    }

    function ryieldState(address vault) external view returns (uint8) {
        return uint8(IRYieldVaultSource(vault).ryieldPack().state);
    }

    function pendingOrderKey(address vault) external view returns (bytes32) {
        return IRYieldVaultSource(vault).ryieldPack().pendingOrderKey;
    }

    function pendingCreatedAt(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).ryieldPack().pendingCreatedAt;
    }

    function depositCap(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).ryieldPack().depositCap;
    }

    function perfFeeBps(address vault) external view returns (uint16) {
        return IRYieldVaultSource(vault).ryieldPack().perfFeeBps;
    }

    function maxPriceImpactBps(address vault) external view returns (uint16) {
        return IRYieldVaultSource(vault).ryieldPack().maxPriceImpactBps;
    }

    function maxExitDiscountBps(address vault) external view returns (uint16) {
        return IRYieldVaultSource(vault).ryieldPack().maxExitDiscountBps;
    }

    function maxEntryPremiumBps(address vault) external view returns (uint16) {
        return IRYieldVaultSource(vault).ryieldPack().maxEntryPremiumBps;
    }

    function targetLeverage(address vault) external view returns (uint8) {
        return IRYieldVaultSource(vault).ryieldPack().targetLeverage;
    }

    function hwmAssetsPerShareWad(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).ryieldPack().hwmAssetsPerShareWad;
    }

    function longRTokenBalance(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).rTokenBalance();
    }

    function longValueUsdc(address vault) external view returns (uint256) {
        return _longValueUsdc(vault);
    }

    function _longValueUsdc(address vault) internal view returns (uint256) {
        IRYieldVaultSource src = IRYieldVaultSource(vault);
        uint256 bal = src.rTokenBalance();
        return bal == 0 ? 0 : Units.rTokenToUsdc(bal, IRYieldVaultMeta(vault).oracle().getPrice());
    }

    function shortEquityUsdc(address vault) external view returns (uint256) {
        return _shortEquityUsdc(vault);
    }

    function _shortEquityUsdc(address vault) internal view returns (uint256) {
        return Units.wadToUsdc(IRYieldVaultSource(vault).lensGmxEquityUsdWad());
    }

    function idleUsdc(address vault) external view returns (uint256) {
        return _idleUsdc(vault);
    }

    function _idleUsdc(address vault) internal view returns (uint256) {
        IRYieldVaultSource src = IRYieldVaultSource(vault);
        uint256 bal = src.usdcBalance();
        uint256 reserved = src.ryieldPack().reservedClaimableUsdc;
        return bal > reserved ? bal - reserved : 0;
    }

    function totalAssetsUsdc(address vault) external view returns (uint256) {
        return _totalAssetsUsdc(vault);
    }

    function _totalAssetsUsdc(address vault) internal view returns (uint256) {
        return _idleUsdc(vault) + _longValueUsdc(vault) + _shortEquityUsdc(vault);
    }

    function pricePerShareWad(address vault) external view returns (uint256) {
        uint256 ts = IRYieldVaultSource(vault).ryieldPack().totalShares;
        if (ts == 0) return WAD;
        return (_totalAssetsUsdc(vault) * WAD) / ts;
    }

    function assetsOf(address vault, address user) external view returns (uint256) {
        IRYieldVaultSource src = IRYieldVaultSource(vault);
        uint256 ts = src.ryieldPack().totalShares;
        if (ts == 0) return 0;
        return (src.sharesOf(user) * _totalAssetsUsdc(vault)) / ts;
    }

    function ammPrice8(address vault) external view returns (uint256) {
        return _ammPrice8(vault);
    }

    function _ammPrice8(address vault) internal view returns (uint256) {
        IRYieldVaultSource src = IRYieldVaultSource(vault);
        RYieldLensPack memory p = src.ryieldPack();
        if (p.pool == address(0)) return 0;
        return AmmTwap.rTokenPrice8(p.pool, src.rToken(), IVaultFactory(IRYieldVaultMeta(vault).factory()).usdc(), p.twapWindow);
    }

    function currentGapBps(address vault) external view returns (int256) {
        return _gapBps(IRYieldVaultMeta(vault).oracle().getPrice(), _ammPrice8(vault));
    }

    function entryGapBps(address vault) external view returns (int256) {
        return IRYieldVaultSource(vault).ryieldPack().entryGapBps;
    }

    function hedgedNotionalUsdc(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).ryieldPack().hedgedNotionalUsdc;
    }

    function minDeposit(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).ryieldPack().minDeposit;
    }

    function gapCheckEnabled(address vault) external view returns (bool) {
        return IRYieldVaultSource(vault).ryieldPack().gapCheckEnabled;
    }

    function pool(address vault) external view returns (address) {
        return IRYieldVaultSource(vault).ryieldPack().pool;
    }

    function twapWindow(address vault) external view returns (uint32) {
        return IRYieldVaultSource(vault).ryieldPack().twapWindow;
    }

    function hedgedAssetsUsdc(address vault) external view returns (uint256) {
        return _hedgedAssetsUsdc(vault);
    }

    function _hedgedAssetsUsdc(address vault) internal view returns (uint256) {
        return _longValueUsdc(vault) + _shortEquityUsdc(vault);
    }

    function accountAssets(address vault, address user)
        external
        view
        returns (uint256 depositedUsdc, uint256 hedgedUsdc, uint256 idleShareUsdc)
    {
        IRYieldVaultSource src = IRYieldVaultSource(vault);
        uint256 ts = src.ryieldPack().totalShares;
        uint256 sh = src.sharesOf(user);
        if (ts == 0 || sh == 0) return (0, 0, 0);
        depositedUsdc = (sh * _totalAssetsUsdc(vault)) / ts;
        hedgedUsdc = (sh * _hedgedAssetsUsdc(vault)) / ts;
        idleShareUsdc = (sh * _idleUsdc(vault)) / ts;
    }

    function maxWithdrawableUsdc(address vault, address user) external view returns (uint256) {
        IRYieldVaultSource src = IRYieldVaultSource(vault);
        uint256 ts = src.ryieldPack().totalShares;
        uint256 sh = src.sharesOf(user);
        if (ts == 0 || sh == 0) return 0;
        return (sh * _idleUsdc(vault)) / ts;
    }

    function redeemSharesOf(address vault, address user) external view returns (uint256) {
        return IRYieldVaultSource(vault).redeemSharesOf(user);
    }

    function claimableUsdc(address vault, address user) external view returns (uint256) {
        IRYieldVaultSource src = IRYieldVaultSource(vault);
        RYieldLensPack memory p = src.ryieldPack();
        uint256 sh = src.redeemSharesOf(user);
        if (sh == 0) return 0;
        uint256 epoch = src.redeemReqEpoch(user);
        if (epoch >= p.currentRedeemEpoch) return 0;
        if (epoch == p.settlingEpoch && p.settlingRemainingShares > 0) return 0;
        uint256 es = src.epochRedeemShares(epoch);
        if (es == 0) return 0;
        return (sh * src.epochPayoutUsdc(epoch)) / es;
    }

    function totalRedeemShares(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).ryieldPack().totalRedeemShares;
    }

    function reservedClaimableUsdc(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).ryieldPack().reservedClaimableUsdc;
    }

    function fundingSettlePending(address vault) external view returns (bool) {
        return IRYieldVaultShares(vault).fundingSettlePending();
    }

    function vaultAccruedFundingGmx(address vault) external view returns (uint256 longAmount, uint256 shortAmount) {
        return IRYieldVaultShares(vault).vaultAccruedFundingGmx();
    }

    function settlingRemainingShares(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).ryieldPack().settlingRemainingShares;
    }

    function settlingEpoch(address vault) external view returns (uint256) {
        return IRYieldVaultSource(vault).ryieldPack().settlingEpoch;
    }

    function _gapBps(uint256 gmxPrice8, uint256 ammP8) internal pure returns (int256) {
        if (gmxPrice8 == 0) return 0;
        return ((int256(gmxPrice8) - int256(ammP8)) * int256(BPS)) / int256(gmxPrice8);
    }
}
