/**
 * positionDirections.ts — 롱/숏/리밋오더 방향성 통합 테스트 (Arbitrum Sepolia)
 *
 * 테스트 구성:
 *   Section 1 — 숏 시장가 오픈
 *     1. openPosition(2, false) → Active
 *     2. isLong() == false 검증
 *     3. 가격 상승 → LTV 악화 (숏 불리)
 *     4. 가격 하락 → LTV 개선 (숏 유리)
 *     5. close → Empty
 *
 *   Section 2 — 롱 지정가(limit) 오픈
 *     6. openLimitPosition(2, trigger+15%, true) → SettlingOpen
 *     7. GMX keeper 즉시 체결 → exists==true
 *     8. executeOrder → Active, isLong==true
 *     9. cancelLimitOrder reverts when Active
 *    10. close → Empty
 *
 *   Section 3 — 숏 지정가(limit) 오픈
 *    11. openLimitPosition(2, trigger−15%, false) → SettlingOpen
 *    12. GMX keeper 체결 → Active, isLong==false
 *    13. cancelLimitOrder reverts when Active (not SettlingOpen)
 *    14. close → Empty
 *
 *   Section 4 — 캔슬 (롱 limit을 실제 미체결 trigger로 생성 후 cancelLimitOrder)
 *    15. openLimitPosition trigger 현재가보다 낮게 → SettlingOpen (미체결)
 *    16. cancelLimitOrder() → 취소 요청
 *    17. GMX keeper 취소 처리 → cancelOrder → Empty
 *
 * 실행:
 *   npx hardhat test test/ryex/positionDirections.ts --network arbitrumSepolia
 */

import { expect } from "chai";
import type { Contract } from "ethers";
import { ethers } from "hardhat";
import {
  DEPOSIT_USDC,
  EXEC_FEE,
  LEVERAGE,
  ORACLE_ABI,
  VaultState,
  ensureActiveVault,
  ensureEmptyVault,
  loadDeployment,
  openAndActivate,
  openLimitAndActivate,
  pollUntil,
  repayAllDebt,
  resetOraclePrice,
  waitAndCancelGmxOrder,
  type Deployment,
} from "./helpers";

const MARKET_SYMBOL = "rETH";

// ── 공통 상태 ─────────────────────────────────────────────────────────────────
let deployment: Deployment;
let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
let vaultAddr: string;
let vault: Contract;
let oracleAddr: string;
let rTokenAddr: string;

// ── 전체 before: 볼트 준비 ────────────────────────────────────────────────────
before(async function () {
  this.timeout(10 * 60_000);
  const signers = await ethers.getSigners();
  owner = signers[0];
  deployment = await loadDeployment();

  const mkt = deployment.markets[MARKET_SYMBOL];
  oracleAddr = mkt.oracle;
  rTokenAddr = mkt.rToken;

  // 볼트 주소 확보 (기존 볼트가 없으면 ensureActiveVault 가 생성 후 Active 상태로 만들고,
  // 우리가 필요한 Empty로 즉시 리셋한다)
  vaultAddr = await ensureActiveVault(owner, deployment, MARKET_SYMBOL);
  vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);

  await resetOraclePrice(oracleAddr, owner);
  console.log(`\nOwner  : ${await owner.getAddress()}`);
  console.log(`Vault  : ${vaultAddr}`);
  console.log(`Oracle : ${oracleAddr}`);
  console.log(`rToken : ${rTokenAddr}`);
});

