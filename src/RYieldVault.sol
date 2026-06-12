// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Minimal seam to the bounded RYieldStrategy (returns USDC to this vault only).
interface IRYieldStrategy {
    function returnToVault(uint256 amount) external;
}

/// @title RYieldVault — 단일자산 델타뉴트럴 funding 수익 볼트 (Litepaper §4.4 / §6).
/// @notice USDC를 예치하면 단일 자산에 대한 델타뉴트럴 전략(rToken 롱 + 동일자산 perp 숏, net delta 0)이
///         받는 funding rate를 수익으로 가져간다. 성과수수료는 gross funding의 10%(§7.1/§10.5), 원금엔 부과 안 함.
///         각 볼트는 단일자산·격리(다른 볼트와 commingle 없음). 인출은 utilization gate(예치 한도) 내에서 언제든.
/// @dev 데모 모델: 온체인 볼트는 "예치/지분/수수료/한도" 회계 레이어다. 델타뉴트럴 전략 실행(AMM에서 rToken
///      매수 + venue perp 숏)과 funding 수금은 프로토콜 keeper/strategy가 수행하고, 수금한 gross funding USDC를
///      harvestFunding()로 볼트에 정산한다(실 funding은 perp 카운터파티가 지급). 가격 PnL은 델타뉴트럴로 상쇄.
///      회계는 balanceOf가 아닌 내부 totalAssets로 추적 → 직접 송금(donation) 기반 share-inflation 공격 불가.
///      Wave 1: 지분은 내부 회계(비-ERC20). 추후 ERC20 토큰화(Pendle 연동, §3.2)는 향후 과제.
contract RYieldVault is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc; // 예치 자산 (6dec)
    address public immutable treasury; // 성과수수료 수령처
    bytes32 public immutable marketId; // 대상 자산 마켓 식별자
    string public assetName; // 예: "rYield NVDA"

    uint256 internal constant BPS = 10_000;
    uint256 public constant PERF_FEE_BPS = 1_000; // gross funding의 10% (§7.1/§10.5)

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    uint256 public totalAssets; // 지분을 backing하는 USDC (원금 + 누적 net funding)
    uint256 public depositCap; // utilization gate: totalAssets 상한 (AMM depth 연동, §4.4)
    uint256 public lifetimeYield; // 누적 net funding (depositor 몫, 조회용)
    uint256 public lifetimePerfFee; // 누적 성과수수료 (treasury)

    // ── vault ↔ strategy seam (Option B: principal held in a bounded RYieldStrategy) ──
    address public strategy; // bounded custodian for deployed capital (owner-set)
    uint256 public deployed; // USDC currently in the strategy (a subset of totalAssets)

    event Deposited(address indexed user, uint256 usdcIn, uint256 sharesOut);
    event Withdrawn(address indexed user, uint256 sharesIn, uint256 usdcOut);
    event Harvested(uint256 grossFundingUsdc, uint256 perfFeeUsdc, uint256 netToVault);
    event DepositCapSet(uint256 cap);
    event StrategySet(address indexed strategy);
    event CapitalDeployed(uint256 amount);
    event CapitalPulled(uint256 amount);

    error CapExceeded();
    error ZeroAmount();
    error InsufficientShares();
    error NoShares();
    error StrategyNotSet();
    error ExceedsIdle();

    constructor(
        IERC20 usdc_,
        address treasury_,
        bytes32 marketId_,
        string memory name_,
        uint256 depositCap_,
        address owner_
    ) Ownable(owner_) {
        require(address(usdc_) != address(0) && treasury_ != address(0), "zero addr");
        usdc = usdc_;
        treasury = treasury_;
        marketId = marketId_;
        assetName = name_;
        depositCap = depositCap_;
    }

    /// @notice 지분당 자산 가격(USDC 1e6 = 1.0). 비어있으면 1.0.
    function pricePerShare() public view returns (uint256) {
        if (totalShares == 0) return 1e6;
        return (totalAssets * 1e6) / totalShares;
    }

    /// @notice 사용자의 현재 자산 가치(USDC).
    function assetsOf(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (sharesOf[user] * totalAssets) / totalShares;
    }

    /// @notice USDC 예치 → 지분 발행. utilization cap 초과 시 revert(§4.4).
    function deposit(uint256 usdcAmount) external returns (uint256 shares) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (totalAssets + usdcAmount > depositCap) revert CapExceeded();
        shares = totalShares == 0 ? usdcAmount : (usdcAmount * totalShares) / totalAssets;
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        sharesOf[msg.sender] += shares;
        totalShares += shares;
        totalAssets += usdcAmount;
        emit Deposited(msg.sender, usdcAmount, shares);
    }

    /// @notice 지분 소각 → 비례 USDC 인출(원금 + 누적 수익). 볼트 잔고가 부족하면(자본이 strategy에
    ///         배포된 경우) 부족분을 strategy에서 회수해 충당한다. CEI: 상태 갱신 후 외부호출.
    function withdraw(uint256 shares) external returns (uint256 usdcOut) {
        if (shares == 0) revert ZeroAmount();
        if (shares > sharesOf[msg.sender]) revert InsufficientShares();
        usdcOut = (shares * totalAssets) / totalShares;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= usdcOut;

        uint256 bal = usdc.balanceOf(address(this));
        if (bal < usdcOut && strategy != address(0)) {
            uint256 need = usdcOut - bal;
            uint256 pull = need > deployed ? deployed : need;
            if (pull > 0) {
                deployed -= pull;
                IRYieldStrategy(strategy).returnToVault(pull);
            }
        }
        usdc.safeTransfer(msg.sender, usdcOut);
        emit Withdrawn(msg.sender, shares, usdcOut);
    }

    /// @notice keeper/strategy가 수금한 gross funding USDC를 정산. 10% 성과수수료→treasury, 90%→볼트(지분가치↑).
    /// @dev msg.sender가 grossFundingUsdc를 입금(transferFrom). 원금 불차감 — 수익에만 부과(§7.1).
    ///      빈 볼트(지분 0)엔 정산 불가(수익을 소유할 지분이 없음).
    function harvestFunding(uint256 grossFundingUsdc) external {
        if (grossFundingUsdc == 0) revert ZeroAmount();
        if (totalShares == 0) revert NoShares();
        usdc.safeTransferFrom(msg.sender, address(this), grossFundingUsdc);
        uint256 perfFee = (grossFundingUsdc * PERF_FEE_BPS) / BPS;
        uint256 net = grossFundingUsdc - perfFee;
        totalAssets += net;
        lifetimeYield += net;
        lifetimePerfFee += perfFee;
        if (perfFee > 0) usdc.safeTransfer(treasury, perfFee);
        emit Harvested(grossFundingUsdc, perfFee, net);
    }

    /// @notice utilization cap 설정(AMM depth 변동 반영, §4.4). admin/governance.
    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapSet(cap);
    }

    // ── vault ↔ strategy (Option B capital seam) — owner/governance gated ──

    /// @notice 볼트 내 유휴 USDC 잔량 (= totalAssets − deployed, 정상 시 balanceOf와 동일).
    function idleAssets() public view returns (uint256) {
        return totalAssets - deployed;
    }

    /// @notice 바운드된 strategy 지정(거버넌스). 자본은 여기로만 배포된다.
    function setStrategy(address strategy_) external onlyOwner {
        strategy = strategy_;
        emit StrategySet(strategy_);
    }

    /// @notice 유휴 USDC를 strategy로 배포(원금을 바운드 보관으로). 거버넌스 정책.
    /// @dev totalAssets 불변 — 자본의 물리적 위치만 볼트→strategy로 이동(예치자 소유 유지).
    function deployToStrategy(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (strategy == address(0)) revert StrategyNotSet();
        if (amount > totalAssets - deployed) revert ExceedsIdle();
        deployed += amount;
        usdc.safeTransfer(strategy, amount);
        emit CapitalDeployed(amount);
    }

    /// @notice strategy에서 USDC를 볼트로 회수(유동성 관리). 거버넌스.
    function pullFromStrategy(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (strategy == address(0)) revert StrategyNotSet();
        uint256 pull = amount > deployed ? deployed : amount;
        deployed -= pull;
        IRYieldStrategy(strategy).returnToVault(pull);
        emit CapitalPulled(pull);
    }
}
