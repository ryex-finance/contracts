// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title LTVMath — LTV / Health Factor (FROZEN 공식, docs/12)
/// @notice 발행 허용·청산 임계의 단일 진실 공식. 순수 함수(가격 oracle 비의존).
///         Go `internal/domain/risk`가 동일 공식을 미러하고 차분 테스트로 강제(docs/12 R3).
/// @dev HF = LLTV / currentLTV  →  HF<=1 ⟺ 청산 가능. (docs/61 확정)
///      Wave 1: 임계값(maxLtv/lltv)은 마켓별 설정이라 파라미터로 받는다.
///      상수(MAX_LTV/LLTV)는 BTC 기본값으로 보존(default 오버로드 = BTC 마켓).
library LTVMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_LTV = 4_500; // 45% — BTC 발행 한도(기본)
    uint256 internal constant LLTV = 6_500; // 65% — BTC 청산 임계(기본)

    /// @notice currentLTV (bps). collateralValueUsd==0 → revert (정의 불가, docs/12 R1)
    /// @dev 입력 collateral/debt 가치는 동일 스케일이어야 한다(Units WAD 권장). 비율이라 스케일은 상쇄.
    function currentLTV(uint256 collateralValueUsd, uint256 debtValueUsd) internal pure returns (uint256) {
        require(collateralValueUsd > 0, "LTV: no collateral");
        return (debtValueUsd * BPS) / collateralValueUsd;
    }

    // ── 마켓별 임계값 버전 (Wave 1, 코어 경로가 사용) ──

    /// @notice Health Factor scaled by 1e18 at given lltv. debt==0(ltv==0) → max.
    function healthFactor(uint256 ltvBps, uint256 lltvBps) internal pure returns (uint256) {
        if (ltvBps == 0) return type(uint256).max;
        return (lltvBps * 1e18) / ltvBps;
    }

    /// @notice 청산 가능? currentLTV >= lltv (⟺ HF <= 1, docs/12 R4)
    function isLiquidatable(uint256 ltvBps, uint256 lltvBps) internal pure returns (bool) {
        return ltvBps >= lltvBps;
    }

    /// @notice 발행 허용? currentLTV <= maxLtv (docs/12 R4)
    function isMintAllowed(uint256 ltvBps, uint256 maxLtvBps) internal pure returns (bool) {
        return ltvBps <= maxLtvBps;
    }

    // ── v1.6: 레버리지별 MaxLTV 곡선 + 상환존(RLT) (Litepaper §5.1–5.3, §10.1) ──

    /// @notice 레버리지에 따른 MaxLTV 압축 곡선 (bps). Litepaper §5.1.
    /// @dev piecewise-linear:
    ///        leverage <= flatTier               → maxLtv1x (저배율 풀 한도)
    ///        flatTier < leverage <= maxLeverage → maxLtv1x − (maxLtv1x − maxLtvAtMaxLev)·(L−flatTier)/(maxLeverage−flatTier)
    ///      maxLtvAtMaxLev==0 이면 최대배율에서 mint 금지(§10.1). governance 튜너블.
    ///      검증: rBTC(maxLtv1x=8500, atMax=5000, flatTier=3, maxLev=10) → 1–3×:85% 5×:75% 7×:65% 10×:50% (표 정확 일치).
    function maxLtvForLeverage(
        uint256 maxLtv1xBps,
        uint256 maxLtvAtMaxLevBps,
        uint256 leverage,
        uint256 flatTier,
        uint256 maxLeverage
    ) internal pure returns (uint256) {
        require(leverage >= 1 && leverage <= maxLeverage, "LTV: bad leverage");
        require(maxLtv1xBps >= maxLtvAtMaxLevBps, "LTV: bad curve");
        // 저배율 평탄 구간(또는 곡선 폭 0).
        if (leverage <= flatTier || maxLeverage <= flatTier) return maxLtv1xBps;
        uint256 drop = (maxLtv1xBps - maxLtvAtMaxLevBps) * (leverage - flatTier) / (maxLeverage - flatTier);
        return maxLtv1xBps - drop;
    }

    /// @notice 레버리지 mint 가능? 곡선 MaxLTV가 0이면(최대배율 금지) 불가.
    function isLeverageMintable(
        uint256 maxLtv1xBps,
        uint256 maxLtvAtMaxLevBps,
        uint256 leverage,
        uint256 flatTier,
        uint256 maxLeverage
    ) internal pure returns (bool) {
        return maxLtvForLeverage(maxLtv1xBps, maxLtvAtMaxLevBps, leverage, flatTier, maxLeverage) > 0;
    }

    /// @notice LLTV = MaxLTV(1×) + Buffer. Litepaper §5.2 (기본 Buffer 10%).
    function lltvFromMaxLtv(uint256 maxLtv1xBps, uint256 bufferBps) internal pure returns (uint256) {
        return maxLtv1xBps + bufferBps;
    }

    /// @notice RLT(Redemption LTV Threshold) = MaxLTV(1×). Litepaper §5.3.
    function rltFromMaxLtv(uint256 maxLtv1xBps) internal pure returns (uint256) {
        return maxLtv1xBps;
    }

    /// @notice 상환존? RLT <= ltv < LLTV (redeemable, 청산 불가). Litepaper §4.5/§5.3.
    function inRedemptionZone(uint256 ltvBps, uint256 rltBps, uint256 lltvBps) internal pure returns (bool) {
        return ltvBps >= rltBps && ltvBps < lltvBps;
    }

    // ── BTC 기본값 오버로드 (frozen 테스트·기본 마켓 참조) ──

    function healthFactor(uint256 ltvBps) internal pure returns (uint256) {
        return healthFactor(ltvBps, LLTV);
    }

    function isLiquidatable(uint256 ltvBps) internal pure returns (bool) {
        return isLiquidatable(ltvBps, LLTV);
    }

    function isMintAllowed(uint256 ltvBps) internal pure returns (bool) {
        return isMintAllowed(ltvBps, MAX_LTV);
    }
}
