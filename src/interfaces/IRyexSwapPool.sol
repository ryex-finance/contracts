// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IRyexSwapPool — rBTC↔USDC 스왑 풀 경계 (docs/15 §3)
/// @notice 데모는 MockSwapPool(오라클 1:1). RYEX 팀 실제 풀이 나오면 같은 인터페이스로 교체(무수정).
interface IRyexSwapPool {
    event Swapped(address indexed user, uint256 rBtcIn, uint256 usdcOut);

    /// @notice rBTC 입력 → USDC 출력. 사용자 EOA가 직접 호출(rBTC approve 선행).
    function swapRBtcForUsdc(uint256 rBtcIn, uint256 minUsdcOut, address to) external returns (uint256 usdcOut);

    /// @notice 견적(view). 주어진 rBTC 입력에 대한 예상 USDC 출력.
    function quoteRBtcToUsdc(uint256 rBtcIn) external view returns (uint256 usdcOut);

    /// @notice USDC 입력 → rBTC 출력 (rYield 롱 레그 매수). USDC approve 선행. 풀의 rBTC float에서 지급.
    function swapUsdcForRBtc(uint256 usdcIn, uint256 minRBtcOut, address to) external returns (uint256 rBtcOut);

    /// @notice 견적(view). 주어진 USDC 입력에 대한 예상 rBTC 출력.
    function quoteUsdcToRBtc(uint256 usdcIn) external view returns (uint256 rBtcOut);
}
