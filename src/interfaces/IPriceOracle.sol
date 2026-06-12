// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IPriceOracle — BTC 가격 추상화 (docs/14)
/// @notice Vault·Risk는 절대 Chainlink를 직접 보지 않고 이 인터페이스만 의존.
///         환경별 구현 교체: MockPriceOracle ↔ ChainlinkPriceOracle (무수정).
interface IPriceOracle {
    /// @return price asset/USD, **8 decimals (Chainlink 표준)**.
    ///         예) $1,650 → 165_000_000_000. 프론트: formatUnits(price, 8).
    ///         구현은 0/stale 거부(fail-safe, docs/70 §4.1).
    function getPrice() external view returns (uint256 price);
    function decimals() external view returns (uint8);
}
