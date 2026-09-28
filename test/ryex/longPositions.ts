/**
 * longPositions.ts — 롱 포지션 open/close 통합 테스트 (Arbitrum Sepolia)
 *
 *   npx hardhat test test/ryex/longPositions.ts --network arbitrumSepolia
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { expect } from "chai";
import type { Contract } from "ethers";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";
import { waitOpenActive } from "./helpers/waitGmx";

const MARKET = "rETH";
const IS_LONG = true;
const LEVERAGE = 2;
const DEPOSIT_USDC = 5n * 10n ** 6n;
const SETTLE_TIMEOUT_MS = 180_000;
const LIMIT_CLOSE_TRY_MS = 15_000;
const LIMIT_CLOSE_MAX_ATTEMPTS = 10;
// GMX Keys.sol: keccak256(abi.encode(string)) — keccak256(toUtf8Bytes(...))는 다른 값 (2026-09-02 버그 수정)
const ACCOUNT_ORDER_LIST = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"]));

describe("long positions (Arbitrum Sepolia)", function () {
  this.timeout(40 * 60_000);

  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let ownerAddr: string;
  let vaultFactory: string;
  let ryexRouter: string;
  let vaultLensAddr: string;
  let usdcAddr: string;
  let marketId: string;
  let execFee: bigint;
  let dataStore: Contract;

  let factory: Contract;
  let router: Contract;
  let lens: Contract;
  let usdc: Contract;
  let oracle: Contract;
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
      throw new Error("deployment JSON not found (ryexRouter / vaultLens)");
    }

    vaultFactory = deployment.vaultFactory;
    ryexRouter = deployment.ryexRouter;
    vaultLensAddr = deployment.vaultLens;
    usdcAddr = deployment.usdc;
    marketId = deployment.markets[MARKET].marketId;

    factory = await ethers.getContractAt("VaultFactory", vaultFactory, owner);
    router = await ethers.getContractAt("RyexRouter", ryexRouter, owner);
    lens = await ethers.getContractAt("VaultLens", vaultLensAddr, owner);
    usdc = new ethers.Contract(usdcAddr, ERC20Abi, owner);

    /** USDC allowance 확인 → max 아니면 approve **/
    const allowance: bigint = await usdc.allowance(ownerAddr, ryexRouter);
    if (allowance !== ethers.MaxUint256) {
      await (await usdc.approve(ryexRouter, ethers.MaxUint256)).wait();
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
    console.log(`Router : ${ryexRouter}`);
  });

  describe("open long positions", function () {
    this.timeout(15 * 60_000);

    beforeEach(async function () {
      /** 기존 볼트 조회 **/
      vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
      if (vaultAddr !== ethers.ZeroAddress) {
        vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
        orderListKey = ethers.keccak256(
          ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
        );

        /** SettlingOpen — 미체결 limit open 취소 **/
        if ((await vault.state()) === 1n) {
          await (await vault.cancelLimitOrder()).wait();
          const deadline = Date.now() + SETTLE_TIMEOUT_MS;
          while (Date.now() < deadline) {
            const state: bigint = await vault.state();
            if (state === 0n || state === 2n) break;
            if (state === 1n) {
              const pending = await vault.pending();
              if (pending.orderKey !== ethers.ZeroHash) {
                const order = await vault.gmxOrders(pending.orderKey);
              }
            }
            await new Promise((r) => setTimeout(r, 5_000));
          }
        }

        /** SettlingLiquidate — close 정산 대기 **/
        if ((await vault.state()) === 3n) {
          const deadline = Date.now() + SETTLE_TIMEOUT_MS;
          while (Date.now() < deadline) {
            const state: bigint = await vault.state();
            if (state === 0n || state === 2n) break;
            if (state === 3n) {
              const pending = await vault.pending();
              if (pending.orderKey !== ethers.ZeroHash) {
                const order = await vault.gmxOrders(pending.orderKey);
              }
            }
            await new Promise((r) => setTimeout(r, 5_000));
          }
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
      }

      /** USDC 예치 **/
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
    });

    afterEach(async function () {
      /** 포지션 있으면 시장가 청산 **/
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

    it("2× market open", async function () {
      const expectedDelta = DEPOSIT_USDC * 10n ** 24n * BigInt(LEVERAGE);
      const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      const minSize = sizeBefore + (expectedDelta * 95n) / 100n;

      /** 시장가 포지션 오픈 **/
      await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, DEPOSIT_USDC, { value: execFee })).wait();

      /** GMX 오픈 정산 대기 **/
      const openDeadline = Date.now() + SETTLE_TIMEOUT_MS;
      while (Date.now() < openDeadline) {
        const state: bigint = await vault.state();
        const sizeNow = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
        if (state === 2n && sizeNow >= minSize) break;
        if (state === 0n) throw new Error("GMX market open cancelled");
        if (state === 1n) {
          const pending = await vault.pending();
          if (pending.orderKey !== ethers.ZeroHash) {
            const order = await vault.gmxOrders(pending.orderKey);
          }
        }
        await new Promise((r) => setTimeout(r, 5_000));
      }

      /** 오픈 결과 확인 **/
      expect(await vault.state()).to.equal(2n);
      expect(await vault.leverage()).to.equal(LEVERAGE);
      const sizeDelta = (await lens.gmxPosition(vaultAddr)).sizeInUsd - sizeBefore;
      console.log(
        `  market open — +${ethers.formatUnits(sizeDelta, 30)} USD (expected ~${ethers.formatUnits(expectedDelta, 30)})`,
      );
      expect(sizeDelta).to.be.gte((expectedDelta * 95n) / 100n);
    });

    it("Active increase — 2× market open (deposit·open 반복)", async function () {
      /** 1차 시장가 오픈 — beforeEach deposit **/
      const expectedDelta1 = DEPOSIT_USDC * 10n ** 24n * BigInt(LEVERAGE);
      const size0 = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      const minSize1 = size0 + (expectedDelta1 * 95n) / 100n;

      await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, DEPOSIT_USDC, { value: execFee })).wait();
      await waitOpenActive(vault, { timeoutMs: SETTLE_TIMEOUT_MS, label: "1st market open" });
      expect(await vault.state()).to.equal(2n);
      const sizeAfter1 = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      expect(sizeAfter1).to.be.gte(minSize1);

      /** 2차 deposit — Active 증액용 USDC **/
      await (await router.deposit(marketId, IS_LONG, DEPOSIT_USDC)).wait();

      let ethBal = await ethers.provider.getBalance(vaultAddr);
      if (ethBal < execFee) {
        await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
      }

      /** 2차 시장가 increase — vault idle USDC → GMX Increase **/
      const expectedDelta2 = DEPOSIT_USDC * 10n ** 24n * BigInt(LEVERAGE);

      await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, DEPOSIT_USDC, { value: execFee })).wait();
      await waitOpenActive(vault, { timeoutMs: SETTLE_TIMEOUT_MS, label: "2nd market increase" });

      const sizeAfter2 = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      const increaseDelta = sizeAfter2 - sizeAfter1;
      console.log(
        `  Active increase — 1st +${ethers.formatUnits(sizeAfter1 - size0, 30)} USD, 2nd +${ethers.formatUnits(increaseDelta, 30)} USD (expected ~${ethers.formatUnits(expectedDelta2, 30)})`,
      );
      expect(increaseDelta).to.be.gte((expectedDelta2 * 95n) / 100n);
      expect(await vault.state()).to.equal(2n);
    });
  });

  describe("close long positions", function () {
    this.timeout(15 * 60_000);

    beforeEach(async function () {
      /** 기존 볼트 조회 · 정리 **/
      vaultAddr = await factory.vaultOf(ownerAddr, marketId, IS_LONG);
      if (vaultAddr !== ethers.ZeroAddress) {
        vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
        orderListKey = ethers.keccak256(
          ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
        );

        if ((await vault.state()) === 1n) {
          await (await vault.cancelLimitOrder()).wait();
        }

        if ((await vault.state()) === 3n) {
          const deadline = Date.now() + SETTLE_TIMEOUT_MS;
          while (Date.now() < deadline) {
            const state: bigint = await vault.state();
            if (state === 0n || state === 2n) break;
            if (state === 3n) {
              const pending = await vault.pending();
              if (pending.orderKey !== ethers.ZeroHash) {
                const order = await vault.gmxOrders(pending.orderKey);
              }
            }
            await new Promise((r) => setTimeout(r, 5_000));
          }
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

        if ((await vault.state()) === 0n) {
          const idle = await usdc.balanceOf(vaultAddr);
          if (idle > 0n) {
            await (await vault.withdraw(idle)).wait();
          }
        }
      }

      const expectedDelta = DEPOSIT_USDC * 10n ** 24n * BigInt(LEVERAGE);
      const minExisting = (expectedDelta * 95n) / 100n;

      /** USDC 예치 + 가스비 + 시장가 오픈 (close 테스트용 Active 상태) **/
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

      const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      const minSize = sizeBefore + minExisting;

      await (await router.openPosition(marketId, IS_LONG, LEVERAGE, 0n, DEPOSIT_USDC, { value: execFee })).wait();

      const openDeadline = Date.now() + SETTLE_TIMEOUT_MS;
      while (Date.now() < openDeadline) {
        const state: bigint = await vault.state();
        const sizeAfter = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
        if (state === 2n && sizeAfter >= minSize) break;
        if (state === 1n) {
          const pending = await vault.pending();
          if (pending.orderKey !== ethers.ZeroHash) {
            const order = await vault.gmxOrders(pending.orderKey);
          }
        }
        await new Promise((r) => setTimeout(r, 5_000));
      }
      if ((await vault.state()) !== 2n) {
        throw new Error("close beforeEach: market open timed out");
      }
    });

    afterEach(async function () {
      /** 포지션 있으면 시장가 청산 **/
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

    it("market close", async function () {
      expect(await vault.state()).to.equal(2n);
      const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      expect(sizeBefore).to.be.gt(0n);

      /** 시장가 포지션 청산 **/
      await (await vault.closePosition(0n, { value: execFee })).wait();

      /** GMX market close 정산 대기 **/
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
      if ((await vault.state()) !== 0n) {
        throw new Error("GMX market close timed out");
      }

      console.log(`  market close — vault Empty`);
      expect((await lens.gmxPosition(vaultAddr)).sizeInUsd).to.be.lt(sizeBefore);
    });

    it("2× limit close", async function () {
      this.timeout(30 * 60_000);

      expect(await vault.state()).to.equal(2n);
      const sizeBefore = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
      expect(sizeBefore).to.be.gt(0n);

      let closed = false;
      let lastMark = 0n;
      let lastTrigger = 0n;

      for (let attempt = 1; attempt <= LIMIT_CLOSE_MAX_ATTEMPTS; attempt++) {
        /** 롱 limit close trigger — mark 위 0.01% (10001/10000, GMX: index ≥ trigger 시 체결) **/
        const mark: bigint = await oracle.getPrice();
        const triggerPrice8 = (mark * 10001n) / 10_000n;
        lastMark = mark;
        lastTrigger = triggerPrice8;
        console.log(
          `  limit close attempt ${attempt}/${LIMIT_CLOSE_MAX_ATTEMPTS} — mark ${ethers.formatUnits(mark, 8)} trigger ${ethers.formatUnits(triggerPrice8, 8)} (+0.01%)`,
        );

        /** 가스비 전송 **/
        let ethBal = await ethers.provider.getBalance(vaultAddr);
        if (ethBal < execFee) {
          await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
        }

        /** 지정가 포지션 청산 **/
        await (await vault.closePosition(triggerPrice8, { value: execFee })).wait();

        /** 15초간 keeper 콜백 대기 **/
        const tryDeadline = Date.now() + LIMIT_CLOSE_TRY_MS;
        while (Date.now() < tryDeadline) {
          const state: bigint = await vault.state();
          const sizeNow = (await lens.gmxPosition(vaultAddr)).sizeInUsd;
          if (state === 0n && sizeNow < sizeBefore) {
            closed = true;
            break;
          }
          if (state === 2n) break;
          await new Promise((r) => setTimeout(r, 5_000));
        }
        if (closed) break;

        /** 미체결 — limit 취소 후 가격 갱신하여 재시도 **/
        if ((await vault.state()) === 3n) {
          await (await vault.cancelLimitOrder()).wait();
          const cancelDeadline = Date.now() + SETTLE_TIMEOUT_MS;
          while (Date.now() < cancelDeadline) {
            const state: bigint = await vault.state();
            if (state === 2n) break;
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

      if (!closed) {
        throw new Error(`GMX limit close failed after ${LIMIT_CLOSE_MAX_ATTEMPTS} attempts`);
      }

      console.log(
        `  limit close — mark ${ethers.formatUnits(lastMark, 8)} trigger ${ethers.formatUnits(lastTrigger, 8)} — vault Empty`,
      );
      expect((await lens.gmxPosition(vaultAddr)).sizeInUsd).to.be.lt(sizeBefore);
    });
  });
});
