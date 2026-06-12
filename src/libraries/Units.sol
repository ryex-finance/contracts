// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title Units — 단위·정밀도 단일화 (docs/60 OQ-3)
/// @notice 모든 토큰/가격 자릿수 변환을 한곳에 모은다. 어떤 컨트랙트도 raw 나눗셈을 직접 하지 않는다.
///         USD 내부 표현은 WAD(1e18)로 통일한다.
///         decimals: USDC=6, rBTC=18, Chainlink price=8, GMX price=30, USD(internal)=18(WAD).
library Units {
    uint256 internal constant USDC_DEC = 6;
    uint256 internal constant RBTC_DEC = 18;
    uint256 internal constant PRICE_DEC = 8; // Chainlink BTC/USD
    uint256 internal constant WAD = 18; // 내부 USD 스케일
    uint256 internal constant GMX_PRICE_DEC = 30;

    uint256 internal constant USDC_TO_WAD = 1e12; // 1e18 / 1e6
    uint256 internal constant PRICE_ONE = 1e8; // 가격 1.0 (8dec)
    uint256 internal constant GMX_TO_CL = 1e22; // 1e30 / 1e8

    /// @notice USDC(6dec) → USD WAD(1e18)
    function usdcToWad(uint256 usdc) internal pure returns (uint256) {
        return usdc * USDC_TO_WAD;
    }

    /// @notice USD WAD(1e18) → USDC(6dec) (내림)
    function wadToUsdc(uint256 wad) internal pure returns (uint256) {
        return wad / USDC_TO_WAD;
    }

    /// @notice rBTC 수량(1e18) × 가격(8dec) → USD WAD(1e18)
    /// @dev btcWad * price8 / 1e8 — 1e18 스케일 유지. usdWadToBtc 와 대칭으로 영점 가격 방어.
    function btcToUsdWad(uint256 btcWad, uint256 price8) internal pure returns (uint256) {
        require(price8 > 0, "Units: zero price");
        return (btcWad * price8) / PRICE_ONE;
    }

    /// @notice USD WAD(1e18) → rBTC 수량(1e18) at 가격(8dec)
    function usdWadToBtc(uint256 usdWad, uint256 price8) internal pure returns (uint256) {
        require(price8 > 0, "Units: zero price");
        return (usdWad * PRICE_ONE) / price8;
    }

    /// @notice GMX 가격(30dec) → Chainlink 스케일(8dec)
    function gmxPriceToChainlink(uint256 gmxPrice30) internal pure returns (uint256) {
        return gmxPrice30 / GMX_TO_CL;
    }
}
