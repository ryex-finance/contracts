// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AmmTwap} from "../../contracts/libraries/AmmTwap.sol";

contract MockUniV3Pool {
    uint160 public sqrtP;

    function setSqrtPrice(uint160 p) external {
        sqrtP = p;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtP, 0, 0, 0, 0, 0, true);
    }
}

/// @dev sqrtPriceX96AtPrice8는 rTokenPrice8의 역변환. 왕복(price8 → sqrtPriceX96 → price8, 독립적으로 재계산)이
///      정합적인지, 그리고 토큰 순서(usdc<rToken vs rToken<usdc) 양쪽 모두 올바른 방향으로 움직이는지 검증한다.
contract AmmTwapSqrtPriceTest is Test {
    // usdc(6dec) < rToken(18dec) 주소 순서를 강제하기 위한 더미 주소 (비교만 하면 되므로 실제 토큰 불필요)
    address constant USDC_LOW = address(0x1000);
    address constant RTOKEN_HIGH = address(0x2000);

    /// @dev AmmTwap._quoteAtTick와 동일한 raw-ratio 컨벤션으로 sqrtX96 → price8을 독립 재계산 (round-trip 검증용).
    ///      overflow 없이(mulDiv) rTokenPrice8의 공식을 그대로 역으로 밟는다 — 라이브러리 내부 구현과는
    ///      별개 경로로 다시 계산해서 sqrtPriceX96AtPrice8의 정방향 계산이 맞는지 교차검증한다.
    function _price8FromSqrt(uint160 sqrtX96, bool usdcIsToken0) internal pure returns (uint256) {
        // ratioX192 = sqrtX96^2 (mulDiv로 overflow 방지: sqrtX96 * sqrtX96 / 1, 그대로도 uint256 범위 내지만 안전하게)
        uint256 ratioX192 = Math.mulDiv(uint256(sqrtX96), uint256(sqrtX96), 1);
        if (usdcIsToken0) {
            // ratioX192 = 1e20 * 2^192 / price8  →  price8 = 1e20 * 2^192 / ratioX192
            return Math.mulDiv(1e20, uint256(1) << 192, ratioX192);
        } else {
            // ratioX192 = price8 * 2^192 / 1e20  →  price8 = ratioX192 * 1e20 / 2^192
            return Math.mulDiv(ratioX192, 1e20, uint256(1) << 192);
        }
    }

    function test_usdcIsToken0_roundTrip() public pure {
        uint256 price8 = 2390 * 1e8; // $2390
        uint160 sqrtX96 = AmmTwap.sqrtPriceX96AtPrice8(RTOKEN_HIGH, USDC_LOW, price8);
        uint256 back = _price8FromSqrt(sqrtX96, true);
        assertApproxEqRel(back, price8, 1e12, "usdc=token0 round-trip mismatch"); // 1e-6 상대오차 허용(sqrt 내림)
    }

    function test_rTokenIsToken0_roundTrip() public pure {
        uint256 price8 = 2390 * 1e8;
        uint160 sqrtX96 = AmmTwap.sqrtPriceX96AtPrice8(USDC_LOW, RTOKEN_HIGH, price8);
        uint256 back = _price8FromSqrt(sqrtX96, false);
        assertApproxEqRel(back, price8, 1e12, "rToken=token0 round-trip mismatch");
    }

    /// @dev price8이 클수록 usdc=token0 케이스에서는 sqrtPriceX96이 작아져야 한다 (역관계) —
    ///      buyback에서 usdc=token0이면 "매수(price8 상승)"가 zeroForOne=true(가격 하락) 스왑과 대응됨을 보장.
    function test_usdcIsToken0_higherPrice8YieldsLowerSqrtPrice() public pure {
        uint160 low = AmmTwap.sqrtPriceX96AtPrice8(RTOKEN_HIGH, USDC_LOW, 2000 * 1e8);
        uint160 high = AmmTwap.sqrtPriceX96AtPrice8(RTOKEN_HIGH, USDC_LOW, 3000 * 1e8);
        assertLt(high, low, "higher price8 must yield lower sqrtPriceX96 when usdc=token0");
    }

    /// @dev price8이 클수록 rToken=token0 케이스에서는 sqrtPriceX96이 커져야 한다 (정관계).
    function test_rTokenIsToken0_higherPrice8YieldsHigherSqrtPrice() public pure {
        uint160 low = AmmTwap.sqrtPriceX96AtPrice8(USDC_LOW, RTOKEN_HIGH, 2000 * 1e8);
        uint160 high = AmmTwap.sqrtPriceX96AtPrice8(USDC_LOW, RTOKEN_HIGH, 3000 * 1e8);
        assertGt(high, low, "higher price8 must yield higher sqrtPriceX96 when rToken=token0");
    }

    function test_zeroPrice_reverts() public {
        vm.expectRevert(AmmTwap.TwapZeroPrice.selector);
        AmmTwap.sqrtPriceX96AtPrice8(RTOKEN_HIGH, USDC_LOW, 0);
    }

    /// @dev 하한 1e6(=$0.0001)는 실제 오라클가 대비 극단적으로 낮은 값이라도 커버 — price8이 1e20*2^192/2^256(≈5.4)
    ///      아래로 내려가면 usdc=token0 케이스의 ratioX192가 진짜로 2^256을 넘어 mulDiv가 정당하게 revert한다
    ///      (수학적으로 실제 오버플로, 라이브러리 버그 아님). 실제 오라클가는 이 범위에 결코 들어오지 않는다.
    ///      허용오차 1e15(0.1%)는 매우 작은 price8에서 두 번의 정수 sqrt/mulDiv 내림이 겹쳐 생기는
    ///      상대오차를 커버하기 위함 — 실제 오라클가($0.01~$1M대) 구간에서는 오차가 훨씬 더 작다.
    function test_fuzz_roundTrip(uint64 rawPrice8, bool usdcIsToken0) public pure {
        uint256 price8 = bound(uint256(rawPrice8), 1e6, 1_000_000 * 1e8);
        address usdc = usdcIsToken0 ? USDC_LOW : RTOKEN_HIGH;
        address rToken = usdcIsToken0 ? RTOKEN_HIGH : USDC_LOW;
        uint160 sqrtX96 = AmmTwap.sqrtPriceX96AtPrice8(rToken, usdc, price8);
        assertGt(sqrtX96, 0);
        uint256 back = _price8FromSqrt(sqrtX96, usdcIsToken0);
        assertApproxEqRel(back, price8, 1e15, "fuzz round-trip mismatch"); // 0.1% 허용오차
    }

    function test_sqrtPriceLimitOk_zeroForOne() public {
        MockUniV3Pool pool = new MockUniV3Pool();
        uint160 current = AmmTwap.sqrtPriceX96AtPrice8(RTOKEN_HIGH, USDC_LOW, 2000 * 1e8);
        uint160 targetHigherPrice = AmmTwap.sqrtPriceX96AtPrice8(RTOKEN_HIGH, USDC_LOW, 2390 * 1e8);
        pool.setSqrtPrice(current);
        // usdc=token0: 매수 → sqrt 하락, limit은 current보다 작아야 함
        assertTrue(targetHigherPrice < current);
        assertTrue(AmmTwap.sqrtPriceLimitOk(address(pool), USDC_LOW, RTOKEN_HIGH, targetHigherPrice));
        assertFalse(AmmTwap.sqrtPriceLimitOk(address(pool), USDC_LOW, RTOKEN_HIGH, current)); // limit == current → SPL
        pool.setSqrtPrice(targetHigherPrice); // 이미 목표가 너머
        assertFalse(AmmTwap.sqrtPriceLimitOk(address(pool), USDC_LOW, RTOKEN_HIGH, targetHigherPrice));
    }

    function test_sqrtPriceLimitOk_oneForZero() public {
        MockUniV3Pool pool = new MockUniV3Pool();
        uint160 current = AmmTwap.sqrtPriceX96AtPrice8(USDC_LOW, RTOKEN_HIGH, 2000 * 1e8);
        uint160 targetHigherPrice = AmmTwap.sqrtPriceX96AtPrice8(USDC_LOW, RTOKEN_HIGH, 2390 * 1e8);
        pool.setSqrtPrice(current);
        // rToken=token0: 매수 → sqrt 상승, limit은 current보다 커야 함
        assertTrue(targetHigherPrice > current);
        assertTrue(AmmTwap.sqrtPriceLimitOk(address(pool), RTOKEN_HIGH, USDC_LOW, targetHigherPrice));
        assertFalse(AmmTwap.sqrtPriceLimitOk(address(pool), RTOKEN_HIGH, USDC_LOW, current));
        pool.setSqrtPrice(targetHigherPrice);
        assertFalse(AmmTwap.sqrtPriceLimitOk(address(pool), RTOKEN_HIGH, USDC_LOW, targetHigherPrice));
    }
}
