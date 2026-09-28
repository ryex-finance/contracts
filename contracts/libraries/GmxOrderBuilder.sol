// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IGmxExchangeRouter} from "../interfaces/IGmxExchangeRouter.sol";
import {GmxConstants} from "./GmxConstants.sol";

/// @title GmxOrderBuilder — GMX v2 CreateOrderParams 조립 + ExchangeRouter multicall 제출.
library GmxOrderBuilder {
    /// @dev receiver/callback = vault (this GMX account).
    function createOrder(
        IGmxExchangeRouter exchangeRouter,
        address orderVault,
        address vault,
        address usdcAddr,
        address gmxMarket,
        uint8 orderType,
        uint256 collatAmount,
        uint256 sizeUsd,
        uint256 triggerPrice30,
        uint256 acceptablePrice,
        bool isLong,
        uint256 execFee
    ) external returns (bytes32 gmxKey) {
        IGmxExchangeRouter.CreateOrderParams memory params;
        params.addresses.receiver = vault;
        params.addresses.cancellationReceiver = vault;
        params.addresses.callbackContract = vault;
        params.addresses.market = gmxMarket;
        params.addresses.initialCollateralToken = usdcAddr;
        params.numbers.sizeDeltaUsd = sizeUsd;
        params.numbers.initialCollateralDeltaAmount = collatAmount;
        params.numbers.triggerPrice = triggerPrice30;
        params.numbers.acceptablePrice = acceptablePrice;
        params.numbers.executionFee = execFee;
        params.numbers.callbackGasLimit = GmxConstants.CALLBACK_GAS_LIMIT;
        params.orderType = orderType;
        params.isLong = isLong;

        bool isIncrease = orderType == GmxConstants.ORDER_MARKET_INCREASE
            || orderType == GmxConstants.ORDER_LIMIT_INCREASE;
        bytes[] memory data = new bytes[](isIncrease ? 3 : 2);
        data[0] = abi.encodeWithSelector(IGmxExchangeRouter.sendWnt.selector, orderVault, execFee);
        if (isIncrease) {
            data[1] = abi.encodeWithSelector(
                IGmxExchangeRouter.sendTokens.selector, usdcAddr, orderVault, collatAmount
            );
            data[2] = abi.encodeWithSelector(IGmxExchangeRouter.createOrder.selector, params);
        } else {
            data[1] = abi.encodeWithSelector(IGmxExchangeRouter.createOrder.selector, params);
        }
        bytes[] memory results = exchangeRouter.multicall{value: execFee}(data);
        gmxKey = abi.decode(results[results.length - 1], (bytes32));
    }
}
