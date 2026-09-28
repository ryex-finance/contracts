// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IGmxDataStore} from "./interfaces/IGmxDataStore.sol";
import {IRYieldFundingDistributor} from "./interfaces/IRYieldFundingDistributor.sol";
import {IRYieldVaultShares} from "./interfaces/IRYieldVaultShares.sol";
import {GmxFundingUtils} from "./libraries/GmxFundingUtils.sol";

/// @title RYieldFundingDistributor — GMX funding fee MultiRewards 배분 (Synthetix StakingRewards per-token).
/// @notice 보상 토큰이 long·short 2개이므로 rewardPerShareStored·rewards를 토큰 주소 키 mapping으로 독립 운영.
///         harvest 시 토큰별로 rewardPerShare += amount/totalShares. claim 시 두 토큰 동시 전송(스왑 없음).
contract RYieldFundingDistributor is IRYieldFundingDistributor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant PRECISION = 1e18;

    address public immutable vault;
    address public immutable gmxMarket;
    address public immutable longToken;
    address public immutable shortToken;
    IGmxDataStore internal immutable dataStore;

    /// @dev GMX 마켓 보상 토큰 목록 (long, short). notifyHarvest·claim 루프 대상.
    address[2] internal _rewardTokens;

    /// @inheritdoc IRYieldFundingDistributor
    /// @dev 토큰별 "지분 1개당 누적 보상" (1e18 스케일). MultiRewards rewardPerTokenStored.
    mapping(address => uint256) public rewardPerShareStored;

    /// @inheritdoc IRYieldFundingDistributor
    /// @dev 토큰별·유저별 확정(미청구) 보상 잔액. MultiRewards rewards[token][user].
    mapping(address => mapping(address => uint256)) public rewards;

    /// @inheritdoc IRYieldFundingDistributor
    /// @dev 토큰별·유저별 정산 완료 지점(rewardDebt). MultiRewards userRewardPerTokenPaid.
    mapping(address => mapping(address => uint256)) public userRewardPerSharePaid;

    error NotVault();
    error BadToken();
    error ZeroVault();
    error LengthMismatch();
    error NoSharesToAllocate();
    error NothingToClaim(); // GMX·distributor 모두 청구자 몫 0

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address vault_, address gmxMarket_, address dataStore_, address longToken_, address shortToken_) {
        if (vault_ == address(0) || gmxMarket_ == address(0) || dataStore_ == address(0)) revert ZeroVault();
        if (longToken_ == address(0) || shortToken_ == address(0)) revert BadToken();
        vault = vault_;
        gmxMarket = gmxMarket_;
        dataStore = IGmxDataStore(dataStore_);
        longToken = longToken_;
        shortToken = shortToken_;
        _rewardTokens[0] = longToken_;
        _rewardTokens[1] = shortToken_;
    }

    /// @inheritdoc IRYieldFundingDistributor
    function rewardTokenCount() external pure returns (uint256) {
        return 2;
    }

    /// @inheritdoc IRYieldFundingDistributor
    function rewardTokenAt(uint256 index) external view returns (address) {
        if (index >= 2) revert BadToken();
        return _rewardTokens[index];
    }

    /// @inheritdoc IRYieldFundingDistributor
    function notifyHarvest(address token, uint256 amount) external onlyVault {
        _notifyHarvest(token, amount);
    }

    /// @inheritdoc IRYieldFundingDistributor
    function notifyHarvestBatch(address[] calldata tokens, uint256[] calldata amounts) external onlyVault {
        if (tokens.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < tokens.length; ++i) {
            _notifyHarvest(tokens[i], amounts[i]);
        }
    }

    /// @inheritdoc IRYieldFundingDistributor
    function accrueUser(address user) external onlyVault {
        _accrue(user);
    }

    /// @inheritdoc IRYieldFundingDistributor
    function setUserDebt(address user) external onlyVault {
        _setDebt(user);
    }

    /// @inheritdoc IRYieldFundingDistributor
    /// @notice 1단계 — GMX accrued funding settle(MarketDecrease touch). 전역(볼트 포지션) 1회, keeper 비동기 체결.
    function settleAccruedFee() external returns (bool submitted) {
        return IRYieldVaultShares(vault).requestAccruedFundingSettle();
    }

    /// @inheritdoc IRYieldFundingDistributor
    /// @notice 2단계 — claimable만: GMX claimFundingFees 수거(→distributor) 후 호출자 share만큼 지급.
    /// @dev accrued 수령은 settleAccruedFee → (keeper 체결) → harvestAndClaim 순서. harvest는 best-effort.
    function harvestAndClaim() external nonReentrant returns (uint256 longAmount, uint256 shortAmount) {
        try IRYieldVaultShares(vault).harvestFunding() {} catch {}
        (longAmount, shortAmount) = _claim(msg.sender);
        if (longAmount == 0 && shortAmount == 0) revert NothingToClaim();
    }

    function _claim(address user) internal returns (uint256 longAmount, uint256 shortAmount) {
        _accrue(user);
        longAmount = _claimToken(user, longToken);
        shortAmount = _claimToken(user, shortToken);
        emit RewardsClaimed(user, longAmount, shortAmount);
    }

    /// @inheritdoc IRYieldFundingDistributor
    function claimableRewards(address user) external view returns (uint256 longAmount, uint256 shortAmount) {
        (longAmount, shortAmount) = _pending(user);
    }

    /// @inheritdoc IRYieldFundingDistributor
    function estimatedGmxFunding(address user) external view returns (uint256 longEst, uint256 shortEst) {
        uint256 sh = IRYieldVaultShares(vault).fundingSharesOf(user);
        uint256 ts = IRYieldVaultShares(vault).totalShares();
        if (sh == 0 || ts == 0) return (0, 0);
        (uint256 vaultLong, uint256 vaultShort) = _vaultClaimableGmx();
        longEst = (vaultLong * sh) / ts;
        shortEst = (vaultShort * sh) / ts;
    }

    /// @inheritdoc IRYieldFundingDistributor
    function estimatedAccruedGmxFunding(address user) external view returns (uint256 longEst, uint256 shortEst) {
        uint256 sh = IRYieldVaultShares(vault).fundingSharesOf(user);
        uint256 ts = IRYieldVaultShares(vault).totalShares();
        if (sh == 0 || ts == 0) return (0, 0);
        (uint256 vaultLong, uint256 vaultShort) = _vaultAccruedGmx();
        longEst = (vaultLong * sh) / ts;
        shortEst = (vaultShort * sh) / ts;
    }

    /// @inheritdoc IRYieldFundingDistributor
    function claimableAll(address user)
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
        (longConfirmed, shortConfirmed) = _pending(user);
        uint256 sh = IRYieldVaultShares(vault).fundingSharesOf(user);
        uint256 ts = IRYieldVaultShares(vault).totalShares();
        if (sh == 0 || ts == 0) return (longConfirmed, 0, shortConfirmed, 0, 0, 0);
        (uint256 vaultLong, uint256 vaultShort) = _vaultClaimableGmx();
        longPending = (vaultLong * sh) / ts;
        shortPending = (vaultShort * sh) / ts;
        (uint256 accLong, uint256 accShort) = _vaultAccruedGmx();
        longAccrued = (accLong * sh) / ts;
        shortAccrued = (accShort * sh) / ts;
    }

    /// @inheritdoc IRYieldFundingDistributor
    function vaultClaimableGmx() external view returns (uint256 longAmount, uint256 shortAmount) {
        (longAmount, shortAmount) = _vaultClaimableGmx();
    }

    function _vaultClaimableGmx() internal view returns (uint256 longAmount, uint256 shortAmount) {
        longAmount = GmxFundingUtils.claimableFunding(dataStore, gmxMarket, longToken, vault);
        shortAmount = GmxFundingUtils.claimableFunding(dataStore, gmxMarket, shortToken, vault);
    }

    function _vaultAccruedGmx() internal view returns (uint256 longAmount, uint256 shortAmount) {
        return IRYieldVaultShares(vault).vaultAccruedFundingGmx();
    }

    function _isRewardToken(address token) internal view returns (bool) {
        return token == longToken || token == shortToken;
    }

    function _notifyHarvest(address token, uint256 amount) internal {
        if (!_isRewardToken(token)) revert BadToken();
        if (amount == 0) return;
        uint256 ts = IRYieldVaultShares(vault).totalShares();
        if (ts == 0) revert NoSharesToAllocate(); // GMX claim과 동 tx — 미배분 토큰 고립 방지
        rewardPerShareStored[token] += (amount * PRECISION) / ts;
        emit HarvestNotified(token, amount, rewardPerShareStored[token]);
    }

    function _shares(address user) internal view returns (uint256) {
        return IRYieldVaultShares(vault).fundingSharesOf(user);
    }

    function _accrueToken(address user, address token) internal {
        uint256 sh = _shares(user);
        uint256 earned = (sh * rewardPerShareStored[token]) / PRECISION;
        uint256 paid = userRewardPerSharePaid[token][user];
        if (earned > paid) rewards[token][user] += earned - paid;
        userRewardPerSharePaid[token][user] = earned;
    }

    function _accrue(address user) internal {
        _accrueToken(user, longToken);
        _accrueToken(user, shortToken);
    }

    function _setDebtToken(address user, address token) internal {
        uint256 sh = _shares(user);
        userRewardPerSharePaid[token][user] = (sh * rewardPerShareStored[token]) / PRECISION;
    }

    function _setDebt(address user) internal {
        _setDebtToken(user, longToken);
        _setDebtToken(user, shortToken);
    }

    function _claimToken(address user, address token) internal returns (uint256 amount) {
        amount = rewards[token][user];
        if (amount == 0) return 0;
        rewards[token][user] = 0;
        IERC20(token).safeTransfer(user, amount);
    }

    function _pendingToken(address user, address token) internal view returns (uint256 amount) {
        uint256 sh = _shares(user);
        uint256 earned = (sh * rewardPerShareStored[token]) / PRECISION;
        amount = rewards[token][user];
        uint256 paid = userRewardPerSharePaid[token][user];
        if (earned > paid) amount += earned - paid;
    }

    function _pending(address user) internal view returns (uint256 longAmount, uint256 shortAmount) {
        longAmount = _pendingToken(user, longToken);
        shortAmount = _pendingToken(user, shortToken);
    }
}
