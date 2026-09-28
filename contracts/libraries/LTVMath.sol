// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Units} from "./Units.sol";
import {VaultState} from "../types/Types.sol";

/// @title LTVMath — LTV / Health Factor (FROZEN 공식, docs/12)
/// @notice 발행 허용·청산 임계의 단일 진실 공식. 순수 함수(가격 oracle 비의존).
///         Go `internal/domain/risk`가 동일 공식을 미러하고 차분 테스트로 강제(docs/12 R3).
/// @dev HF = LLTV / currentLTV  →  HF<=1 ⟺ 청산 가능. (docs/61 확정)
///      Wave 1: 임계값(maxLtv/lltv)은 마켓별 설정이라 파라미터로 받는다.
library LTVMath {
    uint256 internal constant BPS = 10_000;

    /// @notice currentLTV (bps). collateralValueUsd==0 → revert (정의 불가, docs/12 R1)
    /// @dev 입력 collateral/debt 가치는 동일 스케일이어야 한다(Units WAD 권장). 비율이라 스케일은 상쇄.
    function currentLTV(uint256 collateralValueUsd, uint256 debtValueUsd) internal pure returns (uint256) {
        require(collateralValueUsd > 0, "LTV: no collateral");
        return (debtValueUsd * BPS) / collateralValueUsd;
    }

    /// @notice debt==0 → 0, collateral==0 → max (정의 불가 sentinel).
    function currentLTVOrSentinel(uint256 collateralValueUsd, uint256 debtValueUsd) internal pure returns (uint256) {
        if (debtValueUsd == 0) return 0;
        if (collateralValueUsd == 0) return type(uint256).max;
        return currentLTV(collateralValueUsd, debtValueUsd);
    }

    // ── 마켓별 임계값 버전 (Wave 1, 코어 경로가 사용) ──

    /// @notice Health Factor scaled by 1e18 at given lltv. debt==0(ltv==0) → max.
    function healthFactor(uint256 ltvBps, uint256 lltvBps) internal pure returns (uint256) {
        if (ltvBps == 0) return type(uint256).max;
        return (lltvBps * 1e18) / ltvBps;
    }

    /// @notice Health Factor in BPS scale (10000 = HF 1.0 at LLTV). VaultLens 집계용.
    function healthFactorBps(uint256 ltvBps, uint256 lltvBps) internal pure returns (uint256) {
        if (ltvBps == 0) return type(uint256).max;
        return (lltvBps * BPS) / ltvBps;
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

    /// @dev 미설정(0) 레버리지는 1×로 취급.
    function normalizeLeverage(uint8 leverage) internal pure returns (uint256) {
        return leverage == 0 ? 1 : leverage;
    }

    /// @notice collateral × maxLtv 상한 부채 (USD WAD).
    function maxDebtUsdWad(uint256 collateralValueUsdWad, uint256 maxLtvBps) internal pure returns (uint256) {
        return (collateralValueUsdWad * maxLtvBps) / BPS;
    }

    /// @notice 추가 mint 가능 부채 headroom (USD WAD).
    function mintHeadroomUsdWad(uint256 collateralValueUsdWad, uint256 debtValueUsdWad, uint256 maxLtvBps)
        internal
        pure
        returns (uint256)
    {
        uint256 maxDebt = maxDebtUsdWad(collateralValueUsdWad, maxLtvBps);
        return maxDebt > debtValueUsdWad ? maxDebt - debtValueUsdWad : 0;
    }

    /// @notice 마켓 RiskParams 배포 시 불변식 검증.
    function isValidRiskParams(
        uint8 maxLeverage,
        uint16 maxLtv1xBps,
        uint16 bufferBps,
        uint8 flatTier,
        uint16 maxLtvAtMaxLevBps
    ) internal pure returns (bool) {
        if (maxLeverage == 0 || maxLtv1xBps == 0 || bufferBps == 0 || flatTier == 0) return false;
        if (flatTier > maxLeverage || maxLtvAtMaxLevBps > maxLtv1xBps) return false;
        if (uint256(maxLtv1xBps) + bufferBps > BPS) return false;
        return true;
    }

    /// @notice Active 포지션은 GMX equity, 그 외는 USDC 담보 (USD WAD).
    function collateralValueUsdWad(
        VaultState state,
        bytes32 posKey,
        uint256 collateralUsdc,
        uint256 gmxEquityUsdWad
    ) internal pure returns (uint256) {
        if ((state == VaultState.Active || state == VaultState.SettlingLiquidate) && posKey != bytes32(0)) {
            return gmxEquityUsdWad;
        }
        return Units.usdcToWad(collateralUsdc);
    }

    function effectiveMaxLtvBps(
        uint16 maxLtv1xBps,
        uint16 maxLtvAtMaxLevBps,
        uint8 leverage,
        uint8 flatTier,
        uint8 maxLeverage
    ) internal pure returns (uint256) {
        return maxLtvForLeverage(
            maxLtv1xBps, maxLtvAtMaxLevBps, normalizeLeverage(leverage), flatTier, maxLeverage
        );
    }

    function isActiveInRedemptionZone(VaultState state, uint256 ltvBps, uint256 rltBps, uint256 lltvBps)
        internal
        pure
        returns (bool)
    {
        return state == VaultState.Active && inRedemptionZone(ltvBps, rltBps, lltvBps);
    }

    /// @notice SL 연동 cap = RLT − slBuffer (청산용 bufferBps와 별도).
    function slCapBps(uint256 rltBps, uint256 slBufferBps) internal pure returns (uint256) {
        return rltBps > slBufferBps ? rltBps - slBufferBps : 0;
    }

    /// @notice SL 트리거 가격에서 LTV ≤ cap 인지. debt==0 → 항상 true.
    function isSlLtvAllowed(uint256 equityUsdWad, uint256 debtUsdWad, uint256 capBps) internal pure returns (bool) {
        if (debtUsdWad == 0) return true;
        if (equityUsdWad == 0) return false;
        return currentLTVOrSentinel(equityUsdWad, debtUsdWad) <= capBps;
    }

    /// @notice oracle-mark equity 모델에서 currentLTV == targetLtvBps 가 되는 가격(8dec).
    /// @dev equity = collatWad + collatWad·L·(±)(P−E)/E , debtUsd = debtRToken·P/1e8.
    ///      정의 불가(부채 없음·entry 0·분모≤0·1× 롱 등) → 0.
    function priceAtLtvBps(
        uint256 collateralUsdc,
        uint256 debtRToken,
        uint256 entryPrice8,
        uint256 leverage,
        bool isLong,
        uint256 targetLtvBps
    ) internal pure returns (uint256) {
        if (collateralUsdc == 0 || debtRToken == 0 || entryPrice8 == 0 || targetLtvBps == 0) return 0;
        uint256 L = leverage == 0 ? 1 : leverage;
        uint256 C = Units.usdcToWad(collateralUsdc);
        uint256 E = entryPrice8;
        uint256 D = debtRToken;
        uint256 lambda = targetLtvBps;
        // C * λ * 1e8
        uint256 cLamPrice = C * lambda * Units.PRICE_ONE;

        // Short: P = λ·C·1e8·(1+L)·E / (D·BPS·E + λ·C·1e8·L)
        // Long:  P = λ·C·1e8·(L−1)·E / (λ·C·1e8·L − D·BPS·E)   (L>1, den>0)
        if (isLong) {
            if (L <= 1) return 0; // 1× 롱: LTV가 P에 무관
            uint256 num = cLamPrice * (L - 1) * E;
            uint256 den = cLamPrice * L;
            uint256 sub = D * BPS * E;
            if (den <= sub) return 0;
            return num / (den - sub);
        }
        uint256 numS = cLamPrice * (1 + L) * E;
        uint256 denS = D * BPS * E + cLamPrice * L;
        if (denS == 0) return 0;
        return numS / denS;
    }
}
