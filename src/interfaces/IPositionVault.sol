// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {VaultState, GmxConfig, RiskParams, VaultSnapshot} from "../types/Types.sol";
import {IPriceOracle} from "./IPriceOracle.sol";
import {IGmxAdapter} from "./IGmxAdapter.sol";

/// @title IPositionVault — 사용자별 격리 Vault (docs/10)
interface IPositionVault {
    // ── 초기화 (factory가 clone 직후 호출, Initializable 가드) ──
    /// @param risk 자산별 리스크 곡선(maxLtv1x·buffer·maxLtvAtMaxLev·flatTier·maxLeverage). Litepaper v1.6.
    function initialize(
        address owner_,
        address factory_,
        IGmxAdapter gmx_,
        IPriceOracle oracle_,
        address usdc_,
        address rToken_,
        bytes32 marketId_,
        RiskParams calldata risk
    ) external;

    // ── 사용자 동작 (onlyOwner) ──
    function deposit(uint256 usdcAmount) external;
    /// @param isLong true=롱, false=숏
    function openPosition(uint8 leverage, bool isLong) external payable;
    /// @param triggerPrice8 진입 원하는 가격 (8-dec). 롱=이하 체결, 숏=이상 체결.
    function openLimitPosition(uint8 leverage, uint256 triggerPrice8, bool isLong) external payable;
    function mint(uint256 rBtcAmount) external; // LTV 한도 검증(레버리지 곡선)
    function repay(uint256 rBtcAmount) external; // rBTC burn → 부채 감소 (mint 역연산)
    function closePosition() external payable;

    // ── 조건부 청산 주문 (onlyOwner, Active 상태) ──
    function setTakeProfit(uint256 triggerPrice8) external payable;
    function setStopLoss(uint256 triggerPrice8) external payable;
    function cancelTakeProfit() external;
    function cancelStopLoss() external;

    // ── 청산 (public, 조건 충족 시) ──
    function liquidate() external payable;

    // ── RLT 상환 (public, 상환존 RLT<=ltv<LLTV) — redeemer가 rToken 제출, oracle가로 부채↓, 페널티 없음 ──
    function redeem(uint256 rTokenAmount) external;

    // ── Settling 타임아웃 복구 (public, docs/60 OQ-6) ──
    function cancelStuckOrder() external;

    // ── GMX 콜백 (onlyGmx) ──
    function afterOrderExecution(bytes32 orderKey) external;
    function afterOrderCancellation(bytes32 orderKey) external;

    // ── 조회 ──
    function owner() external view returns (address);
    function collateral() external view returns (uint256); // USDC 6-dec
    function debt() external view returns (uint256); // rToken 18-dec
    function state() external view returns (VaultState);
    /// @return USD 18-dec WAD (oracle 8-dec 기반 회계)
    function collateralValueUsdWad() external view returns (uint256);
    /// @return USD 18-dec WAD (debt × oracle 8-dec)
    function debtValueUsdWad() external view returns (uint256);
    function currentLTV() external view returns (uint256);   // bps (10000 = 100%)
    function lltvBps() external view returns (uint256);       // 청산 임계 LTV bps
    function healthFactor() external view returns (uint256);  // 18-dec WAD (1e18 = 1.0)
    function isRedeemable() external view returns (bool);     // RLT 상환존 여부
    function marketId() external view returns (bytes32);
    /// @notice 볼트 전체 상태 단일 스냅샷 (LTV·HF·GMX·리스크·대기주문 포함).
    /// @dev 필드별 decimals — VaultSnapshot struct 주석 참고.
    function vaultInfo() external view returns (VaultSnapshot memory);
}
