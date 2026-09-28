// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IPositionVault} from "./interfaces/IPositionVault.sol";
import {IRToken} from "./interfaces/IRToken.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {ILpZap} from "./interfaces/ILpZap.sol";
import {RToken} from "./RToken.sol";
import {LTVMath} from "./libraries/LTVMath.sol";
import {Units} from "./libraries/Units.sol";
import {AmmTwap} from "./libraries/AmmTwap.sol";
import {Market, RiskParams, GmxInfra} from "./types/Types.sol";

/// @title VaultFactory — 멀티에셋 마켓 레지스트리 + 사용자별 PositionVault clone (docs/10, Wave 1)
/// @notice admin은 마켓 등록·파라미터·pause만. 사용자 자금 직접인출 함수 없음(G5).
///         마켓별로 자산 oracle·rToken·LTV를 보유. createVault(marketId, isLong)로 (user×market×방향) 격리 볼트.
contract VaultFactory is IVaultFactory, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    event SweptFees(address indexed token, address indexed to, uint256 amount);

    address public immutable implementation; // PositionVault 로직 (immutable, D7)
    GmxInfra internal _gmxInfra;
    address public usdc;
    address public router; // RyexRouter — vault.deposit 진입점
    address public treasury; // RyexTreasury — 프로토콜 fee·penalty 수납

    mapping(bytes32 => Market) public markets; // marketId => 설정
    mapping(address => bytes32) public poolToMarketId; // pool => marketId 역참조 (LpZap deposit 마켓 판별용)
    bytes32[] public marketIds; // 등록 순서(조회용)
    address[] internal _allVaults; // 생성 순서 전체 vault (totalVaults / vaultAt 조회용)
    mapping(address => mapping(bytes32 => mapping(bool => address))) public vaultOf; // owner => marketId => isLong => vault
    mapping(address => bool) public isVault;
    uint256 public totalCollateralLocked; // 전체 볼트 USDC collateral 합계 (6dec). Vault push 방식.
    address public swapRouter; // UniV3 SwapRouter (v3-periphery, deadline 있음) — 청산 대기버킷 buyback
    uint24 public swapFee; // UniV3 fee tier (3000 = 0.3%)

    // ── 청산 buyback (docs/liquidation-branches.md — 오라클가 확정정산 + 저가매수 소각, 트레저리 자본 불필요) ──
    uint32 public buybackTwapWindow; // 0=TWAP 필터 없음(스팟만), >0초=TWAP도 오라클 이하여야 시작 (윅 차단)
    uint16 public buybackBountyBps; // permissionless 호출자 보너스 (버킷 소비분 대비 bps)
    uint16 public buybackBufferBps; // 목표가 = 오라클가 × (1 - bufferBps) — sqrtPriceLimitX96로 이 가격 도달 시 스왑 자동정지
    mapping(bytes32 => uint256) public pendingBuybackUsdc; // 마켓별 대기 buyback 자금(6dec)
    mapping(bytes32 => uint256) public outstandingUnretired; // 마켓별 아직 안 태운 rToken(18dec)
    mapping(bytes32 => uint256) public totalBurnedViaBuyback; // 마켓별 누적 buyback 소각량(18dec, 투명성)
    mapping(bytes32 => uint256) public totalEarmarkedUsdc; // 마켓별 누적 적립 USDC(6dec, 그로스, 투명성)

    // ── LP 인센티브 (borrow fee → 마켓별 rToken/USDC 풀 LpZap 리워드, 유동성 유치용) ──
    // LpZap은 UniswapV3Staker의 "라운드"(incentive startTime~endTime, 이미 시작한 라운드엔 추가 적립
    // 불가) 제약이 없는 자체 accRewardPerLiquidity 누적기 컨트랙트 — 도착 즉시(스테이킹 있으면) 반영.
    address public lpZap; // LpZap 배포 주소 (notifyReward만 호출)
    uint16 public borrowFeeToLpBps; // borrow fee 중 LP 인센티브로 돌릴 비율(10000=100%). owner 조정 가능, 나머지는 treasury
    mapping(bytes32 => uint256) public pendingLpIncentiveUsdc; // lpZap 미설정 기간 대기 중인 LP 인센티브 자금(6dec)
    mapping(bytes32 => uint256) public totalLpIncentiveUsdc; // 마켓별 누적 지급(그로스, 6dec, 투명성)

    error VaultExists();
    error ZeroAddress();
    error MarketExists();
    error NoMarket();
    error BadRiskParams();
    error MarketMismatch();
    error PoolNotSet();
    error PoolTooExpensive();
    error LpZapNotSet();
    error LpZapNotContract();
    error ZeroMarketId();
    error BadBorrowApr();
    error PoolAlreadyRegistered();

    uint16 internal constant MAX_BORROW_APR_BPS = 5_000; // 50% 상한 — owner 실수/악의적 설정 방어

    constructor(address implementation_, address usdc_, address admin_) Ownable(admin_) {
        if (implementation_ == address(0) || usdc_ == address(0)) {
            revert ZeroAddress();
        }
        implementation = implementation_;
        usdc = usdc_;
        borrowFeeToLpBps = 10_000; // 기본 100% — owner가 setBorrowFeeToLpBps로 이후 조정
    }

    /// @dev IVaultFactory·Ownable 양쪽에 선언된 owner() 명시적 override (동작은 Ownable 그대로).
    function owner() public view override(IVaultFactory, Ownable) returns (address) {
        return Ownable.owner();
    }

    /// @notice GMX v2 인프라 (exchangeRouter, reader, execFee 등).
    function setGmxInfra(GmxInfra calldata infra_) external onlyOwner {
        if (infra_.exchangeRouter == address(0) || infra_.gmxRouter == address(0)) revert ZeroAddress();
        _gmxInfra = infra_;
    }

    function gmxInfra() external view returns (GmxInfra memory) {
        return _gmxInfra;
    }

    /// @notice 마켓 등록. 자산별 RToken을 factory가 배포(isVault 가드 일관). marketId = keccak(symbol) 권장.
    /// @dev addMarket 시 gmxMarket을 함께 등록 (0 = mock-only). borrowAprBps_는 RiskParams(LTV 곡선)와
    ///      별개 개념(수수료)이라 별도 파라미터로 받는다 — 마켓별 차등 가능, 이후 setBorrowAprBps로 조정.
    function addMarket(
        bytes32 marketId,
        IPriceOracle oracle,
        address gmxMarket,
        string calldata name,
        string calldata symbol,
        RiskParams calldata risk,
        uint16 borrowAprBps_
    ) external onlyOwner returns (address rToken) {
        // marketId==0은 LpZap.poolToMarketId 조회의 "미등록 풀" 센티널 값과 겹친다 — 실수로 0을 쓰면
        // 그 마켓의 LP 예치가 전부 UnknownPool로 잘못 튕긴다. keccak256(symbol) 관례상 0이 나올 일은
        // 없지만 방어적으로 막는다.
        if (marketId == bytes32(0)) revert ZeroMarketId();
        if (markets[marketId].active) revert MarketExists();
        if (address(oracle) == address(0)) revert ZeroAddress();
        // Risk-curve invariants (fail fast at config time, not at runtime in mint/curve):
        //  - maxLeverage>0, maxLtv1x>0; flatTier in [1, maxLeverage]
        //  - buffer>0 so mint cap (<= maxLtv1x) stays strictly below LLTV (= maxLtv1x+buffer) — no mint-into-liquidation
        //  - curve monotonic: maxLtvAtMaxLev <= maxLtv1x (mirrors LTVMath 'bad curve' require)
        //  - LLTV <= 100%: maxLtv1x + buffer <= BPS (no over-100% LTV)
        if (
            !LTVMath.isValidRiskParams(
                risk.maxLeverage, risk.maxLtv1xBps, risk.bufferBps, risk.flatTier, risk.maxLtvAtMaxLevBps
            )
        ) revert BadRiskParams();
        if (borrowAprBps_ > MAX_BORROW_APR_BPS) revert BadBorrowApr();
        rToken = address(new RToken(this, name, symbol));
        markets[marketId] = Market({
            active: true,
            oracle: address(oracle),
            rToken: rToken,
            gmxMarket: gmxMarket,
            pool: address(0), // setMarketPool로 추후 등록 (buyback 활성화 전엔 0 유지)
            maxLtv1xBps: risk.maxLtv1xBps,
            bufferBps: risk.bufferBps,
            maxLtvAtMaxLevBps: risk.maxLtvAtMaxLevBps,
            flatTier: risk.flatTier,
            maxLeverage: risk.maxLeverage,
            borrowAprBps: borrowAprBps_
        });
        marketIds.push(marketId);
        emit MarketAdded(marketId, address(oracle), rToken);
        emit MarketBorrowAprUpdated(marketId, 0, borrowAprBps_);
    }

    /// @notice 마켓 borrow/stability fee APR(bps) 교체 — 마켓별 차등 가능. 기존 vault는 factory.markets[]를
    ///         live 참조하므로 다음 _accrueBorrow 호출 시점부터 새 요율이 적용된다(소급 적용 아님 — 이미
    ///         누적된 accruedBorrowFeeUsdc는 그대로 유지).
    function setBorrowAprBps(bytes32 marketId, uint16 bps_) external onlyOwner {
        Market storage m = markets[marketId];
        if (!m.active) revert NoMarket();
        if (bps_ > MAX_BORROW_APR_BPS) revert BadBorrowApr();
        uint16 old = m.borrowAprBps;
        if (old == bps_) return;
        m.borrowAprBps = bps_;
        emit MarketBorrowAprUpdated(marketId, old, bps_);
    }

    /// @notice 마켓 oracle 교체. 해당 마켓 vault는 factory 레지스트리를 직접 참조하므로 즉시 반영.
    /// @dev mock ↔ GmxPriceOracle 전환 등 운영 시 owner 호출. 활성 포지션 중 교체는 가격 단절 위험 — 운영 판단.
    function setMarketOracle(bytes32 marketId, IPriceOracle oracle_) external onlyOwner {
        Market storage m = markets[marketId];
        if (!m.active) revert NoMarket();
        if (address(oracle_) == address(0)) revert ZeroAddress();
        address oldOracle = m.oracle;
        if (oldOracle == address(oracle_)) return;
        m.oracle = address(oracle_);
        emit MarketOracleUpdated(marketId, oldOracle, address(oracle_));
    }

    /// @notice buyback 가격조회·스왑 라우팅용 UniV3 rToken/USDC pool 등록. 0 = buyback 비활성.
    /// @dev 이미 "다른" 마켓에 등록된 풀을 재등록하면 poolToMarketId가 새 마켓으로 덮어써지는데 기존
    ///      마켓의 m.pool은 그대로 남아 매칭이 깨진다(LpZap.deposit이 엉뚱한 마켓으로 스테이킹됨) — 방어.
    function setMarketPool(bytes32 marketId, address pool_) external onlyOwner {
        Market storage m = markets[marketId];
        if (!m.active) revert NoMarket();
        address old = m.pool;
        if (old == pool_) return;
        if (pool_ != address(0)) {
            bytes32 existing = poolToMarketId[pool_];
            if (existing != bytes32(0) && existing != marketId) revert PoolAlreadyRegistered();
        }
        if (old != address(0)) delete poolToMarketId[old];
        m.pool = pool_;
        if (pool_ != address(0)) poolToMarketId[pool_] = marketId;
        emit MarketPoolUpdated(marketId, old, pool_);
    }

    /// @notice 마켓 RiskParams 전체 교체. vault는 markets[]를 live 참조하므로 기존 vault에도 즉시 반영.
    function setMarketRisk(bytes32 marketId, RiskParams calldata risk) external onlyOwner {
        Market storage m = markets[marketId];
        if (!m.active) revert NoMarket();
        if (
            !LTVMath.isValidRiskParams(
                risk.maxLeverage, risk.maxLtv1xBps, risk.bufferBps, risk.flatTier, risk.maxLtvAtMaxLevBps
            )
        ) revert BadRiskParams();
        m.maxLtv1xBps = risk.maxLtv1xBps;
        m.bufferBps = risk.bufferBps;
        m.maxLtvAtMaxLevBps = risk.maxLtvAtMaxLevBps;
        m.flatTier = risk.flatTier;
        m.maxLeverage = risk.maxLeverage;
        emit MarketRiskUpdated(
            marketId, risk.maxLtv1xBps, risk.bufferBps, risk.maxLtvAtMaxLevBps, risk.flatTier, risk.maxLeverage
        );
    }

    /// @notice 마켓 bufferBps만 교체 (LLTV = maxLtv1x + buffer). 기존 vault에 즉시 반영.
    function setBufferBps(bytes32 marketId, uint16 bufferBps_) external onlyOwner {
        Market storage m = markets[marketId];
        if (!m.active) revert NoMarket();
        if (
            !LTVMath.isValidRiskParams(
                m.maxLeverage, m.maxLtv1xBps, bufferBps_, m.flatTier, m.maxLtvAtMaxLevBps
            )
        ) revert BadRiskParams();
        uint16 old = m.bufferBps;
        if (old == bufferBps_) return;
        m.bufferBps = bufferBps_;
        emit MarketBufferUpdated(marketId, old, bufferBps_);
    }

    function createVault(bytes32 marketId, bool isLong, address owner_) external whenNotPaused returns (address vault) {
        if (owner_ == address(0)) revert ZeroAddress();
        Market memory m = markets[marketId];
        if (!m.active) revert NoMarket();
        if (vaultOf[owner_][marketId][isLong] != address(0)) revert VaultExists();
        vault = Clones.clone(implementation);
        vaultOf[owner_][marketId][isLong] = vault;
        isVault[vault] = true;
        RiskParams memory risk = RiskParams({
            maxLtv1xBps: m.maxLtv1xBps,
            bufferBps: m.bufferBps,
            maxLtvAtMaxLevBps: m.maxLtvAtMaxLevBps,
            flatTier: m.flatTier,
            maxLeverage: m.maxLeverage
        });
        IPositionVault(vault).initialize(
            owner_, address(this), usdc, m.rToken, marketId, isLong, risk
        );
        _allVaults.push(vault);
        emit VaultCreated(owner_, marketId, isLong, vault);
    }

    /// @notice RyexRouter 주소 등록. vault.deposit은 이 주소만 호출 가능.
    function setRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        router = router_;
    }

    /// @notice 프로토콜 treasury(RyexTreasury) 등록. PositionVault fee·penalty 수납처.
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice UniV3 SwapRouter (v3-periphery) + fee tier (전 마켓 공통, 청산 buyback 스왑 실행처).
    function setSwapRouter(address router_, uint24 fee_) external onlyOwner {
        if (router_ == address(0) || fee_ == 0) revert ZeroAddress();
        swapRouter = router_;
        swapFee = fee_;
        emit SwapRouterSet(router_, fee_);
    }

    /// @notice buyback 파라미터. twapWindow=0이면 스팟 게이트만, >0이면 TWAP도 오라클 이하여야 시작.
    ///         bountyBps·bufferBps는 <=2000 캡.
    function setBuybackParams(uint32 twapWindow_, uint16 bountyBps_, uint16 bufferBps_) external onlyOwner {
        if (bountyBps_ > 2_000 || bufferBps_ > 2_000) revert BadRiskParams();
        buybackTwapWindow = twapWindow_;
        buybackBountyBps = bountyBps_;
        buybackBufferBps = bufferBps_;
        emit BuybackParamsSet(twapWindow_, bountyBps_, bufferBps_);
    }

    /// @notice LpZap 배포 주소 등록. notifyBorrowFeeEarned가 이 주소로 borrow fee를 즉시 전달한다.
    /// @dev `lpZap_.code.length` 체크 필수 — `ILpZap.notifyReward`는 반환값이 없는(void) 외부 호출이라,
    ///      코드가 없는 주소(EOA·오타)로 설정돼도 Solidity가 extcodesize를 검사하지 않아 call이 조용히
    ///      "성공"한다(revert 안 함). 이 체크가 없으면 이후 _forwardToLpZap의 safeTransfer로 실USDC가
    ///      그 주소에 영구 유실되는데도 아무 에러 신호가 없다 — 반드시 set 시점에 컨트랙트 여부만 걸러낸다.
    function setLpZap(address lpZap_) external onlyOwner {
        if (lpZap_ == address(0)) revert ZeroAddress();
        if (lpZap_.code.length == 0) revert LpZapNotContract();
        lpZap = lpZap_;
        emit LpZapSet(lpZap_);
    }

    /// @notice borrow fee(1.5% APR) 중 LP 인센티브로 돌릴 비율. 나머지는 그대로 treasury.
    ///         기본 100%(전액) — 유동성 유치가 최우선일 때. 운영 중 owner가 낮춰 treasury 비중을 늘릴 수 있음.
    function setBorrowFeeToLpBps(uint16 bps_) external onlyOwner {
        if (bps_ > 10_000) revert BadRiskParams();
        borrowFeeToLpBps = bps_;
        emit BorrowFeeToLpBpsSet(bps_);
    }

    /// @notice close/liquidate 정산 시 borrow fee 중 LP 몫이 확정되면 이 factory로 전송된 뒤 호출 — registered vault 전용.
    /// @dev vault(DebtSettler)가 이 호출 직전에 USDC를 factory로 이미 safeTransfer 했다는 전제(청산 earmark와 동일 패턴).
    ///      lpZap이 설정돼 있으면 그 즉시 LpZap으로 넘겨 accRewardPerLiquidity에 반영시킨다(라운드 없음 —
    ///      대기 없이 바로 스테이킹된 LP들에게 지분만큼 실시간 반영). 아직 미설정이면 pendingLpIncentiveUsdc에
    ///      쌓아두고, 이후 owner가 setLpZap 하면 permissionless flushPendingLpIncentive로 한 번에 흘려보낼 수 있다.
    ///      이 함수는 절대 revert하지 않는다 — vault의 close/liquidate 정산 자체를 막으면 안 된다는 게 핵심 불변식.
    function notifyBorrowFeeEarned(bytes32 marketId, uint256 usdcAmount) external {
        if (!isVault[msg.sender]) revert NoMarket();
        if (usdcAmount == 0) return;
        totalLpIncentiveUsdc[marketId] += usdcAmount;
        emit BorrowFeeEarned(marketId, msg.sender, usdcAmount);
        if (lpZap == address(0)) {
            pendingLpIncentiveUsdc[marketId] += usdcAmount;
            return;
        }
        _forwardToLpZap(marketId, usdcAmount);
    }

    /// @notice permissionless — lpZap 미설정 기간에 쌓인 대기 버킷을 지금 설정된 LpZap으로 흘려보낸다.
    function flushPendingLpIncentive(bytes32 marketId) external nonReentrant returns (uint256 amount) {
        if (lpZap == address(0)) revert LpZapNotSet();
        amount = pendingLpIncentiveUsdc[marketId];
        if (amount == 0) return 0;
        pendingLpIncentiveUsdc[marketId] = 0;
        _forwardToLpZap(marketId, amount);
    }

    /// @dev USDC를 lpZap으로 전송 + notifyReward 통보. ILpZap.notifyReward는 항상 revert하지 않도록 설계돼
    ///      있지만(라운드 없음 — 누적기만 갱신), 방어적으로 try/catch — lpZap 주소가 잘못 설정된 경우까지
    ///      대비해 vault 정산 경로는 절대 막지 않는다.
    function _forwardToLpZap(bytes32 marketId, uint256 amount) private {
        IERC20(usdc).safeTransfer(lpZap, amount);
        try ILpZap(lpZap).notifyReward(marketId, amount) {} catch {}
    }

    /// @notice 청산 시 오라클가로 확정 정산된 부채분을 대기버킷에 적립 — registered vault 전용.
    /// @dev vault가 이 호출 직전에 USDC를 factory로 이미 safeTransfer 했다는 전제(DebtSettler 패턴).
    function notifyLiquidationEarmark(bytes32 marketId, uint256 usdcAmount, uint256 rTokenAmount) external {
        if (!isVault[msg.sender]) revert NoMarket();
        if (usdcAmount == 0 && rTokenAmount == 0) return;
        pendingBuybackUsdc[marketId] += usdcAmount;
        outstandingUnretired[marketId] += rTokenAmount;
        totalEarmarkedUsdc[marketId] += usdcAmount;
        emit LiquidationEarmarked(marketId, msg.sender, usdcAmount, rTokenAmount);
    }

    /// @notice permissionless — 풀 **스팟**이 오라클가 이하일 때만 대기버킷 USDC로 rToken을 사서 태운다.
    /// @dev 게이트는 스팟(지금 살지) + TWAP 보조(최근에도 프리미엄이 아니었는지). 체결가는 TWAP이 아니다.
    ///      캡은 `sqrtPriceLimitX96` = 오라클가 × (1-buybackBufferBps): 스팟이 그 가격에 닿으면 UniV3가 스왑을 멈춘다.
    ///      실제 소비량은 `amountIn`보다 적을 수 있어 balance-delta로 실측한다.
    ///      실행분(usdcSpent) 대비 보너스만 지급하므로 트레저리 자본은 쓰지 않는다.
    function buybackAndBurn(bytes32 marketId, uint256 maxUsdcIn)
        external
        nonReentrant
        returns (uint256 usdcSpent, uint256 rTokenBurned, uint256 callerBounty)
    {
        Market memory m = markets[marketId];
        if (!m.active) revert NoMarket();
        if (m.pool == address(0)) revert PoolNotSet();
        uint256 outstanding = outstandingUnretired[marketId];
        uint256 bucket = pendingBuybackUsdc[marketId];
        if (outstanding == 0 || bucket == 0 || swapRouter == address(0) || swapFee == 0) {
            return (0, 0, 0);
        }

        uint256 price8 = IPriceOracle(m.oracle).getPrice();
        // 1) 스팟 — 지금 풀이 오라클보다 비싸면 시작 금지. 목표가(오라클-버퍼)에 이미 닿았으면 no-op.
        uint256 spotPrice8 = AmmTwap.rTokenPrice8(m.pool, m.rToken, usdc, 0);
        if (spotPrice8 > price8) revert PoolTooExpensive();
        uint256 targetPrice8 = (price8 * (10_000 - buybackBufferBps)) / 10_000;
        if (spotPrice8 >= targetPrice8) return (0, 0, 0);

        // 2) TWAP 보조 — 최근 평균이 아직 오라클 위면 한 블록 윅으로 보고 스킵 (window=0이면 비활성).
        if (buybackTwapWindow > 0) {
            uint256 twapPrice8 = AmmTwap.rTokenPrice8(m.pool, m.rToken, usdc, buybackTwapWindow);
            if (twapPrice8 > price8) revert PoolTooExpensive();
        }

        // 3) 체결 한도 — 스팟이 목표가에 닿으면 UniV3가 스톱. TWAP 가격으로 사지 않는다.
        uint160 sqrtPriceLimitX96 = AmmTwap.sqrtPriceX96AtPrice8(m.rToken, usdc, targetPrice8);
        // tick 기반 스팟과 exact sqrt 한도가 어긋나면 UniV3 `SPL` revert → 가스만 태움. 잘못된 쪽이면 no-op.
        if (!AmmTwap.sqrtPriceLimitOk(m.pool, usdc, m.rToken, sqrtPriceLimitX96)) return (0, 0, 0);

        // 오퍼링 상한(=실제 소비량이 아니라 "얼마까지 시도할지"): 호출자 지정값, 버킷 잔액,
        // outstanding의 오라클 페어밸류 순으로 캡핑. 실제 소비량은 위 가격한도가 정밀하게 결정한다.
        uint256 usdcOffer = bucket;
        if (maxUsdcIn > 0 && maxUsdcIn < usdcOffer) usdcOffer = maxUsdcIn;
        uint256 maxByDebt = Units.wadToUsdc(Units.rTokenToUsdWad(outstanding, price8));
        if (usdcOffer > maxByDebt) usdcOffer = maxByDebt;
        if (usdcOffer == 0) return (0, 0, 0);

        uint256 balBefore = IERC20(usdc).balanceOf(address(this));
        IERC20(usdc).forceApprove(swapRouter, usdcOffer);
        uint256 bought = ISwapRouter02(swapRouter).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: usdc,
                tokenOut: m.rToken,
                fee: swapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdcOffer,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );
        IERC20(usdc).forceApprove(swapRouter, 0);
        // 가격한도에 걸리면 usdcOffer보다 적게 소비됨 — 실제 소비량은 잔고 델타로 실측(라우터 반환값은 amountOut뿐).
        usdcSpent = balBefore - IERC20(usdc).balanceOf(address(this));

        // outstanding보다 더 사졌어도 전액 태운다(잉여를 미소각 상태로 남기지 않음 — 추가 소각은 페깅에 항상 이득).
        rTokenBurned = bought;
        if (rTokenBurned > 0) IRToken(m.rToken).burn(address(this), rTokenBurned);

        pendingBuybackUsdc[marketId] = bucket - usdcSpent;
        outstandingUnretired[marketId] = outstanding > rTokenBurned ? outstanding - rTokenBurned : 0;
        totalBurnedViaBuyback[marketId] += rTokenBurned;

        callerBounty = (usdcSpent * buybackBountyBps) / 10_000;
        uint256 remainingBucket = pendingBuybackUsdc[marketId];
        if (callerBounty > remainingBucket) callerBounty = remainingBucket;
        if (callerBounty > 0) {
            pendingBuybackUsdc[marketId] = remainingBucket - callerBounty;
            IERC20(usdc).safeTransfer(msg.sender, callerBounty);
        }

        emit BuybackBurned(marketId, msg.sender, usdcSpent, rTokenBurned, callerBounty);
    }

    /// @notice permissionless 조회 — buybackAndBurn을 부르기 전 keeper가 온체인과 동일한 가격 게이트를
    ///         그대로 재사용하기 위한 view. `ready==true`여야 buybackAndBurn이 (0,0,0) no-op 없이 실행될
    ///         가능성이 높다(최종 판단은 여전히 buybackAndBurn 자체의 simulate가 함 — 블록 사이 가격 변동 대비).
    /// @dev RYieldRegistry.vaultSummary()가 ammPrice8을 온체인에서 계산해 keeper에 그대로 넘기는 패턴과
    ///      동일 — keeper가 AmmTwap의 tick 수학을 오프체인에 재구현할 필요를 없앤다(docs/liquidation-keeper-migration.md §3.1).
    ///      buybackAndBurn과 완전히 같은 조건식을 쓰되, 상태 변경(스왑·소각)은 하지 않는다.
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
        )
    {
        Market memory m = markets[marketId];
        if (!m.active || m.pool == address(0)) return (false, 0, 0, 0, 0, 0, 0);

        bucket = pendingBuybackUsdc[marketId];
        outstanding = outstandingUnretired[marketId];
        if (bucket == 0 || outstanding == 0 || swapRouter == address(0) || swapFee == 0) {
            return (false, 0, 0, 0, 0, bucket, outstanding);
        }

        oraclePrice8 = IPriceOracle(m.oracle).getPrice();
        spotPrice8 = AmmTwap.rTokenPrice8(m.pool, m.rToken, usdc, 0);
        targetPrice8 = (oraclePrice8 * (10_000 - buybackBufferBps)) / 10_000;
        twapPrice8 = buybackTwapWindow > 0 ? AmmTwap.rTokenPrice8(m.pool, m.rToken, usdc, buybackTwapWindow) : 0;

        ready = spotPrice8 <= oraclePrice8 && spotPrice8 < targetPrice8
            && (buybackTwapWindow == 0 || twapPrice8 <= oraclePrice8);
    }

    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    /// @notice 마켓 oracle 주소만 반환 (vault hot-path 경량 조회 — 전체 Market 디코드 회피).
    function marketOracle(bytes32 marketId) external view returns (address) {
        return markets[marketId].oracle;
    }

    /// @notice Vault가 collateral 증감 시 호출 → totalCollateralLocked 갱신.
    ///         delta > 0: deposit 등 증가분, delta < 0: withdraw/close/liquidation 감소분.
    function onCollateralChanged(int256 delta) external {
        if (!isVault[msg.sender]) revert NoMarket();
        if (delta > 0) {
            totalCollateralLocked += uint256(delta);
        } else if (delta < 0) {
            uint256 decrease = uint256(-delta);
            totalCollateralLocked = decrease > totalCollateralLocked
                ? 0
                : totalCollateralLocked - decrease;
        }
    }

    // ── 전체 vault 목록 (생성 순서, VaultLens 스캔용) ──

    function totalVaults() external view returns (uint256) {
        return _allVaults.length;
    }

    function vaultAt(uint256 i) external view returns (address) {
        return _allVaults[i];
    }

    // ── admin (파라미터·pause만, timelock 경유 권장 D5) ──

    /// @notice 신규 위험 차단. 상환·청산·인출(탈출)은 Vault에서 계속 허용(docs/70 §5).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function paused() public view override(IVaultFactory, Pausable) returns (bool) {
        return Pausable.paused();
    }

    /// @notice factory가 보유한 USDC/rToken 인출 (긴급용, onlyOwner).
    /// @dev 사용자 Vault 담보엔 접근 불가(G5 불변, 클론 격리) — factory 잔고는 buyback·LP인센티브 대기자금뿐.
    ///      경고: `pendingBuybackUsdc`·`pendingLpIncentiveUsdc`는 실제 USDC 잔고와 별도로 유지되는 회계값이라,
    ///      여기서 USDC를 뽑으면 그만큼 각 버킷의 solvency가 깨진다. 정상 운영 중엔 절대 쓰지 말 것
    ///      — buyback·LP인센티브 모두 트레저리 자본 불필요하게 자기완결되도록 설계된 전제가 무너진다.
    function sweepFees(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit SweptFees(address(token), to, amount);
    }
}
