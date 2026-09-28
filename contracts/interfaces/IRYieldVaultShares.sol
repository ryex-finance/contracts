// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IRYieldVaultShares — funding distributor가 참조하는 rYield share 회계 + 글로벌 수거 트리거.
interface IRYieldVaultShares {
    function totalShares() external view returns (uint256);
    /// @notice funding 배분 기준 지분 (sharesOf만; 상환 큐 redeemShares는 제외).
    function fundingSharesOf(address user) external view returns (uint256);
    /// @notice GMX accrued funding settle 주문 제출(MarketDecrease touch). distributor.settleAccruedFee(1단계)에서 호출.
    /// @return submitted 새 settle 주문을 제출했으면 true(이미 pending이면 false).
    function requestAccruedFundingSettle() external returns (bool submitted);
    /// @notice GMX pending 펀딩비를 distributor로 일괄 수거(무허가). harvestAndClaim에서 최신화용 호출.
    function harvestFunding() external;
    /// @notice GMX Reader 기준 vault 포지션 accrued(미 settle) 펀딩비 총량.
    function vaultAccruedFundingGmx() external view returns (uint256 longAmount, uint256 shortAmount);
    /// @notice 미체결 accrued funding settle 주문 존재 여부.
    function fundingSettlePending() external view returns (bool);
}
