import { expect } from "chai";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import {
  ERC20PresetMinterPauser__factory,
  NonfungiblePositionManager__factory,
  NFTDescriptor__factory,
  Quoter__factory,
  QuoterV2__factory,
  SwapRouter__factory,
  TickLens__factory,
  UniswapV3Factory__factory,
  WETH9__factory,
} from "../../typechain-types";

type DeployConfig = {
  nativeLabel: string;
  existingWeth9: string; // empty string => deploy new WETH9
  deployMockTokens: boolean;
  mintMockTokens: boolean;
  mintAmount: bigint;
};

const DEPLOY_CONFIG_BY_NETWORK: Record<string, DeployConfig> = {
  hardhat: {
    nativeLabel: "ETH",
    existingWeth9: "",
    deployMockTokens: true,
    mintMockTokens: true,
    mintAmount: ethers.parseEther("1000000"),
  },
  arbitrumSepolia: {
    nativeLabel: "ETH",
    existingWeth9: "0x980B62Da83eFf3D4576C647993b0c1D7faf17c73", // 공식 WETH9
    deployMockTokens: false,
    mintMockTokens: false,
    mintAmount: ethers.parseEther("1000000"),
  },
};

describe("UniswapV3 Deploy (Hardhat)", function () {
  it("deploys v3 stack and writes deployment json", async function () {
    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    const cfg = DEPLOY_CONFIG_BY_NETWORK[network.name];
    if (!cfg) {
      throw new Error(`배포 설정이 없는 네트워크입니다: ${network.name}`);
    }

    console.log(`network=${network.name}`);
    console.log(`deployer=${deployerAddress}`);

    let weth9 = "";
    if (cfg.existingWeth9 && cfg.existingWeth9.length > 0) {
      weth9 = cfg.existingWeth9;
    } else {
      const weth = await new WETH9__factory(deployer).deploy();
      await weth.waitForDeployment();
      weth9 = await weth.getAddress();
    }

    const factory = await new UniswapV3Factory__factory(deployer).deploy();
    await factory.waitForDeployment();

    const router = await new SwapRouter__factory(deployer).deploy(await factory.getAddress(), weth9);
    await router.waitForDeployment();

    const nftDescriptorLib = await new NFTDescriptor__factory(deployer).deploy();
    await nftDescriptorLib.waitForDeployment();

    const descriptorFactory = await ethers.getContractFactory("NonfungibleTokenPositionDescriptor", {
      libraries: {
        NFTDescriptor: await nftDescriptorLib.getAddress(),
      },
    });
    const descriptor = await descriptorFactory
      .connect(deployer)
      .deploy(weth9, ethers.encodeBytes32String(cfg.nativeLabel));
    await descriptor.waitForDeployment();

    const npm = await new NonfungiblePositionManager__factory(deployer).deploy(
      await factory.getAddress(),
      weth9,
      await descriptor.getAddress(),
    );
    await npm.waitForDeployment();

    const quoter = await new Quoter__factory(deployer).deploy(await factory.getAddress(), weth9);
    await quoter.waitForDeployment();

    const quoterV2 = await new QuoterV2__factory(deployer).deploy(await factory.getAddress(), weth9);
    await quoterV2.waitForDeployment();

    const tickLens = await new TickLens__factory(deployer).deploy();
    await tickLens.waitForDeployment();

    let tokenA = "";
    let tokenB = "";

    if (cfg.deployMockTokens) {
      const t0 = await new ERC20PresetMinterPauser__factory(deployer).deploy("Mock Token A", "MTA");
      await t0.waitForDeployment();
      const t1 = await new ERC20PresetMinterPauser__factory(deployer).deploy("Mock Token B", "MTB");
      await t1.waitForDeployment();

      tokenA = await t0.getAddress();
      tokenB = await t1.getAddress();

      if (cfg.mintMockTokens) {
        await (await t0.mint(deployerAddress, cfg.mintAmount)).wait();
        await (await t1.mint(deployerAddress, cfg.mintAmount)).wait();
      }
    }

    const output = {
      network: network.name,
      deployer: deployerAddress,
      weth9,
      factory: await factory.getAddress(),
      swapRouter: await router.getAddress(),
      nftDescriptorLibrary: await nftDescriptorLib.getAddress(),
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

    const outDir = path.join(process.cwd(), "deployments");
    await mkdir(outDir, { recursive: true });
    const outPath = path.join(outDir, `univ3.${network.name}.json`);
    await writeFile(outPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
    console.log(`saved=${outPath}`);
  });
});
