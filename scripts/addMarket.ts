/**
 * addMarket.ts — 배포된 VaultFactory에 마켓 추가 (onlyOwner)
 *
 * 실행:
 *   MARKET=rBTC npx hardhat run scripts/addMarket.ts --network arbitrumSepolia
 *   MARKET=rSOL npx hardhat run scripts/addMarket.ts --network arbitrumSepolia
 *
 * 필요 환경변수 (.env):
 *   PRIVATE_KEY=0x...
 *   MARKET=rBTC | rSOL | rNVDA | rGOLD   (추가할 마켓 심볼)
 *   PRICE=6000000000000                   (optional, 8-dec 초기 가격)
 *
 * 사전 조건:
 *   - deployments/{network}-gmx.json 에 vaultFactory, gmxAdapter 주소가 있어야 함
 */
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import { GMX } from "./config/gmxArbitrumSepolia";

// ── 마켓 카탈로그 ──────────────────────────────────────────────────────────
interface RiskParams {
  maxLtv1xBps:       number;
  bufferBps:         number;
  maxLtvAtMaxLevBps: number;
  flatTier:          number;
  maxLeverage:       number;
}

interface MarketCatalogEntry {
  name:      string;
  price8:    bigint;
  gmxMarket: string;
  risk:      RiskParams;
}

const CATALOG: Record<string, MarketCatalogEntry> = {
  rBTC: {
    name: "RYex BTC",
    price8: BigInt(process.env.PRICE ?? "6000000000000"), // 60,000 USD
    gmxMarket: GMX.MARKET_BTC,
    risk: { maxLtv1xBps: 8_500, bufferBps: 1_000, maxLtvAtMaxLevBps: 5_000, flatTier: 3, maxLeverage: 10 },
  },
  rETH: {
    name: "RYex ETH",
    price8: BigInt(process.env.PRICE ?? "300000000000"),  // 3,000 USD
    gmxMarket: GMX.MARKET_ETH,
    risk: { maxLtv1xBps: 8_000, bufferBps: 1_000, maxLtvAtMaxLevBps: 4_500, flatTier: 3, maxLeverage: 10 },
  },
  rSOL: {
    name: "RYex SOL",
    price8: BigInt(process.env.PRICE ?? "15000000000"),   // 150 USD
    gmxMarket: ethers.ZeroAddress, // GMX 테스트넷 미지원 → mock-only
    risk: { maxLtv1xBps: 7_500, bufferBps: 1_000, maxLtvAtMaxLevBps: 5_500, flatTier: 3, maxLeverage: 5 },
  },
  rNVDA: {
    name: "RYex NVDA",
    price8: BigInt(process.env.PRICE ?? "12000000000"),   // 120 USD
    gmxMarket: ethers.ZeroAddress,
    risk: { maxLtv1xBps: 7_800, bufferBps: 1_000, maxLtvAtMaxLevBps: 5_800, flatTier: 3, maxLeverage: 5 },
  },
  rGOLD: {
    name: "RYex GOLD",
    price8: BigInt(process.env.PRICE ?? "240000000000"),  // 2,400 USD
    gmxMarket: ethers.ZeroAddress,
    risk: { maxLtv1xBps: 8_800, bufferBps: 1_000, maxLtvAtMaxLevBps: 6_000, flatTier: 3, maxLeverage: 10 },
  },
};

// ── 이벤트에서 rToken 주소 파싱 ───────────────────────────────────────────
const MARKET_ADDED_TOPIC = ethers.id("MarketAdded(bytes32,address,address)");

function parseRToken(receipt: Awaited<ReturnType<typeof ethers.provider.getTransactionReceipt>> | null): string {
  if (!receipt) throw new Error("addMarket: no receipt");
  for (const log of receipt.logs) {
    if (log.topics[0] === MARKET_ADDED_TOPIC) {
      const decoded = ethers.AbiCoder.defaultAbiCoder().decode(["address", "address"], log.data);
      return decoded[1] as string;
    }
  }
  throw new Error("addMarket: MarketAdded event not found");
}

