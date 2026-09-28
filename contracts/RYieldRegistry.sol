// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IRYieldRegistry} from "./interfaces/IRYieldRegistry.sol";
import {IRYieldVaultSource} from "./interfaces/IRYieldVaultSource.sol";
import {IRYieldVaultMeta} from "./interfaces/IRYieldVaultMeta.sol";
import {IRYieldFundingDistributor} from "./interfaces/IRYieldFundingDistributor.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {RYieldViews} from "./libraries/RYieldViews.sol";
import {RYieldState, RYieldVaultSummary, RYieldUserSummary, RYieldFundingSummary} from "./types/Types.sol";

/// @title RYieldRegistry — rYield 마켓 레지스트리 + vault view 1:1 조회(marketId 진입).
/// @notice UI·인덱서는 vault 주소 대신 marketId로 RYieldVault에 있던 view와 동일하게 조회한다.
contract RYieldRegistry is IRYieldRegistry, Ownable {
    IVaultFactory internal immutable _factory;

    mapping(bytes32 => address) public vaultOf;
    mapping(address => address) public vaultByRToken;
    mapping(address => bytes32) public marketIdOfVault;
    mapping(address => bool) public isRYieldVault;
    address[] internal _vaultList;

    error ZeroAddress();
    error VaultExists();
    error NotRegistered();
    error MarketMismatch();
    error DistributorMismatch();
    error NoMarket();
    error VaultUnchanged();

    constructor(IVaultFactory factory_, address admin_) Ownable(admin_) {
        if (address(factory_) == address(0) || admin_ == address(0)) revert ZeroAddress();
        _factory = factory_;
    }

    /// @inheritdoc IRYieldRegistry
    function factory() external view returns (IVaultFactory) {
        return _factory;
    }

    /// @inheritdoc IRYieldRegistry
    function register(bytes32 marketId, address vault, address distributor) external onlyOwner {
        if (vaultOf[marketId] != address(0)) revert VaultExists();
        address rt = _validateVault(marketId, vault, distributor);
        if (vaultByRToken[rt] != address(0)) revert VaultExists();
        _linkVault(marketId, vault, rt);
        emit RYieldVaultRegistered(marketId, vault, distributor, rt);
    }

    /// @inheritdoc IRYieldRegistry
    /// @notice 마켓 레지스트리 해제. 온체인 vault/distributor 자산·유저는 그대로 — UI discovery만 제거.
    function unregister(bytes32 marketId) external onlyOwner {
        (address vault, address rt) = _unlinkVault(marketId);
        emit RYieldVaultUnregistered(marketId, vault, rt);
    }

    /// @inheritdoc IRYieldRegistry
    /// @notice 동일 marketId에 새 vault(+distributor)로 교체. 기존 vault는 레지스트리에서 해제된다.
    function replaceVault(bytes32 marketId, address vault, address distributor) external onlyOwner {
        address oldVault = vaultOf[marketId];
        if (oldVault == address(0)) revert NotRegistered();
        if (oldVault == vault) revert VaultUnchanged();
        address rt = _validateVault(marketId, vault, distributor);
        _unlinkVault(marketId);
        if (vaultByRToken[rt] != address(0)) revert VaultExists();
        _linkVault(marketId, vault, rt);
        emit RYieldVaultReplaced(marketId, oldVault, vault, distributor, rt);
    }

    /// @inheritdoc IRYieldRegistry
    function totalVaults() external view returns (uint256) {
        return _vaultList.length;
    }

    /// @inheritdoc IRYieldRegistry
    function vaultAt(uint256 index) external view returns (address) {
        return _vaultList[index];
    }

    /// @inheritdoc IRYieldRegistry
    /// @dev vault.fundingDistributor() 단일 진실 — owner가 setFundingDistributor로 교체해도 즉시 반영.
    function distributorOf(bytes32 marketId) public view returns (address) {
        address v = vaultOf[marketId];
        if (v == address(0)) return address(0);
        return IRYieldVaultMeta(v).fundingDistributor();
    }

    // ── identity ────────────────────────────────────────────────────────────────

    function assetName(bytes32 marketId) external view returns (string memory) {
        return IRYieldVaultMeta(_vault(marketId)).assetName();
    }

    function rToken(bytes32 marketId) external view returns (address) {
        return IRYieldVaultSource(_vault(marketId)).rToken();
    }

    function oracle(bytes32 marketId) external view returns (IPriceOracle) {
        return IRYieldVaultMeta(_vault(marketId)).oracle();
    }

    function owner(bytes32 marketId) external view returns (address) {
        return IRYieldVaultMeta(_vault(marketId)).owner();
    }

    function treasury(bytes32 marketId) external view returns (address) {
        return IRYieldVaultMeta(_vault(marketId)).treasury();
    }

    // ── vault views (marketId) ──────────────────────────────────────────────────

    function execFee(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.execFee(_vault(marketId));
    }

    function execFeeBalance(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.execFeeBalance(_vault(marketId));
    }

    function totalShares(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.totalShares(_vault(marketId));
    }

    function ryieldState(bytes32 marketId) external view returns (RYieldState) {
        return RYieldState(RYieldViews.ryieldState(_vault(marketId)));
    }

    function pendingOrderKey(bytes32 marketId) external view returns (bytes32) {
        return RYieldViews.pendingOrderKey(_vault(marketId));
    }

    function pendingCreatedAt(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.pendingCreatedAt(_vault(marketId));
    }

    function depositCap(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.depositCap(_vault(marketId));
    }

    function perfFeeBps(bytes32 marketId) external view returns (uint16) {
        return RYieldViews.perfFeeBps(_vault(marketId));
    }

    function maxPriceImpactBps(bytes32 marketId) external view returns (uint16) {
        return RYieldViews.maxPriceImpactBps(_vault(marketId));
    }

    function maxExitDiscountBps(bytes32 marketId) external view returns (uint16) {
        return RYieldViews.maxExitDiscountBps(_vault(marketId));
    }

    function targetLeverage(bytes32 marketId) external view returns (uint8) {
        return RYieldViews.targetLeverage(_vault(marketId));
    }

    function hwmAssetsPerShareWad(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.hwmAssetsPerShareWad(_vault(marketId));
    }

    function longRTokenBalance(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.longRTokenBalance(_vault(marketId));
    }

    function longValueUsdc(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.longValueUsdc(_vault(marketId));
    }

    function shortEquityUsdc(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.shortEquityUsdc(_vault(marketId));
    }

    function totalAssetsUsdc(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.totalAssetsUsdc(_vault(marketId));
    }

    function pricePerShareWad(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.pricePerShareWad(_vault(marketId));
    }

    function idleUsdc(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.idleUsdc(_vault(marketId));
    }

    function ammPrice8(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.ammPrice8(_vault(marketId));
    }

    function currentGapBps(bytes32 marketId) external view returns (int256) {
        return RYieldViews.currentGapBps(_vault(marketId));
    }

    function entryGapBps(bytes32 marketId) external view returns (int256) {
        return RYieldViews.entryGapBps(_vault(marketId));
    }

    function hedgedNotionalUsdc(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.hedgedNotionalUsdc(_vault(marketId));
    }

    function minDeposit(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.minDeposit(_vault(marketId));
    }

    function gapCheckEnabled(bytes32 marketId) external view returns (bool) {
        return RYieldViews.gapCheckEnabled(_vault(marketId));
    }

    function pool(bytes32 marketId) external view returns (address) {
        return RYieldViews.pool(_vault(marketId));
    }

    function twapWindow(bytes32 marketId) external view returns (uint32) {
        return RYieldViews.twapWindow(_vault(marketId));
    }

    function hedgedAssetsUsdc(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.hedgedAssetsUsdc(_vault(marketId));
    }

    function totalRedeemShares(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.totalRedeemShares(_vault(marketId));
    }

    function reservedClaimableUsdc(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.reservedClaimableUsdc(_vault(marketId));
    }

    function fundingSettlePending(bytes32 marketId) external view returns (bool) {
        return RYieldViews.fundingSettlePending(_vault(marketId));
    }

    function vaultAccruedFundingGmx(bytes32 marketId) external view returns (uint256 longAmount, uint256 shortAmount) {
        return RYieldViews.vaultAccruedFundingGmx(_vault(marketId));
    }

    function settlingRemainingShares(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.settlingRemainingShares(_vault(marketId));
    }

    function settlingEpoch(bytes32 marketId) external view returns (uint256) {
        return RYieldViews.settlingEpoch(_vault(marketId));
    }

    // ── user views ──────────────────────────────────────────────────────────────

    function sharesOf(bytes32 marketId, address user) external view returns (uint256) {
        return RYieldViews.sharesOf(_vault(marketId), user);
    }

    function fundingSharesOf(bytes32 marketId, address user) external view returns (uint256) {
        return RYieldViews.fundingSharesOf(_vault(marketId), user);
    }

    function assetsOf(bytes32 marketId, address user) external view returns (uint256) {
        return RYieldViews.assetsOf(_vault(marketId), user);
    }

    function accountAssets(bytes32 marketId, address user)
        external
        view
        returns (uint256 depositedUsdc, uint256 hedgedUsdc, uint256 idleShareUsdc)
    {
        return RYieldViews.accountAssets(_vault(marketId), user);
    }

    function maxWithdrawableUsdc(bytes32 marketId, address user) external view returns (uint256) {
        return RYieldViews.maxWithdrawableUsdc(_vault(marketId), user);
    }

    function redeemSharesOf(bytes32 marketId, address user) external view returns (uint256) {
        return RYieldViews.redeemSharesOf(_vault(marketId), user);
    }

    function claimableUsdc(bytes32 marketId, address user) external view returns (uint256) {
        return RYieldViews.claimableUsdc(_vault(marketId), user);
    }

    // ── funding distributor views ───────────────────────────────────────────────

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
        )
    {
        address dist = _distributor(marketId);
        return IRYieldFundingDistributor(dist).claimableAll(user);
    }

    function vaultClaimableGmx(bytes32 marketId) external view returns (uint256 longAmount, uint256 shortAmount) {
        address dist = _distributor(marketId);
        return IRYieldFundingDistributor(dist).vaultClaimableGmx();
    }

    // ── 집계 스냅샷 ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRYieldRegistry
    function vaultSummary(bytes32 marketId) external view returns (RYieldVaultSummary memory s) {
        address vault = _vault(marketId);
        IRYieldVaultSource src = IRYieldVaultSource(vault);
        IRYieldVaultMeta meta = IRYieldVaultMeta(vault);
        s.marketId = marketId;
        s.vault = vault;
        s.distributor = meta.fundingDistributor();
        s.rToken = src.rToken();
        s.oracle = address(meta.oracle());
        s.assetName = meta.assetName();
        s.state = RYieldState(RYieldViews.ryieldState(vault));
        s.totalShares = RYieldViews.totalShares(vault);
        s.totalAssetsUsdc = RYieldViews.totalAssetsUsdc(vault);
        s.pricePerShareWad = RYieldViews.pricePerShareWad(vault);
        s.idleUsdc = RYieldViews.idleUsdc(vault);
        s.hedgedAssetsUsdc = RYieldViews.hedgedAssetsUsdc(vault);
        s.longValueUsdc = RYieldViews.longValueUsdc(vault);
        s.shortEquityUsdc = RYieldViews.shortEquityUsdc(vault);
        s.currentGapBps = RYieldViews.currentGapBps(vault);
        s.entryGapBps = RYieldViews.entryGapBps(vault);
        s.hedgedNotionalUsdc = RYieldViews.hedgedNotionalUsdc(vault);
        s.depositCap = RYieldViews.depositCap(vault);
        s.minDeposit = RYieldViews.minDeposit(vault);
        s.perfFeeBps = RYieldViews.perfFeeBps(vault);
        s.targetLeverage = RYieldViews.targetLeverage(vault);
        s.hwmAssetsPerShareWad = RYieldViews.hwmAssetsPerShareWad(vault);
        s.execFee = RYieldViews.execFee(vault);
        s.execFeeBalance = RYieldViews.execFeeBalance(vault);
        s.pendingOrderKey = RYieldViews.pendingOrderKey(vault);
        s.pendingCreatedAt = RYieldViews.pendingCreatedAt(vault);
        s.fundingSettlePending = RYieldViews.fundingSettlePending(vault);
        s.oraclePrice8 = meta.oracle().getPrice();
        s.ammPrice8 = RYieldViews.ammPrice8(vault);
        s.pool = RYieldViews.pool(vault);
        s.reservedClaimableUsdc = RYieldViews.reservedClaimableUsdc(vault);
        s.totalRedeemShares = RYieldViews.totalRedeemShares(vault);
        s.settlingEpoch = RYieldViews.settlingEpoch(vault);
        s.settlingRemainingShares = RYieldViews.settlingRemainingShares(vault);
        s.gapCheckEnabled = RYieldViews.gapCheckEnabled(vault);
        s.maxPriceImpactBps = RYieldViews.maxPriceImpactBps(vault);
        s.maxEntryPremiumBps = RYieldViews.maxEntryPremiumBps(vault);
        s.maxExitDiscountBps = RYieldViews.maxExitDiscountBps(vault);
    }

    /// @inheritdoc IRYieldRegistry
    function userSummary(bytes32 marketId, address user) external view returns (RYieldUserSummary memory s) {
        address vault = _vault(marketId);
        s.shares = RYieldViews.sharesOf(vault, user);
        s.fundingShares = RYieldViews.fundingSharesOf(vault, user);
        (s.assetsUsdc, s.hedgedUsdc, s.idleShareUsdc) = RYieldViews.accountAssets(vault, user);
        s.maxWithdrawableUsdc = RYieldViews.maxWithdrawableUsdc(vault, user);
        s.redeemShares = RYieldViews.redeemSharesOf(vault, user);
        s.claimableUsdc = RYieldViews.claimableUsdc(vault, user);
    }

    /// @inheritdoc IRYieldRegistry
    function fundingSummary(bytes32 marketId, address user) external view returns (RYieldFundingSummary memory s) {
        address vault = _vault(marketId);
        address dist = distributorOf(marketId);
        if (dist != address(0)) {
            (
                s.longConfirmed,
                s.longPending,
                s.shortConfirmed,
                s.shortPending,
                s.longAccrued,
                s.shortAccrued
            ) = IRYieldFundingDistributor(dist).claimableAll(user);
            (s.vaultClaimableLong, s.vaultClaimableShort) = IRYieldFundingDistributor(dist).vaultClaimableGmx();
        }
        s.settlePending = RYieldViews.fundingSettlePending(vault);
        (s.vaultAccruedLong, s.vaultAccruedShort) = RYieldViews.vaultAccruedFundingGmx(vault);
    }

    function _validateVault(bytes32 marketId, address vault, address distributor)
        internal
        view
        returns (address rt)
    {
        if (vault == address(0) || distributor == address(0)) revert ZeroAddress();
        IRYieldVaultSource src = IRYieldVaultSource(vault);
        IRYieldVaultMeta meta = IRYieldVaultMeta(vault);
        if (meta.factory() != address(_factory)) revert MarketMismatch();
        if (src.marketId() != marketId) revert MarketMismatch();
        if (meta.fundingDistributor() != distributor) revert DistributorMismatch();
        if (IRYieldFundingDistributor(distributor).vault() != vault) revert DistributorMismatch();

        bool active;
        (active,, rt,,,,,,,,) = _factory.markets(marketId);
        if (!active || rt == address(0)) revert NoMarket();
        if (src.rToken() != rt) revert MarketMismatch();
    }

    function _linkVault(bytes32 marketId, address vault, address rt) internal {
        if (marketIdOfVault[vault] != bytes32(0)) revert VaultExists();
        vaultOf[marketId] = vault;
        vaultByRToken[rt] = vault;
        marketIdOfVault[vault] = marketId;
        isRYieldVault[vault] = true;
        _vaultList.push(vault);
    }

    function _unlinkVault(bytes32 marketId) internal returns (address vault, address rt) {
        vault = vaultOf[marketId];
        if (vault == address(0)) revert NotRegistered();
        rt = IRYieldVaultSource(vault).rToken();
        delete vaultOf[marketId];
        delete vaultByRToken[rt];
        delete marketIdOfVault[vault];
        isRYieldVault[vault] = false;
        _removeFromVaultList(vault);
    }

    function _removeFromVaultList(address vault) internal {
        uint256 len = _vaultList.length;
        for (uint256 i; i < len; ++i) {
            if (_vaultList[i] == vault) {
                _vaultList[i] = _vaultList[len - 1];
                _vaultList.pop();
                return;
            }
        }
    }

    function _vault(bytes32 marketId) internal view returns (address v) {
        v = vaultOf[marketId];
        if (v == address(0)) revert NotRegistered();
    }

    function _distributor(bytes32 marketId) internal view returns (address dist) {
        dist = distributorOf(marketId);
        if (dist == address(0)) revert NotRegistered();
    }
}
