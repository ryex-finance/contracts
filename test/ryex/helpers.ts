/**
 * test/ryex 공통 헬퍼 — Arbitrum Sepolia 통합 테스트용
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import type { Contract } from "ethers";
import { ethers, network } from "hardhat";
import { GMX } from "./config/gmxArbitrumSepolia";

// ── ABI: Hardhat artifacts(.abi) / 외부 ABI 파일 ──────────────────────────────
import PositionVaultArtifact  from "../../artifacts/src/PositionVault.sol/PositionVault.json";
import VaultFactoryArtifact   from "../../artifacts/src/VaultFactory.sol/VaultFactory.json";
import GmxAdapterArtifact     from "../../artifacts/src/adapters/GmxV2Adapter.sol/GmxV2Adapter.json";
import MockPriceOracleArtifact from "../../artifacts/src/oracles/MockPriceOracle.sol/MockPriceOracle.json";
import RTokenArtifact         from "../../artifacts/src/RToken.sol/RToken.json";
import ERC20Abi               from "../../abi/ERC20.json"; // flat array

export const POSITION_VAULT_ABI  = PositionVaultArtifact.abi;
export const VAULT_FACTORY_ABI   = VaultFactoryArtifact.abi;
export const GMX_ADAPTER_ABI     = GmxAdapterArtifact.abi;
export const ORACLE_ABI          = MockPriceOracleArtifact.abi;
export const RTOKEN_ABI          = RTokenArtifact.abi;
export const ERC20_ABI           = ERC20Abi;

export const GMX_READER_ABI = [
  "function getPosition(address dataStore, bytes32 key) view returns (tuple(tuple(address account,address market,address collateralToken) addresses, tuple(uint256 sizeInUsd,uint256 sizeInTokens,uint256 collateralAmount,int256 pendingImpactAmount,uint256 borrowingFactor,uint256 fundingFeeAmountPerSize,uint256 longTokenClaimableFundingAmountPerSize,uint256 shortTokenClaimableFundingAmountPerSize,uint256 increasedAtTime,uint256 decreasedAtTime) numbers, tuple(bool isLong) flags))",
];

export const OrderKind = {
  None: 0n,
  Open: 1n,
  Close: 2n,
  Liquidate: 3n,
  LimitOpen: 4n,
  TakeProfit: 5n,
  StopLoss: 6n,
  Redeem: 7n,
} as const;

export interface MarketInfo {
  marketId:  string;
  oracle:    string;
  rToken:    string;
  swapPool:  string;
  gmxMarket: string;
  maxLtvBps: number;
  lltvBps:   number;
}

export interface Deployment {
  chainId:      number;
  vaultFactory: string;
  gmxAdapter:   string;
  usdc:         string;
  markets:      Record<string, MarketInfo>;
}

export const VaultState = {
  Empty: 0n,
  SettlingOpen: 1n,
  Active: 2n,
  SettlingLiquidate: 3n,
  Liquidated: 4n,
} as const;

export const BPS = 10_000n;
export const PRICE_ONE = 10n ** 8n;
// GMX testnet pool 사이즈가 작아 $10 이하로 유지해야 InsufficientReserves 회피
export const DEPOSIT_USDC = 5n * 10n ** 6n; // 5 USDC → 2× = $10
export const LEVERAGE = 2;
export const EXEC_FEE = ethers.parseEther("0.0001");

export async function loadDeployment(): Promise<Deployment> {
  const candidates = [
    path.join(process.cwd(), "deployments", `${network.name}-gmx.json`),
    path.join(process.cwd(), "deployments", "arbitrum-sepolia-gmx.json"),
  ];
  for (const f of candidates) {
    try {
      return JSON.parse(await readFile(f, "utf8")) as Deployment;
    } catch {
      /* next */
    }
  }
  throw new Error("No deployment JSON found. Run deployGmxA1.ts first.");
}

export async function pollUntil<T>(
  fn: () => Promise<T>,
  predicate: (v: T) => boolean,
  intervalMs = 5_000,
  timeoutMs = 30_000,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const val = await fn();
    if (predicate(val)) return val;
    console.log(`    ⏳ waiting ${intervalMs / 1000}s…`);
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`pollUntil: timed out after ${timeoutMs / 1000}s`);
}

/** collateral net value × effectiveMaxLtv 기준 추가 mint 가능 rToken 수량 (18dec, 내림) */
export function maxMintableRToken(
  collateralValueUsdWad: bigint,
  debtValueUsdWad: bigint,
  effectiveMaxLtvBps: bigint,
  oraclePrice8: bigint,
): bigint {
  const maxDebtWad = (collateralValueUsdWad * effectiveMaxLtvBps) / BPS;
  if (maxDebtWad <= debtValueUsdWad) return 0n;
  const headroomWad = maxDebtWad - debtValueUsdWad;
  return (headroomWad * PRICE_ONE) / oraclePrice8;
}

