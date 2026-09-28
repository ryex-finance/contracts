// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title Units — 단위·정밀도 단일화 (docs/60 OQ-3)
/// @notice 모든 토큰/가격 자릿수 변환을 한곳에 모은다. 어떤 컨트랙트도 raw 나눗셈을 직접 하지 않는다.
///         USD 내부 표현은 WAD(1e18)로 통일한다.
///         decimals: USDC=6, rToken=18, Chainlink price=8, GMX price=30, USD(internal)=18(WAD).
library Units {
    uint256 internal constant USDC_DEC = 6;
    uint256 internal constant RTOKEN_DEC = 18;
    uint256 internal constant PRICE_DEC = 8; // Chainlink asset/USD
    uint256 internal constant WAD = 18; // 내부 USD 스케일

    uint256 internal constant USDC_TO_WAD = 1e12; // 1e18 / 1e6
    uint256 internal constant PRICE_ONE = 1e8; // 가격 1.0 (8dec)

    /// @notice Chainlink 8-dec → GMX contract price.
    /// @dev GMX: price = USD × 10^(30 - tokenDecimals) = price8 × 10^(22 - tokenDecimals).
    ///      ETH(18) → ×1e4, BTC(8) → ×1e14. tokenDecimals를 무시하고 ×1e22 하면 trigger가 10^18배 과대해져
    ///      LimitIncrease가 영구 미체결(숏) / 즉시 체결(롱) 된다.
    function price8ToGmx30(uint256 price8, uint8 tokenDecimals) internal pure returns (uint256) {
        require(tokenDecimals > 0 && tokenDecimals <= 18, "Units: bad token dec");
        return price8 * (10 ** (22 - uint256(tokenDecimals)));
    }

    /// @notice GMX contract price → Chainlink 8-dec (GMX oracle API 공식).
    /// @dev price8 = gmx30 / 10^(30 - tokenDecimals - PRICE_DEC) = gmx30 / 10^(22 - tokenDecimals)
    function gmx30ToPrice8(uint256 gmxPrice30, uint8 tokenDecimals) internal pure returns (uint256) {
        require(tokenDecimals > 0 && tokenDecimals <= 18, "Units: bad token dec");
        uint256 exp = 22 - uint256(tokenDecimals);
        return gmxPrice30 / (10 ** exp);
    }

    /// @notice GMX sizeInUsd(30) / sizeInTokens(index dec) → avg entry 8-dec.
    /// @dev size/sizeTokens 스케일은 10^(30-indexDec); 8dec로 내리려면 /10^(22-indexDec).
    function gmxSizeToEntryPrice8(uint256 sizeInUsd, uint256 sizeInTokens, uint8 indexTokenDecimals)
        internal
        pure
        returns (uint256)
    {
        if (sizeInTokens == 0 || indexTokenDecimals == 0 || indexTokenDecimals > 18) return 0;
        uint256 exp = 22 - uint256(indexTokenDecimals);
        return sizeInUsd / sizeInTokens / (10 ** exp);
    }

    /// @notice USDC(6dec) → USD WAD(1e18)
    function usdcToWad(uint256 usdc) internal pure returns (uint256) {
        return usdc * USDC_TO_WAD;
    }

    /// @notice USD WAD(1e18) → USDC(6dec) (내림)
    function wadToUsdc(uint256 wad) internal pure returns (uint256) {
        return wad / USDC_TO_WAD;
    }

    /// @notice rToken 수량(18dec) × oracle 가격(8dec) → USD WAD(1e18). 자산 무관 (rBTC, rETH, …).
    /// @dev rTokenWad * price8 / 1e8 — 1e18 스케일 유지. usdWadToRToken 과 대칭으로 영점 가격 방어.
    function rTokenToUsdWad(uint256 rTokenWad, uint256 price8) internal pure returns (uint256) {
        require(price8 > 0, "Units: zero price");
        return (rTokenWad * price8) / PRICE_ONE;
    }

    /// @notice USD WAD(1e18) → rToken 수량(18dec) at oracle 가격(8dec).
    function usdWadToRToken(uint256 usdWad, uint256 price8) internal pure returns (uint256) {
        require(price8 > 0, "Units: zero price");
        return (usdWad * PRICE_ONE) / price8;
    }

    /// @notice rToken(18dec) × oracle price(8dec) → USDC(6dec).
    function rTokenToUsdc(uint256 rTokenWad, uint256 price8) internal pure returns (uint256) {
        return wadToUsdc(rTokenToUsdWad(rTokenWad, price8));
    }
}
