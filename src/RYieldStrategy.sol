// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRyexSwapPool} from "./interfaces/IRyexSwapPool.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IShortPerp} from "./interfaces/IShortPerp.sol";

/// @dev Minimal seam to credit harvested funding to the owning vault (USDC → vault).
interface IRYieldVaultHarvest {
    function harvestFunding(uint256 grossFundingUsdc) external;
}

/// @title RYieldStrategy — bounded custodian for a RYieldVault's deployed capital (Litepaper §4.4/§6).
/// @notice This is the "Option B" custody layer: instead of a hot keeper EOA holding the
///         delta-neutral hedge, the deployed principal lives here and the keeper key may
///         only call a constrained set of ops. The single security invariant:
///
///             **USDC can leave this contract ONLY back to the owning vault.**
///
///         There is no generic transfer; the keeper key cannot exfiltrate funds. A
///         compromised keeper can, at worst, convert the long leg (rToken) to USDC inside
///         the strategy (`reduceLong`) — it stays here and is only ever returnable to the
///         vault. Owner (governance/multisig) sets the keeper and may rotate it.
///
/// @dev v2: the strategy now executes the real two-leg delta-neutral hedge on-chain —
///      `openHedge` buys the rToken long (USDC→rToken via the pool) AND opens the perp
///      short, guarding longNotional ≈ shortNotional; `harvestShortFunding` claims the
///      short's real funding and credits it to the vault; `closeHedge` unwinds both legs.
///      The security property is unchanged: USDC only ever leaves to the vault (via
///      `returnToVault`) or into the wired venues (pool / short perp) as part of a bounded
///      op — never to an arbitrary address, so the keeper key cannot exfiltrate.
contract RYieldStrategy is Ownable {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    /// Max |longNotional − shortNotional| as a fraction of the short, on openHedge.
    uint256 public constant DELTA_BAND_BPS = 200; // 2%

    address public immutable vault; // the RYieldVault this strategy serves (sole USDC recipient)
    IERC20 public immutable usdc; // deposited asset (6dec)
    IERC20 public immutable rToken; // long leg token (18dec)
    IRyexSwapPool public immutable swapPool; // rToken↔USDC venue (oracle-priced)
    IPriceOracle public immutable oracle; // asset price feed
    IShortPerp public immutable shortPerp; // funding-bearing short venue
    bytes32 public immutable marketId;

    address public keeper; // operator: bounded ops only (NOT a fund owner)
    bytes32 public shortKey; // current short position (0 = none)

    event KeeperSet(address indexed keeper);
    event LongReduced(uint256 rTokenIn, uint256 usdcOut);
    event ReturnedToVault(uint256 usdcOut);
    event HedgeOpened(uint256 usdcLong, uint256 shortMargin, uint256 shortSize, bytes32 shortKey);
    event ShortFundingHarvested(uint256 amount);
    event HedgeClosed(uint256 shortPayout, uint256 longUsdc);

    error NotVault();
    error NotKeeper();
    error ZeroAmount();
    error InsufficientUsdc();
    error DeltaImbalance();
    error NoShort();
    error ShortExists();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(
        address vault_,
        IERC20 usdc_,
        IERC20 rToken_,
        IRyexSwapPool swapPool_,
        IPriceOracle oracle_,
        IShortPerp shortPerp_,
        bytes32 marketId_,
        address keeper_,
        address owner_
    ) Ownable(owner_) {
        require(
            vault_ != address(0) && address(usdc_) != address(0) && address(rToken_) != address(0)
                && address(swapPool_) != address(0) && address(shortPerp_) != address(0),
            "zero addr"
        );
        vault = vault_;
        usdc = usdc_;
        rToken = rToken_;
        swapPool = swapPool_;
        oracle = oracle_;
        shortPerp = shortPerp_;
        marketId = marketId_;
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    // ── governance ──

    /// @notice Rotate the keeper (operator). Owner only — the keeper cannot change itself.
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    // ── keeper ops (bounded; cannot move USDC out except via returnToVault) ──

    /// @notice Convert part of the long leg (rToken) to USDC via the swap pool. USDC stays
    ///         in this contract (only returnToVault can move it to the vault). Lets the
    ///         keeper unwind the long / prepare withdrawal liquidity without custody risk.
    function reduceLong(uint256 rTokenIn, uint256 minUsdcOut) external onlyKeeper returns (uint256 usdcOut) {
        if (rTokenIn == 0) revert ZeroAmount();
        rToken.forceApprove(address(swapPool), rTokenIn);
        usdcOut = swapPool.swapRBtcForUsdc(rTokenIn, minUsdcOut, address(this));
        emit LongReduced(rTokenIn, usdcOut);
    }

    /// @notice Open the delta-neutral hedge: buy the rToken long (usdcLong → rToken) AND open
    ///         the perp short (shortMargin margin / shortSize notional). Guards longNotional ≈
    ///         shortNotional (within DELTA_BAND_BPS) so the position is hedged, not directional.
    ///         USDC moves only into the wired venues (pool, short perp) — never to an arbitrary
    ///         address, so the keeper key cannot exfiltrate.
    function openHedge(uint256 usdcLong, uint256 shortMargin, uint256 shortSize, uint256 minRBtcOut)
        external
        onlyKeeper
    {
        if (usdcLong == 0 || shortMargin == 0 || shortSize == 0) revert ZeroAmount();
        if (shortKey != 0) revert ShortExists();
        if (usdcLong + shortMargin > usdc.balanceOf(address(this))) revert InsufficientUsdc();
        uint256 diff = usdcLong > shortSize ? usdcLong - shortSize : shortSize - usdcLong;
        if (diff * BPS > shortSize * DELTA_BAND_BPS) revert DeltaImbalance();

        usdc.forceApprove(address(swapPool), usdcLong);
        swapPool.swapUsdcForRBtc(usdcLong, minRBtcOut, address(this)); // long leg
        usdc.forceApprove(address(shortPerp), shortMargin);
        shortKey = shortPerp.openShort(shortMargin, shortSize); // short leg
        emit HedgeOpened(usdcLong, shortMargin, shortSize, shortKey);
    }

    /// @notice Claim the short's accrued funding and credit it to the vault (90% depositors /
    ///         10% perf fee). Funding USDC flows short perp → strategy → vault only.
    function harvestShortFunding() external onlyKeeper returns (uint256 claimed) {
        if (shortKey == 0) revert NoShort();
        claimed = shortPerp.claimFunding(shortKey);
        if (claimed > 0) {
            usdc.forceApprove(vault, claimed);
            IRYieldVaultHarvest(vault).harvestFunding(claimed);
        }
        emit ShortFundingHarvested(claimed);
    }

    /// @notice Unwind the hedge: close the short and convert the full long back to USDC.
    ///         USDC stays in the strategy (returnable to the vault).
    function closeHedge(uint256 minUsdcOut) external onlyKeeper {
        uint256 shortPayout;
        if (shortKey != 0) {
            shortPayout = shortPerp.closeShort(shortKey);
            shortKey = 0;
        }
        uint256 rBal = rToken.balanceOf(address(this));
        uint256 longUsdc;
        if (rBal > 0) {
            rToken.forceApprove(address(swapPool), rBal);
            longUsdc = swapPool.swapRBtcForUsdc(rBal, minUsdcOut, address(this));
        }
        emit HedgeClosed(shortPayout, longUsdc);
    }

    // ── vault seam (the ONLY USDC-out path) ──

    /// @notice Return USDC to the owning vault (e.g. to service a withdrawal). Vault-only,
    ///         and the destination is hard-wired to `vault` — funds can never reach an
    ///         arbitrary address. Reverts if idle USDC is insufficient (keeper must
    ///         reduceLong first to free liquidity).
    function returnToVault(uint256 amount) external onlyVault {
        if (amount == 0) revert ZeroAmount();
        if (usdc.balanceOf(address(this)) < amount) revert InsufficientUsdc();
        usdc.safeTransfer(vault, amount);
        emit ReturnedToVault(amount);
    }

    // ── views (NAV for off-chain reconciliation) ──

    function usdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function rTokenBalance() external view returns (uint256) {
        return rToken.balanceOf(address(this));
    }

    /// @notice Long-leg value in USDC at the oracle price (via the pool quote).
    function longValueUsdc() public view returns (uint256) {
        uint256 bal = rToken.balanceOf(address(this));
        return bal == 0 ? 0 : swapPool.quoteRBtcToUsdc(bal);
    }

    /// @notice Short-leg mark-to-market value in USDC (margin ± price PnL + accrued funding).
    function shortValueUsdc() public view returns (uint256) {
        return shortKey == 0 ? 0 : shortPerp.positionValueUsdc(shortKey);
    }

    /// @notice Total strategy NAV in USDC = idle USDC + long-leg + short-leg. In a
    ///         delta-neutral position the long's price PnL offsets the short's, so this
    ///         tracks the deployed principal + accrued funding.
    function totalValueUsdc() external view returns (uint256) {
        return usdc.balanceOf(address(this)) + longValueUsdc() + shortValueUsdc();
    }
}
