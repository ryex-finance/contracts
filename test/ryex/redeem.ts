/**
 * redeem.ts — RLT zone rToken redeem 테스트 (Arbitrum Sepolia)
 *
 *   npx hardhat test test/ryex/redeem.ts --network arbitrumSepolia
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
const REDEEM_FEE_BPS = 25n;
// GMX Keys.sol: keccak256(abi.encode(string)) — keccak256(toUtf8Bytes(...))는 다른 값 (2026-09-02 버그 수정)
const ACCOUNT_ORDER_LIST = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"]));

describe("short rToken redeem (Arbitrum Sepolia)", function () {
  this.timeout(30 * 60_000);

  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let ownerAddr: string;
  let marketId: string;
  let rTokenAddr: string;
  let usdcAddr: string;
  let execFee: bigint;

  let factory: Contract;
  let router: Contract;
  let lens: Contract;
  let usdc: Contract;
  let rToken: Contract;
  let dataStore: Contract;
  let vaultAddr: string;
  let vault: Contract;
  let orderListKey: string;

  let gmxOracleAddr: string;
  let mockOracle: Contract;
  let chainlinkPrice8: bigint;

  before(async function () {
    /** 테스트 계정 (mint·redeem 동일 owner) **/
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
      markets: Record<string, { marketId: string; rToken: string; oracle: string }>;
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
    usdcAddr = deployment.usdc;
    gmxOracleAddr = deployment.markets[MARKET].oracle;

    factory = await ethers.getContractAt("VaultFactory", deployment.vaultFactory, owner);
    router = await ethers.getContractAt("RyexRouter", deployment.ryexRouter, owner);
    lens = await ethers.getContractAt("VaultLens", deployment.vaultLens, owner);
    usdc = new ethers.Contract(usdcAddr, ERC20Abi, owner);
    rToken = new ethers.Contract(rTokenAddr, ERC20Abi, owner);

    /** USDC allowance — owner **/
    const allowance: bigint = await usdc.allowance(ownerAddr, deployment.ryexRouter);
    if (allowance !== ethers.MaxUint256) {
      await (await usdc.approve(deployment.ryexRouter, ethers.MaxUint256)).wait();
    }

    /** GMX exec fee · dataStore **/
    const infra = await factory.gmxInfra();
    execFee = infra.execFee;
    dataStore = await ethers.getContractAt(
      ["function containsBytes32(bytes32,bytes32) view returns (bool)"],
      infra.dataStore,
    );

    console.log(`\nOwner  : ${ownerAddr}`);
    console.log(`Router : ${deployment.ryexRouter}`);
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

    if (!reusingActive) {
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
    } else {
      let ethBal = await ethers.provider.getBalance(vaultAddr);
      if (ethBal < execFee) {
        await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
      }
    }

    expect(await vault.state()).to.equal(2n);

    /** 부채 확보 — headroom 95% mint **/
    const colVal: bigint = await lens.collateralValueUsdWad(vaultAddr);
    const debtVal: bigint = await lens.debtValueUsdWad(vaultAddr);
    const effMax: bigint = await lens.effectiveMaxLtvBps(vaultAddr);
    const maxDebt = (colVal * effMax) / BPS;
    const headroom = maxDebt > debtVal ? maxDebt - debtVal : 0n;
    expect(headroom).to.be.gt(0n);

    const gmxOracle = await ethers.getContractAt(
      ["function getPrice() view returns (uint256)"],
      gmxOracleAddr,
      owner,
    );
    chainlinkPrice8 = await gmxOracle.getPrice();

    const mintUsdWad = (headroom * 95n) / 100n;
    const mintAmount = (mintUsdWad * PRICE_ONE) / chainlinkPrice8;
    if ((await vault.debt()) === 0n) {
      await (await vault.mint(mintAmount)).wait();
    }

    /** Chainlink 가격 스냅샷 → MockPriceOracle 배포·전환 **/
    const MockOracle = await ethers.getContractFactory("MockPriceOracle", owner);
    mockOracle = await MockOracle.deploy(chainlinkPrice8);
    await mockOracle.waitForDeployment();
    const mockAddr = await mockOracle.getAddress();

    await (await factory.setMarketOracle(marketId, mockAddr)).wait();
    expect((await factory.markets(marketId)).oracle).to.equal(mockAddr);

    /** 숏 adverse — 가격 상승으로 LTV↑ → RLT zone (RLT ≤ LTV < LLTV) **/
    let mockPrice = chainlinkPrice8;
    const rlt: bigint = await lens.rltBps(vaultAddr);
    const lltv: bigint = await lens.lltvBps(vaultAddr);
    let enteredZone = false;

    for (let step = 0; step < 30; step++) {
      if (await lens.isRedeemable(vaultAddr)) {
        enteredZone = true;
        break;
      }
      if (await lens.isLiquidatable(vaultAddr)) {
        throw new Error("before: mock price pushed vault into liquidation");
      }
      mockPrice = (mockPrice * 102n) / 100n;
      await (await mockOracle.setPrice(mockPrice)).wait();
      await new Promise((r) => setTimeout(r, 1_000));
    }
    if (!enteredZone) {
      throw new Error("before: failed to enter RLT redemption zone");
    }

    const ltv: bigint = await lens.currentLTV(vaultAddr);
    console.log(
      `  before — Active short, debt ${ethers.formatEther(await vault.debt())} rToken, LTV ${ltv} bps (RLT ${rlt}–LLTV ${lltv}), mock ${ethers.formatUnits(mockPrice, 8)} (was ${ethers.formatUnits(chainlinkPrice8, 8)})`,
    );
    expect(await lens.isRedeemable(vaultAddr)).to.equal(true);
    expect(await lens.isLiquidatable(vaultAddr)).to.equal(false);
  });

  after(async function () {
    if (!vault) return;

    /** GmxPriceOracle 복원 **/
    const [, currentOracle] = await factory.markets(marketId);
    if (currentOracle !== gmxOracleAddr) {
      await (await factory.setMarketOracle(marketId, gmxOracleAddr)).wait();
      console.log(`  after — oracle restored to ${gmxOracleAddr}`);
    }

    /** 미체결 redeem 정산 대기 — pending 있으면 close 불가 **/
    if ((await vault.state()) === 2n && (await vault.pending()).kind === 8n) {
      const redeemDeadline = Date.now() + SETTLE_TIMEOUT_MS;
      while (Date.now() < redeemDeadline) {
        if ((await vault.pending()).kind === 0n) break;
        const pending = await vault.pending();
        if (pending.orderKey !== ethers.ZeroHash) {
          const order = await vault.gmxOrders(pending.orderKey);
        }
        await new Promise((r) => setTimeout(r, 5_000));
      }
    }

    /** 잔여 부채 상환 — close는 debt=0 필수 **/
    const debt: bigint = await vault.debt();
    if (debt > 0n) {
      const ownerRToken: bigint = await rToken.balanceOf(ownerAddr);
      if (ownerRToken < debt) {
        throw new Error(`after: insufficient rToken to repay (have ${ownerRToken}, need ${debt})`);
      }
      await (await rToken.approve(vaultAddr, debt)).wait();
      await (await vault.repay(debt)).wait();
    }

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

    /** SettlingLiquidate — close 정산만 대기 **/
    if ((await vault.state()) === 3n) {
      const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      const deadline = Date.now() + SETTLE_TIMEOUT_MS;
      while (Date.now() < deadline) {
        const state: bigint = await vault.state();
        const sizeNow = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
        if (state === 0n && sizeNow < sizeBefore) break;
        const pending = await vault.pending();
        if (pending.orderKey !== ethers.ZeroHash) {
          const order = await vault.gmxOrders(pending.orderKey);
        }
        await new Promise((r) => setTimeout(r, 5_000));
      }
    }

    if ((await vault.state()) === 2n) {
      throw new Error("after: GMX position close timed out");
    }

    /** Empty — 잔여 USDC 회수 **/
    if ((await vault.state()) === 0n) {
      const idle = await usdc.balanceOf(vaultAddr);
      if (idle > 0n) {
        await (await vault.withdraw(idle)).wait();
      }
    }

    const gmxSize = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
    console.log(`  after — state ${await vault.state()}, GMX size ${ethers.formatUnits(gmxSize, 30)} USD`);
  });

  it("redeem — 부분 부채 청산·포지션 축소·USDC 수령", async function () {
    this.timeout(15 * 60_000);

    expect(await lens.isRedeemable(vaultAddr)).to.equal(true);

    const debtBefore: bigint = await vault.debt();
    const redeemAmount = debtBefore / 4n;
    expect(redeemAmount).to.be.gt(0n);

    const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
    /** redeem sizeDelta는 mock ledger equity 기준 — lensGmxEquityUsdWad와 동일 경로 **/
    const equityUsdc = (await vault.lensGmxEquityUsdWad()) / 10n ** 12n;
    expect(sizeBefore).to.be.gt(0n);
    expect(equityUsdc).to.be.gt(0n);

    const mockPrice8: bigint = await mockOracle.getPrice();
    const redeemUsdcEst = (redeemAmount * mockPrice8) / PRICE_ONE / 10n ** 12n;

    /** mint로 보유한 rToken approve **/
    await (await rToken.approve(vaultAddr, redeemAmount)).wait();

    const usdcBefore: bigint = await usdc.balanceOf(ownerAddr);

    /** RLT redeem 호출 **/
    await (await vault.redeem(redeemAmount, { value: execFee })).wait();

    /** GMX partial decrease 정산 대기 **/
    const redeemDeadline = Date.now() + SETTLE_TIMEOUT_MS;
    while (Date.now() < redeemDeadline) {
      const debtNow: bigint = await vault.debt();
      if (debtNow === debtBefore - redeemAmount) break;

      const pending = await vault.pending();
      if (pending.orderKey !== ethers.ZeroHash) {
        const order = await vault.gmxOrders(pending.orderKey);
      }
      await new Promise((r) => setTimeout(r, 5_000));
    }

    /** 부채 감소 확인 **/
    expect(await vault.debt()).to.equal(debtBefore - redeemAmount);

    /** 포지션 비율만큼 축소 확인 (GMX size 30dec) **/
    const sizeAfter = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
    expect(sizeAfter).to.be.lt(sizeBefore);

    const expectedSizeAfter = (sizeBefore * (equityUsdc - redeemUsdcEst)) / equityUsdc;
    /** GMX reader sizeInUsd vs mockSizeUsd 기준 sizeDelta — Sepolia에서 ~12% drift 관측 **/
    const sizeTol = (expectedSizeAfter * 15n) / 100n;
    expect(sizeAfter).to.be.gte(expectedSizeAfter > sizeTol ? expectedSizeAfter - sizeTol : 0n);
    expect(sizeAfter).to.be.lte(expectedSizeAfter + sizeTol);

    /** 호출자 USDC 수령 확인 (redeem fee 0.25% 차감) **/
    const usdcAfter: bigint = await usdc.balanceOf(ownerAddr);
    const usdcReceived = usdcAfter - usdcBefore;
    expect(usdcReceived).to.be.gt(0n);

    const minExpected = (redeemUsdcEst * (BPS - REDEEM_FEE_BPS) * 80n) / (BPS * 100n);
    expect(usdcReceived).to.be.gte(minExpected);

    console.log(
      `  redeem — −${ethers.formatEther(redeemAmount)} rToken, size ${ethers.formatUnits(sizeBefore, 30)} → ${ethers.formatUnits(sizeAfter, 30)} USD, +${ethers.formatUnits(usdcReceived, 6)} USDC`,
    );
  });
});
