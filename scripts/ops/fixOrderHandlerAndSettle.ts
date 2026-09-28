/**
 * fixOrderHandlerAndSettle.ts — OrderHandler 주소 갱신 + stuck vault admin settle 복구
 *
 * 정상 경로: GMX OrderHandler 콜백.
 * settleGmxOrder: PositionVault는 factory.owner()만.
 *
 *   npx hardhat run scripts/ops/fixOrderHandlerAndSettle.ts --network arbitrumSepolia
 */
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";

const NEW_ORDER_HANDLER = "0xC881c2391611829d7bc81c12a285cB0201F08f8c";
const MARKET = "rETH";
const IS_LONG = false;
const STATE_NAMES = ["Empty", "SettlingOpen", "Active", "SettlingLiquidate", "Liquidated"];

async function main() {
  const profile = process.env.DEPLOY_PROFILE ?? `${network.name}-gmx`;
  const file = path.join(process.cwd(), "deployments", `${profile}.json`);
  const dep = JSON.parse(await readFile(file, "utf8"));

  const [signer] = await ethers.getSigners();
  const factory = await ethers.getContractAt("VaultFactory", dep.vaultFactory, signer);

  const before = await factory.gmxInfra();
  console.log("현재 orderHandler:", before.orderHandler);
  if (before.orderHandler.toLowerCase() === NEW_ORDER_HANDLER.toLowerCase()) {
    console.log("이미 최신 orderHandler로 설정되어 있습니다. setGmxInfra 스킵.");
  } else {
    console.log("새 orderHandler   :", NEW_ORDER_HANDLER);
    const tx = await factory.setGmxInfra({
      exchangeRouter: before.exchangeRouter,
      gmxRouter: before.gmxRouter,
      orderVault: before.orderVault,
      reader: before.reader,
      dataStore: before.dataStore,
      orderHandler: NEW_ORDER_HANDLER,
      execFee: before.execFee,
      acceptablePriceMax: before.acceptablePriceMax,
      acceptablePriceMin: before.acceptablePriceMin,
    });
    const rc = await tx.wait();
    console.log(`setGmxInfra tx: ${rc?.hash}`);

    const after = await factory.gmxInfra();
    console.log("확인된 orderHandler:", after.orderHandler);
    if (after.orderHandler.toLowerCase() !== NEW_ORDER_HANDLER.toLowerCase()) {
      throw new Error("orderHandler 업데이트 실패");
    }
  }

  // ── 스턱된 vault 정산 ──
  const market = dep.markets[MARKET];
  const ownerAddr = await signer.getAddress();
  const vaultAddr: string = await factory.vaultOf(ownerAddr, market.marketId, IS_LONG);
  if (vaultAddr === ethers.ZeroAddress) {
    console.log("\nvault 없음 — 정산 스킵");
    return;
  }
  const vault = await ethers.getContractAt("PositionVault", vaultAddr, signer);
  const state = Number(await vault.state());
  console.log(`\nVault: ${vaultAddr}, state=${STATE_NAMES[state]}`);

  if (state !== 1 && state !== 3) {
    console.log("SettlingOpen/SettlingLiquidate 아님 — 정산 불필요.");
    return;
  }
  const pending = await vault.pending();
  if (pending.orderKey === ethers.ZeroHash) {
    console.log("pending 주문 없음.");
    return;
  }
  const order = await vault.gmxOrders(pending.orderKey);
  console.log(`pending gmxKey: ${order.gmxKey}, executed=${order.executed}`);
  if (order.gmxKey === ethers.ZeroHash) {
    console.log("mock-only 주문 — settleGmxOrder 대상 아님.");
    return;
  }

  console.log("settleGmxOrder 호출…");
  const tx2 = await vault.settleGmxOrder(order.gmxKey);
  const rc2 = await tx2.wait();
  console.log(`settleGmxOrder tx: ${rc2?.hash}`);
  console.log(`새 state: ${STATE_NAMES[Number(await vault.state())]}`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
