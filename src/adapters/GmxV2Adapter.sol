// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IGmxAdapter} from "../interfaces/IGmxAdapter.sol";
import {IGmxReader} from "../interfaces/IGmxReader.sol";
import {IGmxExchangeRouter} from "../interfaces/IGmxExchangeRouter.sol";
import {IGmxOrderCallbackReceiver} from "../interfaces/IGmxOrderCallbackReceiver.sol";
import {IPositionVault} from "../interfaces/IPositionVault.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {Units} from "../libraries/Units.sol";

/// @title GmxV2Adapter — GMX v2 adapter: REAL GMX custody + mock-oracle mark (docs/50 §3).
/// @notice Implements IGmxAdapter with a permissionless settlement model:
///         once GMX processes an order (fill or cancel), anyone can call settleGmxOrder(gmxKey)
///         to transition the vault state — no separate off-chain executor required.
///
///         Settlement security:
///         1. DataStore containsBytes32 — verifies GMX actually processed the order (cannot
///            be called before GMX removes it from the order list).
///         2. Reader getPosition — auto-detects fill vs cancel based on position existence.
///
///         executeOrder / cancelOrder remain as owner-only emergency fallback paths.
///
///         GMX 자동 콜백:
///         callbackContract = address(this) 로 설정 시 GMX OrderHandler가
///         주문 체결/취소 후 afterOrderExecution / afterOrderCancellation 을 직접 호출.
///         별도 keeper 없이도 Vault 상태가 자동으로 Active / Empty 로 전환된다.
contract GmxV2Adapter is IGmxAdapter, IGmxOrderCallbackReceiver, Ownable {
    using SafeERC20 for IERC20;

    // ── GMX v2 Arbitrum Sepolia wiring (immutable) ──
    IERC20 public immutable usdc; // GMX testnet USDC (also the RYex vault collateral in A1)
    IGmxExchangeRouter public immutable exchangeRouter;
    address public immutable gmxRouter; // approve target for sendTokens/pluginTransfer
    address public immutable orderVault; // receives WNT exec-fee + USDC collateral
    IGmxReader public immutable reader;  // GMX v2 Reader — 포지션 온체인 조회 (address(0) = mock 모드)
    address public immutable dataStore;  // GMX v2 DataStore — Reader 호출 시 전달

    uint8 internal constant ORDER_MARKET_INCREASE   = 2;
    uint8 internal constant ORDER_LIMIT_INCREASE    = 3; // 지정가 open
    uint8 internal constant ORDER_MARKET_DECREASE   = 4;
    uint8 internal constant ORDER_LIMIT_DECREASE    = 5; // Take Profit
    uint8 internal constant ORDER_STOP_LOSS         = 6; // Stop Loss

    /// @dev limit open 주문의 acceptable price 슬리피지 (trigger 기준 +1%).
    ///      long limit buy: price가 trigger 아래로 내려올 때 체결. acceptablePrice = trigger × (1 + slippage).
    uint256 internal constant LIMIT_SLIPPAGE_BPS = 100; // 1%

    // ── tunables (owner) ──
    uint256 public execFee = 0.005 ether; // WNT exec-fee per order (콜백 가스 포함 여유분); GMX refunds excess
    // acceptablePrice 의미 (GMX v2: 가격 포맷 = price_usd × 1e30):
    //   Increase(open): MAX = 롱 open 허용 최고가 / MIN = 숏 open 허용 최저가
    //   Decrease(close): MIN = 롱 close 허용 최저가 / MAX = 숏 close 허용 최고가
    // type(uint256).max = "어떤 가격이든 체결 OK (상한 없음)"
    // 1 = "어떤 가격이든 체결 OK (하한 없음, $1e-30 이상)"
    uint256 public acceptablePriceMax = type(uint256).max; // 롱 open / 숏 close: 상한 없음
    uint256 public acceptablePriceMin = 1;                 // 숏 open / 롱 close: 하한 없음

    // GMX DataStore account-order list key prefix: keccak256("ACCOUNT_ORDER_LIST")
    bytes32 internal constant ACCOUNT_ORDER_LIST = keccak256("ACCOUNT_ORDER_LIST");

    // GMX 콜백에 할당할 가스 한도. 콜백이 실패해도 GMX 주문 실행에는 영향 없음.
    // _settleCallback: SLOAD × 4 + SSTORE × 3 + USDC transfer + vault call ≈ 250k gas.
    // 여유분 포함 500k 설정.
    uint256 internal constant CALLBACK_GAS_LIMIT = 500_000;

    struct Position {
        address vault;
        uint256 collateral; // mock USDC accounting (6dec) — drives mock-mark value
        uint256 entryPrice8;
        bytes32 marketId;
        uint256 leverage;
        uint256 gmxSizeUsd; // the real GMX position size (30dec USD) opened — for full close
        bool active;
        bool isLong;        // 롱(true) / 숏(false)
    }

    struct Order {
        address vault;
        uint8 kind; // 1=Open, 2=Close, 3=TP/SL, 4=Redeem (partial decrease)
        bytes32 positionKey;
        bytes32 gmxKey; // the real GMX order key (tracing / cancel detection)
        bool executed;
        uint256 redeemUsdc; // kind 4: oracle USDC value for proportional sizing
        uint256 usdcSnap;   // kind 4: adapter USDC balance before GMX order
    }

    mapping(bytes32 => IPriceOracle) public marketOracle; // marketId => mock oracle (mock-mark)
    mapping(bytes32 => address) public gmxMarketOf; // marketId => GMX market token (real leg)
    mapping(bytes32 => Position) public positions; // positionKey => position
    mapping(bytes32 => Order) public orders; // ryexKey => order
    mapping(bytes32 => bytes32) public gmxKeyToRyexKey; // gmxKey → ryexKey (콜백/permissionless 역조회)
    uint256 private _nonce;
    bytes32 public lastOrderKey;

    // GMX v2 OrderHandler 주소 (Arbitrum Sepolia: 0x000F692690F6C39660AfB878D277f038fb3a8eC6)
    // 콜백 호출자 검증에 사용. address(0) = 검증 없음(비권장, 테스트 전용)
    address public gmxOrderHandler;

    event MarketRegistered(bytes32 indexed marketId, address oracle, address gmxMarket);
    event OrderCreated(bytes32 indexed orderKey, address indexed vault, uint8 kind, bytes32 gmxKey);
    event OrderExecuted(bytes32 indexed orderKey, bytes32 gmxKey);
    event OrderCancelled(bytes32 indexed orderKey, bytes32 gmxKey);

    constructor(
        IERC20 usdc_,
        IGmxExchangeRouter exchangeRouter_,
        address gmxRouter_,
        address orderVault_,
        address reader_,         // GMX v2 Reader 주소 (address(0) → mock-only 모드)
        address dataStore_,      // GMX v2 DataStore 주소
        address gmxOrderHandler_, // GMX OrderHandler 주소 (콜백 호출자 검증)
        address owner_
    ) payable Ownable(owner_) {
        usdc = usdc_;
        exchangeRouter = exchangeRouter_;
        gmxRouter = gmxRouter_;
        orderVault = orderVault_;
        reader = IGmxReader(reader_);
        dataStore = dataStore_;
        gmxOrderHandler = gmxOrderHandler_;
        // GMX Router pulls collateral via pluginTransfer → approve once (max).
        usdc_.forceApprove(gmxRouter_, type(uint256).max);
    }

    receive() external payable {} // owner funds ETH for exec-fees / GMX refunds land here

    // ── config (owner) ──

    /// @notice Wire a RYex market to its mock oracle (mock-mark) and its GMX market token (real leg).
    function registerMarket(bytes32 marketId, IPriceOracle oracle, address gmxMarket) external onlyOwner {
        marketOracle[marketId] = oracle;
        gmxMarketOf[marketId] = gmxMarket;
        emit MarketRegistered(marketId, address(oracle), gmxMarket);
    }

    function setExecFee(uint256 fee) external onlyOwner {
        execFee = fee;
    }

    function setAcceptablePrices(uint256 max_, uint256 min_) external onlyOwner {
        acceptablePriceMax = max_;
        acceptablePriceMin = min_;
    }

    function setGmxOrderHandler(address handler_) external onlyOwner {
        gmxOrderHandler = handler_;
    }

    /// @notice Owner manages the adapter's real funds (USDC buffer / ETH for fees). No vault funds here.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "eth send");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ── IGmxAdapter ──

    function positionKey(address account, bytes32 marketId, bool isLong) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, marketId, isLong));
    }

    /// @notice GMX 포지션 데이터를 온체인에서 직접 조회한다.
    ///         reader가 설정된 경우: GMX v2 Reader.getPosition 호출 → 실제 온체인 데이터 반환.
    ///         reader == address(0): 내부 mock 회계(positions 매핑)를 그대로 반환.
    /// @dev    GMX 포지션 account = address(this) (Adapter가 ExchangeRouter를 직접 호출하므로).
    ///         positionKey(GMX) = keccak256(abi.encode(account, market, collateralToken, isLong))
    ///         **조회 시 30dec→8dec 변환 없음** — sizeInUsd는 GMX 원본(30-dec) 그대로 반환.
    ///         RYex LTV(getPositionValueUsd)는 oracle 8-dec 기반 별도 회계.
    function gmxPositionData(address vault, bytes32 marketId, bool isLong)
        external
        view
        returns (IGmxAdapter.GmxPositionData memory data)
    {
        address gmxMarket = gmxMarketOf[marketId];

        // ── Real GMX path ──────────────────────────────────────────────────────
        if (gmxMarket != address(0) && address(reader) != address(0)) {
            bytes32 gmxPosKey = keccak256(abi.encode(address(this), gmxMarket, address(usdc), isLong));
            try reader.getPosition(dataStore, gmxPosKey) returns (IGmxReader.PositionProps memory pos) {
                data.exists           = pos.numbers.sizeInUsd > 0;
                data.sizeInUsd        = pos.numbers.sizeInUsd;
                data.collateralAmount = pos.numbers.collateralAmount;
                data.entryPrice8      = 0; // GMX Reader는 진입 가격을 직접 노출하지 않음
            } catch {
                _fillFromMock(vault, marketId, isLong, data);
            }
            return data;
        }

        // ── Mock fallback ──────────────────────────────────────────────────────
        _fillFromMock(vault, marketId, isLong, data);
    }

    function _fillFromMock(address vault, bytes32 marketId, bool isLong, IGmxAdapter.GmxPositionData memory data)
        internal
        view
    {
        bytes32 pk = positionKey(vault, marketId, isLong);
        Position memory p = positions[pk];
        data.exists           = p.active;
        data.sizeInUsd        = p.active ? p.gmxSizeUsd : 0;
        data.collateralAmount = p.collateral;
        data.entryPrice8      = p.entryPrice8;
    }

    function _newOrderKey(address vault) internal returns (bytes32 k) {
        k = keccak256(abi.encodePacked(vault, _nonce, block.number));
        _nonce++;
        lastOrderKey = k;
    }

    /// @notice 시장가 포지션 오픈 주문. GMX market price로 즉시 체결 (~10s).
    /// @param indexPrice8 현재 자산 가격. **8 decimals (Chainlink 표준)**:
    ///                    예) $1,650 → 165_000_000_000. 내부에서 GMX 30-decimal(× 10^22)로 변환.
    function createOpenOrder(
        bytes32 marketId,
        uint256 collateralUsdc,
        uint256 indexPrice8,
        uint256 leverage,
        bool    isLong
    ) external payable returns (bytes32 orderKey) {
        return _openOrder(marketId, collateralUsdc, indexPrice8, leverage, 0, isLong);
    }

    /// @notice 지정가(limit) 포지션 오픈 주문.
    ///         롱 limit: triggerPrice8 이하로 가격이 내려올 때 GMX keeper 체결.
    ///         숏 limit: triggerPrice8 이상으로 가격이 올라올 때 GMX keeper 체결.
    /// @param triggerPrice8 체결 원하는 기준 가격. **8 decimals (Chainlink 표준)**:
    ///                      예) $1,500 → 150_000_000_000. 내부에서 × 10^22 → GMX 30-decimal 변환.
    function createLimitOrder(
        bytes32 marketId,
        uint256 collateralUsdc,
        uint256 triggerPrice8,
        uint256 leverage,
        bool    isLong
    ) external payable returns (bytes32 orderKey) {
        require(triggerPrice8 > 0, "GMX: zero trigger price");
        return _openOrder(marketId, collateralUsdc, triggerPrice8, leverage, triggerPrice8, isLong);
    }

    /// @dev 공통 open 로직. triggerPrice8 == 0 이면 MarketIncrease, > 0 이면 LimitIncrease.
    function _openOrder(
        bytes32 marketId,
        uint256 collateralUsdc,
        uint256 indexPrice8,   // market: 현재 가격, limit: trigger 가격 (mock accounting용)
        uint256 leverage,
        uint256 triggerPrice8, // 0 = market
        bool    isLong
    ) internal returns (bytes32 orderKey) {
        require(collateralUsdc > 0, "GMX: zero collateral");
        require(leverage >= 1, "GMX: bad leverage");

        usdc.safeTransferFrom(msg.sender, address(this), collateralUsdc);

        uint256 sizeUsd = collateralUsdc * 1e24 * leverage; // 6dec → 30dec × leverage
        address gmxMarket = gmxMarketOf[marketId];
        bytes32 gmxKey;
        if (gmxMarket != address(0)) {
            uint8   orderType;
            uint256 triggerPrice30;
            uint256 acceptable;
            if (triggerPrice8 == 0) {
                // 시장가: 어떤 가격이든 체결
                // 롱 open → 최고가 허용(MAX), 숏 open → 최저가 허용(MIN)
                orderType      = ORDER_MARKET_INCREASE;
                triggerPrice30 = 0;
                acceptable     = isLong ? acceptablePriceMax : acceptablePriceMin;
            } else {
                // 지정가:
                //   롱 limit buy  → trigger 이하 진입, acceptable = trigger + 1% slippage (최대 허용 상한)
                //   숏 limit sell → trigger 이상 진입, acceptable = trigger - 1% slippage (최소 허용 하한)
                orderType      = ORDER_LIMIT_INCREASE;
                triggerPrice30 = triggerPrice8 * 1e22;
                if (isLong) {
                    acceptable = triggerPrice30 * (10_000 + LIMIT_SLIPPAGE_BPS) / 10_000;
                } else {
                    acceptable = triggerPrice30 * (10_000 - LIMIT_SLIPPAGE_BPS) / 10_000;
                }
            }
            gmxKey = _createGmxOrder(gmxMarket, orderType, collateralUsdc, sizeUsd, triggerPrice30, acceptable, isLong);
        }

        bytes32 pk = positionKey(msg.sender, marketId, isLong);
        positions[pk] = Position({
            vault:       msg.sender,
            collateral:  collateralUsdc,
            entryPrice8: indexPrice8,
            marketId:    marketId,
            leverage:    leverage,
            gmxSizeUsd:  sizeUsd,
            active:      false,
            isLong:      isLong
        });
        orderKey = _newOrderKey(msg.sender);
        orders[orderKey] = Order({
            vault: msg.sender, kind: 1, positionKey: pk, gmxKey: gmxKey, executed: false,
            redeemUsdc: 0, usdcSnap: 0
        });
        if (gmxKey != bytes32(0)) gmxKeyToRyexKey[gmxKey] = orderKey;
        emit OrderCreated(orderKey, msg.sender, 1, gmxKey);
    }

    /// @notice Vault closes/liquidates. Fires a REAL GMX full-size decrease; proceeds return here.
    function createCloseOrder(bytes32 pk) external payable returns (bytes32 orderKey) {
        Position memory p = positions[pk];
        require(p.active, "GMX: no position");
        address gmxMarket = gmxMarketOf[p.marketId];
        bytes32 gmxKey;
        if (gmxMarket != address(0)) {
            // 롱 close → 최저가 허용(MIN = 어떤 가격이든 팔겠다)
            // 숏 close → 최고가 허용(MAX = 어떤 가격이든 사겠다)
            uint256 acceptable = p.isLong ? acceptablePriceMin : acceptablePriceMax;
            gmxKey = _createGmxOrder(gmxMarket, ORDER_MARKET_DECREASE, 0, p.gmxSizeUsd, 0, acceptable, p.isLong);
        }
        orderKey = _newOrderKey(msg.sender);
        orders[orderKey] = Order({
            vault: msg.sender, kind: 2, positionKey: pk, gmxKey: gmxKey, executed: false,
            redeemUsdc: 0, usdcSnap: 0
        });
        if (gmxKey != bytes32(0)) gmxKeyToRyexKey[gmxKey] = orderKey;
        emit OrderCreated(orderKey, msg.sender, 2, gmxKey);
    }

    /// @notice 익절(Take Profit) 주문.
    ///         롱 TP: 가격 >= trigger → 체결 (LimitDecrease).  acceptablePrice = trigger × (1 − 1%).
    ///         숏 TP: 가격 <= trigger → 체결 (LimitDecrease).  acceptablePrice = trigger × (1 + 1%).
    /// @param triggerPrice8 익절 목표 가격. **8 decimals**: 예) $2,000 → 200_000_000_000.
    function createTakeProfit(bytes32 pk, uint256 triggerPrice8) external payable returns (bytes32 orderKey) {
        return _createConditionalDecreaseOrder(pk, triggerPrice8, true);
    }

    /// @notice 손절(Stop Loss) 주문.
    ///         롱 SL: 가격 <= trigger → 체결 (StopLossDecrease). acceptablePrice = trigger × (1 − 1%).
    ///         숏 SL: 가격 >= trigger → 체결 (StopLossDecrease). acceptablePrice = trigger × (1 + 1%).
    /// @param triggerPrice8 손절 기준 가격. **8 decimals**: 예) $1,200 → 120_000_000_000.
    function createStopLoss(bytes32 pk, uint256 triggerPrice8) external payable returns (bytes32 orderKey) {
        return _createConditionalDecreaseOrder(pk, triggerPrice8, false);
    }

    /// @dev 공통 조건부 close 로직.
    ///      isTakeProfit=true  → LimitDecrease(5): 롱은 가격 상승, 숏은 가격 하락 시 체결.
    ///      isTakeProfit=false → StopLossDecrease(6): 롱은 가격 하락, 숏은 가격 상승 시 체결.
    function _createConditionalDecreaseOrder(bytes32 pk, uint256 triggerPrice8, bool isTakeProfit)
        internal
        returns (bytes32 orderKey)
    {
        require(triggerPrice8 > 0, "GMX: zero trigger price");
        Position memory p = positions[pk];
        require(p.active, "GMX: no active position");
        require(msg.sender == p.vault, "GMX: not vault");

        address gmxMarket = gmxMarketOf[p.marketId];
        bytes32 gmxKey;
        if (gmxMarket != address(0)) {
            uint8 orderType = isTakeProfit ? ORDER_LIMIT_DECREASE : ORDER_STOP_LOSS;
            uint256 triggerPrice30 = triggerPrice8 * 1e22;

            // acceptable price: 롱은 MIN(trigger−1%), 숏은 MAX(trigger+1%)
            // (체결 가능한 최악의 슬리피지 허용)
            uint256 acceptable;
            if (p.isLong) {
                acceptable = triggerPrice30 * (10_000 - LIMIT_SLIPPAGE_BPS) / 10_000;
            } else {
                acceptable = triggerPrice30 * (10_000 + LIMIT_SLIPPAGE_BPS) / 10_000;
            }
            gmxKey = _createGmxOrder(gmxMarket, orderType, 0, p.gmxSizeUsd, triggerPrice30, acceptable, p.isLong);
        }

        orderKey = _newOrderKey(msg.sender);
        orders[orderKey] = Order({vault: msg.sender, kind: 3, positionKey: pk, gmxKey: gmxKey, executed: false, redeemUsdc: 0, usdcSnap: 0});
        if (gmxKey != bytes32(0)) gmxKeyToRyexKey[gmxKey] = orderKey;
        emit OrderCreated(orderKey, msg.sender, 3, gmxKey);
    }

    /// @notice Position net value (USD WAD) — oracle mark (collateral + leverage·pnl).
    ///         This is what drives RYex LTV/liquidation; the real GMX PnL is intentionally NOT used.
    ///         롱: 가격 상승 → PnL 양수. 숏: 가격 하락 → PnL 양수.
    function getPositionValueUsd(bytes32 pk) public view returns (uint256) {
        Position memory p = positions[pk];
        if (!p.active || p.entryPrice8 == 0) return 0;
        int256 collatWad = int256(Units.usdcToWad(p.collateral));
        int256 cur   = int256(marketOracle[p.marketId].getPrice());
        int256 entry = int256(uint256(p.entryPrice8));
        // 롱: pnl = collateral × leverage × (cur − entry) / entry
        // 숏: pnl = collateral × leverage × (entry − cur) / entry  (방향 반전)
        int256 priceMove = p.isLong ? (cur - entry) : (entry - cur);
        int256 pnl = (collatWad * int256(p.leverage) * priceMove) / entry;
        int256 value = collatWad + pnl;
        return value > 0 ? uint256(value) : 0;
    }

    /// @notice RLT 상환 — GMX MarketDecrease(partial). 체결 시 proceeds → Vault → redeemer.
    function createRedeemOrder(bytes32 pk, uint256 withdrawUsdc)
        external
        payable
        returns (bytes32 orderKey, uint256 paidUsdc)
    {
        Position memory p = positions[pk];
        require(p.active, "GMX: no position");
        require(msg.sender == p.vault, "GMX: not vault");
        require(withdrawUsdc > 0, "GMX: zero redeem");
        uint256 equityUsdc = Units.wadToUsdc(getPositionValueUsd(pk));
        require(equityUsdc > 0 && withdrawUsdc <= equityUsdc, "GMX: exceeds equity");

        uint256 sizeDelta = (p.gmxSizeUsd * withdrawUsdc) / equityUsdc;
        if (sizeDelta == 0) sizeDelta = 1;
        if (sizeDelta > p.gmxSizeUsd) sizeDelta = p.gmxSizeUsd;

        uint256 collatDelta = (p.collateral * withdrawUsdc) / equityUsdc;
        if (collatDelta == 0) collatDelta = 1;
        if (collatDelta > p.collateral) collatDelta = p.collateral;

        uint256 usdcSnap = usdc.balanceOf(address(this));
        address gmxMarket = gmxMarketOf[p.marketId];
        bytes32 gmxKey;
        if (gmxMarket != address(0)) {
            uint256 acceptable = p.isLong ? acceptablePriceMin : acceptablePriceMax;
            gmxKey = _createGmxOrder(gmxMarket, ORDER_MARKET_DECREASE, collatDelta, sizeDelta, 0, acceptable, p.isLong);
        }

        orderKey = _newOrderKey(msg.sender);
        orders[orderKey] = Order({
            vault:       msg.sender,
            kind:        4,
            positionKey: pk,
            gmxKey:      gmxKey,
            executed:    false,
            redeemUsdc:  withdrawUsdc,
            usdcSnap:    usdcSnap
        });
        if (gmxKey != bytes32(0)) gmxKeyToRyexKey[gmxKey] = orderKey;
        emit OrderCreated(orderKey, msg.sender, 4, gmxKey);

        paidUsdc = 0;
        // mock-only: GMX leg 없음 → 즉시 포지션 축소·USDC 송금 (Vault 콜백 없음 — reentrancy 회피)
        if (gmxKey == bytes32(0)) {
            orders[orderKey].executed = true;
            paidUsdc = _fillRedeemOrder(orders[orderKey]);
            emit OrderExecuted(orderKey, bytes32(0));
        }
    }

    /// @dev RLT redeem 체결: mock 회계 비례 축소 + USDC → Vault. paid = Vault 수취액.
    function _fillRedeemOrder(Order storage o) internal returns (uint256 paid) {
        Position storage p = positions[o.positionKey];
        uint256 redeemUsdc = o.redeemUsdc;
        uint256 equityUsdc = Units.wadToUsdc(getPositionValueUsd(o.positionKey));
        if (equityUsdc > 0 && redeemUsdc > 0) {
            uint256 sizeReduce = (p.gmxSizeUsd * redeemUsdc) / equityUsdc;
            if (sizeReduce > p.gmxSizeUsd) sizeReduce = p.gmxSizeUsd;
            if (sizeReduce > 0) p.gmxSizeUsd -= sizeReduce;
            uint256 collRed = (p.collateral * redeemUsdc) / equityUsdc;
            if (collRed > p.collateral) collRed = p.collateral;
            if (collRed > 0) p.collateral -= collRed;
        }
        uint256 bal = usdc.balanceOf(address(this));
        paid = bal > o.usdcSnap ? bal - o.usdcSnap : 0;
        if (paid == 0 && o.gmxKey == bytes32(0)) {
            paid = redeemUsdc > bal ? bal : redeemUsdc;
        }
        if (paid > 0) usdc.safeTransfer(o.vault, paid);
    }

    // ── GMX 자동 콜백 (callbackContract = address(this) 설정 시 자동 호출) ────

    /// @notice GMX OrderHandler가 주문 체결 후 자동으로 호출.
    ///         호출자 검증: msg.sender == gmxOrderHandler (address(0)이면 검증 스킵).
    ///         내부적으로 settleGmxOrder와 동일한 로직으로 Vault 상태를 Active/Empty로 전환.
    function afterOrderExecution(
        bytes32 key,
        IGmxOrderCallbackReceiver.EventLogData memory, // GMX 이벤트 데이터 (미사용)
        IGmxOrderCallbackReceiver.EventLogData memory  // GMX 이벤트 데이터 (미사용)
    ) external override {
        _requireGmxHandler();
        _settleCallback(key, true);
    }

    /// @notice GMX OrderHandler가 주문 취소 후 자동으로 호출.
    function afterOrderCancellation(
        bytes32 key,
        IGmxOrderCallbackReceiver.EventLogData memory,
        IGmxOrderCallbackReceiver.EventLogData memory
    ) external override {
        _requireGmxHandler();
        _settleCallback(key, false);
    }

    /// @notice GMX OrderHandler가 주문 frozen 처리 후 호출 (가격 검증 실패 등).
    ///         frozen은 추후 재실행 또는 취소될 수 있어 상태 전환 없이 이벤트만 발행.
    function afterOrderFrozen(
        bytes32 key,
        IGmxOrderCallbackReceiver.EventLogData memory,
        IGmxOrderCallbackReceiver.EventLogData memory
    ) external override {
        _requireGmxHandler();
        emit OrderFrozen(key);
    }

    event OrderFrozen(bytes32 indexed gmxKey);

    modifier onlyGmxHandler() {
        _requireGmxHandler();
        _;
    }

    function _requireGmxHandler() internal view {
        // gmxOrderHandler == address(0) 이면 누구든 호출 가능 (테스트 전용)
        if (gmxOrderHandler != address(0)) {
            require(msg.sender == gmxOrderHandler, "GMX: not OrderHandler");
        }
    }

    /// @dev 콜백 공통 로직 — GMX의 afterOrderExecution/Cancellation 신호를 그대로 신뢰.
    ///      Reader 재조회 없음: 콜백 타입 자체가 "체결됨" / "취소됨" 의 진실.
    ///      (afterOrderExecution 시점에 Reader가 아직 업데이트 안 됐을 수 있어 재조회 불안전)
    ///      revert 대신 early-return: 콜백이 실패해도 GMX 주문 실행에는 영향 없음.
    function _settleCallback(bytes32 gmxKey, bool isExecution) internal {
        bytes32 ryexKey = gmxKeyToRyexKey[gmxKey];
        if (ryexKey == bytes32(0)) return; // 알 수 없는 주문 (무시)
        Order storage o = orders[ryexKey];
        if (o.vault == address(0) || o.executed) return; // 이미 처리된 주문

        if (isExecution) {
            _doExecute(ryexKey, o);
        } else {
            _doCancel(ryexKey, o);
        }
    }

    // ── permissionless settlement ──────────────────────────────────────────────

    /// @notice GMX 주문 처리 후 누구든 호출해 Vault 상태를 갱신한다.
    ///
    ///         보안 모델 (off-chain executor 불필요):
    ///         1. DataStore.containsBytes32 — GMX가 실제로 주문을 처리했는지 검증.
    ///            주문이 DataStore에 남아있는 동안은 호출 불가 → 조기 호출 방지.
    ///         2. Reader.getPosition — 포지션 실재 여부로 체결/취소 자동 분기.
    ///            open 주문: 포지션 있음 → 체결, 없음 → 취소(리펀드).
    ///            close/TP/SL: 포지션 없음 → 체결, 있음 → 취소 복귀.
    ///
    /// @param gmxKey OrderCreated 이벤트의 gmxKey 필드
    function settleGmxOrder(bytes32 gmxKey) external {
        bytes32 ryexKey = gmxKeyToRyexKey[gmxKey];
        require(ryexKey != bytes32(0), "GMX: unknown gmxKey");
        Order storage o = orders[ryexKey];
        require(o.vault != address(0) && !o.executed, "GMX: bad order");
        require(!_isGmxOrderPending(gmxKey), "GMX: order still pending");

        Position storage p = positions[o.positionKey];
        bool posExists = _gmxPositionExists(p.marketId, p.isLong);

        if (o.kind == 1) {
            posExists ? _doExecute(ryexKey, o) : _doCancel(ryexKey, o);
        } else if (o.kind == 4) {
            // partial decrease: 포지션이 남아 있어도 체결됨
            if (!_isGmxOrderPending(gmxKey)) _doExecute(ryexKey, o);
        } else {
            posExists ? _doCancel(ryexKey, o) : _doExecute(ryexKey, o);
        }
    }

    function _doExecute(bytes32 ryexKey, Order storage o) internal {
        o.executed = true;
        if (o.kind == 1) {
            // open 체결: 포지션 활성화
            positions[o.positionKey].active = true;
        } else if (o.kind == 4) {
            _fillRedeemOrder(o);
        } else {
            // close / liquidate / TP / SL: mock-mark 기준 USDC 지급 후 포지션 종료
            uint256 recovered = Units.wadToUsdc(getPositionValueUsd(o.positionKey));
            uint256 bal = usdc.balanceOf(address(this));
            if (recovered > bal) recovered = bal;
            positions[o.positionKey].active = false;
            if (recovered > 0) usdc.safeTransfer(o.vault, recovered);
        }
        emit OrderExecuted(ryexKey, o.gmxKey);
        IPositionVault(o.vault).afterOrderExecution(ryexKey);
    }

    function _doCancel(bytes32 ryexKey, Order storage o) internal {
        o.executed = true;
        if (o.kind == 1) {
            // open 취소: USDC 리펀드 후 포지션 데이터 삭제
            Position memory p = positions[o.positionKey];
            delete positions[o.positionKey];
            uint256 bal = usdc.balanceOf(address(this));
            uint256 refund = p.collateral > bal ? bal : p.collateral;
            if (refund > 0) usdc.safeTransfer(o.vault, refund);
        }
        emit OrderCancelled(ryexKey, o.gmxKey);
        IPositionVault(o.vault).afterOrderCancellation(ryexKey);
    }

    /// @dev GMX DataStore에서 주문이 아직 대기 중인지 확인.
    ///      처리(체결/취소)된 주문은 DataStore의 account order list에서 제거된다.
    function _isGmxOrderPending(bytes32 gmxKey) internal view returns (bool) {
        bytes32 listKey = keccak256(abi.encode(ACCOUNT_ORDER_LIST, address(this)));
        (bool ok, bytes memory data) = dataStore.staticcall(
            abi.encodeWithSignature("containsBytes32(bytes32,bytes32)", listKey, gmxKey)
        );
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (bool));
    }

    /// @dev GMX Reader로 이 adapter 계정의 포지션이 실재하는지 확인.
    ///      gmxMarket 미등록 또는 reader==address(0) 이면 내부 mock 회계(positions.active)로 fallback.
    function _gmxPositionExists(bytes32 marketId, bool isLong) internal view returns (bool) {
        address gmxMarket = gmxMarketOf[marketId];
        if (gmxMarket == address(0) || address(reader) == address(0)) {
            // mock 모드: 내부 positions 매핑에서 직접 판단 (settleGmxOrder 미지원)
            return false;
        }
        bytes32 gmxPosKey = keccak256(abi.encode(address(this), gmxMarket, address(usdc), isLong));
        try reader.getPosition(dataStore, gmxPosKey) returns (IGmxReader.PositionProps memory pos) {
            return pos.numbers.sizeInUsd > 0;
        } catch {
            return false;
        }
    }

    // ── owner-only fallback (긴급 복구 전용) ──────────────────────────────────

    /// @notice DataStore 검증 없이 강제 체결 정산. owner 긴급 복구 경로.
    function executeOrder(bytes32 orderKey) external onlyOwner {
        Order storage o = orders[orderKey];
        require(o.vault != address(0) && !o.executed, "GMX: bad order");
        _doExecute(orderKey, o);
    }

    /// @notice DataStore 검증 없이 강제 취소 정산. owner 긴급 복구 경로.
    function cancelOrder(bytes32 orderKey) external onlyOwner {
        Order storage o = orders[orderKey];
        require(o.vault != address(0) && !o.executed, "GMX: bad order");
        _doCancel(orderKey, o);
    }

    /// @notice adapter orders 매핑에 없는 staleOrderKey로 vault가 Settling에 갇혔을 때 강제 복구.
    ///         USDC 환불 없음. onlyOwner.
    function forceVaultReset(address vaultAddr, bytes32 staleOrderKey) external onlyOwner {
        IPositionVault(vaultAddr).afterOrderCancellation(staleOrderKey);
    }

    /// @notice 미체결 limit open 주문을 GMX에 취소 요청.
    ///         GMX keeper 처리 후 settleGmxOrder(gmxKey) 호출로 Vault 상태가 Empty로 전환된다.
    function requestCancellation(bytes32 ryexOrderKey) external {
        Order memory o = orders[ryexOrderKey];
        require(o.vault == msg.sender, "GMX: not vault");
        require(!o.executed, "GMX: already executed");
        require(o.gmxKey != bytes32(0), "GMX: no GMX key (mock-only order)");
        exchangeRouter.cancelOrder(o.gmxKey);
    }

    // ── internal: build + submit the GMX v2 order via ExchangeRouter.multicall ──

    function _createGmxOrder(
        address gmxMarket,
        uint8   orderType,
        uint256 collatAmount,
        uint256 sizeUsd,
        uint256 triggerPrice30, // 0 = market order
        uint256 acceptablePrice,
        bool    isLong
    ) internal returns (bytes32 gmxKey) {
        uint256 fee = execFee;
        require(address(this).balance >= fee, "GMX: adapter underfunded (ETH)");

        IGmxExchangeRouter.CreateOrderParams memory params = IGmxExchangeRouter.CreateOrderParams({
            addresses: IGmxExchangeRouter.CreateOrderParamsAddresses({
                receiver:             address(this), // proceeds/refunds return to the adapter
                cancellationReceiver: address(this), // limit cancel도 adapter로 반환
                callbackContract:     address(this), // GMX가 체결/취소 후 afterOrder* 콜백 자동 호출
                uiFeeReceiver:        address(0),
                market:               gmxMarket,
                initialCollateralToken: address(usdc),
                swapPath:             new address[](0)
            }),
            numbers: IGmxExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd:                  sizeUsd,
                initialCollateralDeltaAmount:  collatAmount,
                triggerPrice:                  triggerPrice30,
                acceptablePrice:               acceptablePrice,
                executionFee:                  fee,
                callbackGasLimit:              CALLBACK_GAS_LIMIT,
                minOutputAmount:               0,
                validFromTime:                 0
            }),
            orderType:                orderType,
            decreasePositionSwapType: 0,
            isLong:                   isLong,
            shouldUnwrapNativeToken:  false,
            autoCancel:               false,
            referralCode:             bytes32(0),
            dataList:                 new bytes32[](0)
        });

        // increase 타입이면 sendTokens 포함(3-step), decrease면 2-step
        bool isIncrease = (orderType == ORDER_MARKET_INCREASE || orderType == ORDER_LIMIT_INCREASE);
        bytes[] memory data = new bytes[](isIncrease ? 3 : 2);
        data[0] = abi.encodeWithSelector(IGmxExchangeRouter.sendWnt.selector, orderVault, fee);
        if (isIncrease) {
            data[1] = abi.encodeWithSelector(IGmxExchangeRouter.sendTokens.selector, address(usdc), orderVault, collatAmount);
            data[2] = abi.encodeWithSelector(IGmxExchangeRouter.createOrder.selector, params);
        } else {
            data[1] = abi.encodeWithSelector(IGmxExchangeRouter.createOrder.selector, params);
        }
        bytes[] memory results = exchangeRouter.multicall{value: fee}(data);
        gmxKey = abi.decode(results[results.length - 1], (bytes32));
    }
}
