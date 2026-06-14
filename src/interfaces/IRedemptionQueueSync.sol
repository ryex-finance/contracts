// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @notice 오라클 가격 갱신 시 RLT 큐 자동 동기화 콜백 (MockPriceOracle → VaultFactory).
interface IRedemptionQueueSync {
  function syncRedemptionQueueForOracle(address oracle) external;
}
