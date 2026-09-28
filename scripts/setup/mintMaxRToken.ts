/**
 * mintMaxRToken.ts — Active 숏 vault에서 rToken을 LTV headroom 한도까지 mint
 *
 *   npx hardhat run scripts/setup/mintMaxRToken.ts --network arbitrumSepolia
 *
 * 기본: rETH short vault. IS_LONG=1 이면 long.
 * headroom의 98% mint (라운딩으로 ExceedsMaxLTV 나는 것 방지 — test/ryex/mint.ts와 동일).
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";

const MARKET = process.env.MARKET ?? "rETH";
const IS_LONG = process.env.IS_LONG === "1";
const BPS = 10_000n;
const PRICE_ONE = 10n ** 8n;
/** headroom 사용 비율 (bps). 기본 9800 = 98% */
const HEADROOM_BPS = BigInt(process.env.HEADROOM_BPS ?? "9800");

async function main() {
  const profile = process.env.DEPLOY_PROFILE ?? `${network.name}-gmx`;
  const file = path.join(process.cwd(), "deployments", `${profile}.json`);
  const dep = JSON.parse(await readFile(file, "utf8"));
  const market = dep.markets?.[MARKET];
  if (!market?.marketId || !market?.rToken) {
    throw new Error(`markets.${MARKET} incomplete in ${file}`);
  }
  if (!dep.vaultFactory || !dep.vaultLens) {
    throw new Error(`vaultFactory/vaultLens missing in ${file}`);
  }

  const [owner] = await ethers.getSigners();
  const ownerAddr = await owner.getAddress();
  const factory = await ethers.getContractAt("VaultFactory", dep.vaultFactory, owner);
  const lens = await ethers.getContractAt("VaultLens", dep.vaultLens, owner);
  const rToken = new ethers.Contract(market.rToken, ERC20Abi, owner);

  const vaultAddr: string = await factory.vaultOf(ownerAddr, market.marketId, IS_LONG);
  if (vaultAddr === ethers.ZeroAddress) {
    throw new Error(`${IS_LONG ? "long" : "short"} vault not found for ${ownerAddr}`);
  }

  const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
  const state: bigint = await vault.state();
  if (state !== 2n) {
    throw new Error(`vault ${vaultAddr} state=${state} (need Active=2)`);
  }

  const [, oracleAddr] = await factory.markets(market.marketId);
  const oracle = await ethers.getContractAt(["function getPrice() view returns (uint256)"], oracleAddr, owner);
  const price8: bigint = await oracle.getPrice();

  const colVal: bigint = await lens.collateralValueUsdWad(vaultAddr);
  const debtVal: bigint = await lens.debtValueUsdWad(vaultAddr);
  const effMax: bigint = await lens.effectiveMaxLtvBps(vaultAddr);
  const maxDebt = (colVal * effMax) / BPS;
  const headroom = maxDebt > debtVal ? maxDebt - debtVal : 0n;
  if (headroom === 0n) throw new Error("no mint headroom");

  const mintUsdWad = (headroom * HEADROOM_BPS) / BPS;
  const mintAmount = (mintUsdWad * PRICE_ONE) / price8;
  if (mintAmount === 0n) throw new Error("mintAmount rounded to 0");

  const debtBefore: bigint = await vault.debt();
  const balBefore: bigint = await rToken.balanceOf(ownerAddr);
  const ltvBefore: bigint = await lens.currentLTV(vaultAddr);

  console.log(`Network   : ${network.name}`);
  console.log(`Owner     : ${ownerAddr}`);
  console.log(`Vault     : ${vaultAddr} (${IS_LONG ? "long" : "short"} ${MARKET})`);
  console.log(`rToken    : ${market.rToken}`);
  console.log(`price     : $${ethers.formatUnits(price8, 8)}`);
  console.log(`equity    : $${ethers.formatUnits(colVal, 18)}`);
  console.log(`debt USD  : $${ethers.formatUnits(debtVal, 18)}`);
  console.log(`effMaxLTV : ${effMax} bps`);
  console.log(`LTV before: ${ltvBefore === ethers.MaxUint256 ? "∞" : ltvBefore.toString()} bps`);
  console.log(`headroom  : $${ethers.formatUnits(headroom, 18)} (${HEADROOM_BPS} bps of it)`);
  console.log(`mint      : ${ethers.formatEther(mintAmount)} rToken`);

  await (await vault.mint(mintAmount)).wait();

  const debtAfter: bigint = await vault.debt();
  const balAfter: bigint = await rToken.balanceOf(ownerAddr);
  const ltvAfter: bigint = await lens.currentLTV(vaultAddr);

  console.log(`\n✓ minted`);
  console.log(`  debt     : ${ethers.formatEther(debtBefore)} → ${ethers.formatEther(debtAfter)} rToken`);
  console.log(`  balance  : ${ethers.formatEther(balBefore)} → ${ethers.formatEther(balAfter)} rToken`);
  console.log(`  LTV      : ${ltvAfter} / ${effMax} bps`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
