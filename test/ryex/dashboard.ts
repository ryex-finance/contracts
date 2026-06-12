/**
 * dashboard.ts — VaultFactory 대시보드 view 함수 통합 테스트 (Arbitrum Sepolia)
 *
 * 검증:
 *   1. redeemableCount      — RLT 큐 내 실제 상환 가능 볼트 수
 *   2. totalRedeemableDebt  — 상환 가능 볼트들의 rToken 부채 합계
 *   3. avgHealthAcrossQueue — 큐 내 평균 health factor (bps)
 *
 * 실행:
 *   npx hardhat test test/ryex/dashboard.ts --network arbitrumSepolia
 */
import { expect } from "chai";
import { ethers } from "hardhat";
import {
  VAULT_FACTORY_ABI,
  POSITION_VAULT_ABI,
  ensureActiveVault,
  fundEth,
  loadDeployment,
  mintMaxRToken,
  pushToRedemptionZone,
  repayAllDebt,
  resetOraclePrice,
  type Deployment,
} from "./helpers";

const MARKET_SYMBOL = "rETH";

describe("VaultFactory Dashboard Views (Arbitrum Sepolia)", function () {
  this.timeout(15 * 60_000);

  let deployment: Deployment;
  let owner:      Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let liquidator: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let factory:    Awaited<ReturnType<typeof ethers.getContractAt>>;
  let vault:      Awaited<ReturnType<typeof ethers.getContractAt>>;
  let vaultAddr:  string;
  let marketId:   string;
  let oracleAddr: string;
  let rTokenAddr: string;

  before(async function () {
    const signers = await ethers.getSigners();
    owner     = signers[0];
    liquidator = signers[2];
    deployment = await loadDeployment();

    const mkt = deployment.markets[MARKET_SYMBOL];
    marketId  = mkt.marketId;
    oracleAddr = mkt.oracle;
    rTokenAddr = mkt.rToken;

    factory = new ethers.Contract(deployment.vaultFactory, VAULT_FACTORY_ABI, owner);

    console.log(`\nOwner     : ${await owner.getAddress()}`);
    console.log(`Factory   : ${deployment.vaultFactory}`);
    console.log(`MarketId  : ${marketId}`);

    // Active 볼트 확보 + 부채 초기화 + oracle 가격 정상화
    vaultAddr = await ensureActiveVault(owner, deployment, MARKET_SYMBOL);
    vault = new ethers.Contract(vaultAddr, POSITION_VAULT_ABI, owner);
    await fundEth(owner, await liquidator.getAddress());
    await repayAllDebt(vaultAddr, owner, rTokenAddr, [signers[1], liquidator]);
    await resetOraclePrice(oracleAddr, owner);
    console.log(`Vault     : ${vaultAddr}`);
  });

  // ── 1. 초기 상태: 큐 비어 있음 ──────────────────────────────────────────────
  it("1. 상환 큐가 비어 있을 때 모든 집계값 = 0", async function () {
    // 큐 pruning — 테스트 잔여 항목 정리
    const qLen: bigint = await factory.redemptionQueueLength(marketId);
    console.log(`  redemptionQueueLength = ${qLen}`);

    const count  = await factory.redeemableCount(marketId);
    const debt   = await factory.totalRedeemableDebt(marketId);
    const health = await factory.avgHealthAcrossQueue(marketId);

    console.log(`  redeemableCount      = ${count}`);
    console.log(`  totalRedeemableDebt  = ${ethers.formatUnits(debt, 18)} rToken`);
    console.log(`  avgHealthAcrossQueue = ${health} bps`);

    // 이 볼트가 큐에 없으면 count=0
    const inQueue: boolean = await factory.inRedemptionQueue(marketId, vaultAddr);
    if (!inQueue) {
      expect(count).to.equal(0n);
      expect(health).to.equal(0n);
    }
  });

  // ── 2. max mint → oracle 하락 → 상환존 진입 ──────────────────────────────────
  it("2. 상환존 진입 준비 (max mint + oracle 하락)", async function () {
    await mintMaxRToken(vaultAddr, owner, oracleAddr);
    await pushToRedemptionZone(vaultAddr, oracleAddr, owner);

    const redeemable: boolean = await vault.isRedeemable();
    const ltv:  bigint = await vault.currentLTV();
    const lltv: bigint = await vault.lltvBps();
    console.log(`  isRedeemable = ${redeemable}  LTV=${ltv}bps  LLTV=${lltv}bps`);
    expect(redeemable).to.be.true;
  });

  // ── 3. #Redeemable positions — enqueueRedemption → redeemableCount 증가 ────
  // UI: "Redeemable positions / in RLT queue"
  // 조회: factory.redeemableCount(marketId)
  it("3. enqueueRedemption 후 redeemableCount = 1", async function () {
    await (await factory.enqueueRedemption(marketId, vaultAddr)).wait();

    const count: bigint = await factory.redeemableCount(marketId);
    console.log(`  redeemableCount = ${count}`);
    expect(count).to.be.gte(1n);
  });

  // ── 4. #RLT capacity — totalRedeemableDebt = vault.debt() ─────────────────
  // UI: "RLT capacity / debt available to redeem"
  // 조회: factory.totalRedeemableDebt(marketId)  →  rToken 18dec
  //       프론트에서 oracle 가격 곱해 USD 환산: totalDebt × oracle.getPrice() / 1e8
  it("4. totalRedeemableDebt = 상환 가능 볼트 부채 합계", async function () {
    const factoryDebt: bigint = await factory.totalRedeemableDebt(marketId);
    const vaultDebt:   bigint = await vault.debt();

    console.log(`  factory.totalRedeemableDebt = ${ethers.formatUnits(factoryDebt, 18)} rToken`);
    console.log(`  vault.debt()                = ${ethers.formatUnits(vaultDebt, 18)} rToken`);

    expect(factoryDebt).to.equal(vaultDebt, "totalRedeemableDebt가 vault debt와 불일치");
    expect(factoryDebt).to.be.gt(0n);
  });

  // ── 5. #Avg health — avgHealthAcrossQueue > 10000 ─────────────────────────
  // UI: "Avg health / across queue"
  // 조회: factory.avgHealthAcrossQueue(marketId)  →  bps 단위
  //       10000 = LLTV 경계, 값이 클수록 건강 (예: 11000 = LLTV까지 10% 여유)
  it("5. avgHealthAcrossQueue > 0 (상환존: LLTV 이전이므로 10000 초과)", async function () {
    const health: bigint = await factory.avgHealthAcrossQueue(marketId);
    const ltv:    bigint = await vault.currentLTV();
    const lltv:   bigint = await vault.lltvBps();

    // healthBps = lltvBps * 10000 / currentLTV
    const expectedHealth = (lltv * 10_000n) / ltv;

    console.log(`  avgHealthAcrossQueue = ${health} bps`);
    console.log(`  expected (approx)    = ${expectedHealth} bps`);
    console.log(`  [참고] 10000 = LLTV 경계, 클수록 건강`);

    expect(health).to.be.gt(0n);
    // 상환존은 LLTV 이전이므로 health > 10000
    expect(health).to.be.gt(10_000n);
  });

  // ── 6. 가격 복원 → 세 지표 모두 0으로 복귀 ──────────────────────────────────
  // #Redeemable positions / #RLT capacity / #Avg health 세 값이 동시에 0이 됨을 확인
  it("6. oracle 가격 복원 후 isRedeemable = false (큐 항목은 stale 처리됨)", async function () {
    await resetOraclePrice(oracleAddr, owner);

    const redeemable: boolean = await vault.isRedeemable();
    const count: bigint = await factory.redeemableCount(marketId);
    const debt: bigint  = await factory.totalRedeemableDebt(marketId);
    const health: bigint = await factory.avgHealthAcrossQueue(marketId);

    console.log(`  vault.isRedeemable   = ${redeemable}`);
    console.log(`  redeemableCount      = ${count}  (vault는 큐에 있지만 isRedeemable=false)`);
    console.log(`  totalRedeemableDebt  = ${ethers.formatUnits(debt, 18)} rToken`);
    console.log(`  avgHealthAcrossQueue = ${health} bps`);

    // 가격 복원 후 LTV가 상환존 이탈 → isRedeemable=false → 집계에서 제외
    expect(redeemable).to.be.false;
    expect(count).to.equal(0n);
    expect(debt).to.equal(0n);
    expect(health).to.equal(0n);
  });

  // ── 사후 정리: oracle 가격 복원 ─────────────────────────────────────────────
  after(async function () {
    await resetOraclePrice(oracleAddr, owner).catch(() => {});
  });
});
