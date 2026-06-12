// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IGmxReader — GMX v2 Reader 최소 인터페이스 (포지션 조회용)
/// @notice ABI layout은 GMX v2 Position.Props struct와 정확히 일치해야 디코딩이 맞음.
///         Arbitrum Sepolia Reader: 0x22199a49A999c351eF7927602CFB187ec3cae489
///         Arbitrum One Reader:     0x0537C767cDAa5bD5D2C3253D34EF59A13Edc7f4
interface IGmxReader {
    // ── Position.Addresses ──────────────────────────────────────────────────────
    struct PositionAddresses {
        address account;        // position 보유자 (= GmxV2Adapter address)
        address market;         // GMX market token
        address collateralToken;// 담보 토큰 (USDC)
    }

    // ── Position.Numbers (GMX 원본 — RYex 어댑터가 passthrough, 8dec 변환 없음) ──
    struct PositionNumbers {
        uint256 sizeInUsd;           // GMX 30-dec USD (예: $10 → 10 × 10^30). formatUnits(v, 30)
        uint256 sizeInTokens;        // index token decimals (ETH: 18-dec)
        uint256 collateralAmount;    // USDC 6-dec. formatUnits(v, 6)
        uint256 borrowingFactor;
        uint256 fundingFeeAmountPerSize;
        uint256 longTokenClaimableFundingAmountPerSize;
        uint256 shortTokenClaimableFundingAmountPerSize;
        uint256 increasedAtTime;     // unix timestamp
        uint256 decreasedAtTime;
    }

    // ── Position.Flags ──────────────────────────────────────────────────────────
    struct PositionFlags {
        bool isLong;
    }

    // ── Position.Props (= Reader.getPosition 반환 타입) ─────────────────────────
    struct PositionProps {
        PositionAddresses addresses;
        PositionNumbers   numbers;
        PositionFlags     flags;
    }

    /// @notice dataStore 주소와 positionKey로 포지션 상태를 조회한다.
    ///         positionKey = keccak256(abi.encode(account, market, collateralToken, isLong))
    function getPosition(address dataStore, bytes32 key)
        external
        view
        returns (PositionProps memory);
}
