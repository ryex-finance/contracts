/**
 * deployRYield.ts — rYield 풀링 델타뉴트럴 볼트 배포 (Arbitrum Sepolia)
 *
 * 기존 VaultFactory + GMX 라이브러리(GmxIntegrationReader/GmxExecutor)에 RYieldVault를
 * 독립 배포(clone 아님)하고, deployments JSON에 ryieldVault를 추가한다.
 *
 * 실행:
 *   DEPLOY_PROFILE=arbitrumSepolia-gmx \
 *   MARKET=rETH \
 *   npx hardhat run scripts/deploy/deployRYield.ts --network arbitrumSepolia
 *
 * 전제: deployGmxA1.ts가 이미 실행되어 factory/라이브러리/마켓이 배포·등록됨.
 *
 * 재실행: ryieldVaults.<MARKET>가 JSON에 있고 온체인 코드가 있으면 vault/distributor 배포를
 *         스킵하고 Registry 등록만 확인한다. 강제 재배포는 REDEPLOY=1.
 */
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import { UNIV3 } from "../../config/gmxArbitrumSepolia";
import { dataStoreGetAddress, getGmxDataStore } from "../lib/gmxDataStore";

const MARKET = process.env.MARKET ?? "rETH";
const VAULT_ETH_FUNDING = ethers.parseEther("0.01"); // GMX exec-fee seed
const FORCE_REDEPLOY = process.env.REDEPLOY === "1";

type DepJson = {
  vaultFactory: string;
  ryexTreasury: string;
  gmxIntegrationReader: string;
  gmxExecutor: string;
  usdc: string;
  swapFee: number;
  ryieldVaults?: Record<string, string>;
  ryieldFundingDistributors?: Record<string, string>;
  ryieldRegistry?: string;
  ryieldViews?: string;
  ammTwap?: string;
  gmxFundingUtils?: string;
  gmxFundingAccruedView?: string;
  gmxDataStore?: string;
  markets: Record<string, { marketId: string; rToken: string; gmxMarket?: string }>;
};

