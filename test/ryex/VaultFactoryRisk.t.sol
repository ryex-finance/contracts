// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "../../contracts/VaultFactory.sol";
import {PositionVault} from "../../contracts/PositionVault.sol";
import {VaultLens} from "../../contracts/VaultLens.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {IPriceOracle} from "../../contracts/interfaces/IPriceOracle.sol";
import {IVaultFactory} from "../../contracts/interfaces/IVaultFactory.sol";
import {RiskParams, GmxInfra} from "../../contracts/types/Types.sol";

contract MockOracle is IPriceOracle {
    uint256 internal _price = 3000e8;

    function getPrice() external view returns (uint256) {
        return _price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract VaultFactoryRiskTest is Test {
    VaultFactory internal factory;
    VaultLens internal lens;
    MockUSDC internal usdc;
    MockOracle internal oracle;
    bytes32 internal marketId;
    address internal vault;
    address internal admin = address(this);
    address internal user = address(0xBEEF);

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockOracle();
        PositionVault impl = new PositionVault();
        factory = new VaultFactory(address(impl), address(usdc), admin);
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
        RiskParams memory risk = RiskParams({
            maxLtv1xBps: 8_000,
            bufferBps: 1_000,
            maxLtvAtMaxLevBps: 4_500,
            flatTier: 3,
            maxLeverage: 10
        });
        factory.addMarket(marketId, oracle, address(0), "RYex ETH", "rETH", risk, 150);

        vault = factory.createVault(marketId, false, user);
        lens = new VaultLens(IVaultFactory(address(factory)));
    }

    function test_setBufferBps_updatesMarketAndLens() public {
        assertEq(lens.lltvBps(vault), 9_000);

        factory.setBufferBps(marketId, 500);

        (,,,,,, uint16 buffer,,,,) = factory.markets(marketId);
        assertEq(buffer, 500);
        assertEq(lens.lltvBps(vault), 8_500);
        assertEq(lens.vaultInfo(vault).bufferBps, 500);
    }

    function test_setMarketRisk_updatesCurveParams() public {
        RiskParams memory risk = RiskParams({
            maxLtv1xBps: 7_500,
            bufferBps: 800,
            maxLtvAtMaxLevBps: 5_000,
            flatTier: 2,
            maxLeverage: 5
        });
        factory.setMarketRisk(marketId, risk);

        assertEq(lens.vaultInfo(vault).maxLtv1xBps, 7_500);
        assertEq(lens.vaultInfo(vault).bufferBps, 800);
        assertEq(lens.vaultInfo(vault).maxLtvAtMaxLevBps, 5_000);
        assertEq(lens.vaultInfo(vault).flatTier, 2);
        assertEq(lens.vaultInfo(vault).maxLeverage, 5);
        assertEq(lens.lltvBps(vault), 8_300);
        assertEq(lens.rltBps(vault), 7_500);
    }

    function test_setBufferBps_revertsBadParams() public {
        vm.expectRevert(VaultFactory.BadRiskParams.selector);
        factory.setBufferBps(marketId, 3_000);
    }

    function test_setMarketRisk_revertsBadCurve() public {
        RiskParams memory bad = RiskParams({
            maxLtv1xBps: 8_000,
            bufferBps: 1_000,
            maxLtvAtMaxLevBps: 9_000,
            flatTier: 3,
            maxLeverage: 10
        });
        vm.expectRevert(VaultFactory.BadRiskParams.selector);
        factory.setMarketRisk(marketId, bad);
    }

    function test_setBufferBps_revertsUnknownMarket() public {
        vm.expectRevert(VaultFactory.NoMarket.selector);
        factory.setBufferBps(keccak256("nope"), 500);
    }

    function _marketBorrowApr(bytes32 id) internal view returns (uint16 apr) {
        (
            , // active
            , // oracle
            , // rToken
            , // gmxMarket
            , // pool
            , // maxLtv1xBps
            , // bufferBps
            , // maxLtvAtMaxLevBps
            , // flatTier
            , // maxLeverage
            apr
        ) = factory.markets(id);
    }

    function test_addMarket_setsDefaultBorrowApr() public view {
        assertEq(_marketBorrowApr(marketId), 150);
        assertEq(lens.borrowAprBps(vault), 150);
        assertEq(lens.vaultInfo(vault).borrowAprBps, 150);
    }

    function test_setBorrowAprBps_updatesMarketAndLens() public {
        factory.setBorrowAprBps(marketId, 300);
        assertEq(_marketBorrowApr(marketId), 300);
        assertEq(lens.borrowAprBps(vault), 300);
        assertEq(lens.vaultInfo(vault).borrowAprBps, 300);
    }

    function test_setBorrowAprBps_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IVaultFactory.MarketBorrowAprUpdated(marketId, 150, 300);
        factory.setBorrowAprBps(marketId, 300);
    }

    function test_setBorrowAprBps_revertsAboveCap() public {
        vm.expectRevert(VaultFactory.BadBorrowApr.selector);
        factory.setBorrowAprBps(marketId, 5_001);
    }

    function test_setBorrowAprBps_revertsUnknownMarket() public {
        vm.expectRevert(VaultFactory.NoMarket.selector);
        factory.setBorrowAprBps(keccak256("nope"), 300);
    }

    function test_setBorrowAprBps_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        factory.setBorrowAprBps(marketId, 300);
    }

    function test_perMarket_borrowApr_isIndependent() public {
        bytes32 marketId2 = keccak256("rBTC");
        RiskParams memory risk = RiskParams({
            maxLtv1xBps: 6_500,
            bufferBps: 1_000,
            maxLtvAtMaxLevBps: 4_500,
            flatTier: 3,
            maxLeverage: 10
        });
        factory.addMarket(marketId2, oracle, address(0), "RYex BTC", "rBTC", risk, 400);

        // marketId(rETH) borrowApr는 그대로 150이어야 — 다른 마켓 추가/변경에 영향받지 않음.
        assertEq(_marketBorrowApr(marketId), 150);
        assertEq(_marketBorrowApr(marketId2), 400);

        factory.setBorrowAprBps(marketId, 700);
        assertEq(_marketBorrowApr(marketId), 700, "rETH updated");
        assertEq(_marketBorrowApr(marketId2), 400, "rBTC untouched by rETH's setBorrowAprBps");
    }

    function test_lens_clampsLeverageAboveMax() public {
        OverLevVault over = new OverLevVault(marketId);
        factory.setMarketRisk(
            marketId,
            RiskParams({
                maxLtv1xBps: 8_000,
                bufferBps: 1_000,
                maxLtvAtMaxLevBps: 4_500,
                flatTier: 3,
                maxLeverage: 5
            })
        );
        assertEq(lens.effectiveMaxLtvBps(address(over)), 4_500);
    }
}

/// @dev VaultLens clamp 검증용 — risk는 factory, leverage만 vault.
contract OverLevVault {
    bytes32 public marketId;
    uint8 public leverage = 10;

    constructor(bytes32 marketId_) {
        marketId = marketId_;
    }
}
