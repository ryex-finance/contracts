/**
 * collateralSizing.ts — 요청 담보량 open / shortfall / settle onlyOwner
 *
 *   npx hardhat test test/ryex/collateralSizing.ts --network arbitrumSepolia
 *
 * settleGmxOrder는 호출하지 않음 (GMX OrderHandler 콜백만).
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { expect } from "chai";
import type { Contract } from "ethers";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";
import { waitClosedEmpty, waitOpenActive, waitStateIn, DEFAULT_SETTLE_TIMEOUT_MS } from "./helpers/waitGmx";

const MARKET = "rETH";
const IS_LONG = false;
const LEVERAGE = 2;
const DEPOSIT_FULL = 10n * 10n ** 6n; // 10 USDC
const OPEN_PARTIAL = 5n * 10n ** 6n; // 5 USDC
const INCREASE_AMT = 3n * 10n ** 6n; // 3 USDC

describe("collateral sizing + settle auth (Arbitrum Sepolia)", function () {
  this.timeout(40 * 60_000);

  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let alt: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let ownerAddr: string;
  let factory: Contract;
  let router: Contract;
  let lens: Contract;
  let usdc: Contract;
  let marketId: string;
  let execFee: bigint;
  let vaultAddr: string;
  let vault: Contract;

  async function resetVault() {
    vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
    if (vaultAddr === ethers.ZeroAddress) return;
    vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);

    if ((await vault.state()) === 1n) {
      await (await vault.cancelLimitOrder()).wait();
      await waitStateIn(vault, [0n, 2n], { label: "reset cancel limit" });
    }
    if ((await vault.state()) === 3n) {
      await waitClosedEmpty(vault, { label: "reset settling close" });
    }
    if ((await vault.state()) === 2n) {
      let ethBal = await ethers.provider.getBalance(vaultAddr);
      if (ethBal < execFee) {
        await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
      }
      await (await vault.closePosition(0n, { value: execFee })).wait();
      await waitClosedEmpty(vault, { label: "reset close" });
    }
    if ((await vault.state()) === 0n) {
      const col: bigint = await vault.collateral();
      if (col > 0n) await (await vault.withdraw(col)).wait();
    }
  }

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    alt = signers[1] ?? signers[0];
    ownerAddr = await owner.getAddress();

    const candidates = [
      ...(process.env.DEPLOY_PROFILE
        ? [path.join(process.cwd(), "deployments", `${process.env.DEPLOY_PROFILE}.json`)]
        : []),
      path.join(process.cwd(), "deployments", `${network.name}-gmx.json`),
    ];
    let deployment: {
      vaultFactory: string;
      ryexRouter: string;
      vaultLens: string;
      usdc: string;
      markets: Record<string, { marketId: string }>;
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
      throw new Error("deployment JSON not found");
    }

    marketId = deployment.markets[MARKET].marketId;
    factory = await ethers.getContractAt("VaultFactory", deployment.vaultFactory, owner);
    router = await ethers.getContractAt("RyexRouter", deployment.ryexRouter, owner);
    lens = await ethers.getContractAt("VaultLens", deployment.vaultLens, owner);
    usdc = new ethers.Contract(deployment.usdc, ERC20Abi, owner);

    const allowance: bigint = await usdc.allowance(ownerAddr, deployment.ryexRouter);
    if (allowance !== ethers.MaxUint256) {
      await (await usdc.approve(deployment.ryexRouter, ethers.MaxUint256)).wait();
    }

    const infra = await factory.gmxInfra();
    execFee = infra.execFee;
  });

  beforeEach(async function () {
    await resetVault();
  });

  it("deposit full then open partial — GMX size ≈ partial only; idle remains", async function () {
    await (await router.deposit(marketId, IS_LONG, DEPOSIT_FULL)).wait();
    vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
    vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);

    expect(await vault.collateral()).to.equal(DEPOSIT_FULL);

    const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
    const expectedDelta = OPEN_PARTIAL * 10n ** 24n * BigInt(LEVERAGE);

    await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, OPEN_PARTIAL, { value: execFee })).wait();
    await waitOpenActive(vault, { label: "partial open" });

    const sizeDelta = (await lens.gmxPosition(vaultAddr)).sizeInUsd - sizeBefore;
    expect(sizeDelta).to.be.gte((expectedDelta * 90n) / 100n);
    expect(sizeDelta).to.be.lte((expectedDelta * 110n) / 100n);

    const idle: bigint = await usdc.balanceOf(vaultAddr);
    expect(idle).to.be.gte(DEPOSIT_FULL - OPEN_PARTIAL - 1n); // dust ok
  });

  it("open without prior deposit — router pulls full shortfall", async function () {
    const sizeBefore = 0n;
    await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, OPEN_PARTIAL, { value: execFee })).wait();
    vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
    vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    await waitOpenActive(vault, { label: "shortfall open" });

    const expectedDelta = OPEN_PARTIAL * 10n ** 24n * BigInt(LEVERAGE);
    const sizeDelta = (await lens.gmxPosition(vaultAddr)).sizeInUsd - sizeBefore;
    expect(sizeDelta).to.be.gte((expectedDelta * 90n) / 100n);
  });

  it("Active increase with explicit amount (not full idle)", async function () {
    await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, OPEN_PARTIAL, { value: execFee })).wait();
    vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
    vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    await waitOpenActive(vault, { label: "base open" });

    const size1 = (await lens.gmxPosition(vaultAddr)).sizeInUsd;

    // idle에 여유를 더 넣고, increase는 INCREASE_AMT만
    await (await router.deposit(marketId, IS_LONG, INCREASE_AMT + 2n * 10n ** 6n)).wait();
    await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, INCREASE_AMT, { value: execFee })).wait();
    await waitOpenActive(vault, { label: "partial increase" });

    const size2 = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
    const expectedInc = INCREASE_AMT * 10n ** 24n * BigInt(LEVERAGE);
    const inc = size2 - size1;
    expect(inc).to.be.gte((expectedInc * 90n) / 100n);
    expect(inc).to.be.lte((expectedInc * 110n) / 100n);

    const idle: bigint = await usdc.balanceOf(vaultAddr);
    expect(idle).to.be.gte(2n * 10n ** 6n - 1n);
  });

  it("limit open settles via GMX callback only", async function () {
    const [, oracleAddr] = await factory.markets(marketId);
    const price8: bigint = await (
      await ethers.getContractAt(["function getPrice() view returns (uint256)"], oracleAddr, owner)
    ).getPrice();
    // 숏: 트리거를 마크보다 조금 높게 — 미체결이면 cancel 후 skip
    const trigger = (price8 * 1005n) / 1000n;

    await (await router.openPosition(marketId, IS_LONG, LEVERAGE, trigger, OPEN_PARTIAL, { value: execFee })).wait();
    vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
    vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);

    expect(await vault.state()).to.equal(1n); // SettlingOpen

    try {
      await waitOpenActive(vault, {
        timeoutMs: DEFAULT_SETTLE_TIMEOUT_MS,
        label: "limit open callback",
      });
    } catch (e) {
      if ((await vault.state()) === 1n) {
        await (await vault.cancelLimitOrder()).wait();
        await waitStateIn(vault, [0n, 2n], { label: "limit cancel" });
        this.skip();
      }
      throw e;
    }
    expect(await vault.state()).to.equal(2n);
  });

  it("settleGmxOrder reverts for non-owner", async function () {
    await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, OPEN_PARTIAL, { value: execFee })).wait();
    vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
    vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    await waitOpenActive(vault, { label: "auth setup open" });

    // Active에서 더미 키로 호출해도 권한 먼저 검사되어야 함
    const vaultAsAlt = vault.connect(alt) as Contract;
    const fakeKey = ethers.keccak256(ethers.toUtf8Bytes("not-a-real-gmx-key"));
    await expect(vaultAsAlt.settleGmxOrder(fakeKey)).to.be.reverted;
  });
});
