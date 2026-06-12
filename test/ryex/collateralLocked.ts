/**
 * collateralLocked.ts — VaultFactory.totalCollateralLocked (push 방식) 통합 테스트
 *
 * 검증:
 *   1. deposit  → factory.totalCollateralLocked 증가 확인
 *   2. openPosition → USDC가 GMX로 이동해도 totalCollateralLocked 불변
 *   3-A. 체결 (Active) → closePosition → totalCollateralLocked 감소(0 복귀) 확인
 *   3-B. 취소 (Empty)  → withdraw     → totalCollateralLocked 감소(0 복귀) 확인
 *   4. 최종 baseline과 동일함을 확인
 *
 * 실행:
 *   npx hardhat test test/ryex/collateralLocked.ts --network arbitrumSepolia
 */
import { expect } from "chai";
import { ethers } from "hardhat";
import {
  VaultState,
  DEPOSIT_USDC,
  LEVERAGE,
  EXEC_FEE,
  loadDeployment,
  waitForSettlement,
  type Deployment,
  VAULT_FACTORY_ABI,
  POSITION_VAULT_ABI,
  ERC20_ABI,
} from "./helpers";

const MARKET_SYMBOL = "rETH";

describe("VaultFactory.totalCollateralLocked — push 방식 (Arbitrum Sepolia)", function () {
  this.timeout(5 * 60_000);

  let deployment: Deployment;
  let signer: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let factory:   Awaited<ReturnType<typeof ethers.getContractAt>>;
  let vault:     Awaited<ReturnType<typeof ethers.getContractAt>>;
  let usdc:      Awaited<ReturnType<typeof ethers.getContractAt>>;
  let vaultAddr: string;
  let baseline:  bigint; // 테스트 시작 전 totalCollateralLocked

  before(async function () {
    [signer] = await ethers.getSigners();
    deployment = await loadDeployment();
    const mkt = deployment.markets[MARKET_SYMBOL];

    factory = new ethers.Contract(deployment.vaultFactory, VAULT_FACTORY_ABI, signer);
    usdc    = new ethers.Contract(deployment.usdc, ERC20_ABI, signer);

    // 볼트 생성 or 재사용
    const signerAddr = await signer.getAddress();
    vaultAddr = await factory.vaultOf(signerAddr, mkt.marketId);
    if (vaultAddr === ethers.ZeroAddress) {
      const tx = await factory.createVault(mkt.marketId);
      const rc = await tx.wait();
      const topic = ethers.id("VaultCreated(address,bytes32,address)");
      for (const log of rc!.logs) {
        if (log.topics[0] === topic) {
          vaultAddr = ethers.AbiCoder.defaultAbiCoder().decode(["address"], log.data)[0] as string;
          break;
        }
      }
    }

    vault = new ethers.Contract(vaultAddr, POSITION_VAULT_ABI, signer);
    console.log(`\nVault   : ${vaultAddr}`);
    console.log(`Factory : ${deployment.vaultFactory}`);

    // 사전 정리: 잔여 collateral이 있으면 회수 (이전 테스트 잔여분)
    const existingCol: bigint = await vault.collateral();
    const vaultState: bigint  = await vault.state();
    if (existingCol > 0n && vaultState === VaultState.Empty) {
      console.log(`  → 잔여 collateral ${ethers.formatUnits(existingCol, 6)} USDC 회수…`);
      await (await vault.withdraw(existingCol)).wait();
    }
  });

  // ── 1. baseline 기록 ────────────────────────────────────────────────────────
  it("1. baseline: totalCollateralLocked 초기값 기록", async function () {
    baseline = await factory.totalCollateralLocked();
    console.log(`  baseline = ${ethers.formatUnits(baseline, 6)} USDC`);
    expect(baseline).to.be.gte(0n);
  });

  // ── 2. deposit → +DEPOSIT_USDC ─────────────────────────────────────────────
  it("2. deposit 후 totalCollateralLocked 증가", async function () {
    const before: bigint = await factory.totalCollateralLocked();

    await (await usdc.approve(vaultAddr, DEPOSIT_USDC)).wait();
    await (await vault.deposit(DEPOSIT_USDC)).wait();

    const after: bigint = await factory.totalCollateralLocked();
    const col: bigint   = await vault.collateral();

    console.log(`  totalCollateralLocked: ${ethers.formatUnits(before, 6)} → ${ethers.formatUnits(after, 6)} USDC`);
    console.log(`  vault.collateral     : ${ethers.formatUnits(col, 6)} USDC`);

    expect(after).to.equal(before + DEPOSIT_USDC, "deposit 후 totalCollateralLocked 증가 불일치");
    expect(col).to.equal(DEPOSIT_USDC);
  });

  // ── 3. openPosition → USDC가 GMX로 이동해도 totalCollateralLocked 불변 ──────
  it("3. openPosition 직후 totalCollateralLocked 불변", async function () {
    const before: bigint = await factory.totalCollateralLocked();

    // GMX testnet long 풀 고갈 빈번 → short으로 테스트
    await (await vault.openPosition(LEVERAGE, false /* short */, { value: EXEC_FEE })).wait();

    const after: bigint     = await factory.totalCollateralLocked();
    const stateAfter: bigint = await vault.state();

    console.log(`  totalCollateralLocked: ${ethers.formatUnits(before, 6)} → ${ethers.formatUnits(after, 6)} USDC`);
    console.log(`  vault.state          : ${stateAfter} (1=SettlingOpen, 2=Active, 0=Empty)`);

    // openPosition은 collateral 값을 변경하지 않으므로 불변
    expect(after).to.equal(before, "openPosition 후 totalCollateralLocked 변경됨 (버그)");
  });

  // ── 4. GMX 콜백 대기 ──────────────────────────────────────────────────────
  it("4. GMX 콜백 대기 (체결 or 취소)", async function () {
    const state: bigint = await vault.state();
    if (state !== VaultState.SettlingOpen) {
      console.log(`  → 이미 정산 완료 (state=${state})`);
      return;
    }

    console.log("  → GMX 콜백 대기 중…");
    await waitForSettlement(vaultAddr, deployment.gmxAdapter, signer, 120_000);

    const stateAfter: bigint = await vault.state();
    const locked: bigint     = await factory.totalCollateralLocked();
    console.log(`  vault.state          : ${stateAfter} (2=Active체결, 0=Empty취소)`);
    console.log(`  totalCollateralLocked: ${ethers.formatUnits(locked, 6)} USDC`);

    // 체결(Active): collateral 그대로, totalCollateralLocked 유지
    // 취소(Empty): afterOrderCancellation이 잔액 재조정 → 극미 차이 가능하나 대부분 동일
    expect(stateAfter === VaultState.Active || stateAfter === VaultState.Empty).to.be.true;
  });

  // ── 5. 포지션 정리 → totalCollateralLocked 감소(baseline 복귀) ──────────────
  it("5. 포지션 종료 후 totalCollateralLocked 감소 확인", async function () {
    const stateNow: bigint = await vault.state();

    if (stateNow === VaultState.Active) {
      // 체결된 경우: closePosition
      console.log("  → closePosition 호출…");
      await (await vault.closePosition({ value: EXEC_FEE })).wait();
      await waitForSettlement(vaultAddr, deployment.gmxAdapter, signer, 120_000);
      console.log("  ✓ 포지션 close 완료");
    } else if (stateNow === VaultState.Empty) {
      // 취소된 경우: 남은 collateral 인출
      const col: bigint = await vault.collateral();
      if (col > 0n) {
        console.log(`  → 취소된 주문, collateral ${ethers.formatUnits(col, 6)} USDC 인출…`);
        await (await vault.withdraw(col)).wait();
        console.log("  ✓ withdraw 완료");
      } else {
        console.log("  → 취소 후 collateral 이미 0, skip");
      }
    } else {
      throw new Error(`예상치 못한 vault state: ${stateNow}`);
    }

    const finalLocked: bigint = await factory.totalCollateralLocked();
    const finalCol: bigint    = await vault.collateral();

    console.log(`  totalCollateralLocked: ${ethers.formatUnits(finalLocked, 6)} USDC (baseline: ${ethers.formatUnits(baseline, 6)} USDC)`);
    console.log(`  vault.collateral     : ${ethers.formatUnits(finalCol, 6)} USDC`);

    expect(finalCol).to.equal(0n, "포지션 종료 후 vault.collateral이 0이어야 함");
    expect(finalLocked).to.equal(baseline, "포지션 종료 후 totalCollateralLocked가 baseline으로 복귀해야 함");
  });

  // ── 6. 연속 deposit/withdraw 사이클 ─────────────────────────────────────────
  it("6. deposit → withdraw 사이클에서 정확히 증감", async function () {
    const before: bigint = await factory.totalCollateralLocked();

    // deposit
    await (await usdc.approve(vaultAddr, DEPOSIT_USDC)).wait();
    await (await vault.deposit(DEPOSIT_USDC)).wait();
    const afterDeposit: bigint = await factory.totalCollateralLocked();
    expect(afterDeposit).to.equal(before + DEPOSIT_USDC, "deposit 후 +DEPOSIT_USDC 기대");

    // withdraw 절반
    const half = DEPOSIT_USDC / 2n;
    await (await vault.withdraw(half)).wait();
    const afterHalfWithdraw: bigint = await factory.totalCollateralLocked();
    expect(afterHalfWithdraw).to.equal(before + DEPOSIT_USDC - half, "절반 인출 후 불일치");

    // withdraw 나머지
    await (await vault.withdraw(half)).wait();
    const afterFullWithdraw: bigint = await factory.totalCollateralLocked();
    expect(afterFullWithdraw).to.equal(before, "전액 인출 후 before 복귀 기대");

    console.log(`  ✓ deposit/withdraw 사이클: ${ethers.formatUnits(before, 6)} → +${ethers.formatUnits(DEPOSIT_USDC, 6)} → -절반 → -나머지 → ${ethers.formatUnits(afterFullWithdraw, 6)} USDC`);
  });
});
