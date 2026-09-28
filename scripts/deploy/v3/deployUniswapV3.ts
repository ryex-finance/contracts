import { expect } from "chai";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import { GMX, UNIV3 } from "../../../config/gmxArbitrumSepolia";
import { deployFromArtifact } from "../../lib/artifact";
import { UNISWAP_DEPLOY_ARTIFACTS } from "../../lib/uniswapArtifacts";

type DeployConfig = {
  nativeLabel: string;
  existingWeth9: string;
  deployMockTokens: boolean;
  mintMockTokens: boolean;
  mintAmount: bigint;
  /** true면 기존 배포 주소를 JSON에 기록만 (재배포 안 함) */
  syncExisting: boolean;
};

const DEPLOY_CONFIG_BY_NETWORK: Record<string, DeployConfig> = {
  hardhat: {
    nativeLabel: "ETH",
    existingWeth9: "",
    deployMockTokens: true,
    mintMockTokens: true,
    mintAmount: ethers.parseEther("1000000"),
    syncExisting: false,
  },
  arbitrumSepolia: {
    nativeLabel: "ETH",
    existingWeth9: GMX.TOKEN_WETH,
    deployMockTokens: false,
    mintMockTokens: false,
    mintAmount: ethers.parseEther("1000000"),
    syncExisting: true,
  },
};

type UniDeployment = {
  network: string;
  deployer: string;
  weth9: string;
  factory: string;
  swapRouter: string;
  nftDescriptorLibrary?: string;
  positionDescriptor?: string;
  nonfungiblePositionManager: string;
  quoter?: string;
  quoterV2?: string;
  tickLens?: string;
  mockTokenA?: string;
  mockTokenB?: string;
};

async function syncExistingDeployment(
  deployerAddress: string,
  outPath: string,
): Promise<UniDeployment> {
  let existing: Partial<UniDeployment> = {};
  try {
    existing = JSON.parse(await readFile(outPath, "utf8")) as Partial<UniDeployment>;
  } catch {}

  const output: UniDeployment = {
    network: network.name,
    deployer: deployerAddress,
    weth9: existing.weth9 ?? GMX.TOKEN_WETH,
    factory: existing.factory ?? UNIV3.FACTORY,
    swapRouter: existing.swapRouter ?? UNIV3.SWAP_ROUTER,
    nftDescriptorLibrary: existing.nftDescriptorLibrary,
    positionDescriptor: existing.positionDescriptor,
    nonfungiblePositionManager: existing.nonfungiblePositionManager ?? UNIV3.NPM,
    quoter: existing.quoter,
    quoterV2: existing.quoterV2,
    tickLens: existing.tickLens,
    mockTokenA: existing.mockTokenA ?? "",
    mockTokenB: existing.mockTokenB ?? "",
  };

  await mkdir(path.dirname(outPath), { recursive: true });
  await writeFile(outPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
  return output;
}

describe("UniswapV3 Deploy (Hardhat)", function () {
  this.timeout(600_000);

  it("deploys v3 stack and writes deployment json", async function () {
    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    const cfg = DEPLOY_CONFIG_BY_NETWORK[network.name];
    if (!cfg) {
      throw new Error(`배포 설정이 없는 네트워크입니다: ${network.name}`);
    }

    const outPath = path.join(process.cwd(), "deployments", `univ3.${network.name}.json`);

    console.log(`network=${network.name}`);
    console.log(`deployer=${deployerAddress}`);

    if (cfg.syncExisting && process.env.REDEPLOY_UNIV3 !== "1") {
      const output = await syncExistingDeployment(deployerAddress, outPath);
      console.log("synced existing UniV3 deployment (set REDEPLOY_UNIV3=1 to force redeploy)");
      console.log(output);
      console.log(`saved=${outPath}`);
      return;
    }

    let weth9 = "";
    if (cfg.existingWeth9) {
      weth9 = cfg.existingWeth9;
    } else {
      const weth = await (await ethers.getContractFactory("WETH9")).deploy();
      await weth.waitForDeployment();
      weth9 = await weth.getAddress();
    }

    const A = UNISWAP_DEPLOY_ARTIFACTS;
    const factory = await deployFromArtifact(A.UniswapV3Factory, deployer);
    const factoryAddr = await factory.getAddress();

    const router = await deployFromArtifact(A.SwapRouter, deployer, [factoryAddr, weth9]);
    const nftDescriptorLib = await deployFromArtifact(A.NFTDescriptor, deployer);
    const nftLibAddr = await nftDescriptorLib.getAddress();

    const descriptor = await deployFromArtifact(
      A.NonfungibleTokenPositionDescriptor,
      deployer,
      [weth9, ethers.encodeBytes32String(cfg.nativeLabel)],
      { NFTDescriptor: nftLibAddr },
    );

    const npm = await deployFromArtifact(A.NonfungiblePositionManager, deployer, [
      factoryAddr,
      weth9,
      await descriptor.getAddress(),
    ]);

    const quoter = await deployFromArtifact(A.Quoter, deployer, [factoryAddr, weth9]);
    const quoterV2 = await deployFromArtifact(A.QuoterV2, deployer, [factoryAddr, weth9]);
    const tickLens = await deployFromArtifact(A.TickLens, deployer);

    let tokenA = "";
    let tokenB = "";

    if (cfg.deployMockTokens) {
      const erc20Factory = await ethers.getContractFactory("ERC20PresetMinterPauser");
      const t0 = await erc20Factory.deploy("Mock Token A", "MTA");
      await t0.waitForDeployment();
      const t1 = await erc20Factory.deploy("Mock Token B", "MTB");
      await t1.waitForDeployment();

      tokenA = await t0.getAddress();
      tokenB = await t1.getAddress();

      if (cfg.mintMockTokens) {
        await (await t0.mint(deployerAddress, cfg.mintAmount)).wait();
        await (await t1.mint(deployerAddress, cfg.mintAmount)).wait();
      }
    }

    const output: UniDeployment = {
      network: network.name,
      deployer: deployerAddress,
      weth9,
      factory: factoryAddr,
      swapRouter: await router.getAddress(),
      nftDescriptorLibrary: nftLibAddr,
      positionDescriptor: await descriptor.getAddress(),
      nonfungiblePositionManager: await npm.getAddress(),
      quoter: await quoter.getAddress(),
      quoterV2: await quoterV2.getAddress(),
      tickLens: await tickLens.getAddress(),
      mockTokenA: tokenA,
      mockTokenB: tokenB,
    };

    expect(output.factory).to.properAddress;
    expect(output.swapRouter).to.properAddress;
    expect(output.nonfungiblePositionManager).to.properAddress;

    console.log(output);

    await mkdir(path.dirname(outPath), { recursive: true });
    await writeFile(outPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
    console.log(`saved=${outPath}`);
  });
});
