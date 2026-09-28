/**
 * deployGmxA1.ts — A1 배포 스크립트 (Arbitrum Sepolia)
 *
 * 실행:
 *   npx hardhat run scripts/deploy/deployGmxA1.ts --network arbitrumSepolia
 *
 * 이후 (Uniswap/rYield 재배포 없이):
 *   SKIP_LIQUIDITY=1 npx hardhat run scripts/setup/createRethUsdcPool.ts --network arbitrumSepolia
 *   npx hardhat test test/ryex/ --network arbitrumSepolia   # ryield.ts는 skip
 *
 * 결과: deployments/arbitrumSepolia-gmx.json (DEPLOY_PROFILE로 파일명 변경 가능)
 *
 * 필요 환경변수 (.env):
 *   PRIVATE_KEY=0x... 또는 MNEMONIC=...
 *
 * 마켓 oracle: GMX 연동 마켓 → GmxPriceOracle (ChainlinkPriceFeedProvider)
 * mock-only 마켓 → MockPriceOracle (setup/addMarket.ts)
 *
 * 마켓 추가:
 *   MARKET=rBTC npx hardhat run scripts/setup/addMarket.ts --network arbitrumSepolia
 */
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import { GMX, UNIV3 } from "../../config/gmxArbitrumSepolia";
import { deployFromForgeArtifact } from "../lib/artifact";
import { deployMarketOracle } from "./oracle/marketOracle";
import PositionVaultForge from "../../out/PositionVault.sol/PositionVault.json";

// ── 배포 상수 ──────────────────────────────────────────────────────────────
const VAULT_ETH_FUNDING = ethers.parseEther("0.02");  // vault GMX exec-fee (per clone, seed via receive)
const EXEC_FEE = ethers.parseEther("0.005");
const SWAP_FEE = 3000; // UniV3 0.3%

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
  symbol:       string;
  name:         string;
  gmxMarket:    string;
  risk:         RiskParams;
  borrowAprBps: number; // 마켓별 borrow/stability fee APR(bps) — 이후 factory.setBorrowAprBps로 조정 가능
}

