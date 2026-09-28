/**
 * VaultLens만 재배포 (factory 기존 유지). entry + liquidationPrice UI 필드.
 *
 *   npx hardhat run scripts/deploy/deployVaultLens.ts --network arbitrumSepolia
 */
import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const profile = process.env.DEPLOY_PROFILE || "arbitrumSepolia-gmx";
  const file = path.join(__dirname, `../../deployments/${profile}.json`);
  const dep = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!dep.vaultFactory) throw new Error(`vaultFactory missing in ${file}`);

  const [deployer] = await ethers.getSigners();
  console.log(`Deployer : ${await deployer.getAddress()}`);
  console.log(`Factory  : ${dep.vaultFactory}`);
  console.log(`Old Lens : ${dep.vaultLens || "(none)"}`);

  const Lens = await ethers.getContractFactory("VaultLens");
  const lens = await Lens.deploy(dep.vaultFactory);
  await lens.waitForDeployment();
  const addr = await lens.getAddress();
  console.log(`New Lens : ${addr}`);

  dep.vaultLens = addr;
  dep.updatedAt = new Date().toISOString();
  fs.writeFileSync(file, JSON.stringify(dep, null, 2) + "\n");
  console.log(`Wrote ${file}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
