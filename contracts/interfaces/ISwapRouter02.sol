// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @notice Uniswap V3 SwapRouter (v3-periphery) `exactInputSingle`.
/// @dev 이름에 02가 남아 있으나 ABI는 SwapRouter02가 아니다. Sepolia/이 레포 배포본은
///      v3-periphery SwapRouter — struct에 `deadline`이 있다.
///      SwapRouter02(deadline 없음) 셀렉터로 호출하면 함수를 못 찾고 revert한다.
///      청산 buyback(factory.buybackAndBurn) + rYield 롱 leg 공용.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
