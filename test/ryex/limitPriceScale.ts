/**
 * limitPriceScale.ts — GMX trigger/acceptable 스케일 검증 (Arbitrum Sepolia)
 *
 *   npx hardhat test test/ryex/limitPriceScale.ts --network arbitrumSepolia
 *
 * ETH(18dec) GMX contract price = USD × 10^12 = price8 × 10^4
 * 레거시 버그: price8 × 10^22 (= USD × 10^30) → 숏 limit 영구 미체결
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { expect } from "chai";
import type { Contract } from "ethers";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";
import { waitStateIn } from "./helpers/waitGmx";

const MARKET = "rETH";
const INDEX_DEC = 18;
const COLLATERAL = 5n * 10n ** 6n; // 5 USDC
const LEVERAGE = 2;
const ACCOUNT_ORDER_LIST = ethers.keccak256(
  ethers.AbiCoder.defaultAbiCoder().encode(["string"], ["ACCOUNT_ORDER_LIST"]),
);

function gmxStr(name: string) {
  return ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["string"], [name]));
}
function orderField(gmxKey: string, name: string) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "bytes32"], [gmxKey, gmxStr(name)]),
  );
}
function expectedGmxPrice(price8: bigint, tokenDecimals: number) {
  return price8 * 10n ** BigInt(22 - tokenDecimals);
}
function legacyWrongGmxPrice(price8: bigint) {
  return price8 * 10n ** 22n;
}

describe("limit order GMX price scale (Arbitrum Sepolia)", function () {
  this.timeout(15 * 60_000);

  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let ownerAddr: string;
  let factory: Contract;
  let router: Contract;
  let usdc: Contract;
  let oracle: Contract;
  let dataStore: Contract;
  let marketId: string;
  let execFee: bigint;
  let dataStoreAddr: string;

  async function reset(isLong: boolean) {
    const vaultAddr: string = await factory.vaultOf(ownerAddr, marketId, isLong);
    if (vaultAddr === ethers.ZeroAddress) return;
    const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    const state: bigint = await vault.state();
    if (state === 1n) {
      await (await vault.cancelLimitOrder()).wait();
      await waitStateIn(vault, [0n, 2n], { label: "cancel pending limit", timeoutMs: 180_000 });
    }
    if ((await vault.state()) === 2n) {
      let ethBal = await ethers.provider.getBalance(vaultAddr);
      if (ethBal < execFee) {
        await (await owner.sendTransaction({ to: vaultAddr, value: execFee - ethBal })).wait();
      }
      await (await vault.closePosition(0n, { value: execFee })).wait();
      await waitStateIn(vault, [0n], { label: "close active", timeoutMs: 180_000 });
    }
    if ((await vault.state()) === 0n) {
      const col: bigint = await vault.collateral();
      if (col > 0n) await (await vault.withdraw(col)).wait();
    }
  }

  async function readGmxPrices(gmxKey: string) {
    const getUint = dataStore.getFunction("getUint");
    const getAddr = dataStore.getFunction("getAddress");
    return {
      trigger: await getUint(orderField(gmxKey, "TRIGGER_PRICE")),
      acceptable: await getUint(orderField(gmxKey, "ACCEPTABLE_PRICE")),
      orderType: await getUint(orderField(gmxKey, "ORDER_TYPE")),
      account: await getAddr(orderField(gmxKey, "ACCOUNT")),
    };
  }

  async function placeLimitAndAssert(isLong: boolean) {
    const side = isLong ? "LONG" : "SHORT";
    const mark8: bigint = await oracle.getPrice();
    // 즉시 체결되지 않게: 롱=mark 아래, 숏=mark 위 (GMX LimitIncrease)
    const trigger8 = isLong ? (mark8 * 80n) / 100n : (mark8 * 120n) / 100n;
    const expected = expectedGmxPrice(trigger8, INDEX_DEC);
    const legacy = legacyWrongGmxPrice(trigger8);
    const expectedAcceptable = isLong
      ? (expected * 10_100n) / 10_000n
      : (expected * 9_900n) / 10_000n;

    console.log(`\n[${side}] mark $${ethers.formatUnits(mark8, 8)}`);
    console.log(`[${side}] trigger8 $${ethers.formatUnits(trigger8, 8)} raw=${trigger8}`);
    console.log(`[${side}] expected GMX (×10^${22 - INDEX_DEC}) ${expected}`);
    console.log(`[${side}] legacy wrong (×10^22) ${legacy}`);

    await (await router.openPosition(marketId, isLong, LEVERAGE, trigger8, COLLATERAL, { value: execFee })).wait();
    const vaultAddr: string = await factory.vaultOf(ownerAddr, marketId, isLong);
    const vault = await ethers.getContractAt("PositionVault", vaultAddr, owner);
    expect(await vault.state()).to.equal(1n, `${side} vault should be SettlingOpen`);

    const pending = await vault.pending();
    const gmxOrder = await vault.gmxOrders(pending.orderKey);
    const gmxKey: string = gmxOrder.gmxKey;
    expect(gmxKey).to.not.equal(ethers.ZeroHash);

    const onList = await dataStore.containsBytes32(
      ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "address"], [ACCOUNT_ORDER_LIST, vaultAddr]),
      ),
      gmxKey,
    );
    expect(onList).to.equal(true, `${side} order must be on GMX ACCOUNT_ORDER_LIST`);

    const stored = await readGmxPrices(gmxKey);
    console.log(`[${side}] stored trigger ${stored.trigger} (as ETH-usd ${ethers.formatUnits(stored.trigger, 12)})`);
    console.log(`[${side}] stored acceptable ${stored.acceptable}`);
    console.log(`[${side}] orderType ${stored.orderType} account ${stored.account}`);

    expect(stored.account.toLowerCase()).to.equal(vaultAddr.toLowerCase());
    expect(stored.orderType).to.equal(3n); // LimitIncrease
    expect(stored.trigger).to.equal(expected, `${side} TRIGGER_PRICE must be USD×10^(30-18)`);
    expect(stored.trigger).to.not.equal(legacy, `${side} must not use tokenDecimals-ignorant ×1e22`);
    expect(stored.acceptable).to.equal(expectedAcceptable, `${side} acceptable 1% from trigger`);
    // 오라클 min(~USD×10^12)과 같은 자릿수인지 (숏이 실제로 체결 가능한 스케일)
    const ratio = stored.trigger > mark8 ? stored.trigger / mark8 : mark8 / stored.trigger;
    expect(ratio).to.be.lt(10n ** 6n, `${side} trigger vs mark8 ratio insane — still wrong scale`);

    await (await vault.cancelLimitOrder()).wait();
    await waitStateIn(vault, [0n], { label: `${side} cancel`, timeoutMs: 180_000 });
    const col: bigint = await vault.collateral();
    if (col > 0n) await (await vault.withdraw(col)).wait();
  }

  before(async function () {
    [owner] = await ethers.getSigners();
    ownerAddr = await owner.getAddress();

    const dep = JSON.parse(
      await readFile(path.join(process.cwd(), "deployments", `${network.name}-gmx.json`), "utf8"),
    ) as {
      vaultFactory: string;
      ryexRouter: string;
      usdc: string;
      markets: Record<string, { marketId: string }>;
    };
    marketId = dep.markets[MARKET].marketId;
    factory = await ethers.getContractAt("VaultFactory", dep.vaultFactory, owner);
    router = await ethers.getContractAt("RyexRouter", dep.ryexRouter, owner);
    usdc = new ethers.Contract(dep.usdc, ERC20Abi, owner);

    const allowance: bigint = await usdc.allowance(ownerAddr, dep.ryexRouter);
    if (allowance !== ethers.MaxUint256) {
      await (await usdc.approve(dep.ryexRouter, ethers.MaxUint256)).wait();
    }

    const infra = await factory.gmxInfra();
    execFee = infra.execFee;
    dataStoreAddr = infra.dataStore;
    dataStore = new ethers.Contract(
      dataStoreAddr,
      [
        "function getUint(bytes32) view returns (uint256)",
        "function getAddress(bytes32) view returns (address)",
        "function containsBytes32(bytes32,bytes32) view returns (bool)",
      ],
      owner,
    );
    const [, oracleAddr] = await factory.markets(marketId);
    oracle = await ethers.getContractAt(["function getPrice() view returns (uint256)"], oracleAddr, owner);

    console.log(`factory ${dep.vaultFactory}`);
    console.log(`router  ${dep.ryexRouter}`);
  });

  it("short LimitIncrease trigger is ETH-scale (×1e12), not ×1e30", async function () {
    await reset(false);
    await placeLimitAndAssert(false);
  });

  it("long LimitIncrease trigger is ETH-scale (×1e12), not ×1e30", async function () {
    await reset(true);
    await placeLimitAndAssert(true);
  });
});
