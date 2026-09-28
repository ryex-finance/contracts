/**
 * vault.ts — 볼트 재사용 (동일 clone 주소 유지) 테스트 (Arbitrum Sepolia)
 *
 *   npx hardhat test test/ryex/vault.ts --network arbitrumSepolia
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { expect } from "chai";
import type { Contract } from "ethers";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";

const MARKET = "rETH";
const DEPOSIT_USDC = 5n * 10n ** 6n;

describe("vault reuse (Arbitrum Sepolia)", function () {
  this.timeout(10 * 60_000);

  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let alt: Awaited<ReturnType<typeof ethers.getSigners>>[1];
  let ownerAddr: string;
  let altAddr: string;
  let ryexRouter: string;
  let marketId: string;

  let factory: Contract;
  let router: Contract;
  let usdc: Contract;

  before(async function () {
    /** 테스트 계정 **/
    [owner, alt] = await ethers.getSigners();
    ownerAddr = await owner.getAddress();
    altAddr = await alt.getAddress();

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
      usdc: string;
      markets: Record<string, { marketId: string }>;
    } | undefined;
    for (const f of candidates) {
      try {
        deployment = JSON.parse(await readFile(f, "utf8"));
        if (deployment?.ryexRouter) break;
      } catch {
        /* next */
      }
    }
    if (!deployment?.ryexRouter) {
      throw new Error("deployment JSON not found (ryexRouter)");
    }

    ryexRouter = deployment.ryexRouter;
    marketId = deployment.markets[MARKET].marketId;

    factory = await ethers.getContractAt("VaultFactory", deployment.vaultFactory, owner);
    router = await ethers.getContractAt("RyexRouter", ryexRouter, owner);
    usdc = new ethers.Contract(deployment.usdc, ERC20Abi, owner);

    /** USDC allowance — owner · alt **/
    for (const signer of [owner, alt]) {
      const addr = await signer.getAddress();
      const token = usdc.connect(signer) as Contract;
      const allowance: bigint = await token.allowance(addr, ryexRouter);
      if (allowance !== ethers.MaxUint256) {
        await (await token.approve(ryexRouter, ethers.MaxUint256)).wait();
      }
    }

    console.log(`\nOwner : ${ownerAddr}`);
    console.log(`Alt   : ${altAddr}`);
    console.log(`Router: ${ryexRouter}`);
  });

  it("두 번 deposit — 동일 숏 볼트 주소·totalVaults 불변", async function () {
    const totalBefore: bigint = await factory.totalVaults();
    const vaultBefore: string = await factory.vaultOf(ownerAddr, marketId, false);

    /** 첫 deposit **/
    await (await router.deposit(marketId, false, DEPOSIT_USDC)).wait();
    const vaultAfterFirst: string = await factory.vaultOf(ownerAddr, marketId, false);
    const totalAfterFirst: bigint = await factory.totalVaults();
    expect(vaultAfterFirst).to.not.equal(ethers.ZeroAddress);
    expect(await factory.isVault(vaultAfterFirst)).to.equal(true);

    if (vaultBefore === ethers.ZeroAddress) {
      expect(totalAfterFirst).to.equal(totalBefore + 1n);
    } else {
      expect(vaultAfterFirst).to.equal(vaultBefore);
      expect(totalAfterFirst).to.equal(totalBefore);
    }

    const vault = await ethers.getContractAt("PositionVault", vaultAfterFirst, owner);
    const collateralAfterFirst: bigint = await vault.collateral();

    /** 두 번째 deposit — clone 재생성 없이 동일 주소 **/
    await (await router.deposit(marketId, false, DEPOSIT_USDC)).wait();
    const vaultAfterSecond: string = await factory.vaultOf(ownerAddr, marketId, false);
    const totalAfterSecond: bigint = await factory.totalVaults();

    expect(vaultAfterSecond).to.equal(vaultAfterFirst);
    expect(totalAfterSecond).to.equal(totalAfterFirst);
    expect(await vault.collateral()).to.equal(collateralAfterFirst + DEPOSIT_USDC);

    console.log(`  reuse — ${vaultAfterSecond} (totalVaults ${totalAfterSecond})`);

    /** 테스트 잔액 회수 — Empty 유지 **/
    const idle = await usdc.balanceOf(vaultAfterSecond);
    if (idle > 0n && (await vault.state()) === 0n) {
      await (await vault.withdraw(idle)).wait();
    }
  });

  it("전액 withdraw 후 redeposit — 동일 볼트 주소·totalVaults 불변", async function () {
    /** alt 유저 — GMX 포지션 없는 깨끗한 볼트 사이클 **/
    const altUsdc = usdc.connect(alt) as Contract;
    const altBal: bigint = await altUsdc.balanceOf(altAddr);
    if (altBal < DEPOSIT_USDC * 2n) {
      const ownerBal: bigint = await usdc.balanceOf(ownerAddr);
      if (ownerBal < DEPOSIT_USDC * 2n) {
        throw new Error("insufficient USDC for alt vault cycle test");
      }
      await (await usdc.transfer(altAddr, DEPOSIT_USDC * 2n)).wait();
    }

    const altRouter = router.connect(alt) as Contract;
    const totalBefore: bigint = await factory.totalVaults();
    const vaultBefore: string = await factory.vaultOf(altAddr, marketId, false);

    /** 첫 deposit — 없으면 생성 **/
    await (await altRouter.deposit(marketId, false, DEPOSIT_USDC)).wait();
    const vaultAddr: string = await factory.vaultOf(altAddr, marketId, false);
    expect(vaultAddr).to.not.equal(ethers.ZeroAddress);

    const vault = await ethers.getContractAt("PositionVault", vaultAddr, alt);
    expect(await vault.owner()).to.equal(altAddr);
    expect(await vault.state()).to.equal(0n);

    /** 전액 withdraw — Empty **/
    const bal: bigint = await usdc.balanceOf(vaultAddr);
    await (await vault.withdraw(bal)).wait();
    expect(await vault.state()).to.equal(0n);
    expect(await vault.collateral()).to.equal(0n);

    const totalAfterWithdraw: bigint = await factory.totalVaults();
    expect(totalAfterWithdraw).to.equal(
      vaultBefore === ethers.ZeroAddress ? totalBefore + 1n : totalBefore,
    );

    /** redeposit — 동일 clone 주소 재사용 **/
    await (await altRouter.deposit(marketId, false, DEPOSIT_USDC)).wait();
    const vaultAfterRedeposit: string = await factory.vaultOf(altAddr, marketId, false);
    const totalAfterRedeposit: bigint = await factory.totalVaults();

    expect(vaultAfterRedeposit).to.equal(vaultAddr);
    expect(totalAfterRedeposit).to.equal(totalAfterWithdraw);
    expect(await vault.collateral()).to.equal(DEPOSIT_USDC);

    console.log(`  empty cycle — ${vaultAfterRedeposit} (totalVaults ${totalAfterRedeposit})`);

    /** 테스트 잔액 회수 **/
    await (await vault.withdraw(DEPOSIT_USDC)).wait();
  });

  it("short·long — 서로 다른 볼트 주소", async function () {
    const shortBefore: string = await factory.vaultOf(ownerAddr, marketId, false);
    const longBefore: string = await factory.vaultOf(ownerAddr, marketId, true);
    const totalBefore: bigint = await factory.totalVaults();

    /** 숏 deposit **/
    await (await router.deposit(marketId, false, DEPOSIT_USDC)).wait();
    const shortAddr: string = await factory.vaultOf(ownerAddr, marketId, false);
    expect(shortAddr).to.not.equal(ethers.ZeroAddress);

    /** 롱 deposit **/
    await (await router.deposit(marketId, true, DEPOSIT_USDC)).wait();
    const longAddr: string = await factory.vaultOf(ownerAddr, marketId, true);
    expect(longAddr).to.not.equal(ethers.ZeroAddress);

    /** 방향별 격리 — 주소·isLong 상이 **/
    expect(shortAddr).to.not.equal(longAddr);
    expect(await factory.isVault(shortAddr)).to.equal(true);
    expect(await factory.isVault(longAddr)).to.equal(true);

    const shortVault = await ethers.getContractAt("PositionVault", shortAddr, owner);
    const longVault = await ethers.getContractAt("PositionVault", longAddr, owner);
    expect(await shortVault.isLong()).to.equal(false);
    expect(await longVault.isLong()).to.equal(true);

    const totalAfter: bigint = await factory.totalVaults();
    let expectedTotal = totalBefore;
    if (shortBefore === ethers.ZeroAddress) expectedTotal += 1n;
    if (longBefore === ethers.ZeroAddress) expectedTotal += 1n;
    expect(totalAfter).to.equal(expectedTotal);

    console.log(`  directions — short ${shortAddr} long ${longAddr}`);

    /** 숏 잔액 회수 (Empty일 때만) **/
    if ((await shortVault.state()) === 0n) {
      const idle = await usdc.balanceOf(shortAddr);
      if (idle > 0n) await (await shortVault.withdraw(idle)).wait();
    }
    /** 롱 잔액 회수 (Empty일 때만) **/
    if ((await longVault.state()) === 0n) {
      const idle = await usdc.balanceOf(longAddr);
      if (idle > 0n) await (await longVault.withdraw(idle)).wait();
    }
  });

  it("신규 유저 첫 deposit — VaultCreated·totalVaults +1", async function () {
    /** alt에 아직 숏 볼트가 없어야 생성 이벤트 검증 가능 **/
    const existing: string = await factory.vaultOf(altAddr, marketId, false);
    if (existing !== ethers.ZeroAddress) {
      const v = await ethers.getContractAt("PositionVault", existing, alt);
      const idle = await usdc.balanceOf(existing);
      if (idle > 0n && (await v.state()) === 0n) {
        await (await v.withdraw(idle)).wait();
      }
    }

    const altUsdc = usdc.connect(alt) as Contract;
    if ((await altUsdc.balanceOf(altAddr)) < DEPOSIT_USDC) {
      await (await usdc.transfer(altAddr, DEPOSIT_USDC)).wait();
    }

    const totalBefore: bigint = await factory.totalVaults();
    const vaultBefore: string = await factory.vaultOf(altAddr, marketId, false);

    /** alt 첫 deposit **/
    const altRouter = router.connect(alt) as Contract;
    const tx = await altRouter.deposit(marketId, false, DEPOSIT_USDC);
    const receipt = await tx.wait();

    const vaultAfter: string = await factory.vaultOf(altAddr, marketId, false);
    expect(vaultAfter).to.not.equal(ethers.ZeroAddress);
    expect(await factory.isVault(vaultAfter)).to.equal(true);

    if (vaultBefore === ethers.ZeroAddress) {
      expect(await factory.totalVaults()).to.equal(totalBefore + 1n);
      const created = receipt!.logs
        .map((log: any) => {
          try {
            return factory.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((e: any) => e?.name === "VaultCreated");
      expect(created).to.not.equal(undefined);
      expect(created!.args.vault).to.equal(vaultAfter);
      expect(created!.args.owner).to.equal(altAddr);
      console.log(`  created — ${vaultAfter} (totalVaults ${totalBefore + 1n})`);
    } else {
      expect(vaultAfter).to.equal(vaultBefore);
      expect(await factory.totalVaults()).to.equal(totalBefore);
      console.log(`  reused — ${vaultAfter} (alt vault already existed)`);
    }

    /** 테스트 잔액 회수 **/
    const vault = await ethers.getContractAt("PositionVault", vaultAfter, alt);
    if ((await vault.state()) === 0n) {
      const idle = await usdc.balanceOf(vaultAfter);
      if (idle > 0n) await (await vault.withdraw(idle)).wait();
    }
  });

  it("createVault 직접 호출 — 기존 볼트 있으면 VaultExists", async function () {
    /** owner 숏 볼트 확보 **/
    let vaultAddr: string = await factory.vaultOf(ownerAddr, marketId, false);
    if (vaultAddr === ethers.ZeroAddress) {
      await (await router.deposit(marketId, false, DEPOSIT_USDC)).wait();
      vaultAddr = await factory.vaultOf(ownerAddr, marketId, false);
    }
    expect(vaultAddr).to.not.equal(ethers.ZeroAddress);

    /** 동일 (owner, market, direction) 재생성 시도 — revert **/
    await expect(factory.createVault(marketId, false, ownerAddr)).to.be.revertedWithCustomError(
      factory,
      "VaultExists",
    );

    console.log(`  VaultExists — ${vaultAddr}`);

    /** 테스트 잔액 회수 **/
    const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    if ((await vault.state()) === 0n) {
      const idle = await usdc.balanceOf(vaultAddr);
      if (idle > 0n) await (await vault.withdraw(idle)).wait();
    }
  });
});
