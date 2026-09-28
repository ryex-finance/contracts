// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RYieldRegistry} from "../../contracts/RYieldRegistry.sol";
import {IRYieldVaultSource} from "../../contracts/interfaces/IRYieldVaultSource.sol";
import {IRYieldVaultMeta} from "../../contracts/interfaces/IRYieldVaultMeta.sol";
import {IVaultFactory} from "../../contracts/interfaces/IVaultFactory.sol";
import {IPriceOracle} from "../../contracts/interfaces/IPriceOracle.sol";
import {RYieldState, RYieldLensPack, RYieldVaultSummary, RYieldUserSummary, RYieldFundingSummary, GmxInfra} from "../../contracts/types/Types.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 internal _price;

    function setPrice(uint256 p) external {
        _price = p;
    }

    function getPrice() external view returns (uint256) {
        return _price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract MockFundingDistributor {
    address public vault;
    uint256 public longConfirmed;
    uint256 public longPending;
    uint256 public shortConfirmed;
    uint256 public shortPending;
    uint256 public longAccrued;
    uint256 public shortAccrued;
    uint256 public vaultClaimableLong;
    uint256 public vaultClaimableShort;

    constructor(address vault_) {
        vault = vault_;
    }

    function setFunding(
        uint256 lc,
        uint256 lp,
        uint256 sc,
        uint256 sp,
        uint256 la,
        uint256 sa,
        uint256 vcl,
        uint256 vcs
    ) external {
        longConfirmed = lc;
        longPending = lp;
        shortConfirmed = sc;
        shortPending = sp;
        longAccrued = la;
        shortAccrued = sa;
        vaultClaimableLong = vcl;
        vaultClaimableShort = vcs;
    }

    function claimableAll(address)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (longConfirmed, longPending, shortConfirmed, shortPending, longAccrued, shortAccrued);
    }

    function vaultClaimableGmx() external view returns (uint256, uint256) {
        return (vaultClaimableLong, vaultClaimableShort);
    }
}

contract MockVaultFactory {
    struct Mkt {
        bool active;
        address oracle;
        address rToken;
    }

    mapping(bytes32 => Mkt) internal _markets;
    address public usdc;
    uint256 public execFee = 0.001 ether;

    function setMarket(bytes32 id, address oracle, address rt) external {
        _markets[id] = Mkt({active: true, oracle: oracle, rToken: rt});
    }

    function markets(bytes32 id)
        external
        view
        returns (
            bool active,
            address oracle,
            address rToken,
            address,
            address,
            uint16,
            uint16,
            uint16,
            uint8,
            uint8,
            uint16
        )
    {
        Mkt memory m = _markets[id];
        return (m.active, m.oracle, m.rToken, address(0), address(0), 0, 0, 0, 0, 0, 0);
    }

    function gmxInfra() external view returns (GmxInfra memory infra) {
        infra.execFee = execFee;
    }
}

