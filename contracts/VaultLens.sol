// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IVaultLens} from "./interfaces/IVaultLens.sol";
import {IVaultLensSource} from "./interfaces/IVaultLensSource.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPositionVault} from "./interfaces/IPositionVault.sol";
import {IGmxReader} from "./interfaces/IGmxReader.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LTVMath} from "./libraries/LTVMath.sol";
import {Units} from "./libraries/Units.sol";
import {GmxIntegrationReader} from "./libraries/GmxIntegrationReader.sol";
import {GmxLiquidationPrice} from "./libraries/GmxLiquidationPrice.sol";
import {GmxFundingAccruedView} from "./libraries/GmxFundingAccruedView.sol";
import {VaultState, VaultSnapshot, GmxPositionData, GmxInfra, OrderKind, RiskParams} from "./types/Types.sol";

/// @title VaultLens — UI/인덱서용 vault·마켓 조회 (PositionVault clone 경량화).
contract VaultLens is IVaultLens {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    IVaultFactory public immutable factory;

    constructor(IVaultFactory factory_) {
        require(address(factory_) != address(0), "zero factory");
        factory = factory_;
    }

    /// @dev 마켓 RiskParams + borrowAprBps는 vault가 아닌 factory.markets[] (PositionVault bytecode offload).
    ///      borrowAprBps는 마켓별 차등(owner setBorrowAprBps) — RiskParams(LTV 곡선)와는 별개 개념이라
    ///      두 번째 반환값으로 같이 내려준다(호출 1회로 양쪽 다 커버, 불필요한 중복 staticcall 방지).
    function _marketRisk(address vault) internal view returns (RiskParams memory r, uint16 borrowApr) {
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
            borrowApr
        ) = factory.markets(IVaultLensSource(vault).marketId());
    }

    function collateralValueUsdWad(address vault) public view returns (uint256) {
        IVaultLensSource v = IVaultLensSource(vault);
        VaultState s = v.state();
        uint256 gmxEquity;
        if ((s == VaultState.Active || s == VaultState.SettlingLiquidate) && v.posKey() != bytes32(0)) {
            gmxEquity = v.lensGmxEquityUsdWad();
        }
        return LTVMath.collateralValueUsdWad(s, v.posKey(), v.collateral(), gmxEquity);
    }

    function debtValueUsdWad(address vault) public view returns (uint256) {
        IVaultLensSource v = IVaultLensSource(vault);
        return Units.rTokenToUsdWad(v.debt(), v.oracle().getPrice());
    }

    function currentLTV(address vault) public view returns (uint256) {
        return LTVMath.currentLTVOrSentinel(collateralValueUsdWad(vault), debtValueUsdWad(vault));
    }

    function lltvBps(address vault) public view returns (uint256) {
        (RiskParams memory r,) = _marketRisk(vault);
        return LTVMath.lltvFromMaxLtv(r.maxLtv1xBps, r.bufferBps);
    }

    function rltBps(address vault) public view returns (uint256) {
        (RiskParams memory r,) = _marketRisk(vault);
        return LTVMath.rltFromMaxLtv(r.maxLtv1xBps);
    }

    function effectiveMaxLtvBps(address vault) public view returns (uint256) {
        IVaultLensSource v = IVaultLensSource(vault);
        (RiskParams memory r,) = _marketRisk(vault);
        uint8 lev = v.leverage();
        if (lev == 0) lev = 1;
        if (lev > r.maxLeverage) lev = r.maxLeverage;
        return LTVMath.effectiveMaxLtvBps(
            r.maxLtv1xBps, r.maxLtvAtMaxLevBps, lev, r.flatTier, r.maxLeverage
        );
    }

    function healthFactor(address vault) public view returns (uint256) {
        return LTVMath.healthFactor(currentLTV(vault), lltvBps(vault));
    }

    function isRedeemable(address vault) public view returns (bool) {
        IVaultLensSource v = IVaultLensSource(vault);
        return LTVMath.isActiveInRedemptionZone(
            v.state(), currentLTV(vault), rltBps(vault), lltvBps(vault)
        );
    }

    function isLiquidatable(address vault) public view returns (bool) {
        IVaultLensSource v = IVaultLensSource(vault);
        return v.state() == VaultState.Active
            && LTVMath.isLiquidatable(currentLTV(vault), lltvBps(vault));
    }

    function pendingFeesUsdc(address vault) public view returns (uint256) {
        IVaultLensSource v = IVaultLensSource(vault);
        uint256 fee = v.accruedFeesUsdc() + v.accruedBorrowFeeUsdc();
        uint256 last = v.lastAccrual();
        if (last != 0 && v.debt() > 0) {
            (, uint16 apr) = _marketRisk(vault);
            uint256 dt = block.timestamp - last;
            fee += (Units.rTokenToUsdc(v.debt(), v.oracle().getPrice()) * apr * dt) / (BPS * SECONDS_PER_YEAR);
        }
        return fee;
    }

    /// @notice 마켓별 borrow/stability fee APR(bps) 조회. 마켓마다 다를 수 있음(owner setBorrowAprBps) —
    ///         vault의 marketId 기준으로 factory.markets[]에서 읽는다.
    function borrowAprBps(address vault) public view returns (uint256) {
        (, uint16 apr) = _marketRisk(vault);
        return apr;
    }

    /// @notice [프론트 연동] "받을 수 있는 펀딩비" 배지/툴팁용 추정치. GMX UI의 "Accrued"와 동일한 값.
    /// @dev 프론트 참고사항 —
    ///   - 이 값은 vault가 **받을** 펀딩비만 나타낸다(반대편에서 지불 중이면 여기 안 잡히고 GMX 포지션
    ///     담보에서 자동 차감됨 — 즉 0이라고 "펀딩비 영향 없음"은 아니다).
    ///   - longAmt/shortAmt는 원자 단위(raw, decimals 미보정)이며, 마켓의 long/short 토큰 decimals가 다르다.
    ///     현재 모든 마켓이 USDC 담보라 short 토큰은 보통 USDC(6dec), long 토큰은 index 자산
    ///     (예: ETH 마켓이면 WETH 18dec)이다 — 화면 표시 전 토큰별 decimals로 나눠야 함.
    ///   - **표시 전용 추정치**다. 실제 클레임 금액은 `harvestFunding()`(GMX claimFundingFees) 실행 시점
    ///     기준이라 이 값과 소폭 다를 수 있음(같은 블록이 아니면 시간차 발생).
    ///   - 포지션 없음(posKey==0)이면 항상 (0, 0).
    ///   - `vaultInfo()`를 이미 호출한다면 `VaultSnapshot.accruedFundingLongAmt/ShortAmt`로 값이 같이 오므로
    ///     이 함수를 별도로 또 호출할 필요는 없다(폴링 주기가 다를 때만 단독 호출).
    function vaultAccruedFundingGmx(address vault) public view returns (uint256 longAmt, uint256 shortAmt) {
        IVaultLensSource v = IVaultLensSource(vault);
        if (v.posKey() == bytes32(0)) return (0, 0);
        return GmxFundingAccruedView.accruedFunding(
            address(factory), v.marketId(), vault, factory.usdc(), v.isLong(), v.oracle().getPrice()
        );
    }

    function gmxPosition(address vault) external view returns (GmxPositionData memory) {
        return _gmxPositionEnriched(vault);
    }

    function vaultInfo(address vault) external view returns (VaultSnapshot memory s) {
        IVaultLensSource v = IVaultLensSource(vault);
        (RiskParams memory risk, uint16 apr) = _marketRisk(vault);
        GmxPositionData memory gmx = _gmxPositionEnriched(vault);
        uint256 colVal = collateralValueUsdWad(vault);
        uint256 debtVal = debtValueUsdWad(vault);
        uint256 lltv = LTVMath.lltvFromMaxLtv(risk.maxLtv1xBps, risk.bufferBps);
        uint256 rlt = LTVMath.rltFromMaxLtv(risk.maxLtv1xBps);
        uint256 ltv = LTVMath.currentLTVOrSentinel(colVal, debtVal);

        s.owner = v.owner();
        s.marketId = v.marketId();
        s.state = v.state();
        s.leverage = v.leverage();
        s.isLong = v.isLong();
        s.posKey = v.posKey();
        s.collateralUsdc = v.collateral();
        s.debtRToken = v.debt();
        s.pendingKind = v.pending().kind;
        s.pendingOrderKey = v.pending().orderKey;
        s.pendingCreatedAt = v.pending().createdAt;
        s.maxLtv1xBps = risk.maxLtv1xBps;
        s.bufferBps = risk.bufferBps;
        s.maxLtvAtMaxLevBps = risk.maxLtvAtMaxLevBps;
        s.flatTier = risk.flatTier;
        s.maxLeverage = risk.maxLeverage;
        s.collateralValueUsdWad = colVal;
        s.debtValueUsdWad = debtVal;
        s.currentLtvBps = ltv;
        s.healthFactorWad = LTVMath.healthFactor(ltv, lltv);
        s.lltvBps = lltv;
        s.rltBps = rlt;
        s.effectiveMaxLtvBps = effectiveMaxLtvBps(vault);
        s.oraclePrice8 = v.oracle().getPrice();
        s.liquidationPrice8 = LTVMath.priceAtLtvBps(
            s.collateralUsdc, s.debtRToken, gmx.entryPrice8, s.leverage, s.isLong, lltv
        );
        s.borrowAprBps = apr;
        s.pendingFeesUsdc = pendingFeesUsdc(vault);
        s.pendingOpenCollateralUsdc =
            s.pendingOrderKey == bytes32(0) ? 0 : v.gmxOrders(s.pendingOrderKey).openCollateral;
        s.isRedeemable = isRedeemable(vault);
        s.isLiquidatable = isLiquidatable(vault);
        s.tpOrderKey = v.tpOrderKey();
        s.slOrderKey = v.slOrderKey();
        s.gmx = gmx;
        // 프론트: 펀딩비 추정치(raw, decimals 미보정) — 자세한 주의사항은 vaultAccruedFundingGmx() 참고.
        (s.accruedFundingLongAmt, s.accruedFundingShortAmt) = vaultAccruedFundingGmx(vault);
    }

    /// @dev vault 스냅샷(4필드 ABI) + entry 보정 + GMX liquidationPrice.
    function _gmxPositionEnriched(address vault) internal view returns (GmxPositionData memory data) {
        IVaultLensSource v = IVaultLensSource(vault);
        // clone은 배포 시점 4필드 반환 — 5필드 struct로 직접 decode하면 revert
        (data.exists, data.sizeInUsd, data.collateralAmount, data.entryPrice8) = v.lensGmxSnapshot();
        if (!data.exists) return data;

        (,,, address gmxMarket,,,,,,,) = factory.markets(v.marketId());
        GmxInfra memory infra = factory.gmxInfra();
        if (gmxMarket == address(0) || infra.reader == address(0)) return data;

        uint8 indexDec = _indexTokenDecimals(address(v.oracle()));
        if (data.entryPrice8 == 0) {
            bytes32 key = GmxIntegrationReader.positionKey(vault, gmxMarket, factory.usdc(), v.isLong());
            try IGmxReader(infra.reader).getPosition(infra.dataStore, key) returns (IGmxReader.PositionProps memory pos)
            {
                if (pos.numbers.sizeInTokens > 0) {
                    data.entryPrice8 = Units.gmxSizeToEntryPrice8(
                        pos.numbers.sizeInUsd, pos.numbers.sizeInTokens, indexDec
                    );
                }
            } catch {}
        }

        // pending fees는 best-effort; 실패해도 청산가 근사는 closingFee+maxImpact로 계산
        data.liquidationPrice8 = GmxLiquidationPrice.price8(
            infra.reader, infra.dataStore, vault, gmxMarket, factory.usdc(), v.isLong(), v.oracle().getPrice()
        );
    }

    /// @dev GmxPriceOracle.tokenDecimals(); 없으면 ETH(18) 가정.
    function _indexTokenDecimals(address oracle) internal view returns (uint8) {
        (bool ok, bytes memory ret) = oracle.staticcall(abi.encodeWithSignature("tokenDecimals()"));
        if (ok && ret.length >= 32) {
            uint256 d = abi.decode(ret, (uint256));
            if (d > 0 && d <= 18) return uint8(d);
        }
        return 18;
    }

    // ── RLT 상환존 (인덱서용 — 후보 vault만 isRedeemable 필터, eth_call 전용) ──

    /// @notice 후보 vault 주소만 redeemable 필터. 인덱서가 chunk(예: 100) 단위로 호출.
    function filterRedeemableVaults(address[] calldata vaults) external view returns (address[] memory redeemable) {
        uint256 n = vaults.length;
        address[] memory buf = new address[](n);
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            address v = vaults[i];
            if (v == address(0)) continue;
            if (isRedeemable(v)) buf[count++] = v;
        }
        redeemable = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            redeemable[i] = buf[i];
        }
    }

    function redeemableCount() external view returns (uint256 count) {
        uint256 n = factory.totalVaults();
        for (uint256 i = 0; i < n; i++) {
            if (isRedeemable(factory.vaultAt(i))) count++;
        }
    }

    function totalRedeemableDebt() external view returns (uint256 total) {
        uint256 n = factory.totalVaults();
        for (uint256 i = 0; i < n; i++) {
            address v = factory.vaultAt(i);
            if (isRedeemable(v)) total += IPositionVault(v).debt();
        }
    }

    function avgHealthRedeemable() external view returns (uint256) {
        uint256 n = factory.totalVaults();
        uint256 sum;
        uint256 cnt;
        for (uint256 i = 0; i < n; i++) {
            address v = factory.vaultAt(i);
            if (!isRedeemable(v)) continue;
            uint256 ltv = currentLTV(v);
            uint256 lltv = lltvBps(v);
            if (ltv == 0) continue;
            sum += LTVMath.healthFactorBps(ltv, lltv);
            cnt++;
        }
        return cnt == 0 ? 0 : sum / cnt;
    }

    // ── withdraw UI (잔존 USDC · 부채) ──

    function residualUsdc(address vault) external view returns (uint256) {
        return IERC20(factory.usdc()).balanceOf(vault);
    }

    function debtUsdc(address vault) public view returns (uint256) {
        IVaultLensSource v = IVaultLensSource(vault);
        uint256 d = v.debt();
        if (d == 0) return 0;
        return Units.wadToUsdc(Units.rTokenToUsdWad(d, v.oracle().getPrice()));
    }

    function canWithdraw(address vault) external view returns (bool) {
        return _canWithdraw(vault);
    }

    function _canWithdraw(address vault) internal view returns (bool) {
        IVaultLensSource v = IVaultLensSource(vault);
        if (v.pending().kind != OrderKind.None) return false;
        VaultState s = v.state();
        if (s == VaultState.SettlingOpen || s == VaultState.SettlingLiquidate) return false;
        return IERC20(factory.usdc()).balanceOf(vault) > 0;
    }

    /// @dev 실제 buyback 대기버킷 적립·owner burn은 시뮬레이션하지 않음. USDC 예산 기준 상한 추정.
    function previewWithdrawUsdc(address vault) external view returns (uint256) {
        if (!_canWithdraw(vault)) return 0;
        return _previewWithdrawUsdc(vault);
    }

    function _previewWithdrawUsdc(address vault) internal view returns (uint256) {
        uint256 bal = IERC20(factory.usdc()).balanceOf(vault);
        IVaultLensSource v = IVaultLensSource(vault);
        // GMX 열림: 부채는 포지션 담보 — vault 잔고(미배치 USDC)만 인출 가능.
        if (v.posKey() != bytes32(0)) return bal;

        uint256 fees = pendingFeesUsdc(vault);
        uint256 debtU = debtUsdc(vault);
        if (debtU == 0) {
            return fees >= bal ? 0 : bal - fees;
        }
        uint256 usdcSpent = bal < debtU ? bal : debtU;
        uint256 afterDebt = bal - usdcSpent;
        return fees >= afterDebt ? 0 : afterDebt - fees;
    }
}
