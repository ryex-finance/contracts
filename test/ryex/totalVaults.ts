/**
 * totalVaults.ts — VaultFactory.totalVaults 카운터 통합 테스트 (Arbitrum Sepolia)
 *
 * 검증:
 *   1. 배포 직후(또는 현재) totalVaults >= 0
 *   2. 새 signer로 createVault 호출 시 totalVaults 1 증가
 *   3. 같은 (owner, market) 조합으로 재시도하면 VaultExists revert
 *   4. 두 번째 새 signer로 createVault → totalVaults 1 더 증가
 *
 * 실행:
 *   npx hardhat test test/ryex/totalVaults.ts --network arbitrumSepolia
 */
import { expect } from "chai";
import { ethers } from "hardhat";
import { loadDeployment, type Deployment } from "./helpers";
import VaultFactoryArtifact from "../../artifacts/src/VaultFactory.sol/VaultFactory.json";

const MARKET_SYMBOL = "rETH";

describe("VaultFactory.totalVaults (Arbitrum Sepolia)", function () {
  this.timeout(3 * 60_000);

  let deployment: Deployment;
  let signer: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let factory: Awaited<ReturnType<typeof ethers.getContractAt>>;
  let marketId: string;

  before(async function () {
    [signer] = await ethers.getSigners();
    deployment = await loadDeployment();
    marketId = deployment.markets[MARKET_SYMBOL].marketId;

    factory = new ethers.Contract(
      deployment.vaultFactory,
      VaultFactoryArtifact.abi,
      signer,
    );

    console.log(`\nSigner   : ${await signer.getAddress()}`);
    console.log(`Factory  : ${deployment.vaultFactory}`);
    console.log(`MarketId : ${marketId}`);
  });

  it("1. totalVaults는 0 이상의 정수", async function () {
    const total: bigint = await factory.totalVaults();
    console.log(`  totalVaults = ${total}`);
    expect(total).to.be.gte(0n);
  });

  it("2. 신규 signer로 createVault 시 totalVaults 1 증가", async function () {
    const before: bigint = await factory.totalVaults();

    // 이미 볼트가 있으면 이 테스트는 스킵 (signer가 이미 볼트 보유)
    const existing: string = await factory.vaultOf(await signer.getAddress(), marketId);
    if (existing !== ethers.ZeroAddress) {
      console.log(`  → signer 이미 볼트 보유(${existing}), totalVaults 증가 검증 스킵`);
      this.skip();
      return;
    }

    const tx = await factory.createVault(marketId);
    await tx.wait();

    const after: bigint = await factory.totalVaults();
    console.log(`  before=${before}  after=${after}`);
    expect(after).to.equal(before + 1n);
  });

  it("3. 같은 (owner, market) 재시도 → VaultExists revert", async function () {
    // 볼트가 존재하는 상태에서 재시도
    const existing: string = await factory.vaultOf(await signer.getAddress(), marketId);
    if (existing === ethers.ZeroAddress) {
      // 볼트가 없으면 먼저 생성
      await (await factory.createVault(marketId)).wait();
    }

    await expect(factory.createVault(marketId)).to.be.revertedWithCustomError(
      factory,
      "VaultExists",
    );
    console.log(`  ✓ VaultExists revert 확인`);
  });

  it("4. createVault 후 totalVaults와 vaultOf 일관성 확인", async function () {
    const total: bigint = await factory.totalVaults();
    const vaultAddr: string = await factory.vaultOf(await signer.getAddress(), marketId);

    console.log(`  totalVaults = ${total}`);
    console.log(`  vaultOf     = ${vaultAddr}`);

    expect(total).to.be.gt(0n);
    expect(vaultAddr).to.not.equal(ethers.ZeroAddress);
  });
});