async function ensureRegistry(
  dep: DepJson,
  deployerAddr: string,
  marketId: string,
  vaultAddr: string,
  distributorAddr: string,
): Promise<string> {
  let ryieldViewsAddr = dep.ryieldViews;
  if (!ryieldViewsAddr) {
    let ammTwapAddr = dep.ammTwap;
    if (!ammTwapAddr) {
      const AmmTwapF = await ethers.getContractFactory("AmmTwap");
      const ammTwap = await AmmTwapF.deploy();
      await ammTwap.waitForDeployment();
      ammTwapAddr = await ammTwap.getAddress();
      dep.ammTwap = ammTwapAddr;
      console.log(`AmmTwap            : ${ammTwapAddr}`);
    }
    const RYieldViewsF = await ethers.getContractFactory("RYieldViews", {
      libraries: { AmmTwap: ammTwapAddr },
    });
    const ryieldViews = await RYieldViewsF.deploy();
    await ryieldViews.waitForDeployment();
    ryieldViewsAddr = await ryieldViews.getAddress();
    dep.ryieldViews = ryieldViewsAddr;
    console.log(`RYieldViews          : ${ryieldViewsAddr}`);
  }

  let registryAddr = dep.ryieldRegistry;
  if (!registryAddr) {
    const RegistryF = await ethers.getContractFactory("RYieldRegistry", {
      libraries: { RYieldViews: ryieldViewsAddr },
    });
    const registry = await RegistryF.deploy(dep.vaultFactory, deployerAddr);
    await registry.waitForDeployment();
    registryAddr = await registry.getAddress();
    dep.ryieldRegistry = registryAddr;
    console.log(`RYieldRegistry       : ${registryAddr}`);
  }

  const registry = await ethers.getContractAt("RYieldRegistry", registryAddr);
  const existing = await registry.vaultOf(marketId);
  if (existing === ethers.ZeroAddress) {
    await (await registry.register(marketId, vaultAddr, distributorAddr)).wait();
    console.log(`  registered ${MARKET} on RYieldRegistry`);
  } else if (existing.toLowerCase() !== vaultAddr.toLowerCase()) {
    console.warn(
      `  WARN: RYieldRegistry ${MARKET} → ${existing}, JSON vault → ${vaultAddr}. ` +
        `Use registry.replaceVault() to migrate.`,
    );
  } else {
    console.log(`  RYieldRegistry already has ${MARKET} → ${existing}`);
  }

  return registryAddr;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddr = await deployer.getAddress();

  const profile = process.env.DEPLOY_PROFILE ?? `${network.name}-gmx`;
  const file = path.join(process.cwd(), "deployments", `${profile}.json`);
  const dep = JSON.parse(await readFile(file, "utf8")) as DepJson;

  const market = dep.markets[MARKET];
  if (!market) throw new Error(`market ${MARKET} not in ${file}`);

  console.log(`Network  : ${network.name}`);
  console.log(`Deployer : ${deployerAddr}`);
  console.log(`Factory  : ${dep.vaultFactory}`);
  console.log(`Market   : ${MARKET} (${market.marketId})`);
  console.log(`rToken   : ${market.rToken}`);
  console.log();

  const existingVault = dep.ryieldVaults?.[MARKET];
  const existingDist = dep.ryieldFundingDistributors?.[MARKET];
  if (
    !FORCE_REDEPLOY &&
    existingVault &&
    existingVault !== ethers.ZeroAddress &&
    existingDist &&
    existingDist !== ethers.ZeroAddress
  ) {
    const vaultCode = await ethers.provider.getCode(existingVault);
    const distCode = await ethers.provider.getCode(existingDist);
    if (vaultCode !== "0x" && distCode !== "0x") {
      console.log(`RYieldVault (${MARKET}) already deployed: ${existingVault}`);
      console.log(`RYieldFundingDistributor : ${existingDist}`);
      await ensureRegistry(dep, deployerAddr, market.marketId, existingVault, existingDist);
      await writeFile(file, `${JSON.stringify(dep, null, 2)}\n`);
      console.log(`\nSkipped redeploy — existing ${MARKET} vault kept → ${file}`);
      return;
    }
  }

  // UniV3 rToken/USDC 풀 주소 조회 (AMM 가격 게이트용). 없으면 0 — owner가 추후 setPool.
  const univ3Factory = await ethers.getContractAt(
    ["function getPool(address,address,uint24) view returns (address)"],
    UNIV3.FACTORY,
  );
  const pool: string = await univ3Factory.getPool(market.rToken, dep.usdc, dep.swapFee ?? 3000);
  console.log(`AMM pool : ${pool}${pool === ethers.ZeroAddress ? " (none — setPool later)" : ""}`);
  console.log();

  // AmmTwap 외부 라이브러리 배포(가격 게이트·price impact). GmxIntegrationReader/GmxExecutor는 기존 배포분 재사용.
  const AmmTwapF = await ethers.getContractFactory("AmmTwap");
  const ammTwap = await AmmTwapF.deploy();
  await ammTwap.waitForDeployment();
  const ammTwapAddr = await ammTwap.getAddress();
  console.log(`AmmTwap            : ${ammTwapAddr}`);

  // GmxFundingUtils 외부 라이브러리 배포(펀딩비 수거 오케스트레이션 — vault 코드 크기 절감용).
  const GmxFundingUtilsF = await ethers.getContractFactory("GmxFundingUtils");
  const gmxFundingUtils = await GmxFundingUtilsF.deploy();
  await gmxFundingUtils.waitForDeployment();
  const gmxFundingUtilsAddr = await gmxFundingUtils.getAddress();
  console.log(`GmxFundingUtils    : ${gmxFundingUtilsAddr}`);

  // GmxFundingAccruedView — accrued(미 settle) 펀딩비 조회용 external 라이브러리.
  const GmxFundingAccruedViewF = await ethers.getContractFactory("GmxFundingAccruedView");
  const gmxFundingAccruedView = await GmxFundingAccruedViewF.deploy();
  await gmxFundingAccruedView.waitForDeployment();
  const gmxFundingAccruedViewAddr = await gmxFundingAccruedView.getAddress();
  console.log(`GmxFundingAccruedView : ${gmxFundingAccruedViewAddr}`);

  const RYieldVaultF = await ethers.getContractFactory("RYieldVault", {
    libraries: {
      GmxIntegrationReader: dep.gmxIntegrationReader,
      GmxExecutor: dep.gmxExecutor,
      AmmTwap: ammTwapAddr,
      GmxFundingUtils: gmxFundingUtilsAddr,
      GmxFundingAccruedView: gmxFundingAccruedViewAddr,
    },
  });

  const vault = await RYieldVaultF.deploy(
    dep.vaultFactory,
    market.marketId,
    deployerAddr, // owner (governance)
    dep.ryexTreasury, // treasury (성과수수료)
    pool, // AMM 가격 게이트용 UniV3 풀 (0 = 추후 setPool)
  );
  await vault.waitForDeployment();
  const vaultAddr = await vault.getAddress();
  console.log(`RYieldVault (${MARKET}) : ${vaultAddr}`);

  await (await vault.setAssetName(`rYield ${MARKET}`)).wait();

  // GMX funding fee distributor (vault별 1:1, long·short 토큰 스왑 없이 배분)
  const gmxMarket = dep.markets[MARKET].gmxMarket;
  if (!gmxMarket) throw new Error(`markets.${MARKET}.gmxMarket missing in ${file}`);
  const dataStoreAddr = dep.gmxDataStore;
  if (!dataStoreAddr) throw new Error(`gmxDataStore missing in ${file}`);
  const dataStore = await getGmxDataStore(dataStoreAddr);
  const LONG_TOKEN = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["LONG_TOKEN"]));
  const SHORT_TOKEN = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["SHORT_TOKEN"]));
  const longTokenKey = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(["address", "bytes32"], [gmxMarket, LONG_TOKEN]),
  );
  const shortTokenKey = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(["address", "bytes32"], [gmxMarket, SHORT_TOKEN]),
  );
  const longToken: string = await dataStoreGetAddress(dataStore, longTokenKey);
  const shortToken: string = await dataStoreGetAddress(dataStore, shortTokenKey);
  console.log(`GMX market  : ${gmxMarket}`);
  console.log(`longToken   : ${longToken}`);
  console.log(`shortToken  : ${shortToken}`);

  const DistributorF = await ethers.getContractFactory("RYieldFundingDistributor");
  const distributor = await DistributorF.deploy(vaultAddr, gmxMarket, dataStoreAddr, longToken, shortToken);
  await distributor.waitForDeployment();
  const distributorAddr = await distributor.getAddress();
  console.log(`RYieldFundingDistributor : ${distributorAddr}`);

  await (await vault.setFundingDistributor(distributorAddr)).wait();

  // GMX exec-fee 시드 (rebalance/unwind 시 GMX가 vault ETH 잔고에서 차감)
  await (await deployer.sendTransaction({ to: vaultAddr, value: VAULT_ETH_FUNDING })).wait();
  console.log(`  funded ${ethers.formatEther(VAULT_ETH_FUNDING)} ETH for exec fee`);

  dep.ryieldVaults = { ...(dep.ryieldVaults ?? {}), [MARKET]: vaultAddr };
  dep.ryieldFundingDistributors = { ...(dep.ryieldFundingDistributors ?? {}), [MARKET]: distributorAddr };
  dep.ammTwap = ammTwapAddr;
  dep.gmxFundingUtils = gmxFundingUtilsAddr;
  dep.gmxFundingAccruedView = gmxFundingAccruedViewAddr;

  await ensureRegistry(dep, deployerAddr, market.marketId, vaultAddr, distributorAddr);

  await writeFile(file, `${JSON.stringify(dep, null, 2)}\n`);
  console.log(
    `\nSaved ryieldVaults.${MARKET} + ryieldFundingDistributors.${MARKET} (+ammTwap +gmxFundingUtils +gmxFundingAccruedView +ryieldViews +ryieldRegistry) → ${file}`,
  );
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