function mkId(symbol: string): string {
  return ethers.keccak256(ethers.toUtf8Bytes(symbol));
}

// ── 메인 ──────────────────────────────────────────────────────────────────
async function main() {
  const symbol = process.env.MARKET;
  if (!symbol || !CATALOG[symbol]) {
    console.error(`MARKET 환경변수가 필요합니다. 가능한 값: ${Object.keys(CATALOG).join(", ")}`);
    process.exit(1);
  }

  const mkt = CATALOG[symbol];
  const [deployer] = await ethers.getSigners();
  const deployerAddr = await deployer.getAddress();

  console.log(`Network  : ${network.name}`);
  console.log(`Deployer : ${deployerAddr}`);
  console.log(`Market   : ${symbol} (${mkt.name})`);
  console.log(`GMX mkt  : ${mkt.gmxMarket}`);
  console.log(`Price    : ${mkt.price8} (8-dec)`);
  console.log();

  // ── 배포 주소 로드 ────────────────────────────────────────────────────────
  const addrFile = path.join(process.cwd(), "deployments", `${network.name}-gmx.json`);
  const deployment = JSON.parse(await readFile(addrFile, "utf-8"));
  const factoryAddr  = deployment.vaultFactory as string;
  const adapterAddr  = deployment.gmxAdapter  as string;

  if (!factoryAddr || !adapterAddr) throw new Error(`vaultFactory / gmxAdapter not found in ${addrFile}`);

  const factory = await ethers.getContractAt("VaultFactory", factoryAddr);
  const adapter = await ethers.getContractAt("GmxV2Adapter", adapterAddr);

  // ── 중복 체크 ─────────────────────────────────────────────────────────────
  const id = mkId(symbol);
  const [active] = await (factory as any).markets(id);
  if (active) {
    console.log(`⚠️  ${symbol} 마켓이 이미 등록되어 있습니다.`);
    process.exit(0);
  }

  // ── Oracle 배포 ───────────────────────────────────────────────────────────
  const MockPriceOracleF = await ethers.getContractFactory("MockPriceOracle");
  const oracle = await MockPriceOracleF.deploy(mkt.price8);
  await oracle.waitForDeployment();
  const oracleAddr = await oracle.getAddress();
  console.log(`  Oracle   : ${oracleAddr}`);

  // ── VaultFactory.addMarket → rToken 주소 파싱 ─────────────────────────────
  const addTx = await (factory as any).addMarket(id, oracleAddr, mkt.name, symbol, mkt.risk);
  const addReceipt = await addTx.wait();
  const rTokenAddr = parseRToken(addReceipt);
  console.log(`  rToken   : ${rTokenAddr}`);

  // ── GmxV2Adapter.registerMarket ───────────────────────────────────────────
  await (await (adapter as any).registerMarket(id, oracleAddr, mkt.gmxMarket)).wait();
  console.log(`  Adapter  : registered`);

  // ── MockSwapPool 배포 ─────────────────────────────────────────────────────
  const MockSwapPoolF = await ethers.getContractFactory("MockSwapPool");
  const swapPool = await MockSwapPoolF.deploy(oracleAddr, rTokenAddr, GMX.USDC);
  await swapPool.waitForDeployment();
  const swapPoolAddr = await swapPool.getAddress();
  console.log(`  SwapPool : ${swapPoolAddr}`);

  // ── deployments JSON 업데이트 ─────────────────────────────────────────────
  deployment.markets = deployment.markets ?? {};
  deployment.markets[symbol] = {
    marketId:  id,
    oracle:    oracleAddr,
    rToken:    rTokenAddr,
    swapPool:  swapPoolAddr,
    gmxMarket: mkt.gmxMarket,
    maxLtvBps: mkt.risk.maxLtv1xBps,
    lltvBps:   mkt.risk.maxLtv1xBps + mkt.risk.bufferBps,
  };
  await writeFile(addrFile, JSON.stringify(deployment, null, 2));

  console.log(`\n✅ ${symbol} 마켓 추가 완료 → ${addrFile}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
