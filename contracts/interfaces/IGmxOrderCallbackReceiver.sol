// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IGmxOrderCallbackReceiver — GMX v2 order callback interface
/// @notice Mirrors the exact signature of GMX's IOrderCallbackReceiver so the 4-byte
///         function selectors match and GMX's OrderHandler can invoke our callbacks.
///
///         Source verified against:
///         github.com/gmx-io/gmx-synthetics/contracts/callback/IOrderCallbackReceiver.sol
///         github.com/gmx-io/gmx-synthetics/contracts/event/EventUtils.sol
///
///         Key insight: the second parameter is EventLogData (NOT Order.Props).
///         Both second and third parameters are EventLogData.
interface IGmxOrderCallbackReceiver {

    // ── EventUtils.EventLogData — exact field order must match GMX source ─────

    struct AddressKeyValue      { string key; address   value; }
    struct AddressArrayKeyValue { string key; address[] value; }
    struct UintKeyValue         { string key; uint256   value; }
    struct UintArrayKeyValue    { string key; uint256[] value; }
    struct IntKeyValue          { string key; int256    value; }
    struct IntArrayKeyValue     { string key; int256[]  value; }
    struct BoolKeyValue         { string key; bool      value; }
    struct BoolArrayKeyValue    { string key; bool[]    value; }
    struct Bytes32KeyValue      { string key; bytes32   value; }
    struct Bytes32ArrayKeyValue { string key; bytes32[] value; }
    struct BytesKeyValue        { string key; bytes     value; }
    struct BytesArrayKeyValue   { string key; bytes[]   value; }
    struct StringKeyValue       { string key; string    value; }
    struct StringArrayKeyValue  { string key; string[]  value; }

    struct AddressItems  { AddressKeyValue[]  items; AddressArrayKeyValue[]  arrayItems; }
    struct UintItems     { UintKeyValue[]     items; UintArrayKeyValue[]     arrayItems; }
    struct IntItems      { IntKeyValue[]      items; IntArrayKeyValue[]      arrayItems; }
    struct BoolItems     { BoolKeyValue[]     items; BoolArrayKeyValue[]     arrayItems; }
    struct Bytes32Items  { Bytes32KeyValue[]  items; Bytes32ArrayKeyValue[]  arrayItems; }
    struct BytesItems    { BytesKeyValue[]    items; BytesArrayKeyValue[]    arrayItems; }
    struct StringItems   { StringKeyValue[]   items; StringArrayKeyValue[]   arrayItems; }

    struct EventLogData {
        AddressItems  addressItems;
        UintItems     uintItems;
        IntItems      intItems;
        BoolItems     boolItems;
        Bytes32Items  bytes32Items;
        BytesItems    bytesItems;
        StringItems   stringItems;
    }

    // ── Callback functions ────────────────────────────────────────────────────

    /// @notice GMX keeper가 주문을 체결한 뒤 호출.
    /// @param key GMX 주문 키
    function afterOrderExecution(
        bytes32 key,
        EventLogData memory orderData,
        EventLogData memory eventData
    ) external;

    /// @notice GMX keeper가 주문을 취소한 뒤 호출 (InsufficientReserve 등).
    /// @param key GMX 주문 키
    function afterOrderCancellation(
        bytes32 key,
        EventLogData memory order,
        EventLogData memory eventData
    ) external;

    /// @notice GMX keeper가 주문을 frozen 처리한 뒤 호출 (가격 검증 실패 등).
    /// @param key GMX 주문 키
    function afterOrderFrozen(
        bytes32 key,
        EventLogData memory order,
        EventLogData memory eventData
    ) external;
}
