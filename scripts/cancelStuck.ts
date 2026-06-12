import { ethers } from "hardhat";
import * as fs from "fs";

async function main() {
  const [signer] = await ethers.getSigners();
  const deployment = JSON.parse(fs.readFileSync("deployments/arbitrumSepolia-gmx.json", "utf8"));
  
  const POSITION_VAULT_ABI = ["function state() view returns (uint8)", "function cancelLimitOrder() external", "function pending() view returns (bytes32 orderKey, uint8 kind)"];
  const GMX_ADAPTER_ABI = ["function cancelOrder(bytes32 orderKey) external", "function orders(bytes32) view returns (address vault, bytes32 gmxKey, bool executed)"];
  const DS_ABI = ["function containsBytes32(bytes32 setKey, bytes32 value) view returns (bool)"];
  
  const factory = await ethers.getContractAt("VaultFactory", deployment.vaultFactory, signer);
  const vaultAddr = await factory.vaultOf(await signer.getAddress(), deployment.markets["rETH"].marketId);
  
  if (vaultAddr === ethers.ZeroAddress) {
    console.log("No vault found");
    return;
  }
  
  const vault = new ethers.Contract(vaultAddr, POSITION_VAULT_ABI, signer);
  const state = await vault.state();
  console.log(`Vault: ${vaultAddr}, state: ${state}`);
  
  const STATE_NAMES = ["Empty", "SettlingOpen", "Active", "SettlingLiquidate", "Liquidated"];
  console.log(`State: ${STATE_NAMES[Number(state)]}`);
  
  if (Number(state) === 1) { // SettlingOpen
    const pending = await vault.pending();
    console.log(`Pending orderKey: ${pending.orderKey}`);
    
    const adapter = new ethers.Contract(deployment.gmxAdapter, GMX_ADAPTER_ABI, signer);
    const orderInfo = await adapter.orders(pending.orderKey);
    console.log(`GMX orderKey: ${orderInfo.gmxKey}`);
    
    const ds = new ethers.Contract(deployment.gmxDataStore, DS_ABI, ethers.provider);
    const listKey = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "address"],
        [ethers.keccak256(ethers.toUtf8Bytes("ACCOUNT_ORDER_LIST")), deployment.gmxAdapter],
      ),
    );
    const alive = await ds.containsBytes32(listKey, orderInfo.gmxKey);
    console.log(`GMX order alive: ${alive}`);
    
    if (alive) {
      console.log("Cancelling limit order...");
      const tx = await vault.cancelLimitOrder();
      const rc = await tx.wait();
      console.log(`cancelLimitOrder tx: ${rc?.hash}`);
      
      // Wait a bit for GMX to process
      await new Promise(r => setTimeout(r, 15000));
      
      const aliveAfter = await ds.containsBytes32(listKey, orderInfo.gmxKey).catch(() => false);
      console.log(`GMX order alive after cancel: ${aliveAfter}`);
      
      if (!aliveAfter) {
        console.log("Calling adapter.cancelOrder...");
        const tx2 = await adapter.cancelOrder(pending.orderKey);
        await tx2.wait();
        console.log(`adapter.cancelOrder done`);
        const newState = await vault.state();
        console.log(`New state: ${STATE_NAMES[Number(newState)]}`);
      }
    } else {
      // Already cancelled by GMX, just need adapter.cancelOrder
      console.log("GMX order already gone, calling adapter.cancelOrder...");
      const tx2 = await adapter.cancelOrder(pending.orderKey);
      await tx2.wait();
      const newState = await vault.state();
      console.log(`New state: ${STATE_NAMES[Number(newState)]}`);
    }
  }
}

main().catch(console.error);
