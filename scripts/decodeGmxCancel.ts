import { readFile } from "node:fs/promises";
import type { InterfaceAbi } from "ethers";
import { ethers } from "hardhat";
import ERC20Abi from "../abi/ERC20.json";
import EventEmitterJson from "./lib/gmxEventEmitter.json";

const EVENT_EMITTER = "0xa973c2692C1556E1a3d478e745e9a75624AEDc73";

async function main() {
  const d = JSON.parse(await readFile("deployments/arbitrumSepolia-gmx.json", "utf8"));
  const [owner] = await ethers.getSigners();
  const mkt = d.markets.rETH;
  const factory = await ethers.getContractAt("VaultFactory", d.vaultFactory, owner);
  const router = await ethers.getContractAt("RyexRouter", d.ryexRouter, owner);
  const usdc = new ethers.Contract(d.usdc, ERC20Abi, owner);
  const infra = await factory.gmxInfra();
  const execFee: bigint = infra.execFee;
  const dep = 5n * 10n ** 6n;

  let vaultAddr = await factory.vaultOf(await owner.getAddress(), mkt.marketId, true);
  if (vaultAddr !== ethers.ZeroAddress) {
    const v = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    if ((await v.state()) === 0n && (await v.collateral()) > 0n) {
      await (await v.withdraw(await v.collateral())).wait();
    }
  }

  await (await usdc.approve(d.ryexRouter, dep)).wait();
  const rc = await (await router.openPosition(mkt.marketId, true, 1, 0n, dep, { value: execFee })).wait();
  vaultAddr = await factory.vaultOf(await owner.getAddress(), mkt.marketId, true);
  const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
  const order = await vault.gmxOrders((await vault.pending()).orderKey);
  const gmxKey = order.gmxKey as string;
  console.log("block", rc!.blockNumber, "gmxKey", gmxKey);

  const iface = new ethers.Interface(EventEmitterJson.abi as InterfaceAbi);
  const from = Number(rc!.blockNumber);
  const logs = await ethers.provider.getLogs({ address: EVENT_EMITTER, fromBlock: from, toBlock: from + 30 });

  for (const log of logs) {
    if (log.topics[2] !== gmxKey) continue;
    const p = iface.parseLog({ topics: log.topics as string[], data: log.data });
    if (!p) continue;
    console.log("\n===", p.args.eventName, "===");
    const ed = p.args.eventData;
    const dump = (label: string, group: { items: { key: string; value: unknown }[] }) => {
      for (const it of group.items) console.log(`  ${label}.${it.key}:`, it.value);
    };
    dump("addr", ed.addressItems);
    dump("uint", ed.uintItems);
    dump("bool", ed.boolItems);
    dump("str", ed.stringItems);
    dump("bytes", ed.bytesItems);
    for (const it of ed.bytesItems.items) {
      if (it.key === "reasonBytes" && it.value !== "0x") {
        try {
          const s = ethers.AbiCoder.defaultAbiCoder().decode(["string"], it.value as string)[0];
          console.log("  DECODED REASON:", s);
        } catch {
          console.log("  reasonBytes hex:", it.value);
        }
      }
    }
  }

  await new Promise((r) => setTimeout(r, 15000));
  console.log("\nfinal state", (await vault.state()).toString());
}

main().catch(console.error);
