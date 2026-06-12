import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import { ERC20PresetMinterPauser__factory } from "../typechain-types";

type TokenSpec = {
  name: string;
  symbol: string;
};

const TOKENS: TokenSpec[] = [
  { name: "Ryex Bitcoin", symbol: "rBTC" },
  { name: "Ryex Ether", symbol: "rETH" },
  { name: "Ryex Hyperliquid", symbol: "rHYPE" },
  { name: "Ryex Solana", symbol: "rSOL" },
  { name: "USD Coin", symbol: "USDC" },
];

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();

  console.log(`network=${network.name}`);
  console.log(`deployer=${deployerAddress}`);

  const deployed: Record<string, string> = {};
  for (const token of TOKENS) {
    const instance = await new ERC20PresetMinterPauser__factory(deployer).deploy(token.name, token.symbol);
    await instance.waitForDeployment();
    const addr = await instance.getAddress();
    deployed[token.symbol] = addr;
    console.log(`${token.symbol}=${addr}`);
  }

  const outDir = path.join(process.cwd(), "deployments");
  await mkdir(outDir, { recursive: true });

  const outPath = path.join(outDir, `tokens.${network.name}.json`);
  let existing: Record<string, unknown> = {};
  try {
    existing = JSON.parse(await readFile(outPath, "utf8")) as Record<string, unknown>;
  } catch {}

  const output = {
    ...existing,
    network: network.name,
    deployer: deployerAddress,
    tokens: {
      ...(typeof existing.tokens === "object" && existing.tokens !== null ? (existing.tokens as object) : {}),
      ...deployed,
    },
  };

  await writeFile(outPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
  console.log(`saved=${outPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
