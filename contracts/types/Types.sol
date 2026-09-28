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
    LimitClose,  // 지정가 close — triggerPrice 도달 시 전량 청산
    TakeProfit,  // 익절 — Active 중 별도 보관, pending과 무관
    StopLoss,    // 손절 — Active 중 별도 보관, pending과 무관
    Redeem,      // RLT 상환 — GMX partial MarketDecrease 후 redeemer USDC 지급
    DepositCollateral, // GMX MarketIncrease(size=0) — 포지션 담보만 추가
    WithdrawCollateral // GMX MarketDecrease(size=0) — excess 담보만 회수
}

/// @notice 콜백 대기 주문
struct PendingOrder {
    OrderKind kind;
    bytes32 orderKey;
    uint256 createdAt; // Settling 타임아웃 복구용 — docs/60 OQ-6
}

/// @notice GMX 연동 설정 — VaultFactory에 환경별 주입(하드코딩 금지) docs/40 §3
struct GmxInfra {
    address exchangeRouter;
    address gmxRouter; // USDC approve target
    address orderVault; // WNT exec-fee + collateral sink
    address reader;
    address dataStore;
    address orderHandler; // 콜백 호출자 검증 (0 = 스킵, 테스트 전용)
    uint256 execFee; // WNT per order
    uint256 acceptablePriceMax; // 롱 open / 숏 close 상한
    uint256 acceptablePriceMin; // 숏 open / 롱 close 하한
}

/// @notice GMX 실포지션 스냅샷 — gmxPosition() / vaultInfo().gmx
struct GmxPositionData {
    bool exists;
    uint256 sizeInUsd; // GMX 30-dec
    uint256 collateralAmount; // USDC 6-dec
    uint256 entryPrice8; // 8-dec avg entry (mock ledger 또는 sizeInUsd/sizeInTokens)
    uint256 liquidationPrice8; // GMX 포지션 청산가 8-dec (UI 근사, 0=없음)
}

/// @notice Per-vault GMX 주문 (GmxExecutor store).
struct GmxOrder {
    uint8 kind;
    bool executed;
    uint256 redeemUsdc;
    uint256 usdcSnap;
    bool isIncrease;
    uint256 openCollateral;
    uint256 openSizeUsd;
    uint256 gmxSizeBefore;
    bytes32 gmxKey;
}

/// @notice Per-vault GMX ledger + 주문 맵 (vault storage).
struct GmxVaultStore {
    mapping(bytes32 => GmxOrder) orders;
    mapping(bytes32 => bytes32) gmxKeyToRyexKey;
    bytes32 pendingFundingSettleRyexKey; // 미체결 accrued funding settle 주문 (0=없음)
    uint256 orderNonce;
    uint256 mockCollateral;
    uint256 mockEntryPrice8;
    uint256 mockSizeUsd;
    bool mockActive;
}

/// @notice Per-vault 가변 포지션 상태 (vault storage). VaultSettle 라이브러리가 storage ref로 정산.
/// @dev config(owner·rToken·risk 곡선)는 vault 스칼라에 유지. 여기엔 정산 상태머신이 변경하는 필드만.
struct PositionStore {
    uint256 collateral; // USDC 회계 (6dec)
    uint256 debt; // rToken (18dec)
    VaultState state;
    PendingOrder pending;
    bytes32 posKey;
    address liquidator; // 청산 보상 수령자 (내부 부킹)
    address pendingRedeemer; // RLT redeem 대기 중 rToken 제출자
    uint256 pendingRedeemAmt; // escrow rToken (18dec)
    uint256 pendingRedeemUsdcSnap; // redeem 정산 시 증가분만 회수
    uint256 pendingWithdrawUsdcSnap; // withdrawCollateral 정산 시 증가분만 회수
    uint256 accruedFeesUsdc; // 누적 프로토콜 수수료(USDC 6dec): mint+redeem (treasury 전액)
    uint256 accruedBorrowFeeUsdc; // 누적 borrow fee(USDC 6dec, 1.5% APR) — factory.borrowFeeToLpBps 비율만큼 LP 인센티브로, 나머지 treasury
    uint256 lastAccrual; // 마지막 borrow-fee 적립 시각
    // ── 조건부 청산 주문 (Active 중 보관, pending 슬롯과 별개) ──
    bytes32 tpOrderKey; // Take Profit RYex 주문 키 (없으면 0)
    bytes32 slOrderKey; // Stop Loss RYex 주문 키 (없으면 0)
    uint256 slTriggerPrice8; // SL 트리거 가격 (8dec). mint·SL 갱신 시 ltvAt(SL) 검사용.
    bytes32 tpCancellingKey; // GMX 취소 대기 중 TP (콜백 전까지 tpOrderKey 유지)
    bytes32 slCancellingKey; // GMX 취소 대기 중 SL
}