export interface VaultRiskSnapshot {
  collateralValueUsdWad: bigint;
  debtValueUsdWad: bigint;
  currentLtvBps: bigint;
  effectiveMaxLtvBps: bigint;
  debtRToken: bigint;
  oraclePrice8: bigint;
}

export async function readVaultRisk(
  vault: Contract,
  oracleAddr: string,
): Promise<VaultRiskSnapshot> {
  const oracle = new ethers.Contract(oracleAddr, ORACLE_ABI, ethers.provider);
  const [collateralValueUsdWad, debtValueUsdWad, currentLtvBps, effectiveMaxLtvBps, debtRToken, oraclePrice8] =
    await Promise.all([
      vault.collateralValueUsdWad(),
      vault.debtValueUsdWad(),
      vault.currentLTV(),
      vault.effectiveMaxLtvBps(),
      vault.debt(),
      oracle.getPrice(),
    ]);
  return {
    collateralValueUsdWad,
    debtValueUsdWad,
    currentLtvBps,
    effectiveMaxLtvBps,
    debtRToken,
    oraclePrice8,
  };
}

/** 볼트가 Active 상태가 될 때까지 설정 (없으면 생성·오픈·GMX 체결·정산) */
export async function ensureActiveVault(
  signer: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  deployment: Deployment,
  marketSymbol: string,
): Promise<string> {
  const signerAddr = await signer.getAddress();
  const mkt = deployment.markets[marketSymbol];
  const factory = new ethers.Contract(deployment.vaultFactory, VAULT_FACTORY_ABI, signer);
  const usdc = new ethers.Contract(deployment.usdc, ERC20_ABI, signer);

  let vaultAddr: string = await factory.vaultOf(signerAddr, mkt.marketId);

  if (vaultAddr === ethers.ZeroAddress) {
    console.log("  → Creating vault…");
    const tx = await factory.createVault(mkt.marketId);
    const rc = await tx.wait();
    const topic = ethers.id("VaultCreated(address,bytes32,address)");
    for (const log of rc!.logs) {
      if (log.topics[0] === topic) {
        vaultAddr = ethers.AbiCoder.defaultAbiCoder().decode(["address"], log.data)[0] as string;
        break;
      }
    }
  }

  const vault = new ethers.Contract(vaultAddr, POSITION_VAULT_ABI, signer);
  let state: bigint = await vault.state();

  if (state === VaultState.SettlingOpen) {
    // 이미 진행 중인 주문: GMX 콜백 대기 or settleGmxOrder fallback
    const pendingInfo = await vault.pending();
    const isLimitOrder = pendingInfo.kind === 4n; // OrderKind.LimitOpen
    try {
      await waitForSettlement(vaultAddr, deployment.gmxAdapter, signer, isLimitOrder ? 60_000 : 90_000);
    } catch {
      if (isLimitOrder) {
        await (await vault.cancelLimitOrder()).wait();
        await waitAndCancelGmxOrder(vaultAddr, deployment.gmxAdapter, signer);
      } else {
        throw new Error("ensureActiveVault: market order stuck");
      }
    }
    state = await vault.state();
  }

  if (state === VaultState.Empty) {
    // GMX 테스트넷 long 풀 고갈 빈번 → short(isLong=false)으로 오픈
    await (await usdc.approve(vaultAddr, DEPOSIT_USDC)).wait();
    await (await vault.deposit(DEPOSIT_USDC)).wait();
    await (await vault.openPosition(LEVERAGE, false /* short */, { value: EXEC_FEE })).wait();
    await waitForSettlement(vaultAddr, deployment.gmxAdapter, signer);
    state = await vault.state();
  }

  if (state !== VaultState.Active) {
    throw new Error(`Vault ${vaultAddr} not Active (state=${state})`);
  }

  return vaultAddr;
}

/** LTV 한도까지 mint (headroom 전량) */
export async function mintMaxRToken(
  vaultAddr: string,
  signer: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  oracleAddr: string,
): Promise<bigint> {
  const vault = await ethers.getContractAt("PositionVault", vaultAddr, signer);
  const risk = await readVaultRisk(vault, oracleAddr);
  const amount = maxMintableRToken(
    risk.collateralValueUsdWad,
    risk.debtValueUsdWad,
    risk.effectiveMaxLtvBps,
    risk.oraclePrice8,
  );
  if (amount > 0n) {
    await (await vault.mint(amount)).wait();
  }
  return amount;
}

