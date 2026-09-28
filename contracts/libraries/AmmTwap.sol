// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "../v3/interfaces/IUniswapV3Pool.sol";

/// @title AmmTwap — UniV3 풀의 rToken 가격(8dec)·price-impact 한도를 읽는 external 라이브러리.
/// @notice rYield 진입/청산 게이트가 GMX 오라클 가격과 동일 단위(8dec)로 AMM 가격을 비교하고,
///         풀 깊이 기준 최대 집행 가능 USDC(price impact 한도)를 산출하기 위함.
/// @dev TickMath.getSqrtRatioAtTick는 Uniswap v3-core canonical 구현(상수 동일)을 0.8로 포팅.
///      external 라이브러리(delegatecall)로 두어 RYieldVault 바이트코드를 절감한다.
library AmmTwap {
    uint256 internal constant BPS = 10_000;
    int24 internal constant MAX_TICK = 887272;
    /// @dev Uniswap V3 TickMath — SPL 가드와 동일 범위.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    error TwapBadTick();
    error TwapZeroPool();
    error TwapZeroPrice();

    /// @notice rToken 1개의 USD 가격(8dec). baseToken=rToken, quoteToken=usdc.
    /// @param pool UniV3 rToken/USDC 풀
    /// @param rToken 가격을 매길 자산(18dec 가정)
    /// @param usdc 견적 토큰(6dec 가정)
    /// @param window TWAP 윈도우(초). 0이면 spot(slot0).
    function rTokenPrice8(address pool, address rToken, address usdc, uint32 window)
        external
        view
        returns (uint256 price8)
    {
        if (pool == address(0)) revert TwapZeroPool();
        int24 tick = window == 0 ? _spotTick(pool) : _meanTick(pool, window);
        uint256 usdc6 = _quoteAtTick(tick, 1e18, rToken, usdc); // 1 rToken → USDC(6dec)
        price8 = usdc6 * 100; // USDC 6dec → USD 8dec (1 USDC = 1 USD)
    }

    /// @notice price impact ≤ impactBps를 유지하는 최대 USDC 입력량(6dec).
    /// @dev UniV3 현재가 부근 가상유동성 근사: 입력/입력측리저브 ≈ 가격충격. impactBps==0이면 무제한.
    function maxUsdcInForImpact(address pool, address usdc, address rToken, uint16 impactBps)
        external
        view
        returns (uint256)
    {
        if (impactBps == 0) return type(uint256).max;
        if (pool == address(0)) revert TwapZeroPool();
        uint256 reserve = _usdcVirtualReserve(pool, usdc, rToken);
        return (reserve * impactBps) / BPS;
    }

    /// @notice price8(USD, rToken 1개 기준) → 해당 pool의 sqrtPriceX96. 청산 buyback의
    ///         `sqrtPriceLimitX96`(스왑이 이 가격에 도달하면 자동 정지)을 만들기 위함.
    /// @dev rTokenPrice8의 역변환 — 동일 raw-ratio 컨벤션(token1/token0)을 공유하며 그 식으로부터
    ///      교차검증 도출: ratioX192 = usdcIsToken0 ? 1e20·2^192/price8 : price8·2^192/1e20.
    ///      `Math.sqrt`는 내림이라 목표가에 아주 근접하되 넘지 않는 방향으로 약간 보수적이다.
    function sqrtPriceX96AtPrice8(address rToken, address usdc, uint256 price8) external pure returns (uint160) {
        if (price8 == 0) revert TwapZeroPrice();
        bool usdcIsToken0 = usdc < rToken;
        uint256 ratioX192 = usdcIsToken0
            ? Math.mulDiv(1e20, 1 << 192, price8)
            : Math.mulDiv(price8, 1 << 192, 1e20);
        uint256 sqrtX96 = Math.sqrt(ratioX192);
        require(sqrtX96 <= type(uint160).max, "AmmTwap: sqrtPrice overflow");
        return uint160(sqrtX96);
    }

    /// @notice UniV3 `SPL`을 피하기 위한 방향 가드. tokenIn→tokenOut 스왑의 `sqrtPriceLimitX96`이
    ///         현재 `slot0.sqrtPriceX96`의 올바른 쪽에 있으면 true.
    /// @dev zeroForOne(tokenIn=token0)이면 limit < current && limit > MIN. 반대면 limit > current && limit < MAX.
    ///      tick 기반 스팟가와 exact sqrt 한도가 어긋나 한도가 이미 넘어 있는 경우 buyback이 revert하지 않고 no-op.
    function sqrtPriceLimitOk(address pool, address tokenIn, address tokenOut, uint160 limit)
        external
        view
        returns (bool)
    {
        if (pool == address(0) || limit == 0) return false;
        (uint160 current,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (tokenIn < tokenOut) {
            return limit < current && limit > MIN_SQRT_RATIO;
        }
        return limit > current && limit < MAX_SQRT_RATIO;
    }

    /// @dev 현재가 기준 USDC측 가상 리저브(raw 6dec). x=L·2^96/√P (token0), y=L·√P/2^96 (token1).
    function _usdcVirtualReserve(address pool, address usdc, address rToken) private view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 L = uint256(IUniswapV3Pool(pool).liquidity());
        if (L == 0 || sqrtPriceX96 == 0) return 0;
        bool usdcIsToken0 = usdc < rToken;
        if (usdcIsToken0) {
            return Math.mulDiv(L, 1 << 96, sqrtPriceX96);
        }
        return Math.mulDiv(L, sqrtPriceX96, 1 << 96);
    }

    function _spotTick(address pool) private view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    function _meanTick(address pool, uint32 window) private view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int24 mean = int24(delta / int56(uint56(window)));
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) mean--; // OracleLibrary와 동일 내림 보정
        return mean;
    }

    /// @dev OracleLibrary.getQuoteAtTick 포팅. token0 = min(base,quote).
    function _quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken)
        private
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = _getSqrtRatioAtTick(tick);
        bool baseIsToken0 = baseToken < quoteToken;
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseIsToken0
                ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseIsToken0
                ? Math.mulDiv(ratioX128, baseAmount, 1 << 128)
                : Math.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    /// @dev Uniswap v3-core TickMath.getSqrtRatioAtTick — 상수 동일(0.8 포팅).
    function _getSqrtRatioAtTick(int24 tick) private pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (absTick > uint256(int256(MAX_TICK))) revert TwapBadTick();

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}
