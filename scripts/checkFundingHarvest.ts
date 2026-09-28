/**
 * GMX funding harvest 경로 온체인 검증 (read-only + staticCall).
 *   npx hardhat run scripts/checkFundingHarvest.ts --network arbitrumSepolia
 */
import { readFile } from "node:fs/promises";
import { ethers, network } from "hardhat";
import { dataStoreGetAddress, getGmxDataStore } from "./lib/gmxDataStore";

async function main() {
  const file = `deployments/${network.name}-gmx.json`;
  const dep = JSON.parse(await readFile(file, "utf8"));
  const vaultAddr: string | undefined = dep.ryieldVaults?.rETH;
  const gmxMarket: string = dep.markets.rETH.gmxMarket;
  const dsAddr: string = dep.gmxDataStore;

  const ds = await getGmxDataStore(dsAddr);
  const LONG = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["LONG_TOKEN"]));
  const SHORT = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["SHORT_TOKEN"]));
  const CLAIMABLE = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["CLAIMABLE_FUNDING_AMOUNT"]));

  const reader = await ethers.getContractAt(
    ["function getMarket(address dataStore, address key) view returns (tuple(address marketToken,address indexToken,address longToken,address shortToken))"],
    dep.gmxReader,
  );
  const marketProps = await reader.getMarket(dsAddr, gmxMarket);
  console.log("Reader.getMarket:");
  console.log("  marketToken:", marketProps.marketToken ?? marketProps[0]);
  console.log("  indexToken :", marketProps.indexToken ?? marketProps[1]);
  console.log("  longToken  :", marketProps.longToken ?? marketProps[2]);
  console.log("  shortToken :", marketProps.shortToken ?? marketProps[3]);

  const longTk = await dataStoreGetAddress(
    ds,
    ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["address", "bytes32"], [gmxMarket, LONG])),
  );
  const shortTk = await dataStoreGetAddress(
    ds,
    ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["address", "bytes32"], [gmxMarket, SHORT])),
  );

  console.log("Network     :", network.name);
  console.log("gmxMarket   :", gmxMarket);
  console.log("longToken   :", longTk);
  console.log("shortToken  :", shortTk);
  console.log("exchangeRouter:", dep.gmxExchangeRouter);

  if (!vaultAddr) {
    console.log("\nryieldVaults.rETH not deployed — skip vault checks");
    return;
  }

  const vaultLong = await ds.getUint(
    ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "address", "address", "address"],
        [CLAIMABLE, gmxMarket, longTk, vaultAddr],
      ),
    ),
  );
  const vaultShort = await ds.getUint(
    ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "address", "address", "address"],
        [CLAIMABLE, gmxMarket, shortTk, vaultAddr],
      ),
    ),
  );

  const vault = await ethers.getContractAt("RYieldVault", vaultAddr);
  const fd = await vault.fundingDistributor();

  console.log("\nvault       :", vaultAddr);
  console.log("distributor :", fd);
  console.log("claimable long  (vault):", vaultLong.toString());
  console.log("claimable short (vault):", vaultShort.toString());

  if (fd !== ethers.ZeroAddress) {
    const dist = await ethers.getContractAt("RYieldFundingDistributor", fd);
    console.log("dist.longToken :", await dist.longToken());
    console.log("dist.shortToken:", await dist.shortToken());
    console.log("long match :", (await dist.longToken()) === longTk);
    console.log("short match:", (await dist.shortToken()) === shortTk);
  }

  try {
    await vault.harvestFunding.staticCall();
    console.log("\nharvestFunding staticCall: OK (would succeed)");
  } catch (e: unknown) {
    const err = e as { shortMessage?: string; message?: string };
    console.log("\nharvestFunding staticCall:", err.shortMessage ?? err.message?.slice(0, 240));
  }
}

main().catch(console.error);
