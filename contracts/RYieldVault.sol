// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

// ── rYield: RYieldVault — 단일자산 풀링 델타뉴트럴 funding 볼트 (PositionVault 청산 Path와 독립) ──
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IRToken} from "./interfaces/IRToken.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {IRYieldFundingDistributor} from "./interfaces/IRYieldFundingDistributor.sol";
import {IRYieldVaultShares} from "./interfaces/IRYieldVaultShares.sol";
import {IRYieldVaultSource} from "./interfaces/IRYieldVaultSource.sol";
import {GmxIntegrationBase} from "./GmxIntegrationBase.sol";
import {GmxIntegrationReader} from "./libraries/GmxIntegrationReader.sol";
import {GmxFundingUtils} from "./libraries/GmxFundingUtils.sol";
import {GmxFundingAccruedView} from "./libraries/GmxFundingAccruedView.sol";
import {GmxConstants} from "./libraries/GmxConstants.sol";
import {Units} from "./libraries/Units.sol";
import {AmmTwap} from "./libraries/AmmTwap.sol";
import {RYieldState, RYieldStore, RYieldLensPack} from "./types/Types.sol";

/// @title RYieldVault — 단일자산 풀링 델타뉴트럴 funding 볼트 (Litepaper §4.4 / §6).
/// @notice USDC를 예치하면 한 자산에 대한 델타뉴트럴 전략(AMM rToken 롱 + 동일자산 GMX perp 숏, net delta 0)이
///         받는 funding을 수익으로 가져간다. 자산(rToken)당 단일 풀 볼트 — 여러 예치자가 share로 하나의
///         롱+숏 포지션을 공유한다(자산별 격리, §4.4). 성과수수료는 NAV 성장분(high-water mark)의 10%.
/// @dev GMX v2는 비동기(2-step)이므로 예치(share 발행)와 헤지 실행(GMX 주문)을 분리한다:
///      - deposit: NAV 기준 share 즉시 발행, USDC는 idle 보관. minDeposit 컷라인.
///      - withdraw: 호출자 pro-rata idle 몫까지 즉시 인출(헤지 안 푼 현금 — 타인 idle 잠식 없음).
///      - requestUnwind→executeUnwind(봇)→claimUnwind: 헤지된 내 몫을 상환 큐로 청산받는 경로(체결시점 평가, 본인 귀속).
///      - rebalance(): permissionless(봇이 주기 실행) — idle USDC를 배치 헤지.
///        GMX 숏 주문/정산은 GmxIntegrationBase(콜백) + GmxExecutor(라이브러리)를 그대로 재사용.
///      방어선 ①(방향성 역전): 진입은 AMM가격<GMX가격일 때만(rebalance).
///      방어선 ②(고정비용): minDeposit 컷라인으로 소액이 가스·execFee로 녹는 것을 차단.
///      short-first: 숏을 먼저 체결하고 그 콜백에서 AMM 롱을 매수 → 롱-숏 진입가 갭 노출 구간 최소화.
///      NAV = idle USDC + 롱 rToken 가치(oracle) + 숏 ledger equity(oracle-mark). 롱·숏 가격 PnL은 상쇄되어
///      가격에 중립. GMX funding 수익은 fundingDistributor로 분리 배분(NAV/idle과 별도).
contract RYieldVault is GmxIntegrationBase, IRYieldVaultShares, IRYieldVaultSource {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18; // assets-per-share 스케일
    uint256 internal constant MIN_REBALANCE_USDC = 1e6; // 1 USDC (GMX 최소 담보 가드)
    uint256 internal constant SETTLING_TIMEOUT = 5 minutes;

    address public owner;
    address public treasury; // 성과수수료 수령처
    address public fundingDistributor; // GMX funding fee 배분 (NAV/idle과 분리)
    IRToken internal _assetRToken; // 롱 leg 자산 (AMM에서 매수)
    ISwapRouter02 internal swapRouter; // UniV3 SwapRouter (v3-periphery, factory 참조)
    uint24 internal swapFee; // UniV3 fee tier
    string public assetName; // 예: "rYield rETH"

    RYieldStore internal _ry;
    // totalShares/sharesOf/state/pending/hwm/params → RYieldStore
    // GMX 숏 ledger·주문(_gmxStore), factory, usdc, _marketId, isLong, leverage → GmxIntegrationBase

    event Deposited(address indexed user, uint256 usdcIn, uint256 sharesOut);
    event Withdrawn(address indexed user, uint256 sharesIn, uint256 usdcOut);
    event RebalanceRequested(bytes32 orderKey, uint256 longUsdc, uint256 shortCollateralUsdc, uint256 rTokenBought);
    event HedgeOpened(bytes32 orderKey);
    event HedgeOpenFailed(bytes32 orderKey, uint256 rTokenSoldBack);
    event UnwindRequested(address indexed user, uint256 shares);
    event UnwindCancelled(address indexed user, uint256 shares);
    event UnwindExecuted(uint256 indexed epoch, uint256 shares, uint256 payoutUsdc);
    event UnwindClaimed(address indexed user, uint256 usdcOut);
    event HedgeClosed(bytes32 orderKey, uint256 rTokenSold);
    event HedgeCloseFailed(bytes32 orderKey);
    event PerfFeeAccrued(uint256 feeUsdc, uint256 feeShares);
    event ParamsUpdated();
    event StuckHedgeRecovered(bytes32 orderKey);
    event FundingDistributorSet(address indexed distributor);
    event FundingHarvested(uint256 longAmount, uint256 shortAmount);
    event FundingSettleRequested(bytes32 orderKey, bytes32 gmxKey);

    error NotOwner();
    error BadState();
    error BadKey();
    error ZeroAmount();
    error ZeroShares();
    error CapExceeded();
    error InsufficientShares();
    error NothingToRebalance();
    error NotTimedOut();
    error BadParams();
    error BelowMinDeposit();
    error EntryPremiumTooHigh(); // AMM >= GMX (역프리미엄) — 진입 차단
    error ExitDiscountTooHigh(); // AMM < GMX — 종료(청산) 차단
    error ExceedsIdleShare(); // withdraw가 호출자 idle 몫 초과 — requestUnwind 사용
    error ClaimPending(); // 직전 체결분 미청구 — claimUnwind 먼저
    error InsufficientExecFee(); // deposit 시 GMX exec fee(ETH) 미첨부
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev settleGmxOrder 복구 경로 — vault owner만.
    function _requireSettleAuthorized() internal view override {
        if (msg.sender != owner) revert NotOwner();
    }

    /// @dev 헤지 콜백 대기 중에는 NAV가 일시적으로 부정확(숏 담보 in-flight)하므로 가격성 동작을 차단.
    modifier whenIdle() {
        if (_ry.state != RYieldState.Idle) revert BadState();
        _;
    }

    /// @param factory_ VaultFactory (oracle·gmxInfra·gmxMarket·swapRouter 레지스트리)
    /// @param marketId_ 대상 자산 마켓 키 (PositionVault와 공유 — rETH 등)
    /// @param owner_ 거버넌스/admin
    /// @param treasury_ 성과수수료 수령처
    /// @param pool_ UniV3 rToken/USDC 풀 (AMM 가격 게이트용; 0이면 owner가 추후 setPool)
    constructor(
        address factory_,
        bytes32 marketId_,
        address owner_,
        address treasury_,
        address pool_
    ) {
        if (factory_ == address(0) || owner_ == address(0) || treasury_ == address(0)) revert BadParams();
        IVaultFactory f = IVaultFactory(factory_);
        (bool active,, address rt,,,,,,,,) = f.markets(marketId_);
        if (!active || rt == address(0)) revert BadParams();
        address swap = f.swapRouter();
        if (swap == address(0)) revert BadParams();

        factory = factory_;
        _marketId = marketId_;
        isLong = false; // 헤지 leg는 숏
        owner = owner_;
        treasury = treasury_;
        usdc = IERC20(f.usdc());
        _assetRToken = IRToken(rt);
        swapRouter = ISwapRouter02(swap);
        swapFee = f.swapFee();

        _ry.state = RYieldState.Idle;
        _ry.depositCap = type(uint256).max; // 무제한 — owner가 setDepositCap으로 상한 설정 가능
        _ry.minDeposit = 500e6; // 500 USDC — 고정비용 상쇄 컷라인
        _ry.pool = pool_;
        _ry.twapWindow = 60; // 1분 TWAP (0이면 spot 폴백)
        _ry.perfFeeBps = 1_000; // 10% (§7.1/§10.5)
        _ry.swapSlippageBps = 100; // 1% AMM 슬리피지 허용
        _ry.maxEntryPremiumBps = 0; // AMM < GMX 강제
        _ry.maxExitDiscountBps = 0; // AMM >= GMX 강제 (종료 게이트)
        _ry.maxPriceImpactBps = 30; // 0.3% — 1회 롱 매수 가격충격 한도(나머지는 idle 대기)
        _ry.gapCheckEnabled = true; // 방향성 역전 방어 on
        _ry.targetLeverage = 1; // GMX 숏 1x — 현물 롱과 동일 담보 비율(베이시스)
        _ry.hwmAssetsPerShareWad = WAD; // 1.0 시작

        usdc.forceApprove(f.gmxInfra().gmxRouter, type(uint256).max);
    }

    receive() external payable {} // GMX exec fee 환불 수령

    // ── 등록·source (UI 조회는 RYieldRegistry / RYieldViews) ─────────────────────

    function marketId() external view returns (bytes32) {
        return _marketId;
    }

    function rToken() external view returns (address) {
        return address(_assetRToken);
    }

    // ── 내부 NAV·게이트 (mutate 경로 전용) ─────────────────────────────────────

    function _execFee() internal view returns (uint256) {
        return IVaultFactory(factory).gmxInfra().execFee;
    }

    function _longRTokenBalance() internal view returns (uint256) {
        return _assetRToken.balanceOf(address(this));
    }

    function _longValueUsdc() internal view returns (uint256) {
        uint256 bal = _longRTokenBalance();
        return bal == 0 ? 0 : Units.rTokenToUsdc(bal, _oracle().getPrice());
    }

    function _shortEquityUsdc() internal view returns (uint256) {
        return Units.wadToUsdc(_gmxPositionValueUsdWad());
    }

    function _idleUsdc() internal view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 reserved = _ry.reservedClaimableUsdc;
        return bal > reserved ? bal - reserved : 0;
    }

    function _totalAssetsUsdc() internal view returns (uint256) {
        return _idleUsdc() + _longValueUsdc() + _shortEquityUsdc();
    }

    function _pricePerShareWad() internal view returns (uint256) {
        uint256 ts = _ry.totalShares;
        if (ts == 0) return WAD;
        return (_totalAssetsUsdc() * WAD) / ts;
    }

    function _ammPrice8() internal view returns (uint256) {
        if (_ry.pool == address(0)) return 0;
        return AmmTwap.rTokenPrice8(_ry.pool, address(_assetRToken), address(usdc), _ry.twapWindow);
    }

    function _currentGapBps() internal view returns (int256) {
        return _gapBps(_oracle().getPrice(), _ammPrice8());
    }

    function _hedgedAssetsUsdc() internal view returns (uint256) {
        return _longValueUsdc() + _shortEquityUsdc();
    }

    function _gapBps(uint256 gmxPrice8, uint256 ammP8) internal pure returns (int256) {
        if (gmxPrice8 == 0) return 0;
        return ((int256(gmxPrice8) - int256(ammP8)) * int256(BPS)) / int256(gmxPrice8);
    }

    /// @dev 롱 매수액을 두 상한의 더 작은 값으로 축소(초과분은 호출부에서 idle 대기):
    ///      (a) price impact 캡 — 풀 깊이 대비 maxPriceImpactBps (0이면 무제한).
    ///      (b) 갭 밴드 캡 — gapCheck on일 때만. 밴드 = 현재갭 + maxEntryPremiumBps(bps). 매수가 이 밴드만큼
    ///          AMM 가격을 올리면 GMX(+premium)에 닿으므로, 그 지점까지만 사면 매수 도중에도 AMM ≤ GMX(+premium).
    ///          밴드 ≤ 0(이미 경계/역프리미엄)이면 캡 0 → 매수 없음(NothingToRebalance).
    /// @param gapSnap 매수 전 spot 갭(bps). gapCheck off면 (b) 미적용.
    function _cappedLongUsdc(uint256 desiredLong, int256 gapSnap) internal view returns (uint256) {
        if (_ry.pool == address(0)) return desiredLong;
        uint256 cap = type(uint256).max;
        // (a) 설정 impact 캡 (0 = 무제한)
        if (_ry.maxPriceImpactBps != 0) {
            cap = AmmTwap.maxUsdcInForImpact(_ry.pool, address(usdc), address(_assetRToken), _ry.maxPriceImpactBps);
        }
        // (b) 갭 밴드 캡
        if (_ry.gapCheckEnabled) {
            int256 band = gapSnap + int256(uint256(_ry.maxEntryPremiumBps));
            uint256 bandCap = band <= 0
                ? 0
                : AmmTwap.maxUsdcInForImpact(_ry.pool, address(usdc), address(_assetRToken), uint16(uint256(band)));
            if (bandCap < cap) cap = bandCap;
        }
        return desiredLong < cap ? desiredLong : cap;
    }

    // ── 예치 / 인출 ─────────────────────────────────────────────────────────────

    /// @notice USDC 예치 → NAV 기준 share 발행. cap 초과·0지분 거부. 헤지 콜백 대기 중엔 불가(whenIdle).
    /// @dev GMX는 비동기라 헤지 주문마다 ETH exec fee가 든다. 예치 시 유저가 1회분(gmxInfra.execFee) ETH를
    ///      함께 보내 vault ETH 풀을 채운다. 이 ETH는 USDC NAV와 무관(share 회계는 USDC만) — 봇의 배치
    ///      rebalance/executeUnwind가 이 풀에서 execFee를 쓰고, GMX 미사용분 환불도 vault로 귀속되어 다음 주문에 재사용된다.
    function deposit(uint256 usdcAmount) external payable whenIdle nonReentrant returns (uint256 shares) {
        if (IVaultFactory(factory).paused()) revert BadState();
        if (usdcAmount == 0) revert ZeroAmount();
        if (usdcAmount < _ry.minDeposit) revert BelowMinDeposit();
        if (msg.value < _execFee()) revert InsufficientExecFee();
        _harvestFundingHook(); // 지분 변동 전 pending 선수거 → 신규 예치자의 과거 펀딩비 희석 취득 차단
        _accruePerfFee();
        uint256 ts = _ry.totalShares;
        uint256 navBefore = _totalAssetsUsdc();
        if (navBefore + usdcAmount > _ry.depositCap) revert CapExceeded();
        if (ts == 0) {
            shares = usdcAmount;
        } else {
            if (navBefore == 0) revert BadState();
            shares = (usdcAmount * ts) / navBefore;
        }
        if (shares == 0) revert ZeroShares();
        _fundingAccrue(msg.sender);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        _ry.sharesOf[msg.sender] += shares;
        _ry.totalShares = ts + shares;
        _fundingSetDebt(msg.sender);
        _updateHwm();
        emit Deposited(msg.sender, usdcAmount, shares);
    }

    /// @notice 지분 소각 → NAV 비례 USDC 인출. '내 pro-rata idle 몫'까지만 즉시 인출 가능.
    /// @dev idle 인출은 헤지를 풀지 않는 100% 지분비례라 잔여 holder의 1주당 NAV가 불변 → 타인 피해 없음.
    ///      단 호출자가 가져갈 수 있는 한도는 '자기 idle 몫(shares/ts × idle)'으로 제한해 타인 idle 잠식을 막는다.
    ///      헤지된 몫까지 빼려면 requestUnwind()로 상환 큐에 넣고 봇 executeUnwind() 후 claimUnwind()로 받는다.
    function withdraw(uint256 shares) external whenIdle nonReentrant returns (uint256 usdcOut) {
        if (shares == 0) revert ZeroAmount();
        uint256 userShares = _ry.sharesOf[msg.sender];
        if (shares > userShares) revert InsufficientShares();
        _harvestFundingHook(); // 지분 변동 전 pending 선수거 → 인출자 몫까지 정확히 확정 적립
        _accruePerfFee();
        uint256 ts = _ry.totalShares;
        usdcOut = (shares * _totalAssetsUsdc()) / ts;
        // 자기 idle 몫 한도: 호출자 보유 share의 idle 비율(= userShares/ts × idle)까지만 현금화 가능.
        // 그 이상(헤지 backing 몫)을 빼려면 requestUnwind로 큐잉해야 한다. 타인 idle 잠식·NAV 왜곡 방지.
        uint256 idleShareCap = (userShares * _idleUsdc()) / ts;
        if (usdcOut > idleShareCap) revert ExceedsIdleShare();
        _fundingAccrue(msg.sender);
        _ry.sharesOf[msg.sender] = userShares - shares;
        _ry.totalShares = ts - shares;
        _fundingSetDebt(msg.sender);
        usdc.safeTransfer(msg.sender, usdcOut);
        _updateHwm();
        emit Withdrawn(msg.sender, shares, usdcOut);
    }

    // ── 헤지 실행 (permissionless) ───────────────────────────────────────────────

    /// @notice 유휴 USDC를 델타뉴트럴 헤지로 배치. 누구나 호출(봇이 주기 실행). 버퍼 없이 전액 배치 시도.
    /// @dev 델타중립: 롱 명목 = 숏 명목 N. 목표 longUsdc = idle·L/(L+1), shortCol = longUsdc/L.
    ///      ① 방향성 역전 방어: AMM가격 < GMX가격(+maxEntryPremiumBps)일 때만 진입.
    ///      ② price impact 한도: 풀 깊이상 maxPriceImpactBps 내로만 롱을 매수하고, 못 들어간 USDC는
    ///         idle로 남아 다음 rebalance 호출에서 처리된다(대기 수량).
    ///      ③ short-first: 숏(GMX increase) 먼저 제출(비동기) → SettlingHedge. longUsdc는 idle에 예약만 하고,
    ///         숏 체결 콜백에서 그 체결 시점에 AMM 롱을 매수해 delta 갭 노출 구간을 최소화한다.
    ///      execFee는 vault ETH 잔고(또는 msg.value)에서 GMX가 차감.
    function rebalance() external payable whenIdle nonReentrant {
        if (IVaultFactory(factory).paused()) revert BadState();
        _accruePerfFee();
        uint8 lev = _ry.targetLeverage;
        uint256 deployable = _idleUsdc(); // 버퍼 없음 — 전액 배치 시도
        uint256 desiredLong = (deployable * lev) / (uint256(lev) + 1);

        // ① 진입 게이트 + 갭 스냅샷 (매수 전 spot 기준)
        int256 gapSnap = 0;
        if (_ry.gapCheckEnabled) {
            uint256 gmxP = _oracle().getPrice();
            uint256 ammP = _ammPrice8();
            // AMM이 GMX보다 maxEntryPremiumBps 넘게 비싸면(역프리미엄) 진입 차단
            if (ammP > (gmxP * (BPS + _ry.maxEntryPremiumBps)) / BPS) revert EntryPremiumTooHigh();
            gapSnap = _gapBps(gmxP, ammP);
        }

        // ② 매수 수량 캡: price impact 한도와 '갭 밴드'의 더 작은 쪽까지만 집행(나머지 idle 대기).
        //    매수가 진행되면 AMM 가격이 오르므로, AMM이 GMX(+premium)에 닿는 지점 = 현재갭+premium 만큼의
        //    가격충격까지만 사면 매수 도중에도 AMM ≤ GMX(+premium)가 유지된다. 갭이 넓으면 0.3% impact가 상한.
        uint256 longUsdc = _cappedLongUsdc(desiredLong, gapSnap);
        uint256 shortCol = longUsdc / lev;
        if (shortCol < MIN_REBALANCE_USDC || longUsdc < MIN_REBALANCE_USDC) revert NothingToRebalance();

        // ③ 숏 leg 먼저: GMX market increase (비동기). 롱은 콜백에서.
        leverage = lev;
        bytes32 key = _gmxCreateOpenOrder(shortCol, _oracle().getPrice(), lev, 0);

        _ry.state = RYieldState.SettlingHedge;
        _ry.pendingOrderKey = key;
        _ry.pendingCreatedAt = block.timestamp;
        _ry.pendingLongUsdc = longUsdc;
        _ry.pendingEntryGapBps = gapSnap;
        _ry.pendingHedgeNotionalUsdc = longUsdc; // 숏 명목 ≈ longUsdc (= shortCol·L)
        emit RebalanceRequested(key, longUsdc, shortCol, 0);
    }

    // ── 상환 큐 (per-user unwind) ────────────────────────────────────────────────

    /// @notice 헤지된 내 몫을 청산받기 위해 share를 상환 큐에 적재. 최대 보유 share까지(초과 시 revert).
    /// @dev share를 sharesOf→redeemShares로 옮겨 락(여전히 totalShares에 포함되어 NAV·손익을 부담).
    ///      봇이 executeUnwind()로 배치 청산하면 체결 시점 NAV로 평가되고, 이후 claimUnwind()로 수령한다.
    ///      idle 몫은 굳이 큐 없이 withdraw로 즉시 인출하는 게 효율적(헤지 안 푼 몫이 대상).
    function requestUnwind(uint256 shares) external whenIdle nonReentrant {
        if (shares == 0) revert ZeroAmount();
        uint256 userShares = _ry.sharesOf[msg.sender];
        if (shares > userShares) revert InsufficientShares();
        // 직전 체결분 미청구 상태면 먼저 claim 요구(epoch 혼선 방지).
        if (_ry.redeemShares[msg.sender] > 0 && _ry.redeemReqEpoch[msg.sender] != _ry.currentRedeemEpoch) {
            revert ClaimPending();
        }
        _harvestFundingHook(); // 지분(funding) 변동 전 pending 선수거
        _accruePerfFee();
        _fundingAccrue(msg.sender);
        _ry.sharesOf[msg.sender] = userShares - shares;
        _ry.redeemShares[msg.sender] += shares;
        _fundingSetDebt(msg.sender);
        uint256 epoch = _ry.currentRedeemEpoch;
        _ry.redeemReqEpoch[msg.sender] = epoch;
        _ry.epochRedeemShares[epoch] += shares; // 코호트 총량(청산 지급 분모) 누적
        _ry.totalRedeemShares += shares;
        emit UnwindRequested(msg.sender, shares);
    }

    /// @notice 아직 체결되지 않은(현재 epoch) 내 상환 요청을 취소하고 share를 복원.
    function cancelUnwindRequest() external whenIdle nonReentrant {
        uint256 sh = _ry.redeemShares[msg.sender];
        if (sh == 0) revert ZeroShares();
        if (_ry.redeemReqEpoch[msg.sender] != _ry.currentRedeemEpoch) revert ClaimPending(); // 이미 체결 → claim
        _harvestFundingHook(); // funding 지분 복원 전 pending 선수거
        _fundingAccrue(msg.sender);
        _ry.sharesOf[msg.sender] += sh;
        _ry.totalRedeemShares -= sh;
        _ry.epochRedeemShares[_ry.redeemReqEpoch[msg.sender]] -= sh; // 코호트 총량 복원(미봉인 epoch)
        _ry.redeemShares[msg.sender] = 0;
        _fundingSetDebt(msg.sender);
        emit UnwindCancelled(msg.sender, sh);
    }

    /// @notice GMX funding 수확: claimable claimFundingFees+affiliate → distributor. accrued는 settleAccruedFee 별도.
    /// @dev settle과 분리(GMX UI와 동일 2-step). 입출금 anti-dilution 훅도 claimable만 선수거.
    function harvestFunding() external nonReentrant {
        if (fundingDistributor == address(0)) revert BadParams();
        _doHarvest(true);
    }

    /// @notice GMX 미수령 담보(가격충격/ADL 정산 잔여)를 distributor로 수확(무허가). keeper가 timeKey를 넣는다.
    /// @dev claimable collateral은 (market, token, timeKey, account) 키라 온체인 열거가 불가 → 봇이 off-chain
    ///      인덱싱으로 claimable>0인 timeKey를 찾아 long/short별로 전달. funding과 동일 토큰이라 같은 버킷에 합산.
    /// @param longTimeKeys long 토큰 미수령 담보의 정산 시각 버킷들
    /// @param shortTimeKeys short 토큰 미수령 담보의 정산 시각 버킷들
    function harvestCollateral(uint256[] calldata longTimeKeys, uint256[] calldata shortTimeKeys)
        external
        nonReentrant
    {
        address fd = fundingDistributor;
        if (fd == address(0)) revert BadParams();
        address router = IVaultFactory(factory).gmxInfra().exchangeRouter;
        if (router == address(0)) revert BadParams();
        (uint256 longAmt, uint256 shortAmt) =
            GmxFundingUtils.harvestCollateralToDistributor(router, fd, longTimeKeys, shortTimeKeys);
        emit FundingHarvested(longAmt, shortAmt);
    }

    /// @dev GMX harvest: claimFundingFees+affiliate → distributor notify. accrued settle은 settleAccruedFee(유저 1단계) 전용.
    function _doHarvest(bool strict) internal {
        address fd = fundingDistributor;
        if (fd == address(0)) return;
        address router = IVaultFactory(factory).gmxInfra().exchangeRouter;
        if (router == address(0)) {
            if (strict) revert BadParams();
            return;
        }
        (bool ok, uint256 longAmt, uint256 shortAmt) = GmxFundingUtils.harvestToDistributor(router, fd, strict);
        if (ok) emit FundingHarvested(longAmt, shortAmt);
    }

    /// @dev GMX accrued funding → claimable 전환 시도. 헤지 상태머신(SettlingHedge/Unwind) 중·미체결 settle 있으면 skip.
    /// @return submitted 이번 호출에서 새 settle 주문을 제출했으면 true.
    function _trySettleAccruedFunding() internal returns (bool submitted) {
        if (_ry.state != RYieldState.Idle) return false;
        if (!_gmxStore.mockActive) return false;
        bytes32 pendingKey = _gmxStore.pendingFundingSettleRyexKey;
        if (pendingKey != bytes32(0) && !_gmxStore.orders[pendingKey].executed) return false;
        try this._execSettleAccruedFunding() {
            return true;
        } catch {
            return false;
        }
    }

    /// @inheritdoc IRYieldVaultShares
    function requestAccruedFundingSettle() external returns (bool submitted) {
        return _trySettleAccruedFunding();
    }

    /// @inheritdoc IRYieldVaultShares
    function fundingSettlePending() external view returns (bool) {
        bytes32 k = _gmxStore.pendingFundingSettleRyexKey;
        return k != bytes32(0) && !_gmxStore.orders[k].executed;
    }

    /// @inheritdoc IRYieldVaultShares
    /// @dev GMX UI Accrued와 동일 — settle 전 포지션에 붙어 있는 펀딩비(Reader.getPositionInfo). 표시 전용 추정.
    function vaultAccruedFundingGmx() external view returns (uint256 longAmount, uint256 shortAmount) {
        if (!_gmxStore.mockActive) return (0, 0);
        return GmxFundingAccruedView.accruedFunding(
            factory, _marketId, address(this), address(usdc), isLong, _oracle().getPrice()
        );
    }

    /// @dev try/catch 대상 — 실패해도 claim 경로는 계속(ETH 부족·GMX 일시 오류 등).
    function _execSettleAccruedFunding() external {
        if (msg.sender != address(this)) revert BadParams();
        (bytes32 orderKey,) = _gmxCreateSettleFundingOrder();
        emit FundingSettleRequested(orderKey, _gmxStore.orders[orderKey].gmxKey);
    }

    /// @dev 입출금·상환요청 직전 선(先)수거 훅 (anti-dilution 핵심).
    ///      지분율 변동 전에 GMX claimable 펀딩비를 먼저 수거·확정 적립해, 방금 들어온 예치자가 과거에 쌓인
    ///      펀딩비를 지분율로 가로채는 희석 공격을 원천 차단한다. totalShares==0이면 배분 대상 없음 → skip.
    function _harvestFundingHook() internal {
        if (fundingDistributor == address(0) || _ry.totalShares == 0) return;
        _doHarvest(false);
    }

    /// @notice 대기 중인 상환 큐를 가격조건 한도 내 수량만큼 청산. 누구나 호출(봇 주기 실행). payable(GMX execFee).
    /// @dev 진입(rebalance)과 대칭: gapCheck on이면 AMM >= GMX(−maxExitDiscountBps)일 때만 실행하고,
    ///      롱 매도가 AMM을 그 경계 밑으로 밀지 않는 밴드·price impact 한도 내 share(fill)만 이번에 청산한다.
    ///      한 epoch(코호트)이 한 번에 다 안 들어가면 잔여는 큐에 남아 다음 호출에서 이어 청산(= idle 대기)되고,
    ///      전량 청산(settlingRemainingShares==0)돼야 해당 epoch claim이 열린다. 지급액은 청크별로 누적한다.
    ///      각 청크: freed + 상환자 idle 몫을 epoch payout에 더하고 fill share 소각 → 잔여 holder NAV 불변.
    function executeUnwind() external payable whenIdle nonReentrant {
        if (IVaultFactory(factory).paused()) revert BadState();
        _accruePerfFee();

        // ① 청산 대상 epoch(코호트) 결정: 진행 중이면 이어서, 아니면 현재 epoch을 봉인(seal)하고 시작.
        uint256 epoch;
        uint256 remaining;
        if (_ry.settlingRemainingShares > 0) {
            epoch = _ry.settlingEpoch; // 이전 호출에서 일부만 청산 → 잔여 이어서 처리
            remaining = _ry.settlingRemainingShares;
        } else {
            epoch = _ry.currentRedeemEpoch;
            remaining = _ry.epochRedeemShares[epoch];
            if (remaining == 0) revert NothingToRebalance();
            _ry.currentRedeemEpoch = epoch + 1; // 봉인: 신규 requestUnwind는 다음 epoch으로
            _ry.settlingEpoch = epoch;
            _ry.settlingRemainingShares = remaining;
        }

        // ② 종료 게이트 + 이번 청크에서 청산할 수량(share) 상한. 진입과 대칭: AMM>=GMX일 때 밴드 한도만큼만.
        uint256 ts = _ry.totalShares;
        uint256 fill = _cappedUnwindShares(remaining, ts);
        if (fill == 0) revert NothingToRebalance();

        // ③ 이번 청크 스냅샷 (fill 몫만큼만 비례 청산)
        _ry.pendingRedeemShares = fill;
        _ry.pendingRedeemEpoch = epoch;
        _ry.pendingIdleSnapshotUsdc = _idleUsdc();
        _ry.pendingIdleReserveUsdc = (fill * _idleUsdc()) / ts; // 상환자 기존 idle 몫
        _ry.pendingLongUsdc = (_longRTokenBalance() * fill) / ts; // 콜백에서 매도할 롱 rToken
        _ry.pendingHedgeNotionalUsdc = (_ry.hedgedNotionalUsdc * fill) / ts; // 차감할 헤지 명목
        _ry.pendingCreatedAt = block.timestamp;

        if (_gmxStore.mockActive) {
            // 숏 비례 청산 먼저(비동기). 롱 매도·지급확정은 체결 콜백 _finalizeUnwindBatch에서.
            _ry.state = RYieldState.SettlingUnwind;
            bytes32 key;
            if (fill >= ts) {
                key = _gmxCreateCloseOrder(0); // 전량 — 절대 instant 아님
            } else {
                uint256 shortRedeemUsdc = (_shortEquityUsdc() * fill) / ts;
                if (shortRedeemUsdc == 0) shortRedeemUsdc = 1; // dust 가드 (createRedeemOrder는 0 거부)
                (key,) = _gmxCreateRedeemOrder(shortRedeemUsdc); // mock이면 instant → 콜백 즉시 finalize
            }
            if (_ry.state == RYieldState.SettlingUnwind) {
                _ry.pendingOrderKey = key; // instant면 이미 Idle 복귀이므로 생략
            }
        } else {
            // 숏 없음 — 롱만 즉시 비례 매도 후 동기 finalize.
            uint256 sell = _ry.pendingLongUsdc;
            uint256 bal = _longRTokenBalance();
            if (sell > bal) sell = bal;
            if (sell > 0) _swapRTokenForUsdc(sell);
            _finalizeUnwindBatch();
        }
    }

    /// @dev 이번 executeUnwind에서 청산할 share 수량. 진입(_cappedLongUsdc)의 종료 대칭:
    ///      ① 종료 게이트 — gapCheck on이면 AMM >= GMX·(1-maxExitDiscountBps)일 때만(아니면 revert).
    ///      ② 수량 캡 — 롱 매도가 AMM 가격을 밴드(=현재 종료갭+discount)·price impact 한도 밖으로 밀지 않도록,
    ///         그 한도 내 USDC 매도액에 해당하는 share까지만. 초과분은 큐에 남아 다음 호출에서 처리(= idle).
    function _cappedUnwindShares(uint256 remaining, uint256 ts) internal view returns (uint256) {
        if (ts == 0) return 0;
        uint256 longVal = _longValueUsdc();

        // 게이트 off거나 롱이 없으면(매도할 AMM leg 없음) 밴드 캡 불필요 → 전량 처리.
        if (!_ry.gapCheckEnabled) return remaining;

        uint256 gmxP = _oracle().getPrice();
        uint256 ammP = _ammPrice8();
        // AMM이 GMX보다 maxExitDiscountBps 넘게 싸면(정프리미엄) 종료 차단
        if (ammP < (gmxP * (BPS - _ry.maxExitDiscountBps)) / BPS) revert ExitDiscountTooHigh();

        if (longVal == 0) return remaining; // 매도할 롱 없음 → 가격충격 없음
        if (_ry.pool == address(0)) return remaining; // 게이트 통과했으면 pool 설정됨(방어적 폴백)

        // 매도 캡(USDC): price impact 한도와 '종료 밴드' 중 작은 쪽. 밴드 = (AMM-GMX)/GMX + discount(bps).
        // 매도가 진행되면 AMM 가격이 내려가므로, AMM이 GMX(-discount)에 닿는 지점까지만 팔면 종료 도중에도 AMM >= 경계.
        uint256 cap = type(uint256).max;
        if (_ry.maxPriceImpactBps != 0) {
            cap = AmmTwap.maxUsdcInForImpact(_ry.pool, address(usdc), address(_assetRToken), _ry.maxPriceImpactBps);
        }
        int256 band = -_gapBps(gmxP, ammP) + int256(uint256(_ry.maxExitDiscountBps));
        // 밴드<=0(경계/역방향)이면 매도 0 (impactBps=0은 '무제한'이라 직접 0으로 처리 — 진입과 동일).
        uint256 bandCap = band <= 0
            ? 0
            : AmmTwap.maxUsdcInForImpact(
                _ry.pool,
                address(usdc),
                address(_assetRToken),
                band > int256(uint256(type(uint16).max)) ? type(uint16).max : uint16(uint256(band))
            );
        if (bandCap < cap) cap = bandCap;
        if (cap == type(uint256).max) return remaining; // 캡 없음

        // 매도 캡(USDC) → share 환산: 롱 전체(ts share) 가치 longVal 기준 비례.
        uint256 qCap = (cap * ts) / longVal;
        return remaining < qCap ? remaining : qCap;
    }

    /// @notice 체결 완료된 내 상환분을 USDC로 수령(share는 이미 소각됨).
    function claimUnwind() external nonReentrant returns (uint256 usdcOut) {
        uint256 sh = _ry.redeemShares[msg.sender];
        if (sh == 0) revert ZeroShares();
        uint256 epoch = _ry.redeemReqEpoch[msg.sender];
        if (epoch >= _ry.currentRedeemEpoch) revert BadState(); // 아직 미봉인
        if (epoch == _ry.settlingEpoch && _ry.settlingRemainingShares > 0) revert BadState(); // 분할 청산 진행 중
        uint256 es = _ry.epochRedeemShares[epoch];
        usdcOut = es == 0 ? 0 : (sh * _ry.epochPayoutUsdc[epoch]) / es;
        _ry.redeemShares[msg.sender] = 0;
        if (usdcOut > 0) {
            _ry.reservedClaimableUsdc -= usdcOut;
            usdc.safeTransfer(msg.sender, usdcOut);
        }
        emit UnwindClaimed(msg.sender, usdcOut);
    }

    /// @dev 청크 청산 확정: freed + 상환자 idle 몫을 epoch 지급액에 누적, 소각·헤지명목 차감·잔여 갱신.
    ///      epochRedeemShares(코호트 총량)는 requestUnwind에서 확정 → 여기선 덮어쓰지 않고 payout만 누적한다.
    ///      settlingRemainingShares가 0이 되면 해당 epoch 전량 청산 완료 → claim 가능(그 전까진 claim 불가).
    function _finalizeUnwindBatch() internal {
        uint256 freed = _idleUsdc() > _ry.pendingIdleSnapshotUsdc ? _idleUsdc() - _ry.pendingIdleSnapshotUsdc : 0;
        uint256 payout = _ry.pendingIdleReserveUsdc + freed;
        uint256 epoch = _ry.pendingRedeemEpoch;
        uint256 fill = _ry.pendingRedeemShares;
        _ry.epochPayoutUsdc[epoch] += payout; // 여러 청크에 걸쳐 누적
        _ry.reservedClaimableUsdc += payout;
        _ry.totalShares -= fill; // 상환 share 소각
        _ry.totalRedeemShares -= fill; // 큐에서 제거
        _ry.settlingRemainingShares -= fill; // 이 epoch 잔여 청산량 감소 (0 = 완료 → claim 개방)
        _reduceHedgeNotional(_ry.pendingHedgeNotionalUsdc);
        _clearPending();
        _updateHwm();
        emit UnwindExecuted(epoch, fill, payout);
    }

    /// @dev 헤지 명목을 차감(전량이면 진입갭도 리셋). entryGap은 가중평균이라 부분 청산 시 불변.
    function _reduceHedgeNotional(uint256 removeN) internal {
        if (removeN >= _ry.hedgedNotionalUsdc) {
            _ry.hedgedNotionalUsdc = 0;
            _ry.entryGapBps = 0;
        } else {
            _ry.hedgedNotionalUsdc -= removeN;
        }
    }

    /// @notice 콜백이 오지 않는 헤지 주문을 타임아웃 후 직접 정산(탈출 경로). 누구나 호출.
    /// @dev GMX 주문 목록에서 빠진 뒤 GmxIntegrationBase.settleGmxOrder(gmxKey)로 정산하는 것이 우선이며,
    ///      이 함수는 mock(gmxKey==0) 또는 미체결 취소 요청용 보조 경로.
    function cancelStuckHedge() external nonReentrant {
        if (_ry.state == RYieldState.Idle) revert BadState();
        if (block.timestamp <= _ry.pendingCreatedAt + SETTLING_TIMEOUT) revert NotTimedOut();
        bytes32 key = _ry.pendingOrderKey;
        _gmxRequestCancellation(key); // instant면 콜백이 _onRyexOrderCancelled로 상태 정리
        emit StuckHedgeRecovered(key);
    }

    // ── GMX 정산 콜백 (GmxIntegrationBase override) ──────────────────────────────

    function _onRyexOrderExecuted(bytes32 orderKey, uint8 kind) internal override {
        if (kind == GmxConstants.KIND_SETTLE_FUNDING) {
            _gmxStore.pendingFundingSettleRyexKey = bytes32(0);
            return; // 헤지 상태머신 무관 — accrued→claimable 정산만
        }
        if (_ry.state == RYieldState.SettlingHedge) {
            if (orderKey != _ry.pendingOrderKey) revert BadKey();
            // 숏 체결 확정 → 이제 예약 USDC로 AMM 롱 매수(short-first: delta 갭 노출 최소화)
            uint256 longUsdc = _ry.pendingLongUsdc;
            uint256 idle = _idleUsdc();
            if (longUsdc > idle) longUsdc = idle; // 안전 가드
            uint256 bought = longUsdc > 0 ? _swapUsdcForRToken(longUsdc) : 0;
            _commitEntryGap(_ry.pendingEntryGapBps, _ry.pendingHedgeNotionalUsdc);
            _clearPending();
            _updateHwm();
            emit RebalanceRequested(orderKey, longUsdc, 0, bought);
            emit HedgeOpened(orderKey);
        } else if (_ry.state == RYieldState.SettlingUnwind) {
            // 숏 close/redeem 체결 — 예약 비율만큼 롱 매도 후 배치 finalize(지급확정·share 소각).
            // mock redeem instant 시 이 콜백이 executeUnwind() 안에서 즉시 실행되며 pendingOrderKey가 아직 0이므로
            // 키 하드체크는 생략한다(whenIdle로 동시 pending 1건 보장 → state만으로 안전).
            uint256 sell = _ry.pendingLongUsdc;
            uint256 bal = _longRTokenBalance();
            if (sell > bal) sell = bal;
            if (sell > 0) _swapRTokenForUsdc(sell);
            _finalizeUnwindBatch();
            emit HedgeClosed(orderKey, sell);
        } else {
            revert BadState();
        }
    }

    function _onRyexOrderCancelled(bytes32 orderKey, uint8 kind) internal override {
        if (kind == GmxConstants.KIND_SETTLE_FUNDING) {
            _gmxStore.pendingFundingSettleRyexKey = bytes32(0);
            return;
        }
        if (orderKey != _ry.pendingOrderKey) revert BadKey();
        if (_ry.state == RYieldState.SettlingHedge) {
            // 숏 open 실패 → 롱은 아직 매수 안 함(short-first). 예약 USDC는 그대로 idle에 남으므로 별도 환원 불필요.
            _clearPending();
            emit HedgeOpenFailed(orderKey, 0);
        } else if (_ry.state == RYieldState.SettlingUnwind) {
            // 숏 close 취소 → 배치 미완. 큐(totalRedeemShares·epoch)는 그대로 두고 상태만 Idle 복귀 → 봇 재시도.
            _clearPending();
            emit HedgeCloseFailed(orderKey);
        } else {
            revert BadState();
        }
    }

    /// @dev 진입 갭을 명목가중 평균으로 누적.
    function _commitEntryGap(int256 gapSnap, uint256 addNotional) internal {
        uint256 oldN = _ry.hedgedNotionalUsdc;
        uint256 newN = oldN + addNotional;
        if (newN > 0) {
            _ry.entryGapBps = (_ry.entryGapBps * int256(oldN) + gapSnap * int256(addNotional)) / int256(newN);
        }
        _ry.hedgedNotionalUsdc = newN;
    }

    function _clearPending() internal {
        _ry.state = RYieldState.Idle;
        _ry.pendingOrderKey = bytes32(0);
        _ry.pendingCreatedAt = 0;
        _ry.pendingLongUsdc = 0;
        _ry.pendingEntryGapBps = 0;
        _ry.pendingHedgeNotionalUsdc = 0;
        _ry.pendingRedeemShares = 0;
        _ry.pendingRedeemEpoch = 0;
        _ry.pendingIdleReserveUsdc = 0;
        _ry.pendingIdleSnapshotUsdc = 0;
    }

    // ── 성과수수료 (high-water mark, treasury share dilution) ─────────────────────

    /// @dev NAV/share가 직전 HWM을 초과하면 초과분의 perfFeeBps를 treasury share로 발행(원금 불차감).
    function _accruePerfFee() internal {
        uint256 ts = _ry.totalShares;
        if (ts == 0) return;
        uint256 nav = _totalAssetsUsdc();
        uint256 pps = (nav * WAD) / ts;
        uint256 hwm = _ry.hwmAssetsPerShareWad;
        if (pps <= hwm) return;
        uint256 profitUsdc = ((pps - hwm) * ts) / WAD;
        uint256 feeUsdc = (profitUsdc * _ry.perfFeeBps) / BPS;
        if (feeUsdc == 0 || feeUsdc >= nav) {
            _ry.hwmAssetsPerShareWad = pps;
            return;
        }
        uint256 feeShares = (feeUsdc * ts) / (nav - feeUsdc);
        if (feeShares > 0) {
            _fundingAccrue(treasury);
            _ry.sharesOf[treasury] += feeShares;
            _ry.totalShares = ts + feeShares;
            _fundingSetDebt(treasury);
        }
        _ry.hwmAssetsPerShareWad = (nav * WAD) / _ry.totalShares;
        emit PerfFeeAccrued(feeUsdc, feeShares);
    }

    function _updateHwm() internal {
        uint256 ts = _ry.totalShares;
        if (ts == 0) {
            _ry.hwmAssetsPerShareWad = WAD;
            return;
        }
        uint256 pps = (_totalAssetsUsdc() * WAD) / ts;
        if (pps > _ry.hwmAssetsPerShareWad) _ry.hwmAssetsPerShareWad = pps;
    }

    // ── AMM 롱 leg (USDC ↔ rToken) ──────────────────────────────────────────────

    function _swapUsdcForRToken(uint256 usdcIn) internal returns (uint256 out) {
        uint256 expected = Units.usdWadToRToken(Units.usdcToWad(usdcIn), _oracle().getPrice());
        uint256 minOut = (expected * (BPS - _ry.swapSlippageBps)) / BPS;
        usdc.forceApprove(address(swapRouter), usdcIn);
        out = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(_assetRToken),
                fee: swapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdcIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        usdc.forceApprove(address(swapRouter), 0);
    }

    function _swapRTokenForUsdc(uint256 rTokenIn) internal returns (uint256 out) {
        uint256 expected = Units.rTokenToUsdc(rTokenIn, _oracle().getPrice());
        uint256 minOut = (expected * (BPS - _ry.swapSlippageBps)) / BPS;
        IERC20(address(_assetRToken)).forceApprove(address(swapRouter), rTokenIn);
        out = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(_assetRToken),
                tokenOut: address(usdc),
                fee: swapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: rTokenIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(address(_assetRToken)).forceApprove(address(swapRouter), 0);
    }

    // ── 거버넌스 파라미터 ─────────────────────────────────────────────────────────

    function setDepositCap(uint256 cap) external onlyOwner {
        if (cap == 0) revert BadParams();
        _ry.depositCap = cap;
        emit ParamsUpdated();
    }

    function setTargetLeverage(uint8 lev) external onlyOwner {
        if (lev < 1) revert BadParams();
        _ry.targetLeverage = lev;
        emit ParamsUpdated();
    }

    /// @notice rebalance 1회 AMM 롱 매수 최대 price impact(bps). 0 = 무제한(풀 깊이 체크 비활성).
    function setMaxPriceImpactBps(uint16 bps) external onlyOwner {
        if (bps >= BPS) revert BadParams();
        _ry.maxPriceImpactBps = bps;
        emit ParamsUpdated();
    }

    function setPerfFeeBps(uint16 bps) external onlyOwner {
        if (bps > 3_000) revert BadParams(); // 상한 30%
        _ry.perfFeeBps = bps;
        emit ParamsUpdated();
    }

    function setSwapSlippageBps(uint16 bps) external onlyOwner {
        if (bps >= BPS) revert BadParams();
        _ry.swapSlippageBps = bps;
        emit ParamsUpdated();
    }

    function setMinDeposit(uint256 amount) external onlyOwner {
        _ry.minDeposit = amount;
        emit ParamsUpdated();
    }

    /// @notice AMM 가격 게이트용 UniV3 rToken/USDC 풀.
    function setPool(address pool_) external onlyOwner {
        _ry.pool = pool_;
        emit ParamsUpdated();
    }

    /// @notice TWAP 윈도우(초). 0이면 spot(slot0) 폴백 (풀 observation 부족 시 운영).
    function setTwapWindow(uint32 window) external onlyOwner {
        _ry.twapWindow = window;
        emit ParamsUpdated();
    }

    /// @notice 방향성 역전 방어 on/off (진입·인출 게이트 공통).
    function setGapCheckEnabled(bool on) external onlyOwner {
        _ry.gapCheckEnabled = on;
        emit ParamsUpdated();
    }

    /// @notice 진입 시 AMM이 GMX보다 비싸도 허용하는 폭(bps). 0 = AMM<GMX 강제.
    function setMaxEntryPremiumBps(uint16 bps) external onlyOwner {
        if (bps >= BPS) revert BadParams();
        _ry.maxEntryPremiumBps = bps;
        emit ParamsUpdated();
    }

    /// @notice 종료 시 AMM이 GMX보다 싸도 허용하는 폭(bps). 0 = AMM>=GMX 강제.
    function setMaxExitDiscountBps(uint16 bps) external onlyOwner {
        if (bps >= BPS) revert BadParams();
        _ry.maxExitDiscountBps = bps;
        emit ParamsUpdated();
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert BadParams();
        treasury = treasury_;
        emit ParamsUpdated();
    }

    function setAssetName(string calldata name_) external onlyOwner {
        assetName = name_;
        emit ParamsUpdated();
    }

    /// @notice GMX funding fee 배분 컨트랙트 연결·교체 (owner). distributor.vault() == this 여야 한다.
    function setFundingDistributor(address distributor_) external onlyOwner {
        if (distributor_ == address(0)) revert BadParams();
        if (IRYieldFundingDistributor(distributor_).vault() != address(this)) revert BadParams();
        fundingDistributor = distributor_;
        emit FundingDistributorSet(distributor_);
    }

    function _fundingAccrue(address user) internal {
        address fd = fundingDistributor;
        if (fd != address(0)) IRYieldFundingDistributor(fd).accrueUser(user);
    }

    function _fundingSetDebt(address user) internal {
        address fd = fundingDistributor;
        if (fd != address(0)) IRYieldFundingDistributor(fd).setUserDebt(user);
    }

    // ── IRYieldVaultShares (funding distributor 전용) ───────────────────────────

    /// @inheritdoc IRYieldVaultShares
    function totalShares() external view returns (uint256) {
        return _ry.totalShares;
    }

    /// @inheritdoc IRYieldVaultShares
    function fundingSharesOf(address user) external view returns (uint256) {
        return _ry.sharesOf[user];
    }

    // ── IRYieldVaultSource (RYieldRegistry / RYieldViews 전용) ─────────────────

    /// @inheritdoc IRYieldVaultSource
    function ryieldPack() external view returns (RYieldLensPack memory p) {
        p.state = _ry.state;
        p.totalShares = _ry.totalShares;
        p.pendingOrderKey = _ry.pendingOrderKey;
        p.pendingCreatedAt = _ry.pendingCreatedAt;
        p.depositCap = _ry.depositCap;
        p.perfFeeBps = _ry.perfFeeBps;
        p.maxPriceImpactBps = _ry.maxPriceImpactBps;
        p.maxEntryPremiumBps = _ry.maxEntryPremiumBps;
        p.maxExitDiscountBps = _ry.maxExitDiscountBps;
        p.targetLeverage = _ry.targetLeverage;
        p.hwmAssetsPerShareWad = _ry.hwmAssetsPerShareWad;
        p.entryGapBps = _ry.entryGapBps;
        p.hedgedNotionalUsdc = _ry.hedgedNotionalUsdc;
        p.minDeposit = _ry.minDeposit;
        p.gapCheckEnabled = _ry.gapCheckEnabled;
        p.pool = _ry.pool;
        p.twapWindow = _ry.twapWindow;
        p.reservedClaimableUsdc = _ry.reservedClaimableUsdc;
        p.totalRedeemShares = _ry.totalRedeemShares;
        p.currentRedeemEpoch = _ry.currentRedeemEpoch;
        p.settlingEpoch = _ry.settlingEpoch;
        p.settlingRemainingShares = _ry.settlingRemainingShares;
    }

    /// @inheritdoc IRYieldVaultSource
    function sharesOf(address user) external view returns (uint256) {
        return _ry.sharesOf[user];
    }

    /// @inheritdoc IRYieldVaultSource
    function redeemSharesOf(address user) external view returns (uint256) {
        return _ry.redeemShares[user];
    }

    /// @inheritdoc IRYieldVaultSource
    function redeemReqEpoch(address user) external view returns (uint256) {
        return _ry.redeemReqEpoch[user];
    }

    /// @inheritdoc IRYieldVaultSource
    function epochPayoutUsdc(uint256 epoch) external view returns (uint256) {
        return _ry.epochPayoutUsdc[epoch];
    }

    /// @inheritdoc IRYieldVaultSource
    function epochRedeemShares(uint256 epoch) external view returns (uint256) {
        return _ry.epochRedeemShares[epoch];
    }

    /// @inheritdoc IRYieldVaultSource
    function lensGmxEquityUsdWad() external view returns (uint256) {
        return _gmxPositionValueUsdWad();
    }

    /// @inheritdoc IRYieldVaultSource
    function usdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @inheritdoc IRYieldVaultSource
    function rTokenBalance() external view returns (uint256) {
        return _assetRToken.balanceOf(address(this));
    }
}
