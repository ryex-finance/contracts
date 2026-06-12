# RYex Contracts

Smart contracts for **RYex — the Capital Layer for Perp Markets**.

Each user gets an **isolated collateral vault** that opens a 2× long on GMX, lets the
owner **mint an asset-denominated debt token** (rBTC, rETH, …) up to a per-market max
LTV, repay/close at will, and be **permissionlessly liquidated** once it crosses the
liquidation threshold. Vaults are per-`(user × market)` clones, so one user's risk can
never touch another's.

- **Solidity** `0.8.24` · **Foundry** (primary) + **Hardhat** (compile/TS tests)
- **OpenZeppelin** v5.6.1 · **License** BUSL-1.1
- Status: **demo / unaudited.** The GMX adapter is mocked in the default profile.

---

## Architecture

```
VaultFactory  (Ownable + Pausable · market registry · EIP-1167 clone factory)
  │  admin can only register markets, set params, and pause.
  │  NO function can withdraw user funds (invariant G5).
  │
  ├── deploys one RToken per market   (ERC20 debt token; mint/burn only by a registered vault)
  └── clones one PositionVault per (user × market)
         ├── IGmxAdapter   — LocalGmxMock | GmxV2Adapter   (2-step async absorbed by a state machine)
         ├── IPriceOracle  — MockPriceOracle | Chainlink
         └── IRToken       — mints to the owner EOA on borrow, burns on repay
```

**PositionVault state machine**

```
Empty ─open→ SettlingOpen ─exec→ Active ─close/liquidate→ SettlingLiquidate ─exec→ Empty (reusable)
                  │ cancel↩ (back to Empty)        │ cancel↩ (back to Active)
                  └ cancelStuckOrder after 5m timeout
```

GMX order execution is asynchronous (request → callback). The vault models this as an
explicit state machine: user actions are blocked while an order is settling, callbacks
are authenticated (`NotGmx` / `BadKey`), and a 5-minute timeout lets anyone recover a
stuck order.

**Money math**

- `LTVMath` — health factor as a frozen ratio `HF = LLTV / currentLTV`; LTV/mint checks.
- `Units` — decimal conversions across USDC (6), WAD (18), oracle price (8), GMX (30).

**Key parameters** (defaults; CTO-confirmable before production — see legacy `docs/61`)

| Constant | Value | Meaning |
|---|---|---|
| `MIN_COLLATERAL` | `1e6` (1 USDC) | minimum to open |
| `LIQ_PENALTY_BPS` | `500` (5%) | liquidation penalty |
| `PENALTY_LIQ_SHARE_BPS` | `6000` (60%) | penalty share to the liquidator (rest → treasury) |
| `SETTLING_TIMEOUT` | `5 minutes` | stuck-order recovery window |
| `maxLtvBps` / `lltvBps` | per market | borrow cap / liquidation threshold |

---

## Layout

```
src/
  PositionVault.sol      VaultFactory.sol      RToken.sol
  interfaces/            IGmxAdapter, IPositionVault, IPriceOracle, IRToken, IRyexSwapPool, IVaultFactory
  libraries/             LTVMath, Units
  oracles/               MockPriceOracle
  mocks/                 LocalGmxMock, MockSwapPool, MockUSDC
  types/                 Types (VaultState, OrderKind, PendingOrder, Market)
test/
  unit/  fuzz/  invariant/  integration/   (Foundry · forge test)
  utils/BaseTest.sol
  hardhat/               (TypeScript smoke tests · hardhat test)
script/                  Deploy, DemoScenario, SeedDemo, CapitalLifecycle
deployments/             배포 주소 매니페스트 (gmx, tokens, univ3, pools)
```

---

## Setup

```bash
# Foundry libraries (forge-std + OpenZeppelin v5.6.1, as git submodules)
forge install            # or: git submodule update --init --recursive

# Node tooling for Hardhat + typechain
yarn install
```

## Build

```bash
forge build              # or: make build
yarn build               # forge build && hardhat compile (generates typechain types)
```

## Test

```bash
forge test -vv                       # unit / fuzz / invariant / integration
make coverage                        # forge coverage --report summary
hardhat test                         # TypeScript integration tests (Arbitrum Sepolia)
yarn test                            # both forge + hardhat

FOUNDRY_PROFILE=ci forge test        # heavier fuzz/invariant runs (CI)
```

Current Foundry suite: **70+ tests** across unit, fuzz, invariant (per-user isolation),
and integration (open → mint → liquidate, bad-debt, multi-asset). Coverage is tracked
via `forge coverage` (`solidity-coverage` is also available on the Hardhat side).

## Deploy

```bash
# Arbitrum Sepolia (real GMX V2)
npx hardhat run scripts/deployGmxA1.ts --network arbitrumSepolia

make demo                # DemoScenario end-to-end
make demo-capital        # CapitalLifecycle
```

Deployed addresses are written to `deployments/arbitrumSepolia-gmx.json`.

---

## Security notes

- **No admin fund-withdrawal path** (invariant G5). Admin is limited to market params + pause.
- **Pause is an escape hatch, not a freeze:** new risk-taking (`deposit`, `openPosition`,
  `mint`) is blocked while paused, but `repay`, `closePosition`, and `liquidate` stay open.
- **CEI ordering + `ReentrancyGuard`** on every state-changing vault entrypoint.
- **Bad-debt path:** if recovered collateral < debt, the debt ledger is zeroed and a
  `BadDebt` event is emitted (no socialized loss onto other vaults).
- **Per-user/per-market isolation** is enforced by clones and verified by the
  `Isolation` invariant suite (one user's actions never alter another's vault/debt/LTV).
- GMX async callbacks are authenticated and key-checked; stuck orders are timeout-recoverable.

This code is a **demo and has not been audited.** Do not use with real funds.
