// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRyexRouter} from "./interfaces/IRyexRouter.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPositionVault} from "./interfaces/IPositionVault.sol";
import {VaultState} from "./types/Types.sol";

/// @title RyexRouter — 유저 USDC 진입점 (vault 생성 + deposit / open).
/// @notice USDC는 Router에 approve. 첫 주문도 vault 주소 없이 deposit·open 가능.
contract RyexRouter is IRyexRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IVaultFactory public immutable factory;

    error VaultOwnerMismatch();

    constructor(IVaultFactory factory_) {
        require(address(factory_) != address(0), "zero factory");
        factory = factory_;
    }

    /// @inheritdoc IRyexRouter
    function deposit(bytes32 marketId, bool isLong, uint256 usdcAmount) external nonReentrant {
        require(usdcAmount > 0, "zero amount");
        address user = msg.sender;
        address vault = _vaultFor(user, marketId, isLong);
        IERC20 usdc = IERC20(factory.usdc());
        usdc.safeTransferFrom(user, vault, usdcAmount);
        IPositionVault(vault).deposit(user, usdcAmount);
    }

    /// @inheritdoc IRyexRouter
    function openPosition(
        bytes32 marketId,
        bool isLong,
        uint8 leverage,
        uint256 triggerPrice8,
        uint256 collateralUsdc
    ) external payable nonReentrant {
        require(collateralUsdc > 0, "zero amount");
        address user = msg.sender;
        address vault = _vaultFor(user, marketId, isLong);

        uint256 available = _availableOpenCollateral(vault);
        if (collateralUsdc > available) {
            uint256 shortfall = collateralUsdc - available;
            IERC20 usdc = IERC20(factory.usdc());
            usdc.safeTransferFrom(user, vault, shortfall);
            IPositionVault(vault).deposit(user, shortfall);
        }

        IPositionVault(vault).openPosition{value: msg.value}(leverage, triggerPrice8, isLong, collateralUsdc);
    }

    /// @dev Empty → vault.collateral(), Active → idle USDC balance. 그 외 0.
    function _availableOpenCollateral(address vault) internal view returns (uint256) {
        VaultState s = IPositionVault(vault).state();
        if (s == VaultState.Empty) return IPositionVault(vault).collateral();
        if (s == VaultState.Active) return IERC20(factory.usdc()).balanceOf(vault);
        return 0;
    }

    function _vaultFor(address user, bytes32 marketId, bool isLong) internal returns (address vault) {
        vault = factory.vaultOf(user, marketId, isLong);
        if (vault == address(0)) {
            vault = factory.createVault(marketId, isLong, user);
        } else if (IPositionVault(vault).owner() != user) {
            revert VaultOwnerMismatch();
        }
    }
}
