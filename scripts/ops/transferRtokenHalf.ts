/**
 * Transfer 0.5 rETH from 0xde2E... to 0xF48b...
 *   npx hardhat run scripts/ops/transferRtokenHalf.ts --network arbitrumSepolia
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";

const FROM = "0xde2ED0a0dD147286a79fB01792B730E64d8b7185";
const TO = "0xF48b7D0Ba65a8DBC7ecaA6fE983078ecd73a470E";
const AMOUNT = ethers.parseEther("0.5");

async function main() {
  const dep = JSON.parse(
    await readFile(path.join(process.cwd(), "deployments", `${network.name}-gmx.json`), "utf8"),
  );
  const rTokenAddr: string = dep.markets.rETH.rToken;
  const signers = await ethers.getSigners();
  const signer = signers.find(async () => false) || signers[0];
  let fromSigner = null as Awaited<ReturnType<typeof ethers.getSigners>>[0] | null;
  for (const s of signers) {
    if ((await s.getAddress()).toLowerCase() === FROM.toLowerCase()) {
      fromSigner = s;
      break;
    }
  }
  console.log(
    "available signers:",
    await Promise.all(signers.map(async (s) => s.getAddress())),
  );
  if (!fromSigner) {
    throw new Error(
      `Signer for ${FROM} not available in Hardhat accounts. Add that key to the network accounts to transfer.`,
    );
  }
  const rToken = await ethers.getContractAt(
    ["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)", "function symbol() view returns (string)"],
    rTokenAddr,
    fromSigner,
  );
  const beforeFrom = await rToken.balanceOf(FROM);
  const beforeTo = await rToken.balanceOf(TO);
  console.log("symbol:", await rToken.symbol());
  console.log("from bal before:", ethers.formatEther(beforeFrom));
  console.log("to   bal before:", ethers.formatEther(beforeTo));
  if (beforeFrom < AMOUNT) throw new Error(`insufficient balance: have ${ethers.formatEther(beforeFrom)}, need 0.5`);
  const tx = await rToken.transfer(TO, AMOUNT);
  const rc = await tx.wait();
  console.log("tx:", rc?.hash);
  console.log("from bal after:", ethers.formatEther(await rToken.balanceOf(FROM)));
  console.log("to   bal after:", ethers.formatEther(await rToken.balanceOf(TO)));
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