/**
 * RLT <= LTV < LLTV 상환존 진입.
 * max mint 후에도 LTV가 RLT 미만이면 oracle 가격을 단계적으로 하락.
 */
export async function pushToRedemptionZone(
  vaultAddr: string,
  oracleAddr: string,
  oracleSigner: Awaited<ReturnType<typeof ethers.getSigners>>[0],
): Promise<void> {
  const vault = await ethers.getContractAt("PositionVault", vaultAddr);
  const oracle = await ethers.getContractAt("MockPriceOracle", oracleAddr, oracleSigner);

  if (await vault.isRedeemable()) return;

  for (let i = 0; i < 30; i++) {
    const [ltv, lltv] = await Promise.all([vault.currentLTV(), vault.lltvBps()]);
    if (await vault.isRedeemable()) return;
    if (ltv >= lltv) {
      throw new Error(`LTV ${ltv} bps reached LLTV ${lltv} before redemption zone`);
    }
    const price: bigint = await oracle.getPrice();
    // USDC 담보 구조: collateralValue = stable $5, debtValue = debt × oracle.price
    // 가격 상승 → debtValue 상승 → LTV 상승
    const next = (price * 102n) / 100n; // 2% 상승 → 부채 가치↑ → LTV↑
    await (await oracle.setPrice(next)).wait();
  }
  throw new Error("failed to enter redemption zone after 30 price rises");
}

/** LTV >= LLTV 청산 가능 여부 */
export async function isLiquidatable(vaultAddr: string): Promise<boolean> {
  const vault = await ethers.getContractAt("PositionVault", vaultAddr);
  const [ltv, lltv] = await Promise.all([vault.currentLTV(), vault.lltvBps()]);
  return ltv >= lltv;
}

/** LTV >= LLTV 청산존 진입 (oracle 가격 하락) */
export async function pushToLiquidationZone(
  vaultAddr: string,
  oracleAddr: string,
  oracleSigner: Awaited<ReturnType<typeof ethers.getSigners>>[0],
): Promise<void> {
  const vault = await ethers.getContractAt("PositionVault", vaultAddr);
  const oracle = await ethers.getContractAt("MockPriceOracle", oracleAddr, oracleSigner);

  if (await isLiquidatable(vaultAddr)) return;

  for (let i = 0; i < 50; i++) {
    if (await isLiquidatable(vaultAddr)) return;
    const price: bigint = await oracle.getPrice();
    // USDC 담보 구조: 가격 상승 → debtValue 상승 → LTV 상승 → 청산존 진입
    const next = (price * 105n) / 100n; // 5% 상승 → 부채 가치↑ → LTV↑
    await (await oracle.setPrice(next)).wait();
  }
  throw new Error("failed to enter liquidation zone after 50 price rises");
}

/** GMX Reader에서 adapter 계정 포지션 조회 */
export async function readGmxPosition(adapterAddr: string, isLong: boolean) {
  const posKey = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "address", "bool"],
      [adapterAddr, GMX.MARKET_ETH, GMX.USDC, isLong],
    ),
  );
  const reader = new ethers.Contract(GMX.READER, GMX_READER_ABI, ethers.provider);
  const pos = await reader.getPosition(GMX.DATA_STORE, posKey);
  const sizeInUsd = pos.numbers.sizeInUsd as bigint;
  return {
    posKey,
    sizeInUsd,
    collateralAmount: pos.numbers.collateralAmount as bigint,
    isLong: pos.flags.isLong as boolean,
    exists: sizeInUsd > 0n,
  };
}

/**
 * Vault가 Settling 상태에서 벗어날 때까지 대기.
 * GMX 콜백이 자동으로 상태를 전환하고, 타임아웃 시 settleGmxOrder() fallback 호출.
 *
 * @param waitTimeoutMs GMX 콜백 대기 시간 (콜백이 안 오면 settleGmxOrder로 강제 정산)
 */
/** GMX redeem( partial decrease) 체결 대기 — pending.kind == Redeem → None */
export async function waitForRedeemSettlement(
  vaultAddr: string,
  adapterAddr: string,
  signer: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  waitTimeoutMs = 90_000,
): Promise<void> {
  const vault   = await ethers.getContractAt("PositionVault", vaultAddr);
  const adapter = new ethers.Contract(adapterAddr, GMX_ADAPTER_ABI, signer);

  const cleared = await pollUntil(
    async () => {
      const p = await vault.pending();
      return p.kind as bigint;
    },
    (kind) => kind === 0n,
    5_000,
    waitTimeoutMs,
  ).catch(() => null);

  if (cleared !== null) return;

  console.log("  ⚡ redeem 콜백 타임아웃 — settleGmxOrder fallback 호출…");
  const pending   = await vault.pending();
  const orderInfo = await (adapter as any).orders(pending.orderKey) as { gmxKey: string };
  await (await adapter.settleGmxOrder(orderInfo.gmxKey)).wait();
}

