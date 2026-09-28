/**
 * testIncreaseCallback.ts — 이미 Active인 vault에 소액 증액 주문을 넣고,
 * `settleGmxOrder`를 절대 수동 호출하지 않은 채 `afterOrderExecution` 콜백이
 * 저절로(GMX keeper에 의해) 호출돼 state가 SettlingOpen → Active로 돌아오는지 관찰한다.
 *
 *   npx hardhat run scripts/ops/testIncreaseCallback.ts --network arbitrumSepolia
 *
 * 환경변수:
 *   TEST_USDC (기본 2) — 증액할 USDC 금액
 *   WATCH_MS  (기본 180000) — 관찰 시간(ms)
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";

const MARKET = "rETH";
const IS_LONG = false;
const LEVERAGE = 1;
const TEST_USDC = process.env.TEST_USDC ?? "2";
const WATCH_MS = Number(process.env.WATCH_MS ?? 180_000);
const STATE_NAMES = ["Empty", "SettlingOpen", "Active", "SettlingLiquidate", "Liquidated"];
// GMX Keys.sol: keccak256(abi.encode(string)) — keccak256(toUtf8Bytes(...))는 다른 값 (2026-09-02 버그 수정)
const ACCOUNT_ORDER_LIST = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"]));

async function main() {
  const profile = process.env.DEPLOY_PROFILE ?? `${network.name}-gmx`;
  const dep = JSON.parse(await readFile(path.join(process.cwd(), "deployments", `${profile}.json`), "utf8"));
  const market = dep.markets[MARKET];

  const [owner] = await ethers.getSigners();
  const ownerAddr = await owner.getAddress();
  const factory = await ethers.getContractAt("VaultFactory", dep.vaultFactory, owner);
  const router = await ethers.getContractAt("RyexRouter", dep.ryexRouter, owner);
  const usdc = new ethers.Contract(dep.usdc, ERC20Abi, owner);
  const infra = await factory.gmxInfra();
  const execFee: bigint = infra.execFee;
  const dataStore = await ethers.getContractAt(
    ["function containsBytes32(bytes32,bytes32) view returns (bool)"],
    dep.gmxDataStore,
  );

  const vaultAddr: string = await factory.vaultOf(ownerAddr, market.marketId, IS_LONG);
  if (vaultAddr === ethers.ZeroAddress) throw new Error("vault not found");
  const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);

  const preState = Number(await vault.state());
  console.log(`Vault       : ${vaultAddr}`);
  console.log(`State before: ${STATE_NAMES[preState]}`);
  if (preState !== 2) throw new Error(`vault must be Active before test (got ${STATE_NAMES[preState]})`);
  const prePending = await vault.pending();
  if (prePending.kind !== 0n) throw new Error("vault already has a pending order — abort");

  const depositUsdc = ethers.parseUnits(TEST_USDC, 6);
  console.log(`Test amount : ${TEST_USDC} USDC (increase)`);

  const allowance: bigint = await usdc.allowance(ownerAddr, dep.ryexRouter);
  if (allowance < depositUsdc) {
    console.log("approving router…");
    await (await usdc.approve(dep.ryexRouter, ethers.MaxUint256)).wait();
  }

  console.log("router.deposit(增额)…");
  await (await router.deposit(market.marketId, IS_LONG, depositUsdc)).wait();

  console.log(`openPosition(increase) leverage=${LEVERAGE} short…`);
  const tx = await router.openPosition(market.marketId, IS_LONG, LEVERAGE, 0n, depositUsdc, { value: execFee });
  const rc = await tx.wait();
  console.log(`  tx: ${rc?.hash} (block ${rc?.blockNumber})`);

  const pending = await vault.pending();
  const order = await vault.gmxOrders(pending.orderKey);
  console.log(`ryex orderKey: ${pending.orderKey}`);
  console.log(`gmxKey       : ${order.gmxKey}`);
  console.log(`state after submit: ${STATE_NAMES[Number(await vault.state())]}`);

  const orderListKey = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
  );

  console.log(`\n--- 관찰 시작 (최대 ${WATCH_MS / 1000}s). settleGmxOrder는 호출하지 않습니다. ---`);
  const start = Date.now();
  const submitBlock = rc!.blockNumber;
  let lastState = -1;
  while (Date.now() - start < WATCH_MS) {
    const state = Number(await vault.state());
    const stillOnGmx: boolean = await dataStore.containsBytes32(orderListKey, order.gmxKey).catch(() => true);
    if (state !== lastState) {
      console.log(
        `  [+${Math.round((Date.now() - start) / 1000)}s] state=${STATE_NAMES[state]} gmxOrderStillPending=${stillOnGmx}`,
      );
      lastState = state;
    }
    if (state === 2) {
      console.log("\n✓ state가 Active로 자동 복귀했습니다 — afterOrderExecution 콜백이 정상 호출됐습니다.");
      const execEvents = await vault.queryFilter(vault.filters.GmxOrderExecuted(pending.orderKey), submitBlock);
      for (const ev of execEvents) {
        const txReceipt = await ev.getTransactionReceipt();
        console.log(`  GmxOrderExecuted tx=${ev.transactionHash} from=${txReceipt.from}`);
        console.log(`  (orderHandler=${infra.orderHandler} — from과 일치하면 실제 GMX 키퍼 콜백)`);
      }
      return;
    }
    if (state === 0 || state === 1) {
      // SettlingOpen 계속 유지 중이면 아래에서 타임아웃 처리
    }
    await new Promise((r) => setTimeout(r, 5_000));
  }

  console.log(`\n✗ ${WATCH_MS / 1000}초 동안 state가 Active로 돌아오지 않았습니다 (현재: ${STATE_NAMES[lastState]}).`);
  const stillOnGmx: boolean = await dataStore.containsBytes32(orderListKey, order.gmxKey).catch(() => true);
  console.log(`GMX 상 주문 아직 존재: ${stillOnGmx}`);
  if (!stillOnGmx) {
    console.log("→ GMX에서는 이미 처리 끝났는데 콜백이 안 온 것 — afterOrderExecution 미호출/실패로 판단됩니다.");
  } else {
    console.log("→ GMX 자체가 아직 주문을 처리 중입니다 (콜백 문제로 단정 짓기엔 이릅니다).");
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
