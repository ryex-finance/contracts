import { ethers } from "hardhat";
const USER = "0xF48b7D0Ba65a8DBC7ecaA6fE983078ecd73a470E".toLowerCase();
const ROUTER = "0xb6B5a2AB45f93B2538c997f994107f2a00C2678C";
async function main() {
  const p = ethers.provider;
  const router = await ethers.getContractAt("RyexRouter", ROUTER);
  // only ~3 min after long cancel (~360 blocks at ~0.25s)
  const from = 304940545;
  const to = 304941000;
  console.log("scan", from, to);
  for (let bn = from; bn <= to; bn++) {
    const block = await p.getBlock(bn, true);
    const list = block!.prefetchedTransactions?.length
      ? block!.prefetchedTransactions
      : [];
    const txs = list.length ? list : await Promise.all(block!.transactions.map((h:any)=>typeof h==="string"?p.getTransaction(h):h));
    for (const tx of txs) {
      if (!tx || tx.from?.toLowerCase() !== USER) continue;
      if (tx.nonce < 216 || tx.nonce > 218) continue;
      const rc = await p.getTransactionReceipt(tx.hash);
      let fn="?";
      try { fn = router.interface.parseTransaction({data:tx.data})?.name ?? "?"; } catch { fn=(tx.to||"").slice(0,14); }
      console.log({nonce:tx.nonce,status:rc?.status,fn,value:ethers.formatEther(tx.value),to:tx.to,hash:tx.hash,block:bn});
      if (tx.nonce===217 && rc?.status===0) {
        try { await p.call({to:tx.to!,from:tx.from,data:tx.data,value:tx.value}, bn); }
        catch(e:any){ console.log("revert", e.shortMessage||e.message?.slice(0,300)); }
      }
    }
  }
}
main().catch(e=>{console.error(e);process.exit(1);});
