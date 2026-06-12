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
}
