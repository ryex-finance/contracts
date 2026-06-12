import { expect } from "chai";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import {
  ERC20PresetMinterPauser__factory,
  INonfungiblePositionManager__factory,
  ISwapRouter__factory,
  IUniswapV3Factory__factory,
  IUniswapV3Pool__factory,
} from "../typechain-types";

// 풀당 스왑할 토큰 수량 (사람 단위)
const SWAP_AMOUNT = "100";

type TokensDeployment = { tokens: Record<string, string> };
type UniDeployment    = { nonfungiblePositionManager: string; swapRouter: string };
type PoolsDeployment  = { fee?: number; pools?: Record<string, string> };

function sortTokens(a: string, b: string): [string, string] {
  return a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
}

// sqrtPriceX96 → 실수 가격 (token1 per token0)
function toPrice(sqrtPriceX96: bigint): string {
  return (Number(sqrtPriceX96) ** 2 / 2 ** 192).toFixed(6);
}

async function readDeployments() {
  const base = path.join(process.cwd(), "deployments");
  const tokens = JSON.parse(await readFile(path.join(base, `tokens.${network.name}.json`), "utf8")) as TokensDeployment;
  const uni    = JSON.parse(await readFile(path.join(base, `univ3.${network.name}.json`),  "utf8")) as UniDeployment;
  const pools  = JSON.parse(await readFile(path.join(base, `pools.${network.name}.json`),  "utf8")) as PoolsDeployment;
  return { tokens: tokens.tokens, uni, fee: pools.fee ?? 3000, pools: pools.pools ?? {} };
}

// ─── 풀 상태 출력 헬퍼 ────────────────────────────────────────────────────────
async function printPoolStatus(
  label: string,
  poolAddr: string,
  token0Addr: string,
  token1Addr: string,
  signer: Awaited<ReturnType<typeof ethers.getSigners>>[0],
) {
  const pool = IUniswapV3Pool__factory.connect(poolAddr, signer);
  const t0   = ERC20PresetMinterPauser__factory.connect(token0Addr, signer);
  const t1   = ERC20PresetMinterPauser__factory.connect(token1Addr, signer);

  const [liquidity, slot0, sym0, sym1, d0, d1, b0, b1] = await Promise.all([
    pool.liquidity(),
    pool.slot0(),
    t0.symbol(), t1.symbol(),
    t0.decimals(), t1.decimals(),
    t0.balanceOf(poolAddr),
    t1.balanceOf(poolAddr),
  ]);

  console.log(`  [${label}]`);
  console.log(`    liquidity    : ${liquidity}`);
  console.log(`    tick         : ${slot0.tick}`);
  console.log(`    price        : ${toPrice(slot0.sqrtPriceX96)} ${sym1}/${sym0}`);
  console.log(`    ${sym0} in pool : ${ethers.formatUnits(b0, d0)}`);
  console.log(`    ${sym1} in pool : ${ethers.formatUnits(b1, d1)}`);
  console.log();
}