/// @notice VaultSettle 정산 호출 컨텍스트 (vault config 묶음).
struct SettleCtx {
    address owner;
    address factory;
    bytes32 marketId;
    address oracle; // IPriceOracle
    address usdc; // IERC20
    address rToken; // IRToken
    bool isLong; // _mockPosKey 재계산용 (VaultSettle이 GmxIntegrationBase 콜 없이 자체 계산)
}

/// @notice GmxExecutor / GmxIntegrationReader 공통 호출 컨텍스트.
struct GmxVaultCtx {
    address vault;
    address factory;
    address oracle;
    address usdc;
    bytes32 marketId;
    bool isLong;
    uint8 leverage;
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

/// @notice 볼트 전체 상태 스냅샷 — UI/인덱서가 단일 eth_call로 조회.
/// @dev 금액 필드 decimals 요약:
///      collateralUsdc / pendingFeesUsdc → 6 (USDC)
///      debtRToken                       → 18 (rToken)
///      collateralValueUsdWad / debtValueUsdWad / healthFactorWad → 18 (WAD)
///      oraclePrice8                     → 8 (Chainlink)
///      gmx.sizeInUsd                    → 30 (GMX passthrough)
///      gmx.collateralAmount             → 6 (USDC)
///      gmx.entryPrice8 / gmx.liquidationPrice8 → 8 (GMX avg entry / GMX 포지션 청산가)
///      oraclePrice8 / liquidationPrice8     → 8 (oracle; liquidationPrice8=RYex LLTV)
///      borrowAprBps / currentLtvBps / …     → bps (150 = 1.5% APR; 10000 = 100%)
///      pendingOpenCollateralUsdc         → 6 (USDC; 이번 pending 주문의 담보 증가분만)
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
    uint256 liquidationPrice8;     // RYex LLTV 도달 오라클 가격 8-dec (≠ gmx.liquidationPrice8)
    uint256 borrowAprBps;          // borrow/stability fee APR (bps; 150 = 1.5%)
    uint256 pendingFeesUsdc;       // USDC 6-dec
    uint256 pendingOpenCollateralUsdc; // 대기 중 Open/LimitOpen/DepositCollateral 주문의 담보 증가분 (6dec, 없으면 0)
    // ── 플래그 ──
    bool isRedeemable;
    bool isLiquidatable;
    // ── 조건부 청산 주문 키 ──
    bytes32 tpOrderKey; // Take Profit RYex 주문 키 (0 = 없음)
    bytes32 slOrderKey; // Stop Loss  RYex 주문 키 (0 = 없음)
    // ── GMX 실포지션 (Reader passthrough) ──
    GmxPositionData gmx;
    // ── GMX 펀딩비 (표시 전용 추정치, VaultLens.vaultAccruedFundingGmx 참고) ──
    //   프론트: 두 값 모두 raw 원자단위(decimals 미보정) — long은 index 자산(예: WETH 18dec),
    //   short은 대부분 USDC(6dec)라 화면 표시 전 각 토큰 decimals로 나눠야 한다.
    //   "받을 펀딩비"만 나타내며, 실 클레임 값은 harvestFunding() 실행 시점 기준으로 소폭 다를 수 있다.
    uint256 accruedFundingLongAmt; // long 토큰 원자단위 (예: WETH)
    uint256 accruedFundingShortAmt; // short 토큰 원자단위 (예: USDC)
}

/// @notice rYield 델타뉴트럴 볼트의 헤지 상태머신 (GMX 숏 단일 pending 흡수).
enum RYieldState {
    Idle, // 대기 주문 없음 — deposit/withdraw/rebalance/unwind 진입 가능
    SettlingHedge, // GMX 숏 increase(open) 콜백 대기
    SettlingUnwind // GMX 숏 close 콜백 대기
}