export async function waitForSettlement(
  vaultAddr: string,
  adapterAddr: string,
  signer: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  waitTimeoutMs = 90_000,
): Promise<void> {
  const vault   = await ethers.getContractAt("PositionVault", vaultAddr);
  const adapter = new ethers.Contract(adapterAddr, GMX_ADAPTER_ABI, signer);

  // GMX 콜백으로 자동 상태 전환 대기
  const settled = await pollUntil(
    () => vault.state() as Promise<bigint>,
    (s) => s !== VaultState.SettlingOpen && s !== VaultState.SettlingLiquidate,
    5_000,
    waitTimeoutMs,
  ).catch(() => null);

  if (settled !== null) return; // 콜백 성공

  // fallback: settleGmxOrder 수동 호출
  console.log("  ⚡ 콜백 타임아웃 — settleGmxOrder fallback 호출…");
  const pending   = await vault.pending();
  const orderInfo = await (adapter as any).orders(pending.orderKey) as { gmxKey: string };
  await (await adapter.settleGmxOrder(orderInfo.gmxKey)).wait();
}

/** GMX close/liquidate 주문 체결 대기 후 정산 */
export async function settlePendingOrder(
  vaultAddr: string,
  adapterAddr: string,
  signer: Awaited<ReturnType<typeof ethers.getSigners>>[0],
): Promise<void> {
  await waitForSettlement(vaultAddr, adapterAddr, signer);
}

/** oracle 초기 가격 복원 (배포 시 설정: 1650 USD) */
export async function resetOraclePrice(
  oracleAddr: string,
  oracleSigner: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  price8 = 1_650n * PRICE_ONE,
): Promise<void> {
  const oracle = await ethers.getContractAt("MockPriceOracle", oracleAddr, oracleSigner);
  await (await oracle.setPrice(price8)).wait();
}

/** oracle 현재 가격 조회 */
export async function getOraclePrice(oracleAddr: string): Promise<bigint> {
  const oracle = new ethers.Contract(oracleAddr, ORACLE_ABI, ethers.provider);
  return oracle.getPrice() as Promise<bigint>;
}

/**
 * vault를 Empty 상태로 만든다.
 * - Empty: 즉시 반환
 * - Active: 부채 전액 상환 → closePosition → GMX 콜백 대기 or settleGmxOrder fallback
 * - SettlingOpen/SettlingLiquidate: GMX 콜백 대기 or settleGmxOrder fallback
 */
export async function ensureEmptyVault(
  vaultAddr: string,
  owner: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  adapterAddr: string,
  rTokenAddr: string,
  helpers: Awaited<ReturnType<typeof ethers.getSigners>>[0][] = [],
): Promise<void> {
  const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);

  let state: bigint = await vault.state();

  if (state === VaultState.Empty) return;

  if (state === VaultState.SettlingOpen) {
    const pending = await vault.pending();
    const isLimitOrder = pending.kind === 4n; // OrderKind.LimitOpen
    try {
      await waitForSettlement(vaultAddr, adapterAddr, owner, isLimitOrder ? 60_000 : 90_000);
    } catch {
      if (isLimitOrder) {
        await (await vault.cancelLimitOrder()).wait();
        await waitAndCancelGmxOrder(vaultAddr, adapterAddr, owner);
      } else {
        throw new Error("ensureEmptyVault: market order stuck");
      }
    }
    state = await vault.state();
  }

  if (state === VaultState.SettlingLiquidate) {
    await waitForSettlement(vaultAddr, adapterAddr, owner);
    state = await vault.state();
  }

  if (state === VaultState.Active) {
    await repayAllDebt(vaultAddr, owner, rTokenAddr, helpers);
    await (await vault.closePosition({ value: EXEC_FEE })).wait();
    await waitForSettlement(vaultAddr, adapterAddr, owner);
    state = await vault.state();
  }

  if (state !== VaultState.Empty) {
    throw new Error(`ensureEmptyVault: still state=${state} after cleanup`);
  }
}

/**
 * deposit + openPosition(isLong) → GMX 콜백 자동 정산 or settleGmxOrder fallback → Active
 * vaultAddr는 이미 Empty 상태여야 한다.
 */
