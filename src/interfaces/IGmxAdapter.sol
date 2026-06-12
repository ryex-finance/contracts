// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IGmxAdapter — Vault가 GMX를 보는 단일 진입점 (docs/50 §2)
/// @notice GmxV2Adapter(실제 GMX) 구현체. GMX 인코딩·키 계산·2-step 비동기를 이 경계가 흡수.
interface IGmxAdapter {
    // ── GMX 포지션 데이터 (조회) ─────────────────────────────────────────────────
    /// @dev 프론트 표시 예:
    ///      sizeInUsd        → formatUnits(v, 30)  // GMX 원본, 8dec 변환 없음
    ///      collateralAmount → formatUnits(v, 6)   // USDC
    ///      entryPrice8      → formatUnits(v, 8)   // mock만 유효; 실 GMX는 0
    struct GmxPositionData {
        bool    exists;           // 포지션이 실제로 열려 있는지 (sizeInUsd > 0)
        uint256 sizeInUsd;        // GMX 30-dec USD 명목 사이즈 (예: $10 → 10 × 10^30). passthrough.
        uint256 collateralAmount; // USDC 6-dec (예: 5 USDC → 5_000_000)
        uint256 entryPrice8;      // Chainlink 8-dec 진입가 (mock 회계). 실 GMX Reader 경로는 0.
    }

    // ── 마켓 오픈 ────────────────────────────────────────────────────────────────

    /// @notice 시장가 포지션 오픈 주문. exec fee = msg.value. 호출자 = Vault.
    /// @param isLong true=롱, false=숏
    function createOpenOrder(
        bytes32 marketId,
        uint256 collateralUsdc,
        uint256 indexPrice8,
        uint256 leverage,
        bool    isLong
    ) external payable returns (bytes32 orderKey);

    /// @notice 지정가(limit) 포지션 오픈 주문.
    ///         롱 limit: triggerPrice8 **이하**로 가격이 내려올 때 GMX keeper 체결 (buy-the-dip).
    ///         숏 limit: triggerPrice8 **이상**으로 가격이 올라올 때 GMX keeper 체결 (sell-the-rally).
    /// @param triggerPrice8 원하는 진입 가격 (oracle 8-dec 단위)
    /// @param isLong true=롱 limit buy, false=숏 limit sell
    function createLimitOrder(
        bytes32 marketId,
        uint256 collateralUsdc,
        uint256 triggerPrice8,
        uint256 leverage,
        bool    isLong
    ) external payable returns (bytes32 orderKey);

    // ── 포지션 종료 ──────────────────────────────────────────────────────────────

    /// @notice 포지션 전량 close(청산) 주문 생성.
    function createCloseOrder(bytes32 positionKey) external payable returns (bytes32 orderKey);

    /// @notice RLT 상환용 동기 부분청산. equity를 withdrawUsdc 만큼 줄이고 USDC를 Vault로 송금.
    function reducePosition(bytes32 positionKey, uint256 withdrawUsdc) external returns (uint256 paidUsdc);

    // ── 포지션 조회 ──────────────────────────────────────────────────────────────

    /// @notice 포지션 순가치(USD WAD). HF/LTV 계산 시 담보가치 출처.
    /// @return valueWad USD 18-dec (WAD). oracle 8-dec 기반 회계 — GMX 30-dec과 무관.
    function getPositionValueUsd(bytes32 positionKey) external view returns (uint256 valueWad);

    /// @notice account의 해당 마켓 포지션 키.
    function positionKey(address account, bytes32 marketId, bool isLong) external view returns (bytes32);

    /// @notice GMX 포지션 상태를 온체인에서 직접 조회해 반환 (passthrough).
    /// @dev sizeInUsd·collateralAmount는 GMX Reader 값을 **변환 없이** 그대로 반환.
    ///      entryPrice8은 실 GMX 경로에서 0 (Reader 미제공). RYex LTV는 oracle 8-dec 사용.
    function gmxPositionData(address vault, bytes32 marketId, bool isLong)
        external
        view
        returns (GmxPositionData memory);

    // ── 조건부 청산 (TP/SL) ──────────────────────────────────────────────────────

    /// @notice 익절(Take Profit) 주문 생성.
    ///         롱 TP: triggerPrice8 **이상**으로 가격이 오를 때 체결.
    ///         숏 TP: triggerPrice8 **이하**로 가격이 내릴 때 체결.
    function createTakeProfit(bytes32 positionKey, uint256 triggerPrice8)
        external payable returns (bytes32 orderKey);

    /// @notice 손절(Stop Loss) 주문 생성.
    ///         롱 SL: triggerPrice8 **이하**로 가격이 내릴 때 체결.
    ///         숏 SL: triggerPrice8 **이상**으로 가격이 오를 때 체결.
    function createStopLoss(bytes32 positionKey, uint256 triggerPrice8)
        external payable returns (bytes32 orderKey);

    // ── 지정가 취소 ──────────────────────────────────────────────────────────────

    /// @notice 미체결 limit open 주문을 GMX에 취소 요청한다.
    function requestCancellation(bytes32 ryexOrderKey) external;
}
