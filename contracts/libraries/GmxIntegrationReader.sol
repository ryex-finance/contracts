// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IGmxReader} from "../interfaces/IGmxReader.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {GmxConstants} from "./GmxConstants.sol";
import {Units} from "./Units.sol";
import {GmxInfra, GmxPositionData, GmxVaultCtx, GmxVaultStore} from "../types/Types.sol";

/// @title GmxIntegrationReader — external library: GMX integration 조회 (on-chain, factory, ledger, oracle).
library GmxIntegrationReader {
    function positionKey(address account, address market, address collateralToken, bool isLong)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(account, market, collateralToken, isLong));
    }

    function gmxMarket(GmxVaultCtx memory ctx) internal view returns (address) {
        (,,, address m,,,,,,,) = IVaultFactory(ctx.factory).markets(ctx.marketId);
        return m;
    }

    function gmxInfra(GmxVaultCtx memory ctx) internal view returns (GmxInfra memory) {
        return IVaultFactory(ctx.factory).gmxInfra();
    }

    function sizeInUsd(IGmxReader reader, address dataStore, bytes32 gmxPosKey) internal view returns (uint256) {
        if (address(reader) == address(0)) return 0;
        try reader.getPosition(dataStore, gmxPosKey) returns (IGmxReader.PositionProps memory pos) {
            return pos.numbers.sizeInUsd;
        } catch {
            return 0;
        }
    }

    function readPosition(
        IGmxReader reader,
        address dataStore,
        address account,
        address market,
        address collateralToken,
        bool isLong
    ) internal view returns (GmxPositionData memory data) {
        if (market == address(0) || address(reader) == address(0)) return data;
        bytes32 gmxPosKey = positionKey(account, market, collateralToken, isLong);
        try reader.getPosition(dataStore, gmxPosKey) returns (IGmxReader.PositionProps memory pos) {
            data.exists = pos.numbers.sizeInUsd > 0;
            data.sizeInUsd = pos.numbers.sizeInUsd;
            data.collateralAmount = pos.numbers.collateralAmount;
            // index 18dec 가정(ETH). BTC 등 비-18은 VaultLens가 oracle.tokenDecimals로 재계산.
            if (pos.numbers.sizeInTokens > 0) {
                data.entryPrice8 = Units.gmxSizeToEntryPrice8(pos.numbers.sizeInUsd, pos.numbers.sizeInTokens, 18);
            }
        } catch {}
    }

    function vaultSizeUsd(GmxVaultCtx memory ctx, address market) internal view returns (uint256) {
        GmxInfra memory infra = gmxInfra(ctx);
        bytes32 gmxPosKey = positionKey(ctx.vault, market, ctx.usdc, ctx.isLong);
        return sizeInUsd(IGmxReader(infra.reader), infra.dataStore, gmxPosKey);
    }

    function positionExists(GmxVaultCtx memory ctx) internal view returns (bool) {
        address mkt = gmxMarket(ctx);
        if (mkt == address(0) || gmxInfra(ctx).reader == address(0)) return false;
        return vaultSizeUsd(ctx, mkt) > 0;
    }

    function isOrderPending(GmxVaultCtx memory ctx, bytes32 gmxKey) internal view returns (bool) {
        GmxInfra memory infra = gmxInfra(ctx);
        bytes32 listKey = keccak256(abi.encode(GmxConstants.ACCOUNT_ORDER_LIST, ctx.vault));
        (bool ok, bytes memory data) = infra.dataStore.staticcall(
            abi.encodeWithSignature("containsBytes32(bytes32,bytes32)", listKey, gmxKey)
        );
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (bool));
    }

    function ledgerEquityUsdWad(GmxVaultStore storage s, GmxVaultCtx memory ctx) external view returns (uint256) {
        return _ledgerEquityUsdWad(s, ctx);
    }

    function _ledgerEquityUsdWad(GmxVaultStore storage s, GmxVaultCtx memory ctx) internal view returns (uint256) {
        if (!s.mockActive || s.mockEntryPrice8 == 0) return 0;
        return oracleMarkEquityUsdWad(
            s.mockCollateral,
            s.mockEntryPrice8,
            ctx.leverage,
            ctx.isLong,
            int256(uint256(IPriceOracle(ctx.oracle).getPrice()))
        );
    }

    /// @dev shadow ledger + oracle mark: collateral + leverage·PnL (USD WAD).
    function oracleMarkEquityUsdWad(
        uint256 collateralUsdc,
        uint256 entryPrice8,
        uint256 leverage,
        bool isLong,
        int256 curPrice8
    ) internal pure returns (uint256) {
        if (entryPrice8 == 0 || collateralUsdc == 0) return 0;
        int256 collatWad = int256(Units.usdcToWad(collateralUsdc));
        int256 entry = int256(entryPrice8);
        int256 priceMove = isLong ? (curPrice8 - entry) : (entry - curPrice8);
        int256 pnl = (collatWad * int256(leverage) * priceMove) / entry;
        int256 value = collatWad + pnl;
        return value > 0 ? uint256(value) : 0;
    }

    function positionSnapshot(GmxVaultStore storage s, GmxVaultCtx memory ctx)
        external
        view
        returns (GmxPositionData memory data)
    {
        return _positionSnapshot(s, ctx);
    }

    function _positionSnapshot(GmxVaultStore storage s, GmxVaultCtx memory ctx)
        internal
        view
        returns (GmxPositionData memory data)
    {
        address mkt = gmxMarket(ctx);
        GmxInfra memory infra = gmxInfra(ctx);
        if (mkt != address(0) && infra.reader != address(0)) {
            data = readPosition(
                IGmxReader(infra.reader), infra.dataStore, ctx.vault, mkt, ctx.usdc, ctx.isLong
            );
            if (data.exists) return data;
        }
        data.exists = s.mockActive;
        data.sizeInUsd = s.mockActive ? s.mockSizeUsd : 0;
        data.collateralAmount = s.mockActive ? s.mockCollateral : 0;
        data.entryPrice8 = s.mockActive ? s.mockEntryPrice8 : 0;
    }
}