// ══════════════════════════════════════════════════════════════════════════════
// Section 1 — 숏 시장가 오픈
// ══════════════════════════════════════════════════════════════════════════════
describe("Section 1 — Short market open", function () {
  this.timeout(10 * 60_000);

  before(async function () {
    await resetOraclePrice(oracleAddr, owner);
    // Active(long) → Empty
    await ensureEmptyVault(vaultAddr, owner, deployment.gmxAdapter, rTokenAddr, []);
    // Empty → Active (short)
    await openAndActivate(vaultAddr, owner, deployment.gmxAdapter, deployment.usdc, LEVERAGE, false);
    console.log(`  → Short market position opened`);
  });

  it("1. vault.state() == Active", async () => {
    expect(await vault.state()).to.equal(VaultState.Active);
  });

  it("2. vault.isLong() == false", async () => {
    expect(await vault.isLong()).to.equal(false);
  });

  it("3. vaultInfo().isLong == false", async () => {
    const info = await vault.vaultInfo();
    expect(info.isLong).to.equal(false);
    console.log(`  leverage       : ${info.leverage}×`);
    console.log(`  isLong         : ${info.isLong}`);
    console.log(`  currentLtvBps  : ${info.currentLtvBps} bps`);
    console.log(`  oraclePrice8   : ${ethers.formatUnits(info.oraclePrice8, 8)} USD`);
  });

  it("4. price UP → collateral value decreases (short disadvantage)", async () => {
    const oracle = new ethers.Contract(oracleAddr, ORACLE_ABI, owner);
    // collateralValueUsdWad: 부채 없이도 포지션 mark-price 기반 가치를 반영
    const valueBefore: bigint = await vault.collateralValueUsdWad();

    // 가격 20% 상승
    const priceBefore: bigint = await oracle.getPrice();
    const priceUp = (priceBefore * 120n) / 100n;
    await (await oracle.setPrice(priceUp)).wait();

    const valueAfter: bigint = await vault.collateralValueUsdWad();
    console.log(`  collateralValue before : ${ethers.formatUnits(valueBefore, 18)} USD`);
    console.log(`  collateralValue after  : ${ethers.formatUnits(valueAfter, 18)} USD  (price +20%)`);
    expect(valueAfter).to.be.lt(valueBefore, "Short position value should DECREASE when price rises");

    // 원복
    await (await oracle.setPrice(priceBefore)).wait();
  });

  it("5. price DOWN → collateral value increases (short advantage)", async () => {
    const oracle = new ethers.Contract(oracleAddr, ORACLE_ABI, owner);
    const valueBefore: bigint = await vault.collateralValueUsdWad();

    // 가격 20% 하락
    const priceBefore: bigint = await oracle.getPrice();
    const priceDown = (priceBefore * 80n) / 100n;
    await (await oracle.setPrice(priceDown)).wait();

    const valueAfter: bigint = await vault.collateralValueUsdWad();
    console.log(`  collateralValue before : ${ethers.formatUnits(valueBefore, 18)} USD`);
    console.log(`  collateralValue after  : ${ethers.formatUnits(valueAfter, 18)} USD  (price −20%)`);
    expect(valueAfter).to.be.gt(valueBefore, "Short position value should INCREASE when price falls");

    // 원복
    await (await oracle.setPrice(priceBefore)).wait();
  });

  it("6. closePosition → Empty (vault reuse)", async () => {
    await ensureEmptyVault(vaultAddr, owner, deployment.gmxAdapter, rTokenAddr, []);
    expect(await vault.state()).to.equal(VaultState.Empty);
    console.log(`  → Vault back to Empty — ready for reuse`);
  });
});

