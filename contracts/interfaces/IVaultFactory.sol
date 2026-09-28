// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";
import {GmxInfra, RiskParams} from "../types/Types.sol";

/// @title IVaultFactory — 멀티에셋 마켓 레지스트리 + 사용자별 PositionVault clone (docs/10, Wave 1)
interface IVaultFactory {
    event VaultCreated(address indexed owner, bytes32 indexed marketId, bool isLong, address vault);
    event MarketAdded(bytes32 indexed marketId, address oracle, address rToken);
    event MarketOracleUpdated(bytes32 indexed marketId, address oldOracle, address newOracle);
    event MarketRiskUpdated(
        bytes32 indexed marketId,
        uint16 maxLtv1xBps,
        uint16 bufferBps,
        uint16 maxLtvAtMaxLevBps,
        uint8 flatTier,
        uint8 maxLeverage
    );
    event MarketBufferUpdated(bytes32 indexed marketId, uint16 oldBufferBps, uint16 newBufferBps);
    /// @notice 마켓별 borrow/stability fee APR(bps) 변경. addMarket 최초 등록 시에도 발생(old=0).
    event MarketBorrowAprUpdated(bytes32 indexed marketId, uint16 oldBps, uint16 newBps);
    event SwapRouterSet(address indexed swapRouter, uint24 fee);
    event TreasurySet(address indexed treasury);
    event MarketPoolUpdated(bytes32 indexed marketId, address oldPool, address newPool);
    event BuybackParamsSet(uint32 twapWindow, uint16 bountyBps, uint16 bufferBps);
    /// @notice 청산 시 오라클가로 확정 정산된 부채분 — 즉시 소각 없이 대기버킷에 적립(투명성 로그).
    event LiquidationEarmarked(bytes32 indexed marketId, address indexed vault, uint256 usdcAmount, uint256 rTokenAmount);
    /// @notice permissionless buyback 실행 — 스팟이 오라클가 이하일 때만 성립.
    event BuybackBurned(
        bytes32 indexed marketId, address indexed caller, uint256 usdcSpent, uint256 rTokenBurned, uint256 callerBounty
    );
    event LpZapSet(address indexed lpZap);
    event BorrowFeeToLpBpsSet(uint16 bps);
    /// @notice close/liquidate 정산 시 borrow fee 중 LP 인센티브 몫이 확정됨(투명성 로그). lpZap 설정 여부에
    ///         따라 즉시 LpZap으로 전달되거나(설정됨) 대기버킷에 쌓인다(미설정, flushPendingLpIncentive 대상).
    event BorrowFeeEarned(bytes32 indexed marketId, address indexed vault, uint256 usdcAmount);

    /// @notice (owner, marketId, isLong)용 Vault clone 생성·초기화. 방향별 1인1볼트.
  ///         Router 등 대리 생성 시 owner_에 실제 유저 주소 전달.
    function createVault(bytes32 marketId, bool isLong, address owner_) external returns (address vault);

    function vaultOf(address owner, bytes32 marketId, bool isLong) external view returns (address);
    function router() external view returns (address);
    function setRouter(address router_) external;
    function treasury() external view returns (address);
    function setTreasury(address treasury_) external;
    function isVault(address vault) external view returns (bool);

    function totalVaults() external view returns (uint256);
    function vaultAt(uint256 i) external view returns (address);

    /// @notice 마켓 oracle 주소만 반환 (vault hot-path 경량 조회 — 전체 Market 디코드 회피).
    function marketOracle(bytes32 marketId) external view returns (address);

    /// @notice 마켓 설정 조회 (flat Market). Litepaper v1.6 레버리지 곡선 파라미터.
    function markets(bytes32 marketId)
        external
        view
        returns (
            bool active,
            address oracle,
            address rToken,
            address gmxMarket,
            address pool,
            uint16 maxLtv1xBps,
            uint16 bufferBps,
            uint16 maxLtvAtMaxLevBps,
            uint8 flatTier,
            uint8 maxLeverage,
            uint16 borrowAprBps
        );

    /// @notice Vault가 collateral 증감 시 호출 → factory의 totalCollateralLocked 갱신.
    ///         delta > 0: 증가(deposit), delta < 0: 감소(withdraw/close/liquidation).
    ///         isVault[msg.sender] 가드로 registered vault만 허용.
    function onCollateralChanged(int256 delta) external;

    function totalCollateralLocked() external view returns (uint256);

    /// @notice UniV3 SwapRouter (v3-periphery, deadline 있음 — 청산 buyback USDC↔rToken).
    function swapRouter() external view returns (address);

  /// @notice UniV3 pool fee tier (e.g. 3000 = 0.3%).
    function swapFee() external view returns (uint24);

    function setSwapRouter(address router_, uint24 fee_) external;

    /// @notice 마켓 oracle 교체 (mock ↔ GMX 등). vault는 factory markets[marketId].oracle을 직접 참조.
    function setMarketOracle(bytes32 marketId, IPriceOracle oracle_) external;

    /// @notice 마켓 전체 RiskParams 교체 (MaxLTV 곡선·buffer·maxLeverage). vault LTV는 factory를 live 참조.
    function setMarketRisk(bytes32 marketId, RiskParams calldata risk) external;

    /// @notice 마켓 bufferBps만 교체 (LLTV = maxLtv1x + buffer).
    function setBufferBps(bytes32 marketId, uint16 bufferBps_) external;

    /// @notice 마켓별 borrow/stability fee APR(bps) 교체 — 마켓마다 차등 가능. 상한 있음(MAX_BORROW_APR_BPS).
    function setBorrowAprBps(bytes32 marketId, uint16 bps_) external;

