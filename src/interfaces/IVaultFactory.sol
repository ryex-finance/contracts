// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";
import {IGmxAdapter} from "./IGmxAdapter.sol";

/// @title IVaultFactory — 멀티에셋 마켓 레지스트리 + 사용자별 PositionVault clone (docs/10, Wave 1)
interface IVaultFactory {
    event VaultCreated(address indexed owner, bytes32 indexed marketId, address vault);
    event MarketAdded(bytes32 indexed marketId, address oracle, address rToken);

    /// @notice (msg.sender, marketId)용 Vault clone 생성·초기화. 마켓별 1인1볼트(I1).
    function createVault(bytes32 marketId) external returns (address vault);

    function vaultOf(address owner, bytes32 marketId) external view returns (address);
    function isVault(address vault) external view returns (bool);

    /// @notice 마켓 설정 조회 (flat Market). Litepaper v1.6 레버리지 곡선 파라미터.
    function markets(bytes32 marketId)
        external
        view
        returns (
            bool active,
            address oracle,
            address rToken,
            uint16 maxLtv1xBps,
            uint16 bufferBps,
            uint16 maxLtvAtMaxLevBps,
            uint8 flatTier,
            uint8 maxLeverage
        );

    /// @notice Vault가 collateral 증감 시 호출 → factory의 totalCollateralLocked 갱신.
    ///         delta > 0: 증가(deposit), delta < 0: 감소(withdraw/close/liquidation).
    ///         isVault[msg.sender] 가드로 registered vault만 허용.
    function onCollateralChanged(int256 delta) external;

    function totalCollateralLocked() external view returns (uint256);

    // 환경 주입 의존성 (하드코딩 금지)
    function gmxAdapter() external view returns (IGmxAdapter);
    function usdc() external view returns (address);
    function paused() external view returns (bool);
}
