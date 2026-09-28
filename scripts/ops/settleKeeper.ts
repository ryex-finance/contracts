/**
 * settleKeeper.ts — 콜백 누락 vault 수동 복구 툴
 *
 * 정상 경로: GMX OrderHandler → afterOrderExecution / afterOrderCancellation
 * 이 스크립트: settleGmxOrder(gmxKey)
 *
 * PositionVault: factory.owner()(프로토콜 관리자)만 settle 가능
 * RYieldVault: vault owner만 settle 가능
 *
 *   npx hardhat run scripts/ops/settleKeeper.ts --network arbitrumSepolia
 *   ONCE=1 ...   # 1회 스캔
 *   FORCE=1 ...  # orderHandler 있어도 강제 스캔
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";

const STATE_NAMES = ["Empty", "SettlingOpen", "Active", "SettlingLiquidate", "Liquidated"];
const POLL_INTERVAL_MS = Number(process.env.POLL_INTERVAL_MS ?? 15_000);
const RUN_ONCE = process.env.ONCE === "1";
const FORCE = process.env.FORCE === "1";

const DATASTORE_ABI = ["function containsBytes32(bytes32 setKey, bytes32 value) view returns (bool)"];
// GMX Keys.sol: keccak256(abi.encode(string))
const ACCOUNT_ORDER_LIST = ethers.keccak256(
  ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"]),
);

async function loadDeployment() {
  const file = path.join(process.cwd(), "deployments", `${network.name}-gmx.json`);
  return JSON.parse(await readFile(file, "utf8"));
}

async function scanOnce(dep: any, signer: Awaited<ReturnType<typeof ethers.provider.getSigner>>) {
  const factory = await ethers.getContractAt("VaultFactory", dep.vaultFactory, signer);
  const infra = await factory.gmxInfra();
  if (infra.orderHandler !== ethers.ZeroAddress && !FORCE) {
    console.log(
      `orderHandler=${infra.orderHandler} — 평소엔 GMX 콜백 사용. stuck 복구면 FORCE=1 로 실행.`,
    );
    return;
  }
  if (infra.dataStore === ethers.ZeroAddress) {
    console.log("dataStore 미설정 — 스킵");
    return;
  }

  const ds = new ethers.Contract(dep.gmxDataStore ?? infra.dataStore, DATASTORE_ABI, ethers.provider);
  const total = Number(await factory.totalVaults());
  const signerAddr = await signer.getAddress();
  const factoryOwner: string = await factory.owner();
  const isFactoryOwner = factoryOwner.toLowerCase() === signerAddr.toLowerCase();
  console.log(
    `[${new Date().toISOString()}] scanning ${total} vault(s) as ${signerAddr}` +
      ` (factory.owner=${factoryOwner}, isFactoryOwner=${isFactoryOwner})...`,
  );

  for (let i = 0; i < total; i++) {
    const vaultAddr: string = await factory.vaultAt(i);
    const vault = await ethers.getContractAt("PositionVault", vaultAddr, signer);
    const state = Number(await vault.state());
    if (state !== 1 && state !== 3) continue;

    // PositionVault.settleGmxOrder는 factory.owner()만 허용
    if (!isFactoryOwner) {
      console.log(`  skip ${vaultAddr} — settleGmxOrder requires factory.owner()`);
      continue;
    }

    const pending = await vault.pending();
    if (pending.orderKey === ethers.ZeroHash) continue;
    const order = await vault.gmxOrders(pending.orderKey);
    const gmxKey: string = order.gmxKey;
    if (gmxKey === ethers.ZeroHash || order.executed) continue;

    const orderListKey = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
    );
    const stillOnGmx: boolean = await ds.containsBytes32(orderListKey, gmxKey);
    if (stillOnGmx) {
      console.log(`  skip ${vaultAddr} — GMX order still pending (cancelLimitOrder / wait keeper)`);
      continue;
    }

    console.log(`  ${vaultAddr} — ${STATE_NAMES[state]} → settleGmxOrder(${gmxKey})`);
    try {
      const tx = await vault.settleGmxOrder(gmxKey);
      console.log(`    tx ${(await tx.wait())?.hash}`);
    } catch (e) {
      console.log(`    fail: ${(e as Error).message?.slice(0, 200)}`);
    }
  }
}

async function main() {
  const dep = await loadDeployment();
  const [signer] = await ethers.getSigners();
  if (RUN_ONCE) {
    await scanOnce(dep, signer);
    return;
  }
  for (;;) {
    await scanOnce(dep, signer);
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