    /// @notice 마켓 UniV3 rToken/USDC pool 등록 (buyback 가격조회용). 0 허용(미설정 = buyback 비활성).
    function setMarketPool(bytes32 marketId, address pool_) external;

    /// @notice buyback 파라미터 — TWAP 보조 필터 윈도우(초, 0=스팟만), 호출자 보너스(bps),
    ///         목표가 버퍼(bps, 오라클가에서 이만큼 아래를 목표로 sqrtPriceLimitX96 설정).
    function setBuybackParams(uint32 twapWindow_, uint16 bountyBps_, uint16 bufferBps_) external;

    /// @notice 청산 시 오라클가로 확정한 부채분을 대기버킷에 적립 — registered vault 전용.
    ///         vault가 사전에 USDC를 factory로 전송한 뒤 호출(이벤트·카운터 갱신).
    function notifyLiquidationEarmark(bytes32 marketId, uint256 usdcAmount, uint256 rTokenAmount) external;

    /// @notice permissionless — 풀 **스팟**이 오라클가 이하일 때만 대기버킷 USDC로 rToken을 사서 태움.
    ///         TWAP(설정 시)은 최근 평균이 오라클 위인 윅을 거르는 보조 필터일 뿐, 체결가가 아니다.
    /// @param maxUsdcIn 이번 호출에서 쓸 USDC 상한(0=버킷 전체까지 시도). 실제 사용량은
    ///        버킷 잔액·outstanding 오라클 페어밸류·sqrtPriceLimit(오라클-버퍼)로 추가 캡핑됨.
    function buybackAndBurn(bytes32 marketId, uint256 maxUsdcIn)
        external
        returns (uint256 usdcSpent, uint256 rTokenBurned, uint256 callerBounty);

    /// @notice 마켓별 대기 중인 buyback 자금(USDC, 6dec) — 투명성 대시보드.
    function pendingBuybackUsdc(bytes32 marketId) external view returns (uint256);

    /// @notice 마켓별 아직 buyback으로 소각되지 않은 rToken 수량(18dec) — 투명성 대시보드.
    function outstandingUnretired(bytes32 marketId) external view returns (uint256);

    /// @notice 마켓별 buyback으로 누적 소각된 rToken 수량(18dec) — 투명성 대시보드.
    function totalBurnedViaBuyback(bytes32 marketId) external view returns (uint256);

    /// @notice 마켓별 청산에서 누적 적립된 USDC 총액(그로스, 6dec) — 투명성 대시보드.
    function totalEarmarkedUsdc(bytes32 marketId) external view returns (uint256);

    /// @notice permissionless 조회 — buybackAndBurn과 동일한 가격 게이트를 상태 변경 없이 재사용.
    ///         keeper가 buybackAndBurn 호출 전 오프체인에서 UniV3 tick 수학을 재구현할 필요를 없앤다.
    /// @return ready true면 buybackAndBurn 실행 조건 충족(스팟 ≤ 오라클, 스팟 < 목표가, TWAP 필터 통과).
    function buybackPreview(bytes32 marketId)
        external
        view
        returns (
            bool ready,
            uint256 spotPrice8,
            uint256 twapPrice8,
            uint256 oraclePrice8,
            uint256 targetPrice8,
            uint256 bucket,
            uint256 outstanding
        );

    // ── LP 인센티브 (borrow fee → 마켓 rToken/USDC 풀 LpZap 리워드, 라운드 없이 연속 분배) ──

    /// @notice LpZap 배포 주소 (0=미설정 — notifyBorrowFeeEarned는 pendingLpIncentiveUsdc에 대기).
    function lpZap() external view returns (address);
    function setLpZap(address lpZap_) external;

    /// @notice borrow fee(1.5% APR) 중 LP 인센티브로 돌릴 비율(bps, 10000=100%). owner 조정 가능.
    function borrowFeeToLpBps() external view returns (uint16);
    function setBorrowFeeToLpBps(uint16 bps_) external;

    /// @notice close/liquidate 정산 시 borrow fee의 LP 몫을 LpZap으로 즉시 전달(또는 미설정 시 대기버킷에
    ///         적립) — registered vault 전용. vault가 사전에 USDC를 factory로 전송한 뒤 호출.
    function notifyBorrowFeeEarned(bytes32 marketId, uint256 usdcAmount) external;

    /// @notice permissionless — lpZap 미설정 기간에 쌓인 대기 버킷을 지금 설정된 LpZap으로 흘려보낸다.
    function flushPendingLpIncentive(bytes32 marketId) external returns (uint256 amount);

    /// @notice 마켓별 대기 중인(lpZap 미설정 기간의) LP 인센티브 자금(USDC, 6dec) — 투명성 대시보드.
    function pendingLpIncentiveUsdc(bytes32 marketId) external view returns (uint256);

    /// @notice 마켓별 누적 LP 인센티브 지급 총액(그로스, 6dec) — 투명성 대시보드.
    function totalLpIncentiveUsdc(bytes32 marketId) external view returns (uint256);

    /// @notice pool 주소 → marketId 역참조 (LpZap이 NFT 예치 시 마켓 판별용). 0=미등록 풀.
    function poolToMarketId(address pool) external view returns (bytes32);

    function gmxInfra() external view returns (GmxInfra memory);
    function usdc() external view returns (address);
    function paused() external view returns (bool);

    /// @notice 프로토콜 관리자 주소 (Ownable). settleGmxOrder 등 관리자 전용 복구 경로에서 사용.
    function owner() external view returns (address);
}
