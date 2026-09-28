// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title ILpZap — VaultFactory → LpZap borrow-fee 통보 인터페이스.
/// @dev VaultFactory.notifyBorrowFeeEarned가 USDC를 LpZap으로 전송한 직후 이 함수를 호출해
///      accRewardPerLiquidity 누적을 즉시(스테이킹된 LP가 있으면) 반영시킨다. 라운드 없음 — 도착 즉시 반영.
interface ILpZap {
    function notifyReward(bytes32 marketId, uint256 amount) external;
}
