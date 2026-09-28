// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IRToken} from "../interfaces/IRToken.sol";
import {DebtSettler} from "./DebtSettler.sol";
import {Units} from "./Units.sol";
import {GmxExecutor} from "./GmxExecutor.sol";
import {GmxIntegrationReader} from "./GmxIntegrationReader.sol";
import {PositionStore, SettleCtx, VaultState, OrderKind, PendingOrder, GmxVaultStore, GmxVaultCtx} from "../types/Types.sol";

/// @title VaultSettle — PositionVault 정산 상태머신(외부 라이브러리, vault에서 delegatecall).
/// @notice PositionStore storage ref로 직접 vault 상태를 갱신. 로직은 PositionVault에서 동일 의미로 이전.
///         단일 storage 포인터만 넘겨 bytecode를 vault 밖으로 분리(EIP-170 대응).
/// @dev handleOrderExecuted/handleOrderCancelled(GMX 콜백 dispatch)도 이 라이브러리가 소유한다 —
///      "어떤 정산을 실행할지 결정"하는 상태머신의 진입점이라 개별 settleXxx와 분리하지 않고 같은 곳에 둔다.
///      (TP/SL 취소·Open 체결 확인처럼 엄밀히 "정산"은 아닌 분기도 있으나, _pos 상태를 갱신하는
///      동일한 콜백 경로이므로 여기 두는 편이 vault 쪽 중복·왕복 호출보다 응집도가 높다.)
library VaultSettle {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant REDEEM_FEE_BPS = 25; // 0.25%
    uint256 internal constant LIQ_PENALTY_BPS = 1_000; // 10%
    uint256 internal constant PENALTY_LIQ_SHARE_BPS = 6_000; // keeper 60%
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    error BadState();
    error BadKey();
    error ZeroPrice();
    error NotTimedOut();

    event Redeemed(
        address indexed vault, address indexed redeemer, uint256 rTokenAmount, uint256 usdcOut, uint256 feeUsdc
    );
    event CollateralWithdrawn(address indexed vault, uint256 amount);
    event CollateralWithdrawnFromPosition(address indexed vault, uint256 usdcAmount);
    event FeesSettled(address indexed vault, uint256 toTreasuryUsdc);
    event BadDebt(address indexed vault, uint256 shortfallUsdc);
    event PositionOpened(address indexed vault, bytes32 posKey);
    event PositionOpenFailed(address indexed vault, bytes32 orderKey);
    event CollateralDepositedToPosition(address indexed vault, uint256 usdcAmount);
    event Liquidated(address indexed vault, uint256 debtRepaidUsdc, uint256 refundUsdc, uint256 keeperBountyUsdc);

    // ── 내부 헬퍼 (vault 동작과 동일, lib 컨텍스트에서 재구현) ──

    function _notify(address factory, int256 delta) private {
        if (delta == 0) return;
        try IVaultFactory(factory).onCollateralChanged(delta) {} catch {}
    }

    function _resync(PositionStore storage pos, address factory, IERC20 usdc) private {
        uint256 prev = pos.collateral;
        uint256 bal = usdc.balanceOf(address(this));
        if (bal != prev) {
            pos.collateral = bal;
            _notify(factory, int256(bal) - int256(prev));
        }
    }

    function _clearKeys(PositionStore storage pos) private {
        pos.tpOrderKey = bytes32(0);
        pos.slOrderKey = bytes32(0);
        pos.slTriggerPrice8 = 0;
        pos.tpCancellingKey = bytes32(0);
        pos.slCancellingKey = bytes32(0);
    }

    function _clearPendingRedeem(PositionStore storage pos) private {
        pos.pendingRedeemer = address(0);
        pos.pendingRedeemAmt = 0;
        pos.pendingRedeemUsdcSnap = 0;
        delete pos.pending;
    }

    /// @dev vault _accrueBorrow와 동일 로직(재구현). settleRedeem 호출 전 필요.
    function _accrueBorrow(PositionStore storage pos, SettleCtx memory c) private {
        uint256 last = pos.lastAccrual;
        if (last != 0 && pos.debt > 0) {
            uint256 dt = block.timestamp - last;
            if (dt > 0) {
                uint256 debtValueUsdWad = Units.rTokenToUsdWad(pos.debt, IPriceOracle(c.oracle).getPrice());
                pos.accruedBorrowFeeUsdc +=
                    (Units.wadToUsdc(debtValueUsdWad) * _borrowAprBps(c) * dt) / (BPS * SECONDS_PER_YEAR);
            }
        }
        pos.lastAccrual = block.timestamp;
    }

    /// @dev 마켓별 borrow fee APR(bps) — factory.markets[].borrowAprBps live 조회. PositionVault._borrowAprBps와
    ///      동일 개념(재구현, EIP-170 대응으로 별도 storage 왕복 없이 c.factory/c.marketId만 사용).
    function _borrowAprBps(SettleCtx memory c) private view returns (uint16 bps) {
        (,,,,,,,,,, bps) = IVaultFactory(c.factory).markets(c.marketId);
    }

    function _mockPosKey(SettleCtx memory c) private view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), c.marketId, c.isLong));
    }

    function _clearSlTriggerIfIdle(PositionStore storage pos) private {
        if (pos.slOrderKey == bytes32(0) && pos.slCancellingKey == bytes32(0)) pos.slTriggerPrice8 = 0;
    }

    /// @dev TP/SL 취소 콜백(체결/취소 공통) 처리. true면 소비됨(dispatch 종료).
    function _handleConditionalCancel(PositionStore storage pos, bytes32 orderKey) private returns (bool) {
        if (
            orderKey != pos.tpOrderKey && orderKey != pos.tpCancellingKey && orderKey != pos.slOrderKey
                && orderKey != pos.slCancellingKey
        ) {
            return false;
        }
        if (orderKey == pos.tpOrderKey) pos.tpOrderKey = bytes32(0);
        if (orderKey == pos.tpCancellingKey) pos.tpCancellingKey = bytes32(0);
        if (orderKey == pos.slOrderKey) pos.slOrderKey = bytes32(0);
        if (orderKey == pos.slCancellingKey) pos.slCancellingKey = bytes32(0);
        _clearSlTriggerIfIdle(pos);
        return true;
    }

    // ── 정산 진입점 (vault dispatch에서 호출) ──

    /// @notice RLT redeem 정산. 호출 전 vault가 _accrueBorrow 완료 가정 (의미 보존).
    function settleRedeem(PositionStore storage pos, SettleCtx memory c) public {
        uint256 amt = pos.pendingRedeemAmt;
        address redeemer = pos.pendingRedeemer;
        if (amt == 0 || redeemer == address(0)) revert BadState();
        IERC20 usdc = IERC20(c.usdc);
        uint256 bal = usdc.balanceOf(address(this));
        uint256 snap = pos.pendingRedeemUsdcSnap;
        uint256 recovered = bal > snap ? bal - snap : 0;
        pos.debt -= amt;
        IRToken(c.rToken).burn(address(this), amt);
        _clearPendingRedeem(pos);
        (uint256 fee,) = DebtSettler.settleRedeemPayout(c.factory, usdc, redeemer, recovered, REDEEM_FEE_BPS);
        emit Redeemed(address(this), redeemer, amt, recovered, fee);
    }

    /// @notice redeem GMX 취소 시 escrow rToken 반환.
    function cancelPendingRedeem(PositionStore storage pos, address rToken) public {
        uint256 amt = pos.pendingRedeemAmt;
        address redeemer = pos.pendingRedeemer;
        _clearPendingRedeem(pos);
        if (amt > 0 && redeemer != address(0)) IERC20(rToken).safeTransfer(redeemer, amt);
    }

    /// @notice withdrawCollateral 정산 — 증가분만 owner에게 전송.
    function settleWithdrawCollateral(PositionStore storage pos, SettleCtx memory c) public {
        uint256 snap = pos.pendingWithdrawUsdcSnap;
        pos.pendingWithdrawUsdcSnap = 0;
        delete pos.pending;
        IERC20 usdc = IERC20(c.usdc);
        uint256 bal = usdc.balanceOf(address(this));
        uint256 received = bal > snap ? bal - snap : 0;
        if (received == 0) return;
        uint256 toOwner = received;
        if (toOwner > pos.collateral) toOwner = pos.collateral;
        if (toOwner > 0) {
            pos.collateral -= toOwner;
            usdc.safeTransfer(c.owner, toOwner);
            _notify(c.factory, -int256(toOwner));
            emit CollateralWithdrawnFromPosition(address(this), toOwner);
            emit CollateralWithdrawn(address(this), toOwner);
        }
    }

    /// @notice GMX 포지션 종료 후 vault USDC·상태 동기화. 부채 정산은 owner withdraw.
    function syncAfterGmxClose(PositionStore storage pos, address factory, IERC20 usdc) public {
        _resync(pos, factory, usdc);
        pos.posKey = bytes32(0);
        _clearKeys(pos);
        delete pos.pending;
        pos.state = VaultState.Empty;
        if (pos.debt == 0) pos.lastAccrual = 0;
    }

    /// @notice 부채·fee 정산 후 vault 리셋. owner withdraw 및 청산 콜백 공용.
    function settleDebtExit(PositionStore storage pos, SettleCtx memory c, bool applyPenalty, address keeper)
        public
        returns (uint256 toOwner, uint256 usdcDebtSpent, uint256 keeperBounty)
    {
        IERC20 usdc = IERC20(c.usdc);
        if (pos.debt > 0) {
            DebtSettler.ExitResult memory out = DebtSettler.settleExitWithDebt(
                c.owner,
                keeper,
                c.factory,
                c.marketId,
                IPriceOracle(c.oracle),
                usdc,
                IRToken(c.rToken),
                pos.debt,
                pos.accruedFeesUsdc,
                pos.accruedBorrowFeeUsdc,
                applyPenalty,
                LIQ_PENALTY_BPS,
                PENALTY_LIQ_SHARE_BPS
            );
            toOwner = out.refund;
            usdcDebtSpent = out.usdcDebtSpent;
            keeperBounty = out.keeperBounty;
            pos.debt = out.newDebt;
            emit FeesSettled(address(this), out.fees);
            if (out.badDebtShortfall > 0) emit BadDebt(address(this), out.badDebtShortfall);
        } else {
            DebtSettler.CloseResult memory out = DebtSettler.settleCloseNoDebt(
                c.owner, c.factory, c.marketId, usdc, pos.accruedFeesUsdc, pos.accruedBorrowFeeUsdc
            );
            toOwner = out.toOwner;
            emit FeesSettled(address(this), out.fees);
        }

        uint256 prevCollateral = pos.collateral;
        pos.collateral = 0;
        _notify(c.factory, -int256(prevCollateral));
        pos.accruedFeesUsdc = 0;
        pos.accruedBorrowFeeUsdc = 0;
        pos.lastAccrual = 0;
        pos.posKey = bytes32(0);
        _clearKeys(pos);
        pos.state = VaultState.Empty;
        delete pos.pending;
        pos.liquidator = address(0);
    }

    // ── GMX 콜백 dispatch (PositionVault._handleRyexOrderExecuted/Cancelled 이전, EIP-170 대응) ──

    /// @notice GMX 주문 체결 콜백 dispatch. TP/SL 취소·체결, open/deposit/close/redeem/withdrawCollateral/liquidate 분기.
    function handleOrderExecuted(PositionStore storage pos, GmxVaultStore storage gmxStore, SettleCtx memory c, bytes32 orderKey)
        external
    {
        // cancellingKey 주문이 취소보다 먼저 체결된 경우(레이스) — cancel-ack가 아니라 실제 close다.
        // 예전엔 early return만 해서 GMX는 닫혔는데 vault posKey/부채가 남는 버그가 있었음.
        if (orderKey == pos.tpCancellingKey || orderKey == pos.slCancellingKey) {
            pos.tpCancellingKey = bytes32(0);
            pos.slCancellingKey = bytes32(0);
            syncAfterGmxClose(pos, c.factory, IERC20(c.usdc));
            return;
        }
        if (orderKey == pos.tpOrderKey || orderKey == pos.slOrderKey) {
            syncAfterGmxClose(pos, c.factory, IERC20(c.usdc));
            return;
        }
        if (pos.pending.orderKey != orderKey) revert BadKey();
        OrderKind pkind = pos.pending.kind;
        if (pkind == OrderKind.Open || pkind == OrderKind.LimitOpen) {
            pos.posKey = _mockPosKey(c);
            pos.state = VaultState.Active;
            pos.lastAccrual = block.timestamp;
            delete pos.pending;
            emit PositionOpened(address(this), pos.posKey);
        } else if (pkind == OrderKind.DepositCollateral) {
            pos.state = VaultState.Active;
            delete pos.pending;
            emit CollateralDepositedToPosition(address(this), gmxStore.orders[orderKey].openCollateral);
        } else if (pkind == OrderKind.Close || pkind == OrderKind.LimitClose) {
            syncAfterGmxClose(pos, c.factory, IERC20(c.usdc));
        } else if (pkind == OrderKind.Redeem) {
            _accrueBorrow(pos, c);
            settleRedeem(pos, c);
        } else if (pkind == OrderKind.WithdrawCollateral) {
            settleWithdrawCollateral(pos, c);
        } else {
            (uint256 refund, uint256 usdcDebtSpent, uint256 keeperBounty) =
                settleDebtExit(pos, c, true, pos.liquidator);
            emit Liquidated(address(this), usdcDebtSpent, refund, keeperBounty);
        }
    }

    /// @notice GMX 주문 취소 콜백 dispatch.
    function handleOrderCancelled(PositionStore storage pos, SettleCtx memory c, bytes32 orderKey) external {
        if (_handleConditionalCancel(pos, orderKey)) return;
        if (pos.pending.orderKey != orderKey) revert BadKey();
        if (pos.pending.kind == OrderKind.Open || pos.pending.kind == OrderKind.LimitOpen) {
            if (pos.posKey == bytes32(0)) _resync(pos, c.factory, IERC20(c.usdc));
            pos.state = pos.posKey != bytes32(0) ? VaultState.Active : VaultState.Empty;
            delete pos.pending;
            emit PositionOpenFailed(address(this), orderKey);
        } else if (pos.pending.kind == OrderKind.DepositCollateral) {
            pos.state = VaultState.Active;
            delete pos.pending;
            emit PositionOpenFailed(address(this), orderKey);
        } else if (pos.pending.kind == OrderKind.Redeem) {
            cancelPendingRedeem(pos, c.rToken);
        } else if (pos.pending.kind == OrderKind.WithdrawCollateral) {
            pos.pendingWithdrawUsdcSnap = 0;
            pos.state = VaultState.Active;
            delete pos.pending;
        } else {
            pos.state = VaultState.Active;
            pos.liquidator = address(0);
            delete pos.pending;
        }
    }

    /// @notice 미체결 limit open/close 주문의 triggerPrice만 갱신(취소+재생성 없이 GMX updateOrder 사용).
    ///         cancelLimitOrder와 동일한 가드 + 실제 GMX 호출까지 여기서 처리 — vault 쪽 bytecode 절약(EIP-170).
    function updateLimitOrder(PositionStore storage pos, GmxVaultStore storage gmxStore, GmxVaultCtx memory ctx, uint256 newTriggerPrice8)
        external
    {
        if (newTriggerPrice8 == 0) revert ZeroPrice();
        requireLimitPending(pos);
        GmxExecutor.updateLimitOrder(gmxStore, ctx, pos.pending.orderKey, newTriggerPrice8);
    }

    /// @dev cancelLimitOrder/updateLimitOrder 공용 가드 — 대기 중인 limit open/close만 허용.
    function requireLimitPending(PositionStore storage pos) public view {
        bool limitOpen = pos.pending.kind == OrderKind.LimitOpen && pos.state == VaultState.SettlingOpen;
        bool limitClose = pos.pending.kind == OrderKind.LimitClose && pos.state == VaultState.SettlingLiquidate;
        if (!limitOpen && !limitClose) revert BadState();
    }

    /// @notice cancelStuckOrder 본체(EIP-170). mode: 0=noop, 1=vault가 GMX cancel 요청, 2=vault가 _completeRyexOrder.
    /// @dev GMX에 남아 있으면 cancel 요청만 지시. 이미 사라졌으면 settleGmxOrder 판별로 exec/cancel 확정.
    function recoverStuckOrder(
        PositionStore storage pos,
        GmxVaultStore storage gmxStore,
        GmxVaultCtx memory ctx,
        uint256 settlingTimeout
    ) external returns (bytes32 ryexKey, bytes32 gmxKey, bool isExec, uint8 kind, uint8 mode) {
        if (pos.pending.kind == OrderKind.None || pos.pending.orderKey == bytes32(0)) revert BadState();
        if (pos.pending.kind == OrderKind.LimitOpen || pos.pending.kind == OrderKind.LimitClose) revert BadState();
        if (block.timestamp <= pos.pending.createdAt + settlingTimeout) revert NotTimedOut();

        VaultState s = pos.state;
        bool okPending = (s == VaultState.Active
                && (pos.pending.kind == OrderKind.Redeem || pos.pending.kind == OrderKind.WithdrawCollateral))
            || s == VaultState.SettlingOpen || s == VaultState.SettlingLiquidate;
        if (!okPending) revert BadState();

        ryexKey = pos.pending.orderKey;
        gmxKey = gmxStore.orders[ryexKey].gmxKey;
        kind = gmxStore.orders[ryexKey].kind;

        if (gmxKey != bytes32(0) && GmxIntegrationReader.isOrderPending(ctx, gmxKey)) {
            return (ryexKey, gmxKey, false, kind, 1);
        }

        if (!gmxStore.orders[ryexKey].executed) {
            if (gmxKey != bytes32(0)) {
                (ryexKey, isExec, kind) = GmxExecutor.settleGmxOrderAndFinish(gmxStore, ctx, gmxKey);
            } else {
                GmxExecutor.cancelOrder(gmxStore, ryexKey, gmxStore.orders[ryexKey]);
                isExec = false;
            }
            return (ryexKey, gmxKey, isExec, kind, 2);
        }
        return (ryexKey, gmxKey, false, kind, 0);
    }
}
