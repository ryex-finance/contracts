// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IGmxAdapter} from "./interfaces/IGmxAdapter.sol";
import {IPositionVault} from "./interfaces/IPositionVault.sol";
import {RToken} from "./RToken.sol";
import {Market, RiskParams} from "./types/Types.sol";

/// @title VaultFactory — 멀티에셋 마켓 레지스트리 + 사용자별 PositionVault clone (docs/10, Wave 1)
/// @notice admin은 마켓 등록·파라미터·pause만. 사용자 자금 직접인출 함수 없음(G5).
///         마켓별로 자산 oracle·rToken·LTV를 보유. createVault(marketId)로 (user×market) 격리 볼트.
contract VaultFactory is IVaultFactory, Ownable, Pausable {
    using SafeERC20 for IERC20;

    event SweptFees(address indexed token, address indexed to, uint256 amount);

    address public immutable implementation; // PositionVault 로직 (immutable, D7)
    IGmxAdapter public gmxAdapter;
    address public usdc;

    mapping(bytes32 => Market) public markets; // marketId => 설정
    bytes32[] public marketIds; // 등록 순서(조회용)
    mapping(address => bytes32) public marketIdByOracle; // oracle → marketId (가격 갱신 sync용)
    mapping(bytes32 => address[]) internal _vaultRegistry; // marketId → 생성된 vault 목록
    mapping(address => mapping(bytes32 => address)) public vaultOf; // owner => marketId => vault
    mapping(address => bool) public isVault;
    uint256 public totalVaults;           // 누적 생성 볼트 수
    uint256 public totalCollateralLocked; // 전체 볼트 USDC collateral 합계 (6dec). Vault push 방식.

    // RLT 상환 FIFO 큐 (마켓별). zone 진입 시 자동/수동 enqueue (Litepaper §4.5).
    mapping(bytes32 => address[]) internal _redemptionQueue;
    mapping(bytes32 => mapping(address => bool)) public inRedemptionQueue; // marketId => vault => queued

    event RedemptionEnqueued(bytes32 indexed marketId, address indexed vault);
    event RedemptionDequeued(bytes32 indexed marketId, address indexed vault);

    error VaultExists();
    error ZeroAddress();
    error MarketExists();
    error NoMarket();
    error BadRiskParams();
    error NotRedeemable();
    error StillRedeemable();
    error MarketMismatch();

    constructor(address implementation_, IGmxAdapter gmx_, address usdc_, address admin_) Ownable(admin_) {
        if (implementation_ == address(0) || usdc_ == address(0) || address(gmx_) == address(0)) {
            revert ZeroAddress();
        }
        implementation = implementation_;
        gmxAdapter = gmx_;
        usdc = usdc_;
    }

    /// @notice 마켓 등록. 자산별 RToken을 factory가 배포(isVault 가드 일관). marketId = keccak(symbol) 권장.
    /// @dev 배포 스크립트가 adapter.registerMarket(marketId, oracle, gmxMarket)을 호출해 마켓을 등록해야 함.
    /// @param risk 자산별 레버리지 LTV 곡선(Litepaper v1.6 §5): maxLtv1x·buffer·maxLtvAtMaxLev·flatTier·maxLeverage.
    function addMarket(
        bytes32 marketId,
        IPriceOracle oracle,
        string calldata name,
        string calldata symbol,
        RiskParams calldata risk
    ) external onlyOwner returns (address rToken) {
        if (markets[marketId].active) revert MarketExists();
        if (address(oracle) == address(0)) revert ZeroAddress();
        // Risk-curve invariants (fail fast at config time, not at runtime in mint/curve):
        //  - maxLeverage>0, maxLtv1x>0; flatTier in [1, maxLeverage]
        //  - buffer>0 so mint cap (<= maxLtv1x) stays strictly below LLTV (= maxLtv1x+buffer) — no mint-into-liquidation
        //  - curve monotonic: maxLtvAtMaxLev <= maxLtv1x (mirrors LTVMath 'bad curve' require)
        //  - LLTV <= 100%: maxLtv1x + buffer <= BPS (no over-100% LTV)
        if (
            risk.maxLeverage == 0 || risk.maxLtv1xBps == 0 || risk.bufferBps == 0 || risk.flatTier == 0
                || risk.flatTier > risk.maxLeverage || risk.maxLtvAtMaxLevBps > risk.maxLtv1xBps
                || uint256(risk.maxLtv1xBps) + risk.bufferBps > 10_000
        ) revert BadRiskParams();
        rToken = address(new RToken(this, name, symbol));
        markets[marketId] = Market({
            active: true,
            oracle: address(oracle),
            rToken: rToken,
            maxLtv1xBps: risk.maxLtv1xBps,
            bufferBps: risk.bufferBps,
            maxLtvAtMaxLevBps: risk.maxLtvAtMaxLevBps,
            flatTier: risk.flatTier,
            maxLeverage: risk.maxLeverage
        });
        marketIds.push(marketId);
        marketIdByOracle[address(oracle)] = marketId;
        emit MarketAdded(marketId, address(oracle), rToken);
    }

    function createVault(bytes32 marketId) external whenNotPaused returns (address vault) {
        Market memory m = markets[marketId];
        if (!m.active) revert NoMarket();
        if (vaultOf[msg.sender][marketId] != address(0)) revert VaultExists(); // I1: 마켓별 1인1볼트
        vault = Clones.clone(implementation);
        vaultOf[msg.sender][marketId] = vault;
        isVault[vault] = true;
        totalVaults++;
        RiskParams memory risk = RiskParams({
            maxLtv1xBps: m.maxLtv1xBps,
            bufferBps: m.bufferBps,
            maxLtvAtMaxLevBps: m.maxLtvAtMaxLevBps,
            flatTier: m.flatTier,
            maxLeverage: m.maxLeverage
        });
        IPositionVault(vault).initialize(
            msg.sender, address(this), gmxAdapter, IPriceOracle(m.oracle), usdc, m.rToken, marketId, risk
        );
        _vaultRegistry[marketId].push(vault);
        emit VaultCreated(msg.sender, marketId, vault);
    }

    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    /// @notice Vault가 collateral 증감 시 호출 → totalCollateralLocked 갱신.
    ///         delta > 0: deposit 등 증가분, delta < 0: withdraw/close/liquidation 감소분.
    function onCollateralChanged(int256 delta) external {
        if (!isVault[msg.sender]) revert NoMarket();
        if (delta > 0) {
            totalCollateralLocked += uint256(delta);
        } else if (delta < 0) {
            uint256 decrease = uint256(-delta);
            totalCollateralLocked = decrease > totalCollateralLocked
                ? 0
                : totalCollateralLocked - decrease;
        }
    }

    // ── RLT 상환 큐 (Litepaper §4.5) — FIFO 순서 힌트. 실제 redeem은 Vault.redeem(zone 가드)에서. ──

    /// @inheritdoc IVaultFactory
    function syncRedemptionQueueForOracle(address oracle) external {
        bytes32 marketId = marketIdByOracle[oracle];
        if (marketId == bytes32(0) || !markets[marketId].active) return;
        if (markets[marketId].oracle != oracle) return;
        _syncRedemptionQueue(marketId);
    }

    /// @inheritdoc IVaultFactory
    /// @dev mint 후 zone 진입 시 enqueue, redeem 정산 후 zone 이탈 시 dequeue.
    function notifyVaultRedemptionCheck() external {
        if (!isVault[msg.sender]) revert NoMarket();
        _syncVaultInQueue(IPositionVault(msg.sender).marketId(), msg.sender);
    }

    function _syncVaultInQueue(bytes32 marketId, address vault) internal {
        if (IPositionVault(vault).isRedeemable()) {
            _tryEnqueue(marketId, vault, false);
        } else {
            _tryDequeueVault(marketId, vault);
        }
    }

    function _tryDequeueVault(bytes32 marketId, address vault) internal {
        if (!inRedemptionQueue[marketId][vault]) return;
        address[] storage q = _redemptionQueue[marketId];
        uint256 n = q.length;
        for (uint256 i = 0; i < n; i++) {
            if (q[i] == vault) {
                _dequeueAt(marketId, i);
                return;
            }
        }
        inRedemptionQueue[marketId][vault] = false;
    }

    /// @notice 마켓 내 등록 볼트를 스캔해 상환존 진입분을 큐에 등록(permissionless).
    function syncRedemptionQueue(bytes32 marketId) external {
        if (!markets[marketId].active) revert NoMarket();
        _syncRedemptionQueue(marketId);
    }

    function _syncRedemptionQueue(bytes32 marketId) internal {
        _pruneStaleRedemptions(marketId);
        address[] storage vaults = _vaultRegistry[marketId];
        uint256 n = vaults.length;
        for (uint256 i = 0; i < n; i++) {
            _tryEnqueue(marketId, vaults[i], false);
        }
    }

    /// @dev 상환존 이탈한 큐 항목 제거. setPrice sync 시 자동 호출.
    function _pruneStaleRedemptions(bytes32 marketId) internal {
        address[] storage q = _redemptionQueue[marketId];
        uint256 i = 0;
        while (i < q.length) {
            if (!IPositionVault(q[i]).isRedeemable()) {
                _dequeueAt(marketId, i);
            } else {
                i++;
            }
        }
    }

    function _dequeueAt(bytes32 marketId, uint256 index) internal {
        address[] storage q = _redemptionQueue[marketId];
        address vault = q[index];
        inRedemptionQueue[marketId][vault] = false;
        q[index] = q[q.length - 1];
        q.pop();
        emit RedemptionDequeued(marketId, vault);
    }

    /// @notice 상환존에 든 Vault를 그 Vault의 마켓 FIFO 큐에 등록(permissionless).
    function enqueueRedemption(bytes32 marketId, address vault) external {
        if (!isVault[vault]) revert NoMarket();
        if (!markets[marketId].active) revert NoMarket();
        if (IPositionVault(vault).marketId() != marketId) revert MarketMismatch();
        _tryEnqueue(marketId, vault, true);
    }

    function _tryEnqueue(bytes32 marketId, address vault, bool requireRedeemable) internal {
        if (inRedemptionQueue[marketId][vault]) return;
        if (!IPositionVault(vault).isRedeemable()) {
            if (requireRedeemable) revert NotRedeemable();
            return;
        }
        inRedemptionQueue[marketId][vault] = true;
        _redemptionQueue[marketId].push(vault);
        emit RedemptionEnqueued(marketId, vault);
    }

    function vaultRegistryLength(bytes32 marketId) external view returns (uint256) {
        return _vaultRegistry[marketId].length;
    }

    function vaultRegistryAt(bytes32 marketId, uint256 i) external view returns (address) {
        return _vaultRegistry[marketId][i];
    }

    /// @notice 더 이상 상환 불가한 Vault를 큐에서 제거(permissionless, swap-pop). 플래그 해제 → 재진입 시 재등록 가능.
    function pruneRedemption(bytes32 marketId, uint256 index) external {
        address[] storage q = _redemptionQueue[marketId];
        if (IPositionVault(q[index]).isRedeemable()) revert StillRedeemable();
        _dequeueAt(marketId, index);
    }

    /// @notice FIFO 큐에서 아직 상환 가능한 첫 Vault(없으면 0). redeemer가 이걸 redeem.
    function nextRedeemable(bytes32 marketId) external view returns (address) {
        address[] storage q = _redemptionQueue[marketId];
        uint256 n = q.length;
        for (uint256 i = 0; i < n; i++) {
            if (IPositionVault(q[i]).isRedeemable()) return q[i];
        }
        return address(0);
    }

    function redemptionQueueLength(bytes32 marketId) external view returns (uint256) {
        return _redemptionQueue[marketId].length;
    }

    function redemptionQueueAt(bytes32 marketId, uint256 i) external view returns (address) {
        return _redemptionQueue[marketId][i];
    }

    // ── 대시보드 집계 view ──────────────────────────────────────────────────────

    /// @notice RLT queue 중 실제 상환 가능한 볼트 수 (Redeemable positions).
    function redeemableCount(bytes32 marketId) external view returns (uint256 count) {
        address[] storage q = _redemptionQueue[marketId];
        uint256 n = q.length;
        for (uint256 i = 0; i < n; i++) {
            if (IPositionVault(q[i]).isRedeemable()) count++;
        }
    }

    /// @notice 상환 가능한 볼트들의 rToken 부채 합계 — 18dec (RLT capacity).
    ///         프론트에서 oracle 가격 곱해 USD로 환산.
    function totalRedeemableDebt(bytes32 marketId) external view returns (uint256 total) {
        address[] storage q = _redemptionQueue[marketId];
        uint256 n = q.length;
        for (uint256 i = 0; i < n; i++) {
            address v = q[i];
            if (IPositionVault(v).isRedeemable()) {
                total += IPositionVault(v).debt();
            }
        }
    }

    /// @notice 큐 내 볼트들의 평균 health factor — BPS 단위 (10000 = LLTV 경계).
    ///         healthBps = lltvBps * 10000 / currentLTV. 값이 클수록 건강.
    ///         큐가 비어 있으면 0 반환.
    function avgHealthAcrossQueue(bytes32 marketId) external view returns (uint256) {
        address[] storage q = _redemptionQueue[marketId];
        uint256 n = q.length;
        if (n == 0) return 0;
        uint256 sum;
        uint256 cnt;
        for (uint256 i = 0; i < n; i++) {
            address v = q[i];
            if (!IPositionVault(v).isRedeemable()) continue;
            uint256 ltv  = IPositionVault(v).currentLTV();
            uint256 lltv = IPositionVault(v).lltvBps();
            if (ltv == 0) continue;
            sum += (lltv * 10_000) / ltv; // 10000 = at-LLTV, >10000 = healthy
            cnt++;
        }
        return cnt == 0 ? 0 : sum / cnt;
    }

    // ── admin (파라미터·pause만, timelock 경유 권장 D5) ──

    function setGmxAdapter(IGmxAdapter gmx_) external onlyOwner {
        if (address(gmx_) == address(0)) revert ZeroAddress();
        gmxAdapter = gmx_;
    }

    /// @notice 신규 위험 차단. 상환·청산·인출(탈출)은 Vault에서 계속 허용(docs/70 §5).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function paused() public view override(IVaultFactory, Pausable) returns (bool) {
        return Pausable.paused();
    }

    /// @notice 프로토콜 수수료/페널티/정산금 인출(treasury). PositionVault 정산이 factory로 보낸 USDC를 회수.
    /// @dev 이 컨트랙트가 보유한 토큰(프로토콜 수익)만 대상 — 사용자 Vault 담보엔 접근 불가(G5 불변, 클론 격리).
    function sweepFees(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit SweptFees(address(token), to, amount);
    }
}
