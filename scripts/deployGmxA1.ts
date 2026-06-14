/**
 * deployGmxA1.ts — A1 배포 스크립트 (Arbitrum Sepolia)
 *
 * 실행:
 *   npx hardhat run scripts/deployGmxA1.ts --network arbitrumSepolia
 *
 * 필요 환경변수 (.env):
 *   PRIVATE_KEY=0x...
 *   ETH_PRICE=300000000000    (optional, 8-dec, default 3000e8)
 *
 * 마켓 추가는 별도 스크립트로:
 *   MARKET=rBTC npx hardhat run scripts/addMarket.ts --network arbitrumSepolia
 */
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import { GMX } from "./config/gmxArbitrumSepolia";

// ── 배포 상수 ──────────────────────────────────────────────────────────────
const ADAPTER_ETH_FUNDING = ethers.parseEther("0.02");  // exec-fee gas (~60 orders)
const ADAPTER_USDC_BUFFER = 2_000n * 10n ** 6n;         // 2,000 USDC (6-dec)

// ── 리스크 파라미터 ────────────────────────────────────────────────────────
interface RiskParams {
  maxLtv1xBps:       number;
  bufferBps:         number;
  maxLtvAtMaxLevBps: number;
  flatTier:          number;
  maxLeverage:       number;
}

// ── 마켓 정의 ──────────────────────────────────────────────────────────────
interface MarketDef {
  symbol:    string;
  name:      string;
  price8:    bigint;  // 8-dec 초기 가격 (MockPriceOracle 초기값)
  gmxMarket: string;  // GMX 마켓 토큰 주소 (ZeroAddress = mock-only)
  risk:      RiskParams;
}

// 초기 배포: ETH/USDC 마켓만. 추가 마켓은 scripts/addMarket.ts 사용.
const MARKETS: MarketDef[] = [
  {
    symbol: "rETH", name: "RYex ETH",
    price8: BigInt(process.env.ETH_PRICE ?? "165000000000"), // 1650 USD
    gmxMarket: GMX.MARKET_ETH,
    risk: { maxLtv1xBps: 8_000, bufferBps: 1_000, maxLtvAtMaxLevBps: 4_500, flatTier: 3, maxLeverage: 10 },
  },
];

// ── marketId = keccak256(bytes(symbol)) ───────────────────────────────────
function mkId(symbol: string): string {
  return ethers.keccak256(ethers.toUtf8Bytes(symbol));
}

// ── 이벤트에서 rToken 주소 추출 ───────────────────────────────────────────
// VaultFactory: event MarketAdded(bytes32 indexed marketId, address oracle, address rToken)
const MARKET_ADDED_TOPIC = ethers.id("MarketAdded(bytes32,address,address)");

function parseRToken(receipt: Awaited<ReturnType<typeof ethers.provider.getTransactionReceipt>> | null): string {
  if (!receipt) throw new Error("addMarket: no receipt");
  for (const log of receipt.logs) {
    if (log.topics[0] === MARKET_ADDED_TOPIC) {
      // rToken은 세 번째 non-indexed 파라미터 → data의 두 번째 word
      const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
        ["address", "address"],
        log.data
      );
      return decoded[1] as string;
    }
  }
  throw new Error("addMarket: MarketAdded event not found");
}

