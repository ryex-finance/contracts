// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @notice Vault 생명주기 상태 (GMX 2-step 비동기 흡수) — docs/10 §6
enum VaultState {
    Empty, // 생성됨, 포지션 없음
    SettlingOpen, // GMX open 주문 콜백 대기
    Active, // 포지션 활성
    SettlingLiquidate, // GMX close(청산) 주문 콜백 대기
    Liquidated // legacy only — 신규 청산은 Empty로 정산; deposit/open 시 Empty로 복구

}

/// @notice 대기 중 GMX 주문 종류
enum OrderKind {
    None,
    Open,        // market open
    Close,       // 수동 close (부채 0 필수)
    Liquidate,   // LLTV 강제 청산
    LimitOpen,   // 지정가 open — triggerPrice 도달 시 체결
    TakeProfit,  // 익절 — Active 중 별도 보관, pending과 무관
    StopLoss,    // 손절 — Active 중 별도 보관, pending과 무관
    Redeem       // RLT 상환 — GMX partial MarketDecrease 후 redeemer USDC 지급
}

/// @notice 콜백 대기 주문
struct PendingOrder {
    OrderKind kind;
    bytes32 orderKey;
    uint256 createdAt; // Settling 타임아웃 복구용 — docs/60 OQ-6
}

/// @notice GMX 연동 설정 — 환경별 주입(하드코딩 금지) docs/40 §3
struct GmxConfig {
    address exchangeRouter;
    address orderHandler; // 콜백 권한 검증
    address reader;
    address dataStore;
    address market; // BTC market token
    address collateralToken; // USDC
}

/// @notice 자산별 리스크 파라미터 — Litepaper v1.6 §5/§10. 레버리지별 LTV 곡선의 입력.
/// @dev RLT(상환 임계) = maxLtv1xBps, LLTV(청산 임계) = maxLtv1xBps + bufferBps.
struct RiskParams {
    uint16 maxLtv1xBps; // MaxLTV at 1× (= RLT). rBTC 8500(85%)
    uint16 bufferBps; // LLTV = maxLtv1x + buffer (§5.2, 기본 1000=10%)
    uint16 maxLtvAtMaxLevBps; // 최대배율에서의 MaxLTV. 0 ⇒ 최대배율 mint 금지(§10.1). rBTC 5000(50%)
    uint8 flatTier; // 이 레버리지 이하는 full maxLtv1x (기본 3)
    uint8 maxLeverage; // 허용 최대 레버리지 (rBTC 10)
}

/// @notice GMX 실포지션 스냅샷 — vaultInfo() 내 gmx 필드. IGmxAdapter.GmxPositionData와 동일 레이아웃.
/// @dev 프론트: sizeInUsd→formatUnits(30), collateralAmount→formatUnits(6), entryPrice8→formatUnits(8)
struct VaultGmxPosition {
    bool exists;
    uint256 sizeInUsd;        // GMX 30-dec USD 명목 (예: $10 → 10 × 10^30). 8dec 변환 없음.
    uint256 collateralAmount; // USDC 6-dec (예: 5 USDC → 5_000_000)
    uint256 entryPrice8;      // Chainlink 8-dec 진입가. 실 GMX Reader 경로는 0.
}

/// @notice 볼트 전체 상태 스냅샷 — UI/인덱서가 단일 eth_call로 조회.
/// @dev 금액 필드 decimals 요약:
///      collateralUsdc / pendingFeesUsdc → 6 (USDC)
///      debtRToken                       → 18 (rToken)
///      collateralValueUsdWad / debtValueUsdWad / healthFactorWad → 18 (WAD)
///      oraclePrice8                     → 8 (Chainlink)
///      gmx.sizeInUsd                    → 30 (GMX passthrough)
///      gmx.collateralAmount             → 6 (USDC)
///      gmx.entryPrice8                  → 8 (mock만; 실 GMX는 0)
///      currentLtvBps / lltvBps / …      → bps (10000 = 100%)
struct VaultSnapshot {
    address owner;
    bytes32 marketId;
    VaultState state;
    uint8 leverage;
    bool isLong;    // 롱(true) / 숏(false)
    bytes32 posKey;
    // ── 잔고 ──
    uint256 collateralUsdc; // USDC 6-dec
    uint256 debtRToken;     // rToken 18-dec
    // ── 대기 주문 ──
    OrderKind pendingKind;
    bytes32 pendingOrderKey;
    uint256 pendingCreatedAt;
    // ── 리스크 파라미터 (bps / 레버리지) ──
    uint16 maxLtv1xBps;
    uint16 bufferBps;
    uint16 maxLtvAtMaxLevBps;
    uint8 flatTier;
    uint8 maxLeverage;
    // ── 계산값 (RYex 회계 — oracle 8-dec → WAD 18-dec 기반, GMX 30-dec 아님) ──
    uint256 collateralValueUsdWad; // USD 18-dec WAD (예: $5 → 5 × 10^18)
    uint256 debtValueUsdWad;       // USD 18-dec WAD
    uint256 currentLtvBps;         // bps (7599 = 75.99%)
    uint256 healthFactorWad;       // 18-dec (1e18 = HF 1.0)
    uint256 lltvBps;               // bps
    uint256 rltBps;                // bps
    uint256 effectiveMaxLtvBps;    // bps
    uint256 oraclePrice8;          // Chainlink 8-dec (예: $1650 → 165_000_000_000)
    uint256 pendingFeesUsdc;       // USDC 6-dec
    // ── 플래그 ──
    bool isRedeemable;
    bool isLiquidatable;
    // ── 조건부 청산 주문 키 ──
    bytes32 tpOrderKey; // Take Profit RYex 주문 키 (0 = 없음)
    bytes32 slOrderKey; // Stop Loss  RYex 주문 키 (0 = 없음)
    // ── GMX 실포지션 (Reader passthrough) ──
    VaultGmxPosition gmx;
}

/// @notice 자산별 마켓 설정 — VaultFactory 레지스트리(멀티에셋). 자산별 oracle·rToken·리스크곡선.
/// @dev flat struct(중첩 없음) — public mapping auto-getter 호환. RiskParams로 묶어 전달.
struct Market {
    bool active;
    address oracle; // IPriceOracle (자산 가격피드)
    address rToken; // IRToken (자산별 부채 토큰: rBTC, rETH, …)
    uint16 maxLtv1xBps; // MaxLTV at 1× (= RLT)
    uint16 bufferBps; // LLTV = maxLtv1x + buffer
    uint16 maxLtvAtMaxLevBps; // 최대배율 MaxLTV (0=mint 금지)
    uint8 flatTier; // full-maxLtv 평탄 구간 상한
    uint8 maxLeverage; // 허용 최대 레버리지
}
