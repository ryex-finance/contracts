// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IRyexRouter — 유저 진입점: vault 조회/생성 + USDC deposit / open (1 tx).
interface IRyexRouter {
    /// @notice vault 없으면 생성 후 USDC 입금. 있으면 owner 검증 후 입금.
    /// @dev USDC는 Router에 approve 필요. Router가 vault로 transfer 후 vault.deposit 호출.
    function deposit(bytes32 marketId, bool isLong, uint256 usdcAmount) external;

    /// @notice 요청 `collateralUsdc`만큼 오픈. vault 가용분이 부족하면 부족분만 transferFrom+deposit 후 open.
    /// @dev USDC는 Router에 approve(부족분). exec fee는 msg.value로 vault에 전달.
    /// @param triggerPrice8 0 = market open, else limit open (8 decimals)
    function openPosition(
        bytes32 marketId,
        bool isLong,
        uint8 leverage,
        uint256 triggerPrice8,
        uint256 collateralUsdc
    ) external payable;
}
