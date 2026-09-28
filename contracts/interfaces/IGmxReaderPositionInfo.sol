// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IGmxReader} from "./IGmxReader.sol";

/// @title IGmxReaderPositionInfo — GMX Reader.getPositionInfo 반환 디코딩용 (ABI layout 일치 필수).
/// @dev fees.funding.claimableLong/ShortTokenAmount = accrued(미 settle) 펀딩비 추정치.
interface IGmxReaderPositionInfo {
    struct GmxPriceProps {
        uint256 min;
        uint256 max;
    }

    struct MarketPrices {
        GmxPriceProps indexTokenPrice;
        GmxPriceProps longTokenPrice;
        GmxPriceProps shortTokenPrice;
    }

    struct PositionReferralFees {
        bytes32 referralCode;
        address affiliate;
        address trader;
        uint256 totalRebateFactor;
        uint256 affiliateRewardFactor;
        uint256 adjustedAffiliateRewardFactor;
        uint256 traderDiscountFactor;
        uint256 totalRebateAmount;
        uint256 traderDiscountAmount;
        uint256 affiliateRewardAmount;
    }

    struct PositionProFees {
        uint256 traderTier;
        uint256 traderDiscountFactor;
        uint256 traderDiscountAmount;
    }

    struct PositionFundingFees {
        uint256 fundingFeeAmount;
        uint256 claimableLongTokenAmount;
        uint256 claimableShortTokenAmount;
        uint256 latestFundingFeeAmountPerSize;
        uint256 latestLongTokenClaimableFundingAmountPerSize;
        uint256 latestShortTokenClaimableFundingAmountPerSize;
    }

    struct PositionBorrowingFees {
        uint256 borrowingFeeUsd;
        uint256 borrowingFeeAmount;
        uint256 borrowingFeeReceiverFactor;
        uint256 borrowingFeeAmountForFeeReceiver;
    }

    struct PositionUiFees {
        address uiFeeReceiver;
        uint256 uiFeeReceiverFactor;
        uint256 uiFeeAmount;
    }

    struct PositionLiquidationFees {
        uint256 liquidationFeeUsd;
        uint256 liquidationFeeAmount;
        uint256 liquidationFeeReceiverFactor;
        uint256 liquidationFeeAmountForFeeReceiver;
    }

    struct PositionFees {
        PositionReferralFees referral;
        PositionProFees pro;
        PositionFundingFees funding;
        PositionBorrowingFees borrowing;
        PositionUiFees ui;
        PositionLiquidationFees liquidation;
        GmxPriceProps collateralTokenPrice;
        uint256 positionFeeFactor;
        uint256 protocolFeeAmount;
        uint256 positionFeeReceiverFactor;
        uint256 feeReceiverAmount;
        uint256 feeAmountForPool;
        uint256 positionFeeAmountForPool;
        uint256 positionFeeAmount;
        uint256 totalCostAmountExcludingFunding;
        uint256 totalCostAmount;
        uint256 totalDiscountAmount;
    }

    struct ExecutionPriceResult {
        int256 priceImpactUsd;
        uint256 executionPrice;
        bool balanceWasImproved;
        int256 proportionalPendingImpactUsd;
        int256 totalImpactUsd;
        uint256 priceImpactDiffUsd;
    }

    struct PositionInfo {
        bytes32 positionKey;
        IGmxReader.PositionProps position;
        PositionFees fees;
        ExecutionPriceResult executionPriceResult;
        int256 basePnlUsd;
        int256 uncappedBasePnlUsd;
        int256 pnlAfterPriceImpactUsd;
    }

    function getPositionInfo(
        address dataStore,
        address referralStorage,
        bytes32 positionKey,
        MarketPrices memory prices,
        uint256 sizeDeltaUsd,
        address uiFeeReceiver,
        bool usePositionSizeAsSizeDeltaUsd
    ) external view returns (PositionInfo memory);
}
