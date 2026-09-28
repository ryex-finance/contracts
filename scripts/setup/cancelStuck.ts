import { ethers } from "hardhat";
import * as fs from "fs";

async function main() {
  const [signer] = await ethers.getSigners();
  const deployment = JSON.parse(fs.readFileSync("deployments/arbitrumSepolia-gmx.json", "utf8"));

  const DS_ABI = ["function containsBytes32(bytes32 setKey, bytes32 value) view returns (bool)"];

  const factory = await ethers.getContractAt("VaultFactory", deployment.vaultFactory, signer);
  const vaultAddr = await factory.vaultOf(await signer.getAddress(), deployment.markets["rETH"].marketId, false);

  if (vaultAddr === ethers.ZeroAddress) {
    console.log("No vault found");
    return;
  }

  const vault = await ethers.getContractAt("PositionVault", vaultAddr, signer);
  const state = await vault.state();
  console.log(`Vault: ${vaultAddr}, state: ${state}`);

  const STATE_NAMES = ["Empty", "SettlingOpen", "Active", "SettlingLiquidate", "Liquidated"];
  console.log(`State: ${STATE_NAMES[Number(state)]}`);

  if (Number(state) === 1) {
    // SettlingOpen
    const pending = await vault.pending();
    console.log(`Pending orderKey: ${pending.orderKey}`);

    const order = await vault.gmxOrders(pending.orderKey);
    const gmxKey = order.gmxKey as string;
    console.log(`GMX orderKey: ${gmxKey}`);

    const ds = new ethers.Contract(deployment.gmxDataStore, DS_ABI, ethers.provider);
    // GMX Keys.sol: keccak256(abi.encode(string)) — keccak256(toUtf8Bytes(...))는 다른 값이었음
    // (2026-09-02 버그 수정). 이전엔 containsBytes32가 항상 false라 "GMX order already gone"으로
    // 오판, 실제 GMX에 주문이 살아있어도 즉시 settleGmxOrder를 호출하는 위험이 있었음.
    const listKey = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "address"],
        [ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"])), vaultAddr],
      ),
    );
    const alive = gmxKey !== ethers.ZeroHash ? await ds.containsBytes32(listKey, gmxKey) : false;
    console.log(`GMX order alive: ${alive}`);

    if (alive) {
      console.log("Cancelling limit order...");
      const tx = await vault.cancelLimitOrder();
      const rc = await tx.wait();
      console.log(`cancelLimitOrder tx: ${rc?.hash}`);

      await new Promise((r) => setTimeout(r, 15000));

      const aliveAfter = await ds.containsBytes32(listKey, gmxKey).catch(() => false);
      console.log(`GMX order alive after cancel: ${aliveAfter}`);

      if (!aliveAfter && gmxKey !== ethers.ZeroHash) {
        console.log("Calling vault.settleGmxOrder...");
        const tx2 = await vault.settleGmxOrder(gmxKey);
        await tx2.wait();
        console.log(`settleGmxOrder done`);
        const newState = await vault.state();
        console.log(`New state: ${STATE_NAMES[Number(newState)]}`);
      }
    } else if (gmxKey !== ethers.ZeroHash) {
      console.log("GMX order already gone, calling vault.settleGmxOrder...");
      const tx2 = await vault.settleGmxOrder(gmxKey);
      await tx2.wait();
      const newState = await vault.state();
      console.log(`New state: ${STATE_NAMES[Number(newState)]}`);
    }
  }
}

main().catch(console.error);
