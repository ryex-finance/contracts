import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import ERC20Abi from "../abi/ERC20.json";

async function main() {
  const MARKET = "rETH";
  const dep = JSON.parse(
    await readFile(path.join(process.cwd(), "deployments", `${network.name}-gmx.json`), "utf8"),
  );
  const [owner] = await ethers.getSigners();
  const ownerAddr = await owner.getAddress();
  const factory = await ethers.getContractAt("VaultFactory", dep.vaultFactory, owner);
  const lens = await ethers.getContractAt("VaultLens", dep.vaultLens, owner);
  const marketId = dep.markets[MARKET].marketId;

  console.log("Owner:", ownerAddr);

  for (const isLong of [false, true]) {
    const label = isLong ? "LONG vault" : "SHORT vault";
    const vaultAddr = await factory.vaultOf(ownerAddr, marketId, isLong);
    console.log(`\n=== ${label} ===`);
    console.log("address:", vaultAddr);
    if (vaultAddr === ethers.ZeroAddress) continue;

    const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    const gmx = await lens.gmxPosition(vaultAddr);
    const usdc = new ethers.Contract(dep.usdc, ERC20Abi, owner);
    console.log("state:", (await vault.state()).toString(), "(0=Empty 1=SettlingOpen 2=Active 3=SettlingLiquidate)");
    console.log("isLong:", await vault.isLong());
    console.log("collateral:", (await vault.collateral()).toString());
    console.log("posKey:", await vault.posKey());
    console.log("pending:", await vault.pending());
    console.log("GMX exists:", gmx.exists, "sizeInUsd:", gmx.sizeInUsd.toString());
    console.log("vault USDC:", (await usdc.balanceOf(vaultAddr)).toString());
    console.log("vault ETH:", (await ethers.provider.getBalance(vaultAddr)).toString());
  }

  /** GMX Reader — vault/owner 계정별 long·short raw 조회 **/
  const reader = await ethers.getContractAt("IGmxReader", dep.gmxReader, owner);
  const dataStore = dep.gmxDataStore;
  const gmxMarket = dep.markets.rETH.gmxMarket;
  const usdcAddr = dep.usdc;

  for (const [label, account] of [
    ["owner EOA", ownerAddr],
    ["short vault", await factory.vaultOf(ownerAddr, marketId, false)],
  ] as const) {
    if (account === ethers.ZeroAddress) continue;
    console.log(`\n=== GMX Reader: ${label} (${account}) ===`);
    for (const isLong of [false, true]) {
      const posKey = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(["address", "address", "address", "bool"], [
          account,
          gmxMarket,
          usdcAddr,
          isLong,
        ]),
      );
      try {
        const pos = await reader.getPosition(dataStore, posKey);
        const size = pos.numbers.sizeInUsd;
        console.log(`  ${isLong ? "LONG" : "SHORT"}: sizeInUsd=${size.toString()} collateral=${pos.numbers.collateralAmount.toString()}`);
      } catch (e) {
        console.log(`  ${isLong ? "LONG" : "SHORT"}: (no position)`);
      }
    }
  }
}

main().catch(console.error);
