/**
 * 가격 반영 초기 유동성 공급
 * - USDC 잔액 확인 → 부족 시 민팅
 * - 각 풀의 목표 가격(rBTC:75000, rETH:2300, rSOL:85, rHYPE:44)에 맞는 비율로 공급
 */
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

const DEFAULT_FEE = 3000;

// ── 풀당 유동성 공급 수량 (목표 가격 비율에 맞춰 설정) ─────────────────────────
// 각 풀 한 쪽 가치 ~$975K~$989K 수준
const PAIR_SEED: Record<string, { baseAmount: string; usdcAmount: string }> = {
  "rBTC/USDC":  { baseAmount: "13",    usdcAmount: "975000"  }, // 13 × 75,000 = 975,000
  "rETH/USDC":  { baseAmount: "430",   usdcAmount: "989000"  }, // 430 × 2,300 = 989,000
  "rSOL/USDC":  { baseAmount: "11000", usdcAmount: "935000"  }, // 11,000 × 85 = 935,000
  "rHYPE/USDC": { baseAmount: "22000", usdcAmount: "968000"  }, // 22,000 × 44 = 968,000
};

type TokensDeployment = { tokens: Record<string, string> };
type UniDeployment    = { nonfungiblePositionManager: string };
type PoolsDeployment  = { fee?: number };

function sortTokens(a: string, b: string): [string, string] {
  return a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
}

function toPrice(sqrtPriceX96: bigint): string {
  return (Number(sqrtPriceX96) ** 2 / 2 ** 192).toFixed(2);
}