/// @notice rYield 풀링 볼트 상태 (RYieldVault storage). 단일자산·격리·share 회계 + 헤지 상태머신.
/// @dev GMX 숏 ledger/주문은 GmxIntegrationBase의 _gmxStore를 재사용. 여기엔 share·헤지·수수료·게이트 회계만.
struct RYieldStore {
    // ── 풀링 지분 회계 ──
    uint256 totalShares;
    mapping(address => uint256) sharesOf;
    // ── 헤지 상태머신 (GMX 숏 단일 pending, short-first) ──
    RYieldState state;
    bytes32 pendingOrderKey; // 대기 중 GMX 숏 주문(RYex 키)
    uint256 pendingCreatedAt; // Settling 타임아웃 복구용
    uint256 pendingLongUsdc; // 숏 체결 후 AMM 롱에 쓸 예약 USDC (체결 콜백에서 매수)
    int256 pendingEntryGapBps; // 이번 헤지 진입 갭 스냅샷 (체결 시 가중평균에 커밋)
    uint256 pendingHedgeNotionalUsdc; // 이번 헤지 숏 명목 (가중평균 가중치)
    // ── 포지션 누적 회계 (방향성 역전 방어) ──
    int256 entryGapBps; // 명목가중 평균 진입 갭 = (GMX-AMM)/GMX, +면 AMM이 GMX보다 쌈
    uint256 hedgedNotionalUsdc; // 현재 헤지된 숏 명목 합계
    // ── 상환 큐 (per-user unwind: requestUnwind → 봇 executeUnwind → claim) ──
    uint256 reservedClaimableUsdc; // 체결 완료된 상환 지급예정액 — 가용 idle/NAV에서 제외(이미 소각된 share 몫)
    uint256 totalRedeemShares; // 현재 epoch 대기 중 상환 요청 share 합
    uint256 currentRedeemEpoch; // 신규 requestUnwind가 적재되는 epoch
    mapping(address => uint256) redeemShares; // 유저별 대기/미청구 상환 share
    mapping(address => uint256) redeemReqEpoch; // 유저 요청이 속한 epoch
    mapping(uint256 => uint256) epochPayoutUsdc; // 체결된 epoch의 총 지급액
    mapping(uint256 => uint256) epochRedeemShares; // 체결된 epoch의 총 상환 share
    // 실행 중 배치 스냅샷 (executeUnwind → finalize 동안 보존)
    uint256 pendingRedeemShares; // 이번 배치(청크) 상환 share
    uint256 pendingRedeemEpoch; // 이번 청크가 귀속되는 epoch
    uint256 pendingIdleReserveUsdc; // 상환자 기존 idle 몫(청산 전 예약분)
    uint256 pendingIdleSnapshotUsdc; // 청산 전 가용 idle 스냅샷(freed 계산용)
    // 부분 청산(코호트 다회 분할) 상태 — 한 epoch을 가격밴드 한도 내 수량씩 여러 executeUnwind로 소진
    uint256 settlingEpoch; // 현재 분할 청산 중인 epoch (settlingRemainingShares>0일 때 유효)
    uint256 settlingRemainingShares; // 해당 epoch에서 아직 청산 못한 잔여 share (>0면 claim 불가)
    // ── 성과수수료 high-water mark ──
    uint256 hwmAssetsPerShareWad; // 직전 최고 NAV/share (1e18 스케일)
    // ── 파라미터 (owner 설정) ──
    uint256 depositCap; // NAV(totalAssets) 상한 — utilization gate (AMM depth 연동)
    uint256 minDeposit; // 최소 예치액 (고정비용 상쇄, 기본 500 USDC)
    address pool; // UniV3 rToken/USDC 풀 (AMM 가격 게이트용)
    uint32 twapWindow; // TWAP 윈도우(초). 0 = spot(slot0) 폴백
    uint16 perfFeeBps; // 성과수수료 (1000 = 10%)
    uint16 swapSlippageBps; // AMM 롱 leg USDC↔rToken 스왑 최대 슬리피지
    uint16 maxEntryPremiumBps; // 진입 시 AMM이 GMX보다 높아도 허용하는 폭 (기본 0 = AMM<GMX 강제)
    uint16 maxExitDiscountBps; // 종료 시 AMM이 GMX보다 낮아도 허용하는 폭 (기본 0 = AMM>=GMX 강제)
    uint16 maxPriceImpactBps; // rebalance 1회 AMM 롱 매수 최대 price impact (풀 깊이 기준 부분 집행)
    bool gapCheckEnabled; // 방향성 역전 방어 on/off (진입·인출 게이트 공통)
    uint8 targetLeverage; // GMX 숏 레버리지
}

