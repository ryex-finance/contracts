/**
 * redeployLpZap.ts — LpZap만 새로 배포하고 VaultFactory.setLpZap으로 교체.
 *
 * VaultFactory/rYield 등 나머지 스택은 그대로 둔 채 LpZap 컨트랙트 로직만 바뀌었을 때 사용
 * (예: increaseLiquidity 추가). 실행 전 반드시 기존 LpZap에 스테이킹된 liquidity/USDC가
 * 없는지 확인할 것 — 있으면 이 스크립트가 그 자금을 이관해주지 않는다(단순 스왑 교체용).
 *
 *   npx hardhat run scripts/setup/redeployLpZap.ts --network arbitrumSepolia
 */
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import { UNIV3 } from "../../config/gmxArbitrumSepolia";

async function main() {
  const profile = process.env.DEPLOY_PROFILE ?? `${network.name}-gmx`;
  const depFile = path.join(process.cwd(), "deployments", `${profile}.json`);
  const uniFile = path.join(process.cwd(), "deployments", `univ3.${network.name}.json`);
  const poolsFile = path.join(process.cwd(), "deployments", `pools.${network.name}.json`);

  const dep = JSON.parse(await readFile(depFile, "utf8"));
  const uni = JSON.parse(await readFile(uniFile, "utf8"));

  if (!dep.vaultFactory) throw new Error("deployments.vaultFactory missing");
  if (!dep.usdc) throw new Error("deployments.usdc missing");
  const npmAddr: string = uni.nonfungiblePositionManager ?? UNIV3.NPM;

  const vaultFactory = await ethers.getContractAt("VaultFactory", dep.vaultFactory);
  const oldLpZap: string = await vaultFactory.lpZap();
  console.log(`Network      : ${network.name}`);
  console.log(`VaultFactory : ${dep.vaultFactory}`);
  console.log(`Old LpZap    : ${oldLpZap}`);

  // 안전장치 — 옮길 자금/포지션이 있으면 그냥 덮어쓰면 안 되니 여기서 멈춘다.
  if (oldLpZap !== ethers.ZeroAddress) {
    const marketId = dep.markets?.rETH?.marketId;
    if (marketId) {
      const oldZap = await ethers.getContractAt("LpZap", oldLpZap);
      const staked: bigint = await oldZap.totalStakedLiquidity(marketId);
      if (staked > 0n) {
        throw new Error(
          `old LpZap still has ${staked} staked liquidity for market ${marketId} — this script does not migrate positions, aborting`,
        );
      }
    }
  }

  const LpZapF = await ethers.getContractFactory("LpZap");
  const lpZap = await LpZapF.deploy(dep.vaultFactory, npmAddr, dep.usdc);
  await lpZap.waitForDeployment();
  const lpZapAddr = await lpZap.getAddress();
  console.log(`New LpZap    : ${lpZapAddr}`);

  await (await vaultFactory.setLpZap(lpZapAddr)).wait();
  console.log(`VaultFactory.setLpZap ✓ (${lpZapAddr})`);

  dep.lpZap = lpZapAddr;
  dep.updatedAt = new Date().toISOString();
  await writeFile(depFile, `${JSON.stringify(dep, null, 2)}\n`);
  console.log(`✓ synced lpZap → ${depFile}`);

  try {
    const poolsOut = JSON.parse(await readFile(poolsFile, "utf8"));
    poolsOut.lpZap = lpZapAddr;
    await writeFile(poolsFile, `${JSON.stringify(poolsOut, null, 2)}\n`);
    console.log(`✓ synced lpZap → ${poolsFile}`);
  } catch {
    console.log(`(skip) ${poolsFile} not found`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
