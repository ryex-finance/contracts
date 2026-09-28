// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "../../contracts/VaultFactory.sol";
import {PositionVault} from "../../contracts/PositionVault.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {IPriceOracle} from "../../contracts/interfaces/IPriceOracle.sol";
import {AmmTwap} from "../../contracts/libraries/AmmTwap.sol";
import {RiskParams, GmxInfra} from "../../contracts/types/Types.sol";

contract MockOracleSettable is IPriceOracle {
    uint256 public price = 3000e8;

    function setPrice(uint256 p) external {
        price = p;
    }

    function getPrice() external view returns (uint256) {
        return price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @dev tick을 항상 0으로 고정 반환 — AmmTwap._spotTick/_meanTick은 slot0().tick / observe()의
///      tickCumulative만 보고 sqrtPriceX96 필드는 스팟가 계산에 쓰지 않는다(docs/liquidation-keeper-migration.md).
contract MockUniV3PoolFixedTick {
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, 0, 0, 0, 0, 0, true);
    }
}

/// @notice VaultFactory.buybackPreview — buybackAndBurn과 동일한 게이트를 revert 없이 재현하는지 검증.
///         (keeper가 오프체인에서 tick 수학을 재구현하지 않고 이 view 하나로 판단하기 위한 헬퍼, §liquidation-keeper-migration.md)
contract VaultFactoryBuybackPreviewTest is Test {
    VaultFactory internal factory;
    MockUSDC internal usdc;
    MockOracleSettable internal oracle;
    MockUniV3PoolFixedTick internal pool;
    bytes32 internal marketId;
    address internal rToken;
    address internal swapRouterStub = address(0xBEEF);

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockOracleSettable();
        pool = new MockUniV3PoolFixedTick();
        PositionVault impl = new PositionVault();
        factory = new VaultFactory(address(impl), address(usdc), address(this));
        factory.setGmxInfra(
            GmxInfra({
                exchangeRouter: address(0x1),
                gmxRouter: address(0x2),
                orderVault: address(0),
                reader: address(0),
                dataStore: address(0),
                orderHandler: address(0),
                execFee: 1e14,
                acceptablePriceMax: 0,
                acceptablePriceMin: 0
            })
        );

        marketId = keccak256("rETH");
        factory.addMarket(
            marketId,
            oracle,
            address(0),
            "RYex ETH",
            "rETH",
            RiskParams({maxLtv1xBps: 8_000, bufferBps: 1_000, maxLtvAtMaxLevBps: 4_500, flatTier: 3, maxLeverage: 10}),
            150
        );
        (,, rToken,,,,,,,,) = factory.markets(marketId);
    }

    function _earmark(uint256 usdcAmount, uint256 rTokenAmount) internal {
        address vault = factory.createVault(marketId, true, address(this));
        vm.prank(vault);
        factory.notifyLiquidationEarmark(marketId, usdcAmount, rTokenAmount);
    }

    function _spotPrice8() internal view returns (uint256) {
        return AmmTwap.rTokenPrice8(address(pool), rToken, address(usdc), 0);
    }

    function test_notReady_marketNotActive() public view {
        (bool ready,,,,, uint256 bucket, uint256 outstanding) = factory.buybackPreview(keccak256("nope"));
        assertFalse(ready);
        assertEq(bucket, 0);
        assertEq(outstanding, 0);
    }

    function test_notReady_poolNotSet() public {
        _earmark(1000e6, 1e18);
        (bool ready,,,,,,) = factory.buybackPreview(marketId);
        assertFalse(ready, "PoolNotSet must not be ready");
    }

    function test_notReady_noBucketOrOutstanding() public {
        factory.setMarketPool(marketId, address(pool));
        (bool ready,,,,, uint256 bucket, uint256 outstanding) = factory.buybackPreview(marketId);
        assertFalse(ready);
        assertEq(bucket, 0);
        assertEq(outstanding, 0);
    }

    function test_notReady_swapRouterNotSet() public {
        factory.setMarketPool(marketId, address(pool));
        _earmark(1000e6, 1e18);
        (bool ready,,,,, uint256 bucket, uint256 outstanding) = factory.buybackPreview(marketId);
        assertFalse(ready, "swapRouter unset must not be ready");
        assertEq(bucket, 1000e6);
        assertEq(outstanding, 1e18);
    }

    function test_ready_whenSpotBelowTargetAndOracle() public {
        factory.setMarketPool(marketId, address(pool));
        factory.setSwapRouter(swapRouterStub, 3000);
        factory.setBuybackParams(0, 20, 100); // twapWindow=0(비활성), bounty 0.2%, buffer 1%
        _earmark(1000e6, 1e18);

        uint256 spot = _spotPrice8();
        // oracle = spot / 0.98 → spot이 오라클의 98%. buffer 1%(target=oracle*0.99)보다 낮으므로 ready=true.
        uint256 oraclePrice = (spot * 100) / 98;
        oracle.setPrice(oraclePrice);

        (bool ready, uint256 spotPrice8, uint256 twapPrice8, uint256 oraclePrice8, uint256 targetPrice8,,) =
            factory.buybackPreview(marketId);

        assertTrue(ready, "spot below oracle*(1-buffer) must be ready");
        assertEq(spotPrice8, spot);
        assertEq(twapPrice8, 0, "twap must be 0 when window disabled");
        assertEq(oraclePrice8, oraclePrice);
        assertEq(targetPrice8, (oraclePrice * 9_900) / 10_000);
        assertLt(spotPrice8, targetPrice8);
    }

    function test_notReady_whenSpotAboveOracle() public {
        factory.setMarketPool(marketId, address(pool));
        factory.setSwapRouter(swapRouterStub, 3000);
        factory.setBuybackParams(0, 20, 100);
        _earmark(1000e6, 1e18);

        uint256 spot = _spotPrice8();
        // oracle을 spot보다 낮게 — 풀이 오라클보다 비싼 상황. buybackAndBurn이면 revert하지만
        // buybackPreview는 view라 조용히 ready=false만 반환한다(운영에서 폴링해도 안전).
        oracle.setPrice(spot - 1);

        (bool ready,,,,,,) = factory.buybackPreview(marketId);
        assertFalse(ready, "spot above oracle must not be ready");
    }

    function test_notReady_whenSpotWithinBufferOfOracle() public {
        factory.setMarketPool(marketId, address(pool));
        factory.setSwapRouter(swapRouterStub, 3000);
        factory.setBuybackParams(0, 20, 100); // buffer 1%
        _earmark(1000e6, 1e18);

        uint256 spot = _spotPrice8();
        // oracle == spot → target = spot*0.99 < spot → spot < target 실패(할인폭이 buffer 이내).
        oracle.setPrice(spot);

        (bool ready,,,,,,) = factory.buybackPreview(marketId);
        assertFalse(ready, "spot inside buffer of oracle must not be ready");
    }

    /// @dev buybackAndBurn과 상태 변경(스왑·소각·버킷 차감) 없이 완전히 같은 판정을 내려야 한다는 게 이
    ///      view의 존재 이유 — buybackPreview 호출 전후로 회계값이 안 바뀌는지도 함께 확인.
    function test_preview_doesNotMutateState() public {
        factory.setMarketPool(marketId, address(pool));
        factory.setSwapRouter(swapRouterStub, 3000);
        factory.setBuybackParams(0, 20, 100);
        _earmark(1000e6, 1e18);
        oracle.setPrice((_spotPrice8() * 100) / 98);

        factory.buybackPreview(marketId);
        factory.buybackPreview(marketId);

        assertEq(factory.pendingBuybackUsdc(marketId), 1000e6);
        assertEq(factory.outstandingUnretired(marketId), 1e18);
    }
}
