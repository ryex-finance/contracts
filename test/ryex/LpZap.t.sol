// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultFactory} from "../../contracts/VaultFactory.sol";
import {PositionVault} from "../../contracts/PositionVault.sol";
import {LpZap} from "../../contracts/LpZap.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {IPriceOracle} from "../../contracts/interfaces/IPriceOracle.sol";
import {INonfungiblePositionManager} from "../../contracts/v3/interfaces/INonfungiblePositionManager.sol";
import {RiskParams, GmxInfra} from "../../contracts/types/Types.sol";

contract MockOracle is IPriceOracle {
    function getPrice() external pure returns (uint256) {
        return 3000e8;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @dev getPool만 필요한 UniV3Factory 최소 목.
contract MockUniFactory {
    mapping(bytes32 => address) internal _pools;

    function setPool(address token0, address token1, uint24 fee, address pool) external {
        _pools[keccak256(abi.encode(token0, token1, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[keccak256(abi.encode(tokenA, tokenB, fee))];
    }
}

/// @dev INonfungiblePositionManager 최소 목 — LpZap이 쓰는 함수만 구현. 실제 토큰 이동은 흉내만 낸다
///      (금액 검증이 아니라 LpZap 자체의 accRewardPerLiquidity/liquidity 회계를 검증하는 게 목적).
contract MockNpm {
    using SafeERC20 for IERC20;

    struct Pos {
        address owner;
        address token0;
        address token1;
        uint24 fee;
        uint128 liquidity;
    }

    mapping(uint256 => Pos) public pos;
    address public uniFactory;
    uint256 public nextTokenId = 100;
    /// @dev 0이면 amountDesired 전량 소비(기본), >0이면 그 값을 그대로 소비량으로 반환해 dust 환불 테스트.
    uint256 public forcedAmount0;
    uint256 public forcedAmount1;

    constructor(address uniFactory_) {
        uniFactory = uniFactory_;
    }

    function setForcedMintAmounts(uint256 a0, uint256 a1) external {
        forcedAmount0 = a0;
        forcedAmount1 = a1;
    }

    function factory() external view returns (address) {
        return uniFactory;
    }

    /// @dev 실제 NPM처럼 실제 소비량(amount0/1, desired 이하)만 caller(=LpZap, approve 받아둔 상태)로부터
    ///      transferFrom으로 당겨온다 — 그래야 LpZap이 되돌려주는 dust 환불량(desired-소비량)이 실제로
    ///      LpZap 잔고에 정확히 남아 있는지까지 검증할 수 있다(단순 fake 반환값이면 dust 회계가 안 맞음).
    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = nextTokenId++;
        amount0 = forcedAmount0 > 0 ? forcedAmount0 : params.amount0Desired;
        amount1 = forcedAmount1 > 0 ? forcedAmount1 : params.amount1Desired;
        liquidity = uint128(amount0 + amount1);
        if (amount0 > 0) IERC20(params.token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(params.token1).safeTransferFrom(msg.sender, address(this), amount1);
        pos[tokenId] =
            Pos({owner: params.recipient, token0: params.token0, token1: params.token1, fee: params.fee, liquidity: liquidity});
    }

    function mintPosition(uint256 tokenId, address owner_, address token0, address token1, uint24 fee, uint128 liquidity)
        external
    {
        pos[tokenId] = Pos({owner: owner_, token0: token0, token1: token1, fee: fee, liquidity: liquidity});
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return pos[tokenId].owner;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(pos[tokenId].owner == from, "not owner");
        pos[tokenId].owner = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(pos[tokenId].owner == from, "not owner");
        pos[tokenId].owner = to;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Pos memory p = pos[tokenId];
        return (0, address(0), p.token0, p.token1, p.fee, 0, 0, p.liquidity, 0, 0, 0, 0);
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Pos storage p = pos[params.tokenId];
        require(params.liquidity <= p.liquidity, "too much");
        p.liquidity -= params.liquidity;
        amount0 = uint256(params.liquidity) * 2; // 결정적 fake 반환값(경제적 의미 없음, 회계 검증용)
        amount1 = uint256(params.liquidity) * 3;
    }

    /// @dev mint()와 동일한 패턴 — 실제 소비량(amount0/1)만 caller(=LpZap)로부터 당겨오고, 기존
    ///      liquidity에 더한다. forcedAmount0/1로 dust 환불 테스트도 mint와 동일하게 재사용 가능.
    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Pos storage p = pos[params.tokenId];
        amount0 = forcedAmount0 > 0 ? forcedAmount0 : params.amount0Desired;
        amount1 = forcedAmount1 > 0 ? forcedAmount1 : params.amount1Desired;
        liquidity = uint128(amount0 + amount1);
        if (amount0 > 0) IERC20(p.token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(p.token1).safeTransferFrom(msg.sender, address(this), amount1);
        p.liquidity += liquidity;
    }

    function collect(INonfungiblePositionManager.CollectParams calldata) external pure returns (uint256, uint256) {
        return (7, 11); // 고정 fake 스왑피 반환값
    }
}

/// @notice LpZap — 라운드 없는 accRewardPerLiquidity 연속 분배 회계 검증.
contract LpZapTest is Test {
    VaultFactory internal factory;
    MockUSDC internal usdc;
    MockOracle internal oracle;
    MockUniFactory internal uniFactory;
    MockNpm internal npm;
    LpZap internal zap;

    bytes32 internal marketId;
    address internal pool = address(0xF00D);
    address internal token0 = address(0x1111);
    address internal token1 = address(0x2222);
    uint24 internal constant FEE = 3000;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockOracle();
        uniFactory = new MockUniFactory();
        npm = new MockNpm(address(uniFactory));

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
        uniFactory.setPool(token0, token1, FEE, pool);

        zap = new LpZap(address(factory), address(npm), address(usdc));
        factory.setLpZap(address(zap));

        feeVault = factory.createVault(marketId, false, address(this));
    }

    address internal feeVault;

    function _mintAndDeposit(uint256 tokenId, address owner_, uint128 liquidity) internal {
        npm.mintPosition(tokenId, owner_, token0, token1, FEE, liquidity);
        vm.prank(owner_);
        zap.deposit(tokenId);
        vm.roll(block.number + 1); // TooSoon(같은 블록 claim/withdraw 금지) 가드 회피 — 정상 플로우 시뮬레이션
    }

    function _notify(uint256 amount) internal {
        usdc.mint(feeVault, amount);
        vm.prank(feeVault);
        usdc.transfer(address(factory), amount);
        vm.prank(feeVault);
        factory.notifyBorrowFeeEarned(marketId, amount);
    }

    function test_deposit_recordsPositionAndTotalStaked() public {
        _mintAndDeposit(1, alice, 1_000);

        (address owner_, bytes32 mId, uint128 liq, uint256 debt) = zap.positions(1);
        assertEq(owner_, alice);
        assertEq(mId, marketId);
        assertEq(liq, 1_000);
        assertEq(debt, 0);
        assertEq(zap.totalStakedLiquidity(marketId), 1_000);
        assertEq(npm.ownerOf(1), address(zap), "NFT custody moved to LpZap");
    }

    function test_deposit_unknownPoolReverts() public {
        npm.mintPosition(2, alice, address(0x3333), address(0x4444), FEE, 1_000);
        vm.prank(alice);
        vm.expectRevert(LpZap.UnknownPool.selector);
        zap.deposit(2);
    }

    function test_soleStaker_getsFullRewardShare() public {
        _mintAndDeposit(1, alice, 1_000);
        _notify(100e6);

        assertEq(zap.pendingBonus(1), 100e6, "sole staker gets 100% of reward");
    }

    function test_claim_paysOutBonusAndCollectsSwapFees() public {
        _mintAndDeposit(1, alice, 1_000);
        _notify(100e6);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 bonus, uint256 fee0, uint256 fee1) = zap.claim(1);

        assertEq(bonus, 100e6);
        assertEq(fee0, 7);
        assertEq(fee1, 11);
        assertEq(usdc.balanceOf(alice) - balBefore, 100e6);
        assertEq(zap.pendingBonus(1), 0, "settled after claim");
    }

    function test_claim_notOwnerReverts() public {
        _mintAndDeposit(1, alice, 1_000);
        vm.prank(bob);
        vm.expectRevert(LpZap.NotOwner.selector);
        zap.claim(1);
    }

    function test_twoStakers_splitProportionally() public {
        _mintAndDeposit(1, alice, 1_000); // 25%
        _mintAndDeposit(2, bob, 3_000); // 75%
        _notify(400e6);

        assertEq(zap.pendingBonus(1), 100e6, "alice 25% of 400");
        assertEq(zap.pendingBonus(2), 300e6, "bob 75% of 400");
    }

    function test_lateStaker_doesNotRetroactivelyEarnPastReward() public {
        _mintAndDeposit(1, alice, 1_000);
        _notify(100e6); // alice만 있을 때 적립

        _mintAndDeposit(2, bob, 1_000); // 이제 합류 — 과거분엔 지분 없음
        assertEq(zap.pendingBonus(2), 0, "bob joined after the reward, gets none of the past round");
        assertEq(zap.pendingBonus(1), 100e6, "alice keeps her full past accrual");

        _notify(200e6); // 이제 50:50
        assertEq(zap.pendingBonus(1), 100e6 + 100e6);
        assertEq(zap.pendingBonus(2), 100e6);
    }

    function test_notifyReward_queuesWhenNoStakerYet_thenFlushesOnNextNotify() public {
        // 아무도 스테이킹 안 한 상태에서 보상 도착 — pendingReward에 대기.
        _notify(50e6);
        assertEq(zap.pendingReward(marketId), 50e6);

        _mintAndDeposit(1, alice, 1_000);
        assertEq(zap.pendingBonus(1), 0, unicode"deposit 시점엔 아직 flush 안 됨");

        // 다음 notifyReward에서 대기분+신규분이 함께 flush.
        _notify(50e6);
        assertEq(zap.pendingReward(marketId), 0);
        assertEq(zap.pendingBonus(1), 100e6, "queued 50 + new 50, sole staker gets all");
    }

    function test_notifyReward_onlyFactory() public {
        vm.expectRevert(LpZap.NotFactory.selector);
        zap.notifyReward(marketId, 100e6);
    }

    function test_withdraw_partial_keepsPositionAndNftCustody() public {
        _mintAndDeposit(1, alice, 1_000);
        _notify(100e6);

        vm.prank(alice);
        (uint256 bonus, uint256 amount0, uint256 amount1) = zap.withdraw(1, 400, 0, 0);

        assertEq(bonus, 100e6, "pending settled on partial withdraw too");
        // amount0/1은 decreaseLiquidity가 아니라 그 뒤 collect()의 반환값(실제 recipient로 이동하는 양) —
        // 실제 NPM도 decreaseLiquidity는 tokensOwed만 늘리고, collect가 최종 이체량을 반환한다.
        assertEq(amount0, 7); // MockNpm.collect() 고정 fake 반환값
        assertEq(amount1, 11);
        assertEq(zap.totalStakedLiquidity(marketId), 600);
        (, , uint128 liqLeft,) = zap.positions(1);
        assertEq(liqLeft, 600);
        assertEq(npm.ownerOf(1), address(zap), "NFT stays custodied -- position not fully closed");
    }

    function test_withdraw_full_returnsNftAndClearsPosition() public {
        _mintAndDeposit(1, alice, 1_000);

        vm.prank(alice);
        zap.withdraw(1, 1_000, 0, 0);

        assertEq(zap.totalStakedLiquidity(marketId), 0);
        (address owner_,,,) = zap.positions(1);
        assertEq(owner_, address(0), "position deleted");
        assertEq(npm.ownerOf(1), alice, "NFT returned to owner");
    }

    function test_withdraw_tooMuchLiquidityReverts() public {
        _mintAndDeposit(1, alice, 1_000);
        vm.prank(alice);
        vm.expectRevert(LpZap.BadAmount.selector);
        zap.withdraw(1, 1_001, 0, 0);
    }

    function test_withdraw_notOwnerReverts() public {
        _mintAndDeposit(1, alice, 1_000);
        vm.prank(bob);
        vm.expectRevert(LpZap.NotOwner.selector);
        zap.withdraw(1, 500, 0, 0);
    }

    /// @dev anti-sniping 가드: deposit과 같은 block에서 claim/withdraw로 즉시 정산 시도 시 TooSoon.
    ///      (원자적 번들로 deposit+liquidate(보상 유발)+claim을 한 블록에 묶어 지분 없이 무임승차하는
    ///      스나이핑을 막는 최소 방어 — 정상 LP는 같은 블록에 예치+정산할 이유가 없어 전혀 걸리지 않는다.)
    function test_claim_sameBlockAsDepositReverts() public {
        npm.mintPosition(1, alice, token0, token1, FEE, 1_000);
        vm.prank(alice);
        zap.deposit(1);

        vm.prank(alice);
        vm.expectRevert(LpZap.TooSoon.selector);
        zap.claim(1);
    }

    function test_withdraw_sameBlockAsDepositReverts() public {
        npm.mintPosition(1, alice, token0, token1, FEE, 1_000);
        vm.prank(alice);
        zap.deposit(1);

        vm.prank(alice);
        vm.expectRevert(LpZap.TooSoon.selector);
        zap.withdraw(1, 500, 0, 0);
    }

    function test_claim_nextBlockAfterDepositSucceeds() public {
        npm.mintPosition(1, alice, token0, token1, FEE, 1_000);
        vm.prank(alice);
        zap.deposit(1);
        vm.roll(block.number + 1);

        vm.prank(alice);
        (uint256 bonus,,) = zap.claim(1);
        assertEq(bonus, 0, "no reward accrued yet, but call itself must succeed");
    }

    // ── mintAndDeposit: "addLiquidity → 자동 스테이킹" 1-tx 플로우 ──

    function _setUpMintAndDepositPool() internal returns (address t0, address t1, address mdPool) {
        MockUSDC a = new MockUSDC();
        MockUSDC b = new MockUSDC();
        (t0, t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        mdPool = address(0xBEEF);
        uniFactory.setPool(t0, t1, FEE, mdPool);
        factory.setMarketPool(marketId, mdPool);
        MockUSDC(t0).mint(alice, 1_000e6);
        MockUSDC(t1).mint(alice, 1_000e6);
    }

    function test_mintAndDeposit_createsPositionAndStakesWithoutTouchingUserWallet() public {
        (address t0, address t1,) = _setUpMintAndDepositPool();

        vm.startPrank(alice);
        IERC20(t0).approve(address(zap), 100e6);
        IERC20(t1).approve(address(zap), 200e6);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = zap.mintAndDeposit(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: -60,
                tickUpper: 60,
                amount0Desired: 100e6,
                amount1Desired: 200e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice, // LpZap이 무시하고 자기 자신으로 덮어써야 함 — 아래에서 검증
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertEq(amount0, 100e6);
        assertEq(amount1, 200e6);
        assertEq(npm.ownerOf(tokenId), address(zap), "NFT never passes through user wallet");
        (address owner_, bytes32 mId, uint128 liq,) = zap.positions(tokenId);
        assertEq(owner_, alice);
        assertEq(mId, marketId);
        assertEq(liq, liquidity);
        assertEq(zap.totalStakedLiquidity(marketId), liquidity);
        // 전량 소비했으니 alice 잔고는 정확히 amountDesired만큼만 줄어야 함(환불 없음)
        assertEq(IERC20(t0).balanceOf(alice), 1_000e6 - 100e6);
        assertEq(IERC20(t1).balanceOf(alice), 1_000e6 - 200e6);
    }

    function test_mintAndDeposit_refundsUnusedDust() public {
        (address t0, address t1,) = _setUpMintAndDepositPool();
        npm.setForcedMintAmounts(60e6, 150e6); // desired보다 적게 "소비"됐다고 강제 — 나머지는 dust

        vm.startPrank(alice);
        IERC20(t0).approve(address(zap), 100e6);
        IERC20(t1).approve(address(zap), 200e6);
        zap.mintAndDeposit(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: -60,
                tickUpper: 60,
                amount0Desired: 100e6,
                amount1Desired: 200e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        // 100 desired - 60 consumed = 40 환불, 200 desired - 150 consumed = 50 환불
        assertEq(IERC20(t0).balanceOf(alice), 1_000e6 - 60e6, "unused amount0 dust refunded");
        assertEq(IERC20(t1).balanceOf(alice), 1_000e6 - 150e6, "unused amount1 dust refunded");
        assertEq(IERC20(t0).balanceOf(address(zap)), 0, "no dust stuck in LpZap");
        assertEq(IERC20(t1).balanceOf(address(zap)), 0, "no dust stuck in LpZap");
    }

    function test_mintAndDeposit_unknownPoolReverts() public {
        MockUSDC a = new MockUSDC();
        MockUSDC b = new MockUSDC();
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        // uniFactory.setPool / factory.setMarketPool 둘 다 안 함 — poolToMarketId 미등록
        MockUSDC(t0).mint(alice, 100e6);
        MockUSDC(t1).mint(alice, 100e6);

        vm.startPrank(alice);
        IERC20(t0).approve(address(zap), 100e6);
        IERC20(t1).approve(address(zap), 100e6);
        vm.expectRevert(LpZap.UnknownPool.selector);
        zap.mintAndDeposit(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: -60,
                tickUpper: 60,
                amount0Desired: 100e6,
                amount1Desired: 100e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function test_mintAndDeposit_claimNextBlockPaysBonus() public {
        (address t0, address t1,) = _setUpMintAndDepositPool();

        vm.startPrank(alice);
        IERC20(t0).approve(address(zap), 100e6);
        IERC20(t1).approve(address(zap), 100e6);
        // 100e6+100e6=200e6 liquidity로 딱 나누어떨어지게(라운딩 없이) 골라 순수 회계만 검증.
        (uint256 tokenId,,,) = zap.mintAndDeposit(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: -60,
                tickUpper: 60,
                amount0Desired: 100e6,
                amount1Desired: 100e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        vm.roll(block.number + 1); // TooSoon 가드 회피
        _notify(50e6);

        vm.prank(alice);
        (uint256 bonus,,) = zap.claim(tokenId);
        assertEq(bonus, 50e6, "sole staker via mintAndDeposit gets full reward");
    }

    // ── increaseLiquidity: 스테이킹 유지한 채 유동성 추가(top-up) ──
    // deposit()/withdraw() 계열 테스트는 token0/token1이 회계 검증용 fake 주소(0x1111/0x2222)라 실제
    // ERC20이 아니다 — increaseLiquidity는 실제로 token0/token1.safeTransferFrom을 호출하므로 반드시
    // _setUpMintAndDepositPool()(진짜 MockUSDC 페어)로 만든 포지션 위에서 테스트한다.

    /// @dev via-ir + optimizer_runs=1에서도 stack-too-deep을 피하려고 "풀 세팅"과 "mintAndDeposit 실행"을
    ///      완전히 분리했다(한 함수에 파라미터+MintParams 필드+반환값이 몰리면 Yul 임시변수가 넘친다).
    function _depositViaMintAndDeposit(address t0, address t1, address owner_, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId)
    {
        vm.startPrank(owner_);
        IERC20(t0).approve(address(zap), amount0);
        IERC20(t1).approve(address(zap), amount1);
        tokenId = _doMintAndDeposit(t0, t1, owner_, amount0, amount1);
        vm.stopPrank();
        vm.roll(block.number + 1); // TooSoon 가드 회피
    }

    function _doMintAndDeposit(address t0, address t1, address owner_, uint256 amount0, uint256 amount1)
        private
        returns (uint256 tokenId)
    {
        (tokenId,,,) = zap.mintAndDeposit(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: -60,
                tickUpper: 60,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: owner_,
                deadline: block.timestamp
            })
        );
    }

    function _mintViaZap(address owner_, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId, address t0, address t1)
    {
        (t0, t1,) = _setUpMintAndDepositPool();
        tokenId = _depositViaMintAndDeposit(t0, t1, owner_, amount0, amount1);
    }

    function test_increaseLiquidity_addsLiquidityAndKeepsStaking() public {
        (uint256 tokenId, address t0, address t1) = _mintViaZap(alice, 100e6, 100e6); // liquidity = 200e6
        (, , uint128 liqBefore,) = zap.positions(tokenId);

        MockUSDC(t0).mint(alice, 50e6);
        MockUSDC(t1).mint(alice, 50e6);
        vm.startPrank(alice);
        IERC20(t0).approve(address(zap), 50e6);
        IERC20(t1).approve(address(zap), 50e6);
        (uint256 bonus, uint128 liquidityAdded, uint256 amount0, uint256 amount1) =
            zap.increaseLiquidity(tokenId, 50e6, 50e6, 0, 0);
        vm.stopPrank();

        assertEq(bonus, 0, "no reward accrued yet");
        assertEq(amount0, 50e6);
        assertEq(amount1, 50e6);
        assertEq(liquidityAdded, 100e6);
        (, , uint128 liqAfter,) = zap.positions(tokenId);
        assertEq(liqAfter, liqBefore + 100e6, "position liquidity increased");
        assertEq(zap.totalStakedLiquidity(marketId), liqAfter);
        assertEq(npm.ownerOf(tokenId), address(zap), "NFT stays custodied throughout top-up");
    }

    function test_increaseLiquidity_settlesExistingBonusAtOldLiquidityFirst() public {
        (uint256 tokenId, address t0, address t1) = _mintViaZap(alice, 100e6, 100e6); // sole staker, 200e6 liquidity
        _notify(100e6); // 100e6 pending @ 200e6 liquidity

        MockUSDC(t0).mint(alice, 100e6);
        MockUSDC(t1).mint(alice, 100e6);
        vm.startPrank(alice);
        IERC20(t0).approve(address(zap), 100e6);
        IERC20(t1).approve(address(zap), 100e6);
        uint256 balBefore = usdc.balanceOf(alice);
        (uint256 bonus,,,) = zap.increaseLiquidity(tokenId, 100e6, 100e6, 0, 0);
        vm.stopPrank();

        // 증가분(200e6)이 반영되기 전, 기존 liquidity 기준으로 전액 정산돼야 함 — 희석 없음.
        assertEq(bonus, 100e6, "settled at old liquidity, not diluted by the new top-up");
        assertEq(usdc.balanceOf(alice) - balBefore, 100e6);
        assertEq(zap.pendingBonus(tokenId), 0, "settled after increaseLiquidity");
    }

    function test_increaseLiquidity_doesNotDiluteOtherStakers() public {
        (uint256 tokenId, address t0, address t1) = _mintViaZap(alice, 100e6, 100e6); // alice: 200e6
        npm.mintPosition(999, bob, t0, t1, FEE, 200e6); // bob: 200e6, 50:50
        vm.prank(bob);
        zap.deposit(999);
        vm.roll(block.number + 1);

        MockUSDC(t0).mint(alice, 200e6);
        MockUSDC(t1).mint(alice, 200e6);
        vm.startPrank(alice);
        IERC20(t0).approve(address(zap), 200e6);
        IERC20(t1).approve(address(zap), 200e6);
        zap.increaseLiquidity(tokenId, 200e6, 200e6, 0, 0); // alice: 200e6 → 600e6
        vm.stopPrank();

        _notify(400e6); // 총 liquidity 600e6(alice) + 200e6(bob) = 800e6
        assertEq(zap.pendingBonus(tokenId), 300e6, "alice now 75% (600/800)");
        assertEq(zap.pendingBonus(999), 100e6, "bob's absolute share unaffected by alice's top-up");
    }

    function test_increaseLiquidity_refundsUnusedDust() public {
        (uint256 tokenId, address t0, address t1) = _mintViaZap(alice, 100e6, 100e6);
        npm.setForcedMintAmounts(60e6, 150e6); // desired보다 적게 소비됐다고 강제

        MockUSDC(t0).mint(alice, 100e6);
        MockUSDC(t1).mint(alice, 200e6);
        uint256 balT0Before = IERC20(t0).balanceOf(alice);
        uint256 balT1Before = IERC20(t1).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(t0).approve(address(zap), 100e6);
        IERC20(t1).approve(address(zap), 200e6);
        zap.increaseLiquidity(tokenId, 100e6, 200e6, 0, 0);
        vm.stopPrank();

        // desired 100e6/200e6 중 실제로는 60e6/150e6만 소비됐으니(forced), 잔고는 딱 소비분만큼만 줄어야 함
        // (desired - 소비량 = dust는 같은 tx에서 즉시 환불되므로 순변화량 = -소비량).
        assertEq(IERC20(t0).balanceOf(alice), balT0Before - 60e6, "unused amount0 dust refunded");
        assertEq(IERC20(t1).balanceOf(alice), balT1Before - 150e6, "unused amount1 dust refunded");
        assertEq(IERC20(t0).balanceOf(address(zap)), 0, "no dust stuck in LpZap");
        assertEq(IERC20(t1).balanceOf(address(zap)), 0, "no dust stuck in LpZap");
    }

    function test_increaseLiquidity_notOwnerReverts() public {
        (uint256 tokenId,,) = _mintViaZap(alice, 100e6, 100e6);
        vm.prank(bob);
        vm.expectRevert(LpZap.NotOwner.selector);
        zap.increaseLiquidity(tokenId, 100, 100, 0, 0);
    }

    function test_increaseLiquidity_sameBlockAsDepositReverts() public {
        (address t0, address t1,) = _setUpMintAndDepositPool();
        vm.startPrank(alice);
        IERC20(t0).approve(address(zap), 100e6);
        IERC20(t1).approve(address(zap), 100e6);
        (uint256 tokenId,,,) = zap.mintAndDeposit(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: -60,
                tickUpper: 60,
                amount0Desired: 100e6,
                amount1Desired: 100e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            })
        );
        // 같은 block, approve 없이도 TooSoon이 먼저 걸려야 함(가드 순서 확인용으로 approve는 생략).
        vm.expectRevert(LpZap.TooSoon.selector);
        zap.increaseLiquidity(tokenId, 0, 0, 0, 0);
        vm.stopPrank();
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(LpZap.ZeroAddress.selector);
        new LpZap(address(0), address(npm), address(usdc));

        vm.expectRevert(LpZap.ZeroAddress.selector);
        new LpZap(address(factory), address(0), address(usdc));

        vm.expectRevert(LpZap.ZeroAddress.selector);
        new LpZap(address(factory), address(npm), address(0));
    }
}
