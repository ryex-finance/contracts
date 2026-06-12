/**
 * transferOracleOwnership.ts — MockPriceOracle owner를 지정 주소로 이전
 *
 * 실행:
 *   npx hardhat run scripts/transferOracleOwnership.ts --network arbitrumSepolia
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";

const NEW_OWNER = "0xDC7fCD25178a32ED003558d57e59E1C62B47C717";

const ORACLE_ABI = [
  "function owner() view returns (address)",
  "function transferOwnership(address to) external",
];

interface Deployment {
  markets: Record<string, { oracle: string }>;
}

async function main() {
  const [signer] = await ethers.getSigners();
  const signerAddr = await signer.getAddress();

  const deploymentsPath = path.join(
    process.cwd(),
    "deployments",
    `${network.name}-gmx.json`,
  );
  const deployment = JSON.parse(await readFile(deploymentsPath, "utf8")) as Deployment;

  console.log(`Network   : ${network.name}`);
  console.log(`Signer    : ${signerAddr}`);
  console.log(`New owner : ${NEW_OWNER}\n`);

  const entries = Object.entries(deployment.markets ?? {});
  if (entries.length === 0) {
    throw new Error(`no markets found in ${deploymentsPath}`);
  }

  for (const [symbol, mkt] of entries) {
    const oracle = new ethers.Contract(mkt.oracle, ORACLE_ABI, signer);
    const curOwner: string = await oracle.owner();

    console.log(`── ${symbol} oracle=${mkt.oracle}`);
    console.log(`   current owner: ${curOwner}`);

    if (curOwner.toLowerCase() !== signerAddr.toLowerCase()) {
      throw new Error(`${symbol}: signer is not owner (owner=${curOwner})`);
    }
    if (curOwner.toLowerCase() === NEW_OWNER.toLowerCase()) {
      console.log(`   skip: already owned by ${NEW_OWNER}`);
      continue;
    }

    const tx = await oracle.transferOwnership(NEW_OWNER);
    const rc = await tx.wait();
    const newOwner: string = await oracle.owner();

    console.log(`   tx: ${rc?.hash}`);
    console.log(`   new owner: ${newOwner}`);
    if (newOwner.toLowerCase() !== NEW_OWNER.toLowerCase()) {
      throw new Error(`${symbol}: ownership transfer failed`);
    }
  }

  console.log("\n✓ 완료");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
