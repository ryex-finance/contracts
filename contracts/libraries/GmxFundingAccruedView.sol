// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IGmxDataStore} from "../interfaces/IGmxDataStore.sol";
import {IGmxReaderPositionInfo} from "../interfaces/IGmxReaderPositionInfo.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {GmxInfra} from "../types/Types.sol";
import {GmxFundingUtils} from "./GmxFundingUtils.sol";

/// @title GmxFundingAccruedView — GMX Reader 기반 accrued(미 settle) 펀딩비 조회 (표시 전용, external 라이브러리).
/// @dev GMX UI의 "Accrued"와 동일 — settle(포지션 터치) 전 포지션에 붙어 있는 펀딩비를
///      Reader.getPositionInfo(fees.funding.claimableLong/ShortTokenAmount)로 추정한다.
///      실제 정산·지급 금액이 아니라 UI 대시보드용 추정치다(claim은 GMX claimFundingFees 실값 기준).
///      external 함수로 두어 RYieldVault 런타임 바이트코드에 인라인되지 않게 한다(24KB 한계 관리).
library GmxFundingAccruedView {
    /// @notice factory·marketId에서 GMX 인프라·마켓을 해석해 accrued 펀딩비를 조회.
    /// @param indexPrice8 오라클 8-dec 가격(index=long 토큰 기준). short(USDC)은 $1 고정 가정.
    /// @dev GMX 가격 규약: price30 = USD × 10^(30 - tokenDecimals) = price8 × 10^(22 - tokenDecimals).
    ///      index==long 토큰인 표준 GMX 마켓(ETH/USD 등) 전제. 합성마켓(index≠long)은 추정 부정확.
    function accruedFunding(
        address factory,
        bytes32 marketId,
        address account,
        address collateralToken,
        bool isLong,
        uint256 indexPrice8
    ) external view returns (uint256 longAmt, uint256 shortAmt) {
        if (factory == address(0) || indexPrice8 == 0) return (0, 0);
        GmxInfra memory infra = IVaultFactory(factory).gmxInfra();
        if (infra.reader == address(0)) return (0, 0);
        (,,, address market,,,,,,,) = IVaultFactory(factory).markets(marketId);
        if (market == address(0)) return (0, 0);

        IGmxDataStore ds = IGmxDataStore(infra.dataStore);
        address longTk = GmxFundingUtils.marketLongToken(ds, market);
        address shortTk = GmxFundingUtils.marketShortToken(ds, market);
        if (longTk == address(0) || shortTk == address(0)) return (0, 0);

        uint256 longP;
        uint256 shortP;
        {
            uint8 longDec = IERC20Metadata(longTk).decimals();
            uint8 shortDec = IERC20Metadata(shortTk).decimals();
            if (longDec > 22 || shortDec > 30) return (0, 0);
            longP = indexPrice8 * (10 ** (22 - longDec)); // index==long 가정
            shortP = 10 ** (30 - shortDec); // USDC 스테이블 ≈ $1
        }

        IGmxReaderPositionInfo.GmxPriceProps memory longPx = IGmxReaderPositionInfo.GmxPriceProps(longP, longP);
        IGmxReaderPositionInfo.GmxPriceProps memory shortPx = IGmxReaderPositionInfo.GmxPriceProps(shortP, shortP);
        IGmxReaderPositionInfo.MarketPrices memory prices = IGmxReaderPositionInfo.MarketPrices({
            indexTokenPrice: longPx,
            longTokenPrice: longPx,
            shortTokenPrice: shortPx
        });

        bytes32 posKey = keccak256(abi.encode(account, market, collateralToken, isLong));
        try IGmxReaderPositionInfo(infra.reader).getPositionInfo(
            infra.dataStore, address(0), posKey, prices, 0, address(0), false
        ) returns (IGmxReaderPositionInfo.PositionInfo memory info) {
            longAmt = info.fees.funding.claimableLongTokenAmount;
            shortAmt = info.fees.funding.claimableShortTokenAmount;
        } catch {
            return (0, 0);
        }
    }
}
