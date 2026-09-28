// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IGmxDataStore} from "../interfaces/IGmxDataStore.sol";
import {IGmxReader} from "../interfaces/IGmxReader.sol";
import {Units} from "./Units.sol";
import {GmxFundingUtils} from "./GmxFundingUtils.sol";

/// @title GmxLiquidationPrice — GMX UI `getLiquidationPrice`(useMaxPriceImpact, pendingFees≈0) 근사.
/// @dev collateral≠index(USDC 담보) 경로. pending funding/borrowing은 0으로 두고 closingFee+maxImpact만 반영
///      (getPositionInfo ABI 드리프트·오버플로로 vaultInfo 전체가 revert되지 않게).
library GmxLiquidationPrice {
    uint256 internal constant FLOAT = 1e30;

    bytes32 internal constant MIN_COLLATERAL_USD = keccak256(abi.encode("MIN_COLLATERAL_USD"));
    bytes32 internal constant MIN_COLLATERAL_FACTOR_FOR_LIQUIDATION =
        keccak256(abi.encode("MIN_COLLATERAL_FACTOR_FOR_LIQUIDATION"));
    bytes32 internal constant MAX_POSITION_IMPACT_FACTOR_FOR_LIQUIDATIONS =
        keccak256(abi.encode("MAX_POSITION_IMPACT_FACTOR_FOR_LIQUIDATIONS"));
    bytes32 internal constant POSITION_FEE_FACTOR = keccak256(abi.encode("POSITION_FEE_FACTOR"));
    bytes32 internal constant INDEX_TOKEN = keccak256(abi.encode("INDEX_TOKEN"));

    /// @notice GMX 포지션 청산가 (8-dec). 없거나 계산 불가 → 0.
    function price8(
        address reader,
        address dataStore,
        address account,
        address market,
        address collateralToken,
        bool isLong,
        uint256 /* indexPrice8 */
    ) internal view returns (uint256) {
        if (reader == address(0) || dataStore == address(0) || market == address(0)) return 0;
        IGmxDataStore ds = IGmxDataStore(dataStore);
        bytes32 posKey = keccak256(abi.encode(account, market, collateralToken, isLong));

        IGmxReader.PositionProps memory pos;
        try IGmxReader(reader).getPosition(dataStore, posKey) returns (IGmxReader.PositionProps memory p) {
            pos = p;
        } catch {
            return 0;
        }
        uint256 sizeInUsd = pos.numbers.sizeInUsd;
        uint256 sizeInTokens = pos.numbers.sizeInTokens;
        uint256 collateralAmount = pos.numbers.collateralAmount;
        if (sizeInUsd == 0 || sizeInTokens == 0) return 0;

        uint8 indexDec = _indexDecimals(ds, market);
        uint8 collatDec = _tokenDecimals(collateralToken);
        if (indexDec == 0 || collatDec == 0 || collatDec > 30) return 0;

        uint256 collateralUsd = collateralAmount * (10 ** (30 - collatDec));

        uint256 minCollateralUsd = ds.getUint(MIN_COLLATERAL_USD);
        uint256 minFactor = ds.getUint(keccak256(abi.encode(MIN_COLLATERAL_FACTOR_FOR_LIQUIDATION, market)));
        uint256 maxImpactFactor = ds.getUint(keccak256(abi.encode(MAX_POSITION_IMPACT_FACTOR_FOR_LIQUIDATIONS, market)));
        uint256 feeFactor = ds.getUint(keccak256(abi.encode(POSITION_FEE_FACTOR, market, false)));

        uint256 closingFeeUsd = _applyFactor(sizeInUsd, feeFactor);
        uint256 impactAbs = _applyFactor(sizeInUsd, maxImpactFactor);
        uint256 pendingFeesUsd = 0; // UI 보수 근사: closing + maxImpact만

        uint256 liquidationCollateralUsd = _applyFactor(sizeInUsd, minFactor);
        if (liquidationCollateralUsd < minCollateralUsd) liquidationCollateralUsd = minCollateralUsd;

        if (collateralUsd < impactAbs + pendingFeesUsd + closingFeeUsd) return 0;
        uint256 remainingCollateralUsd = collateralUsd - impactAbs - pendingFeesUsd - closingFeeUsd;

        uint256 num;
        if (isLong) {
            num = liquidationCollateralUsd + sizeInUsd;
            if (num < remainingCollateralUsd) return 0;
            num -= remainingCollateralUsd;
        } else {
            num = remainingCollateralUsd + sizeInUsd;
            if (num < liquidationCollateralUsd) return 0;
            num -= liquidationCollateralUsd;
        }
        return Units.gmxSizeToEntryPrice8(num, sizeInTokens, indexDec);
    }

    function _applyFactor(uint256 value, uint256 factor) private pure returns (uint256) {
        return (value * factor) / FLOAT;
    }

    function _indexDecimals(IGmxDataStore ds, address market) private view returns (uint8) {
        address index = ds.getAddress(keccak256(abi.encode(market, INDEX_TOKEN)));
        if (index == address(0)) index = GmxFundingUtils.marketLongToken(ds, market);
        return _tokenDecimals(index);
    }

    function _tokenDecimals(address token) private view returns (uint8) {
        if (token == address(0)) return 0;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 0;
        }
    }
}
