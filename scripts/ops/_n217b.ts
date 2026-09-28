import { ethers } from "hardhat";

const USER = "0xF48b7D0Ba65a8DBC7ecaA6fE983078ecd73a470E".toLowerCase();
const ROUTER = "0xb6B5a2AB45f93B2538c997f994107f2a00C2678C";
const END = 304946689;
const START = 304940545;

async function main() {
  const p = ethers.provider;
  const router = await ethers.getContractAt("RyexRouter", ROUTER);
  const found: any[] = [];
  // scan backwards from success tx, 400-block chunks, stop when nonce 217 found
  const chunk = 80;
  for (let to = END; to > START; to -= chunk) {
    const from = Math.max(START, to - chunk + 1);
    for (let bn = to; bn >= from; bn--) {
      const block = await p.getBlock(bn, true);
      const list = block!.prefetchedTransactions?.length
        ? block!.prefetchedTransactions
        : await Promise.all(block!.transactions.map((h: any) => (typeof h === "string" ? p.getTransaction(h) : Promise.resolve(h))));
      for (const tx of list) {
        if (!tx || tx.from?.toLowerCase() !== USER) continue;
        if (tx.nonce !== 217 && tx.nonce !== 214) continue;
        const rc = await p.getTransactionReceipt(tx.hash);
        let fn = "?";
        try { fn = router.interface.parseTransaction({ data: tx.data })?.name ?? "?"; } catch {
          fn = (tx.to || "").slice(0, 14);
        }
        const row = {
          nonce: tx.nonce,
          status: rc?.status,
          fn,
          value: ethers.formatEther(tx.value),
          to: tx.to,
          hash: tx.hash,
          block: bn,
          gasUsed: rc?.gasUsed?.toString(),
        };
        console.log("FOUND", row);
        found.push(row);
        if (tx.nonce === 217 && rc?.status === 0) {
          try {
            await p.call({ to: tx.to!, from: tx.from, data: tx.data, value: tx.value }, bn);
          } catch (e: any) {
            console.log("revert:", e.shortMessage || e.reason || e.message?.slice(0, 400));
            try {
              const parsed = router.interface.parseTransaction({ data: tx.data, value: tx.value });
              console.log("failed fn", parsed?.name);
              parsed?.fragment.inputs.forEach((inp, i) => {
                let v: any = parsed.args[i];
                if (typeof v === "bigint") v = v.toString();
                console.log(" ", inp.name, v);
              });
            } catch {}
          }
        }
      }
    }
    if (found.some((f) => f.nonce === 217)) break;
    console.log("scanned", from, "..", to, "no 217 yet");
  }
  if (!found.some((f) => f.nonce === 217)) console.log("nonce 217 not found in window");
}
main().catch((e) => { console.error(e); process.exit(1); });
