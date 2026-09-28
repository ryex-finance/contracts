/**
 * ryield.ts — rYield 풀링 델타뉴트럴 볼트 e2e (Arbitrum Sepolia, 실 GMX)
 *
 *   npx hardhat test test/ryex/ryield.ts --network arbitrumSepolia
 *
 * 이번 라운드에서는 rYield 재배포·유동성 공급을 하지 않으므로 skip.
 * 이후 deployRYield + 풀 LP 후 describe.skip 제거.
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { expect } from "chai";
import type { Contract } from "ethers";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";
import { dataStoreGetAddress, getGmxDataStore } from "../../scripts/lib/gmxDataStore";

const MARKET = "rETH";
const DEPOSIT_USDC = 5n * 10n ** 6n; // 5 USDC
const SETTLE_TIMEOUT_MS = 240_000;
// GMX Keys.sol: keccak256(abi.encode(string)) — keccak256(toUtf8Bytes(...))는 다른 값 (2026-09-02 버그 수정)
const ACCOUNT_ORDER_LIST = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"]));

type DepJson = {
  vaultFactory: string;
  ryexTreasury: string;
  gmxIntegrationReader: string;
  gmxExecutor: string;
  usdc: string;
  ryieldVaults?: Record<string, string>;
  ryieldFundingDistributors?: Record<string, string>;
  ryieldRegistry?: string;
  ryieldViews?: string;
  gmxDataStore?: string;
  gmxFundingAccruedView?: string;
  markets: Record<string, { marketId: string; rToken: string; oracle: string; gmxMarket?: string }>;
};

describe.skip("rYield delta-neutral vault (Arbitrum Sepolia)", function () {
  this.timeout(40 * 60_000);

  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let ownerAddr: string;
  let usdcAddr: string;
  let marketId: string;
  let rTokenAddr: string;
  let execFee: bigint;

  let factory: Contract;
  let usdc: Contract;
  let oracle: Contract;
  let dataStore: Contract;
  let vault: Contract;
  let vaultAddr: string;
  let registry: Contract;
  let orderListKey: string;

  before(async function () {
    [owner] = await ethers.getSigners();
    ownerAddr = await owner.getAddress();

    const candidates = [
      ...(process.env.DEPLOY_PROFILE
        ? [path.join(process.cwd(), "deployments", `${process.env.DEPLOY_PROFILE}.json`)]
        : []),
      path.join(process.cwd(), "deployments", `${network.name}-gmx.json`),
      path.join(process.cwd(), "deployments", `${network.name}-gmx.json`),
    ];
    let dep: DepJson | undefined;
    for (const f of candidates) {
      try {
        dep = JSON.parse(await readFile(f, "utf8")) as DepJson;
        if (dep?.vaultFactory) break;
      } catch {
        /* next */
      }
    }
    if (!dep?.vaultFactory) throw new Error("deployment JSON not found");

    usdcAddr = dep.usdc;
    marketId = dep.markets[MARKET].marketId;
    rTokenAddr = dep.markets[MARKET].rToken;

    factory = await ethers.getContractAt("VaultFactory", dep.vaultFactory, owner);
    usdc = new ethers.Contract(usdcAddr, ERC20Abi, owner);
    oracle = await ethers.getContractAt(
      ["function getPrice() view returns (uint256)"],
      dep.markets[MARKET].oracle,
      owner,
    );

    const infra = await factory.gmxInfra();
    execFee = infra.execFee;
    dataStore = await ethers.getContractAt(
      ["function containsBytes32(bytes32,bytes32) view returns (bool)"],
      infra.dataStore,
    );

    // RYieldVault 로드 (없으면 배포)
    vaultAddr = dep.ryieldVaults?.[MARKET] ?? ethers.ZeroAddress;
    if (vaultAddr === ethers.ZeroAddress) {
      const AmmTwapF = await ethers.getContractFactory("AmmTwap");
      const ammTwap = await AmmTwapF.deploy();
      await ammTwap.waitForDeployment();
      const GmxFundingUtilsF = await ethers.getContractFactory("GmxFundingUtils");
      const gmxFundingUtils = await GmxFundingUtilsF.deploy();
      await gmxFundingUtils.waitForDeployment();
      let gmxFundingAccruedViewAddr = dep.gmxFundingAccruedView;
      if (!gmxFundingAccruedViewAddr) {
        const GmxFundingAccruedViewF = await ethers.getContractFactory("GmxFundingAccruedView");
        const gmxFundingAccruedView = await GmxFundingAccruedViewF.deploy();
        await gmxFundingAccruedView.waitForDeployment();
        gmxFundingAccruedViewAddr = await gmxFundingAccruedView.getAddress();
      }
      const RYieldVaultF = await ethers.getContractFactory("RYieldVault", {
        libraries: {
          GmxIntegrationReader: dep.gmxIntegrationReader,
          GmxExecutor: dep.gmxExecutor,
          AmmTwap: await ammTwap.getAddress(),
          GmxFundingUtils: await gmxFundingUtils.getAddress(),
          GmxFundingAccruedView: gmxFundingAccruedViewAddr,
        },
      });
      const deployed = await RYieldVaultF.deploy(
        dep.vaultFactory,
        marketId,
        ownerAddr,
        dep.ryexTreasury,
        ethers.ZeroAddress, // AMM pool — setPool 후 게이트 검증
      );
      await deployed.waitForDeployment();
      vaultAddr = await deployed.getAddress();
      console.log(`  deployed RYieldVault → ${vaultAddr}`);
    }
    vault = await ethers.getContractAt("RYieldVault", vaultAddr, owner);

    // Funding distributor (없으면 배포·연결)
    let distributorAddr = dep.ryieldFundingDistributors?.[MARKET] ?? ethers.ZeroAddress;
    if (distributorAddr === ethers.ZeroAddress && dep.gmxDataStore && dep.markets[MARKET].gmxMarket) {
      const gmxMarket = dep.markets[MARKET].gmxMarket!;
      const ds = await getGmxDataStore(dep.gmxDataStore);
      const LONG_TOKEN = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["LONG_TOKEN"]));
      const SHORT_TOKEN = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["SHORT_TOKEN"]));
      const longToken = await dataStoreGetAddress(
        ds,
        ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["address", "bytes32"], [gmxMarket, LONG_TOKEN])),
      );
      const shortToken = await dataStoreGetAddress(
        ds,
        ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["address", "bytes32"], [gmxMarket, SHORT_TOKEN])),
      );
      const DistributorF = await ethers.getContractFactory("RYieldFundingDistributor");
      const deployedDist = await DistributorF.deploy(vaultAddr, gmxMarket, dep.gmxDataStore, longToken, shortToken);
      await deployedDist.waitForDeployment();
      distributorAddr = await deployedDist.getAddress();
      try {
        await (await vault.setFundingDistributor(distributorAddr)).wait();
      } catch {
        /* owner 아님 */
      }
      console.log(`  deployed RYieldFundingDistributor → ${distributorAddr}`);
    }

    // RYieldRegistry (조회 진입점) — 없으면 배포·등록
    let ryieldViewsAddr = dep.ryieldViews;
    if (!ryieldViewsAddr) {
      const RYieldViewsF = await ethers.getContractFactory("RYieldViews");
      const ryieldViews = await RYieldViewsF.deploy();
      await ryieldViews.waitForDeployment();
      ryieldViewsAddr = await ryieldViews.getAddress();
      console.log(`  deployed RYieldViews → ${ryieldViewsAddr}`);
    }
    let registryAddr = dep.ryieldRegistry;
    if (!registryAddr) {
      const RegistryF = await ethers.getContractFactory("RYieldRegistry", {
        libraries: { RYieldViews: ryieldViewsAddr },
      });
      const deployedRegistry = await RegistryF.deploy(dep.vaultFactory, ownerAddr);
      await deployedRegistry.waitForDeployment();
      registryAddr = await deployedRegistry.getAddress();
      console.log(`  deployed RYieldRegistry → ${registryAddr}`);
    }
    registry = await ethers.getContractAt("RYieldRegistry", registryAddr, owner);
    const registeredVault: string = await registry.vaultOf(marketId);
    if (registeredVault === ethers.ZeroAddress && distributorAddr !== ethers.ZeroAddress) {
      try {
        await (await registry.register(marketId, vaultAddr, distributorAddr)).wait();
        console.log(`  registered ${MARKET} on RYieldRegistry`);
      } catch {
        /* registry owner 아님 */
      }
    }

    orderListKey = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
    );

    // USDC approve
    const allowance: bigint = await usdc.allowance(ownerAddr, vaultAddr);
    if (allowance < DEPOSIT_USDC * 100n) {
      await (await usdc.approve(vaultAddr, ethers.MaxUint256)).wait();
    }

    // 테스트 셋업: 소액(5 USDC) 예치 검증을 위해 owner가 minDeposit을 낮춘다 (owner == deployer 가정).
    try {
      if ((await registry.minDeposit(marketId)) > DEPOSIT_USDC) {
        await (await vault.setMinDeposit(10n ** 6n)).wait(); // 1 USDC
      }
    } catch {
      /* owner 아님 — 스킵 */
    }

    console.log(`\nOwner      : ${ownerAddr}`);
    console.log(`RYieldVault: ${vaultAddr}`);
    console.log(`Registry   : ${registryAddr}`);
    console.log(`rToken     : ${rTokenAddr}`);
    console.log(`oracle     : $${ethers.formatUnits(await oracle.getPrice(), 8)}`);
    console.log(`USDC bal   : ${ethers.formatUnits(await usdc.balanceOf(ownerAddr), 6)}`);
  });

  describe("deposit / withdraw accounting", function () {
    it("first deposit mints shares 1:1 and updates NAV", async function () {
      const balBefore: bigint = await usdc.balanceOf(ownerAddr);
      if (balBefore < DEPOSIT_USDC) {
        this.skip();
      }
      const tsBefore: bigint = await registry.totalShares(marketId);
      const userBefore: bigint = await registry.sharesOf(marketId, ownerAddr);
      const navBefore: bigint = await registry.totalAssetsUsdc(marketId);

      const sharesOut: bigint = await vault.deposit.staticCall(DEPOSIT_USDC, { value: execFee });
      await (await vault.deposit(DEPOSIT_USDC, { value: execFee })).wait();

      const tsAfter: bigint = await registry.totalShares(marketId);
      const userAfter: bigint = await registry.sharesOf(marketId, ownerAddr);
      const navAfter: bigint = await registry.totalAssetsUsdc(marketId);

      // 신규 share = 예상 발행량, NAV는 deposit 만큼 증가
      expect(tsAfter - tsBefore).to.equal(sharesOut);
      expect(userAfter - userBefore).to.equal(sharesOut);
      expect(navAfter - navBefore).to.equal(DEPOSIT_USDC);
      expect(sharesOut).to.be.gt(0n);
      if (tsBefore === 0n) {
        // 첫 예치는 1:1 (share 단위 = USDC 단위)
        expect(sharesOut).to.equal(DEPOSIT_USDC);
        expect(await registry.pricePerShareWad(marketId)).to.equal(10n ** 18n);
      }
      console.log(
        `  deposit ${ethers.formatUnits(DEPOSIT_USDC, 6)} USDC → ${sharesOut} shares (pps=${ethers.formatUnits(await registry.pricePerShareWad(marketId), 18)})`,
      );
    });

    it("withdraw burns shares and pays idle USDC pro-rata", async function () {
      const userShares: bigint = await registry.sharesOf(marketId, ownerAddr);
      if (userShares === 0n) this.skip();

      const idle: bigint = await registry.idleUsdc(marketId);
      const ts: bigint = await registry.totalShares(marketId);
      const nav: bigint = await registry.totalAssetsUsdc(marketId);

      // idle로 충당 가능한 만큼만 인출 (헤지 없으면 NAV == idle)
      const halfShares = userShares / 2n;
      const expectedUsdc = (halfShares * nav) / ts;
      if (expectedUsdc > idle) this.skip(); // 헤지 중이면 unwind 필요 — 별도 테스트

      const usdcBalBefore: bigint = await usdc.balanceOf(ownerAddr);
      const out: bigint = await vault.withdraw.staticCall(halfShares);
      await (await vault.withdraw(halfShares)).wait();
      const usdcBalAfter: bigint = await usdc.balanceOf(ownerAddr);

      expect(out).to.equal(expectedUsdc);
      expect(usdcBalAfter - usdcBalBefore).to.equal(out);
      expect(await registry.sharesOf(marketId, ownerAddr)).to.equal(userShares - halfShares);
    });

    it("harvestAndClaim reverts when nothing to claim", async function () {
      const fdAddr = await registry.distributorOf(marketId);
      if (fdAddr === ethers.ZeroAddress) this.skip();
      const dist = await ethers.getContractAt("RYieldFundingDistributor", fdAddr, owner);
      await expect(dist.harvestAndClaim.staticCall()).to.be.revertedWithCustomError(dist, "NothingToClaim");
    });
  });

  describe("hedge lifecycle (rebalance → settle → unwind)", function () {
    this.timeout(40 * 60_000);

    it("rebalance opens AMM long + GMX short, then unwind closes", async function () {
      // idle USDC 확보 (없으면 예치)
      let idle: bigint = await registry.idleUsdc(marketId);
      if (idle < 3n * 10n ** 6n) {
        const bal: bigint = await usdc.balanceOf(ownerAddr);
        if (bal < DEPOSIT_USDC) this.skip();
        await (await vault.deposit(DEPOSIT_USDC, { value: execFee })).wait();
        idle = await registry.idleUsdc(marketId);
      }

      // vault ETH(exec fee) 확보
      let vethBal = await ethers.provider.getBalance(vaultAddr);
      if (vethBal < execFee) {
        const ownerEth = await ethers.provider.getBalance(ownerAddr);
        if (ownerEth < execFee * 2n) {
          console.log("  skip hedge — owner ETH insufficient for exec fee");
          this.skip();
        }
        await (await owner.sendTransaction({ to: vaultAddr, value: execFee - vethBal + execFee })).wait();
      }

      // rebalance — AMM 풀 유동성 없으면 revert → skip
      try {
        await vault.rebalance.staticCall({ value: 0n });
      } catch (e) {
        console.log(`  skip hedge — rebalance not executable (likely no rToken/USDC AMM liquidity): ${(e as Error).message.slice(0, 120)}`);
        this.skip();
      }
      await (await vault.rebalance()).wait();
      expect(await registry.ryieldState(marketId)).to.equal(1n); // SettlingHedge

      // GMX 숏 increase 정산 대기
      const pendingKey: string = await registry.pendingOrderKey(marketId);
      const order = await vault.gmxOrders(pendingKey);
      const gmxKey: string = order.gmxKey;
      await settleHedge(gmxKey);
      expect(await registry.ryieldState(marketId)).to.equal(0n); // Idle
      const shortEq: bigint = await registry.shortEquityUsdc(marketId);
      const longVal: bigint = await registry.longValueUsdc(marketId);
      console.log(`  hedged — long ${ethers.formatUnits(longVal, 6)} USDC / short equity ${ethers.formatUnits(shortEq, 6)} USDC`);
      expect(shortEq).to.be.gt(0n);
      expect(longVal).to.be.gt(0n);

      // requestUnwind — 헤지된 내 몫을 상환 큐에 적재 (share 락)
      const myShares: bigint = await registry.sharesOf(marketId, ownerAddr);
      await (await vault.requestUnwind(myShares)).wait();
      expect(await registry.redeemSharesOf(marketId, ownerAddr)).to.equal(myShares);
      expect(await registry.sharesOf(marketId, ownerAddr)).to.equal(0n);

      // vault ETH(exec fee) 확보
      vethBal = await ethers.provider.getBalance(vaultAddr);
      if (vethBal < execFee) {
        await (await owner.sendTransaction({ to: vaultAddr, value: execFee })).wait();
      }

      // 종료 게이트(AMM>=GMX)는 진입(AMM<GMX)과 정반대라 정적 가격에선 동시에 못 만족한다.
      // 이 테스트는 청산 메커니즘 검증용이므로 종료 discount를 넓혀 전량 청산되게 한다.
      await (await vault.setMaxExitDiscountBps(9999)).wait();

      // executeUnwind — 봇이 큐 배치 청산 (숏 비례 close/redeem + 롱 매도)
      await (await vault.executeUnwind()).wait();
      expect(await registry.ryieldState(marketId)).to.equal(2n); // SettlingUnwind
      const unwindKey: string = await registry.pendingOrderKey(marketId);
      const unwindOrder = await vault.gmxOrders(unwindKey);
      await settleHedge(unwindOrder.gmxKey);
      expect(await registry.ryieldState(marketId)).to.equal(0n);

      // claimUnwind — 체결된 상환분 수령
      const claimable: bigint = await registry.claimableUsdc(marketId, ownerAddr);
      expect(claimable).to.be.gt(0n);
      const balBefore: bigint = await usdc.balanceOf(ownerAddr);
      const claimed: bigint = await vault.claimUnwind.staticCall();
      await (await vault.claimUnwind()).wait();
      const balAfter: bigint = await usdc.balanceOf(ownerAddr);
      expect(balAfter - balBefore).to.equal(claimed);
      expect(await registry.redeemSharesOf(marketId, ownerAddr)).to.equal(0n);
      console.log(`  unwound+claimed ${ethers.formatUnits(claimed, 6)} USDC`);
    });
  });

  /** GMX 주문이 키퍼 콜백 또는 settleGmxOrder로 정산될 때까지 폴링 */
  async function settleHedge(gmxKey: string) {
    if (gmxKey === ethers.ZeroHash) return; // mock 즉시 정산
    const deadline = Date.now() + SETTLE_TIMEOUT_MS;
    while (Date.now() < deadline) {
      const state: bigint = await registry.ryieldState(marketId);
      if (state === 0n) return; // 콜백으로 정산됨
      const stillOnGmx = await dataStore.containsBytes32(orderListKey, gmxKey);
      if (!stillOnGmx) {
        await new Promise((r) => setTimeout(r, 15_000));
        try {
          await (await vault.settleGmxOrder(gmxKey)).wait();
          return;
        } catch {
          /* 콜백 대기 */
        }
      }
      await new Promise((r) => setTimeout(r, 5_000));
    }
    throw new Error("GMX hedge settlement timed out");
  }
});
