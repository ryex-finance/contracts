import { expect } from "chai";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import { INonfungiblePositionManager__factory, IUniswapV3Factory__factory } from "../../typechain-types";

const DEFAULT_SQRT_PRICE_X96 = 2n ** 96n; // 1:1
const DEFAULT_FEE = 3000; // 0.3%

type TokensDeployment = {
  tokens: Record<string, string>;
};

type UniDeployment = {
  nonfungiblePositionManager: string;
};

function sortTokens(a: string, b: string): [string, string] {
  return a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
}

describe("UniswapV3 Pool Setup (Hardhat)", function () {
  it("creates + initializes rBTC/USDC, rETH/USDC, rSOL/USDC, rHYPE/USDC with fee 3000", async function () {
    const [signer] = await ethers.getSigners();
    const signerAddress = await signer.getAddress();

    const tokensPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
    const uniPath = path.join(process.cwd(), "deployments", `univ3.${network.name}.json`);
    const tokensJson = JSON.parse(await readFile(tokensPath, "utf8")) as TokensDeployment;
    const uniJson = JSON.parse(await readFile(uniPath, "utf8")) as UniDeployment;

    const usdc = tokensJson.tokens.USDC;
    const rbtc = tokensJson.tokens.rBTC;
    const reth = tokensJson.tokens.rETH;
    const rsol = tokensJson.tokens.rSOL;
    const rhype = tokensJson.tokens.rHYPE;
    const npmAddr = uniJson.nonfungiblePositionManager;

    if (!usdc || !rbtc || !reth || !rsol || !rhype || !npmAddr) {
      throw new Error("deployments 파일에 필요한 주소가 없습니다.");
    }

    const npm = INonfungiblePositionManager__factory.connect(npmAddr, signer);
    const factory = IUniswapV3Factory__factory.connect(await npm.factory(), signer);

    const pairs = [
      { name: "rBTC/USDC", a: rbtc, b: usdc },
      { name: "rETH/USDC", a: reth, b: usdc },
      { name: "rSOL/USDC", a: rsol, b: usdc },
      { name: "rHYPE/USDC", a: rhype, b: usdc },
    ];
    const created: Record<string, string> = {};

    console.log(`network=${network.name}`);
    console.log(`signer=${signerAddress}`);
    console.log(`npm=${npmAddr}`);
    console.log(`fee=${DEFAULT_FEE}`);

    for (const pair of pairs) {
      const [token0, token1] = sortTokens(pair.a, pair.b);

      const tx = await npm.createAndInitializePoolIfNecessary(
        token0,
        token1,
        DEFAULT_FEE,
        DEFAULT_SQRT_PRICE_X96,
      );
      await tx.wait();

      const pool = await factory.getPool(token0, token1, DEFAULT_FEE);
      expect(pool).to.not.equal(ethers.ZeroAddress);
      created[pair.name] = pool;

      console.log(`${pair.name}=${pool}`);
    }

    const outDir = path.join(process.cwd(), "deployments");
    await mkdir(outDir, { recursive: true });
    const outPath = path.join(outDir, `pools.${network.name}.json`);
    await writeFile(
      outPath,
      `${JSON.stringify(
        {
          network: network.name,
          signer: signerAddress,
          fee: DEFAULT_FEE,
          pools: created,
        },
        null,
        2,
      )}\n`,
      "utf8",
    );
    console.log(`saved=${outPath}`);
  });
});
