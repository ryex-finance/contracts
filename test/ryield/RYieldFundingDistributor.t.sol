// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RYieldFundingDistributor} from "../../contracts/RYieldFundingDistributor.sol";
import {IRYieldVaultShares} from "../../contracts/interfaces/IRYieldVaultShares.sol";

contract MockRewardToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev vault 대역: funding 배분에 필요한 share 회계만 흉내. harvestFunding은 no-op(테스트가 직접 notify).
interface INotify {
    function notifyHarvest(address token, uint256 amount) external;
}

contract MockShareVault is IRYieldVaultShares {
    uint256 public totalShares;
    mapping(address => uint256) public fundingSharesOf;
    bool public harvestReverts;
    bool public settleSubmitted;
    bool public settlePending;

    function setSettleSubmitted(bool on) external {
        settleSubmitted = on;
    }

    function setSettlePending(bool on) external {
        settlePending = on;
    }

    function requestAccruedFundingSettle() external returns (bool submitted) {
        return settleSubmitted;
    }

    function fundingSettlePending() external view returns (bool) {
        return settlePending;
    }

    function vaultAccruedFundingGmx() external pure returns (uint256 longAmount, uint256 shortAmount) {
        return (0, 0);
    }

    // GMX pending 모사: harvestFunding 호출 시 이 수량을 distributor로 옮기고(mint) notify.
    address public distributor;
    MockRewardToken public longTk;
    MockRewardToken public shortTk;
    uint256 public pendingLong;
    uint256 public pendingShort;

    function setShares(address user, uint256 shares) external {
        totalShares = totalShares - fundingSharesOf[user] + shares;
        fundingSharesOf[user] = shares;
    }

    function setHarvestReverts(bool on) external {
        harvestReverts = on;
    }

    function wire(address dist, MockRewardToken l, MockRewardToken s) external {
        distributor = dist;
        longTk = l;
        shortTk = s;
    }

    function setPendingGmx(uint256 l, uint256 s) external {
        pendingLong = l;
        pendingShort = s;
    }

    // 실제 vault.harvestFunding 모사: GMX pending을 distributor로 수거하고 rewardPerShare 갱신.
    // harvestReverts=true면 GMX 장애를 모사해 revert (harvestAndClaim best-effort 검증용).
    function harvestFunding() external {
        require(!harvestReverts, "gmx down");
        if (pendingLong > 0) {
            longTk.mint(distributor, pendingLong);
            INotify(distributor).notifyHarvest(address(longTk), pendingLong);
            pendingLong = 0;
        }
        if (pendingShort > 0) {
            shortTk.mint(distributor, pendingShort);
            INotify(distributor).notifyHarvest(address(shortTk), pendingShort);
            pendingShort = 0;
        }
    }
}

