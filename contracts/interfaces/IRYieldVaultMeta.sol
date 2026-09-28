// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";

/// @dev registry 등록 검증·identity 조회용 — GmxIntegrationBase/RYieldVault public getter 매핑.
/// @notice RYieldVault는 이 인터페이스를 explicit implement 하지 않는다(public auto-getter로 충족).
interface IRYieldVaultMeta {
    function factory() external view returns (address);
    function owner() external view returns (address);
    function treasury() external view returns (address);
    function fundingDistributor() external view returns (address);
    function assetName() external view returns (string memory);
    function oracle() external view returns (IPriceOracle);
}
