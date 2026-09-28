// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {VaultState, RiskParams} from "../types/Types.sol";

/// @title IPositionVault — 사용자별 격리 Vault (docs/10)
interface IPositionVault {
    // ── 초기화 (factory가 clone 직후 호출, Initializable 가드) ──
    function initialize(
        address owner_,
        address factory_,
        address usdc_,
        address rToken_,
        bytes32 marketId_,
        bool isLong_,
        RiskParams calldata risk
    ) external;

    // ── 담보 (Router 전용) ──
    function deposit(address owner_, uint256 usdcAmount) external;
    /// @param triggerPrice8 0 = market open, else limit open (8 decimals)
    /// @param collateralUsdc 이번에 GMX로 보낼 담보(요청 수량). vault 가용 잔고 이하.
    function openPosition(uint8 leverage, uint256 triggerPrice8, bool isLong, uint256 collateralUsdc)
        external
        payable;
    function mint(uint256 rBtcAmount) external;
    function repay(uint256 rBtcAmount) external;
    function withdraw(uint256 usdcAmount) external;
    /// @param triggerPrice8 0 = market close, else limit close (8 decimals)
    function closePosition(uint256 triggerPrice8) external payable;
    /// @notice Active 포지션에 GMX 담보만 추가 (size 유지). vault idle USDC → MarketIncrease(size=0).
    function depositCollateral(uint256 usdcAmount) external payable;
    /// @notice Active 포지션에서 excess 담보만 회수 (size 유지). MarketDecrease(size=0).
    function withdrawCollateral(uint256 usdcAmount) external payable;
    /// @notice 미체결 limit open/close 취소
    function cancelLimitOrder() external;
    /// @notice 미체결 limit open/close 주문의 triggerPrice만 갱신 (사이즈·담보 불변)
    function updateLimitOrder(uint256 newTriggerPrice8) external payable;

    // ── 조건부 청산 주문 (onlyOwner, Active 상태) ──
    function setTakeProfit(uint256 triggerPrice8) external payable;
    function setStopLoss(uint256 triggerPrice8) external payable;
    function cancelTakeProfit() external;
    function cancelStopLoss() external;

    function liquidate() external payable;
    function redeem(uint256 rTokenAmount) external payable;
    function cancelStuckOrder() external;

    // ── GMX funding fee (2-step: accrued→claimable settle, claimable→owner claim) ──
    /// @notice accrued funding을 claimable로 전환(1단계). 누구나 호출 가능(keeper).
    function requestAccruedFundingSettle() external returns (bytes32 orderKey);
    /// @notice claimable funding fee(+affiliate reward)를 owner 지갑으로 직접 클레임.
    function harvestFunding() external returns (uint256 longAmount, uint256 shortAmount);

    // ── 조회 (기본 상태만; 파생 지표는 VaultLens) ──
    function owner() external view returns (address);
    function collateral() external view returns (uint256);
    function debt() external view returns (uint256);
    function state() external view returns (VaultState);
    function marketId() external view returns (bytes32);
    function accruedFeesUsdc() external view returns (uint256);
    function accruedBorrowFeeUsdc() external view returns (uint256);
}
