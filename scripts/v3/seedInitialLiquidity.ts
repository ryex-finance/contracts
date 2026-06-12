import { expect } from "chai";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import {
  ERC20PresetMinterPauser__factory,
  INonfungiblePositionManager__factory,
  IUniswapV3Factory__factory,
  IUniswapV3Pool__factory,
} from "../../typechain-types";

const DEFAULT_FEE = 3000; // 0.3%
// 풀 전체 범위 (fee=3000, tickSpacing=60 기준)
const TICK_LOWER = -887220; // Math.ceil(-887272 / 60) * 60
const TICK_UPPER = 887220;  // Math.floor(887272 / 60) * 60

type TokensDeployment = { tokens: Record<string, string> };
type UniDeployment = { nonfungiblePositionManager: string };
type PoolsDeployment = { fee?: number; pools?: Record<string, string> };

function sortTokens(a: string, b: string): [string, string] {
  return a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
}

describe("Seed Initial Liquidity (Hardhat)", function () {
  this.timeout(300_000);

  it("checks token balances before seeding", async function () {
    const [signer] = await ethers.getSigners();
    const signerAddr = await signer.getAddress();

    const tokensPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
    const { tokens } = JSON.parse(await readFile(tokensPath, "utf8")) as TokensDeployment;

    console.log(`\nnetwork=${network.name}  signer=${signerAddr}`);
    for (const [symbol, addr] of Object.entries(tokens)) {
      const erc20 = ERC20PresetMinterPauser__factory.connect(addr, signer);
      const decimals = await erc20.decimals();
      const bal = await erc20.balanceOf(signerAddr);
      console.log(`  ${symbol} balance=${ethers.formatUnits(bal, decimals)}`);
    }
  });

  it("supplies initial liquidity to 4 USDC pools", async function () {
    const [signer] = await ethers.getSigners();
    const signerAddr = await signer.getAddress();

    const tokensPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
    const uniPath    = path.join(process.cwd(), "deployments", `univ3.${network.name}.json`);
    const poolsPath  = path.join(process.cwd(), "deployments", `pools.${network.name}.json`);

    const { tokens }   = JSON.parse(await readFile(tokensPath, "utf8")) as TokensDeployment;
    const { nonfungiblePositionManager: npmAddr } =
      JSON.parse(await readFile(uniPath, "utf8")) as UniDeployment;
    const poolsJson = JSON.parse(await readFile(poolsPath, "utf8")) as PoolsDeployment;

    const usdc  = tokens.USDC;
    const rbtc  = tokens.rBTC;
    const reth  = tokens.rETH;
    const rsol  = tokens.rSOL;
    const rhype = tokens.rHYPE;
    const fee   = poolsJson.fee ?? DEFAULT_FEE;

    if (!usdc || !rbtc || !reth || !rsol || !rhype || !npmAddr) {
      throw new Error("deployments 파일에 필요한 주소가 없습니다.");
    }

    const pairs = [
      { name: "rBTC/USDC",  base: rbtc,  quote: usdc },
      { name: "rETH/USDC",  base: reth,  quote: usdc },
      { name: "rSOL/USDC",  base: rsol,  quote: usdc },
      { name: "rHYPE/USDC", base: rhype, quote: usdc },
    ];

    const npm = INonfungiblePositionManager__factory.connect(npmAddr, signer);
    const factory = IUniswapV3Factory__factory.connect(await npm.factory(), signer);

    // tickSpacing 검증
    const tickSpacing = Number(await factory.feeAmountTickSpacing(fee));
    if (tickSpacing <= 0) throw new Error(`fee ${fee} is not enabled`);
    const tickLower = Math.ceil(-887272 / tickSpacing) * tickSpacing;
    const tickUpper = Math.floor(887272 / tickSpacing) * tickSpacing;

    console.log(`\nnetwork=${network.name}  signer=${signerAddr}`);
    console.log(`npm=${npmAddr}  fee=${fee}  tickSpacing=${tickSpacing}`);
    console.log(`tickLower=${tickLower}  tickUpper=${tickUpper}`);

    // ── USDC approve (풀 수 × 25만) ──────────────────────────────────────
    const usdcErc20   = ERC20PresetMinterPauser__factory.connect(usdc, signer);
    const usdcDec     = await usdcErc20.decimals();
    const usdcPerPool = ethers.parseUnits("250000", usdcDec);
    const usdcTotal   = usdcPerPool * BigInt(pairs.length);

    const usdcBal = await usdcErc20.balanceOf(signerAddr);
    console.log(`USDC balance=${ethers.formatUnits(usdcBal, usdcDec)}  need=${ethers.formatUnits(usdcTotal, usdcDec)}`);
    expect(usdcBal).to.be.gte(usdcTotal, "USDC 잔액 부족");

    await (await usdcErc20.approve(npmAddr, usdcTotal)).wait();

    // ── 각 페어 처리 ──────────────────────────────────────────────────────
    for (const pair of pairs) {
      const baseErc20   = ERC20PresetMinterPauser__factory.connect(pair.base, signer);
      const baseDec     = await baseErc20.decimals();
      const basePerPool = ethers.parseUnits("100000", baseDec);

      const baseBal = await baseErc20.balanceOf(signerAddr);
      console.log(`${pair.name} base balance=${ethers.formatUnits(baseBal, baseDec)}  need=${ethers.formatUnits(basePerPool, baseDec)}`);
      expect(baseBal).to.be.gte(basePerPool, `${pair.name} 기본 토큰 잔액 부족`);

      await (await baseErc20.approve(npmAddr, basePerPool)).wait();

      const [token0, token1] = sortTokens(pair.base, pair.quote);
      const pool = await factory.getPool(token0, token1, fee);
      expect(pool).to.not.equal(ethers.ZeroAddress, `${pair.name} pool not found`);

      const isBaseToken0    = token0.toLowerCase() === pair.base.toLowerCase();
      const amount0Desired  = isBaseToken0 ? basePerPool : usdcPerPool;
      const amount1Desired  = isBaseToken0 ? usdcPerPool : basePerPool;

      const tx = await npm.mint({
        token0,
        token1,
        fee,
        tickLower,
        tickUpper,
        amount0Desired,
        amount1Desired,
        amount0Min: 0n,
        amount1Min: 0n,
        recipient: signerAddr,
        deadline: Math.floor(Date.now() / 1000) + 1800,
      });
      const receipt = await tx.wait();

      console.log(`✓ ${pair.name} pool=${pool} tx=${receipt?.hash ?? ""}`);
    }
  });

  it("verifies pool creation and liquidity in detail", async function () {
    const [signer] = await ethers.getSigners();

    const tokensPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
    const uniPath    = path.join(process.cwd(), "deployments", `univ3.${network.name}.json`);
    const poolsPath  = path.join(process.cwd(), "deployments", `pools.${network.name}.json`);

    const { tokens }  = JSON.parse(await readFile(tokensPath, "utf8")) as TokensDeployment;
    const { nonfungiblePositionManager: npmAddr } =
      JSON.parse(await readFile(uniPath, "utf8")) as UniDeployment;
    const { fee: savedFee, pools: savedPools } =
      JSON.parse(await readFile(poolsPath, "utf8")) as PoolsDeployment;
    const fee = savedFee ?? DEFAULT_FEE;

    const npm     = INonfungiblePositionManager__factory.connect(npmAddr, signer);
    const factory = IUniswapV3Factory__factory.connect(await npm.factory(), signer);

    const pairs = [
      { name: "rBTC/USDC",  a: tokens.rBTC,  b: tokens.USDC },
      { name: "rETH/USDC",  a: tokens.rETH,  b: tokens.USDC },
      { name: "rSOL/USDC",  a: tokens.rSOL,  b: tokens.USDC },
      { name: "rHYPE/USDC", a: tokens.rHYPE, b: tokens.USDC },
    ];

    const sep = "─".repeat(72);
    console.log(`\n${sep}`);
    console.log(`network : ${network.name}`);
    console.log(`factory : ${await npm.factory()}`);
    console.log(`npm     : ${npmAddr}`);
    console.log(`fee     : ${fee} (${fee / 10000}%)`);
    console.log(sep);

    let allOk = true;

    for (const pair of pairs) {
      const [token0, token1] = sortTokens(pair.a, pair.b);

      // ── 풀 주소 검증 ────────────────────────────────────────────────────
      const poolOnChain  = await factory.getPool(token0, token1, fee);
      const poolInFile   = (savedPools ?? {})[pair.name] ?? "(not saved)";
      const addrMatch    = poolOnChain.toLowerCase() === poolInFile.toLowerCase();

      // ── 풀 상태 조회 ────────────────────────────────────────────────────
      const poolContract = IUniswapV3Pool__factory.connect(poolOnChain, signer);
      const liquidity    = await poolContract.liquidity();
      const slot0        = await poolContract.slot0();
      const sqrtPrice    = slot0.sqrtPriceX96;

      // sqrtPriceX96 → 실제 가격 (token1 per token0)
      const price = Number(sqrtPrice) ** 2 / 2 ** 192;

      // ── 토큰 잔액 조회 ──────────────────────────────────────────────────
      const t0 = ERC20PresetMinterPauser__factory.connect(token0, signer);
      const t1 = ERC20PresetMinterPauser__factory.connect(token1, signer);
      const [sym0, sym1, d0, d1] = await Promise.all([
        t0.symbol(), t1.symbol(), t0.decimals(), t1.decimals(),
      ]);
      const [b0, b1] = await Promise.all([t0.balanceOf(poolOnChain), t1.balanceOf(poolOnChain)]);

      // ── 유동성 유효 여부 ────────────────────────────────────────────────
      const hasLiquidity = liquidity > 0n;
      const hasBalance   = b0 > 0n || b1 > 0n;
      const status       = hasLiquidity && hasBalance ? "✅ OK" : "❌ FAIL";
      if (!hasLiquidity || !hasBalance) allOk = false;

      console.log(`\n[${pair.name}]  ${status}`);
      console.log(`  pool (chain)  : ${poolOnChain}`);
      console.log(`  pool (file)   : ${poolInFile}  match=${addrMatch ? "✅" : "❌"}`);
      console.log(`  liquidity     : ${liquidity.toString()}`);
      console.log(`  tick          : ${slot0.tick}`);
      console.log(`  sqrtPriceX96  : ${sqrtPrice.toString()}`);
      console.log(`  price         : ${price.toFixed(6)} ${sym1}/${sym0}`);
      console.log(`  ${sym0} in pool : ${ethers.formatUnits(b0, d0)}`);
      console.log(`  ${sym1} in pool : ${ethers.formatUnits(b1, d1)}`);

      // ── assert ──────────────────────────────────────────────────────────
      expect(poolOnChain).to.not.equal(ethers.ZeroAddress, `${pair.name}: pool not deployed`);
      expect(addrMatch).to.equal(true, `${pair.name}: pool address mismatch between chain and deployment file`);
      expect(liquidity).to.be.gt(0n, `${pair.name}: liquidity is 0`);
      expect(b0 + b1).to.be.gt(0n, `${pair.name}: no tokens in pool`);
    }

    console.log(`\n${sep}`);
    console.log(allOk ? "✅ All pools OK" : "❌ Some pools have issues");
    console.log(sep);
  });

  it("prints pool liquidity status to console", async function () {
    const [signer] = await ethers.getSigners();

    const tokensPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
    const uniPath    = path.join(process.cwd(), "deployments", `univ3.${network.name}.json`);

    const { tokens } = JSON.parse(await readFile(tokensPath, "utf8")) as TokensDeployment;
    const { nonfungiblePositionManager: npmAddr } =
      JSON.parse(await readFile(uniPath, "utf8")) as UniDeployment;

    const { usdc, rbtc, reth, rsol, rhype } = {
      usdc:  tokens.USDC,
      rbtc:  tokens.rBTC,
      reth:  tokens.rETH,
      rsol:  tokens.rSOL,
      rhype: tokens.rHYPE,
    };

    const npm     = INonfungiblePositionManager__factory.connect(npmAddr, signer);
    const factory = IUniswapV3Factory__factory.connect(await npm.factory(), signer);

    const pairs = [
      { name: "rBTC/USDC",  a: rbtc,  b: usdc },
      { name: "rETH/USDC",  a: reth,  b: usdc },
      { name: "rSOL/USDC",  a: rsol,  b: usdc },
      { name: "rHYPE/USDC", a: rhype, b: usdc },
    ];

    console.log(`\nnetwork=${network.name}  fee=${DEFAULT_FEE}`);

    for (const pair of pairs) {
      const [token0, token1] = sortTokens(pair.a, pair.b);
      const pool = await factory.getPool(token0, token1, DEFAULT_FEE);
      expect(pool).to.not.equal(ethers.ZeroAddress);

      const poolContract = IUniswapV3Pool__factory.connect(pool, signer);
      const liquidity    = await poolContract.liquidity();
      const slot0        = await poolContract.slot0();

      const t0 = ERC20PresetMinterPauser__factory.connect(token0, signer);
      const t1 = ERC20PresetMinterPauser__factory.connect(token1, signer);
      const d0 = await t0.decimals();
      const d1 = await t1.decimals();
      const b0 = await t0.balanceOf(pool);
      const b1 = await t1.balanceOf(pool);

      console.log(
        `${pair.name} pool=${pool}\n` +
        `  liquidity=${liquidity}  tick=${slot0.tick}  sqrtPriceX96=${slot0.sqrtPriceX96}\n` +
        `  token0Bal=${ethers.formatUnits(b0, d0)}  token1Bal=${ethers.formatUnits(b1, d1)}`,
      );
    }
  });
});
