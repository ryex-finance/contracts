// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Units} from "../../contracts/libraries/Units.sol";

/// @dev GMX contract price = USD × 10^(30 - tokenDecimals). Round-trip must preserve price8.
contract UnitsPriceScaleTest is Test {
    function test_eth18_roundTrip() public pure {
        uint256 price8 = 2390 * 1e8;
        uint256 gmx = Units.price8ToGmx30(price8, 18);
        assertEq(gmx, 2390 * 1e12, "ETH trigger must be USD * 1e12");
        assertEq(Units.gmx30ToPrice8(gmx, 18), price8);
    }

    function test_btc8_roundTrip() public pure {
        uint256 price8 = 95_000 * 1e8;
        uint256 gmx = Units.price8ToGmx30(price8, 8);
        assertEq(gmx, 95_000 * 1e22, "BTC trigger must be USD * 1e22");
        assertEq(Units.gmx30ToPrice8(gmx, 8), price8);
    }

    function test_eth18_notLegacy1e30() public pure {
        uint256 price8 = 2390 * 1e8;
        uint256 gmx = Units.price8ToGmx30(price8, 18);
        // Legacy bug: price8 * 1e22 == 2390e30 (unreachable vs oracle ~2400e12)
        assertTrue(gmx != price8 * 1e22, "must not use tokenDecimals-ignorant *1e22");
        assertTrue(gmx * 1e18 == price8 * 1e22, "legacy was 1e18x too large for ETH");
    }

    function test_fuzz_roundTrip(uint64 raw, uint8 tokenDecimals) public pure {
        tokenDecimals = uint8(bound(tokenDecimals, 1, 18));
        uint256 price8 = bound(uint256(raw), 1, 1_000_000 * 1e8);
        uint256 gmx = Units.price8ToGmx30(price8, tokenDecimals);
        assertEq(Units.gmx30ToPrice8(gmx, tokenDecimals), price8);
    }
}
