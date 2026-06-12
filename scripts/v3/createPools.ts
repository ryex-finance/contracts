import { expect } from "chai";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import {
  INonfungiblePositionManager__factory,
  IUniswapV3Factory__factory,
} from "../../typechain-types";

const DEFAULT_FEE = 3000; // 0.3%

// ── 샘플 가격 설정 (USDC per token, token1/token0 ratio) ─────────────────────
// USDC 주소가 모든 base token 주소보다 크므로 USDC는 항상 token1
const PAIR_PRICES: Record<string, number> = {
  "rBTC/USDC":  75_000,
  "rETH/USDC":  2_300,
  "rSOL/USDC":  85,
  "rHYPE/USDC": 44,
};

// sqrtPriceX96 = sqrt(price) * 2^96
// 분할 계산으로 float 오버플로 방지 (sqrt(p) * 2^40 < MAX_SAFE_INTEGER)
function calcSqrtPriceX96(priceToken1PerToken0: number): bigint {
  const sqrtP = Math.sqrt(priceToken1PerToken0);
  return BigInt(Math.round(sqrtP * 2 ** 40)) * 2n ** 56n;
}

type TokensDeployment  = { tokens: Record<string, string> };
type UniswapDeployment = { nonfungiblePositionManager: string };

function sortTokens(a: string, b: string): [string, string] {
  return a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
}

describe("Create Pools (Hardhat)", function () {
  this.timeout(120_000);

  it("creates 4 USDC pairs with fee 3000 at target prices", async function () {
    const [signer] = await ethers.getSigners();
    const signerAddress = await signer.getAddress();

    const tokensPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
    const uniPath    = path.join(process.cwd(), "deployments", `univ3.${network.name}.json`);

    const { tokens }  = JSON.parse(await readFile(tokensPath, "utf8")) as TokensDeployment;
    const { nonfungiblePositionManager: npmAddr } =
      JSON.parse(await readFile(uniPath, "utf8")) as UniswapDeployment;

    const { USDC: usdc, rBTC: rbtc, rETH: reth, rSOL: rsol, rHYPE: rhype } = tokens;
    if (!usdc || !rbtc || !reth || !rsol || !rhype || !npmAddr) {
      throw new Error("deployments json에 필요한 주소가 없습니다.");
    }

    const npm = INonfungiblePositionManager__factory.connect(npmAddr, signer);
    const factoryAddr = await npm.factory();
    const factory = IUniswapV3Factory__factory.connect(factoryAddr, signer);

    const pairs = [
      { name: "rBTC/USDC",  a: rbtc,  b: usdc },
      { name: "rETH/USDC",  a: reth,  b: usdc },
      { name: "rSOL/USDC",  a: rsol,  b: usdc },
      { name: "rHYPE/USDC", a: rhype, b: usdc },
    ];

    const created: Record<string, string> = {};

    console.log(`\nnetwork=${network.name}  signer=${signerAddress}`);
    console.log(`npm=${npmAddr}  factory=${factoryAddr}  fee=${DEFAULT_FEE}`);
    console.log("─".repeat(72));

    for (const pair of pairs) {
      const [token0, token1] = sortTokens(pair.a, pair.b);
      const price           = PAIR_PRICES[pair.name];
      const sqrtPriceX96    = calcSqrtPriceX96(price);

      // 실제 가격 검증 (역산)
      const priceCheck = Number(sqrtPriceX96) ** 2 / 2 ** 192;

      const tx = await npm.createAndInitializePoolIfNecessary(
        token0, token1, DEFAULT_FEE, sqrtPriceX96,
      );
      await tx.wait();

      const pool = await factory.getPool(token0, token1, DEFAULT_FEE);
      expect(pool).to.not.equal(ethers.ZeroAddress);
      created[pair.name] = pool;

      console.log(`${pair.name}`);
      console.log(`  pool          = ${pool}`);
      console.log(`  targetPrice   = ${price.toLocaleString()} USDC/token`);
      console.log(`  sqrtPriceX96  = ${sqrtPriceX96}`);
      console.log(`  priceCheck    = ${priceCheck.toFixed(2)} USDC/token`);
    }

    const outPath = path.join(process.cwd(), "deployments", `pools.${network.name}.json`);
    await mkdir(path.dirname(outPath), { recursive: true });
    await writeFile(
      outPath,
      `${JSON.stringify(
        { network: network.name, signer: signerAddress, fee: DEFAULT_FEE,
          prices: PAIR_PRICES, pools: created },
        null, 2,
      )}\n`,
      "utf8",
    );
    console.log(`\nsaved=${outPath}`);
  });
});
