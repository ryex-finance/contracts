// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IGmxOrderCallbackReceiver} from "./interfaces/IGmxOrderCallbackReceiver.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {GmxExecutor} from "./libraries/GmxExecutor.sol";
import {GmxIntegrationReader} from "./libraries/GmxIntegrationReader.sol";
import {GmxConstants} from "./libraries/GmxConstants.sol";
import {GmxOrder, GmxPositionData, GmxVaultCtx, GmxVaultStore} from "./types/Types.sol";

/// @title GmxIntegrationBase — per-vault GMX v2 account (GmxExecutor mutate, GmxIntegrationReader read).
abstract contract GmxIntegrationBase is IGmxOrderCallbackReceiver, ReentrancyGuard {
    GmxVaultStore internal _gmxStore;

    address public factory;
    IERC20 public usdc;
    bytes32 internal _marketId;
    bool public isLong;
    uint8 public leverage;

    event GmxOrderCreated(bytes32 indexed orderKey, uint8 kind, bytes32 gmxKey);
    event GmxOrderExecuted(bytes32 indexed orderKey, bytes32 gmxKey);
    event GmxOrderCancelled(bytes32 indexed orderKey, bytes32 gmxKey);
    event GmxOrderFrozen(bytes32 indexed gmxKey);

    function _onRyexOrderExecuted(bytes32 orderKey, uint8 kind) internal virtual;
    function _onRyexOrderCancelled(bytes32 orderKey, uint8 kind) internal virtual;

    /// @dev factory markets[marketId].oracle — vault별 저장·동기화 없음. 경량 게터로 전체 Market 디코드 회피.
    function _oracle() internal view returns (IPriceOracle) {
        return IPriceOracle(IVaultFactory(factory).marketOracle(_marketId));
    }

    /// @notice 마켓 oracle (VaultFactory 레지스트리 참조). setMarketOracle 즉시 반영.
    function oracle() public view virtual returns (IPriceOracle) {
        return _oracle();
    }

    function _gmxCtx() internal view returns (GmxVaultCtx memory) {
        return GmxVaultCtx({
            vault: address(this),
            factory: factory,
            oracle: address(_oracle()),
            usdc: address(usdc),
            marketId: _marketId,
            isLong: isLong,
            leverage: leverage
        });
    }

    function _mockPosKey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), _marketId, isLong));
    }

    function _gmxPositionValueUsdWad() internal view returns (uint256) {
        return GmxIntegrationReader.ledgerEquityUsdWad(_gmxStore, _gmxCtx());
    }

    /// @dev shadow ledger + oracle mark at arbitrary price8 (SL LTV 시뮬).
    function _gmxEquityUsdWadAtPrice(uint256 price8) internal view returns (uint256) {
        GmxVaultStore storage s = _gmxStore;
        if (!s.mockActive || s.mockEntryPrice8 == 0) return 0;
        return GmxIntegrationReader.oracleMarkEquityUsdWad(
            s.mockCollateral, s.mockEntryPrice8, leverage, isLong, int256(price8)
        );
    }

    function _gmxPositionSnapshot() internal view returns (GmxPositionData memory) {
        return GmxIntegrationReader.positionSnapshot(_gmxStore, _gmxCtx());
    }

    function gmxOrders(bytes32 key) external view returns (GmxOrder memory) {
        return _gmxStore.orders[key];
    }

    function gmxKeyToRyexKey(bytes32 gmxKey) external view returns (bytes32) {
        return _gmxStore.gmxKeyToRyexKey[gmxKey];
    }

    function _gmxCreateOpenOrder(
        uint256 collateralUsdc,
        uint256 indexPrice8,
        uint256 leverage_,
        uint256 triggerPrice8
    ) internal returns (bytes32 orderKey) {
        bytes32 gmxKey;
        uint8 kind;
        (orderKey, gmxKey, kind) =
            GmxExecutor.createOpenOrder(_gmxStore, _gmxCtx(), collateralUsdc, indexPrice8, leverage_, triggerPrice8);
        emit GmxOrderCreated(orderKey, kind, gmxKey);
    }

    function _gmxCreateCloseOrder(uint256 triggerPrice8) internal returns (bytes32 orderKey) {
        bytes32 gmxKey;
        uint8 kind;
        (orderKey, gmxKey, kind) = GmxExecutor.createCloseOrder(_gmxStore, _gmxCtx(), triggerPrice8);
        emit GmxOrderCreated(orderKey, kind, gmxKey);
    }

    function _gmxCreateConditionalDecrease(uint256 triggerPrice8, bool isTakeProfit)
        internal
        returns (bytes32 orderKey)
    {
        bytes32 gmxKey;
        uint8 kind;
        (orderKey, gmxKey, kind) = GmxExecutor.createConditionalDecrease(_gmxStore, _gmxCtx(), triggerPrice8, isTakeProfit);
        emit GmxOrderCreated(orderKey, kind, gmxKey);
    }

    function _gmxCreateRedeemOrder(uint256 withdrawUsdc)
        internal
        returns (bytes32 orderKey, uint256 paidUsdc)
    {
        bytes32 gmxKey;
        uint8 kind;
        bool instant;
        (orderKey, gmxKey, kind, paidUsdc, instant) = GmxExecutor.createRedeemOrder(_gmxStore, _gmxCtx(), withdrawUsdc);
        emit GmxOrderCreated(orderKey, kind, gmxKey);
        if (instant) _completeRyexOrder(orderKey, bytes32(0), true, kind);
    }

    function _gmxCreateDepositCollateralOrder(uint256 collateralUsdc)
        internal
        returns (bytes32 orderKey, bool instant)
    {
        bytes32 gmxKey;
        uint8 kind;
        (orderKey, gmxKey, kind, instant) =
            GmxExecutor.createDepositCollateralOrder(_gmxStore, _gmxCtx(), collateralUsdc);
        emit GmxOrderCreated(orderKey, kind, gmxKey);
    }

    function _gmxCreateWithdrawCollateralOrder(uint256 withdrawUsdc)
        internal
        returns (bytes32 orderKey, bool instant)
    {
        bytes32 gmxKey;
        uint8 kind;
        (orderKey, gmxKey, kind, instant) =
            GmxExecutor.createWithdrawCollateralOrder(_gmxStore, _gmxCtx(), withdrawUsdc);
        emit GmxOrderCreated(orderKey, kind, gmxKey);
    }

    /// @dev GMX accrued funding settle 주문 제출(MarketDecrease size=0, collateral=1 wei). 헤지 상태머신과 독립.
    function _gmxCreateSettleFundingOrder() internal returns (bytes32 orderKey, bool instant) {
        bytes32 gmxKey;
        (orderKey, gmxKey, instant) = GmxExecutor.createSettleFundingOrder(_gmxStore, _gmxCtx());
        emit GmxOrderCreated(orderKey, GmxConstants.KIND_SETTLE_FUNDING, gmxKey);
        if (instant) _completeRyexOrder(orderKey, bytes32(0), true, GmxConstants.KIND_SETTLE_FUNDING);
    }

    function _gmxRequestCancellation(bytes32 ryexOrderKey) internal {
        (bool instant, uint8 kind) = GmxExecutor.requestCancellation(_gmxStore, _gmxCtx(), ryexOrderKey);
        if (instant) _completeRyexOrder(ryexOrderKey, bytes32(0), false, kind);
    }

    /// @dev nonReentrant 미적용 — GMX가 cancelOrder/executeOrder를 self-cancel 등으로 동기 처리하면서
    ///      우리 쪽 nonReentrant 진입점(cancelLimitOrder 등) 콜스택 안에서 같은 tx로 콜백이 재호출될 수 있음
    ///      (실사례: 사용자가 cancelLimitOrder() 호출 → exchangeRouter.cancelOrder()가 즉시 처리되며 같은 tx에서
    ///      afterOrderCancellation() 재호출 → 예전엔 nonReentrant 충돌로 되돌려졌고 GMX가 그 실패를 try/catch로
    ///      삼켜 vault 로컬 상태만 SettlingOpen에 영구 고착됐음). 접근 통제는 _requireGmxHandler()로 충분
    ///      (orderHandler만 호출 가능 — 신뢰 주체이므로 재진입 자체는 허용해도 안전).
    function afterOrderExecution(bytes32 key, EventLogData memory, EventLogData memory) external override {
        _requireGmxHandler();
        (bytes32 ryexKey, bool isExec, uint8 kind, bool handled) =
            GmxExecutor.finishSettlement(_gmxStore, _gmxCtx(), key, true);
        if (handled) _completeRyexOrder(ryexKey, key, isExec, kind);
    }

    /// @dev nonReentrant 미적용 이유는 afterOrderExecution 주석 참조.
    function afterOrderCancellation(bytes32 key, EventLogData memory, EventLogData memory) external override {
        _requireGmxHandler();
        (bytes32 ryexKey, bool isExec, uint8 kind, bool handled) =
            GmxExecutor.finishSettlement(_gmxStore, _gmxCtx(), key, false);
        if (handled) _completeRyexOrder(ryexKey, key, isExec, kind);
    }

    function afterOrderFrozen(bytes32 key, EventLogData memory, EventLogData memory) external override {
        _requireGmxHandler();
        emit GmxOrderFrozen(key);
    }

    /// @notice GMX 키퍼 콜백 누락 시 수동 복구. 호출 가능 범위는 구현체별(_requireSettleAuthorized) 결정
    ///         — PositionVault: 프로토콜 관리자(factory.owner())만. RYieldVault: vault owner(=governance).
    function settleGmxOrder(bytes32 gmxKey) external nonReentrant {
        _requireSettleAuthorized();
        (bytes32 ryexKey, bool isExec, uint8 kind) = GmxExecutor.settleGmxOrderAndFinish(_gmxStore, _gmxCtx(), gmxKey);
        _completeRyexOrder(ryexKey, gmxKey, isExec, kind);
    }

    /// @dev PositionVault / RYieldVault가 owner로 구현.
    function _requireSettleAuthorized() internal view virtual;

    function _completeRyexOrder(bytes32 ryexKey, bytes32 gmxKey, bool isExec, uint8 kind) internal {
        if (isExec) {
            emit GmxOrderExecuted(ryexKey, gmxKey);
            _onRyexOrderExecuted(ryexKey, kind);
        } else {
            emit GmxOrderCancelled(ryexKey, gmxKey);
            _onRyexOrderCancelled(ryexKey, kind);
        }
    }

    function _requireGmxHandler() internal view {
        address handler = IVaultFactory(factory).gmxInfra().orderHandler;
        if (handler != address(0)) require(msg.sender == handler, "GMX: not OrderHandler");
    }
}