contract MockRYieldVault is IRYieldVaultSource, IRYieldVaultMeta {
    address internal _factory;
    address internal _owner;
    address internal _treasury;
    address internal _fundingDistributor;
    string internal _assetName;
    bytes32 internal _marketId;
    address internal _rToken;
    MockPriceOracle internal _oracle;
    RYieldLensPack internal pack;
    uint256 internal _usdcBal;
    uint256 internal _rTokBal;
    uint256 internal _gmxEquityWad;
    bool internal _settlePending;
    uint256 internal _accruedLong;
    uint256 internal _accruedShort;

    mapping(address => uint256) internal _sharesOf;
    mapping(address => uint256) internal _redeemSharesOf;
    mapping(address => uint256) internal _redeemReqEpoch;
    mapping(uint256 => uint256) internal _epochPayoutUsdc;
    mapping(uint256 => uint256) internal _epochRedeemShares;

    function setMeta(
        address factory_,
        address owner_,
        address treasury_,
        address distributor_,
        string calldata name_,
        bytes32 marketId_,
        address rToken_,
        MockPriceOracle oracle_
    ) external {
        _factory = factory_;
        _owner = owner_;
        _treasury = treasury_;
        _fundingDistributor = distributor_;
        _assetName = name_;
        _marketId = marketId_;
        _rToken = rToken_;
        _oracle = oracle_;
    }

    function setPack(RYieldLensPack calldata p) external {
        pack = p;
    }

    function setBalances(uint256 usdcBal, uint256 rTokBal, uint256 gmxEquityWad) external {
        _usdcBal = usdcBal;
        _rTokBal = rTokBal;
        _gmxEquityWad = gmxEquityWad;
    }

    function setFundingFlags(bool settlePending, uint256 accruedLong, uint256 accruedShort) external {
        _settlePending = settlePending;
        _accruedLong = accruedLong;
        _accruedShort = accruedShort;
    }

    function setUser(address user, uint256 shares) external {
        _sharesOf[user] = shares;
    }

    function setFundingDistributor(address d) external {
        _fundingDistributor = d;
    }

    function factory() external view returns (address) {
        return _factory;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function treasury() external view returns (address) {
        return _treasury;
    }

    function fundingDistributor() external view returns (address) {
        return _fundingDistributor;
    }

    function assetName() external view returns (string memory) {
        return _assetName;
    }

    function oracle() external view returns (IPriceOracle) {
        return _oracle;
    }

    function marketId() external view returns (bytes32) {
        return _marketId;
    }

    function rToken() external view returns (address) {
        return _rToken;
    }

    function ryieldPack() external view returns (RYieldLensPack memory) {
        return pack;
    }

    function sharesOf(address user) external view returns (uint256) {
        return _sharesOf[user];
    }

    function redeemSharesOf(address user) external view returns (uint256) {
        return _redeemSharesOf[user];
    }

    function redeemReqEpoch(address user) external view returns (uint256) {
        return _redeemReqEpoch[user];
    }

    function epochPayoutUsdc(uint256 epoch) external view returns (uint256) {
        return _epochPayoutUsdc[epoch];
    }

    function epochRedeemShares(uint256 epoch) external view returns (uint256) {
        return _epochRedeemShares[epoch];
    }

    function lensGmxEquityUsdWad() external view returns (uint256) {
        return _gmxEquityWad;
    }

    function usdcBalance() external view returns (uint256) {
        return _usdcBal;
    }

    function rTokenBalance() external view returns (uint256) {
        return _rTokBal;
    }

    function fundingSharesOf(address user) external view returns (uint256) {
        return _sharesOf[user];
    }

    function fundingSettlePending() external view returns (bool) {
        return _settlePending;
    }

    function vaultAccruedFundingGmx() external view returns (uint256 longAmount, uint256 shortAmount) {
        return (_accruedLong, _accruedShort);
    }
}

contract RYieldRegistryTest is Test {
    bytes32 internal constant MARKET = keccak256("rETH");
    address internal admin = makeAddr("admin");
    address internal user = makeAddr("user");

    MockVaultFactory internal vf;
    MockPriceOracle internal oracle;
    RYieldRegistry internal registry;
    MockRYieldVault internal vault;
    MockFundingDistributor internal distributor;
    address internal rTokenAddr;

    function setUp() public {
        vf = new MockVaultFactory();
        oracle = new MockPriceOracle();
        oracle.setPrice(3_000e8);
        rTokenAddr = makeAddr("rETH");
        vf.setMarket(MARKET, address(oracle), rTokenAddr);

        registry = new RYieldRegistry(IVaultFactory(address(vf)), admin);

        vault = new MockRYieldVault();
        distributor = new MockFundingDistributor(address(vault));

        vault.setMeta(
            address(vf),
            admin,
            makeAddr("treasury"),
            address(distributor),
            "rYield rETH",
            MARKET,
            rTokenAddr,
            oracle
        );
        vault.setBalances(1_000e6, 0, 0);
        vault.setFundingFlags(true, 9e18, 10e18);
        vault.setPack(
            RYieldLensPack({
                state: RYieldState.Idle,
                totalShares: 1_000e6,
                pendingOrderKey: bytes32(0),
                pendingCreatedAt: 0,
                depositCap: 10_000e6,
                perfFeeBps: 1_000,
                maxPriceImpactBps: 30,
                maxEntryPremiumBps: 0,
                maxExitDiscountBps: 0,
                targetLeverage: 2,
                hwmAssetsPerShareWad: 1e18,
                entryGapBps: 0,
                hedgedNotionalUsdc: 0,
                minDeposit: 500e6,
                gapCheckEnabled: true,
                pool: address(0),
                twapWindow: 60,
                reservedClaimableUsdc: 0,
                totalRedeemShares: 0,
                currentRedeemEpoch: 0,
                settlingEpoch: 0,
                settlingRemainingShares: 0
            })
        );
        vault.setUser(user, 100e6);

        distributor.setFunding(1e18, 2e18, 3e18, 4e18, 5e18, 6e18, 7e18, 8e18);
    }

    function test_register_and_marketId_views() public {
        vm.prank(admin);
        registry.register(MARKET, address(vault), address(distributor));

        assertEq(registry.totalShares(MARKET), 1_000e6);
        assertEq(registry.totalAssetsUsdc(MARKET), 1_000e6);
        assertEq(registry.sharesOf(MARKET, user), 100e6);
        assertEq(registry.assetsOf(MARKET, user), 100e6);
        assertTrue(registry.fundingSettlePending(MARKET));
        assertEq(registry.execFee(MARKET), 0.001 ether);

        RYieldVaultSummary memory vs = registry.vaultSummary(MARKET);
        assertEq(vs.marketId, MARKET);
        assertEq(vs.totalAssetsUsdc, 1_000e6);
        assertEq(vs.oraclePrice8, 3_000e8);

        RYieldFundingSummary memory fs = registry.fundingSummary(MARKET, user);
        assertEq(fs.longConfirmed, 1e18);
        assertEq(fs.vaultAccruedLong, 9e18);
    }

    function test_register_revertsOnDuplicate() public {
        vm.prank(admin);
        registry.register(MARKET, address(vault), address(distributor));

        vm.prank(admin);
        vm.expectRevert(RYieldRegistry.VaultExists.selector);
        registry.register(MARKET, address(vault), address(distributor));
    }

    function test_view_revertsWhenNotRegistered() public {
        vm.expectRevert(RYieldRegistry.NotRegistered.selector);
        registry.totalAssetsUsdc(MARKET);
    }

    function test_distributorOf_tracksVaultUpdate() public {
        vm.prank(admin);
        registry.register(MARKET, address(vault), address(distributor));
        assertEq(registry.distributorOf(MARKET), address(distributor));

        MockFundingDistributor distributor2 = new MockFundingDistributor(address(vault));
        vault.setFundingDistributor(address(distributor2));
        assertEq(registry.distributorOf(MARKET), address(distributor2));
    }

    function test_unregister_clearsMappingsAndAllowsReregister() public {
        vm.prank(admin);
        registry.register(MARKET, address(vault), address(distributor));
        assertEq(registry.totalVaults(), 1);

        vm.prank(admin);
        registry.unregister(MARKET);

        assertEq(registry.vaultOf(MARKET), address(0));
        assertEq(registry.vaultByRToken(rTokenAddr), address(0));
        assertEq(registry.marketIdOfVault(address(vault)), bytes32(0));
        assertFalse(registry.isRYieldVault(address(vault)));
        assertEq(registry.totalVaults(), 0);

        vm.expectRevert(RYieldRegistry.NotRegistered.selector);
        registry.totalAssetsUsdc(MARKET);

        vm.prank(admin);
        registry.register(MARKET, address(vault), address(distributor));
        assertEq(registry.vaultOf(MARKET), address(vault));
        assertEq(registry.totalVaults(), 1);
    }

    function test_replaceVault_swapsRegistryEntry() public {
        vm.prank(admin);
        registry.register(MARKET, address(vault), address(distributor));

        MockRYieldVault vault2 = new MockRYieldVault();
        MockFundingDistributor distributor2 = new MockFundingDistributor(address(vault2));
        vault2.setMeta(
            address(vf),
            admin,
            makeAddr("treasury2"),
            address(distributor2),
            "rYield rETH v2",
            MARKET,
            rTokenAddr,
            oracle
        );
        vault2.setBalances(2_000e6, 0, 0);
        vault2.setPack(
            RYieldLensPack({
                state: RYieldState.Idle,
                totalShares: 2_000e6,
                pendingOrderKey: bytes32(0),
                pendingCreatedAt: 0,
                depositCap: 10_000e6,
                perfFeeBps: 1_000,
                maxPriceImpactBps: 30,
                maxEntryPremiumBps: 0,
                maxExitDiscountBps: 0,
                targetLeverage: 2,
                hwmAssetsPerShareWad: 1e18,
                entryGapBps: 0,
                hedgedNotionalUsdc: 0,
                minDeposit: 500e6,
                gapCheckEnabled: true,
                pool: address(0),
                twapWindow: 60,
                reservedClaimableUsdc: 0,
                totalRedeemShares: 0,
                currentRedeemEpoch: 0,
                settlingEpoch: 0,
                settlingRemainingShares: 0
            })
        );

        vm.prank(admin);
        registry.replaceVault(MARKET, address(vault2), address(distributor2));

        assertEq(registry.vaultOf(MARKET), address(vault2));
        assertEq(registry.marketIdOfVault(address(vault)), bytes32(0));
        assertFalse(registry.isRYieldVault(address(vault)));
        assertTrue(registry.isRYieldVault(address(vault2)));
        assertEq(registry.totalVaults(), 1);
        assertEq(registry.totalAssetsUsdc(MARKET), 2_000e6);
    }

    function test_replaceVault_revertsWhenSameVault() public {
        vm.prank(admin);
        registry.register(MARKET, address(vault), address(distributor));

        vm.prank(admin);
        vm.expectRevert(RYieldRegistry.VaultUnchanged.selector);
        registry.replaceVault(MARKET, address(vault), address(distributor));
    }

    function test_replaceVault_revertsWhenNotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(RYieldRegistry.NotRegistered.selector);
        registry.replaceVault(MARKET, address(vault), address(distributor));
    }
}
