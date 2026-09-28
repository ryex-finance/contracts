// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IGmxExchangeRouter — minimal surface of GMX v2 ExchangeRouter used by GmxV2Adapter.
/// @notice Struct/selector shapes verified against the live Arbitrum Sepolia deployment
///         (gmx-synthetics/deployments/arbitrumSepolia/ExchangeRouter.json) and exercised
///         end-to-end by ryex-keeper/scripts/gmx-isolation.ts (real open+close, keeper-filled).
/// @dev Orders are created via multicall([sendWnt, sendTokens, createOrder]) so the WNT exec-fee
///      and the USDC collateral land in the OrderVault atomically before createOrder records them.
interface IGmxExchangeRouter {
    struct CreateOrderParamsAddresses {
        address receiver;
        address cancellationReceiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address initialCollateralToken;
        address[] swapPath;
    }

    struct CreateOrderParamsNumbers {
        uint256 sizeDeltaUsd;
        uint256 initialCollateralDeltaAmount;
        uint256 triggerPrice;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 callbackGasLimit;
        uint256 minOutputAmount;
        uint256 validFromTime;
    }

    // orderType / decreasePositionSwapType are enums on GMX; uint8 is ABI-identical.
    struct CreateOrderParams {
        CreateOrderParamsAddresses addresses;
        CreateOrderParamsNumbers numbers;
        uint8 orderType; // 2=MarketIncrease, 4=MarketDecrease
        uint8 decreasePositionSwapType; // 0=NoSwap
        bool isLong;
        bool shouldUnwrapNativeToken;
        bool autoCancel;
        bytes32 referralCode;
        bytes32[] dataList;
    }

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
    function sendWnt(address receiver, uint256 amount) external payable;
    function sendTokens(address token, address receiver, uint256 amount) external payable;
    function createOrder(CreateOrderParams calldata params) external payable returns (bytes32);
    /// @notice 미체결 주문 취소. GMX keeper가 처리하고 collateral을 cancellationReceiver로 반환.
    function cancelOrder(bytes32 key) external payable;

    /// @notice 미체결 limit/trigger 주문의 sizeDeltaUsd·acceptablePrice·triggerPrice 등을 갱신.
    ///         market 주문에는 사용 불가. 호출자(msg.sender)가 order.account()와 일치해야 함.
    /// @dev validFromTime=0 → 즉시 유효. autoCancel은 LimitDecrease/StopLossDecrease에만 적용.
    function updateOrder(
        bytes32 key,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 triggerPrice,
        uint256 minOutputAmount,
        uint256 validFromTime,
        bool autoCancel
    ) external payable;

    /// @notice GMX funding fee 청구. markets[i]·tokens[i] 쌍별 claim, receiver로 전송.
    /// @dev msg.sender가 포지션 소유자(vault). markets.length == tokens.length.
    function claimFundingFees(address[] memory markets, address[] memory tokens, address receiver)
        external
        payable
        returns (uint256[] memory);

    /// @notice 미수령 담보(가격충격/ADL) 청구. timeKeys[i]는 markets[i]·tokens[i]의 정산 시각 버킷.
    /// @dev off-chain 인덱싱으로 claimable > 0인 timeKey를 찾아 전달해야 한다(온체인 열거 불가).
    function claimCollateral(
        address[] memory markets,
        address[] memory tokens,
        uint256[] memory timeKeys,
        address receiver
    ) external payable returns (uint256[] memory);

    /// @notice 레퍼럴 affiliate 리워드 청구(볼트가 affiliate일 때만 >0).
    function claimAffiliateRewards(address[] memory markets, address[] memory tokens, address receiver)
        external
        payable
        returns (uint256[] memory);
}
