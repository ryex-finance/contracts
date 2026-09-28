// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {ILpZap} from "./interfaces/ILpZap.sol";
import {INonfungiblePositionManager} from "./v3/interfaces/INonfungiblePositionManager.sol";

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @title LpZap — borrow fee LP 인센티브를 "라운드" 없이 연속 분배 (UniswapV3Staker 대체)
/// @notice UniswapV3Staker는 incentive를 (startTime, endTime) 라운드 단위로만 열 수 있어(이미 시작한
///         라운드엔 리워드를 추가 적립 불가) 매번 재스테이킹이 필요한 UX 문제가 있었다. LpZap은 그 대신
///         MasterChef류 accRewardPerLiquidity 누적기로 직접 회계한다 — 라운드/시작·종료시각이 전혀 없고,
///         VaultFactory.notifyBorrowFeeEarned가 호출되는 즉시(스테이킹된 LP가 있으면) 반영된다.
/// @dev 지분은 "예치된 liquidity 크기"만 본다(구간 안/밖 무관 — 구간 밖이면 어차피 UniV3 자체 스왑피를
///      못 받는 손해를 이미 지므로 단순화가 합리적, docs 참고). rToken/USDC 풀의 NFT 포지션(NPM tokenId)을
///      이 컨트랙트에 예치(deposit)하면 스테이킹, claim은 유지한 채 언제든, withdraw는 부분/전량 가능하며
///      전량 시 NFT를 자동 반환한다.
contract LpZap is ILpZap, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant PRECISION = 1e18;

    struct Position {
        address owner;
        bytes32 marketId;
        uint128 liquidity;
        uint256 rewardDebt; // 마지막 정산 시점의 accRewardPerLiquidity[marketId] 스냅샷
    }

    IVaultFactory public immutable factory;
    INonfungiblePositionManager public immutable npm;
    IERC20 public immutable usdc;

    mapping(uint256 => Position) public positions; // tokenId => Position
    mapping(bytes32 => uint256) public accRewardPerLiquidity; // marketId => acc (PRECISION 스케일)
    mapping(bytes32 => uint128) public totalStakedLiquidity; // marketId => 예치된 liquidity 합
    mapping(bytes32 => uint256) public pendingReward; // marketId => totalStaked==0일 때 대기 중인 리워드(6dec)
    mapping(uint256 => uint256) public depositedAtBlock; // tokenId => 예치 시점 block.number (same-block 스나이핑 방지)

    event Deposited(uint256 indexed tokenId, address indexed owner, bytes32 indexed marketId, uint128 liquidity);
    event Claimed(uint256 indexed tokenId, address indexed owner, uint256 bonus, uint256 fee0, uint256 fee1);
    event Withdrawn(
        uint256 indexed tokenId,
        address indexed owner,
        uint128 liquidityRemoved,
        uint256 bonus,
        uint256 amount0,
        uint256 amount1
    );
    event LiquidityIncreased(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 bonus,
        uint128 liquidityAdded,
        uint256 amount0,
        uint256 amount1
    );
    event RewardNotified(bytes32 indexed marketId, uint256 amount, bool queued);

    error NotOwner();
    error ZeroLiquidity();
    error BadAmount();
    error UnknownPool();
    error NotFactory();
    error ZeroAddress();
    error TooSoon();

    constructor(address factory_, address npm_, address usdc_) {
        if (factory_ == address(0) || npm_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        factory = IVaultFactory(factory_);
        npm = INonfungiblePositionManager(npm_);
        usdc = IERC20(usdc_);
    }

    /// @notice VaultFactory 전용 — borrow fee 도착분 통보. factory가 이 호출 직전에 usdc를 이미
    ///         이 컨트랙트로 전송했다는 전제(청산 earmark·기존 LP인센티브 버킷과 동일 패턴).
    /// @dev 절대 revert하지 않는다 — factory의 close/liquidate 정산 경로가 이 호출에 의존하면 안 됨.
    ///      스테이킹된 liquidity가 아직 없으면(totalStaked==0) pendingReward에 대기시켰다가 다음
    ///      notifyReward(또는 최초 deposit 이후 다음 notifyReward)에서 함께 반영한다.
    function notifyReward(bytes32 marketId, uint256 amount) external {
        if (msg.sender != address(factory)) revert NotFactory();
        if (amount == 0) return;
        uint128 total = totalStakedLiquidity[marketId];
        if (total == 0) {
            pendingReward[marketId] += amount;
            emit RewardNotified(marketId, amount, true);
            return;
        }
        uint256 amt = amount + pendingReward[marketId];
        pendingReward[marketId] = 0;
        accRewardPerLiquidity[marketId] += (amt * PRECISION) / total;
        emit RewardNotified(marketId, amount, false);
    }

    /// @notice LP NFT 예치(stake). 사전에 `npm.approve(address(this), tokenId)` 필요.
    /// @dev marketId는 포지션의 (token0,token1,fee) → pool 주소 → `factory.poolToMarketId`로 역산한다.
    ///      VaultFactory.setMarketPool로 등록된 풀이 아니면 revert(UnknownPool).
    function deposit(uint256 tokenId) external nonReentrant {
        npm.transferFrom(msg.sender, address(this), tokenId);
        (,, address token0, address token1, uint24 fee,,, uint128 liquidity,,,,) = npm.positions(tokenId);
        if (liquidity == 0) revert ZeroLiquidity();

        address pool = IUniswapV3FactoryMinimal(npm.factory()).getPool(token0, token1, fee);
        bytes32 marketId = factory.poolToMarketId(pool);
        if (marketId == bytes32(0)) revert UnknownPool();

        _record(tokenId, msg.sender, marketId, liquidity);
    }

    /// @notice 유동성 생성(mint) + 즉시 스테이킹을 한 번에 — "addLiquidity 하면 자동으로 LpZap에 들어간다"는
    ///         프론트 요구사항 대응(별도 approve(NFT)+deposit 2-tx 대신 ERC20 approve 후 이 함수 1-tx).
    /// @dev NFT를 유저 지갑에 잠깐이라도 보내지 않고 곧장 `recipient: address(this)`로 민팅하므로
    ///      `deposit()`의 `npm.transferFrom` 단계가 필요 없다 — 그 대신 token0/token1 ERC20을 이 함수가
    ///      먼저 당겨와야 하니 사전에 `token0.approve(lpZap, amount0Desired)` / `token1.approve(...)` 필요
    ///      (npm.mint에 직접 넣던 두 토큰 approve 대상이 npm → lpZap으로 바뀌는 것뿐, 기존 add-liquidity
    ///      슬리피지 파라미터 로직은 그대로 재사용 가능). 실제 소비량(amount0/1)이 desired보다 적으면
    ///      남는 dust는 즉시 caller에게 환불한다.
    function mintAndDeposit(INonfungiblePositionManager.MintParams calldata p)
        external
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address pool = IUniswapV3FactoryMinimal(npm.factory()).getPool(p.token0, p.token1, p.fee);
        bytes32 marketId = factory.poolToMarketId(pool);
        if (marketId == bytes32(0)) revert UnknownPool();

        if (p.amount0Desired > 0) IERC20(p.token0).safeTransferFrom(msg.sender, address(this), p.amount0Desired);
        if (p.amount1Desired > 0) IERC20(p.token1).safeTransferFrom(msg.sender, address(this), p.amount1Desired);
        IERC20(p.token0).forceApprove(address(npm), p.amount0Desired);
        IERC20(p.token1).forceApprove(address(npm), p.amount1Desired);

        INonfungiblePositionManager.MintParams memory mintParams = p;
        mintParams.recipient = address(this);
        (tokenId, liquidity, amount0, amount1) = npm.mint(mintParams);

        IERC20(p.token0).forceApprove(address(npm), 0);
        IERC20(p.token1).forceApprove(address(npm), 0);
        if (p.amount0Desired > amount0) IERC20(p.token0).safeTransfer(msg.sender, p.amount0Desired - amount0);
        if (p.amount1Desired > amount1) IERC20(p.token1).safeTransfer(msg.sender, p.amount1Desired - amount1);

        _record(tokenId, msg.sender, marketId, liquidity);
    }

    function _record(uint256 tokenId, address owner_, bytes32 marketId, uint128 liquidity) private {
        positions[tokenId] = Position({
            owner: owner_,
            marketId: marketId,
            liquidity: liquidity,
            rewardDebt: accRewardPerLiquidity[marketId]
        });
        totalStakedLiquidity[marketId] += liquidity;
        depositedAtBlock[tokenId] = block.number;

        emit Deposited(tokenId, owner_, marketId, liquidity);
    }

    /// @notice 포지션 유지한 채 borrow-fee 보너스(USDC) + 풀 자체 스왑 수수료(collect) claim.
    /// @dev deposit과 같은 block에서는 claim 불가(TooSoon) — deposit 직후 곧바로 자기 자신이(또는 자신이
    ///      트리거한) borrow-fee 이벤트를 같은 블록/번들로 묶어 원자적으로 스나이핑하는 걸 막는 최소 방어.
    ///      정상적인 LP는 이 제약에 절대 걸리지 않는다(같은 블록에 예치+클레임을 할 이유가 없음).
    function claim(uint256 tokenId) external nonReentrant returns (uint256 bonus, uint256 fee0, uint256 fee1) {
        Position storage p = positions[tokenId];
        if (p.owner != msg.sender) revert NotOwner();
        if (block.number == depositedAtBlock[tokenId]) revert TooSoon();

        bonus = _settle(p);
        (fee0, fee1) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit Claimed(tokenId, msg.sender, bonus, fee0, fee1);
    }

    /// @notice 유동성 일부/전부 회수(+claim 동시 정산). 전부 회수 시 NFT를 owner에게 반환.
    /// @dev deposit과 같은 block에서는 withdraw 불가(TooSoon) — claim과 동일한 이유(스나이핑 방지).
    ///      CEI 순서: totalStakedLiquidity·p.liquidity 등 내부 상태를 npm 외부호출보다 먼저 갱신한다
    ///      (nonReentrant로 이미 재진입은 막혀 있지만, 방어적으로 원칙을 지킨다).
    function withdraw(uint256 tokenId, uint128 liquidityToRemove, uint256 amount0Min, uint256 amount1Min)
        external
        nonReentrant
        returns (uint256 bonus, uint256 amount0, uint256 amount1)
    {
        Position storage p = positions[tokenId];
        if (p.owner != msg.sender) revert NotOwner();
        if (block.number == depositedAtBlock[tokenId]) revert TooSoon();
        if (liquidityToRemove == 0 || liquidityToRemove > p.liquidity) revert BadAmount();

        bonus = _settle(p);

        bytes32 marketId = p.marketId;
        uint128 remaining = p.liquidity - liquidityToRemove;
        totalStakedLiquidity[marketId] -= liquidityToRemove;
        p.liquidity = remaining;
        if (remaining == 0) delete positions[tokenId];

        npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToRemove,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
        (amount0, amount1) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        if (remaining == 0) npm.safeTransferFrom(address(this), msg.sender, tokenId);

        emit Withdrawn(tokenId, msg.sender, liquidityToRemove, bonus, amount0, amount1);
    }

    /// @notice 스테이킹 유지한 채 유동성 추가(top-up, §5 공백 해소). 사전에
    ///         `token0.approve(lpZap, amount0Desired)` / `token1.approve(lpZap, amount1Desired)` 필요
    ///         (mintAndDeposit과 동일 패턴 — npm이 아니라 lpZap에 ERC20 approve).
    /// @dev 증가분을 반영하기 전에 반드시 먼저 `_settle`로 **기존** liquidity 기준 보너스를 정산하고
    ///      rewardDebt를 현재 accRewardPerLiquidity로 스냅샷한다 — 순서를 바꿔 먼저 liquidity를 늘리면
    ///      이번에 새로 늘어난 몫이 과거 acc 구간에도 소급 적용되어 이미 스테이킹돼 있던 다른 유저의
    ///      리워드를 부당하게 희석시킨다(MasterChef류 accPerShare 패턴의 표준 안전장치, deposit/withdraw와
    ///      동일 원칙). `amount0Desired`/`amount1Desired`보다 덜 쓰였으면 차액은 mintAndDeposit과 동일하게
    ///      즉시 환불. deposit과 같은 block에서는 불가(`TooSoon` — 다른 정산 함수와 동일한 스나이핑 방지 가드).
    function increaseLiquidity(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 bonus, uint128 liquidityAdded, uint256 amount0, uint256 amount1) {
        Position storage p = positions[tokenId];
        if (p.owner != msg.sender) revert NotOwner();
        if (block.number == depositedAtBlock[tokenId]) revert TooSoon();

        (liquidityAdded, amount0, amount1) =
            _increaseLiquidityViaNpm(tokenId, amount0Desired, amount1Desired, amount0Min, amount1Min);

        bonus = _settle(p); // 기존 liquidity 기준으로 먼저 정산 — 증가분 반영 전에 반드시 선행
        totalStakedLiquidity[p.marketId] += liquidityAdded;
        p.liquidity += liquidityAdded;

        emit LiquidityIncreased(tokenId, msg.sender, bonus, liquidityAdded, amount0, amount1);
    }

    /// @dev increaseLiquidity의 npm 상호작용(토큰 당겨오기·approve·호출·dust 환불)만 분리 — via-ir에서도
    ///      한 함수 안에 지역변수가 몰리면 "stack too deep"이 나서 조각냈다(로직상 의미 변화는 없음).
    function _increaseLiquidityViaNpm(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) private returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        (,, address token0, address token1,,,,,,,,) = npm.positions(tokenId);

        if (amount0Desired > 0) IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0Desired);
        if (amount1Desired > 0) IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1Desired);
        IERC20(token0).forceApprove(address(npm), amount0Desired);
        IERC20(token1).forceApprove(address(npm), amount1Desired);

        (liquidity, amount0, amount1) = npm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );

        IERC20(token0).forceApprove(address(npm), 0);
        IERC20(token1).forceApprove(address(npm), 0);
        if (amount0Desired > amount0) IERC20(token0).safeTransfer(msg.sender, amount0Desired - amount0);
        if (amount1Desired > amount1) IERC20(token1).safeTransfer(msg.sender, amount1Desired - amount1);
    }

    /// @notice 정산 없이 현재까지 쌓인 보너스 미리보기 (프론트 표시용).
    function pendingBonus(uint256 tokenId) external view returns (uint256) {
        Position memory p = positions[tokenId];
        if (p.liquidity == 0) return 0;
        return (uint256(p.liquidity) * (accRewardPerLiquidity[p.marketId] - p.rewardDebt)) / PRECISION;
    }

    function _settle(Position storage p) internal returns (uint256 bonus) {
        bonus = (uint256(p.liquidity) * (accRewardPerLiquidity[p.marketId] - p.rewardDebt)) / PRECISION;
        p.rewardDebt = accRewardPerLiquidity[p.marketId];
        if (bonus > 0) usdc.safeTransfer(p.owner, bonus);
    }
}
