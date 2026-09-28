// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IGmxExchangeRouter} from "../interfaces/IGmxExchangeRouter.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {GmxConstants} from "./GmxConstants.sol";
import {GmxOrderBuilder} from "./GmxOrderBuilder.sol";
import {GmxIntegrationReader} from "./GmxIntegrationReader.sol";
import {Units} from "./Units.sol";
import {GmxInfra, GmxOrder, GmxVaultCtx, GmxVaultStore} from "../types/Types.sol";

/// @title GmxExecutor — external library for per-vault GMX order + settlement (bytecode offload).
library GmxExecutor {
    error GmxZeroCollateral();
    error GmxBadLeverage();
    error GmxNoPosition();
    error GmxZeroTrigger();
    error GmxZeroRedeem();
    error GmxExceedsEquity();
    error GmxAlreadyExecuted();
    error GmxUnknownKey();
    error GmxOrderPending();
    error GmxBadOrder();
    error GmxUnderfundedEth();

    uint8 internal constant KIND_DEPOSIT_COLLATERAL = 6;
    uint8 internal constant KIND_WITHDRAW_COLLATERAL = 7;
    /// @dev GMX UI Settle accrued funding — MarketDecrease(size=0, collateral=1 wei).
    uint8 internal constant KIND_SETTLE_FUNDING = GmxConstants.KIND_SETTLE_FUNDING;

    function createOpenOrder(
        GmxVaultStore storage s,
        GmxVaultCtx memory ctx,
        uint256 collateralUsdc,
        uint256 indexPrice8,
        uint256 leverage_,
        uint256 triggerPrice8
    ) external returns (bytes32 orderKey, bytes32 gmxKey, uint8 kind) {
        if (collateralUsdc == 0) revert GmxZeroCollateral();
        if (leverage_ < 1) revert GmxBadLeverage();
        kind = 1;

        uint256 sizeUsd = collateralUsdc * 1e24 * leverage_;
        address mkt = GmxIntegrationReader.gmxMarket(ctx);
        gmxKey = bytes32(0);
        if (mkt != address(0)) {
            GmxInfra memory infra = GmxIntegrationReader.gmxInfra(ctx);
            uint8 orderType;
            uint256 triggerPrice30;
            uint256 acceptable;
            if (triggerPrice8 == 0) {
                orderType = GmxConstants.ORDER_MARKET_INCREASE;
                triggerPrice30 = 0;
                acceptable = acceptableMarketOpen(ctx.isLong, infra.acceptablePriceMax, infra.acceptablePriceMin);
            } else {
                orderType = GmxConstants.ORDER_LIMIT_INCREASE;
                triggerPrice30 = Units.price8ToGmx30(triggerPrice8, indexTokenDecimals(ctx));
                acceptable = acceptableLimitOpen(ctx.isLong, triggerPrice30);
            }
            gmxKey = submitOrder(ctx, mkt, orderType, collateralUsdc, sizeUsd, triggerPrice30, acceptable);
        }

        bool increasing = s.mockActive;
        uint256 gmxSizeBefore;
        if (mkt != address(0) && GmxIntegrationReader.gmxInfra(ctx).reader != address(0)) {
            gmxSizeBefore = GmxIntegrationReader.vaultSizeUsd(ctx, mkt);
        } else if (increasing) {
            gmxSizeBefore = s.mockSizeUsd;
        }

        if (increasing) {
            uint256 oldCol = s.mockCollateral;
            s.mockCollateral = oldCol + collateralUsdc;
            s.mockSizeUsd += sizeUsd;
            if (indexPrice8 > 0) {
                if (s.mockEntryPrice8 > 0 && oldCol > 0) {
                    s.mockEntryPrice8 = (s.mockEntryPrice8 * oldCol + indexPrice8 * collateralUsdc) / (oldCol + collateralUsdc);
                } else {
                    s.mockEntryPrice8 = indexPrice8;
                }
            }
        } else {
            s.mockCollateral = collateralUsdc;
            s.mockEntryPrice8 = indexPrice8;
            s.mockSizeUsd = sizeUsd;
            s.mockActive = false;
        }

        orderKey = newOrderKey(s, ctx);
        s.orders[orderKey] = GmxOrder({
            kind: 1,
            executed: false,
            redeemUsdc: 0,
            usdcSnap: 0,
            isIncrease: increasing,
            openCollateral: collateralUsdc,
            openSizeUsd: sizeUsd,
            gmxSizeBefore: gmxSizeBefore,
            gmxKey: gmxKey
        });
        if (gmxKey != bytes32(0)) s.gmxKeyToRyexKey[gmxKey] = orderKey;
    }

    function createCloseOrder(GmxVaultStore storage s, GmxVaultCtx memory ctx, uint256 triggerPrice8)
        external
        returns (bytes32 orderKey, bytes32 gmxKey, uint8 kind)
    {
        if (!s.mockActive) revert GmxNoPosition();
        kind = triggerPrice8 == 0 ? 2 : 5;
        address mkt = GmxIntegrationReader.gmxMarket(ctx);
        uint256 gmxSizeBefore;
        if (mkt != address(0) && GmxIntegrationReader.gmxInfra(ctx).reader != address(0)) {
            gmxSizeBefore = GmxIntegrationReader.vaultSizeUsd(ctx, mkt);
        } else {
            gmxSizeBefore = s.mockSizeUsd;
        }
        gmxKey = bytes32(0);
        if (mkt != address(0)) {
            GmxInfra memory infra = GmxIntegrationReader.gmxInfra(ctx);
            if (triggerPrice8 == 0) {
                uint256 acceptable = acceptableMarketClose(ctx.isLong, infra.acceptablePriceMax, infra.acceptablePriceMin);
                gmxKey = submitOrder(ctx, mkt, GmxConstants.ORDER_MARKET_DECREASE, 0, s.mockSizeUsd, 0, acceptable);
            } else {
                uint256 triggerPrice30 = Units.price8ToGmx30(triggerPrice8, indexTokenDecimals(ctx));
                uint256 acceptable = acceptableConditionalClose(ctx.isLong, triggerPrice30);
                gmxKey = submitOrder(ctx, mkt, GmxConstants.ORDER_LIMIT_DECREASE, 0, s.mockSizeUsd, triggerPrice30, acceptable);
            }
        }
        orderKey = newOrderKey(s, ctx);
        s.orders[orderKey] = GmxOrder(kind, false, 0, 0, false, 0, 0, gmxSizeBefore, gmxKey);
        if (gmxKey != bytes32(0)) s.gmxKeyToRyexKey[gmxKey] = orderKey;
    }

    function createConditionalDecrease(GmxVaultStore storage s, GmxVaultCtx memory ctx, uint256 triggerPrice8, bool isTakeProfit)
        external
        returns (bytes32 orderKey, bytes32 gmxKey, uint8 kind)
    {
        if (triggerPrice8 == 0) revert GmxZeroTrigger();
        if (!s.mockActive) revert GmxNoPosition();
        kind = 3;
        address mkt = GmxIntegrationReader.gmxMarket(ctx);
        uint256 gmxSizeBefore;
        if (mkt != address(0) && GmxIntegrationReader.gmxInfra(ctx).reader != address(0)) {
            gmxSizeBefore = GmxIntegrationReader.vaultSizeUsd(ctx, mkt);
        } else {
            gmxSizeBefore = s.mockSizeUsd;
        }
        gmxKey = bytes32(0);
        if (mkt != address(0)) {
            uint8 orderType = isTakeProfit ? GmxConstants.ORDER_LIMIT_DECREASE : GmxConstants.ORDER_STOP_LOSS;
            uint256 triggerPrice30 = Units.price8ToGmx30(triggerPrice8, indexTokenDecimals(ctx));
            uint256 acceptable = acceptableConditionalClose(ctx.isLong, triggerPrice30);
            gmxKey = submitOrder(ctx, mkt, orderType, 0, s.mockSizeUsd, triggerPrice30, acceptable);
        }
        orderKey = newOrderKey(s, ctx);
        s.orders[orderKey] = GmxOrder(3, false, 0, 0, false, 0, 0, gmxSizeBefore, gmxKey);
        if (gmxKey != bytes32(0)) s.gmxKeyToRyexKey[gmxKey] = orderKey;
    }

    /// @notice GMX MarketIncrease — initialCollateralDeltaAmount만, sizeDeltaUsd=0 (담보만 추가).
    function createDepositCollateralOrder(GmxVaultStore storage s, GmxVaultCtx memory ctx, uint256 collateralUsdc)
        external
        returns (bytes32 orderKey, bytes32 gmxKey, uint8 kind, bool instant)
    {
        if (!s.mockActive) revert GmxNoPosition();
        if (collateralUsdc == 0) revert GmxZeroCollateral();
        kind = KIND_DEPOSIT_COLLATERAL;
        address mkt = GmxIntegrationReader.gmxMarket(ctx);
        gmxKey = bytes32(0);
        if (mkt != address(0)) {
            GmxInfra memory infra = GmxIntegrationReader.gmxInfra(ctx);
            uint256 acceptable = acceptableMarketOpen(ctx.isLong, infra.acceptablePriceMax, infra.acceptablePriceMin);
            gmxKey = submitOrder(ctx, mkt, GmxConstants.ORDER_MARKET_INCREASE, collateralUsdc, 0, 0, acceptable);
        }
        orderKey = newOrderKey(s, ctx);
        // usdcSnap = 주문 제출 후 vault 잔고(담보는 이미 OrderVault로 이동). cancel 시 환불되면 snap+collateral로 복귀.
        uint256 usdcSnap = IERC20Balance(ctx.usdc, ctx.vault);
        s.orders[orderKey] = GmxOrder({
            kind: KIND_DEPOSIT_COLLATERAL,
            executed: false,
            redeemUsdc: 0,
            usdcSnap: usdcSnap,
            isIncrease: false,
            openCollateral: collateralUsdc,
            openSizeUsd: 0,
            gmxSizeBefore: 0,
            gmxKey: gmxKey
        });
        if (gmxKey != bytes32(0)) s.gmxKeyToRyexKey[gmxKey] = orderKey;
        instant = false;
        if (gmxKey == bytes32(0)) {
            s.orders[orderKey].executed = true;
            s.mockCollateral += collateralUsdc;
            instant = true;
        }
    }

    /// @notice GMX MarketDecrease — sizeDeltaUsd=0, initialCollateralDeltaAmount만 (excess 담보 회수).
    function createWithdrawCollateralOrder(GmxVaultStore storage s, GmxVaultCtx memory ctx, uint256 withdrawUsdc)
        external
        returns (bytes32 orderKey, bytes32 gmxKey, uint8 kind, bool instant)
    {
        if (!s.mockActive) revert GmxNoPosition();
        if (withdrawUsdc == 0) revert GmxZeroRedeem();
        if (withdrawUsdc > s.mockCollateral) revert GmxExceedsEquity();
        kind = KIND_WITHDRAW_COLLATERAL;
        uint256 usdcSnap = IERC20Balance(ctx.usdc, ctx.vault);
        address mkt = GmxIntegrationReader.gmxMarket(ctx);
        gmxKey = bytes32(0);
        if (mkt != address(0)) {
            GmxInfra memory infra = GmxIntegrationReader.gmxInfra(ctx);
            uint256 acceptable = acceptableMarketClose(ctx.isLong, infra.acceptablePriceMax, infra.acceptablePriceMin);
            gmxKey = submitOrder(ctx, mkt, GmxConstants.ORDER_MARKET_DECREASE, withdrawUsdc, 0, 0, acceptable);
        }
        orderKey = newOrderKey(s, ctx);
        s.orders[orderKey] = GmxOrder({
            kind: KIND_WITHDRAW_COLLATERAL,
            executed: false,
            redeemUsdc: withdrawUsdc,
            usdcSnap: usdcSnap,
            isIncrease: false,
            openCollateral: 0,
            openSizeUsd: 0,
            gmxSizeBefore: 0,
            gmxKey: gmxKey
        });
        if (gmxKey != bytes32(0)) s.gmxKeyToRyexKey[gmxKey] = orderKey;
        instant = false;
        if (gmxKey == bytes32(0)) {
            s.orders[orderKey].executed = true;
            fillWithdrawCollateralOrder(s, s.orders[orderKey]);
            instant = true;
        }
    }

    function createRedeemOrder(GmxVaultStore storage s, GmxVaultCtx memory ctx, uint256 withdrawUsdc)
        external
        returns (bytes32 orderKey, bytes32 gmxKey, uint8 kind, uint256 paidUsdc, bool instant)
    {
        if (!s.mockActive) revert GmxNoPosition();
        if (withdrawUsdc == 0) revert GmxZeroRedeem();
        kind = 4;
        uint256 equityUsdc = Units.wadToUsdc(GmxIntegrationReader._ledgerEquityUsdWad(s, ctx));
        if (equityUsdc == 0 || withdrawUsdc > equityUsdc) revert GmxExceedsEquity();

        uint256 sizeDelta = (s.mockSizeUsd * withdrawUsdc) / equityUsdc;
        if (sizeDelta == 0) sizeDelta = 1;
        if (sizeDelta > s.mockSizeUsd) sizeDelta = s.mockSizeUsd;

        uint256 collatDelta = (s.mockCollateral * withdrawUsdc) / equityUsdc;
        if (collatDelta == 0) collatDelta = 1;
        if (collatDelta > s.mockCollateral) collatDelta = s.mockCollateral;

        uint256 usdcSnap = IERC20Balance(ctx.usdc, ctx.vault);
        // settleGmxOrder cancel/exec 판별용 — 체결 시 size가 줄어든다.
        uint256 gmxSizeBefore = s.mockSizeUsd;
        address mkt = GmxIntegrationReader.gmxMarket(ctx);
        gmxKey = bytes32(0);
        if (mkt != address(0)) {
            GmxInfra memory infra = GmxIntegrationReader.gmxInfra(ctx);
            gmxSizeBefore = GmxIntegrationReader.vaultSizeUsd(ctx, mkt);
            uint256 acceptable = acceptableMarketClose(ctx.isLong, infra.acceptablePriceMax, infra.acceptablePriceMin);
            gmxKey = submitOrder(ctx, mkt, GmxConstants.ORDER_MARKET_DECREASE, collatDelta, sizeDelta, 0, acceptable);
        }

        orderKey = newOrderKey(s, ctx);
        s.orders[orderKey] = GmxOrder(4, false, withdrawUsdc, usdcSnap, false, 0, 0, gmxSizeBefore, gmxKey);
        if (gmxKey != bytes32(0)) s.gmxKeyToRyexKey[gmxKey] = orderKey;

        paidUsdc = 0;
        instant = false;
        if (gmxKey == bytes32(0)) {
            s.orders[orderKey].executed = true;
            fillRedeemOrder(s, ctx, s.orders[orderKey]);
            instant = true;
        }
    }

    /// @notice GMX accrued funding settle — MarketDecrease(sizeDeltaUsd=0, collateralDelta=1 wei).
    /// @dev GMX UI Settle과 동일: 포지션을 터치해 accrued → CLAIMABLE_FUNDING_AMOUNT로 이동. 이후 claimFundingFees 가능.
    ///      keeper 비동기 체결이므로 같은 tx의 claim은 기존 claimable만 수거(신규 accrued는 체결 후 다음 harvest).
    function createSettleFundingOrder(GmxVaultStore storage s, GmxVaultCtx memory ctx)
        external
        returns (bytes32 orderKey, bytes32 gmxKey, bool instant)
    {
        if (!s.mockActive) revert GmxNoPosition();
        if (s.pendingFundingSettleRyexKey != bytes32(0)) {
            GmxOrder storage pending = s.orders[s.pendingFundingSettleRyexKey];
            if (!pending.executed) revert GmxOrderPending();
        }
        address mkt = GmxIntegrationReader.gmxMarket(ctx);
        gmxKey = bytes32(0);
        if (mkt != address(0)) {
            GmxInfra memory infra = GmxIntegrationReader.gmxInfra(ctx);
            uint256 acceptable = acceptableMarketClose(ctx.isLong, infra.acceptablePriceMax, infra.acceptablePriceMin);
            // collateralDelta=1 wei — GMX interface SettleAccruedFundingFeeModal 과 동일 패턴.
            gmxKey = submitOrder(ctx, mkt, GmxConstants.ORDER_MARKET_DECREASE, 1, 0, 0, acceptable);
        }
        orderKey = newOrderKey(s, ctx);
        s.orders[orderKey] = GmxOrder({
            kind: KIND_SETTLE_FUNDING,
            executed: false,
            redeemUsdc: 0,
            usdcSnap: 0,
            isIncrease: false,
            openCollateral: 0,
            openSizeUsd: 0,
            gmxSizeBefore: 0,
            gmxKey: gmxKey
        });
        s.pendingFundingSettleRyexKey = orderKey;
        if (gmxKey != bytes32(0)) s.gmxKeyToRyexKey[gmxKey] = orderKey;
        instant = false;
        if (gmxKey == bytes32(0)) {
            executeOrder(s, ctx, orderKey, s.orders[orderKey]);
            instant = true;
        }
    }

    function settleGmxOrder(GmxVaultStore storage s, GmxVaultCtx memory ctx, bytes32 gmxKey) public returns (bool isExec) {
        bytes32 ryexKey = s.gmxKeyToRyexKey[gmxKey];
        if (ryexKey == bytes32(0)) revert GmxUnknownKey();
        GmxOrder storage o = s.orders[ryexKey];
        if (o.executed) revert GmxBadOrder();
        if (GmxIntegrationReader.isOrderPending(ctx, gmxKey)) revert GmxOrderPending();

        address mkt = GmxIntegrationReader.gmxMarket(ctx);
        uint256 sizeNow;
        if (mkt != address(0) && GmxIntegrationReader.gmxInfra(ctx).reader != address(0)) {
            sizeNow = GmxIntegrationReader.vaultSizeUsd(ctx, mkt);
        } else {
            sizeNow = s.mockSizeUsd;
        }
        uint256 bal = IERC20Balance(ctx.usdc, ctx.vault);
        if (o.kind == 1) {
            // Limit/Market open(increase)
            isExec = sizeNow > o.gmxSizeBefore;
        } else if (o.kind == 4) {
            // Redeem decrease — size 감소 또는 vault USDC 유입
            isExec = (o.gmxSizeBefore > 0 && sizeNow < o.gmxSizeBefore) || (bal > o.usdcSnap);
        } else if (o.kind == KIND_DEPOSIT_COLLATERAL) {
            // 담보는 생성 시 이미 OrderVault로 이동. cancel이면 vault로 환불(≥ snap+openCollateral),
            // exec면 포지션에 남아 vault 잔고는 snap 근처.
            isExec = o.openCollateral == 0 ? false : bal < o.usdcSnap + o.openCollateral;
        } else if (o.kind == KIND_WITHDRAW_COLLATERAL) {
            isExec = bal > o.usdcSnap;
        } else if (o.kind == KIND_SETTLE_FUNDING) {
            // size 불변·잔고 단서로 판별 불가. 잘못된 exec(mockCollateral dust)보다 cancel이 안전.
            isExec = false;
        } else if (o.gmxSizeBefore > 0) {
            // TP/SL/close/liquidate 등 decrease
            isExec = sizeNow < o.gmxSizeBefore;
        } else {
            isExec = !GmxIntegrationReader.positionExists(ctx);
        }
        if (isExec) executeOrder(s, ctx, ryexKey, o);
        else cancelOrder(s, ryexKey, o);
        return isExec;
    }

    function settleCallback(GmxVaultStore storage s, GmxVaultCtx memory ctx, bytes32 gmxKey, bool isExecution)
        public
        returns (bool handled)
    {
        bytes32 ryexKey = s.gmxKeyToRyexKey[gmxKey];
        if (ryexKey == bytes32(0)) return false;
        GmxOrder storage o = s.orders[ryexKey];
        if (o.executed) return false;
        if (isExecution) executeOrder(s, ctx, ryexKey, o);
        else cancelOrder(s, ryexKey, o);
        return true;
    }

    function executeOrder(GmxVaultStore storage s, GmxVaultCtx memory ctx, bytes32 ryexKey, GmxOrder storage o) public {
        o.executed = true;
        if (o.kind == 1) s.mockActive = true;
        else if (o.kind == KIND_DEPOSIT_COLLATERAL) s.mockCollateral += o.openCollateral;
        else if (o.kind == 4) fillRedeemOrder(s, ctx, o);
        else if (o.kind == KIND_WITHDRAW_COLLATERAL) fillWithdrawCollateralOrder(s, o);
        else if (o.kind == KIND_SETTLE_FUNDING) {
            if (s.mockCollateral > 0) s.mockCollateral -= 1; // 1 wei dust touch
            s.pendingFundingSettleRyexKey = bytes32(0);
        } else s.mockActive = false;
    }

    function cancelOrder(GmxVaultStore storage s, bytes32 ryexKey, GmxOrder storage o) public {
        o.executed = true;
        if (o.kind == KIND_SETTLE_FUNDING) {
            s.pendingFundingSettleRyexKey = bytes32(0);
            return;
        }
        if (o.kind == 1) {
            if (o.isIncrease) {
                if (s.mockCollateral >= o.openCollateral) s.mockCollateral -= o.openCollateral;
                if (s.mockSizeUsd >= o.openSizeUsd) s.mockSizeUsd -= o.openSizeUsd;
            } else {
                s.mockCollateral = 0;
                s.mockEntryPrice8 = 0;
                s.mockSizeUsd = 0;
                s.mockActive = false;
            }
        }
    }

    /// @notice mock 즉시 취소 또는 GMX router 취소 요청. instant=true면 vault가 정산 콜백을 직접 호출.
    function requestCancellation(GmxVaultStore storage s, GmxVaultCtx memory ctx, bytes32 ryexOrderKey)
        external
        returns (bool instant, uint8 kind)
    {
        GmxOrder storage o = s.orders[ryexOrderKey];
        if (o.executed) revert GmxAlreadyExecuted();
        kind = o.kind;
        if (o.gmxKey == bytes32(0)) {
            cancelOrder(s, ryexOrderKey, o);
            return (true, kind);
        }
        GmxInfra memory infra = GmxIntegrationReader.gmxInfra(ctx);
        IGmxExchangeRouter(infra.exchangeRouter).cancelOrder(o.gmxKey);
        return (false, kind);
    }

    /// @notice GMX callback 정산. handled=false면 no-op.
    function finishSettlement(GmxVaultStore storage s, GmxVaultCtx memory ctx, bytes32 gmxKey, bool isExecution)
        external
        returns (bytes32 ryexKey, bool isExec, uint8 kind, bool handled)
    {
        if (!settleCallback(s, ctx, gmxKey, isExecution)) return (bytes32(0), false, 0, false);
        ryexKey = s.gmxKeyToRyexKey[gmxKey];
        kind = s.orders[ryexKey].kind;
        return (ryexKey, isExecution, kind, true);
    }

    /// @dev settleGmxOrder 전용 — pending 여부·포지션 존재로 exec/cancel 판별.
    function settleGmxOrderAndFinish(GmxVaultStore storage s, GmxVaultCtx memory ctx, bytes32 gmxKey)
        external
        returns (bytes32 ryexKey, bool isExec, uint8 kind)
    {
        isExec = settleGmxOrder(s, ctx, gmxKey);
        ryexKey = s.gmxKeyToRyexKey[gmxKey];
        kind = s.orders[ryexKey].kind;
    }

    function fillWithdrawCollateralOrder(GmxVaultStore storage s, GmxOrder storage o) internal {
        uint256 amt = o.redeemUsdc;
        if (amt > s.mockCollateral) amt = s.mockCollateral;
        if (amt > 0) s.mockCollateral -= amt;
    }

    function fillRedeemOrder(GmxVaultStore storage s, GmxVaultCtx memory ctx, GmxOrder storage o) internal returns (uint256 paid) {
        uint256 redeemUsdc = o.redeemUsdc;
        uint256 equityUsdc = Units.wadToUsdc(GmxIntegrationReader._ledgerEquityUsdWad(s, ctx));
        if (equityUsdc > 0 && redeemUsdc > 0) {
            uint256 sizeReduce = (s.mockSizeUsd * redeemUsdc) / equityUsdc;
            if (sizeReduce > s.mockSizeUsd) sizeReduce = s.mockSizeUsd;
            if (sizeReduce > 0) s.mockSizeUsd -= sizeReduce;
            uint256 collRed = (s.mockCollateral * redeemUsdc) / equityUsdc;
            if (collRed > s.mockCollateral) collRed = s.mockCollateral;
            if (collRed > 0) s.mockCollateral -= collRed;
        }
        uint256 bal = IERC20Balance(ctx.usdc, ctx.vault);
        paid = bal > o.usdcSnap ? bal - o.usdcSnap : 0;
        if (paid == 0 && o.gmxKey == bytes32(0)) {
            paid = redeemUsdc > bal ? bal : redeemUsdc;
        }
    }

    /// @notice 미체결 limit open/close 주문의 triggerPrice만 갱신 (사이즈·담보는 그대로). GMX `updateOrder` 호출.
    /// @dev mock-only(gmxKey==0) 주문은 GMX에 없으므로 대상 아님 — cancelLimitOrder 후 재생성해야 함.
    function updateLimitOrder(GmxVaultStore storage s, GmxVaultCtx memory ctx, bytes32 ryexOrderKey, uint256 newTriggerPrice8)
        external
    {
        if (newTriggerPrice8 == 0) revert GmxZeroTrigger();
        GmxOrder storage o = s.orders[ryexOrderKey];
        if (o.executed) revert GmxAlreadyExecuted();
        if (o.gmxKey == bytes32(0)) revert GmxBadOrder();

        uint256 triggerPrice30 = Units.price8ToGmx30(newTriggerPrice8, indexTokenDecimals(ctx));
        uint256 sizeDeltaUsd;
        uint256 acceptable;
        if (o.kind == 1) {
            // LimitOpen(increase) — 생성 시 저장된 사이즈 그대로 유지.
            sizeDeltaUsd = o.openSizeUsd;
            acceptable = acceptableLimitOpen(ctx.isLong, triggerPrice30);
        } else if (o.kind == 5) {
            // LimitClose(decrease) — 전량 청산이므로 현재 포지션 사이즈 기준.
            sizeDeltaUsd = s.mockSizeUsd;
            acceptable = acceptableConditionalClose(ctx.isLong, triggerPrice30);
        } else {
            revert GmxBadOrder();
        }

        GmxInfra memory infra = GmxIntegrationReader.gmxInfra(ctx);
        IGmxExchangeRouter(infra.exchangeRouter).updateOrder(
            o.gmxKey, sizeDeltaUsd, acceptable, triggerPrice30, 0, 0, false
        );
    }

    /// @dev GmxPriceOracle.tokenDecimals(); 없으면 ETH(18) 가정.
    function indexTokenDecimals(GmxVaultCtx memory ctx) internal view returns (uint8) {
        (bool ok, bytes memory ret) = ctx.oracle.staticcall(abi.encodeWithSignature("tokenDecimals()"));
        if (ok && ret.length >= 32) {
            uint256 d = abi.decode(ret, (uint256));
            if (d > 0 && d <= 18) return uint8(d);
        }
        return 18;
    }

    function acceptableMarketOpen(bool isLong, uint256 max_, uint256 min_) internal pure returns (uint256) {
        return isLong ? max_ : min_;
    }

    function acceptableMarketClose(bool isLong, uint256 max_, uint256 min_) internal pure returns (uint256) {
        return isLong ? min_ : max_;
    }

    function acceptableLimitOpen(bool isLong, uint256 triggerPrice30) internal pure returns (uint256) {
        if (isLong) {
            return triggerPrice30 * (10_000 + GmxConstants.LIMIT_SLIPPAGE_BPS) / 10_000;
        }
        return triggerPrice30 * (10_000 - GmxConstants.LIMIT_SLIPPAGE_BPS) / 10_000;
    }

    function acceptableConditionalClose(bool isLong, uint256 triggerPrice30) internal pure returns (uint256) {
        if (isLong) {
            return triggerPrice30 * (10_000 - GmxConstants.LIMIT_SLIPPAGE_BPS) / 10_000;
        }
        return triggerPrice30 * (10_000 + GmxConstants.LIMIT_SLIPPAGE_BPS) / 10_000;
    }

    function submitOrder(
        GmxVaultCtx memory ctx,
        address gmxMarket,
        uint8 orderType,
        uint256 collatAmount,
        uint256 sizeUsd,
        uint256 triggerPrice30,
        uint256 acceptablePrice
    ) internal returns (bytes32 gmxKey) {
        GmxInfra memory infra = GmxIntegrationReader.gmxInfra(ctx);
        if (ctx.vault.balance < infra.execFee) revert GmxUnderfundedEth();
        gmxKey = GmxOrderBuilder.createOrder(
            IGmxExchangeRouter(infra.exchangeRouter),
            infra.orderVault,
            ctx.vault,
            ctx.usdc,
            gmxMarket,
            orderType,
            collatAmount,
            sizeUsd,
            triggerPrice30,
            acceptablePrice,
            ctx.isLong,
            infra.execFee
        );
    }

    function newOrderKey(GmxVaultStore storage s, GmxVaultCtx memory ctx) internal returns (bytes32 k) {
        k = keccak256(abi.encodePacked(ctx.vault, s.orderNonce, block.number));
        s.orderNonce++;
    }

    function IERC20Balance(address token, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