describe("Seed Liquidity (Priced)", function () {
  this.timeout(300_000);

  it("checks balances and mints USDC if needed", async function () {
    const [signer] = await ethers.getSigners();
    const signerAddr = await signer.getAddress();

    const tokensPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
    const { tokens } = JSON.parse(await readFile(tokensPath, "utf8")) as TokensDeployment;

    // 필요한 총 USDC 계산
    const usdcContract = ERC20PresetMinterPauser__factory.connect(tokens.USDC, signer);
    const usdcDec      = await usdcContract.decimals();
    const totalUsdcNeeded = Object.values(PAIR_SEED).reduce(
      (sum, { usdcAmount }) => sum + ethers.parseUnits(usdcAmount, usdcDec),
      0n,
    );

    const usdcBal = await usdcContract.balanceOf(signerAddr);

    const sep = "─".repeat(60);
    console.log(`\n${sep}`);
    console.log(`network         : ${network.name}`);
    console.log(`signer          : ${signerAddr}`);
    console.log(`USDC balance    : ${ethers.formatUnits(usdcBal, usdcDec)}`);
    console.log(`USDC needed     : ${ethers.formatUnits(totalUsdcNeeded, usdcDec)}`);

    for (const [symbol, addr] of Object.entries(tokens)) {
      if (symbol === "USDC") continue;
      const t   = ERC20PresetMinterPauser__factory.connect(addr, signer);
      const dec = await t.decimals();
      const bal = await t.balanceOf(signerAddr);
      const needed = PAIR_SEED[`${symbol}/USDC`]?.baseAmount ?? "0";
      const neededWei = ethers.parseUnits(needed, dec);
      const ok = bal >= neededWei ? "✅" : "❌";
      console.log(`${symbol.padEnd(6)} balance : ${ethers.formatUnits(bal, dec).padStart(12)}  need ${needed}  ${ok}`);
    }

    // USDC 부족 시 민팅
    if (usdcBal < totalUsdcNeeded) {
      const mintAmount = totalUsdcNeeded - usdcBal;
      console.log(`\n💧 USDC 부족 → ${ethers.formatUnits(mintAmount, usdcDec)} 민팅 중...`);
      await (await usdcContract.mint(signerAddr, mintAmount)).wait();
      const newBal = await usdcContract.balanceOf(signerAddr);
      console.log(`✓ 민팅 완료. 새 잔액: ${ethers.formatUnits(newBal, usdcDec)} USDC`);
    } else {
      console.log(`✅ USDC 잔액 충분`);
    }
    console.log(sep);
  });

  it("seeds initial liquidity at target prices", async function () {
    const [signer] = await ethers.getSigners();
    const signerAddr = await signer.getAddress();

    const tokensPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
    const uniPath    = path.join(process.cwd(), "deployments", `univ3.${network.name}.json`);
    const poolsPath  = path.join(process.cwd(), "deployments", `pools.${network.name}.json`);

    const { tokens }  = JSON.parse(await readFile(tokensPath, "utf8")) as TokensDeployment;
    const { nonfungiblePositionManager: npmAddr } =
      JSON.parse(await readFile(uniPath, "utf8")) as UniDeployment;
    const { fee } = JSON.parse(await readFile(poolsPath, "utf8")) as PoolsDeployment;

    const usdc  = tokens.USDC;
    const rbtc  = tokens.rBTC;
    const reth  = tokens.rETH;
    const rsol  = tokens.rSOL;
    const rhype = tokens.rHYPE;
    if (!usdc || !rbtc || !reth || !rsol || !rhype || !npmAddr) {
      throw new Error("deployments 파일에 필요한 주소가 없습니다.");
    }

    const pairs = [
      { name: "rBTC/USDC",  base: rbtc,  quote: usdc },
      { name: "rETH/USDC",  base: reth,  quote: usdc },
      { name: "rSOL/USDC",  base: rsol,  quote: usdc },
      { name: "rHYPE/USDC", base: rhype, quote: usdc },
    ];

    const activeFee    = fee ?? DEFAULT_FEE;
    const npm          = INonfungiblePositionManager__factory.connect(npmAddr, signer);
    const factory      = IUniswapV3Factory__factory.connect(await npm.factory(), signer);
    const tickSpacing  = Number(await factory.feeAmountTickSpacing(activeFee));
    const tickLower    = Math.ceil(-887272 / tickSpacing) * tickSpacing;
    const tickUpper    = Math.floor(887272 / tickSpacing) * tickSpacing;

    console.log(`\nnpm=${npmAddr}  fee=${activeFee}  tickSpacing=${tickSpacing}`);
    console.log(`tickLower=${tickLower}  tickUpper=${tickUpper}\n`);

    // USDC: 총량 한 번에 approve
    const usdcContract = ERC20PresetMinterPauser__factory.connect(usdc, signer);
    const usdcDec      = await usdcContract.decimals();
    const totalUsdc    = Object.values(PAIR_SEED).reduce(
      (sum, { usdcAmount }) => sum + ethers.parseUnits(usdcAmount, usdcDec),
      0n,
    );
    await (await usdcContract.approve(npmAddr, totalUsdc)).wait();

    for (const pair of pairs) {
      const seed       = PAIR_SEED[pair.name];
      const baseErc20  = ERC20PresetMinterPauser__factory.connect(pair.base, signer);
      const baseDec    = await baseErc20.decimals();
      const baseAmount = ethers.parseUnits(seed.baseAmount, baseDec);
      const usdcAmount = ethers.parseUnits(seed.usdcAmount, usdcDec);

      await (await baseErc20.approve(npmAddr, baseAmount)).wait();

      const [token0, token1]   = sortTokens(pair.base, pair.quote);
      const isBaseToken0       = token0.toLowerCase() === pair.base.toLowerCase();
      const amount0Desired     = isBaseToken0 ? baseAmount : usdcAmount;
      const amount1Desired     = isBaseToken0 ? usdcAmount : baseAmount;

      const pool = await factory.getPool(token0, token1, activeFee);
      expect(pool).to.not.equal(ethers.ZeroAddress, `${pair.name} 풀 없음`);

      const tx      = await npm.mint({
        token0, token1, fee: activeFee,
        tickLower, tickUpper,
        amount0Desired, amount1Desired,
        amount0Min: 0n, amount1Min: 0n,
        recipient: signerAddr,
        deadline: Math.floor(Date.now() / 1000) + 1800,
      });
      const receipt = await tx.wait();
      expect(receipt).to.not.be.null;

      // 공급 후 풀 상태
      const poolContract = IUniswapV3Pool__factory.connect(pool, signer);
      const slot0        = await poolContract.slot0();
      const liquidity    = await poolContract.liquidity();

      console.log(`✓ ${pair.name}`);
      console.log(`  pool      = ${pool}`);
      console.log(`  tx        = ${receipt?.hash ?? ""}`);
      console.log(`  price     = ${toPrice(slot0.sqrtPriceX96)} USDC/token  tick=${slot0.tick}`);
      console.log(`  liquidity = ${liquidity}`);
      console.log(`  base in   = ${seed.baseAmount}  usdc in = ${seed.usdcAmount}`);
      console.log();
    }
  });
});
