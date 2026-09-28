// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPositionVault} from "./interfaces/IPositionVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IRToken} from "./interfaces/IRToken.sol";
import {GmxIntegrationBase} from "./GmxIntegrationBase.sol";
import {LTVMath} from "./libraries/LTVMath.sol";
import {Units} from "./libraries/Units.sol";
import {VaultSettle} from "./libraries/VaultSettle.sol";
import {GmxFundingUtils} from "./libraries/GmxFundingUtils.sol";
import {GmxIntegrationReader} from "./libraries/GmxIntegrationReader.sol";
import {GmxConstants} from "./libraries/GmxConstants.sol";
import {IGmxDataStore} from "./interfaces/IGmxDataStore.sol";
import {VaultState, OrderKind, PendingOrder, RiskParams, GmxPositionData, PositionStore, SettleCtx, GmxInfra} from "./types/Types.sol";

/// @title PositionVault — 사용자별 격리 Vault (docs/10, Litepaper v1.6 §4.2/§5)
/// @notice EIP-1167 clone. GMX 2-step 비동기를 상태머신으로 흡수. 관리자 자금인출 함수 없음(G5).
///         v1.6: 레버리지별 MaxLTV 곡선(§5.1), LLTV=MaxLTV1x+Buffer(§5.2), 청산 페널티 10%(§7).
/// @dev 가변 포지션 상태는 _pos(PositionStore)에 통합 → VaultSettle 라이브러리가 정산(EIP-170 대응).
contract PositionVault is IPositionVault, Initializable, GmxIntegrationBase {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_EXEC_FEE = 1e14; // 0.0001 ETH (I7)
    uint256 internal constant MIN_COLLATERAL = 1e6; // 1 USDC (OQ-15)
    uint256 internal constant LIQ_PENALTY_BPS = 1_000; // 10% — Litepaper §7.1/§10.1
    uint256 internal constant PENALTY_LIQ_SHARE_BPS = 6_000; // 청산자(keeper) 보상 60%, 나머지 RyexTreasury
    uint256 internal constant SETTLING_TIMEOUT = 5 minutes; // OQ-6
    uint256 internal constant SL_LTV_BUFFER_BPS = 300; // 3% — SL↔mint LTV cap = RLT − 3% (청산 buffer와 별도)
    // ── v1.6 수수료 (Litepaper §7.1/§10.3). accruedFeesUsdc 누적 → close/liquidate 시 RyexTreasury로 지급. ──
    // 데모 편차(프로덕션 백로그): §7.1은 mint/redeem fee를 "발생 즉시 USDC 지급"이라 하나, owner free USDC+approval이
    //   필요해 담보 전액 예치 플로우를 깨므로 borrow fee처럼 누적-정산(잔여 equity 상한)으로 통일. underwater 청산 시
    //   잔여 equity < 누적 수수료면 미수 mint/redeem fee 일부 미징수.
    // borrow fee(Stability fee) APR은 v1.6 초안엔 고정 상수였으나 마켓별 차등을 위해
    // factory.markets[marketId].borrowAprBps(bps)로 옮겨졌다 — _marketBorrowAprBps() 참고. 기본값 150(1.5%).
    uint256 internal constant MINT_FEE_BPS = 25; // 0.25% 1회 (mint 시)
    uint256 internal constant REDEEM_FEE_BPS = 25; // 0.25% 1회 (repay/redeem 시)
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    address public owner;
    IRToken internal rToken;
    // 구버전 risk 스냅샷 슬롯 자리(레이아웃 유지). live 값은 factory.markets[] / VaultLens.
    uint16 private __gapRisk0;
    uint16 private __gapRisk1;
    uint16 private __gapRisk2;
    uint8 private __gapRisk3;
    uint8 private __gapRisk4;
    // leverage, isLong, factory, usdc, marketId, oracle() → GmxIntegrationBase

    // ── 가변 포지션 상태 (정산 상태머신이 변경) → VaultSettle가 storage ref로 갱신 ──
    PositionStore internal _pos;

    event CollateralDeposited(address indexed vault, uint256 amount);
    event CollateralWithdrawn(address indexed vault, uint256 amount);
    event PositionOpenRequested(address indexed vault, bytes32 orderKey, uint8 leverage, bool isLong);
    event PositionOpened(address indexed vault, bytes32 posKey);
    event PositionOpenFailed(address indexed vault, bytes32 orderKey);
    event PositionCloseRequested(address indexed vault, bytes32 orderKey, uint8 kind);
    event TakeProfitSet(address indexed vault, bytes32 orderKey, uint256 triggerPrice8);
    event StopLossSet(address indexed vault, bytes32 orderKey, uint256 triggerPrice8);
    event ConditionalOrderCancelled(address indexed vault, bytes32 orderKey, uint8 kind);
    event RBTCMinted(address indexed vault, uint256 amount);
    event RBTCRepaid(address indexed vault, uint256 amount);
    event Liquidated(address indexed vault, uint256 debtRepaidUsdc, uint256 refundUsdc, uint256 keeperBountyUsdc);
    event StuckOrderRecovered(address indexed vault, bytes32 orderKey);
    event RedeemRequested(address indexed vault, address indexed redeemer, bytes32 orderKey, uint256 rTokenAmount);
    event CollateralDepositRequested(address indexed vault, bytes32 orderKey, uint256 usdcAmount);
    event CollateralDepositedToPosition(address indexed vault, uint256 usdcAmount);
    event CollateralWithdrawRequested(address indexed vault, bytes32 orderKey, uint256 usdcAmount);
    event FundingSettleRequested(bytes32 orderKey, bytes32 gmxKey);
    event FundingHarvested(uint256 longAmount, uint256 shortAmount);
    error NotOwner();
    error BadState();
    error BadKey();
    error InsufficientExecFee();
    error BelowMinCollateral();
    error ExceedsMaxLTV();
    error NotLiquidatable();
    error AlreadyLiquidatable();
    error OutstandingDebt();
    error NotTimedOut();
    error BadLeverage();
    error BadDirection();
    error NotRouter();
    error NotRedeemable();
    error ZeroAmount();
    error ZeroPrice();
    error ExceedCollateral();
    error NoTpOrder();
    error NoSlOrder();
    error SlLtvExceeded();
    error InvalidSlPrice();
    error DepositNotReceived();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev settleGmxOrder 복구 경로 — 프로토콜 관리자(factory.owner())만. vault owner(유저 본인)는 호출 불가.
    function _requireSettleAuthorized() internal view override {
        if (msg.sender != IVaultFactory(factory).owner()) revert NotOwner();
    }

    modifier notPaused() {
        if (IVaultFactory(factory).paused()) revert BadState();
        _;
    }

    modifier onlyRouter() {
        if (msg.sender != IVaultFactory(factory).router()) revert NotRouter();
        _;
    }

    /// @dev Active + 대기주문 없음 공통 가드 (다수 진입점 중복 제거).
    function _requireActiveIdle() internal view {
        if (_pos.state != VaultState.Active) revert BadState();
        if (_pos.pending.kind != OrderKind.None) revert BadState();
    }

    /// @dev GMX 실행수수료(msg.value) 최소치 가드.
    function _requireExecFee() internal view {
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee();
    }

    constructor() {
        _disableInitializers(); // 로직 컨트랙트 초기화 차단
    }

    function initialize(
        address owner_,
        address factory_,
        address usdc_,
        address rToken_,
        bytes32 marketId_,
        bool isLong_,
        RiskParams calldata risk
    ) external initializer {
        owner = owner_;
        factory = factory_;
        usdc = IERC20(usdc_);
        rToken = IRToken(rToken_);
        _marketId = marketId_;
        isLong = isLong_;
        // RiskParams는 factory.markets[] live — vault에 스냅샷 저장하지 않음(bytecode·진실원 단일화).
        risk;
        _pos.state = VaultState.Empty;
        usdc.forceApprove(IVaultFactory(factory_).gmxInfra().gmxRouter, type(uint256).max);
    }

    // ── 마켓 risk (factory live — setMarketRisk / setBufferBps 즉시 반영) ──

    function _marketRisk() internal view returns (RiskParams memory r) {
        (
            ,
            ,
            ,
            ,
            ,
            r.maxLtv1xBps,
            r.bufferBps,
            r.maxLtvAtMaxLevBps,
            r.flatTier,
            r.maxLeverage,
        ) = IVaultFactory(factory).markets(_marketId);
    }

    /// @dev 마켓별 borrow fee APR(bps) — factory.markets[].borrowAprBps live 조회(owner setBorrowAprBps
    ///      즉시 반영, 소급 아님). _marketRisk()와 별도 호출인 이유: RiskParams(LTV 곡선)와는 무관한 수수료값.
    function _borrowAprBps() internal view returns (uint16 bps) {
        (,,,,,,,,,, bps) = IVaultFactory(factory).markets(_marketId);
    }

    // ── 조회 (기본 상태만; 파생 지표·RiskParams는 VaultLens) ──

    function marketId() public view override returns (bytes32) {
        return _marketId;
    }

    function collateral() external view returns (uint256) {
        return _pos.collateral;
    }

    function debt() external view returns (uint256) {
        return _pos.debt;
    }

    function state() external view returns (VaultState) {
        return _pos.state;
    }

    function posKey() external view returns (bytes32) {
        return _pos.posKey;
    }

    function pending() external view returns (PendingOrder memory) {
        return _pos.pending;
    }

    function accruedFeesUsdc() external view returns (uint256) {
        return _pos.accruedFeesUsdc;
    }

    /// @notice 누적 borrow fee(1.5% APR) 조회. mint/redeem fee(accruedFeesUsdc)와 별도 회계 —
    ///         정산 시 factory.borrowFeeToLpBps 비율만큼 LP 인센티브로 분리되기 때문(docs 참고).
    function accruedBorrowFeeUsdc() external view returns (uint256) {
        return _pos.accruedBorrowFeeUsdc;
    }

    function lastAccrual() external view returns (uint256) {
        return _pos.lastAccrual;
    }

    function tpOrderKey() external view returns (bytes32) {
        return _pos.tpOrderKey;
    }

    function slOrderKey() external view returns (bytes32) {
        return _pos.slOrderKey;
    }

    function slTriggerPrice8() external view returns (uint256) {
        return _pos.slTriggerPrice8;
    }

    // ── 사용자 동작 ──

    /// @notice Router가 USDC를 vault로 보낸 뒤 호출. owner_는 vault.owner와 일치해야 함.
    function deposit(address owner_, uint256 usdcAmount) external onlyRouter notPaused nonReentrant {
        if (owner_ != owner) revert NotOwner();
        if (_pos.state != VaultState.Empty && _pos.state != VaultState.Active) revert BadState();
        if (usdcAmount == 0) revert BelowMinCollateral();
        _pos.collateral += usdcAmount;
        // 포지션 미배치(posKey==0) 상태에서는 collateral 전액이 vault에 idle USDC로 존재해야 함.
        // router가 전송 없이 deposit을 호출하면(회계 오염) 여기서 차단. GMX 배치 중(posKey!=0)엔
        // idle<collateral이 정상이므로 검증 생략.
        if (_pos.posKey == bytes32(0) && usdc.balanceOf(address(this)) < _pos.collateral) revert DepositNotReceived();
        emit CollateralDeposited(address(this), usdcAmount);
        _notifyFactory(int256(usdcAmount));
    }

    /// @notice vault USDC 회수.
    ///         GMX 종료 후(posKey==0) + debt·fee 있음 → 오라클가 확정정산(대기버킷 적립) 후 잔여 USDC를 owner에게 전송.
    ///         GMX 열림 중 → vault 잔고(미배치 USDC)만 부분 인출. 부채는 포지션 담보이므로 idle USDC는 인출 가능.
    function withdraw(uint256 usdcAmount) external onlyOwner notPaused nonReentrant {
        if (_pos.pending.kind != OrderKind.None) revert BadState();
        if (_pos.state == VaultState.SettlingLiquidate || _pos.state == VaultState.SettlingOpen) revert BadState();

        _accrueBorrow();

        if (
            (_pos.debt > 0 || _pos.accruedFeesUsdc > 0 || _pos.accruedBorrowFeeUsdc > 0)
                && _pos.posKey == bytes32(0)
        ) {
            (uint256 toOwner,,) = _settleDebtExit(false, address(0));
            emit CollateralWithdrawn(address(this), toOwner);
            return;
        }

        uint256 bal = usdc.balanceOf(address(this));
        if (bal > _pos.collateral) {
            _notifyFactory(int256(bal - _pos.collateral));
            _pos.collateral = bal;
        }
        if (usdcAmount == 0) revert ZeroAmount();
        if (usdcAmount > bal) revert ExceedCollateral();

        _pos.collateral -= usdcAmount;
        usdc.safeTransfer(owner, usdcAmount);
        _notifyFactory(-int256(usdcAmount));
        if (_pos.collateral == 0) {
            if (_pos.posKey != bytes32(0)) revert BadState();
            _pos.state = VaultState.Empty;
            _pos.lastAccrual = 0;
        }
        emit CollateralWithdrawn(address(this), usdcAmount);
    }

    /// @notice 요청 `collateralUsdc`만큼만 오픈/증액. Router 전용(부족분은 Router가 deposit).
    /// @dev triggerPrice8=0 시장가, 아니면 limit. limit 취소는 cancelLimitOrder().
    function openPosition(uint8 leverage_, uint256 triggerPrice8, bool isLong_, uint256 collateralUsdc)
        external
        payable
        onlyRouter
        notPaused
        nonReentrant
    {
        OrderKind kind = triggerPrice8 == 0 ? OrderKind.Open : OrderKind.LimitOpen;
        _openPosition(leverage_, triggerPrice8, kind, isLong_, collateralUsdc);
    }

    function _openPosition(uint8 leverage_, uint256 triggerPrice8, OrderKind kind, bool isLong_, uint256 collateralUsdc)
        internal
    {
        if (isLong_ != isLong) revert BadDirection();
        if (_pos.pending.kind != OrderKind.None) revert BadState();
        uint256 incrementUsdc = _openCollateralDelta(collateralUsdc);
        if (leverage_ < 1 || leverage_ > _marketRisk().maxLeverage) revert BadLeverage();
        _requireExecFee();
        leverage = leverage_;
        uint256 indexPrice8 = kind == OrderKind.LimitOpen ? triggerPrice8 : _oracle().getPrice();
        bytes32 key = _gmxCreateOpenOrder(incrementUsdc, indexPrice8, leverage_, triggerPrice8);
        _pos.state = VaultState.SettlingOpen;
        _pos.pending = PendingOrder(kind, key, block.timestamp);
        emit PositionOpenRequested(address(this), key, leverage_, isLong);
    }

    function _openCollateralDelta(uint256 requested) internal view returns (uint256) {
        uint256 available;
        if (_pos.state == VaultState.Empty) available = _pos.collateral;
        else if (_pos.state == VaultState.Active) available = usdc.balanceOf(address(this));
        else revert BadState();
        if (requested < MIN_COLLATERAL) revert BelowMinCollateral();
        if (requested > available) revert ExceedCollateral();
        return requested;
    }

    /// @notice GMX 포지션에 담보만 추가 (size·레버리지 유지). deposit 후 vault idle USDC 사용.
    /// @dev MarketIncrease(sizeDelta=0). SettlingOpen → Active 유지.
    function depositCollateral(uint256 usdcAmount) external payable onlyOwner notPaused nonReentrant {
        _requireActiveIdle();
        if (_pos.posKey == bytes32(0)) revert BadState();
        if (usdcAmount == 0) revert ZeroAmount();
        if (usdcAmount < MIN_COLLATERAL) revert BelowMinCollateral();
        if (usdcAmount > usdc.balanceOf(address(this))) revert ExceedCollateral();
        _requireExecFee();
        _pos.state = VaultState.SettlingOpen;
        (bytes32 key, bool instant) = _gmxCreateDepositCollateralOrder(usdcAmount);
        _pos.pending = PendingOrder(OrderKind.DepositCollateral, key, block.timestamp);
        emit CollateralDepositRequested(address(this), key, usdcAmount);
        if (instant) {
            _pos.state = VaultState.Active;
            delete _pos.pending;
            emit CollateralDepositedToPosition(address(this), usdcAmount);
        }
    }

    /// @notice GMX 포지션에서 excess 담보만 회수 (size 유지). owner에게 USDC 전송.
    /// @dev MarketDecrease(sizeDelta=0). 부채 있으면 인출 후 LTV ≤ effectiveMaxLtv 검사.
    function withdrawCollateral(uint256 usdcAmount) external payable onlyOwner notPaused nonReentrant {
        _requireActiveIdle();
        if (_pos.posKey == bytes32(0)) revert BadState();
        if (usdcAmount == 0) revert ZeroAmount();
        _requireExecFee();
        _accrueBorrow();
        _requireWithdrawCollateralLtv(usdcAmount);
        _pos.pendingWithdrawUsdcSnap = usdc.balanceOf(address(this));
        (bytes32 key, bool instant) = _gmxCreateWithdrawCollateralOrder(usdcAmount);
        _pos.pending = PendingOrder(OrderKind.WithdrawCollateral, key, block.timestamp);
        emit CollateralWithdrawRequested(address(this), key, usdcAmount);
        if (instant) _settleWithdrawCollateral();
    }

    /// @notice 미체결 limit open/close 주문 취소 요청.
    function cancelLimitOrder() external onlyOwner nonReentrant {
        VaultSettle.requireLimitPending(_pos);
        _gmxRequestCancellation(_pos.pending.orderKey);
    }

    /// @notice 미체결 limit open/close 주문의 triggerPrice만 갱신 (취소+재생성 없이 GMX updateOrder 사용).
    ///         사이즈·담보는 그대로 유지된다. GMX 쪽 order가 아직 없는(mock-only) 주문은 대상이 아니다.
    function updateLimitOrder(uint256 newTriggerPrice8) external payable onlyOwner nonReentrant {
        VaultSettle.updateLimitOrder(_pos, _gmxStore, _gmxCtx(), newTriggerPrice8);
    }

    function mint(uint256 rBtcAmount) external onlyOwner notPaused nonReentrant {
        _requireActiveIdle();
        if (rBtcAmount == 0) revert ZeroAmount();
        _accrueBorrow();
        uint256 effMaxLtv = _effectiveMaxLtvBps();
        if (effMaxLtv == 0) revert ExceedsMaxLTV();
        uint256 mintValueWad = Units.rTokenToUsdWad(rBtcAmount, _oracle().getPrice());
        if (mintValueWad > LTVMath.mintHeadroomUsdWad(_collateralValueUsdWad(), _debtValueUsdWad(), effMaxLtv)) {
            revert ExceedsMaxLTV();
        }
        uint256 newDebt = _pos.debt + rBtcAmount;
        if (_pos.slTriggerPrice8 != 0) {
            _requireSlLtvAtPrice(_pos.slTriggerPrice8, newDebt);
        }
        _pos.accruedFeesUsdc += (Units.wadToUsdc(mintValueWad) * MINT_FEE_BPS) / BPS;
        _pos.debt = newDebt;
        rToken.mint(owner, rBtcAmount);
        emit RBTCMinted(address(this), rBtcAmount);
    }

    function repay(uint256 rBtcAmount) external onlyOwner notPaused nonReentrant {
        if (_pos.state != VaultState.Active) revert BadState();
        uint256 amt = rBtcAmount > _pos.debt ? _pos.debt : rBtcAmount;
        if (amt == 0) revert ZeroAmount();
        _accrueBorrow();
        _pos.accruedFeesUsdc += (Units.wadToUsdc(Units.rTokenToUsdWad(amt, _oracle().getPrice())) * REDEEM_FEE_BPS) / BPS;
        _pos.debt -= amt;
        rToken.burn(owner, amt);
        emit RBTCRepaid(address(this), amt);
    }

    /// @notice 포지션 청산. triggerPrice8=0 시장가, 아니면 limit (취소는 cancelLimitOrder).
    function closePosition(uint256 triggerPrice8) external payable onlyOwner notPaused nonReentrant {
        _requestClose(triggerPrice8);
    }

    function _requestClose(uint256 triggerPrice8) internal {
        _requireActiveIdle();
        if (_pos.debt != 0) revert OutstandingDebt();
        _requireExecFee();
        _requestCancelAllConditionalOrders();
        bytes32 key = _gmxCreateCloseOrder(triggerPrice8);
        OrderKind kind = triggerPrice8 == 0 ? OrderKind.Close : OrderKind.LimitClose;
        _pos.state = VaultState.SettlingLiquidate;
        _pos.pending = PendingOrder(kind, key, block.timestamp);
        emit PositionCloseRequested(address(this), key, uint8(kind));
    }

    /// @notice 익절(Take Profit) 주문 설정 / 갱신. Active 상태에서만 가능.
    ///         롱 TP: triggerPrice8 이상으로 가격이 오를 때 전량 청산.
    ///         숏 TP: triggerPrice8 이하로 가격이 내릴 때 전량 청산.
    ///         기존 TP가 있으면 GMX 취소 후 새 주문으로 교체.
    /// @param triggerPrice8 익절 목표 가격. **8 decimals**: 예) $2,000 → 200_000_000_000.
    function setTakeProfit(uint256 triggerPrice8) external payable onlyOwner notPaused nonReentrant {
        _setConditionalOrder(triggerPrice8, true);
    }

    /// @notice 손절(Stop Loss) 주문 설정 / 갱신. Active 상태에서만 가능.
    ///         롱 SL: triggerPrice8 이하로 가격이 내릴 때 전량 청산.
    ///         숏 SL: triggerPrice8 이상으로 가격이 오를 때 전량 청산.
    ///         기존 SL이 있으면 GMX 취소 후 새 주문으로 교체.
    /// @param triggerPrice8 손절 기준 가격. **8 decimals**: 예) $1,200 → 120_000_000_000.
    function setStopLoss(uint256 triggerPrice8) external payable onlyOwner notPaused nonReentrant {
        _setConditionalOrder(triggerPrice8, false);
    }

    function _setConditionalOrder(uint256 triggerPrice8, bool isTakeProfit) internal {
        _requireActiveIdle();
        if (!isTakeProfit && LTVMath.isLiquidatable(_currentLTV(), _lltvBps())) revert AlreadyLiquidatable();
        _requireExecFee();
        if (triggerPrice8 == 0) revert ZeroPrice();
        if (!isTakeProfit) {
            _requireSlTriggerDirection(triggerPrice8);
            if (_pos.debt > 0) _requireSlLtvAtPrice(triggerPrice8, _pos.debt);
        }
        if (isTakeProfit) _requestCancelConditional(_pos.tpOrderKey, true);
        else _requestCancelConditional(_pos.slOrderKey, false);
        bytes32 key = _gmxCreateConditionalDecrease(triggerPrice8, isTakeProfit);
        if (isTakeProfit) {
            _pos.tpOrderKey = key;
            emit TakeProfitSet(address(this), key, triggerPrice8);
        } else {
            _pos.slOrderKey = key;
            _pos.slTriggerPrice8 = triggerPrice8;
            emit StopLossSet(address(this), key, triggerPrice8);
        }
    }

    /// @notice TP 주문 취소 (GMX에 취소 요청 전송).
    function cancelTakeProfit() external onlyOwner nonReentrant {
        if (_pos.tpOrderKey == bytes32(0)) revert NoTpOrder();
        _requestCancelConditional(_pos.tpOrderKey, true);
    }

    /// @notice SL 주문 취소 (GMX에 취소 요청 전송).
    function cancelStopLoss() external onlyOwner nonReentrant {
        if (_pos.slOrderKey == bytes32(0)) revert NoSlOrder();
        _requestCancelConditional(_pos.slOrderKey, false);
    }

    /// @notice 청산(LLTV 백스톱). pause 중에도 허용(탈출 경로, docs/70 §5).
    function liquidate() external payable nonReentrant {
        _requireActiveIdle();
        _requireExecFee();
        uint256 ltv = _currentLTV();
        if (!LTVMath.isLiquidatable(ltv, _lltvBps())) revert NotLiquidatable(); // L1/I4
        _pos.liquidator = msg.sender;
        _requestCancelAllConditionalOrders();
        bytes32 key = _gmxCreateCloseOrder(0);
        _pos.state = VaultState.SettlingLiquidate;
        _pos.pending = PendingOrder(OrderKind.Liquidate, key, block.timestamp);
        emit PositionCloseRequested(address(this), key, uint8(OrderKind.Liquidate));
    }

    /// @notice RLT 상환 (Litepaper §4.5/§5.3). 상환존(RLT<=ltv<LLTV)에서 누구나 rToken을 제출해
    ///         oracle가로 부채를 줄이고, GMX partial decrease 후 회수 USDC(−redeem fee)를 받는다. 페널티 없음.
    /// @dev rToken은 escrow 후 GMX 체결 시 burn. GMX 취소 시 redeemer에게 반환.
    ///      인센티브: AMM 할인 매수 rToken → oracle가 상환 스프레드.
    function redeem(uint256 rTokenAmount) external payable nonReentrant {
        _requireActiveIdle();
        if (!_inRedemptionZone()) revert NotRedeemable();
        _requireExecFee();
        uint256 amt = rTokenAmount > _pos.debt ? _pos.debt : rTokenAmount;
        if (amt == 0) revert ZeroAmount();
        _accrueBorrow();
        uint256 redeemUsdc = Units.wadToUsdc(Units.rTokenToUsdWad(amt, _oracle().getPrice()));
        IERC20(address(rToken)).safeTransferFrom(msg.sender, address(this), amt);
        _pos.pendingRedeemer = msg.sender;
        _pos.pendingRedeemAmt = amt;
        _pos.pendingRedeemUsdcSnap = usdc.balanceOf(address(this));
        (bytes32 key, uint256 paid) = _gmxCreateRedeemOrder(redeemUsdc);
        _pos.pending = PendingOrder(OrderKind.Redeem, key, block.timestamp);
        emit RedeemRequested(address(this), msg.sender, key, amt);
        if (paid > 0) _settleRedeem();
    }

    /// @notice Settling 멈춤 복구 (docs/60 OQ-6). 정산 행이 안 올 때 탈출.
    ///         LimitOpen/Close는 cancelLimitOrder() 사용.
    /// @dev onlyOwner — permissionless면 GMX 미취소 상태에서 로컬만 풀어 orphan fill이 가능했음.
    ///      본체는 VaultSettle.recoverStuckOrder (EIP-170).
    function cancelStuckOrder() external onlyOwner nonReentrant {
        (bytes32 ryexKey, bytes32 gmxKey, bool isExec, uint8 kind, uint8 mode) =
            VaultSettle.recoverStuckOrder(_pos, _gmxStore, _gmxCtx(), SETTLING_TIMEOUT);
        if (mode == 1) {
            _gmxRequestCancellation(ryexKey);
        } else if (mode == 2) {
            _completeRyexOrder(ryexKey, gmxKey, isExec, kind);
        }
        emit StuckOrderRecovered(address(this), ryexKey);
    }

    // ── GMX 정산 → Vault 상태머신 ───────────────────────────────────────────────

    function _onRyexOrderExecuted(bytes32 orderKey, uint8 kind) internal override {
        if (kind == GmxConstants.KIND_SETTLE_FUNDING) {
            _gmxStore.pendingFundingSettleRyexKey = bytes32(0);
            return;
        }
        VaultSettle.handleOrderExecuted(_pos, _gmxStore, _settleCtx(), orderKey);
    }

    function _onRyexOrderCancelled(bytes32 orderKey, uint8 kind) internal override {
        if (kind == GmxConstants.KIND_SETTLE_FUNDING) {
            _gmxStore.pendingFundingSettleRyexKey = bytes32(0);
            return;
        }
        VaultSettle.handleOrderCancelled(_pos, _settleCtx(), orderKey);
    }

    /// @notice GMX accrued funding(미정산)을 claimable로 전환(2-step 1단계). 누구나 호출 가능(keeper).
    function requestAccruedFundingSettle() external nonReentrant returns (bytes32 orderKey) {
        if (_pos.state != VaultState.Active) revert BadState();
        bool instant;
        (orderKey, instant) = _gmxCreateSettleFundingOrder();
        emit FundingSettleRequested(orderKey, _gmxStore.orders[orderKey].gmxKey);
        instant;
    }

    /// @notice claimable funding fee(+affiliate reward)를 owner 지갑으로 직접 클레임. 볼트 회계는 미변경.
    function harvestFunding() external nonReentrant returns (uint256 longAmt, uint256 shortAmt) {
        GmxInfra memory infra = IVaultFactory(factory).gmxInfra();
        address mkt = GmxIntegrationReader.gmxMarket(_gmxCtx());
        (longAmt, shortAmt) =
            GmxFundingUtils.harvestFundingToReceiver(IGmxDataStore(infra.dataStore), infra.exchangeRouter, mkt, owner);
        emit FundingHarvested(longAmt, shortAmt);
    }

    function _requestCancelConditional(bytes32 key, bool isTakeProfit) internal {
        if (key == bytes32(0)) return;
        if (isTakeProfit) {
            _pos.tpOrderKey = bytes32(0);
            _pos.tpCancellingKey = key;
        } else {
            _pos.slOrderKey = bytes32(0);
            _pos.slCancellingKey = key;
        }
        _gmxRequestCancellation(key);
        emit ConditionalOrderCancelled(
            address(this), key, uint8(isTakeProfit ? OrderKind.TakeProfit : OrderKind.StopLoss)
        );
    }

    function _requestCancelAllConditionalOrders() internal {
        _requestCancelConditional(_pos.tpOrderKey, true);
        _requestCancelConditional(_pos.slOrderKey, false);
    }

    // ── factory TVL 통보 ──

    /// @notice collateral 증감분을 factory로 push → totalCollateralLocked 갱신.
    ///         실패해도 볼트 동작에 영향 없도록 try/catch로 감쌈.
    function _notifyFactory(int256 delta) internal {
        if (delta == 0) return;
        try IVaultFactory(factory).onCollateralChanged(delta) {} catch {}
    }

    /// @dev vault USDC 잔고를 collateral 회계에 재동기화하고 증감분을 factory에 통보 (다수 정산 경로 공통).
    function _resyncCollateral() internal {
        if (_pos.posKey != bytes32(0)) return; // 활성 GMX 포지션 있으면 idle로 덮지 않음
        uint256 prev = _pos.collateral;
        uint256 bal = usdc.balanceOf(address(this));
        if (bal != prev) {
            _pos.collateral = bal;
            _notifyFactory(int256(bal) - int256(prev));
        }
    }

    // ── 수수료 적립 ──

    function _accrueBorrow() internal {
        uint256 last = _pos.lastAccrual;
        if (last != 0 && _pos.debt > 0) {
            uint256 dt = block.timestamp - last;
            if (dt > 0) {
                _pos.accruedBorrowFeeUsdc +=
                    (Units.wadToUsdc(_debtValueUsdWad()) * _borrowAprBps() * dt) / (BPS * SECONDS_PER_YEAR);
            }
        }
        _pos.lastAccrual = block.timestamp;
    }

    // ── 정산 (VaultSettle 외부 라이브러리 위임, delegatecall) ──

    function _settleCtx() internal view returns (SettleCtx memory) {
        return SettleCtx({
            owner: owner,
            factory: factory,
            marketId: _marketId,
            oracle: address(_oracle()),
            usdc: address(usdc),
            rToken: address(rToken),
            isLong: isLong
        });
    }

    function _settleRedeem() internal {
        _accrueBorrow();
        VaultSettle.settleRedeem(_pos, _settleCtx());
    }

    function _cancelPendingRedeem() internal {
        VaultSettle.cancelPendingRedeem(_pos, address(rToken));
    }

    function _settleWithdrawCollateral() internal {
        VaultSettle.settleWithdrawCollateral(_pos, _settleCtx());
    }

    /// @dev 부채 있을 때 담보 인출 후 LTV ≤ effectiveMaxLtv (oracle mark equity 기준).
    function _requireWithdrawCollateralLtv(uint256 withdrawUsdc) internal view {
        if (_pos.debt == 0) return;
        uint256 colVal = _collateralValueUsdWad();
        uint256 debtVal = _debtValueUsdWad();
        uint256 withdrawWad = Units.usdcToWad(withdrawUsdc);
        if (colVal <= withdrawWad) revert ExceedsMaxLTV();
        uint256 newLtv = LTVMath.currentLTV(colVal - withdrawWad, debtVal);
        if (newLtv > _effectiveMaxLtvBps()) revert ExceedsMaxLTV();
    }

    /// @notice 부채·fee 정산 후 vault 리셋. `withdraw`(owner) 및 liquidate 콜백(keeper 페널티) 공용.
    function _settleDebtExit(bool applyPenalty, address keeper)
        internal
        returns (uint256 toOwner, uint256 usdcDebtSpent, uint256 keeperBounty)
    {
        return VaultSettle.settleDebtExit(_pos, _settleCtx(), applyPenalty, keeper);
    }

    function lensGmxSnapshot() external view returns (GmxPositionData memory) {
        return _gmxPositionSnapshot();
    }

    function lensGmxEquityUsdWad() external view returns (uint256) {
        return _gmxPositionValueUsdWad();
    }

    function _lltvBps() internal view returns (uint256) {
        RiskParams memory r = _marketRisk();
        return LTVMath.lltvFromMaxLtv(r.maxLtv1xBps, r.bufferBps);
    }

    function _rltBps() internal view returns (uint256) {
        return LTVMath.rltFromMaxLtv(_marketRisk().maxLtv1xBps);
    }

    function _effectiveMaxLtvBps() internal view returns (uint256) {
        RiskParams memory r = _marketRisk();
        // setMarketRisk로 maxLeverage가 기존 포지션 배율보다 낮아져도 mint/인출 경로가 revert되지 않게 clamp.
        uint256 lev = LTVMath.normalizeLeverage(leverage);
        if (lev > r.maxLeverage) lev = r.maxLeverage;
        return LTVMath.maxLtvForLeverage(
            r.maxLtv1xBps, r.maxLtvAtMaxLevBps, lev, r.flatTier, r.maxLeverage
        );
    }

    function _collateralValueUsdWad() internal view returns (uint256) {
        if ((_pos.state == VaultState.Active || _pos.state == VaultState.SettlingLiquidate) && _pos.posKey != bytes32(0))
        {
            return _gmxPositionValueUsdWad();
        }
        return Units.usdcToWad(_pos.collateral);
    }

    function _debtValueUsdWad() internal view returns (uint256) {
        return Units.rTokenToUsdWad(_pos.debt, _oracle().getPrice());
    }

    function _currentLTV() internal view returns (uint256) {
        return LTVMath.currentLTVOrSentinel(_collateralValueUsdWad(), _debtValueUsdWad());
    }

    function _inRedemptionZone() internal view returns (bool) {
        return _pos.state == VaultState.Active && LTVMath.inRedemptionZone(_currentLTV(), _rltBps(), _lltvBps());
    }

    function _slCapBps() internal view returns (uint256) {
        return LTVMath.slCapBps(_rltBps(), SL_LTV_BUFFER_BPS);
    }

    /// @dev SL 트리거 가격에서 debtRToken 기준 LTV ≤ RLT − SL_LTV_BUFFER_BPS (3%).
    function _requireSlLtvAtPrice(uint256 price8, uint256 debtRToken) internal view {
        if (debtRToken == 0) return;
        uint256 cap = _slCapBps();
        if (cap == 0) revert SlLtvExceeded();
        uint256 equityWad = _gmxEquityUsdWadAtPrice(price8);
        uint256 debtWad = Units.rTokenToUsdWad(debtRToken, _oracle().getPrice());
        if (!LTVMath.isSlLtvAllowed(equityWad, debtWad, cap)) revert SlLtvExceeded();
    }

    /// @dev 롱 SL: trigger < mark. 숏 SL: trigger > mark.
    function _requireSlTriggerDirection(uint256 triggerPrice8) internal view {
        uint256 mark = _oracle().getPrice();
        if (isLong) {
            if (triggerPrice8 >= mark) revert InvalidSlPrice();
        } else if (triggerPrice8 <= mark) {
            revert InvalidSlPrice();
        }
    }

    receive() external payable {} // GMX exec fee 환불 수령
}
