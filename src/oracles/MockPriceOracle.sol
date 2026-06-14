// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IRedemptionQueueSync} from "../interfaces/IRedemptionQueueSync.sol";

/// @title MockPriceOracle — 데모/로컬 가격 시뮬 (docs/14)
/// @notice 가격 임의 변경(setPrice)으로 §5 하락 시나리오 재현. 인터페이스·fail-safe는 프로덕션과 동일.
///         setPrice 시 factory.syncRedemptionQueueForOracle 호출 → RLT zone 진입 볼트 자동 큐 등록.
contract MockPriceOracle is IPriceOracle {
    uint256 private _price; // 8 decimals
    address public owner;
    IRedemptionQueueSync public redemptionSync;

    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event OwnerTransferred(address indexed from, address indexed to);
    event RedemptionSyncConfigured(address indexed factory);

    error NotOwner();
    error ZeroPrice();

    constructor(uint256 initialPrice8) {
        if (initialPrice8 == 0) revert ZeroPrice();
        _price = initialPrice8;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param price8 새 가격. **8 decimals (Chainlink 표준)**:
    ///              예) $1,650 → 165_000_000_000 (= 1650 × 10^8).
    function setPrice(uint256 price8) external {
        if (price8 == 0) revert ZeroPrice(); // fail-safe P1
        emit PriceUpdated(_price, price8);
        _price = price8;
        if (address(redemptionSync) != address(0)) {
            redemptionSync.syncRedemptionQueueForOracle(address(this));
        }
    }

    /// @notice VaultFactory 연결. 배포 스크립트에서 1회 설정.
    function configureRedemptionSync(IRedemptionQueueSync sync) external onlyOwner {
        redemptionSync = sync;
        emit RedemptionSyncConfigured(address(sync));
    }

    function transferOwnership(address to) external onlyOwner {
        emit OwnerTransferred(owner, to);
        owner = to;
    }

    /// @return asset/USD **8 decimals**. 예) $1,650 → 165_000_000_000. 프론트: formatUnits(v, 8).
    function getPrice() external view returns (uint256) {
        return _price; // _price>0 보장(생성자/setter)
    }

    /// @return 8 (Chainlink 표준)
    function decimals() external pure returns (uint8) {
        return 8;
    }
}
