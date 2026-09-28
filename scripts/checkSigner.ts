import { ethers } from "hardhat";

async function main() {
  const [owner] = await ethers.getSigners();
  const addr = await owner.getAddress();
  const bal = await ethers.provider.getBalance(addr);
  console.log("signer:", addr);
  console.log("ETH:", ethers.formatEther(bal));
}

main();