// 초기 배포: ETH/USDC 마켓만. 추가 마켓은 scripts/setup/addMarket.ts 사용.
const MARKETS: MarketDef[] = [
  {
    symbol: "rETH", name: "RYex ETH",
    gmxMarket: GMX.MARKET_ETH,
    risk: { maxLtv1xBps: 6_500, bufferBps: 1_000, maxLtvAtMaxLevBps: 4_500, flatTier: 3, maxLeverage: 10 },
    borrowAprBps: 150, // 1.5%
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

  // ── 1. 라이브러리 + PositionVault 구현체 ───────────────────────────────────
  const GmxIntegrationReaderF = await ethers.getContractFactory("GmxIntegrationReader");
  const readerLib = await GmxIntegrationReaderF.deploy();
  await readerLib.waitForDeployment();
  const readerLibAddr = await readerLib.getAddress();
  console.log(`GmxIntegrationReader : ${readerLibAddr}`);

  const GmxOrderBuilderF = await ethers.getContractFactory("GmxOrderBuilder");
  const orderBuilderLib = await GmxOrderBuilderF.deploy();
  await orderBuilderLib.waitForDeployment();
  const orderBuilderLibAddr = await orderBuilderLib.getAddress();
  console.log(`GmxOrderBuilder      : ${orderBuilderLibAddr}`);

  const GmxExecutorF = await ethers.getContractFactory("GmxExecutor", {
    libraries: { GmxOrderBuilder: orderBuilderLibAddr },
  });
  const gmxLib = await GmxExecutorF.deploy();
  await gmxLib.waitForDeployment();
  const gmxLibAddr = await gmxLib.getAddress();
  console.log(`GmxExecutor        : ${gmxLibAddr}`);

  const DebtSettlerF = await ethers.getContractFactory("DebtSettler");
  const settleLib = await DebtSettlerF.deploy();
  await settleLib.waitForDeployment();
  const settleLibAddr = await settleLib.getAddress();
  console.log(`DebtSettler         : ${settleLibAddr}`);

  // VaultSettle: PositionVault 정산 상태머신 라이브러리 (내부에서 DebtSettler + GmxExecutor 링크)
  const VaultSettleF = await ethers.getContractFactory("VaultSettle", {
    libraries: { DebtSettler: settleLibAddr, GmxExecutor: gmxLibAddr },
  });
  const vaultSettleLib = await VaultSettleF.deploy();
  await vaultSettleLib.waitForDeployment();
  const vaultSettleLibAddr = await vaultSettleLib.getAddress();
  console.log(`VaultSettle         : ${vaultSettleLibAddr}`);

  const GmxFundingUtilsF = await ethers.getContractFactory("GmxFundingUtils");
  const gmxFundingUtils = await GmxFundingUtilsF.deploy();
  await gmxFundingUtils.waitForDeployment();
  const gmxFundingUtilsAddr = await gmxFundingUtils.getAddress();
  console.log(`GmxFundingUtils     : ${gmxFundingUtilsAddr}`);

  const GmxFundingAccruedViewF = await ethers.getContractFactory("GmxFundingAccruedView");
  const gmxFundingAccruedView = await GmxFundingAccruedViewF.deploy();
  await gmxFundingAccruedView.waitForDeployment();
  const gmxFundingAccruedViewAddr = await gmxFundingAccruedView.getAddress();
  console.log(`GmxFundingAccruedView : ${gmxFundingAccruedViewAddr}`);

  // AmmTwap: VaultFactory의 buybackAndBurn/buybackPreview가 쓰는 external 라이브러리(청산 buyback 가격조회).
  const AmmTwapF = await ethers.getContractFactory("AmmTwap");
  const ammTwap = await AmmTwapF.deploy();
  await ammTwap.waitForDeployment();
  const ammTwapAddr = await ammTwap.getAddress();
  console.log(`AmmTwap            : ${ammTwapAddr}`);

  // Hardhat artifact는 EIP-170 초과 → forge bytecode 사용.
  // PositionVault는 DebtSettler를 직접 링크하지 않음(VaultSettle 경유).
  const impl = await deployFromForgeArtifact(PositionVaultForge, deployer, [], {
    GmxIntegrationReader: readerLibAddr,
    GmxExecutor: gmxLibAddr,
    VaultSettle: vaultSettleLibAddr,
    GmxFundingUtils: gmxFundingUtilsAddr,
  });
  const implAddr = await impl.getAddress();
  console.log(`PositionVault impl : ${implAddr}`);

  // ── 2. VaultFactory ───────────────────────────────────────────────────────
  const VaultFactoryF = await ethers.getContractFactory("VaultFactory", {
    libraries: { AmmTwap: ammTwapAddr },
  });
  const factory = await VaultFactoryF.deploy(implAddr, GMX.USDC, deployerAddr);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log(`VaultFactory       : ${factoryAddr}`);

  const VaultLensF = await ethers.getContractFactory("VaultLens", {
    libraries: { GmxFundingAccruedView: gmxFundingAccruedViewAddr },
  });
  const vaultLens = await VaultLensF.deploy(factoryAddr);
  await vaultLens.waitForDeployment();
  const vaultLensAddr = await vaultLens.getAddress();
  console.log(`VaultLens          : ${vaultLensAddr}`);

  await (await factory.setGmxInfra({
    exchangeRouter: GMX.EXCHANGE_ROUTER,
    gmxRouter: GMX.ROUTER,
    orderVault: GMX.ORDER_VAULT,
    reader: GMX.READER,
    dataStore: GMX.DATA_STORE,
    orderHandler: GMX.ORDER_HANDLER,
    execFee: EXEC_FEE,
    acceptablePriceMax: ethers.MaxUint256,
    acceptablePriceMin: 1n,
  })).wait();
  console.log(`VaultFactory.setGmxInfra ✓`);
  console.log();

  // ── 3.5 RyexTreasury + RyexRouter ───────────────────────────────────────
  const RyexTreasuryF = await ethers.getContractFactory("RyexTreasury");
  const treasury = await RyexTreasuryF.deploy(deployerAddr);
  await treasury.waitForDeployment();
  const treasuryAddr = await treasury.getAddress();
  console.log(`RyexTreasury       : ${treasuryAddr}`);

  const RyexRouterF = await ethers.getContractFactory("RyexRouter");
  const router = await RyexRouterF.deploy(factoryAddr);
  await router.waitForDeployment();
  const routerAddr = await router.getAddress();
  console.log(`RyexRouter         : ${routerAddr}`);

  // Router만 vault.deposit을 호출 가능(onlyRouter)
  await (await factory.setRouter(routerAddr)).wait();
  await (await factory.setTreasury(treasuryAddr)).wait();
  await (await factory.setSwapRouter(UNIV3.SWAP_ROUTER, SWAP_FEE)).wait();
  console.log(`VaultFactory.setRouter ✓`);
  console.log(`VaultFactory.setTreasury ✓`);
  console.log(`VaultFactory.setSwapRouter ✓ (${UNIV3.SWAP_ROUTER})`);
  console.log();

  // ── 4. 마켓별 Oracle / rToken 배포 ───────────────────────────────────────
  const deployedMarkets: Record<string, object> = {};

  for (const mkt of MARKETS) {
    const id = mkId(mkt.symbol);

    const oracleAddr = await deployMarketOracle({ gmxMarket: mkt.gmxMarket });

    // rToken (factory.addMarket이 배포 → 이벤트에서 주소 파싱)
    const addTx = await factory.addMarket(
      id,
      oracleAddr,
      mkt.gmxMarket,
      mkt.name,
      mkt.symbol,
      mkt.risk,
      mkt.borrowAprBps
    );
    const addReceipt = await addTx.wait();
    const rTokenAddr = parseRToken(addReceipt);

    const price8 = await (await ethers.getContractAt("GmxPriceOracle", oracleAddr)).getPrice();
    console.log(`  ${mkt.symbol.padEnd(6)}: oracle=${oracleAddr}  price=$${ethers.formatUnits(price8, 8)}`);
    console.log(`  ${" ".repeat(6)}  rToken=${rTokenAddr}`);
    console.log(`  ${" ".repeat(6)}  gmx   =${mkt.gmxMarket}`);

    deployedMarkets[mkt.symbol] = {
      marketId:     id,
      oracle:       oracleAddr,
      rToken:       rTokenAddr,
      gmxMarket:    mkt.gmxMarket,
      maxLtvBps:    mkt.risk.maxLtv1xBps,
      lltvBps:      mkt.risk.maxLtv1xBps + mkt.risk.bufferBps,
      borrowAprBps: mkt.borrowAprBps,
      pool:         "", // setMarketPool은 scripts/setup/createRethUsdcPool.ts가 배포 후 이 파일에 다시 기록
    };

  }

  // ── 5. deployments JSON 저장 ─────────────────────────────────────────────
  const profile = process.env.DEPLOY_PROFILE ?? `${network.name}-gmx`;
  const outDir = path.join(process.cwd(), "deployments");
  await mkdir(outDir, { recursive: true });
  const outFile = path.join(outDir, `${profile}.json`);
  // 주의: 이 스크립트는 VaultFactory를 매번 새로 배포한다(REDEPLOY 가드 없음) — 그래서 factory 주소에
  // 종속된 값들(lpZap·UniV3 pool·rYield 스택 전부)은 이전 JSON에서 절대 이어받지 않고 항상 빈 값으로
  // 리셋한다. 안 그러면 옛 factory를 가리키는 주소가 새 JSON에 남아 프론트/키퍼가 오작동한다
  // (2026-09 재배포 때 실제로 이 문제로 수동 정리가 필요했음). lpZap·pool은 scripts/setup/createRethUsdcPool.ts가,
  // rYield 스택은 scripts/deploy/deployRYield.ts가 그 다음 단계에서 이 파일에 다시 채워 넣는다.
  const output = {
    profile,
    chainId:              network.config.chainId,
    vaultFactory:         factoryAddr,
    ryexTreasury:         treasuryAddr,
    ryexRouter:           routerAddr,
    positionVaultImpl:    implAddr,
    gmxIntegrationReader: readerLibAddr,
    gmxOrderBuilder:      orderBuilderLibAddr,
    gmxExecutor:          gmxLibAddr,
    debtSettler:          settleLibAddr,
    vaultSettle:          vaultSettleLibAddr,
    vaultLens:            vaultLensAddr,
    usdc:                 GMX.USDC,
    gmxExchangeRouter:    GMX.EXCHANGE_ROUTER,
    gmxReader:            GMX.READER,
    gmxDataStore:         GMX.DATA_STORE,
    gmxOrderVault:        GMX.ORDER_VAULT,
    swapRouter:           UNIV3.SWAP_ROUTER,
    swapFee:              SWAP_FEE,
    markets:              deployedMarkets,
    lpZap:                     "",
    ryieldRegistry:            "",
    ryieldViews:               "",
    ryieldVaults:              {},
    ryieldFundingDistributors: {},
    ammTwap:                   ammTwapAddr,
    gmxFundingUtils:           gmxFundingUtilsAddr,
    gmxFundingAccruedView:     gmxFundingAccruedViewAddr,
    updatedAt:                 new Date().toISOString(),
  };

  await writeFile(outFile, `${JSON.stringify(output, null, 2)}\n`);

  console.log(`\nAddresses saved → ${outFile}`);
  console.log(`VaultFactory  : ${factoryAddr}`);
  console.log(`RyexTreasury  : ${treasuryAddr}`);
  console.log(`RyexRouter    : ${routerAddr}`);
  console.log(`GmxIntegrationReader : ${readerLibAddr}`);
  console.log(`GmxOrderBuilder  : ${orderBuilderLibAddr}`);
  console.log(`GmxExecutor    : ${gmxLibAddr}`);
  console.log(`DebtSettler    : ${settleLibAddr}`);
  console.log(`VaultSettle    : ${vaultSettleLibAddr}`);
  console.log(`VaultLens      : ${vaultLensAddr}`);
  console.log(`GmxFundingUtils: ${gmxFundingUtilsAddr}`);
  console.log(`GmxFundingAccruedView : ${gmxFundingAccruedViewAddr}`);
  console.log(`AmmTwap       : ${ammTwapAddr}`);
  console.log(`USDC (GMX)    : ${GMX.USDC}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
