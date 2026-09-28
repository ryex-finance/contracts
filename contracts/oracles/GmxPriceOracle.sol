// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IGmxPriceFeedProvider} from "../interfaces/IGmxPriceFeedProvider.sol";
import {Units} from "../libraries/Units.sol";

/// @title GmxPriceOracle — GMX ChainlinkPriceFeedProvider 기반 live mark
/// @notice Ryex LTV·mint가 GMX Sepolia와 동일한 Chainlink feed 가격을 본다 (8 decimals).
contract GmxPriceOracle is IPriceOracle {
    address public immutable indexToken;
    address public immutable priceFeedProvider;
    uint8 public immutable tokenDecimals;

    error ZeroAddress();
    error ZeroPrice();

    constructor(address indexToken_, address priceFeedProvider_, uint8 tokenDecimals_) {
        if (indexToken_ == address(0) || priceFeedProvider_ == address(0)) revert ZeroAddress();
        if (tokenDecimals_ == 0) revert ZeroPrice();
        indexToken = indexToken_;
        priceFeedProvider = priceFeedProvider_;
        tokenDecimals = tokenDecimals_;
    }

    /// @inheritdoc IPriceOracle
    function getPrice() external view returns (uint256) {
        (, uint256 minPrice30,,,) =
            IGmxPriceFeedProvider(priceFeedProvider).getOraclePrice(indexToken, "");
        uint256 price8 = Units.gmx30ToPrice8(minPrice30, tokenDecimals);
        if (price8 == 0) revert ZeroPrice();
        return price8;
    }

    /// @inheritdoc IPriceOracle
    function decimals() external pure returns (uint8) {
        return 8;
    }
}