// ─── 스왑 공통 함수 ───────────────────────────────────────────────────────────
async function runSwap(opts: {
  pairName:    string;
  baseAddr:    string;
  usdcAddr:    string;
  poolAddr:    string;
  routerAddr:  string;
  fee:         number;
  direction:   "base→USDC" | "USDC→base";
  signer:      Awaited<ReturnType<typeof ethers.getSigners>>[0];
}) {
  const { pairName, baseAddr, usdcAddr, poolAddr, routerAddr, fee, direction, signer } = opts;
  const signerAddr = await signer.getAddress();

  const tokenInAddr  = direction === "base→USDC" ? baseAddr  : usdcAddr;
  const tokenOutAddr = direction === "base→USDC" ? usdcAddr  : baseAddr;

  const tokenIn  = ERC20PresetMinterPauser__factory.connect(tokenInAddr,  signer);
  const tokenOut = ERC20PresetMinterPauser__factory.connect(tokenOutAddr, signer);
  const [symIn, symOut, decIn, decOut] = await Promise.all([
    tokenIn.symbol(), tokenOut.symbol(), tokenIn.decimals(), tokenOut.decimals(),
  ]);

  const amountIn = ethers.parseUnits(SWAP_AMOUNT, decIn);

  // 잔액 확인
  const balBefore = await tokenIn.balanceOf(signerAddr);
  expect(balBefore).to.be.gte(amountIn, `${symIn} 잔액 부족`);

  const [token0, token1] = sortTokens(baseAddr, usdcAddr);

  console.log(`\n  [${pairName}]  ${direction}`);
  console.log(`  router=${routerAddr}`);

  // ── before ──────────────────────────────────────────────────────────────────
  console.log(`  ---- before swap ----`);
  await printPoolStatus("pool", poolAddr, token0, token1, signer);

  // ── approve & swap ──────────────────────────────────────────────────────────
  await (await tokenIn.approve(routerAddr, amountIn)).wait();

  const router = ISwapRouter__factory.connect(routerAddr, signer);
  const tx = await router.exactInputSingle({
    tokenIn:           tokenInAddr,
    tokenOut:          tokenOutAddr,
    fee,
    recipient:         signerAddr,
    deadline:          Math.floor(Date.now() / 1000) + 1800,
    amountIn,
    amountOutMinimum:  0n,
    sqrtPriceLimitX96: 0n,
  });
  const receipt = await tx.wait();

  // ── after ───────────────────────────────────────────────────────────────────
  const outBal = await tokenOut.balanceOf(signerAddr);
  console.log(`  ✓ swap tx=${receipt?.hash ?? ""}`);
  console.log(`  amountIn =${ethers.formatUnits(amountIn, decIn)} ${symIn}`);
  console.log(`  amountOut≈${ethers.formatUnits(outBal, decOut)} ${symOut} (total balance)`);
  console.log(`  ---- after swap ----`);
  await printPoolStatus("pool", poolAddr, token0, token1, signer);

  expect(receipt).to.not.be.null;
}

// ─── describe ─────────────────────────────────────────────────────────────────
describe("Swap Test (Arbitrum Sepolia)", function () {
  this.timeout(120_000);

  it("rBTC → USDC swap (100 rBTC)", async function () {
    const [signer] = await ethers.getSigners();
    const { tokens, uni, fee, pools } = await readDeployments();
    await runSwap({
      pairName: "rBTC/USDC", baseAddr: tokens.rBTC, usdcAddr: tokens.USDC,
      poolAddr: pools["rBTC/USDC"], routerAddr: uni.swapRouter,
      fee, direction: "base→USDC", signer,
    });
  });

  it("rETH → USDC swap (100 rETH)", async function () {
    const [signer] = await ethers.getSigners();
    const { tokens, uni, fee, pools } = await readDeployments();
    await runSwap({
      pairName: "rETH/USDC", baseAddr: tokens.rETH, usdcAddr: tokens.USDC,
      poolAddr: pools["rETH/USDC"], routerAddr: uni.swapRouter,
      fee, direction: "base→USDC", signer,
    });
  });

  it("rSOL → USDC swap (100 rSOL)", async function () {
    const [signer] = await ethers.getSigners();
    const { tokens, uni, fee, pools } = await readDeployments();
    await runSwap({
      pairName: "rSOL/USDC", baseAddr: tokens.rSOL, usdcAddr: tokens.USDC,
      poolAddr: pools["rSOL/USDC"], routerAddr: uni.swapRouter,
      fee, direction: "base→USDC", signer,
    });
  });

  it("rHYPE → USDC swap (100 rHYPE)", async function () {
    const [signer] = await ethers.getSigners();
    const { tokens, uni, fee, pools } = await readDeployments();
    await runSwap({
      pairName: "rHYPE/USDC", baseAddr: tokens.rHYPE, usdcAddr: tokens.USDC,
      poolAddr: pools["rHYPE/USDC"], routerAddr: uni.swapRouter,
      fee, direction: "base→USDC", signer,
    });
  });

  it.only("prints my USDC balance", async function () {
    const [signer] = await ethers.getSigners();
    const signerAddr = await signer.getAddress();
    const { tokens } = await readDeployments();

    const usdc = ERC20PresetMinterPauser__factory.connect(tokens.USDC, signer);
    const [decimals, balance] = await Promise.all([usdc.decimals(), usdc.balanceOf(signerAddr)]);

    console.log(`\nnetwork  : ${network.name}`);
    console.log(`address  : ${signerAddr}`);
    console.log(`USDC     : ${tokens.USDC}`);
    console.log(`balance  : ${ethers.formatUnits(balance, decimals)} USDC`);
  });
});
