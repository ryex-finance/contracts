/**
 * smokeSwapRethUsdc.ts — rETH/USDC UniV3 풀 극소량 스왑 스모크 테스트
 *
 *   npx hardhat run scripts/setup/smokeSwapRethUsdc.ts --network arbitrumSepolia
 *
 * 기본: 0.1 USDC → rETH (AMOUNT_USDC=0.1 로 변경 가능)
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";

const MARKET = "rETH";
const AMOUNT_USDC = process.env.AMOUNT_USDC ?? "0.1";

const SWAP_ROUTER_ABI = [
  "function exactInputSingle((address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 deadline,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)) payable returns (uint256 amountOut)",
];

async function main() {
  const dep = JSON.parse(await readFile(path.join(process.cwd(), "deployments", `${network.name}-gmx.json`), "utf8"));
  const uni = JSON.parse(await readFile(path.join(process.cwd(), "deployments", `univ3.${network.name}.json`), "utf8"));
  const pools = JSON.parse(await readFile(path.join(process.cwd(), "deployments", `pools.${network.name}.json`), "utf8"));

  const rToken = dep.markets[MARKET].rToken as string;
  const usdcAddr = dep.usdc as string;
  const fee = Number(dep.swapFee ?? pools.fee ?? 3000);
  const pool = pools.pools[`${MARKET}/USDC`] as string;
  const routerAddr = (uni.swapRouter ?? dep.swapRouter) as string;

  const [signer] = await ethers.getSigners();
  const me = await signer.getAddress();
  const usdc = new ethers.Contract(usdcAddr, ERC20Abi, signer);
  const reth = new ethers.Contract(rToken, ERC20Abi, signer);
  const router = new ethers.Contract(routerAddr, SWAP_ROUTER_ABI, signer);

  const amountIn = ethers.parseUnits(AMOUNT_USDC, 6);
  const usdcBefore: bigint = await usdc.balanceOf(me);
  const rethBefore: bigint = await reth.balanceOf(me);
  if (usdcBefore < amountIn) throw new Error(`need ${AMOUNT_USDC} USDC, have ${ethers.formatUnits(usdcBefore, 6)}`);

  console.log(`Network : ${network.name}`);
  console.log(`Pool    : ${pool}`);
  console.log(`Router  : ${routerAddr}`);
  console.log(`Swap    : ${AMOUNT_USDC} USDC → rETH (fee=${fee})`);
  console.log(`before  : USDC=${ethers.formatUnits(usdcBefore, 6)}  rETH=${ethers.formatEther(rethBefore)}`);

  await (await usdc.approve(routerAddr, amountIn)).wait();

  const deadline = Math.floor(Date.now() / 1000) + 600;
  const tx = await router.exactInputSingle({
    tokenIn: usdcAddr,
    tokenOut: rToken,
    fee,
    recipient: me,
    deadline,
    amountIn,
    amountOutMinimum: 0n,
    sqrtPriceLimitX96: 0n,
  });
  const rc = await tx.wait();

  const usdcAfter: bigint = await usdc.balanceOf(me);
  const rethAfter: bigint = await reth.balanceOf(me);
  const usdcSpent = usdcBefore - usdcAfter;
  const rethGot = rethAfter - rethBefore;

  console.log(`tx      : ${rc?.hash}`);
  console.log(`after   : USDC=${ethers.formatUnits(usdcAfter, 6)}  rETH=${ethers.formatEther(rethAfter)}`);
  console.log(`spent   : ${ethers.formatUnits(usdcSpent, 6)} USDC`);
  console.log(`got     : ${ethers.formatEther(rethGot)} rETH`);

  if (rethGot === 0n) throw new Error("swap returned 0 rETH");
  console.log("\n✓ smoke swap OK");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
