// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPositionVault} from "./interfaces/IPositionVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IGmxAdapter} from "./interfaces/IGmxAdapter.sol";
import {IRToken} from "./interfaces/IRToken.sol";
import {LTVMath} from "./libraries/LTVMath.sol";
import {Units} from "./libraries/Units.sol";
import {VaultState, OrderKind, PendingOrder, RiskParams, VaultSnapshot, VaultGmxPosition} from "./types/Types.sol";

/// @title PositionVault — 사용자별 격리 Vault (docs/10, Litepaper v1.6 §4.2/§5)
/// @notice EIP-1167 clone. GMX 2-step 비동기를 상태머신으로 흡수. 관리자 자금인출 함수 없음(G5).
///         v1.6: 레버리지별 MaxLTV 곡선(§5.1), LLTV=MaxLTV1x+Buffer(§5.2), 청산 페널티 10%(§7).
contract PositionVault is IPositionVault, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_EXEC_FEE = 1e14; // 0.0001 ETH (I7)
    uint256 internal constant MIN_COLLATERAL = 1e6; // 1 USDC (OQ-15)
    uint256 internal constant LIQ_PENALTY_BPS = 1_000; // 10% — Litepaper §7.1/§10.1
    uint256 internal constant PENALTY_LIQ_SHARE_BPS = 6_000; // 청산자(keeper) 보상 60%, 나머지 treasury
    uint256 internal constant SETTLING_TIMEOUT = 5 minutes; // OQ-6
    // ── v1.6 수수료 (Litepaper §7.1/§10.3). 모두 accruedFeesUsdc에 누적 → close/liquidate 시 treasury(=factory)로 지급. ──
    // 데모 편차(프로덕션 백로그): §7.1은 mint/redeem fee를 "발생 즉시 USDC 지급"이라 하나, owner free USDC+approval이
    //   필요해 담보 전액 예치 플로우를 깨므로 borrow fee처럼 누적-정산(잔여 equity 상한)으로 통일. underwater 청산 시
    //   잔여 equity < 누적 수수료면 미수 mint/redeem fee 일부 미징수.
    uint256 internal constant BORROW_FEE_APR_BPS = 150; // 1.5% APR (Stability fee) — 미상환 부채 달러가치에 연속 부과
    uint256 internal constant MINT_FEE_BPS = 25; // 0.25% 1회 (mint 시)
    uint256 internal constant REDEEM_FEE_BPS = 25; // 0.25% 1회 (repay/redeem 시)
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    address public owner;
    address public factory;
    IGmxAdapter public gmx;
    IPriceOracle public oracle;
    IERC20 public usdc;
    IRToken public rToken;
    bytes32 public marketId; // 자산 마켓 식별자

    // ── v1.6 리스크 곡선 파라미터 (자산별, Litepaper §5) ──
    uint16 public maxLtv1xBps; // MaxLTV at 1× (= RLT, 상환 임계)
    uint16 public bufferBps; // LLTV = maxLtv1x + buffer
    uint16 public maxLtvAtMaxLevBps; // 최대배율 MaxLTV (0=mint 금지)
    uint8 public flatTier; // full-maxLtv 평탄 구간 상한
    uint8 public maxLeverage; // 허용 최대 레버리지
    uint8 public leverage; // 이 포지션의 선택 레버리지 (open 시 확정)
    bool  public isLong;   // 롱(true) / 숏(false) — open 시 확정

    uint256 public collateral; // USDC 회계 (6dec)
    uint256 public debt; // rToken (18dec)
    VaultState public state;
    PendingOrder public pending;
    bytes32 public posKey;
    address public liquidator; // 청산 보상 수령자

    address public pendingRedeemer; // RLT redeem 대기 중 rToken 제출자
    uint256 public pendingRedeemAmt; // escrow rToken (18dec)
    uint256 public pendingRedeemUsdcSnap; // redeem 정산 시 증가분만 회수

    uint256 public accruedFeesUsdc; // 누적 프로토콜 수수료(USDC 6dec): borrow+mint+redeem. close/liquidate 시 정산.
    uint256 public lastAccrual; // 마지막 borrow-fee 적립 시각 (포지션 Active 시 시작)

    // ── 조건부 청산 주문 (Active 중 보관, pending 슬롯과 별개) ──
    bytes32 public tpOrderKey; // Take Profit RYex 주문 키 (없으면 0)
    bytes32 public slOrderKey; // Stop Loss RYex 주문 키 (없으면 0)

    event CollateralDeposited(address indexed vault, uint256 amount);
    event CollateralWithdrawn(address indexed vault, uint256 amount);
    event PositionOpenRequested(address indexed vault, bytes32 orderKey, uint8 leverage, bool isLong);
    event PositionOpened(address indexed vault, bytes32 posKey);
    event PositionOpenFailed(address indexed vault, bytes32 orderKey);
    event PositionCloseRequested(address indexed vault, bytes32 orderKey, uint8 kind);
    event TakeProfitSet(address indexed vault, bytes32 orderKey, uint256 triggerPrice8);
    event StopLossSet(address indexed vault, bytes32 orderKey, uint256 triggerPrice8);
    event ConditionalOrderCancelled(address indexed vault, bytes32 orderKey, uint8 kind);
    event Closed(address indexed vault, uint256 returned);
    event RBTCMinted(address indexed vault, uint256 amount);
    event RBTCRepaid(address indexed vault, uint256 amount);
    event Liquidated(address indexed vault, uint256 debtRepaidUsdc, uint256 refundUsdc, uint256 keeperBountyUsdc);
    event BadDebt(address indexed vault, uint256 shortfallUsdc);
    event StuckOrderRecovered(address indexed vault, bytes32 orderKey);
    event FeesSettled(address indexed vault, uint256 toTreasuryUsdc);
    event Redeemed(address indexed vault, address indexed redeemer, uint256 rTokenAmount, uint256 usdcOut, uint256 feeUsdc);
    event RedeemRequested(address indexed vault, address indexed redeemer, bytes32 orderKey, uint256 rTokenAmount);

    error NotOwner();
    error NotGmx();
    error BadState();
    error BadKey();
    error InsufficientExecFee();
    error BelowMinCollateral();
    error ExceedsMaxLTV();
    error NotLiquidatable();
    error OutstandingDebt();
    error NotTimedOut();
    error BadLeverage();
    error NotRedeemable();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyGmx() {
        if (msg.sender != address(gmx)) revert NotGmx();
        _;
    }

    modifier notPaused() {
        if (IVaultFactory(factory).paused()) revert BadState();
        _;
    }

    constructor() {
        _disableInitializers(); // 로직 컨트랙트 초기화 차단
    }

    function initialize(
        address owner_,
        address factory_,
        IGmxAdapter gmx_,
        IPriceOracle oracle_,
        address usdc_,
        address rToken_,
        bytes32 marketId_,
        RiskParams calldata risk
    ) external initializer {
        owner = owner_;
        factory = factory_;
        gmx = gmx_;
        oracle = oracle_;
        usdc = IERC20(usdc_);
        rToken = IRToken(rToken_);
        marketId = marketId_;
        maxLtv1xBps = risk.maxLtv1xBps;
        bufferBps = risk.bufferBps;
        maxLtvAtMaxLevBps = risk.maxLtvAtMaxLevBps;
        flatTier = risk.flatTier;
        maxLeverage = risk.maxLeverage;
        state = VaultState.Empty;
    }

    // ── 사용자 동작 ──

    function deposit(uint256 usdcAmount) external onlyOwner notPaused nonReentrant {
        if (state != VaultState.Empty && state != VaultState.Active) revert BadState();
        usdc.safeTransferFrom(owner, address(this), usdcAmount);
        collateral += usdcAmount;
        emit CollateralDeposited(address(this), usdcAmount);
        _notifyFactory(int256(usdcAmount));
    }

    /// @notice Empty 상태에서 잉여 collateral을 owner에게 반환.
    ///         포지션 미오픈 상태에서만 허용 (Active 불가).
    function withdraw(uint256 usdcAmount) external onlyOwner notPaused nonReentrant {
        if (state != VaultState.Empty) revert BadState();
        require(usdcAmount <= collateral, "exceed collateral");
        collateral -= usdcAmount;
        usdc.safeTransfer(owner, usdcAmount);
        emit CollateralWithdrawn(address(this), usdcAmount);
        _notifyFactory(-int256(usdcAmount));
    }

    /// @notice 시장가 포지션 오픈. leverage 1×–maxLeverage (Litepaper §5.1).
    /// @param leverage_ 레버리지 배율 (1 ~ maxLeverage)
    /// @param isLong_   true=롱, false=숏
    /// @dev  가격은 내부적으로 oracle.getPrice() (8 decimals, Chainlink 표준) 로 읽어
    ///       어댑터가 GMX 30-decimal 포맷(× 10^22)으로 변환한다. 호출자는 신경 쓸 필요 없음.
    function openPosition(uint8 leverage_, bool isLong_) external payable onlyOwner notPaused nonReentrant {
        if (state != VaultState.Empty) revert BadState();
        if (collateral < MIN_COLLATERAL) revert BelowMinCollateral();
        if (leverage_ < 1 || leverage_ > maxLeverage) revert BadLeverage();
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee();
        leverage = leverage_;
        isLong = isLong_;
        usdc.forceApprove(address(gmx), collateral);
        bytes32 key = gmx.createOpenOrder{value: msg.value}(marketId, collateral, oracle.getPrice(), leverage_, isLong_);
        state = VaultState.SettlingOpen;
        pending = PendingOrder(OrderKind.Open, key, block.timestamp);
        emit PositionOpenRequested(address(this), key, leverage_, isLong_);
    }

    /// @notice 지정가(limit) 포지션 오픈.
    ///         롱 limit: triggerPrice8 이하로 가격이 내려올 때 GMX keeper 체결.
    ///         숏 limit: triggerPrice8 이상으로 가격이 올라올 때 GMX keeper 체결.
    ///         취소는 cancelLimitOrder() — cancelStuckOrder() 타임아웃 적용 안 됨.
    /// @param leverage_     레버리지 배율 (1 ~ maxLeverage)
    /// @param triggerPrice8 체결 원하는 가격. **8 decimals (Chainlink 표준)**:
    ///                      예) $1,650 → 165_000_000_000 (= 1650 × 10^8).
    ///                      어댑터 내부에서 GMX 30-decimal(× 10^22)로 자동 변환.
    /// @param isLong_       true=롱 limit buy, false=숏 limit sell
    function openLimitPosition(uint8 leverage_, uint256 triggerPrice8, bool isLong_)
        external
        payable
        onlyOwner
        notPaused
        nonReentrant
    {
        if (state != VaultState.Empty) revert BadState();
        if (collateral < MIN_COLLATERAL) revert BelowMinCollateral();
        if (leverage_ < 1 || leverage_ > maxLeverage) revert BadLeverage();
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee();
        require(triggerPrice8 > 0, "Vault: zero limit price");
        leverage = leverage_;
        isLong = isLong_;
        usdc.forceApprove(address(gmx), collateral);
        bytes32 key = gmx.createLimitOrder{value: msg.value}(marketId, collateral, triggerPrice8, leverage_, isLong_);
        state = VaultState.SettlingOpen;
        pending = PendingOrder(OrderKind.LimitOpen, key, block.timestamp);
        emit PositionOpenRequested(address(this), key, leverage_, isLong_);
    }

    /// @notice 미체결 limit open 주문을 취소 요청한다.
    ///         GMX keeper가 취소를 처리하면:
    ///         1. USDC가 어댑터로 반환
    ///         2. 누구든 adapter.settleGmxOrder(gmxKey)를 호출 → afterOrderCancellation → Empty 복귀
    function cancelLimitOrder() external onlyOwner nonReentrant {
        if (state != VaultState.SettlingOpen) revert BadState();
        if (pending.kind != OrderKind.LimitOpen) revert BadState();
        gmx.requestCancellation(pending.orderKey);
        // SettlingOpen 유지 — GMX keeper 처리 후 settleGmxOrder(gmxKey) 호출로 Empty 전환
    }

    function mint(uint256 rBtcAmount) external onlyOwner notPaused nonReentrant {
        if (state != VaultState.Active) revert BadState();
        if (pending.kind != OrderKind.None) revert BadState();
        require(rBtcAmount > 0, "zero mint");
        _accrueBorrow(); // 기존 부채에 대한 borrow fee 먼저 적립
        uint256 effMaxLtv = effectiveMaxLtvBps(); // 레버리지 곡선 §5.1
        if (effMaxLtv == 0) revert ExceedsMaxLTV(); // 최대배율 mint 금지(§10.1)
        uint256 newDebt = debt + rBtcAmount;
        uint256 ltv = LTVMath.currentLTV(collateralValueUsdWad(), Units.btcToUsdWad(newDebt, oracle.getPrice()));
        if (!LTVMath.isMintAllowed(ltv, effMaxLtv)) revert ExceedsMaxLTV(); // I3/D3
        // mint fee 0.25% — 발행 USD가치 기준, USDC로 누적(§7.1)
        accruedFeesUsdc += (Units.wadToUsdc(Units.btcToUsdWad(rBtcAmount, oracle.getPrice())) * MINT_FEE_BPS) / BPS;
        debt = newDebt;
        rToken.mint(owner, rBtcAmount); // D2: owner EOA
        emit RBTCMinted(address(this), rBtcAmount);
    }

    /// @notice 부채 상환 — owner EOA의 rBTC를 burn하고 Vault.debt 감소(mint의 역연산, docs/11 D4).
    function repay(uint256 rBtcAmount) external onlyOwner notPaused nonReentrant {
        if (state != VaultState.Active) revert BadState();
        uint256 amt = rBtcAmount > debt ? debt : rBtcAmount;
        require(amt > 0, "nothing to repay");
        _accrueBorrow(); // 적립 후 상환
        // redeem fee 0.25% — 상환 USD가치 기준, USDC로 누적(§7.1)
        accruedFeesUsdc += (Units.wadToUsdc(Units.btcToUsdWad(amt, oracle.getPrice())) * REDEEM_FEE_BPS) / BPS;
        debt -= amt;
        rToken.burn(owner, amt); // D1: Vault만 burn. owner 잔액 부족 시 revert.
        emit RBTCRepaid(address(this), amt);
    }

    function closePosition() external payable onlyOwner notPaused nonReentrant {
        if (state != VaultState.Active) revert BadState();
        if (pending.kind != OrderKind.None) revert BadState();
        if (debt != 0) revert OutstandingDebt(); // OQ-5: 부채 전액 상환 후에만
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee();
        bytes32 key = gmx.createCloseOrder{value: msg.value}(posKey);
        state = VaultState.SettlingLiquidate;
        pending = PendingOrder(OrderKind.Close, key, block.timestamp);
        emit PositionCloseRequested(address(this), key, uint8(OrderKind.Close));
    }

    /// @notice 익절(Take Profit) 주문 설정 / 갱신. Active 상태에서만 가능.
    ///         롱 TP: triggerPrice8 이상으로 가격이 오를 때 전량 청산.
    ///         숏 TP: triggerPrice8 이하로 가격이 내릴 때 전량 청산.
    ///         기존 TP가 있으면 덮어쓴다(GMX 구 주문은 stale 상태로 남음 — 직접 취소 필요).
    /// @param triggerPrice8 익절 목표 가격. **8 decimals**: 예) $2,000 → 200_000_000_000.
    function setTakeProfit(uint256 triggerPrice8) external payable onlyOwner notPaused nonReentrant {
        if (state != VaultState.Active) revert BadState();
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee();
        require(triggerPrice8 > 0, "Vault: zero TP price");
        bytes32 key = gmx.createTakeProfit{value: msg.value}(posKey, triggerPrice8);
        tpOrderKey = key;
        emit TakeProfitSet(address(this), key, triggerPrice8);
    }

    /// @notice 손절(Stop Loss) 주문 설정 / 갱신. Active 상태에서만 가능.
    ///         롱 SL: triggerPrice8 이하로 가격이 내릴 때 전량 청산.
    ///         숏 SL: triggerPrice8 이상으로 가격이 오를 때 전량 청산.
    /// @param triggerPrice8 손절 기준 가격. **8 decimals**: 예) $1,200 → 120_000_000_000.
    function setStopLoss(uint256 triggerPrice8) external payable onlyOwner notPaused nonReentrant {
        if (state != VaultState.Active) revert BadState();
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee();
        require(triggerPrice8 > 0, "Vault: zero SL price");
        bytes32 key = gmx.createStopLoss{value: msg.value}(posKey, triggerPrice8);
        slOrderKey = key;
        emit StopLossSet(address(this), key, triggerPrice8);
    }

    /// @notice TP 주문 취소 (GMX에 취소 요청 전송).
    function cancelTakeProfit() external onlyOwner nonReentrant {
        bytes32 key = tpOrderKey;
        require(key != bytes32(0), "Vault: no TP order");
        tpOrderKey = bytes32(0);
        gmx.requestCancellation(key);
        emit ConditionalOrderCancelled(address(this), key, uint8(OrderKind.TakeProfit));
    }

    /// @notice SL 주문 취소 (GMX에 취소 요청 전송).
    function cancelStopLoss() external onlyOwner nonReentrant {
        bytes32 key = slOrderKey;
        require(key != bytes32(0), "Vault: no SL order");
        slOrderKey = bytes32(0);
        gmx.requestCancellation(key);
        emit ConditionalOrderCancelled(address(this), key, uint8(OrderKind.StopLoss));
    }

    /// @notice 청산(LLTV 백스톱). pause 중에도 허용(탈출 경로, docs/70 §5).
    function liquidate() external payable nonReentrant {
        if (state != VaultState.Active) revert BadState();
        if (pending.kind != OrderKind.None) revert BadState();
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee();
        uint256 ltv = currentLTV();
        if (!LTVMath.isLiquidatable(ltv, lltvBps())) revert NotLiquidatable(); // L1/I4
        liquidator = msg.sender;
        bytes32 key = gmx.createCloseOrder{value: msg.value}(posKey);
        state = VaultState.SettlingLiquidate;
        pending = PendingOrder(OrderKind.Liquidate, key, block.timestamp);
        emit PositionCloseRequested(address(this), key, uint8(OrderKind.Liquidate));
    }

    /// @notice RLT 상환 (Litepaper §4.5/§5.3). 상환존(RLT<=ltv<LLTV)에서 누구나 rToken을 제출해
    ///         oracle가로 부채를 줄이고, GMX partial decrease 후 회수 USDC(−redeem fee)를 받는다. 페널티 없음.
    /// @dev rToken은 escrow 후 GMX 체결 시 burn. GMX 취소 시 redeemer에게 반환.
    ///      인센티브: AMM 할인 매수 rToken → oracle가 상환 스프레드.
    function redeem(uint256 rTokenAmount) external payable nonReentrant {
        if (state != VaultState.Active) revert BadState();
        if (pending.kind != OrderKind.None) revert BadState();
        if (!LTVMath.inRedemptionZone(currentLTV(), rltBps(), lltvBps())) revert NotRedeemable();
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee();
        uint256 amt = rTokenAmount > debt ? debt : rTokenAmount;
        require(amt > 0, "zero redeem");
        _accrueBorrow();
        uint256 redeemUsdc = Units.wadToUsdc(Units.btcToUsdWad(amt, oracle.getPrice()));
        IERC20(address(rToken)).safeTransferFrom(msg.sender, address(this), amt);
        pendingRedeemer = msg.sender;
        pendingRedeemAmt = amt;
        pendingRedeemUsdcSnap = usdc.balanceOf(address(this));
        (bytes32 key, uint256 paid) = gmx.createRedeemOrder{value: msg.value}(posKey, redeemUsdc);
        pending = PendingOrder(OrderKind.Redeem, key, block.timestamp);
        emit RedeemRequested(address(this), msg.sender, key, amt);
        if (paid > 0) _settleRedeem(); // mock-only 즉시 정산
    }

    /// @notice Settling 멈춤 복구 (docs/60 OQ-6). 정산 행이 안 올 때 탈출.
    ///         LimitOpen 주문은 cancelLimitOrder()를 사용. Redeem 대기는 타임아웃 후 rToken 반환.
    function cancelStuckOrder() external {
        if (state == VaultState.Active && pending.kind == OrderKind.Redeem) {
            if (block.timestamp <= pending.createdAt + SETTLING_TIMEOUT) revert NotTimedOut();
            bytes32 key = pending.orderKey;
            _cancelPendingRedeem();
            emit StuckOrderRecovered(address(this), key);
            return;
        }
        VaultState s = state;
        if (s != VaultState.SettlingLiquidate && s != VaultState.SettlingOpen) revert BadState();
        if (pending.kind == OrderKind.LimitOpen) revert BadState(); // limit은 cancelLimitOrder() 사용
        if (block.timestamp <= pending.createdAt + SETTLING_TIMEOUT) revert NotTimedOut();
        bytes32 key = pending.orderKey;
        delete pending;
        if (s == VaultState.SettlingLiquidate) {
            state = VaultState.Active;
        } else {
            uint256 prev = collateral;
            collateral = usdc.balanceOf(address(this));
            if (collateral != prev) {
                _notifyFactory(int256(collateral) - int256(prev));
            }
            state = VaultState.Empty;
        }
        emit StuckOrderRecovered(address(this), key);
    }

    // ── GMX 콜백 ──

    function afterOrderExecution(bytes32 orderKey) external onlyGmx nonReentrant {
        // ── TP / SL (pending 슬롯과 별도 관리) ─────────────────────────────────
        if (orderKey == tpOrderKey || orderKey == slOrderKey) {
            // 어느 쪽이 체결되든 나머지 키도 초기화 (stale GMX 주문은 owner가 직접 취소)
            tpOrderKey = bytes32(0);
            slOrderKey = bytes32(0);
            _settleClose();
            return;
        }

        // ── 일반 pending 주문 ────────────────────────────────────────────────────
        if (pending.orderKey != orderKey) revert BadKey();
        OrderKind kind = pending.kind;
        if (kind == OrderKind.Open || kind == OrderKind.LimitOpen) {
            posKey = gmx.positionKey(address(this), marketId, isLong);
            state = VaultState.Active;
            lastAccrual = block.timestamp;
            delete pending;
            emit PositionOpened(address(this), posKey);
        } else if (kind == OrderKind.Close) {
            _settleClose();
        } else if (kind == OrderKind.Redeem) {
            _settleRedeem();
        } else {
            _settleLiquidation();
        }
    }

    function afterOrderCancellation(bytes32 orderKey) external onlyGmx nonReentrant {
        if (pending.orderKey != orderKey) revert BadKey();
        if (pending.kind == OrderKind.Open || pending.kind == OrderKind.LimitOpen) {
            uint256 prev = collateral;
            collateral = usdc.balanceOf(address(this)); // GMX/어댑터가 반환한 담보 재조정
            // 반환된 USDC가 기존 담보와 다를 수 있음 (수수료 등) → 차이만큼 보정
            if (collateral != prev) {
                _notifyFactory(int256(collateral) - int256(prev));
            }
            state = VaultState.Empty;
            delete pending;
            emit PositionOpenFailed(address(this), orderKey);
        } else if (pending.kind == OrderKind.Redeem) {
            _cancelPendingRedeem();
        } else {
            state = VaultState.Active; // close/liquidate 취소 → 복귀
            delete pending;
        }
    }

    // ── factory TVL 통보 ──

    /// @notice collateral 증감분을 factory로 push → totalCollateralLocked 갱신.
    ///         실패해도 볼트 동작에 영향 없도록 try/catch로 감쌈.
    function _notifyFactory(int256 delta) internal {
        if (delta == 0) return;
        try IVaultFactory(factory).onCollateralChanged(delta) {} catch {}
    }

    // ── 수수료 적립 ──

    /// @notice 미상환 부채 달러가치에 대한 borrow fee(1.5%APR)를 USDC로 누적. debt 변경/정산 전 호출.
    /// @dev 이산 적립(touch마다 현재 가격×경과시간) — 데모 근사. 프로덕션은 가격 적분/인덱스 필요.
    function _accrueBorrow() internal {
        uint256 last = lastAccrual;
        if (last != 0) {
            uint256 dt = block.timestamp - last;
            if (dt > 0 && debt > 0) {
                uint256 debtUsdc = Units.wadToUsdc(debtValueUsdWad());
                accruedFeesUsdc += (debtUsdc * BORROW_FEE_APR_BPS * dt) / (BPS * SECONDS_PER_YEAR);
            }
        }
        lastAccrual = block.timestamp;
    }

    // ── 정산 (CEI: 효과 먼저, 외부호출 나중) ──

    function _settleRedeem() internal {
        uint256 amt = pendingRedeemAmt;
        address redeemer = pendingRedeemer;
        require(amt > 0 && redeemer != address(0), "bad redeem");

        _accrueBorrow();
        uint256 bal = usdc.balanceOf(address(this));
        uint256 snap = pendingRedeemUsdcSnap;
        uint256 recovered = bal > snap ? bal - snap : 0;
        debt -= amt;
        rToken.burn(address(this), amt);

        pendingRedeemer = address(0);
        pendingRedeemAmt = 0;
        pendingRedeemUsdcSnap = 0;
        delete pending;

        uint256 fee = (recovered * REDEEM_FEE_BPS) / BPS;
        if (fee > recovered) fee = recovered;
        if (fee > 0) usdc.safeTransfer(factory, fee);
        uint256 toRedeemer = recovered - fee;
        if (toRedeemer > 0) usdc.safeTransfer(redeemer, toRedeemer);
        emit Redeemed(address(this), redeemer, amt, recovered, fee);
    }

    function _cancelPendingRedeem() internal {
        uint256 amt = pendingRedeemAmt;
        address redeemer = pendingRedeemer;
        pendingRedeemer = address(0);
        pendingRedeemAmt = 0;
        pendingRedeemUsdcSnap = 0;
        delete pending;
        if (amt > 0 && redeemer != address(0)) IERC20(address(rToken)).safeTransfer(redeemer, amt);
    }

    function _settleClose() internal {
        _accrueBorrow();
        uint256 recovered = usdc.balanceOf(address(this));
        uint256 fees = accruedFeesUsdc > recovered ? recovered : accruedFeesUsdc;
        uint256 toOwner = recovered - fees;
        uint256 prevCollateral = collateral;
        collateral = 0;
        _notifyFactory(-int256(prevCollateral));
        posKey = bytes32(0);
        accruedFeesUsdc = 0;
        tpOrderKey = bytes32(0);
        slOrderKey = bytes32(0);
        state = VaultState.Empty;
        delete pending;
        if (fees > 0) usdc.safeTransfer(factory, fees); // treasury
        if (toOwner > 0) usdc.safeTransfer(owner, toOwner);
        emit FeesSettled(address(this), fees);
        emit Closed(address(this), toOwner);
    }

    function _settleLiquidation() internal {
        _accrueBorrow();
        uint256 recovered = usdc.balanceOf(address(this));
        uint256 debtUsdc = Units.wadToUsdc(debtValueUsdWad());
        uint256 repayUsdc = recovered >= debtUsdc ? debtUsdc : recovered;
        uint256 afterDebt = recovered - repayUsdc; // residual equity after repaying debt
        // 정산 순서(§7): 부채 → 수수료(treasury) → 페널티(잔여 equity의 10%, §7.1) → 환불(owner).
        uint256 fees = accruedFeesUsdc > afterDebt ? afterDebt : accruedFeesUsdc;
        uint256 afterFees = afterDebt - fees;
        uint256 penalty = (afterFees * LIQ_PENALTY_BPS) / BPS;
        uint256 refund = afterFees - penalty;

        address _owner = owner;
        address _liq = liquidator;
        uint256 prevCollateral = collateral;
        debt = 0;
        collateral = 0;
        _notifyFactory(-int256(prevCollateral));
        posKey = bytes32(0);
        accruedFeesUsdc = 0;
        tpOrderKey = bytes32(0);
        slOrderKey = bytes32(0);
        state = VaultState.Empty; // I1: 동일 (user×market) 볼트 재사용. 이력은 Liquidated 이벤트로 보존.
        delete pending;

        uint256 keeperBounty;
        {
            // 부채상환분(repayUsdc)도 protocol treasury(=factory)로 보낸다(Vault에 stranded 방지).
            // OQ-1(a) 데모: rToken을 burn하지 않으므로 이 USDC가 유통 rToken을 backing. P5 리저브가 buy+burn 예정.
            uint256 toLiq = (penalty * PENALTY_LIQ_SHARE_BPS) / BPS; // 청산자(keeper) 보상 — §10.4는 미명시, 데모 인센티브
            keeperBounty = toLiq;
            uint256 toTreasury = repayUsdc + fees + (penalty - toLiq);
            if (toLiq > 0) usdc.safeTransfer(_liq, toLiq);
            if (toTreasury > 0) usdc.safeTransfer(factory, toTreasury); // factory.sweepFees로 회수
        }
        if (refund > 0) usdc.safeTransfer(_owner, refund); // I5
        emit FeesSettled(address(this), fees);
        emit Liquidated(address(this), repayUsdc, refund, keeperBounty);
        if (debtUsdc > repayUsdc) emit BadDebt(address(this), debtUsdc - repayUsdc); // bad debt (OQ-4)
    }

    // ── 조회 ──

    /// @notice LLTV(bps) = MaxLTV(1×) + Buffer. Litepaper §5.2.
    function lltvBps() public view returns (uint256) {
        return LTVMath.lltvFromMaxLtv(maxLtv1xBps, bufferBps);
    }

    /// @notice RLT(상환 임계, bps) = MaxLTV(1×). Litepaper §5.3.
    function rltBps() public view returns (uint256) {
        return LTVMath.rltFromMaxLtv(maxLtv1xBps);
    }

    /// @notice 현재 레버리지에서의 유효 MaxLTV(bps). 곡선 §5.1. open 전(leverage==0)이면 1× 기준.
    function effectiveMaxLtvBps() public view returns (uint256) {
        uint8 lev = leverage == 0 ? 1 : leverage;
        return LTVMath.maxLtvForLeverage(maxLtv1xBps, maxLtvAtMaxLevBps, lev, flatTier, maxLeverage);
    }

    /// @notice 상환 가능 여부: Active 이고 RLT<=ltv<LLTV (상환존). 청산존과 상호배타.
    function isRedeemable() public view returns (bool) {
        return state == VaultState.Active && LTVMath.inRedemptionZone(currentLTV(), rltBps(), lltvBps());
    }

    /// @return USD 18-dec WAD. Active 시 oracle 8-dec 기반 포지션 순가치; Empty 시 USDC 잔액 환산.
    function collateralValueUsdWad() public view returns (uint256) {
        if ((state == VaultState.Active || state == VaultState.SettlingLiquidate) && posKey != bytes32(0)) {
            return gmx.getPositionValueUsd(posKey); // OQ-2 하이브리드: 포지션 가치=GMX
        }
        return Units.usdcToWad(collateral);
    }

    /// @return USD 18-dec WAD. debt(rToken 18-dec) × oracle.getPrice() (8-dec).
    function debtValueUsdWad() public view returns (uint256) {
        return Units.btcToUsdWad(debt, oracle.getPrice());
    }

    function currentLTV() public view returns (uint256) {
        if (debt == 0) return 0;
        uint256 col = collateralValueUsdWad();
        // 담보 전소(equity=0): 최대 위험 → 청산 가능. revert 시 underwater vault가 영구 stuck(G1/G6).
        if (col == 0) return type(uint256).max;
        return LTVMath.currentLTV(col, debtValueUsdWad());
    }

    function healthFactor() external view returns (uint256) {
        return LTVMath.healthFactor(currentLTV(), lltvBps());
    }

    /// @notice GMX 포지션 데이터를 어댑터를 통해 온체인에서 직접 조회해 반환한다.
    ///         GmxV2Adapter: GMX v2 Reader.getPosition 호출 → 실제 온체인 데이터.
    /// @dev    passthrough 뷰 — GMX 필드는 **8dec로 변환하지 않음**:
    ///         sizeInUsd        → 30-dec (formatUnits(v, 30))
    ///         collateralAmount → 6-dec USDC (formatUnits(v, 6))
    ///         entryPrice8      → 8-dec (mock만; 실 GMX는 0)
    ///         exists = false 이면 포지션이 아직 없거나 이미 청산된 것.
    function gmxPosition() external view returns (IGmxAdapter.GmxPositionData memory) {
        return gmx.gmxPositionData(address(this), marketId, isLong);
    }

    /// @notice 볼트 전체 상태를 단일 eth_call로 반환. UI/인덱서용 통합 스냅샷.
    /// @dev 금액 decimals — VaultSnapshot struct 주석 참고.
    ///      RYex LTV/민트 한도: collateralValueUsdWad·oraclePrice8 (8dec→WAD).
    ///      GMX 포지션 표시: gmx.sizeInUsd (30dec passthrough).
    function vaultInfo() external view returns (VaultSnapshot memory s) {
        uint256 lltv = lltvBps();
        uint256 rlt = rltBps();
        uint256 colWad = collateralValueUsdWad();
        uint256 debtWad = debtValueUsdWad();
        uint256 ltv = _ltvFromValues(colWad, debtWad);

        IGmxAdapter.GmxPositionData memory gmxData = gmx.gmxPositionData(address(this), marketId, isLong);

        s.owner = owner;
        s.marketId = marketId;
        s.state = state;
        s.leverage = leverage;
        s.isLong = isLong;
        s.posKey = posKey;
        s.collateralUsdc = collateral;
        s.debtRToken = debt;
        s.pendingKind = pending.kind;
        s.pendingOrderKey = pending.orderKey;
        s.pendingCreatedAt = pending.createdAt;
        s.maxLtv1xBps = maxLtv1xBps;
        s.bufferBps = bufferBps;
        s.maxLtvAtMaxLevBps = maxLtvAtMaxLevBps;
        s.flatTier = flatTier;
        s.maxLeverage = maxLeverage;
        s.collateralValueUsdWad = colWad;
        s.debtValueUsdWad = debtWad;
        s.currentLtvBps = ltv;
        s.healthFactorWad = LTVMath.healthFactor(ltv, lltv);
        s.lltvBps = lltv;
        s.rltBps = rlt;
        s.effectiveMaxLtvBps = effectiveMaxLtvBps();
        s.oraclePrice8 = oracle.getPrice();
        s.pendingFeesUsdc = pendingFeesUsdc();
        s.isRedeemable = state == VaultState.Active && LTVMath.inRedemptionZone(ltv, rlt, lltv);
        s.isLiquidatable = state == VaultState.Active && LTVMath.isLiquidatable(ltv, lltv);
        s.tpOrderKey = tpOrderKey;
        s.slOrderKey = slOrderKey;
        s.gmx = VaultGmxPosition({
            exists: gmxData.exists,
            sizeInUsd: gmxData.sizeInUsd,
            collateralAmount: gmxData.collateralAmount,
            entryPrice8: gmxData.entryPrice8
        });
    }

    /// @dev currentLTV()와 동일 로직. vaultInfo() 내부에서 중복 계산 방지.
    function _ltvFromValues(uint256 colWad, uint256 debtWad) internal view returns (uint256) {
        if (debt == 0) return 0;
        if (colWad == 0) return type(uint256).max;
        return LTVMath.currentLTV(colWad, debtWad);
    }

    /// @notice 현재까지 발생한 총 수수료(USDC) = 누적 + 미적립 borrow fee. UI/정산 미리보기용.
    function pendingFeesUsdc() public view returns (uint256) {
        uint256 fee = accruedFeesUsdc;
        uint256 last = lastAccrual;
        if (last != 0 && debt > 0) {
            uint256 dt = block.timestamp - last;
            fee += (Units.wadToUsdc(debtValueUsdWad()) * BORROW_FEE_APR_BPS * dt) / (BPS * SECONDS_PER_YEAR);
        }
        return fee;
    }

    receive() external payable {} // GMX exec fee 환불 수령
}