// ══════════════════════════════════════════════════════════════════════════════
// Section 2 — 롱 지정가(limit) 오픈
// ══════════════════════════════════════════════════════════════════════════════
describe.skip("Section 2 — Long limit buy", function () {
  this.timeout(10 * 60_000);

  let triggerPrice8: bigint;

  before(async function () {
    await resetOraclePrice(oracleAddr, owner);
    await ensureEmptyVault(vaultAddr, owner, deployment.gmxAdapter, rTokenAddr, []);
    triggerPrice8 = await openLimitAndActivate(
      vaultAddr, owner, deployment.gmxAdapter, deployment.usdc, oracleAddr, LEVERAGE, true,
    );
    console.log(`  → Long limit trigger : ${ethers.formatUnits(triggerPrice8, 8)} USD`);
  });

  it("7. vault.state() == Active after limit fill", async () => {
    expect(await vault.state()).to.equal(VaultState.Active);
  });

  it("8. vault.isLong() == true", async () => {
    expect(await vault.isLong()).to.equal(true);
  });

  it("9. GMX position exists", async () => {
    const pos = await vault.gmxPosition();
    console.log(`  exists          : ${pos.exists}`);
    console.log(`  sizeInUsd       : ${ethers.formatUnits(pos.sizeInUsd, 30)} USD`);
    console.log(`  collateralAmount: ${ethers.formatUnits(pos.collateralAmount, 6)} USDC`);
    expect(pos.exists).to.equal(true);
    expect(pos.sizeInUsd).to.be.gt(0n);
  });

  it("10. cancelLimitOrder reverts when already Active", async () => {
    await expect(vault.cancelLimitOrder()).to.be.revertedWithCustomError(vault, "BadState");
  });

  it("11. close long limit position → Empty", async () => {
    await ensureEmptyVault(vaultAddr, owner, deployment.gmxAdapter, rTokenAddr, []);
    expect(await vault.state()).to.equal(VaultState.Empty);
  });
});

// ══════════════════════════════════════════════════════════════════════════════
// Section 3 — 숏 지정가(limit) 오픈
// ══════════════════════════════════════════════════════════════════════════════
describe.skip("Section 3 — Short limit sell", function () {
  this.timeout(10 * 60_000);

  let triggerPrice8: bigint;

  before(async function () {
    await resetOraclePrice(oracleAddr, owner);
    await ensureEmptyVault(vaultAddr, owner, deployment.gmxAdapter, rTokenAddr, []);
    triggerPrice8 = await openLimitAndActivate(
      vaultAddr, owner, deployment.gmxAdapter, deployment.usdc, oracleAddr, LEVERAGE, false,
    );
    console.log(`  → Short limit trigger: ${ethers.formatUnits(triggerPrice8, 8)} USD`);
  });

  it("12. vault.state() == Active after short limit fill", async () => {
    expect(await vault.state()).to.equal(VaultState.Active);
  });

  it("13. vault.isLong() == false", async () => {
    expect(await vault.isLong()).to.equal(false);
  });

  it("14. GMX position exists (short)", async () => {
    const pos = await vault.gmxPosition();
    console.log(`  exists          : ${pos.exists}`);
    console.log(`  sizeInUsd       : ${ethers.formatUnits(pos.sizeInUsd, 30)} USD`);
    console.log(`  collateralAmount: ${ethers.formatUnits(pos.collateralAmount, 6)} USDC`);
    expect(pos.exists).to.equal(true);
    expect(pos.sizeInUsd).to.be.gt(0n);
  });

  it("15. vaultInfo confirms isLong==false + leverage", async () => {
    const info = await vault.vaultInfo();
    expect(info.isLong).to.equal(false);
    expect(Number(info.leverage)).to.equal(LEVERAGE);
  });

  it("16. close short limit position → Empty", async () => {
    await ensureEmptyVault(vaultAddr, owner, deployment.gmxAdapter, rTokenAddr, []);
    expect(await vault.state()).to.equal(VaultState.Empty);
  });
});

