// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IRYieldFundingDistributor — GMX funding fee MultiRewards 배분·청구 (스왑 없음).
/// @dev Synthetix MultiRewards 패턴: 토큰별 rewardPerShareStored + rewards[token][user] 이중 mapping.
interface IRYieldFundingDistributor {
    event HarvestNotified(address indexed token, uint256 amount, uint256 rewardPerShareStored);
    event RewardsClaimed(address indexed user, uint256 longAmount, uint256 shortAmount);

    function vault() external view returns (address);
    function longToken() external view returns (address);
    function shortToken() external view returns (address);
    function gmxMarket() external view returns (address);

    /// @notice GMX 마켓 보상 토큰 개수 (long + short = 2).
    function rewardTokenCount() external view returns (uint256);

    /// @notice 보상 토큰 주소 (0=long, 1=short).
    function rewardTokenAt(uint256 index) external view returns (address);

    /// @notice 토큰별 지분 1개당 누적 보상 (1e18 스케일). MultiRewards rewardPerTokenStored.
    function rewardPerShareStored(address token) external view returns (uint256);

    /// @notice 토큰별·유저별 확정 미청구 보상. MultiRewards rewards[token][user].
    function rewards(address token, address user) external view returns (uint256);

    /// @notice 토큰별·유저별 정산 완료 지점. MultiRewards userRewardPerTokenPaid.
    function userRewardPerSharePaid(address token, address user) external view returns (uint256);

    /// @notice vault가 GMX claim 직후 호출 — 해당 토큰 rewardPerShare 갱신.
    function notifyHarvest(address token, uint256 amount) external;

    /// @notice harvest 루프용 — tokens[i]·amounts[i] 쌍별 notifyHarvest.
    function notifyHarvestBatch(address[] calldata tokens, uint256[] calldata amounts) external;

    /// @notice share 변경 전 — 토큰별 reward를 rewards[user]에 적립.
    function accrueUser(address user) external;

    /// @notice share 변경 후 — userRewardPerSharePaid 재설정.
    function setUserDebt(address user) external;

    /// @notice GMX accrued funding settle 주문 제출(1단계, GMX UI Settle과 동일). keeper 체결 후 harvestAndClaim(2단계).
    /// @return submitted 새 settle 주문을 제출했으면 true(이미 pending·skip 조건이면 false).
    function settleAccruedFee() external returns (bool submitted);

    /// @notice 통합 claim 버튼(2단계) — GMX claimable 수거(→distributor) 후 호출자 share만큼 지급.
    ///         GMX·distributor 모두 호출자 몫 0이면 revert. harvest는 best-effort. accrued는 settleAccruedFee 선행.
    function harvestAndClaim() external returns (uint256 longAmount, uint256 shortAmount);

    /// @notice distributor에 적립된(확정+미정산) 청구 가능량.
    function claimableRewards(address user) external view returns (uint256 longAmount, uint256 shortAmount);

    /// @notice GMX DataStore claimable funding × 유저 지분비 (settle 완료분, 표시용).
    function estimatedGmxFunding(address user) external view returns (uint256 longEst, uint256 shortEst);

    /// @notice GMX Reader accrued(미 settle) funding × 유저 지분비 (표시용).
    function estimatedAccruedGmxFunding(address user) external view returns (uint256 longEst, uint256 shortEst);

    /// @notice UI 대시보드용 통합 조회: 확정·claimable·accrued를 토큰별로 반환.
    /// @return longConfirmed distributor 내 확정 long
    /// @return longPending GMX claimable 예상 long(지분비)
    /// @return shortConfirmed distributor 내 확정 short
    /// @return shortPending GMX claimable 예상 short(지분비)
    /// @return longAccrued GMX accrued(미 settle) 예상 long(지분비)
    /// @return shortAccrued GMX accrued(미 settle) 예상 short(지분비)
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
        );

    /// @notice 볼트 전체가 GMX에 미수령한 총 펀딩비(글로벌 클레임 버튼 프리뷰용).
    function vaultClaimableGmx() external view returns (uint256 longAmount, uint256 shortAmount);
}
