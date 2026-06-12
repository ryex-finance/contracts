// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRyexSwapPool} from "../interfaces/IRyexSwapPool.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {Units} from "../libraries/Units.sol";

/// @title MockSwapPool — 데모용 rBTC→USDC 오라클 1:1 스왑 (docs/15 §3)
/// @notice 오라클 가격으로 환산(수수료 0, 슬리피지 없음). USDC float를 보유(배포 시 시드).
///         스왑은 Vault.debt를 변경하지 않음(docs/15 S2) — rBTC는 EOA 자산일 뿐이다.
contract MockSwapPool is IRyexSwapPool {
    using SafeERC20 for IERC20;

    IPriceOracle public immutable oracle;
    IERC20 public immutable rBtc;
    IERC20 public immutable usdc;

    event SwappedUsdcForRBtc(address indexed user, uint256 usdcIn, uint256 rBtcOut);

    error Slippage();

    constructor(IPriceOracle oracle_, IERC20 rBtc_, IERC20 usdc_) {
        oracle = oracle_;
        rBtc = rBtc_;
        usdc = usdc_;
    }

    /// @notice rBTC(18dec) → USDC(6dec) at oracle price. Units로 정밀도 단일화(OQ-3).
    function quoteRBtcToUsdc(uint256 rBtcIn) public view returns (uint256) {
        return Units.wadToUsdc(Units.btcToUsdWad(rBtcIn, oracle.getPrice()));
    }

    function swapRBtcForUsdc(uint256 rBtcIn, uint256 minUsdcOut, address to) external returns (uint256 out) {
        out = quoteRBtcToUsdc(rBtcIn);
        if (out < minUsdcOut) revert Slippage(); // S3
        rBtc.safeTransferFrom(msg.sender, address(this), rBtcIn); // S1
        usdc.safeTransfer(to, out);
        emit Swapped(msg.sender, rBtcIn, out);
    }

    /// @notice USDC(6dec) → rBTC(18dec) at oracle price. rYield 롱 레그 매수용(역방향). 풀의 rBTC float에서 지급.
    function quoteUsdcToRBtc(uint256 usdcIn) public view returns (uint256) {
        return Units.usdWadToBtc(Units.usdcToWad(usdcIn), oracle.getPrice());
    }

    function swapUsdcForRBtc(uint256 usdcIn, uint256 minRBtcOut, address to) external returns (uint256 out) {
        out = quoteUsdcToRBtc(usdcIn);
        if (out < minRBtcOut) revert Slippage();
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        rBtc.safeTransfer(to, out); // from the pool's rBTC float
        emit SwappedUsdcForRBtc(msg.sender, usdcIn, out);
    }
}
