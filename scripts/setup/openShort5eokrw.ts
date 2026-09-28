/**
 * openShort5eokrw.ts — 배포된 Ryex로 rETH 숏 1x 오픈 (원화 5억원 상당)
 *
 *   npx hardhat run scripts/setup/openShort5eokrw.ts --network arbitrumSepolia
 *
 * 환율: KRW_PER_USD 환경변수(기본 1422 ≈ 2026-08-06 open.er-api)
 *   5억 KRW / 1422 ≈ 351,618 USDC → 1x면 담보 = 사이즈
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";

const MARKET = "rETH";
const IS_LONG = false;
const LEVERAGE = 1;
const TARGET_KRW = 500_000_000; // 5억원
/** KRW per 1 USD — override: KRW_PER_USD=1400 */
const KRW_PER_USD = Number(process.env.KRW_PER_USD ?? "1422");
const SETTLE_TIMEOUT_MS = 180_000;
// GMX Keys.sol: keccak256(abi.encode(string)) — keccak256(toUtf8Bytes(...))는 다른 값 (2026-09-02 버그 수정)
const ACCOUNT_ORDER_LIST = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"]));

async function waitSettle(
  vault: Awaited<ReturnType<typeof ethers.getContractAt>>,
  _dataStore: Awaited<ReturnType<typeof ethers.getContractAt>>,
  _orderListKey: string,
  wantStates: bigint[],
) {
  const deadline = Date.now() + SETTLE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const state: bigint = await vault.state();
    if (wantStates.includes(state)) return state;
    // GMX OrderHandler 콜백만 대기 — settleGmxOrder 미사용
    await new Promise((r) => setTimeout(r, 5_000));
  }
  throw new Error(`settle timeout — vault state=${await vault.state()}`);
}

async function main() {
  const profile = process.env.DEPLOY_PROFILE ?? `${network.name}-gmx`;
  const file = path.join(process.cwd(), "deployments", `${profile}.json`);
  const dep = JSON.parse(await readFile(file, "utf8"));
  const market = dep.markets?.[MARKET];
  if (!market?.marketId) throw new Error(`markets.${MARKET} missing in ${file}`);
  if (!dep.ryexRouter || !dep.vaultFactory || !dep.usdc) {
    throw new Error(`ryexRouter/vaultFactory/usdc missing in ${file}`);
  }

  const usdHuman = TARGET_KRW / KRW_PER_USD;
  const depositUsdc = ethers.parseUnits(usdHuman.toFixed(6), 6);

  const [owner] = await ethers.getSigners();
  const ownerAddr = await owner.getAddress();
  const factory = await ethers.getContractAt("VaultFactory", dep.vaultFactory, owner);
  const router = await ethers.getContractAt("RyexRouter", dep.ryexRouter, owner);
  const lens = await ethers.getContractAt("VaultLens", dep.vaultLens, owner);
  const usdc = new ethers.Contract(dep.usdc, ERC20Abi, owner);
  const infra = await factory.gmxInfra();
  const execFee: bigint = infra.execFee;
  const dataStore = await ethers.getContractAt(
    ["function containsBytes32(bytes32,bytes32) view returns (bool)"],
    dep.gmxDataStore,
  );

  const bal: bigint = await usdc.balanceOf(ownerAddr);
  console.log(`Network     : ${network.name}`);
  console.log(`Deployer    : ${ownerAddr}`);
  console.log(`Target      : ₩${TARGET_KRW.toLocaleString()} @ ${KRW_PER_USD} KRW/USD`);
  console.log(`Deposit     : ${ethers.formatUnits(depositUsdc, 6)} USDC (1x short → size ≈ same)`);
  console.log(`USDC balance: ${ethers.formatUnits(bal, 6)}`);
  if (bal < depositUsdc) throw new Error("insufficient USDC");

  let vaultAddr: string = await factory.vaultOf(ownerAddr, market.marketId, IS_LONG);
  if (vaultAddr !== ethers.ZeroAddress) {
    const existing = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    const st: bigint = await existing.state();
    if (st === 2n) {
      throw new Error(`short vault already Active (${vaultAddr}) — close first`);
    }
    if (st === 1n || st === 3n) {
      throw new Error(`short vault settling (state=${st}) — wait/cancel first`);
    }
    if (st === 0n) {
      const idle: bigint = await usdc.balanceOf(vaultAddr);
      const col: bigint = await existing.collateral();
      if (idle > 0n || col > 0n) {
        const withdrawAmt = col > 0n ? col : idle;
        console.log(`withdrawing leftover ${ethers.formatUnits(withdrawAmt, 6)} USDC from empty vault`);
        await (await existing.withdraw(withdrawAmt)).wait();
      }
    }
  }

  const allowance: bigint = await usdc.allowance(ownerAddr, dep.ryexRouter);
  if (allowance < depositUsdc) {
    await (await usdc.approve(dep.ryexRouter, ethers.MaxUint256)).wait();
  }

  console.log("deposit…");
  await (await router.deposit(market.marketId, IS_LONG, depositUsdc)).wait();
  vaultAddr = await factory.vaultOf(ownerAddr, market.marketId, IS_LONG);
  const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
  console.log(`Vault       : ${vaultAddr}`);

  console.log(`openPosition leverage=${LEVERAGE} short market…`);
  await (await router.openPosition(market.marketId, IS_LONG, LEVERAGE, 0n, depositUsdc, { value: execFee })).wait();

  const orderListKey = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
  );
  const pending = await vault.pending();
  const order = await vault.gmxOrders(pending.orderKey);
  console.log(`pendingKey  : ${pending.orderKey}`);
  console.log(`gmxKey      : ${order.gmxKey}`);
  console.log("waiting GMX settle…");

  await waitSettle(vault, dataStore, orderListKey, [2n]);

  const gmx = await lens.gmxPosition(vaultAddr);
  const sizeUsd = Number(gmx.sizeInUsd) / 1e30;
  const col = await vault.collateral();
  console.log(`\n✓ Active short`);
  console.log(`  collateral : ${ethers.formatUnits(col, 6)} USDC`);
  console.log(`  sizeInUsd  : $${sizeUsd.toLocaleString(undefined, { maximumFractionDigits: 2 })}`);
  console.log(`  ≈ ₩${Math.round(sizeUsd * KRW_PER_USD).toLocaleString()} @ ${KRW_PER_USD}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