export async function openAndActivate(
  vaultAddr: string,
  owner: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  adapterAddr: string,
  usdcAddr: string,
  leverage: number,
  isLong: boolean,
): Promise<void> {
  const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
  const usdc = new ethers.Contract(usdcAddr, ERC20_ABI, owner);

  await (await usdc.approve(vaultAddr, DEPOSIT_USDC)).wait();
  await (await vault.deposit(DEPOSIT_USDC)).wait();
  await (await vault.openPosition(leverage, isLong, { value: EXEC_FEE })).wait();
  await waitForSettlement(vaultAddr, adapterAddr, owner);
}

/**
 * deposit + openLimitPosition(isLong, triggerPrice) → GMX 콜백 자동 정산 or settleGmxOrder fallback → Active
 *
 * 즉시 체결 보장 전략 (GMX 실제 오라클 가격 기준):
 *   롱 limit(buy):  triggerPrice = $1,000,000 → 현재 ETH 가격 ≤ 1M → 즉시 체결
 *   숏 limit(sell): triggerPrice = $1 wei     → 현재 ETH 가격 ≥ 1 wei → 즉시 체결
 */
export async function openLimitAndActivate(
  vaultAddr: string,
  owner: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  adapterAddr: string,
  usdcAddr: string,
  oracleAddr: string,
  leverage: number,
  isLong: boolean,
): Promise<bigint> {
  const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
  const usdc = new ethers.Contract(usdcAddr, ERC20_ABI, owner);

  const triggerPrice8 = isLong
    ? 1_000_000n * PRICE_ONE   // $1,000,000 — 항상 즉시 체결
    : 1n;                      // $0.00000001 — 항상 즉시 체결

  await (await usdc.approve(vaultAddr, DEPOSIT_USDC)).wait();
  await (await vault.deposit(DEPOSIT_USDC)).wait();
  await (await vault.openLimitPosition(leverage, triggerPrice8, isLong, { value: EXEC_FEE })).wait();
  await waitForSettlement(vaultAddr, adapterAddr, owner, 90_000);

  return triggerPrice8;
}

/**
 * GMX에 limit 취소를 요청한 뒤 처리될 때까지 대기.
 * GMX 콜백이 자동으로 Vault를 Empty로 전환하거나, 타임아웃 시 settleGmxOrder fallback 호출.
 * vault.cancelLimitOrder() 호출 이후에 사용.
 */
export async function waitAndCancelGmxOrder(
  vaultAddr: string,
  adapterAddr: string,
  signer: Awaited<ReturnType<typeof ethers.getSigners>>[0],
): Promise<void> {
  await waitForSettlement(vaultAddr, adapterAddr, signer, 60_000);
}

/** 테스트용 서브 계정에 ETH 전송 (가스) */
export async function fundEth(
  from: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  to: string,
  amount = ethers.parseEther("0.01"),
): Promise<void> {
  const bal = await ethers.provider.getBalance(to);
  if (bal < amount / 2n) {
    await (await from.sendTransaction({ to, value: amount })).wait();
  }
}

/** mint/redeem 테스트 전 부채 초기화. owner 잔액 부족 시 helper들에게서 rToken 회수 시도. */
export async function repayAllDebt(
  vaultAddr: string,
  owner: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  rTokenAddr: string,
  helpers: Awaited<ReturnType<typeof ethers.getSigners>>[0][] = [],
): Promise<void> {
  const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
  const debt: bigint = await vault.debt();
  if (debt === 0n) return;

  const ownerAddr = await owner.getAddress();
  const rToken = new ethers.Contract(rTokenAddr, RTOKEN_ABI, ethers.provider);

  let balance: bigint = await rToken.balanceOf(ownerAddr);
  if (balance < debt) {
    for (const h of helpers) {
      if (balance >= debt) break;
      const hAddr = await h.getAddress();
      const hBal: bigint = await rToken.balanceOf(hAddr);
      if (hBal === 0n) continue;
      const need = debt - balance;
      const pull = hBal < need ? hBal : need;
      const rTokenAsH = new ethers.Contract(rTokenAddr, RTOKEN_ABI, h);
      await (await rTokenAsH.transfer(ownerAddr, pull)).wait();
      balance += pull;
    }
  }

  const repayAmt = balance < debt ? balance : debt;
  if (repayAmt > 0n) {
    console.log(`  → Repaying debt: ${ethers.formatUnits(repayAmt, 18)} rToken`);
    await (await vault.repay(repayAmt)).wait();
  }
}