/// @notice RYieldRegistry·RYieldViews가 읽는 rYield vault 스칼라 스냅샷(mapping 제외).
struct RYieldLensPack {
    RYieldState state;
    uint256 totalShares;
    bytes32 pendingOrderKey;
    uint256 pendingCreatedAt;
    uint256 depositCap;
    uint16 perfFeeBps;
    uint16 maxPriceImpactBps;
    uint16 maxEntryPremiumBps;
    uint16 maxExitDiscountBps;
    uint8 targetLeverage;
    uint256 hwmAssetsPerShareWad;
    int256 entryGapBps;
    uint256 hedgedNotionalUsdc;
    uint256 minDeposit;
    bool gapCheckEnabled;
    address pool;
    uint32 twapWindow;
    uint256 reservedClaimableUsdc;
    uint256 totalRedeemShares;
    uint256 currentRedeemEpoch;
    uint256 settlingEpoch;
    uint256 settlingRemainingShares;
}

/// @notice RYieldRegistry UI 대시보드 — 풀 전역 스냅샷.
struct RYieldVaultSummary {
    bytes32 marketId;
    address vault;
    address distributor;
    address rToken;
    address oracle;
    string assetName;
    RYieldState state;
    uint256 totalShares;
    uint256 totalAssetsUsdc;
    uint256 pricePerShareWad;
    uint256 idleUsdc;
    uint256 hedgedAssetsUsdc;
    uint256 longValueUsdc;
    uint256 shortEquityUsdc;
    int256 currentGapBps;
    int256 entryGapBps;
    uint256 hedgedNotionalUsdc;
    uint256 depositCap;
    uint256 minDeposit;
    uint16 perfFeeBps;
    uint8 targetLeverage;
    uint256 hwmAssetsPerShareWad;
    uint256 execFee;
    uint256 execFeeBalance;
    bytes32 pendingOrderKey;
    uint256 pendingCreatedAt;
    bool fundingSettlePending;
    uint256 oraclePrice8;
    uint256 ammPrice8;
    address pool;
    uint256 reservedClaimableUsdc;
    uint256 totalRedeemShares;
    uint256 settlingEpoch;
    uint256 settlingRemainingShares;
    bool gapCheckEnabled;
    uint16 maxPriceImpactBps;
    uint16 maxEntryPremiumBps;
    uint16 maxExitDiscountBps;
}

/// @notice RYieldRegistry UI — 유저 지분·인출·상환 큐 스냅샷.
struct RYieldUserSummary {
    uint256 shares;
    uint256 fundingShares;
    uint256 assetsUsdc;
    uint256 hedgedUsdc;
    uint256 idleShareUsdc;
    uint256 maxWithdrawableUsdc;
    uint256 redeemShares;
    uint256 claimableUsdc;
}

/// @notice RYieldRegistry UI — 펀딩비(확정·claimable·accrued) 스냅샷.
struct RYieldFundingSummary {
    uint256 longConfirmed;
    uint256 longPending;
    uint256 shortConfirmed;
    uint256 shortPending;
    uint256 longAccrued;
    uint256 shortAccrued;
    bool settlePending;
    uint256 vaultClaimableLong;
    uint256 vaultClaimableShort;
    uint256 vaultAccruedLong;
    uint256 vaultAccruedShort;
}

/// @notice 자산별 마켓 설정 — VaultFactory 레지스트리(멀티에셋). 자산별 oracle·rToken·리스크곡선.
/// @dev flat struct(중첩 없음) — public mapping auto-getter 호환. RiskParams로 묶어 전달.
struct Market {
    bool active;
    address oracle; // IPriceOracle (자산 가격피드)
    address rToken; // IRToken (자산별 부채 토큰: rBTC, rETH, …)
    address gmxMarket; // GMX v2 market token (0 = mock-only)
    address pool; // UniV3 rToken/USDC 풀 (청산 buyback 가격조회·스왑 라우팅용, 0=미설정)
    uint16 maxLtv1xBps; // MaxLTV at 1× (= RLT)
    uint16 bufferBps; // LLTV = maxLtv1x + buffer
    uint16 maxLtvAtMaxLevBps; // 최대배율 MaxLTV (0=mint 금지)
    uint8 flatTier; // full-maxLtv 평탄 구간 상한
    uint8 maxLeverage; // 허용 최대 레버리지
    uint16 borrowAprBps; // borrow/stability fee APR(bps, 마켓별 — 기본 150=1.5%). owner가 setBorrowAprBps로 조정
}
