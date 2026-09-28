// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "../../contracts/VaultFactory.sol";
import {PositionVault} from "../../contracts/PositionVault.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {IPriceOracle} from "../../contracts/interfaces/IPriceOracle.sol";
import {RiskParams, GmxInfra} from "../../contracts/types/Types.sol";

contract MockOracle is IPriceOracle {
    function getPrice() external pure returns (uint256) {
        return 3000e8;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @dev ILpZap 최소 목(mock) — notifyReward 호출·수신 USDC만 기록. 실제 accRewardPerLiquidity
///      회계는 LpZap.t.sol에서 별도로 검증한다. 여기선 VaultFactory → LpZap 라우팅 표면만 본다.
contract MockLpZap {
    bytes32 public lastMarketId;
    uint256 public lastAmount;
    uint256 public callCount;
    bool public shouldRevert;

    function notifyReward(bytes32 marketId, uint256 amount) external {
        if (shouldRevert) revert("mock revert");
        lastMarketId = marketId;
        lastAmount = amount;
        callCount += 1;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }
}

/// @notice borrow fee → 마켓 rToken/USDC 풀 LpZap 라우팅 (VaultFactory 표면, 라운드 없음).
contract VaultFactoryLpIncentiveTest is Test {
    VaultFactory internal factory;
    MockUSDC internal usdc;
    MockOracle internal oracle;
    MockLpZap internal lpZap;
    bytes32 internal marketId;
    address internal pool = address(0xF00D);
    address internal vault;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockOracle();
        lpZap = new MockLpZap();
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
        factory.setMarketPool(marketId, pool);

        vault = factory.createVault(marketId, false, address(0xBEEF));
    }

    function test_defaults_borrowFeeToLpBpsIs100pct() public view {
        assertEq(factory.borrowFeeToLpBps(), 10_000);
    }

    function test_setMarketPool_registersPoolToMarketId() public view {
        assertEq(factory.poolToMarketId(pool), marketId);
    }

    function test_setMarketPool_revertsWhenPoolAlreadyRegisteredToOtherMarket() public {
        bytes32 marketId2 = keccak256("rBTC");
        factory.addMarket(
            marketId2,
            oracle,
            address(0),
            "RYex BTC",
            "rBTC",
            RiskParams({maxLtv1xBps: 6_500, bufferBps: 1_000, maxLtvAtMaxLevBps: 4_500, flatTier: 3, maxLeverage: 10}),
            150
        );
        // pool은 이미 marketId(rETH)에 등록돼 있음(setUp) — 다른 마켓(rBTC)에 재등록 시도하면 막혀야 한다.
        vm.expectRevert(VaultFactory.PoolAlreadyRegistered.selector);
        factory.setMarketPool(marketId2, pool);
    }

    function test_setMarketPool_allowsReassigningSameMarketToNewPool() public {
        address newPool = address(0xC0FFEE);
        factory.setMarketPool(marketId, newPool);
        assertEq(factory.poolToMarketId(newPool), marketId);
        assertEq(factory.poolToMarketId(pool), bytes32(0), "old pool mapping cleared");
    }

    function test_setMarketPool_allowsSettingSamePoolAgainForSameMarket() public {
        // old == pool_ 이면 조기 return 이라 self-reassign은 항상 허용돼야 한다(가드가 자기 자신도 막으면 회귀).
        factory.setMarketPool(marketId, pool);
        assertEq(factory.poolToMarketId(pool), marketId);
    }

    function test_notifyBorrowFeeEarned_onlyVault() public {
        vm.expectRevert(VaultFactory.NoMarket.selector);
        factory.notifyBorrowFeeEarned(marketId, 100e6);
    }

    function _earmark(uint256 amount) internal {
        usdc.mint(vault, amount);
        vm.prank(vault);
        usdc.transfer(address(factory), amount);
        vm.prank(vault);
        factory.notifyBorrowFeeEarned(marketId, amount);
    }

    function test_notifyBorrowFeeEarned_noLpZap_queuesInPendingBucket() public {
        _earmark(100e6);
        assertEq(factory.pendingLpIncentiveUsdc(marketId), 100e6, "queued, no lpZap yet");
        assertEq(factory.totalLpIncentiveUsdc(marketId), 100e6);
    }

    function test_notifyBorrowFeeEarned_withLpZap_forwardsImmediately() public {
        factory.setLpZap(address(lpZap));
        _earmark(100e6);

        assertEq(factory.pendingLpIncentiveUsdc(marketId), 0, "nothing queued -- forwarded immediately");
        assertEq(factory.totalLpIncentiveUsdc(marketId), 100e6, "lifetime counter still tracks");
        assertEq(usdc.balanceOf(address(lpZap)), 100e6, "lpZap received USDC");
        assertEq(lpZap.lastMarketId(), marketId);
        assertEq(lpZap.lastAmount(), 100e6);
        assertEq(lpZap.callCount(), 1);
    }

    function test_notifyBorrowFeeEarned_lpZapRevert_neverBubblesUp() public {
        factory.setLpZap(address(lpZap));
        lpZap.setShouldRevert(true);
        // USDC가 이미 factory→lpZap로 전송된 뒤 notifyReward가 revert해도(soft-fail try/catch)
        // vault의 close/liquidate 정산 호출인 notifyBorrowFeeEarned 자체는 절대 revert하지 않는다.
        _earmark(100e6);
        assertEq(usdc.balanceOf(address(lpZap)), 100e6, "USDC still forwarded despite notifyReward revert");
        assertEq(lpZap.callCount(), 0, "revert path never committed state in mock");
    }

    function test_flushPendingLpIncentive_movesQueuedBucketToLpZap() public {
        _earmark(300e6); // lpZap 아직 미설정 — 대기
        assertEq(factory.pendingLpIncentiveUsdc(marketId), 300e6);

        factory.setLpZap(address(lpZap));
        uint256 amount = factory.flushPendingLpIncentive(marketId);

        assertEq(amount, 300e6);
        assertEq(factory.pendingLpIncentiveUsdc(marketId), 0);
        assertEq(usdc.balanceOf(address(lpZap)), 300e6);
        assertEq(lpZap.lastAmount(), 300e6);
    }

    function test_flushPendingLpIncentive_revertsWithoutLpZap() public {
        vm.expectRevert(VaultFactory.LpZapNotSet.selector);
        factory.flushPendingLpIncentive(marketId);
    }

    function test_flushPendingLpIncentive_noopWhenBucketEmpty() public {
        factory.setLpZap(address(lpZap));
        uint256 amount = factory.flushPendingLpIncentive(marketId);
        assertEq(amount, 0);
        assertEq(lpZap.callCount(), 0);
    }

    /// @dev ILpZap.notifyReward는 반환값 없는 외부호출이라 EOA/코드없는 주소로 잘못 설정돼도 revert 없이
    ///      조용히 "성공"해버린다(Solidity가 extcodesize 체크를 안 함) — 그러면 _forwardToLpZap의
    ///      safeTransfer로 실USDC가 그 주소에 영구 유실. set 시점에 code.length로 반드시 걸러야 한다.
    function test_setLpZap_revertsForNonContractAddress() public {
        vm.expectRevert(VaultFactory.LpZapNotContract.selector);
        factory.setLpZap(address(0xDEAD));
    }

    function test_setLpZap_revertsForZeroAddress() public {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setLpZap(address(0));
    }

    /// @dev marketId==0은 LpZap.poolToMarketId의 "미등록 풀" 센티널과 겹쳐 그 마켓의 LP 예치가 전부
    ///      UnknownPool로 오탐하게 된다 — addMarket 시점에 막는다.
    function test_addMarket_revertsForZeroMarketId() public {
        vm.expectRevert(VaultFactory.ZeroMarketId.selector);
        factory.addMarket(
            bytes32(0),
            oracle,
            address(0),
            "Bad",
            "BAD",
            RiskParams({maxLtv1xBps: 8_000, bufferBps: 1_000, maxLtvAtMaxLevBps: 4_500, flatTier: 3, maxLeverage: 10}),
            150
        );
    }

    function test_setBorrowFeeToLpBps_ownerOnlyAndCapped() public {
        vm.expectRevert(VaultFactory.BadRiskParams.selector);
        factory.setBorrowFeeToLpBps(10_001);

        factory.setBorrowFeeToLpBps(5_000);
        assertEq(factory.borrowFeeToLpBps(), 5_000);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        factory.setBorrowFeeToLpBps(0);
    }
}