// ── 메인 ──────────────────────────────────────────────────────────────────
async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddr = await deployer.getAddress();
  console.log(`Network  : ${network.name}`);
  console.log(`Deployer : ${deployerAddr}`);
  console.log(`Balance  : ${ethers.formatEther(await ethers.provider.getBalance(deployerAddr))} ETH`);
  console.log();

  // ── 1. PositionVault 구현체 ───────────────────────────────────────────────
  const PositionVaultF = await ethers.getContractFactory("PositionVault");
  const impl = await PositionVaultF.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  console.log(`PositionVault impl : ${implAddr}`);

  // ── 2. GmxV2Adapter (exec-fee ETH 선펀딩) ────────────────────────────────
  const GmxV2AdapterF = await ethers.getContractFactory("GmxV2Adapter");
  const adapter = await GmxV2AdapterF.deploy(
    GMX.USDC,
    GMX.EXCHANGE_ROUTER,
    GMX.ROUTER,
    GMX.ORDER_VAULT,
    GMX.READER,
    GMX.DATA_STORE,
    GMX.ORDER_HANDLER, // 콜백 호출자 검증용 (afterOrderExecution 등)
    deployerAddr,
    { value: ADAPTER_ETH_FUNDING }
  );
  await adapter.waitForDeployment();
  const adapterAddr = await adapter.getAddress();
  console.log(`GmxV2Adapter       : ${adapterAddr}`);

  // ── 3. VaultFactory ───────────────────────────────────────────────────────
  const VaultFactoryF = await ethers.getContractFactory("VaultFactory");
  const factory = await VaultFactoryF.deploy(implAddr, adapterAddr, GMX.USDC, deployerAddr);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log(`VaultFactory       : ${factoryAddr}`);
  console.log();

  // ── 4. 마켓별 Oracle / rToken / SwapPool 배포 ────────────────────────────
  const MockPriceOracleF = await ethers.getContractFactory("MockPriceOracle");
  const MockSwapPoolF    = await ethers.getContractFactory("MockSwapPool");

  const deployedMarkets: Record<string, object> = {};

  for (const mkt of MARKETS) {
    const id = mkId(mkt.symbol);

    // Oracle (MockPriceOracle: 초기 가격 세팅, owner가 setPrice()로 업데이트 가능)
    const oracle = await MockPriceOracleF.deploy(mkt.price8);
    await oracle.waitForDeployment();
    const oracleAddr = await oracle.getAddress();

    // rToken (factory.addMarket이 배포 → 이벤트에서 주소 파싱)
    const addTx = await factory.addMarket(
      id,
      oracleAddr,
      mkt.name,
      mkt.symbol,
      mkt.risk
    );
    const addReceipt = await addTx.wait();
    const rTokenAddr = parseRToken(addReceipt);

    // Adapter에 마켓 등록 (실 GMX 마켓 주소 연결)
    await (await (adapter as any).registerMarket(id, oracleAddr, mkt.gmxMarket)).wait();

    // SwapPool (rToken ↔ USDC 스왑풀, oracle 가격 기준)
    const swapPool = await MockSwapPoolF.deploy(oracleAddr, rTokenAddr, GMX.USDC);
    await swapPool.waitForDeployment();
    const swapPoolAddr = await swapPool.getAddress();

    console.log(`  ${mkt.symbol.padEnd(6)}: oracle=${oracleAddr}`);
    console.log(`  ${" ".repeat(6)}  rToken=${rTokenAddr}`);
    console.log(`  ${" ".repeat(6)}  pool  =${swapPoolAddr}`);
    console.log(`  ${" ".repeat(6)}  gmx   =${mkt.gmxMarket}`);

    deployedMarkets[mkt.symbol] = {
      marketId:  id,
      oracle:    oracleAddr,
      rToken:    rTokenAddr,
      swapPool:  swapPoolAddr,
      gmxMarket: mkt.gmxMarket,
      maxLtvBps: mkt.risk.maxLtv1xBps,
      lltvBps:   mkt.risk.maxLtv1xBps + mkt.risk.bufferBps,
    };

    // oracle setPrice → factory RLT 큐 자동 sync
    await (await oracle.configureRedemptionSync(await factory.getAddress())).wait();
  }

  // ── 5. RLT-redeem 버퍼 USDC 전송 ─────────────────────────────────────────
  const usdc = await ethers.getContractAt(
    ["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)"],
    GMX.USDC
  );
  const usdcBal: bigint = await (usdc as any).balanceOf(deployerAddr);
  if (usdcBal >= ADAPTER_USDC_BUFFER) {
    await (await (usdc as any).transfer(adapterAddr, ADAPTER_USDC_BUFFER)).wait();
    console.log(`\nTransferred ${ADAPTER_USDC_BUFFER / 10n ** 6n} USDC buffer → adapter`);
  } else {
    console.log(`\nSkipped USDC buffer (deployer USDC balance: ${usdcBal})`);
  }

  // ── 6. deployments JSON 저장 ─────────────────────────────────────────────
  const profile = `${network.name}-gmx`;
  const output = {
    profile,
    chainId:           network.config.chainId,
    vaultFactory:      factoryAddr,
    positionVaultImpl: implAddr,
    gmxAdapter:        adapterAddr,
    usdc:              GMX.USDC,
    gmxExchangeRouter: GMX.EXCHANGE_ROUTER,
    gmxReader:         GMX.READER,
    gmxDataStore:      GMX.DATA_STORE,
    gmxOrderVault:     GMX.ORDER_VAULT,
    markets:           deployedMarkets,
  };

  const outDir = path.join(process.cwd(), "deployments");
  await mkdir(outDir, { recursive: true });
  const outFile = path.join(outDir, `${profile}.json`);
  await writeFile(outFile, JSON.stringify(output, null, 2));

  console.log(`\nAddresses saved → ${outFile}`);
  console.log(`VaultFactory  : ${factoryAddr}`);
  console.log(`GmxV2Adapter  : ${adapterAddr}`);
  console.log(`USDC (GMX)    : ${GMX.USDC}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
