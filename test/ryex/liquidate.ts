/**
 * liquidate.ts — LLTV 전량 청산 통합 테스트 (Arbitrum Sepolia)
 *
 * LTV >= LLTV 일 때 누구나 liquidate() 호출 → GMX close → executor 정산 → Empty (재사용 가능)
 *
 * 실행:
 *   npx hardhat test test/ryex/liquidate.ts --network arbitrumSepolia
 */
import { expect } from "chai";
import type { Contract } from "ethers";
import { ethers } from "hardhat";
import {
  EXEC_FEE,
  VaultState,
  ensureActiveVault,
  fundEth,
  isLiquidatable,
  loadDeployment,
  mintMaxRToken,
  pushToLiquidationZone,
  readVaultRisk,
  repayAllDebt,
  resetOraclePrice,
  settlePendingOrder,
  type Deployment,
} from "./helpers";

const MARKET_SYMBOL = "rETH";

describe("Vault Liquidation — LLTV (Arbitrum Sepolia)", function () {
  this.timeout(10 * 60_000);

  let deployment: Deployment;
  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let liquidator: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let vaultAddr: string;
  let vault: Contract;
  let oracleAddr: string;
  let rTokenAddr: string;

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    liquidator = signers[2]; // 3rd party liquidator
    deployment = await loadDeployment();

    const mkt = deployment.markets[MARKET_SYMBOL];
    oracleAddr = mkt.oracle;
    rTokenAddr = mkt.rToken;

    console.log(`\nOwner       : ${await owner.getAddress()}`);
    console.log(`Liquidator  : ${await liquidator.getAddress()} (3rd party)`);

    vaultAddr = await ensureActiveVault(owner, deployment, MARKET_SYMBOL);
    vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);

    await fundEth(owner, await liquidator.getAddress());
    await repayAllDebt(vaultAddr, owner, rTokenAddr, [signers[1], liquidator]);
    await resetOraclePrice(oracleAddr, owner);
    console.log(`Vault       : ${vaultAddr}`);
  });

  it("1. liquidate reverts when LTV below LLTV", async () => {
    const ltv = await vault.currentLTV();
    const lltv = await vault.lltvBps();
    console.log(`  LTV=${ltv} bps  LLTV=${lltv} bps`);
    expect(await isLiquidatable(vaultAddr)).to.equal(false);

    const vaultAsLiq = await ethers.getContractAt("PositionVault", vaultAddr, liquidator);
    await expect(vaultAsLiq.liquidate({ value: EXEC_FEE }))
      .to.be.revertedWithCustomError(vault, "NotLiquidatable");
  });

  it("2. enter liquidation zone (LTV >= LLTV)", async () => {
    const minted = await mintMaxRToken(vaultAddr, owner, oracleAddr);
    expect(minted).to.be.gt(0n);
    console.log(`  minted to max : ${ethers.formatUnits(minted, 18)} rToken`);

    await pushToLiquidationZone(vaultAddr, oracleAddr, owner);

    const risk = await readVaultRisk(vault, oracleAddr);
    const lltv = await vault.lltvBps();
    console.log(`  LTV           : ${risk.currentLtvBps} bps`);
    console.log(`  LLTV          : ${lltv} bps`);
    console.log(`  isLiquidatable: ${await isLiquidatable(vaultAddr)}`);

    expect(risk.currentLtvBps).to.be.gte(lltv);
    expect(await isLiquidatable(vaultAddr)).to.equal(true);
  });

  it("3. third party triggers liquidate → SettlingLiquidate", async () => {
    const vaultAsLiq = await ethers.getContractAt("PositionVault", vaultAddr, liquidator);
    const tx = await vaultAsLiq.liquidate({ value: EXEC_FEE });
    const rc = await tx.wait();
    console.log(`  liquidate tx  : ${rc?.hash}`);

    const state: bigint = await vault.state();
    expect(state).to.equal(VaultState.SettlingLiquidate);

    const pending = await vault.pending();
    expect(pending.orderKey).to.not.equal(ethers.ZeroHash);
  });

  // it("4. GMX close settles → vault returns to Empty", async () => {
  //   console.log("  → Waiting for GMX keeper to close position…");
  //   await settlePendingOrder(vaultAddr, deployment.gmxAdapter, owner, true);

  //   const finalState: bigint = await vault.state();
  //   const debtAfter: bigint = await vault.debt();
  //   console.log(`  final state   : ${finalState} (expected ${VaultState.Empty})`);
  //   console.log(`  debt after    : ${ethers.formatUnits(debtAfter, 18)}`);

  //   expect(finalState).to.equal(VaultState.Empty);
  //   expect(debtAfter).to.equal(0n);
  // });

  it("5. cannot liquidate without active position", async () => {
    const vaultAsLiq = await ethers.getContractAt("PositionVault", vaultAddr, liquidator);
    await expect(vaultAsLiq.liquidate({ value: EXEC_FEE }))
      .to.be.revertedWithCustomError(vault, "BadState");
  });

  it("6. same vault can open a new position", async () => {
    await resetOraclePrice(oracleAddr, owner);
    const reused = await ensureActiveVault(owner, deployment, MARKET_SYMBOL);
    expect(reused).to.equal(vaultAddr);
    expect(await vault.state()).to.equal(VaultState.Active);
    expect(await vault.gmxPosition()).to.have.property("exists", true);
  });
});
