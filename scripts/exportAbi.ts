/**
 * 프론트엔드용 ABI 추출 스크립트
 * 실행: npx hardhat run scripts/exportAbi.ts
 *       (네트워크 불필요 — artifacts만 읽음)
 *
 * 결과: abi/ 폴더에 각 컨트랙트 ABI JSON 파일 생성
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const OUT_DIR = path.join(process.cwd(), "abi");

const CONTRACTS: { name: string; artifactPath: string }[] = [
  // ── Uniswap V3 Core ──────────────────────────────────────────────────────────
  {
    name: "UniswapV3Factory",
    artifactPath: "artifacts/@uniswap/v3-core/contracts/UniswapV3Factory.sol/UniswapV3Factory.json",
  },
  {
    name: "IUniswapV3Factory",
    artifactPath: "artifacts/@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol/IUniswapV3Factory.json",
  },
  {
    name: "UniswapV3Pool",
    artifactPath: "artifacts/@uniswap/v3-core/contracts/UniswapV3Pool.sol/UniswapV3Pool.json",
  },
  {
    name: "IUniswapV3Pool",
    artifactPath: "artifacts/@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol/IUniswapV3Pool.json",
  },
  // ── Uniswap V3 Periphery ──────────────────────────────────────────────────────
  {
    name: "SwapRouter",
    artifactPath: "artifacts/@uniswap/v3-periphery/SwapRouter.sol/SwapRouter.json",
  },
  {
    name: "ISwapRouter",
    artifactPath: "artifacts/@uniswap/v3-periphery/interfaces/ISwapRouter.sol/ISwapRouter.json",
  },
  {
    name: "NonfungiblePositionManager",
    artifactPath: "artifacts/@uniswap/v3-periphery/NonfungiblePositionManager.sol/NonfungiblePositionManager.json",
  },
  {
    name: "INonfungiblePositionManager",
    artifactPath: "artifacts/@uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol/INonfungiblePositionManager.json",
  },
  // ── Quoter ───────────────────────────────────────────────────────────────────
  {
    name: "Quoter",
    artifactPath: "artifacts/@uniswap/v3-periphery/lens/Quoter.sol/Quoter.json",
  },
  {
    name: "IQuoter",
    artifactPath: "artifacts/@uniswap/v3-periphery/interfaces/IQuoter.sol/IQuoter.json",
  },
  {
    name: "QuoterV2",
    artifactPath: "artifacts/@uniswap/v3-periphery/lens/QuoterV2.sol/QuoterV2.json",
  },
  {
    name: "IQuoterV2",
    artifactPath: "artifacts/@uniswap/v3-periphery/interfaces/IQuoterV2.sol/IQuoterV2.json",
  },
  // ── ERC20 / WETH9 ────────────────────────────────────────────────────────────
  {
    name: "ERC20",
    artifactPath: "artifacts/@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol/ERC20PresetMinterPauser.json",
  },
  {
    name: "WETH9",
    artifactPath: "artifacts/src/v3/WETH9.sol/WETH9.json",
  },
];

async function main() {
  await mkdir(OUT_DIR, { recursive: true });

  for (const { name, artifactPath } of CONTRACTS) {
    const fullPath = path.join(process.cwd(), artifactPath);
    const artifact = JSON.parse(await readFile(fullPath, "utf8")) as { abi: unknown[] };

    const outPath = path.join(OUT_DIR, `${name}.json`);
    await writeFile(outPath, `${JSON.stringify(artifact.abi, null, 2)}\n`, "utf8");
    console.log(`✓ ${name.padEnd(30)} → abi/${name}.json  (${artifact.abi.length} entries)`);
  }

  console.log(`\n✅ ABI 추출 완료 → ${OUT_DIR}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
