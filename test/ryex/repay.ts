/**
 * repay.ts — Active 숏 포지션에서 rToken repay 테스트 (Arbitrum Sepolia)
 *
 *   npx hardhat test test/ryex/repay.ts --network arbitrumSepolia
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
// GMX Keys.sol: keccak256(abi.encode(string)) — keccak256(toUtf8Bytes(...))는 다른 값 (2026-09-02 버그 수정)
const ACCOUNT_ORDER_LIST = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"]));

describe("short rToken repay (Arbitrum Sepolia)", function () {
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
    console.log(`rToken : ${rTokenAddr}`);

    /** 기존 숏 볼트 정리 **/
    let reusingActive = false;
    vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
    if (vaultAddr !== ethers.ZeroAddress) {
      vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
      orderListKey = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
      );

      /** 기존 부채 상환 — repay 테스트는 mint 후 시작 **/
      const existingDebt: bigint = await vault.debt();
      if (existingDebt > 0n) {
        await (await vault.repay(existingDebt)).wait();
      }

      /** TP/SL 취소 **/
      if ((await vault.tpOrderKey()) !== ethers.ZeroHash) {
        await (await vault.cancelTakeProfit()).wait();
      }
      if ((await vault.slOrderKey()) !== ethers.ZeroHash) {
        await (await vault.cancelStopLoss()).wait();
      }

      if ((await vault.state()) === 1n) {
        await (await vault.cancelLimitOrder()).wait();
      }

      /** Active + GMX 포지션 있으면 재오픈 생략 **/
      if ((await vault.state()) === 2n) {
        const gmxSize = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
        if (gmxSize > 0n) {
          reusingActive = true;
        }
      }

      if (!reusingActive && (await vault.state()) === 2n) {
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

      if (!reusingActive && (await vault.state()) === 0n) {
        const idle = await usdc.balanceOf(vaultAddr);
        if (idle > 0n) {
          await (await vault.withdraw(idle)).wait();
        }
      }
    }

    if (reusingActive) {
      let ethBal = await ethers.provider.getBalance(vaultAddr);
      if (ethBal < execFee) {
        await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
      }
    } else {
      /** USDC 예치 **/
      await (await router.deposit(marketId, IS_LONG, DEPOSIT_USDC)).wait();
      vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
      vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
      orderListKey = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
      );

      let ethBal = await ethers.provider.getBalance(vaultAddr);
      if (ethBal < execFee) {
        await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
      }

      /** 시장가 숏 오픈 **/
      const expectedDelta = DEPOSIT_USDC * 10n ** 24n * BigInt(LEVERAGE);
      const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      const minSize = sizeBefore + (expectedDelta * 95n) / 100n;

      await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, DEPOSIT_USDC, { value: execFee })).wait();

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
    }

    expect(await vault.state()).to.equal(2n);
    expect(await vault.debt()).to.equal(0n);

    /** headroom 95% mint — repay 테스트용 부채 확보 **/
    const colVal: bigint = await lens.collateralValueUsdWad(vaultAddr);
    const debtVal: bigint = await lens.debtValueUsdWad(vaultAddr);
    const effMax: bigint = await lens.effectiveMaxLtvBps(vaultAddr);
    const maxDebt = (colVal * effMax) / BPS;
    const headroom = maxDebt > debtVal ? maxDebt - debtVal : 0n;
    expect(headroom).to.be.gt(0n);

    const price8: bigint = await oracle.getPrice();
    const mintUsdWad = (headroom * 95n) / 100n;
    const mintAmount = (mintUsdWad * PRICE_ONE) / price8;
    expect(mintAmount).to.be.gt(0n);

    await (await vault.mint(mintAmount)).wait();
    expect(await vault.debt()).to.equal(mintAmount);
    expect(await rToken.balanceOf(ownerAddr)).to.be.gte(mintAmount);

    console.log(
      `  before — short Active, minted ${ethers.formatEther(mintAmount)} rToken, debt ${await vault.debt()}`,
    );
  });

  after(async function () {
    if (!vault) return;

    /** 부채 상환 **/
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

    /** Active — 시장가 청산 (debt=0 필수) **/
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

    if ((await vault.state()) === 0n) {
      const idle = await usdc.balanceOf(vaultAddr);
      if (idle > 0n) {
        await (await vault.withdraw(idle)).wait();
      }
    }
  });

  it("close with debt — OutstandingDebt revert", async function () {
    expect(await vault.state()).to.equal(2n);

    const debt: bigint = await vault.debt();
    expect(debt).to.be.gt(0n);

    /** 가스비 전송 **/
    let ethBal = await ethers.provider.getBalance(vaultAddr);
    if (ethBal < execFee) {
      await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
    }

    /** 부채 있으면 close 불가 — debt=0 필수 **/
    await expect(vault.closePosition(0n, { value: execFee })).to.be.revertedWithCustomError(
      vault,
      "OutstandingDebt",
    );

    expect(await vault.debt()).to.equal(debt);
    expect(await vault.state()).to.equal(2n);

    console.log(`  OutstandingDebt — debt ${ethers.formatEther(debt)}, close rejected`);
  });

  it("partial repay — vault.debt·rToken 잔액 감소", async function () {
    expect(await vault.state()).to.equal(2n);

    const debtBefore: bigint = await vault.debt();
    expect(debtBefore).to.be.gt(0n);

    const repayAmount = debtBefore / 2n;
    expect(repayAmount).to.be.gt(0n);

    const rTokenBefore: bigint = await rToken.balanceOf(ownerAddr);

    /** 부채 50% 상환 **/
    await (await vault.repay(repayAmount)).wait();

    /** vault.debt·owner rToken 확인 **/
    expect(await vault.debt()).to.equal(debtBefore - repayAmount);
    expect(await rToken.balanceOf(ownerAddr)).to.equal(rTokenBefore - repayAmount);

    console.log(
      `  partial repay — −${ethers.formatEther(repayAmount)} rToken, debt ${await vault.debt()}`,
    );
  });

  it("full repay — debt 0", async function () {
    expect(await vault.state()).to.equal(2n);

    const debtBefore: bigint = await vault.debt();
    expect(debtBefore).to.be.gt(0n);

    const rTokenBefore: bigint = await rToken.balanceOf(ownerAddr);
    expect(rTokenBefore).to.be.gte(debtBefore);

    /** 잔여 부채 전액 상환 **/
    await (await vault.repay(debtBefore)).wait();

    /** debt=0·rToken burn 확인 **/
    expect(await vault.debt()).to.equal(0n);
    expect(await rToken.balanceOf(ownerAddr)).to.equal(rTokenBefore - debtBefore);

    const ltv: bigint = await lens.currentLTV(vaultAddr);
    expect(ltv).to.equal(0n);

    console.log(`  full repay — debt 0, LTV ${ltv} bps`);
  });
});
