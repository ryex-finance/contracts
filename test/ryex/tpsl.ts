/**
 * tpsl.ts — 숏 포지션 TP/SL 설정 테스트 (Arbitrum Sepolia)
 *
 *   npx hardhat test test/ryex/tpsl.ts --network arbitrumSepolia
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { expect } from "chai";
import type { Contract } from "ethers";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";

const MARKET = "rETH";
const IS_LONG = false;
const LEVERAGE = 2;
const DEPOSIT_USDC = 5n * 10n ** 6n;
const SETTLE_TIMEOUT_MS = 180_000;
const BPS = 10_000n;
const PRICE_ONE = 10n ** 8n;
const SL_LTV_BUFFER_BPS = 300n;
// GMX Keys.sol: keccak256(abi.encode(string)) — keccak256(toUtf8Bytes(...))는 다른 값 (2026-09-02 버그 수정)
const ACCOUNT_ORDER_LIST = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"]));

describe("short tpsl (Arbitrum Sepolia)", function () {
  this.timeout(25 * 60_000);

  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let ownerAddr: string;
  let marketId: string;
  let rTokenAddr: string;
  let execFee: bigint;

  let factory: Contract;
  let router: Contract;
  let lens: Contract;
  let usdc: Contract;
  let rToken: Contract;
  let oracle: Contract;
  let dataStore: Contract;
  let vaultAddr: string;
  let vault: Contract;
  let orderListKey: string;

  before(async function () {
    /** 테스트 계정 **/
    [owner] = await ethers.getSigners();
    ownerAddr = await owner.getAddress();

    /** 배포 주소 로드 **/
    const candidates = [
      ...(process.env.DEPLOY_PROFILE
        ? [path.join(process.cwd(), "deployments", `${process.env.DEPLOY_PROFILE}.json`)]
        : []),
      path.join(process.cwd(), "deployments", `${network.name}-gmx.json`),
      path.join(process.cwd(), "deployments", `${network.name}-gmx.json`),
    ];
    let deployment: {
      vaultFactory: string;
      ryexRouter: string;
      vaultLens: string;
      usdc: string;
      markets: Record<string, { marketId: string; rToken: string }>;
    } | undefined;
    for (const f of candidates) {
      try {
        deployment = JSON.parse(await readFile(f, "utf8"));
        if (deployment?.ryexRouter && deployment.vaultLens) break;
      } catch {
        /* next */
      }
    }
    if (!deployment?.ryexRouter || !deployment.vaultLens) {
      throw new Error("deployment JSON not found (ryexRouter / vaultLens)");
    }

    marketId = deployment.markets[MARKET].marketId;
    rTokenAddr = deployment.markets[MARKET].rToken;

    factory = await ethers.getContractAt("VaultFactory", deployment.vaultFactory, owner);
    router = await ethers.getContractAt("RyexRouter", deployment.ryexRouter, owner);
    lens = await ethers.getContractAt("VaultLens", deployment.vaultLens, owner);
    usdc = new ethers.Contract(deployment.usdc, ERC20Abi, owner);
    rToken = new ethers.Contract(rTokenAddr, ERC20Abi, owner);

    /** USDC allowance 확인 → max 아니면 approve **/
    const allowance: bigint = await usdc.allowance(ownerAddr, deployment.ryexRouter);
    if (allowance !== ethers.MaxUint256) {
      await (await usdc.approve(deployment.ryexRouter, ethers.MaxUint256)).wait();
    }

    /** GMX exec fee · dataStore · oracle 조회 **/
    const infra = await factory.gmxInfra();
    execFee = infra.execFee;
    dataStore = await ethers.getContractAt(
      ["function containsBytes32(bytes32,bytes32) view returns (bool)"],
      infra.dataStore,
    );
    const [, oracleAddr] = await factory.markets(marketId);
    oracle = await ethers.getContractAt(["function getPrice() view returns (uint256)"], oracleAddr, owner);

    console.log(`\nOwner  : ${ownerAddr}`);
    console.log(`Router : ${deployment.ryexRouter}`);

    /** 기존 숏 볼트 정리 **/
    let reusingActive = false;
    vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
    if (vaultAddr !== ethers.ZeroAddress) {
      vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
      orderListKey = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
      );

      /** TP/SL 취소 **/
      if ((await vault.tpOrderKey()) !== ethers.ZeroHash) {
        await (await vault.cancelTakeProfit()).wait();
      }
      if ((await vault.slOrderKey()) !== ethers.ZeroHash) {
        await (await vault.cancelStopLoss()).wait();
      }

      /** SettlingOpen — 미체결 limit open 취소 **/
      if ((await vault.state()) === 1n) {
        await (await vault.cancelLimitOrder()).wait();
      }

      /** Active + GMX 포지션 있으면 청산·재오픈 생략 (exec fee 절약) **/
      if ((await vault.state()) === 2n) {
        const gmxSize = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
        if (gmxSize > 0n) {
          reusingActive = true;
        } else {
          let ethBal = await ethers.provider.getBalance(vaultAddr);
          if (ethBal < execFee) {
            await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
          }
          const sizeBefore = gmxSize;
          await (await vault.closePosition(0n, { value: execFee })).wait();

          const deadline = Date.now() + SETTLE_TIMEOUT_MS;
          while (Date.now() < deadline) {
            const state: bigint = await vault.state();
            const sizeNow = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
            if (state === 0n && sizeNow < sizeBefore) break;
            if (state === 3n) {
              const pending = await vault.pending();
              if (pending.orderKey !== ethers.ZeroHash) {
                const order = await vault.gmxOrders(pending.orderKey);
              }
            }
            await new Promise((r) => setTimeout(r, 5_000));
          }
        }
      }

      /** Empty — 잔여 USDC 회수 **/
      if (!reusingActive && (await vault.state()) === 0n) {
        const idle = await usdc.balanceOf(vaultAddr);
        if (idle > 0n) {
          await (await vault.withdraw(idle)).wait();
        }
      }
    }

    if (reusingActive) {
      /** 가스비 전송 **/
      let ethBal = await ethers.provider.getBalance(vaultAddr);
      if (ethBal < execFee * 2n) {
        await (await owner.sendTransaction({ to: vaultAddr, value: execFee * 2n - ethBal })).wait();
      }
      console.log(`  before — reusing Active short (${ethers.formatUnits((await lens.gmxPosition(vaultAddr)).sizeInUsd, 30)} USD)`);
    } else {
    await (await router.deposit(marketId, IS_LONG, DEPOSIT_USDC)).wait();
    vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
    vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    orderListKey = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
    );

    /** 가스비 전송 **/
    let ethBal = await ethers.provider.getBalance(vaultAddr);
    if (ethBal < execFee) {
      await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
    }

    /** 시장가 숏 오픈 **/
    const expectedDelta = DEPOSIT_USDC * 10n ** 24n * BigInt(LEVERAGE);
    const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
    const minSize = sizeBefore + (expectedDelta * 95n) / 100n;

    await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, DEPOSIT_USDC, { value: execFee })).wait();

    /** GMX 오픈 정산 대기 **/
    const openDeadline = Date.now() + SETTLE_TIMEOUT_MS;
    while (Date.now() < openDeadline) {
      const state: bigint = await vault.state();
      const sizeNow = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      if (state === 2n && sizeNow >= minSize) break;
      if (state === 0n) throw new Error("before: GMX market open cancelled");
      if (state === 1n) {
        const pending = await vault.pending();
        if (pending.orderKey !== ethers.ZeroHash) {
          const order = await vault.gmxOrders(pending.orderKey);
        }
      }
      await new Promise((r) => setTimeout(r, 5_000));
    }
    if ((await vault.state()) !== 2n) {
      throw new Error("before: market open timed out");
    }

    const sizeDelta = (await lens.gmxPosition(vaultAddr)).sizeInUsd - sizeBefore;
    console.log(
      `  before — short Active, +${ethers.formatUnits(sizeDelta, 30)} USD (expected ~${ethers.formatUnits(expectedDelta, 30)})`,
    );
    }
  });

  after(async function () {
    if (!vault) return;

    /** 잔여 부채 상환 — close는 debt=0 필수 **/
    const debt: bigint = await vault.debt();
    if (debt > 0n) {
      await (await vault.repay(debt)).wait();
    }

    /** TP/SL 취소 **/
    if ((await vault.tpOrderKey()) !== ethers.ZeroHash) {
      await (await vault.cancelTakeProfit()).wait();
    }
    if ((await vault.slOrderKey()) !== ethers.ZeroHash) {
      await (await vault.cancelStopLoss()).wait();
    }

    /** Active — 시장가 청산 **/
    if ((await vault.state()) === 2n) {
      let ethBal = await ethers.provider.getBalance(vaultAddr);
      if (ethBal < execFee) {
        await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
      }
      const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      await (await vault.closePosition(0n, { value: execFee })).wait();

      const deadline = Date.now() + SETTLE_TIMEOUT_MS;
      while (Date.now() < deadline) {
        const state: bigint = await vault.state();
        const sizeNow = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
        if (state === 0n && sizeNow < sizeBefore) break;
        if (state === 3n) {
          const pending = await vault.pending();
          if (pending.orderKey !== ethers.ZeroHash) {
            const order = await vault.gmxOrders(pending.orderKey);
          }
        }
        await new Promise((r) => setTimeout(r, 5_000));
      }
    }

    /** Empty — 잔여 USDC 회수 **/
    if ((await vault.state()) === 0n) {
      const idle = await usdc.balanceOf(vaultAddr);
      if (idle > 0n) {
        await (await vault.withdraw(idle)).wait();
      }
    }
  });

  it("take profit only", async function () {
    expect(await vault.state()).to.equal(2n);

    /** 숏 TP trigger — mark 아래 0.01% (가격 하락 시 체결) **/
    const mark: bigint = await oracle.getPrice();
    const tpTrigger = (mark * 9999n) / 10_000n;
    console.log(
      `  TP — mark ${ethers.formatUnits(mark, 8)} trigger ${ethers.formatUnits(tpTrigger, 8)} (-0.01%)`,
    );

    /** 가스비 전송 **/
    let ethBal = await ethers.provider.getBalance(vaultAddr);
    if (ethBal < execFee) {
      await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
    }

    /** 익절 주문 설정 **/
    await (await vault.setTakeProfit(tpTrigger, { value: execFee })).wait();

    /** TP만 설정됐는지 확인 **/
    expect(await vault.tpOrderKey()).to.not.equal(ethers.ZeroHash);
    expect(await vault.slOrderKey()).to.equal(ethers.ZeroHash);
    expect(await vault.state()).to.equal(2n);

    /** TP 취소 — 다음 테스트를 위해 정리 **/
    await (await vault.cancelTakeProfit()).wait();
    expect(await vault.tpOrderKey()).to.equal(ethers.ZeroHash);
    expect(await vault.state()).to.equal(2n);
  });

  it("stop loss only", async function () {
    expect(await vault.state()).to.equal(2n);

    /** 숏 SL trigger — mark 위 0.01% (가격 상승 시 체결) **/
    const mark: bigint = await oracle.getPrice();
    const slTrigger = (mark * 10001n) / 10_000n;
    console.log(
      `  SL — mark ${ethers.formatUnits(mark, 8)} trigger ${ethers.formatUnits(slTrigger, 8)} (+0.01%)`,
    );

    /** 가스비 전송 **/
    let ethBal = await ethers.provider.getBalance(vaultAddr);
    if (ethBal < execFee) {
      await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
    }

    /** 손절 주문 설정 **/
    await (await vault.setStopLoss(slTrigger, { value: execFee })).wait();

    /** SL만 설정됐는지 확인 **/
    expect(await vault.slOrderKey()).to.not.equal(ethers.ZeroHash);
    expect(await vault.tpOrderKey()).to.equal(ethers.ZeroHash);
    expect(await vault.state()).to.equal(2n);

    /** SL 취소 — 다음 테스트를 위해 정리 **/
    await (await vault.cancelStopLoss()).wait();
    expect(await vault.slOrderKey()).to.equal(ethers.ZeroHash);
    expect(await vault.state()).to.equal(2n);
  });

  it("take profit and stop loss", async function () {
    expect(await vault.state()).to.equal(2n);

    /** 숏 TP/SL trigger — mark 기준 아래·위 0.01% **/
    const mark: bigint = await oracle.getPrice();
    const tpTrigger = (mark * 9999n) / 10_000n;
    const slTrigger = (mark * 10001n) / 10_000n;
    console.log(
      `  TP+SL — mark ${ethers.formatUnits(mark, 8)} tp ${ethers.formatUnits(tpTrigger, 8)} sl ${ethers.formatUnits(slTrigger, 8)}`,
    );

    /** 가스비 전송 (TP + SL 각각 exec fee) **/
    let ethBal = await ethers.provider.getBalance(vaultAddr);
    if (ethBal < execFee * 2n) {
      await (await owner.sendTransaction({ to: vaultAddr, value: execFee * 2n - ethBal })).wait();
    }

    /** 익절 주문 설정 **/
    await (await vault.setTakeProfit(tpTrigger, { value: execFee })).wait();
    expect(await vault.tpOrderKey()).to.not.equal(ethers.ZeroHash);

    /** 손절 주문 설정 **/
    await (await vault.setStopLoss(slTrigger, { value: execFee })).wait();

    /** TP·SL 동시에 걸렸는지 확인 **/
    expect(await vault.tpOrderKey()).to.not.equal(ethers.ZeroHash);
    expect(await vault.slOrderKey()).to.not.equal(ethers.ZeroHash);
    expect(await vault.state()).to.equal(2n);

    /** 둘 다 취소 **/
    await (await vault.cancelTakeProfit()).wait();
    await (await vault.cancelStopLoss()).wait();
    expect(await vault.tpOrderKey()).to.equal(ethers.ZeroHash);
    expect(await vault.slOrderKey()).to.equal(ethers.ZeroHash);
    expect(await vault.state()).to.equal(2n);
  });

  it("stop loss after mint — debt>0일 때 SL 트리거 LTV cap(RLT−3%) 통과", async function () {
    expect(await vault.state()).to.equal(2n);
    expect(await vault.debt()).to.equal(0n);
    expect(await vault.slOrderKey()).to.equal(ethers.ZeroHash);

    /** mint headroom 25% — SL 트리거 가격에서 LTV ≤ cap 여유 **/
    const colVal: bigint = await lens.collateralValueUsdWad(vaultAddr);
    const debtVal: bigint = await lens.debtValueUsdWad(vaultAddr);
    const effMax: bigint = await lens.effectiveMaxLtvBps(vaultAddr);
    const maxDebt = (colVal * effMax) / BPS;
    const headroom = maxDebt > debtVal ? maxDebt - debtVal : 0n;
    expect(headroom).to.be.gt(0n);

    const price8: bigint = await oracle.getPrice();
    const mintUsdWad = headroom / 4n;
    const mintAmount = (mintUsdWad * PRICE_ONE) / price8;
    expect(mintAmount).to.be.gt(0n);

    await (await vault.mint(mintAmount)).wait();
    expect(await vault.debt()).to.equal(mintAmount);

    /** 숏 SL trigger — mark 위 0.01% **/
    const mark: bigint = await oracle.getPrice();
    const slTrigger = (mark * 10001n) / 10_000n;
    const slCap: bigint = (await lens.rltBps(vaultAddr)) - SL_LTV_BUFFER_BPS;

    let ethBal = await ethers.provider.getBalance(vaultAddr);
    if (ethBal < execFee) {
      await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
    }

    /** debt>0 → setStopLoss 시 트리거 가격 LTV ≤ RLT−3% 검사 **/
    await (await vault.setStopLoss(slTrigger, { value: execFee })).wait();

    expect(await vault.slOrderKey()).to.not.equal(ethers.ZeroHash);
    expect(await vault.slTriggerPrice8()).to.equal(slTrigger);
    expect(await vault.state()).to.equal(2n);

    const ltvNow: bigint = await lens.currentLTV(vaultAddr);
    expect(ltvNow).to.be.lte(effMax);

    console.log(
      `  SL after mint — debt ${ethers.formatEther(mintAmount)}, SL trigger ${ethers.formatUnits(slTrigger, 8)}, LTV ${ltvNow} bps (SL cap ${slCap} bps at trigger)`,
    );

    /** 정리 **/
    await (await vault.cancelStopLoss()).wait();
    await (await vault.repay(mintAmount)).wait();
    expect(await vault.debt()).to.equal(0n);
  });

  it("mint after stop loss — SL 유지 mint, 과다 mint는 SlLtvExceeded", async function () {
    expect(await vault.state()).to.equal(2n);
    expect(await vault.debt()).to.equal(0n);
    expect(await vault.slOrderKey()).to.equal(ethers.ZeroHash);

    const mark: bigint = await oracle.getPrice();
    const slTrigger = (mark * 10001n) / 10_000n;
    const slCap: bigint = (await lens.rltBps(vaultAddr)) - SL_LTV_BUFFER_BPS;

    let ethBal = await ethers.provider.getBalance(vaultAddr);
    if (ethBal < execFee) {
      await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
    }

    /** debt=0 → SL 먼저 설정 (트리거 방향만 검사) **/
    await (await vault.setStopLoss(slTrigger, { value: execFee })).wait();
    expect(await vault.slTriggerPrice8()).to.equal(slTrigger);

    const colVal: bigint = await lens.collateralValueUsdWad(vaultAddr);
    const debtVal: bigint = await lens.debtValueUsdWad(vaultAddr);
    const effMax: bigint = await lens.effectiveMaxLtvBps(vaultAddr);
    const maxDebt = (colVal * effMax) / BPS;
    const headroom = maxDebt > debtVal ? maxDebt - debtVal : 0n;
    expect(headroom).to.be.gt(0n);

    const price8: bigint = await oracle.getPrice();
    const greedyUsdWad = (headroom * 98n) / 100n;
    const greedyMint = (greedyUsdWad * PRICE_ONE) / price8;
    const safeUsdWad = headroom / 4n;
    const safeMint = (safeUsdWad * PRICE_ONE) / price8;

    /** SL 트리거 가격 기준 LTV cap 초과 mint 거부 **/
    await expect(vault.mint.staticCall(greedyMint)).to.be.revertedWithCustomError(vault, "SlLtvExceeded");

    /** cap 이내 mint 허용 **/
    await (await vault.mint(safeMint)).wait();
    expect(await vault.debt()).to.equal(safeMint);
    expect(await vault.slOrderKey()).to.not.equal(ethers.ZeroHash);

    const ltv: bigint = await lens.currentLTV(vaultAddr);
    expect(ltv).to.be.lte(effMax);

    console.log(
      `  mint after SL — +${ethers.formatEther(safeMint)} rToken (greedy ${ethers.formatEther(greedyMint)} reverted), LTV ${ltv}/${effMax} bps, SL cap ${slCap} bps at trigger`,
    );

    /** 정리 **/
    await (await vault.cancelStopLoss()).wait();
    await (await vault.repay(safeMint)).wait();
    expect(await vault.debt()).to.equal(0n);
  });
});