// ══════════════════════════════════════════════════════════════════════════════
// Section 4 — 미체결 limit order 취소 (cancelLimitOrder)
// ══════════════════════════════════════════════════════════════════════════════
describe("Section 4 — Cancel unexecuted limit order", function () {
  this.timeout(10 * 60_000);

  before(async function () {
    await resetOraclePrice(oracleAddr, owner);
    await ensureEmptyVault(vaultAddr, owner, deployment.gmxAdapter, rTokenAddr, []);

    // 롱 limit — trigger를 $0.01 (8dec=1,000,000)로 설정
    // GMX 실제 ETH 가격은 항상 $0.01 이상 → markPrice ≤ $0.01 조건 미충족 → 절대 체결 안 됨
    const triggerPrice8 = 1_000_000n; // $0.01 in 8dec (= 0.00 cents)
    console.log(`  limit trigger  : ${ethers.formatUnits(triggerPrice8, 8)} USD (extremely low — never fills)`);

    const usdc = new ethers.Contract(deployment.usdc, ["function approve(address,uint256) returns (bool)"], owner);
    await (await usdc.approve(vaultAddr, DEPOSIT_USDC)).wait();
    await (await vault.deposit(DEPOSIT_USDC)).wait();
    await (await vault.openLimitPosition(LEVERAGE, triggerPrice8, true, { value: EXEC_FEE })).wait();
  });

  it("17. state == SettlingOpen (limit pending)", async () => {
    expect(await vault.state()).to.equal(VaultState.SettlingOpen);
    const pending = await vault.pending();
    // OrderKind.LimitOpen == 4
    expect(pending.kind).to.equal(4n);
    console.log(`  orderKey : ${pending.orderKey}`);
  });

  it("18. openPosition reverts while SettlingOpen", async () => {
    await expect(vault.openPosition(LEVERAGE, true, { value: EXEC_FEE }))
      .to.be.revertedWithCustomError(vault, "BadState");
  });

  it("19. cancelLimitOrder → GMX cancels → Empty", async function () {
    // cancelLimitOrder() → GMX에 취소 요청 전송
    const tx = await vault.cancelLimitOrder();
    await tx.wait();
    console.log(`  cancelLimitOrder tx: ${tx.hash}`);

    // GMX keeper 취소 처리 → afterOrderCancellation 콜백 자동 or settleGmxOrder fallback → Empty
    console.log("  → Waiting for GMX keeper cancellation + callback/fallback settlement…");
    await waitAndCancelGmxOrder(vaultAddr, deployment.gmxAdapter, owner);

    expect(await vault.state()).to.equal(VaultState.Empty);
    console.log(`  → Vault returned to Empty after cancel`);
  });
});

// ══════════════════════════════════════════════════════════════════════════════
// Section 5 — 롱/숏 연속 사이클 (볼트 재사용 검증)
// ══════════════════════════════════════════════════════════════════════════════
describe("Section 5 — Vault reuse: long → close → short → close", function () {
  this.timeout(15 * 60_000);

  it("20. open long → Active", async function () {
    await resetOraclePrice(oracleAddr, owner);
    await ensureEmptyVault(vaultAddr, owner, deployment.gmxAdapter, rTokenAddr, []);
    await openAndActivate(vaultAddr, owner, deployment.gmxAdapter, deployment.usdc, LEVERAGE, true);
    expect(await vault.isLong()).to.equal(true);
    expect(await vault.state()).to.equal(VaultState.Active);
    console.log(`  ✓ Long open, vaultAddr: ${vaultAddr}`);
  });

  it("21. close long → Empty (same vault)", async function () {
    await ensureEmptyVault(vaultAddr, owner, deployment.gmxAdapter, rTokenAddr, []);
    expect(await vault.state()).to.equal(VaultState.Empty);
    console.log(`  ✓ Closed to Empty, vault address unchanged`);
  });

  it("22. open short on same vault → Active", async function () {
    await openAndActivate(vaultAddr, owner, deployment.gmxAdapter, deployment.usdc, LEVERAGE, false);
    expect(await vault.isLong()).to.equal(false);
    expect(await vault.state()).to.equal(VaultState.Active);
    console.log(`  ✓ Same vault ${vaultAddr} now has SHORT position`);
  });

  it("23. close short → Empty (vault fully reused)", async function () {
    await ensureEmptyVault(vaultAddr, owner, deployment.gmxAdapter, rTokenAddr, []);
    expect(await vault.state()).to.equal(VaultState.Empty);
    console.log(`  ✓ Full cycle: long→close→short→close on single vault address`);
  });
});
