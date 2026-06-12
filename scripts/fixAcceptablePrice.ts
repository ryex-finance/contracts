/**
 * fixAcceptablePrice.ts — 배포된 GmxV2Adapter의 acceptablePriceMax를 MaxUint256으로 수정
 *
 * 문제:
 *   acceptablePriceMax = 1e30 = $1 USD (GMX v2 가격 포맷: price_usd × 1e30)
 *   롱 open 시 "최대 $1에 체결" 조건 → ETH $1650에서 항상 GMX 취소
 *
 * 수정:
 *   acceptablePriceMax = MaxUint256 → 어떤 가격이든 체결
 *
 * 실행:
 *   npx hardhat run scripts/fixAcceptablePrice.ts --network arbitrumSepolia
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";

async function main() {
  const [signer] = await ethers.getSigners();
  const addrFile = path.join(process.cwd(), "deployments", `${network.name}-gmx.json`);
  const deployment = JSON.parse(await readFile(addrFile, "utf-8"));
  const adapterAddr = deployment.gmxAdapter as string;

  const adapter = await ethers.getContractAt("GmxV2Adapter", adapterAddr, signer);

  const before = await (adapter as any).acceptablePriceMax();
  console.log("현재 acceptablePriceMax:", before.toString());
  console.log("  → 1e30 = $1 USD (GMX 30dec 포맷), ETH $1650 = 1650e30");
  console.log("  → 이 값이 너무 낮아서 롱 주문이 즉시 취소됐습니다");

  const tx = await (adapter as any).setAcceptablePrices(ethers.MaxUint256, 1n);
  await tx.wait();
  console.log("\n✅ setAcceptablePrices(MaxUint256, 1) 완료 tx:", tx.hash);

  const after = await (adapter as any).acceptablePriceMax();
  const isMax = after === ethers.MaxUint256;
  console.log("새 acceptablePriceMax:", isMax ? "MaxUint256 ✅" : after.toString());
  console.log("새 acceptablePriceMin:", (await (adapter as any).acceptablePriceMin()).toString());
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
