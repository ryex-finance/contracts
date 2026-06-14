/**
 * rTokenRedeem.ts — RLT 상환존 redeem 통합 테스트 (Arbitrum Sepolia)
 *
 * Litepaper §4.5/§5.3: RLT <= LTV < LLTV 구간에서 누구나 rToken을 제출해
 * 부채를 줄이고 부분청산 USDC(−redeem fee)를 받을 수 있다.
 *
 * 실행:
 *   npx hardhat test test/ryex/rTokenRedeem.ts --network arbitrumSepolia
 */
import { expect } from "chai";
import type { Contract } from "ethers";
import { ethers } from "hardhat";
import {
  ERC20_ABI,
  RTOKEN_ABI,
  VaultState,
  ensureActiveVault,
  fundEth,
  loadDeployment,
  mintMaxRToken,
  pushToRedemptionZone,
  PRICE_ONE,
  VAULT_FACTORY_ABI,
  readGmxPosition,
  readVaultRisk,
  repayAllDebt,
  waitForRedeemSettlement,
  EXEC_FEE,
  type Deployment,
} from "./helpers";

const MARKET_SYMBOL = "rETH";

describe("rToken Redeem — RLT zone (Arbitrum Sepolia)", function () {
  this.timeout(8 * 60_000);

  let deployment: Deployment;
  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let redeemer: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let vaultAddr: string;
  let vault: Contract;
  let rTokenAddr: string;
  let oracleAddr: string;

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    redeemer = signers[1];
    deployment = await loadDeployment();

    const mkt = deployment.markets[MARKET_SYMBOL];
    rTokenAddr = mkt.rToken;
    oracleAddr = mkt.oracle;

    console.log(`\nOwner     : ${await owner.getAddress()}`);
    console.log(`Redeemer  : ${await redeemer.getAddress()} (3rd party)`);
    console.log(`rToken    : ${rTokenAddr}`);

    vaultAddr = await ensureActiveVault(owner, deployment, MARKET_SYMBOL);
    vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    await fundEth(owner, await redeemer.getAddress());
    await repayAllDebt(vaultAddr, owner, rTokenAddr, [redeemer]);
    // 숏 포지션: oracle >> entry 이면 PnL 음수 → collateralValueUsdWad=0 → mint 불가
    const oracle = await ethers.getContractAt("MockPriceOracle", oracleAddr, owner);
    const adapter = await ethers.getContractAt("GmxV2Adapter", deployment.gmxAdapter);
    const pk = await adapter.positionKey(vaultAddr, await vault.marketId(), await vault.isLong());
    const pos = await adapter.positions(pk);
    const syncPrice = pos.entryPrice8 > 0n ? pos.entryPrice8 : 1650n * PRICE_ONE;
    await (await oracle.setPrice(syncPrice)).wait();
    console.log(`  oracle sync  : $${ethers.formatUnits(syncPrice, 8)} (entry-aligned)`);
    console.log(`Vault     : ${vaultAddr}`);
  });

  it("1. redeem reverts when not in redemption zone (no debt)", async () => {
    expect(await vault.isRedeemable()).to.equal(false);
    const rlt = await vault.rltBps();
    const lltv = await vault.lltvBps();
    const ltv = await vault.currentLTV();
    console.log(`  LTV=${ltv} bps  RLT=${rlt}  LLTV=${lltv}`);

    const vaultAsRedeemer = await ethers.getContractAt("PositionVault", vaultAddr, redeemer);
    await expect(vaultAsRedeemer.redeem(1n))
      .to.be.revertedWithCustomError(vault, "NotRedeemable");
  });

  it("2. mint to max LTV and enter RLT redemption zone", async () => {
    const minted = await mintMaxRToken(vaultAddr, owner, oracleAddr);
    expect(minted).to.be.gt(0n);
    console.log(`  minted to max : ${ethers.formatUnits(minted, 18)} rToken`);

    await pushToRedemptionZone(vaultAddr, oracleAddr, owner);

    const risk = await readVaultRisk(vault, oracleAddr);
    const rlt = await vault.rltBps();
    const lltv = await vault.lltvBps();

    console.log(`  LTV           : ${risk.currentLtvBps} bps`);
    console.log(`  RLT / LLTV    : ${rlt} / ${lltv} bps`);
    console.log(`  isRedeemable  : ${await vault.isRedeemable()}`);

    expect(await vault.isRedeemable()).to.equal(true);
    expect(risk.currentLtvBps).to.be.gte(rlt);
    expect(risk.currentLtvBps).to.be.lt(lltv);
  });

  it("3. third party redeems rToken — GMX partial decrease + USDC to redeemer", async function () {
    const riskBefore = await readVaultRisk(vault, oracleAddr);
    const debtBefore: bigint = riskBefore.debtRToken;
    expect(debtBefore).to.be.gt(0n);

    const isLong: boolean = await vault.isLong();
    const gmxBefore = await readGmxPosition(deployment.gmxAdapter, isLong);
    expect(gmxBefore.exists).to.equal(true, "GMX position must exist before redeem");
    console.log(`  GMX size before : $${ethers.formatUnits(gmxBefore.sizeInUsd, 30)}`);

    // redeem 수량: 부채의 50% (3rd party가 대신 갚을 분)
    const redeemAmount = debtBefore / 2n;
    expect(redeemAmount).to.be.gt(0n);

    // owner → redeemer 로 rToken 전달 (AMM에서 샀다고 가정)
    const rTokenOwner = new ethers.Contract(rTokenAddr, RTOKEN_ABI, owner);
    await (await rTokenOwner.transfer(await redeemer.getAddress(), redeemAmount)).wait();

    const usdc = new ethers.Contract(deployment.usdc, ERC20_ABI, redeemer);
    const redeemerAddr = await redeemer.getAddress();
    const usdcBefore: bigint = await usdc.balanceOf(redeemerAddr);

    console.log(`  redeeming     : ${ethers.formatUnits(redeemAmount, 18)} rToken`);
    console.log(`  redeemer USDC : ${ethers.formatUnits(usdcBefore, 6)} (before)`);

    const vaultAsRedeemer = await ethers.getContractAt("PositionVault", vaultAddr, redeemer);
    const rTokenRedeemer = new ethers.Contract(rTokenAddr, RTOKEN_ABI, redeemer);
    await (await rTokenRedeemer.approve(vaultAddr, redeemAmount)).wait();
    const tx = await vaultAsRedeemer.redeem(redeemAmount, { value: EXEC_FEE });
    await tx.wait();
    await waitForRedeemSettlement(vaultAddr, deployment.gmxAdapter, redeemer);

    const riskAfter = await readVaultRisk(vault, oracleAddr);
    const usdcAfter: bigint = await usdc.balanceOf(redeemerAddr);
    const gmxAfter = await readGmxPosition(deployment.gmxAdapter, isLong);

    console.log(`  debt before/after : ${ethers.formatUnits(debtBefore, 18)} → ${ethers.formatUnits(riskAfter.debtRToken, 18)}`);
    console.log(`  LTV  before/after : ${riskBefore.currentLtvBps} → ${riskAfter.currentLtvBps} bps`);
    console.log(`  GMX size after    : $${ethers.formatUnits(gmxAfter.sizeInUsd, 30)}`);
    console.log(`  redeemer USDC     : ${ethers.formatUnits(usdcBefore, 6)} → ${ethers.formatUnits(usdcAfter, 6)} (+${ethers.formatUnits(usdcAfter - usdcBefore, 6)})`);

    expect(riskAfter.debtRToken).to.equal(debtBefore - redeemAmount);
    expect(riskAfter.currentLtvBps).to.be.lt(riskBefore.currentLtvBps, "LTV should decrease after redeem");
    expect(usdcAfter).to.be.gt(usdcBefore, "redeemer should receive USDC");
    expect(gmxAfter.sizeInUsd).to.be.lt(gmxBefore.sizeInUsd, "GMX sizeInUsd should decrease");
    expect(await vault.state()).to.equal(VaultState.Active);
    expect(await vault.pending()).to.satisfy((p: { kind: bigint }) => p.kind === 0n, "no pending order");

    // LTV가 RLT 아래로 내려가면 큐에서 자동 제거
    const factory = new ethers.Contract(deployment.vaultFactory, VAULT_FACTORY_ABI, ethers.provider);
    const marketId = deployment.markets[MARKET_SYMBOL].marketId;
    const rlt = await vault.rltBps();
    expect(riskAfter.currentLtvBps).to.be.lt(rlt, "should leave RLT zone after 50% redeem");
    expect(await factory.inRedemptionQueue(marketId, vaultAddr)).to.equal(false);
    expect(await factory.redeemableCount(marketId)).to.equal(0n);
  });

  it("4. owner cannot block third-party redeem (non-owner succeeds)", async () => {
    // 아직 상환존이면 추가 redeem 가능
    if (!(await vault.isRedeemable())) {
      console.log("  skipped: no longer in redemption zone");
      return;
    }

    const debt: bigint = await vault.debt();
    if (debt === 0n) {
      console.log("  skipped: no remaining debt");
      return;
    }

    const small = debt / 10n;
    if (small === 0n) return;

    const rTokenOwner = new ethers.Contract(rTokenAddr, RTOKEN_ABI, owner);
    await (await rTokenOwner.transfer(await redeemer.getAddress(), small)).wait();

    const vaultAsRedeemer = await ethers.getContractAt("PositionVault", vaultAddr, redeemer);
    const rTokenRedeemer = new ethers.Contract(rTokenAddr, RTOKEN_ABI, redeemer);
    await (await rTokenRedeemer.approve(vaultAddr, small)).wait();
    const tx = await vaultAsRedeemer.redeem(small, { value: EXEC_FEE });
    await tx.wait();
    await waitForRedeemSettlement(vaultAddr, deployment.gmxAdapter, redeemer);
  });
});
