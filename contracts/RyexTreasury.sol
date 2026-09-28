// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRyexTreasury} from "./interfaces/IRyexTreasury.sol";

/// @title RyexTreasury — PositionVault 프로토콜 수익 전용 수납처
/// @notice 수신: borrow/mint/repay 누적 fee, redeem fee, 청산 penalty treasury 몫(40%).
///         청산 buyback 대기자금(오라클가 확정정산분)·사용자 담보는 VaultFactory에 유지.
/// @dev    Vault는 USDC를 직접 transfer. 인출은 governance(admin)만 sweep.
contract RyexTreasury is IRyexTreasury, Ownable {
    using SafeERC20 for IERC20;

    error ZeroAddress();

    constructor(address admin_) Ownable(admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
    }

    /// @inheritdoc IRyexTreasury
    function sweep(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Swept(address(token), to, amount);
    }
}
