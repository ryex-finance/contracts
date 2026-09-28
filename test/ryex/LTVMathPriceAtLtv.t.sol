// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LTVMath} from "../../contracts/libraries/LTVMath.sol";
import {Units} from "../../contracts/libraries/Units.sol";

contract LTVMathPriceAtLtvTest is Test {
    function test_short_liqPrice_nearLltv() public pure {
        // C=351617.440225 USDC, D≈117.54 rETH, E≈1907.24, L=1, λ=7500
        uint256 C = 351_617_440_225;
        uint256 D = 117_537_604_189_985_010_985;
        uint256 E = 190_724_435_386;
        uint256 P = LTVMath.priceAtLtvBps(C, D, E, 1, false, 7_500);
        assertApproxEqAbs(P, 206_181_473_003, 1e6); // ~$2061.81 ± $0.01
    }

    function test_long_1x_undefined() public pure {
        assertEq(LTVMath.priceAtLtvBps(1e6, 1e18, 2_000e8, 1, true, 7_500), 0);
    }

    function test_gmxSizeToEntry() public pure {
        // 1 ETH notional at $2000 → sizeUsd=2000e30, sizeTokens=1e18
        uint256 entry = Units.gmxSizeToEntryPrice8(2_000 * 1e30, 1e18, 18);
        assertEq(entry, 2_000 * 1e8);
    }
}