/// @notice FundingDistributor MultiRewards 회계 + anti-dilution 단위 검증 (GMX 불필요).
contract RYieldFundingDistributorTest is Test {
    MockShareVault vault;
    MockRewardToken longTk; // e.g. WETH
    MockRewardToken shortTk; // e.g. USDC
    RYieldFundingDistributor dist;

    address alice = address(0xA11CE);
    address whale = address(0xB0B);

    function setUp() public {
        vault = new MockShareVault();
        longTk = new MockRewardToken("WETH");
        shortTk = new MockRewardToken("USDC");
        // dataStore/gmxMarket는 core 회계 테스트에서 미사용 → 더미 non-zero 주소.
        dist = new RYieldFundingDistributor(
            address(vault), address(0xdead), address(0xbeef), address(longTk), address(shortTk)
        );
        vault.wire(address(dist), longTk, shortTk);
    }

    // 봇의 harvest 시뮬: GMX가 토큰을 distributor로 보낸 뒤 vault가 notifyHarvest 호출.
    function _harvest(address token, uint256 amount) internal {
        MockRewardToken(token).mint(address(dist), amount);
        vm.prank(address(vault));
        dist.notifyHarvest(token, amount);
    }

    // vault의 지분 변경 훅 순서 재현: accrue(before) → share 변경 → setDebt(after).
    function _setShares(address user, uint256 newShares) internal {
        vm.prank(address(vault));
        dist.accrueUser(user);
        vault.setShares(user, newShares);
        vm.prank(address(vault));
        dist.setUserDebt(user);
    }

    function test_singleUser_accruesAndClaimsBothTokens() public {
        _setShares(alice, 100e18);
        _harvest(address(longTk), 5e18);
        _harvest(address(shortTk), 200e6);

        (uint256 lc, uint256 sc) = dist.claimableRewards(alice);
        assertEq(lc, 5e18, "alice long");
        assertEq(sc, 200e6, "alice short");

        vm.prank(alice);
        (uint256 lg, uint256 sh) = dist.harvestAndClaim();
        assertEq(lg, 5e18);
        assertEq(sh, 200e6);
        assertEq(longTk.balanceOf(alice), 5e18);
        assertEq(shortTk.balanceOf(alice), 200e6);

        (uint256 lc2, uint256 sc2) = dist.claimableRewards(alice);
        assertEq(lc2, 0);
        assertEq(sc2, 0);
    }

    /// @notice 핵심: 이미 수령한 유저가 share를 계속 보유해도 다른 유저 몫을 반복 수령하지 못한다.
    function test_claimedUserCannotDrainOthers() public {
        _setShares(alice, 50e18);
        _setShares(whale, 50e18); // 총 100, 각 50%
        _harvest(address(shortTk), 100e6); // rewardPerShare += 1/share

        // alice 1차 수령: 자기 몫 50만.
        vm.prank(alice);
        (, uint256 s1) = dist.harvestAndClaim();
        assertEq(s1, 50e6, "alice gets only her 50%");
        assertEq(shortTk.balanceOf(alice), 50e6);

        // alice가 share를 그대로 든 채 다시 눌러도(신규 harvest 없음) 받을 게 없어 revert.
        vm.prank(alice);
        vm.expectRevert(RYieldFundingDistributor.NothingToClaim.selector);
        dist.harvestAndClaim();

        // whale 몫 50은 손상 없이 그대로 → 온전히 수령.
        (, uint256 whalePending) = dist.claimableRewards(whale);
        assertEq(whalePending, 50e6, "whale share untouched by alice's claims");
        vm.prank(whale);
        (, uint256 s2) = dist.harvestAndClaim();
        assertEq(s2, 50e6);
        assertEq(shortTk.balanceOf(whale), 50e6);
    }

    /// @notice 이미 수령한 뒤 '새 harvest'가 생기면, 그 신규분에 대해서만(share 비율) 추가 수령 가능.
    function test_claimedUserGetsOnlyNewHarvestAfterward() public {
        _setShares(alice, 50e18);
        _setShares(whale, 50e18);
        _harvest(address(shortTk), 100e6);

        vm.prank(alice);
        dist.harvestAndClaim(); // 50 수령, 체크포인트 전진

        _harvest(address(shortTk), 40e6); // 신규 harvest → alice 몫 20만

        (, uint256 pending) = dist.claimableRewards(alice);
        assertEq(pending, 20e6, "only new harvest share, not cumulative");
        vm.prank(alice);
        (, uint256 s) = dist.harvestAndClaim();
        assertEq(s, 20e6);
    }

    /// @notice 핵심: harvest(선수거)가 지분 변동 '전'에 일어나면, 뒤늦게 들어온 고래는 과거 보상을 못 가져간다.
    function test_antiDilution_lateWhaleCannotStealPastRewards() public {
        // 1) alice 100 share 보유 중, 과거 펀딩비 100 USDC가 수거(선수거)됨.
        _setShares(alice, 100e18);
        _harvest(address(shortTk), 100e6);

        // 2) 그 후 고래가 900 share로 진입 (vault가 지분 변경 시 accrue→setDebt 실행).
        _setShares(whale, 900e18);

        // 고래는 과거 100 USDC에 대해 0을 받아야 한다.
        (, uint256 whaleShort) = dist.claimableRewards(whale);
        assertEq(whaleShort, 0, "whale must not steal past rewards");

        // alice는 과거 100 USDC 전액 확보.
        (, uint256 aliceShort) = dist.claimableRewards(alice);
        assertEq(aliceShort, 100e6, "alice keeps all past rewards");

        // 3) 이후 새 펀딩비 200 USDC는 현재 지분비(100:900)로 분배.
        _harvest(address(shortTk), 200e6);
        (, uint256 aliceAfter) = dist.claimableRewards(alice);
        (, uint256 whaleAfter) = dist.claimableRewards(whale);
        assertEq(aliceAfter, 100e6 + 20e6, "alice 10% of new");
        assertEq(whaleAfter, 180e6, "whale 90% of new");
    }

    function test_notifyHarvest_revertsWhenNoShares() public {
        // 지분 0인데 amount>0면 배분 대상 없음 → revert(토큰 고립 방지).
        longTk.mint(address(dist), 1e18);
        vm.prank(address(vault));
        vm.expectRevert(RYieldFundingDistributor.NoSharesToAllocate.selector);
        dist.notifyHarvest(address(longTk), 1e18);
    }

    function test_onlyVault_guardsMutators() public {
        vm.expectRevert(RYieldFundingDistributor.NotVault.selector);
        dist.notifyHarvest(address(longTk), 1);
        vm.expectRevert(RYieldFundingDistributor.NotVault.selector);
        dist.accrueUser(alice);
        vm.expectRevert(RYieldFundingDistributor.NotVault.selector);
        dist.setUserDebt(alice);
    }

    function test_harvestAndClaim_isPermissionlessPerUser() public {
        _setShares(alice, 50e18);
        _harvest(address(longTk), 10e18);
        vm.prank(alice);
        dist.harvestAndClaim();
        assertEq(longTk.balanceOf(alice), 10e18);
    }

    // ── 통합 claim 버튼 (harvestAndClaim) 스펙 3케이스 ──────────────────────────────

    /// @dev 케이스 ①: GMX에 수령분 존재 → harvestAndClaim이 먼저 수거(→distributor)하고 호출자 share만큼 지급.
    function test_harvestAndClaim_case1_gmxHarvestThenPay() public {
        _setShares(alice, 100e18);
        vault.setPendingGmx(4e18, 250e6); // GMX에 미수령 펀딩비 대기
        vm.prank(alice);
        (uint256 l, uint256 s) = dist.harvestAndClaim();
        assertEq(l, 4e18, "long harvested+paid");
        assertEq(s, 250e6, "short harvested+paid");
        assertEq(longTk.balanceOf(alice), 4e18);
        assertEq(shortTk.balanceOf(alice), 250e6);
        // GMX pending 소진
        assertEq(vault.pendingLong(), 0);
    }

    /// @dev 케이스 ①+지분분할: GMX 수거분이 전 지분에 분배되고 호출자는 자기 share만 가져간다.
    function test_harvestAndClaim_case1_paysOnlyCallerShare() public {
        _setShares(alice, 100e18);
        _setShares(whale, 300e18); // 총 400, alice 25%
        vault.setPendingGmx(0, 400e6);
        vm.prank(alice);
        (, uint256 s) = dist.harvestAndClaim();
        assertEq(s, 100e6, "alice gets 25% of harvested");
        // 나머지 300 USDC는 whale 몫으로 distributor에 남아 있음
        (, uint256 whaleShort) = dist.claimableRewards(whale);
        assertEq(whaleShort, 300e6);
    }

    /// @dev 케이스 ②: GMX 수거분 없음이지만 distributor에 확정분 존재 → share만큼 지급.
    function test_harvestAndClaim_case2_distributorOnly() public {
        _setShares(alice, 100e18);
        _harvest(address(shortTk), 300e6); // 누군가 이미 글로벌 harvest 해둔 상태
        vm.prank(alice);
        (uint256 l, uint256 s) = dist.harvestAndClaim();
        assertEq(l, 0);
        assertEq(s, 300e6);
        assertEq(shortTk.balanceOf(alice), 300e6);
    }

    /// @dev 케이스 ③: GMX·distributor 모두 청구자 몫 0 → revert(NothingToClaim).
    function test_harvestAndClaim_case3_revertsWhenNothing() public {
        _setShares(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(RYieldFundingDistributor.NothingToClaim.selector);
        dist.harvestAndClaim();
    }

    /// @dev 이미 전부 청구한 뒤 다시 누르면(둘 다 0) revert.
    function test_harvestAndClaim_revertsAfterFullyClaimed() public {
        _setShares(alice, 100e18);
        _harvest(address(longTk), 5e18);
        vm.prank(alice);
        dist.harvestAndClaim(); // 5e18 수령
        vm.prank(alice);
        vm.expectRevert(RYieldFundingDistributor.NothingToClaim.selector);
        dist.harvestAndClaim(); // 남은 것 없음
    }

    /// @dev settle만 제출(1단계). claim과 분리.
    function test_settleAccruedFee_submits() public {
        vault.setSettleSubmitted(true);
        assertTrue(dist.settleAccruedFee());
    }

    function test_settleAccruedFee_noOpWhenNotSubmitted() public {
        assertFalse(dist.settleAccruedFee());
    }

    /// @dev harvest가 revert해도(GMX 장애 모사) distributor 잔액은 청구 가능해야 한다.
    function test_harvestAndClaim_bestEffortHarvest_stillClaimsDistributor() public {
        _setShares(alice, 100e18);
        _harvest(address(longTk), 7e18);
        vault.setHarvestReverts(true); // vault.harvestFunding()이 revert하도록
        vm.prank(alice);
        (uint256 l,) = dist.harvestAndClaim();
        assertEq(l, 7e18, "distributor balance still claimable despite GMX harvest failure");
    }
}
