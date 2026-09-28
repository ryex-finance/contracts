// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IGmxDataStore} from "../interfaces/IGmxDataStore.sol";
import {IGmxExchangeRouter} from "../interfaces/IGmxExchangeRouter.sol";
import {IRYieldFundingDistributor} from "../interfaces/IRYieldFundingDistributor.sol";

/// @title GmxFundingUtils — GMX v2 funding fee claimable 조회·마켓 토큰 해석 + 수거 오케스트레이션.
/// @dev 수거(external) 로직을 라이브러리로 분리해 RYieldVault 런타임 바이트코드 크기를 24KB 한계 아래로 유지.
///      external 함수는 delegatecall로 실행되어 vault 컨텍스트(address(this)=vault)를 유지하므로,
///      GMX router가 보는 claim 주체(msg.sender)는 여전히 포지션 소유자인 vault다.
library GmxFundingUtils {
    bytes32 internal constant LONG_TOKEN = keccak256(abi.encode("LONG_TOKEN"));
    bytes32 internal constant SHORT_TOKEN = keccak256(abi.encode("SHORT_TOKEN"));
    bytes32 internal constant CLAIMABLE_FUNDING_AMOUNT = keccak256(abi.encode("CLAIMABLE_FUNDING_AMOUNT"));

    function marketLongToken(IGmxDataStore dataStore, address market) internal view returns (address) {
        return dataStore.getAddress(keccak256(abi.encode(market, LONG_TOKEN)));
    }

    function marketShortToken(IGmxDataStore dataStore, address market) internal view returns (address) {
        return dataStore.getAddress(keccak256(abi.encode(market, SHORT_TOKEN)));
    }

    function claimableFunding(IGmxDataStore dataStore, address market, address token, address account)
        internal
        view
        returns (uint256)
    {
        return dataStore.getUint(keccak256(abi.encode(CLAIMABLE_FUNDING_AMOUNT, market, token, account)));
    }

    /// @notice GMX의 무파라미터 claimable(funding fee + affiliate reward)을 long·short 두 토큰 모두 distributor로
    ///         일괄 수거 + rewardPerShare 갱신. (timeKey가 필요한 collateral은 harvestCollateralToDistributor 별도.)
    /// @dev 호출 전 accrued는 settleAccruedFee(유저 1단계)로 claimable 전환되어야 전량 수거 가능.
    /// @dev vault delegatecall 컨텍스트 → router의 msg.sender = vault(포지션 소유자), receiver = distributor.
    ///      funding은 strict 플래그 적용(명시적 harvest=revert, 입출금 훅=무시). affiliate는 항상 best-effort(보너스).
    /// @return ok 하나라도 수거·기록 성공 여부
    /// @return longAmt 수거한 long 토큰 총량(funding+affiliate)
    /// @return shortAmt 수거한 short 토큰 총량(funding+affiliate)
    function harvestToDistributor(address router, address distributor, bool strict)
        external
        returns (bool ok, uint256 longAmt, uint256 shortAmt)
    {
        IRYieldFundingDistributor d = IRYieldFundingDistributor(distributor);
        address market = d.gmxMarket();
        address[] memory markets = new address[](2);
        markets[0] = market;
        markets[1] = market;
        address[] memory tokens = new address[](2);
        tokens[0] = d.longToken();
        tokens[1] = d.shortToken();

        // ① funding fee (주 수익)
        if (strict) {
            uint256[] memory f = IGmxExchangeRouter(router).claimFundingFees(markets, tokens, distributor);
            IRYieldFundingDistributor(distributor).notifyHarvestBatch(tokens, f);
            (ok, longAmt, shortAmt) = (true, f[0], f[1]);
        } else {
            try IGmxExchangeRouter(router).claimFundingFees(markets, tokens, distributor) returns (uint256[] memory f) {
                IRYieldFundingDistributor(distributor).notifyHarvestBatch(tokens, f);
                (ok, longAmt, shortAmt) = (true, f[0], f[1]);
            } catch {}
        }

        // ② affiliate reward (레퍼럴 리베이트 — 볼트가 affiliate가 아니면 0). 항상 best-effort로 함께 쓸어담음.
        try IGmxExchangeRouter(router).claimAffiliateRewards(markets, tokens, distributor) returns (
            uint256[] memory a
        ) {
            if (a[0] != 0 || a[1] != 0) {
                IRYieldFundingDistributor(distributor).notifyHarvestBatch(tokens, a);
                ok = true;
                longAmt += a[0];
                shortAmt += a[1];
            }
        } catch {}
    }

    /// @notice PositionVault(단일 owner)용 — claimable funding fee를 owner 지갑으로 직접 클레임.
    /// @dev distributor·rewardPerShare 불필요(지분 분배 대상이 owner 1명). 볼트 idle/collateral 회계 미오염.
    function harvestFundingToReceiver(IGmxDataStore dataStore, address router, address market, address receiver)
        external
        returns (uint256 longAmt, uint256 shortAmt)
    {
        address[] memory markets = new address[](2);
        markets[0] = market;
        markets[1] = market;
        address[] memory tokens = new address[](2);
        tokens[0] = marketLongToken(dataStore, market);
        tokens[1] = marketShortToken(dataStore, market);
        uint256[] memory f = IGmxExchangeRouter(router).claimFundingFees(markets, tokens, receiver);
        longAmt = f[0];
        shortAmt = f[1];
    }

    /// @notice 미수령 담보(claimable collateral: 가격충격/ADL 정산 잔여)를 long·short 토큰별 timeKey들로 청구해
    ///         distributor로 수거 + rewardPerShare 갱신. keeper가 off-chain에서 claimable>0인 timeKey를 넣는다.
    /// @dev funding과 동일 토큰 표시 → 같은 rewardPerShare 버킷으로 합산 분배(메인 볼트 idle/collateral 미오염).
    /// @return longAmt 수거한 long 토큰 총량
    /// @return shortAmt 수거한 short 토큰 총량
    function harvestCollateralToDistributor(
        address router,
        address distributor,
        uint256[] calldata longTimeKeys,
        uint256[] calldata shortTimeKeys
    ) external returns (uint256 longAmt, uint256 shortAmt) {
        uint256 nL = longTimeKeys.length;
        uint256 nS = shortTimeKeys.length;
        uint256 n = nL + nS;
        if (n == 0) return (0, 0);

        IRYieldFundingDistributor d = IRYieldFundingDistributor(distributor);
        address market = d.gmxMarket();
        address longToken = d.longToken();
        address shortToken = d.shortToken();

        address[] memory markets = new address[](n);
        address[] memory tokens = new address[](n);
        uint256[] memory timeKeys = new uint256[](n);
        for (uint256 i; i < nL; ++i) {
            markets[i] = market;
            tokens[i] = longToken;
            timeKeys[i] = longTimeKeys[i];
        }
        for (uint256 j; j < nS; ++j) {
            markets[nL + j] = market;
            tokens[nL + j] = shortToken;
            timeKeys[nL + j] = shortTimeKeys[j];
        }

        uint256[] memory amounts = IGmxExchangeRouter(router).claimCollateral(markets, tokens, timeKeys, distributor);
        for (uint256 i; i < nL; ++i) {
            longAmt += amounts[i];
        }
        for (uint256 j; j < nS; ++j) {
            shortAmt += amounts[nL + j];
        }

        // 토큰별 합산 후 2건만 notify (rewardPerShare 갱신).
        address[] memory notifyTokens = new address[](2);
        uint256[] memory notifyAmounts = new uint256[](2);
        notifyTokens[0] = longToken;
        notifyTokens[1] = shortToken;
        notifyAmounts[0] = longAmt;
        notifyAmounts[1] = shortAmt;
        IRYieldFundingDistributor(distributor).notifyHarvestBatch(notifyTokens, notifyAmounts);
    }
}
