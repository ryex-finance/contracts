/**
 * rTokenMint.ts — rToken mint LTV 한도 통합 테스트 (Arbitrum Sepolia)
 *
 * 검증:
 *   - 포지션 net value(collateralValueUsdWad) × effectiveMaxLtv 기준 mint 한도 계산
 *   - 한도 초과 mint → ExceedsMaxLTV revert
 *   - 한도 이내 mint → 성공, currentLTV <= effectiveMaxLtvBps
 *
 * 실행:
 *   npx hardhat test test/ryex/rTokenMint.ts --network arbitrumSepolia
 */
import { expect } from "chai";
import type { Contract } from "ethers";
import { ethers } from "hardhat";
import {
  VaultState,
  ensureActiveVault,
  loadDeployment,
  maxMintableRToken,
  readVaultRisk,
  repayAllDebt,
  type Deployment,
} from "./helpers";

const MARKET_SYMBOL = "rETH";

describe("rToken Mint — LTV limit (Arbitrum Sepolia)", function () {
  this.timeout(8 * 60_000);

  let deployment: Deployment;
  let signer: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let vaultAddr: string;
  let vault: Contract;
  let rTokenAddr: string;

  before(async function () {
    [signer] = await ethers.getSigners();
    deployment = await loadDeployment();
    rTokenAddr = deployment.markets[MARKET_SYMBOL].rToken;

    console.log(`\nSigner  : ${await signer.getAddress()}`);
    console.log(`rToken  : ${rTokenAddr}`);

    vaultAddr = await ensureActiveVault(signer, deployment, MARKET_SYMBOL);
    vault = await ethers.getContractAt("PositionVault", vaultAddr, signer);
    await repayAllDebt(vaultAddr, signer, deployment.markets[MARKET_SYMBOL].rToken);
    console.log(`Vault   : ${vaultAddr} (Active, debt cleared)`);
  });

  it("1. active vault has positive collateral net value", async () => {
    const risk = await readVaultRisk(vault, deployment.markets[MARKET_SYMBOL].oracle);
    console.log(`  collateralValueUsdWad : ${ethers.formatUnits(risk.collateralValueUsdWad, 18)} USD`);
    console.log(`  effectiveMaxLtvBps    : ${risk.effectiveMaxLtvBps} (${Number(risk.effectiveMaxLtvBps) / 100}%)`);
    console.log(`  oraclePrice8          : ${ethers.formatUnits(risk.oraclePrice8, 8)}`);

    expect(await vault.state()).to.equal(VaultState.Active);
    expect(risk.collateralValueUsdWad).to.be.gt(0n);
    expect(risk.effectiveMaxLtvBps).to.be.gt(0n);
  });

  it("2. mints within LTV limit (95% of headroom)", async () => {
    const riskBefore = await readVaultRisk(vault, deployment.markets[MARKET_SYMBOL].oracle);
    const headroom = maxMintableRToken(
      riskBefore.collateralValueUsdWad,
      riskBefore.debtValueUsdWad,
      riskBefore.effectiveMaxLtvBps,
      riskBefore.oraclePrice8,
    );
    const mintAmount = (headroom * 95n) / 100n;
    expect(mintAmount).to.be.gt(0n);

    const rToken = new ethers.Contract(
      rTokenAddr,
      ["function balanceOf(address) view returns (uint256)"],
      signer,
    );
    const balBefore: bigint = await rToken.balanceOf(await signer.getAddress());

    console.log(`  minting           : ${ethers.formatUnits(mintAmount, 18)} rToken`);
    const mintTx = await vault.mint(mintAmount);
    await mintTx.wait();

    const riskAfter = await readVaultRisk(vault, deployment.markets[MARKET_SYMBOL].oracle);
    const balAfter: bigint = await rToken.balanceOf(await signer.getAddress());

    console.log(`  debt before/after : ${ethers.formatUnits(riskBefore.debtRToken, 18)} → ${ethers.formatUnits(riskAfter.debtRToken, 18)}`);
    console.log(`  LTV before/after  : ${riskBefore.currentLtvBps} → ${riskAfter.currentLtvBps} bps`);
    console.log(`  max LTV (eff)     : ${riskAfter.effectiveMaxLtvBps} bps`);

    expect(riskAfter.debtRToken).to.equal(riskBefore.debtRToken + mintAmount);
    expect(balAfter - balBefore).to.equal(mintAmount);
    expect(riskAfter.currentLtvBps).to.be.lte(riskAfter.effectiveMaxLtvBps);
    expect(riskAfter.currentLtvBps).to.be.gt(0n);
  });

  it("3. reverts when mint exceeds effectiveMaxLtv", async () => {
    const risk = await readVaultRisk(vault, deployment.markets[MARKET_SYMBOL].oracle);
    const headroom = maxMintableRToken(
      risk.collateralValueUsdWad,
      risk.debtValueUsdWad,
      risk.effectiveMaxLtvBps,
      risk.oraclePrice8,
    );
    // 정수 나눗셈 여유: headroom 2배 또는 최소 0.001 rToken 초과
    const bump = headroom > 0n ? headroom : 1n;
    const overMint = headroom + (bump > ethers.parseUnits("0.001", 18) ? bump : ethers.parseUnits("0.001", 18));

    console.log(`  remaining headroom : ${ethers.formatUnits(headroom, 18)} rToken`);
    console.log(`  trying overMint    : ${ethers.formatUnits(overMint, 18)} rToken`);

    await expect(vault.mint(overMint))
      .to.be.revertedWithCustomError(vault, "ExceedsMaxLTV");
  });

  it("4. reverts on second over-mint after partial utilization", async () => {
    const risk = await readVaultRisk(vault, deployment.markets[MARKET_SYMBOL].oracle);
    const headroom = maxMintableRToken(
      risk.collateralValueUsdWad,
      risk.debtValueUsdWad,
      risk.effectiveMaxLtvBps,
      risk.oraclePrice8,
    );
    expect(headroom).to.be.gt(0n);

    const overMint = headroom + ethers.parseUnits("0.001", 18);
    await expect(vault.mint(overMint))
      .to.be.revertedWithCustomError(vault, "ExceedsMaxLTV");
  });
});
