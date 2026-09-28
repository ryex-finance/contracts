// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title GmxConstants — GMX v2 order types and tuning knobs shared by PositionVault.
library GmxConstants {
    uint8 internal constant ORDER_MARKET_INCREASE = 2;
    uint8 internal constant ORDER_LIMIT_INCREASE = 3;
    uint8 internal constant ORDER_MARKET_DECREASE = 4;
    uint8 internal constant ORDER_LIMIT_DECREASE = 5;
    uint8 internal constant ORDER_STOP_LOSS = 6;
    /// @dev GMX UI "Settle" accrued funding — MarketDecrease(size=0, collateral=1 wei) 포지션 터치.
    uint8 internal constant KIND_SETTLE_FUNDING = 8;

    uint256 internal constant LIMIT_SLIPPAGE_BPS = 100; // 1%
    uint256 internal constant CALLBACK_GAS_LIMIT = 500_000;
    /// @dev GMX Keys.sol과 동일하게 keccak256(abi.encode(string))로 해시해야 함.
    ///      keccak256(bytes(string))(구버전)는 다른 값이 나와 DataStore 조회가 항상 빈 결과를 반환했음
    ///      (2026-09-02 확인 — isOrderPending()이 실주문 존재에도 상시 false).
    bytes32 internal constant ACCOUNT_ORDER_LIST = keccak256(abi.encode("ACCOUNT_ORDER_LIST"));
}
