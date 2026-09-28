/**
 * settlement.ts — 수수료 적립·close 후 treasury 정산 테스트 (Arbitrum Sepolia)
 *
 *   npx hardhat test test/ryex/settlement.ts --network arbitrumSepolia
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
const MINT_FEE_BPS = 25n;
const REPAY_FEE_BPS = 25n;
// GMX Keys.sol: keccak256(abi.encode(string)) — keccak256(toUtf8Bytes(...))는 다른 값 (2026-09-02 버그 수정)
const ACCOUNT_ORDER_LIST = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"]));

describe("fee settlement (Arbitrum Sepolia)", function () {
  this.timeout(30 * 60_000);

  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let ownerAddr: string;
  let marketId: string;
  let rTokenAddr: string;
  let treasuryAddr: string;
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
  let feesBaseline = 0n;

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
      ryexTreasury?: string;
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

    treasuryAddr = deployment.ryexTreasury ?? (await factory.treasury());
    expect(treasuryAddr).to.not.equal(ethers.ZeroAddress);

    /** USDC allowance **/
    const allowance: bigint = await usdc.allowance(ownerAddr, deployment.ryexRouter);
    if (allowance !== ethers.MaxUint256) {
      await (await usdc.approve(deployment.ryexRouter, ethers.MaxUint256)).wait();
    }

    /** GMX exec fee · dataStore · oracle **/
    const infra = await factory.gmxInfra();
    execFee = infra.execFee;
    dataStore = await ethers.getContractAt(
      ["function containsBytes32(bytes32,bytes32) view returns (bool)"],
      infra.dataStore,
    );
    const [, oracleAddr] = await factory.markets(marketId);
    oracle = await ethers.getContractAt(["function getPrice() view returns (uint256)"], oracleAddr, owner);

    console.log(`\nOwner    : ${ownerAddr}`);
    console.log(`Treasury : ${treasuryAddr}`);
    console.log(`rToken   : ${rTokenAddr}`);

    /** 기존 숏 볼트 정리 **/
    let reusingActive = false;
    vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
    if (vaultAddr !== ethers.ZeroAddress) {
      vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
      orderListKey = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
      );

      const existingDebt: bigint = await vault.debt();
      if (existingDebt > 0n) {
        await (await vault.repay(existingDebt)).wait();
      }

      if ((await vault.tpOrderKey()) !== ethers.ZeroHash) {
        await (await vault.cancelTakeProfit()).wait();
      }
      if ((await vault.slOrderKey()) !== ethers.ZeroHash) {
        await (await vault.cancelStopLoss()).wait();
      }
      if ((await vault.state()) === 1n) {
        await (await vault.cancelLimitOrder()).wait();
      }

      /** Active + GMX 포지션 있으면 close·재오픈 생략 (exec fee 절약) **/
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
        const ownerEth = await ethers.provider.getBalance(ownerAddr);
        const need = execFee - ethBal;
        if (ownerEth >= need) {
          await (await owner.sendTransaction({ to: vaultAddr, value: need })).wait();
        }
      }
    } else {
    /** USDC 예치 · 시장가 숏 오픈 **/
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

    expect(await vault.debt()).to.equal(0n);
    feesBaseline = await vault.accruedFeesUsdc();

    console.log(`  before — short Active, debt=0, fees=${feesBaseline}`);
  });

  after(async function () {
    if (!vault) return;

    const debt: bigint = await vault.debt();
    if (debt > 0n) {
      await (await vault.repay(debt)).wait();
    }

    if ((await vault.tpOrderKey()) !== ethers.ZeroHash) {
      await (await vault.cancelTakeProfit()).wait();
    }
    if ((await vault.slOrderKey()) !== ethers.ZeroHash) {
      await (await vault.cancelStopLoss()).wait();
    }

    if ((await vault.state()) === 2n) {
      let ethBal = await ethers.provider.getBalance(vaultAddr);
      if (ethBal < execFee) {
        const ownerEth = await ethers.provider.getBalance(ownerAddr);
        const need = execFee - ethBal;
        if (ownerEth >= need) {
          await (await owner.sendTransaction({ to: vaultAddr, value: need })).wait();
        }
      }
      const ownerEth = await ethers.provider.getBalance(ownerAddr);
      if (ownerEth >= execFee) {
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
    }

    if ((await vault.state()) === 0n) {
      const idle = await usdc.balanceOf(vaultAddr);
      if (idle > 0n) {
        await (await vault.withdraw(idle)).wait();
      }
    }
  });

  it("mint·borrow·repay fee — accruedFeesUsdc·pendingFeesUsdc 증가", async function () {
    this.timeout(10 * 60_000);

    expect(await vault.state()).to.equal(2n);
    expect(await vault.accruedFeesUsdc()).to.equal(feesBaseline);

    /** headroom 50% mint — mint fee 0.25% 적립 **/
    const colVal: bigint = await lens.collateralValueUsdWad(vaultAddr);
    const debtVal: bigint = await lens.debtValueUsdWad(vaultAddr);
    const effMax: bigint = await lens.effectiveMaxLtvBps(vaultAddr);
    const maxDebt = (colVal * effMax) / BPS;
    const headroom = maxDebt > debtVal ? maxDebt - debtVal : 0n;
    expect(headroom).to.be.gt(0n);

    const price8: bigint = await oracle.getPrice();
    const mintUsdWad = headroom / 2n;
    const mintAmount = (mintUsdWad * PRICE_ONE) / price8;
    const mintUsdcEst = mintUsdWad / 10n ** 12n;
    const expectedMintFee = (mintUsdcEst * MINT_FEE_BPS) / BPS;

    await (await vault.mint(mintAmount)).wait();

    const accruedAfterMint: bigint = await vault.accruedFeesUsdc();
    expect(accruedAfterMint).to.be.gt(0n);
    expect(accruedAfterMint).to.be.gte(expectedMintFee > 0n ? expectedMintFee : 1n);

    /** borrow fee — 시간 경과 후 repay 시 _accrueBorrow가 미적립 borrow 반영 **/
    console.log(`  borrow accrual wait 60s…`);
    await new Promise((r) => setTimeout(r, 60_000));
    await (await owner.sendTransaction({ to: ownerAddr, value: 0n })).wait();

    /** partial repay — repay fee + borrow accrual checkpoint **/
    const debt: bigint = await vault.debt();
    const repayAmount = debt / 4n;
    expect(repayAmount).to.be.gt(0n);

    const repayUsdcEst = (repayAmount * price8) / PRICE_ONE / 10n ** 12n;
    const expectedRepayFee = (repayUsdcEst * REPAY_FEE_BPS) / BPS;
    const accruedBeforeRepay: bigint = await vault.accruedFeesUsdc();

    await (await vault.repay(repayAmount)).wait();

    const accruedAfterRepay: bigint = await vault.accruedFeesUsdc();
    const feeDelta = accruedAfterRepay - accruedBeforeRepay;
    expect(feeDelta).to.be.gt(expectedRepayFee > 0n ? expectedRepayFee : 1n);

    console.log(
      `  fees — mint ${accruedAfterMint}, after repay +${feeDelta} USDC (6dec, incl. borrow accrual)`,
    );
  });

  it("close·withdraw — GMX 종료 후 accruedFeesUsdc → treasury 정산", async function () {
    this.timeout(15 * 60_000);

    /** 잔여 부채 전액 상환 — close는 debt=0 필수 **/
    const debt: bigint = await vault.debt();
    if (debt > 0n) {
      await (await vault.repay(debt)).wait();
    }
    expect(await vault.debt()).to.equal(0n);

    const accruedBeforeClose: bigint = await vault.accruedFeesUsdc();
    expect(accruedBeforeClose).to.be.gt(0n);

    const ownerEthForClose = await ethers.provider.getBalance(ownerAddr);
    if (ownerEthForClose < execFee) {
      console.log(
        `  skip close·withdraw — owner ETH ${ethers.formatEther(ownerEthForClose)} < execFee ${ethers.formatEther(execFee)}`,
      );
      this.skip();
    }

    const treasuryUsdcBefore: bigint = await usdc.balanceOf(treasuryAddr);
    const ownerUsdcBefore: bigint = await usdc.balanceOf(ownerAddr);

    /** 시장가 close — GMX 포지션 종료 **/
    let ethBal = await ethers.provider.getBalance(vaultAddr);
    if (ethBal < execFee) {
      await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
    }
    const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
    await (await vault.closePosition(0n, { value: execFee })).wait();

    const closeDeadline = Date.now() + SETTLE_TIMEOUT_MS;
    while (Date.now() < closeDeadline) {
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

    expect(await vault.state()).to.equal(0n);
    expect((await lens.gmxPosition(vaultAddr)).sizeInUsd).to.be.lt(sizeBefore);

    /** withdraw — posKey=0·fee>0 이면 treasury 정산 + owner 환급 **/
    const vaultUsdc: bigint = await usdc.balanceOf(vaultAddr);
    expect(vaultUsdc).to.be.gt(0n);

    await (await vault.withdraw(1n)).wait();

    const accruedAfter: bigint = await vault.accruedFeesUsdc();
    expect(accruedAfter).to.equal(0n);

    const treasuryUsdcAfter: bigint = await usdc.balanceOf(treasuryAddr);
    const ownerUsdcAfter: bigint = await usdc.balanceOf(ownerAddr);
    const treasuryReceived = treasuryUsdcAfter - treasuryUsdcBefore;
    const ownerReceived = ownerUsdcAfter - ownerUsdcBefore;

    expect(treasuryReceived).to.be.gte(accruedBeforeClose > 1n ? accruedBeforeClose - 1n : 0n);
    expect(ownerReceived).to.be.gt(0n);

    console.log(
      `  close·withdraw — fees ${accruedBeforeClose} → treasury +${ethers.formatUnits(treasuryReceived, 6)} USDC, owner +${ethers.formatUnits(ownerReceived, 6)} USDC`,
    );
  });
});
