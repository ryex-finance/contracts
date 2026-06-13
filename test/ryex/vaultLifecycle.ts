/**
 * vaultLifecycle.ts — RYex PositionVault 온체인 통합 테스트 (Arbitrum Sepolia)
 *
 * 테스트 흐름:
 *   1. 배포된 VaultFactory로 rETH 볼트 생성 (이미 있으면 재사용)
 *   2. GMX 테스트넷 USDC를 볼트에 예치
 *   3. 시장가 포지션 오픈 (market order → 실제 GMX 주문 생성)
 *   4. GMX keeper가 체결할 때까지 폴링 (vault.gmxPosition().exists == true)
 *   5. GmxV2Adapter.executeOrder() 호출 → 볼트 상태 Active 전환
 *   6. vault.state() == Active, vault.gmxPosition().exists == true 최종 검증
 *
 * 실행:
 *   npx hardhat test test/ryex/vaultLifecycle.ts --network arbitrumSepolia
 */
import { expect } from "chai";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import { GMX } from "./config/gmxArbitrumSepolia";

// ── 배포 주소 타입 ────────────────────────────────────────────────────────────
interface MarketInfo {
  marketId:  string;
  oracle:    string;
  rToken:    string;
  swapPool:  string;
  gmxMarket: string;
  maxLtvBps: number;
  lltvBps:   number;
}
interface Deployment {
  chainId:           number;
  vaultFactory:      string;
  positionVaultImpl: string;
  gmxAdapter:        string;
  usdc:              string;
  gmxReader:         string;
  gmxDataStore:      string;
  markets:           Record<string, MarketInfo>;
}

// ── VaultState 열거형 (Types.sol 동일) ───────────────────────────────────────
const VaultState = { Empty: 0n, SettlingOpen: 1n, Active: 2n, SettlingLiquidate: 3n, Liquidated: 4n };

// ── 헬퍼: 조건 충족까지 폴링 ──────────────────────────────────────────────────
async function pollUntil<T>(
  fn: () => Promise<T>,
  predicate: (v: T) => boolean,
  intervalMs = 5_000,
  timeoutMs  = 3 * 60_000,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const val = await fn();
    if (predicate(val)) return val;
    console.log(`    ⏳ waiting ${intervalMs / 1000}s…`);
    await new Promise(r => setTimeout(r, intervalMs));
  }
  throw new Error(`pollUntil: timed out after ${timeoutMs / 1000}s`);
}

// ── ABI: Hardhat artifacts(.abi) / 외부 ABI 파일 ──────────────────────────────
import PositionVaultArtifact  from "../../artifacts/src/PositionVault.sol/PositionVault.json";
import VaultFactoryArtifact   from "../../artifacts/src/VaultFactory.sol/VaultFactory.json";
import GmxAdapterArtifact     from "../../artifacts/src/adapters/GmxV2Adapter.sol/GmxV2Adapter.json";
import ERC20Abi               from "../../abi/ERC20.json";
import { waitForSettlement }  from "./helpers";

const VAULT_FACTORY_ABI  = VaultFactoryArtifact.abi;
const POSITION_VAULT_ABI = PositionVaultArtifact.abi;
const GMX_ADAPTER_ABI    = GmxAdapterArtifact.abi;
const ERC20_ABI          = ERC20Abi;

const GMX_READER_ABI = [
  "function getPosition(address dataStore, bytes32 key) view returns (tuple(tuple(address account,address market,address collateralToken) addresses, tuple(uint256 sizeInUsd,uint256 sizeInTokens,uint256 collateralAmount,int256 pendingImpactAmount,uint256 borrowingFactor,uint256 fundingFeeAmountPerSize,uint256 longTokenClaimableFundingAmountPerSize,uint256 shortTokenClaimableFundingAmountPerSize,uint256 increasedAtTime,uint256 decreasedAtTime) numbers, tuple(bool isLong) flags))",
];

/** GMX Reader에서 adapter 계정의 실제 포지션을 직접 조회 (vault.gmxPosition()과 교차 검증용)
 *  isLong: false = short (테스트넷 long 풀 고갈로 short으로 전환) */
async function readGmxReaderDirect(adapterAddr: string) {
  const posKey = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "address", "bool"],
      [adapterAddr, GMX.MARKET_ETH, GMX.USDC, false /* short */],
    ),
  );
  const reader = new ethers.Contract(GMX.READER, GMX_READER_ABI, ethers.provider);
  const pos = await reader.getPosition(GMX.DATA_STORE, posKey);
  return {
    posKey,
    account: pos.addresses.account as string,
    market: pos.addresses.market as string,
    sizeInUsd: pos.numbers.sizeInUsd as bigint,
    collateralAmount: pos.numbers.collateralAmount as bigint,
    isLong: pos.flags.isLong as boolean,
    exists: (pos.numbers.sizeInUsd as bigint) > 0n,
  };
}

// ── 테스트 Suite ──────────────────────────────────────────────────────────────
describe("RYex Vault Lifecycle (Arbitrum Sepolia)", function () {
  this.timeout(3 * 60_000); // 최대 3분 (step별 30s polling × 여유)

  let deployment: Deployment;
  let signer: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let signerAddr: string;

  // 사용할 마켓: rETH (유일하게 실제 GMX 마켓 연결)
  const MARKET_SYMBOL = "rETH";
  // GMX testnet은 pool size가 작음 → $10 이하로 유지해야 InsufficientReserves 회피
  const DEPOSIT_USDC  = 5n * 10n ** 6n;  // 5 USDC (2× = $10 position)
  const LEVERAGE      = 2;
  const EXEC_FEE      = ethers.parseEther("0.0001"); // PositionVault MIN_EXEC_FEE

  before(async () => {
    [signer] = await ethers.getSigners();
    signerAddr = await signer.getAddress();

    const candidates = [
      path.join(process.cwd(), "deployments", `${network.name}-gmx.json`),
      path.join(process.cwd(), "deployments", "arbitrum-sepolia-gmx.json"),
    ];
    let deployFile = "";
    for (const f of candidates) {
      try {
        await readFile(f, "utf8");
        deployFile = f;
        break;
      } catch {
        /* try next */
      }
    }
    if (!deployFile) throw new Error(`No deployment JSON found. Run deployGmxA1.ts first.`);
    deployment = JSON.parse(await readFile(deployFile, "utf8")) as Deployment;

    console.log(`\nNetwork  : ${network.name}  (chainId ${deployment.chainId})`);
    console.log(`Signer   : ${signerAddr}`);
    console.log(`Factory  : ${deployment.vaultFactory}`);
    console.log(`Adapter  : ${deployment.gmxAdapter}`);
    console.log(`Market   : ${MARKET_SYMBOL}  (gmxMarket=${deployment.markets[MARKET_SYMBOL].gmxMarket})`);
  });

  // ── Step 1: 볼트 생성 (또는 기존 볼트 재사용) ────────────────────────────────
  it("1. create or reuse vault", async () => {
    const factory = new ethers.Contract(deployment.vaultFactory, VAULT_FACTORY_ABI, signer);
    const mkt     = deployment.markets[MARKET_SYMBOL];

    let vaultAddr: string = await factory.vaultOf(signerAddr, mkt.marketId);

    if (vaultAddr === ethers.ZeroAddress) {
      console.log("  → Creating new vault…");
      const tx = await factory.createVault(mkt.marketId);
      const rc = await tx.wait();
      // VaultCreated(address indexed owner, bytes32 indexed marketId, address vault) 이벤트 파싱
      const VAULT_CREATED_TOPIC = ethers.id("VaultCreated(address,bytes32,address)");
      for (const log of rc.logs) {
        if (log.topics[0] === VAULT_CREATED_TOPIC) {
          vaultAddr = ethers.AbiCoder.defaultAbiCoder().decode(["address"], log.data)[0] as string;
          break;
        }
      }
      console.log(`  ✓ Vault created: ${vaultAddr}`);
    } else {
      console.log(`  ✓ Reusing existing vault: ${vaultAddr}`);
    }

    expect(vaultAddr).to.not.equal(ethers.ZeroAddress);

    // 공유 상태로 저장
    (this as any).vaultAddr = vaultAddr;
  });

  // ── Step 2: USDC 잔액 확인 ──────────────────────────────────────────────────
  it("2. check USDC balance", async () => {
    const usdc = new ethers.Contract(deployment.usdc, ERC20_ABI, signer);
    const bal: bigint = await usdc.balanceOf(signerAddr);
    console.log(`  USDC balance: ${ethers.formatUnits(bal, 6)} USDC`);
    expect(bal).to.be.gte(DEPOSIT_USDC, `Need at least ${ethers.formatUnits(DEPOSIT_USDC, 6)} USDC on ${signerAddr}`);
  });

  // ── Step 3: 예치 + 포지션 오픈 ────────────────────────────────────────────
  it("3. deposit and open position", async () => {
    const vaultAddr: string = (this as any).vaultAddr ?? await (async () => {
      const factory = new ethers.Contract(deployment.vaultFactory, VAULT_FACTORY_ABI, signer);
      return factory.vaultOf(signerAddr, deployment.markets[MARKET_SYMBOL].marketId);
    })();

    const vault   = new ethers.Contract(vaultAddr, POSITION_VAULT_ABI, signer);
    const usdc    = new ethers.Contract(deployment.usdc, ERC20_ABI, signer);
    const curState: bigint = await vault.state();

    if (curState === VaultState.Active) {
      console.log("  → Vault already Active, skipping deposit/open");
      (this as any).vaultAddr = vaultAddr;
      return;
    }
    if (curState === VaultState.SettlingOpen) {
      console.log("  → Vault already SettlingOpen, skipping deposit/open");
      (this as any).vaultAddr = vaultAddr;
      return;
    }

    // Empty 상태 — 이전 테스트 실행에서 취소된 collateral 누적분 정리
    const existingCol: bigint = await vault.collateral();
    if (existingCol > 0n) {
      console.log(`  → 잔여 collateral ${ethers.formatUnits(existingCol, 6)} USDC 회수 (이전 실행 잔여분)…`);
      await (await vault.withdraw(existingCol)).wait();
    }

    console.log(`  → Approving ${ethers.formatUnits(DEPOSIT_USDC, 6)} USDC…`);
    await (await usdc.approve(vaultAddr, DEPOSIT_USDC)).wait();

    console.log(`  → Depositing…`);
    await (await vault.deposit(DEPOSIT_USDC)).wait();

    const col: bigint = await vault.collateral();
    console.log(`  ✓ Collateral: ${ethers.formatUnits(col, 6)} USDC (목표: ${ethers.formatUnits(DEPOSIT_USDC, 6)} USDC)`);

    // GMX 테스트넷 long 풀 고갈 빈번 → short(isLong=false)로 테스트
    console.log(`  → Opening position (${LEVERAGE}× short market order)…`);
    const openTx = await vault.openPosition(LEVERAGE, false /* isLong=short */, { value: EXEC_FEE });
    const rc     = await openTx.wait();
    console.log(`  ✓ openPosition tx: ${rc?.hash}`);

    const stateAfter: bigint = await vault.state();
    // GMX 콜백이 openPosition TX 직후 바로 발화할 수 있음 (Arbitrum 빠른 keeper)
    // → SettlingOpen (대기 중) or Active (즉시 체결) or Empty (즉시 취소) 모두 유효
    if (stateAfter === VaultState.Active) {
      console.log("  ⚡ GMX callback 즉시 발화 — 이미 Active (체결)");
    } else if (stateAfter === VaultState.Empty) {
      console.log("  ⚡ GMX callback 즉시 발화 — 이미 Empty (취소)");
    } else {
      expect(stateAfter).to.equal(VaultState.SettlingOpen, "Vault should be SettlingOpen");
      console.log("  ✓ vault = SettlingOpen (GMX 처리 대기 중)");
    }

    (this as any).vaultAddr = vaultAddr;
  });

  // ── Step 4: GMX keeper 처리 대기 (체결 or 취소 콜백 자동 발생) ─────────────
  it("4. wait for GMX keeper to process the order (callback fires automatically)", async () => {
    const vaultAddr: string = (this as any).vaultAddr;
    const vault   = new ethers.Contract(vaultAddr, POSITION_VAULT_ABI, signer);
    const adapter = new ethers.Contract(deployment.gmxAdapter, GMX_ADAPTER_ABI, signer);

    const curState: bigint = await vault.state();
    if (curState !== VaultState.SettlingOpen) {
      console.log(`  → Already transitioned to state=${curState} (callback fired)`);
      return;
    }

    console.log("  → Waiting for GMX keeper to process order (target: vault.state ≠ SettlingOpen)…");
    console.log("     GMX callback fires afterOrderExecution or afterOrderCancellation automatically.");

    // vault.state()가 SettlingOpen에서 벗어날 때까지 대기 (콜백이 자동으로 전환)
    const finalState = await pollUntil(
      () => vault.state() as Promise<bigint>,
      (s) => s !== VaultState.SettlingOpen,
      5_000,
      90_000, // 최대 90초
    );

    const gmxPos = await vault.gmxPosition() as { exists: boolean; sizeInUsd: bigint; collateralAmount: bigint };
    const pending = await vault.pending();
    const orderInfo = await adapter.orders(pending.orderKey) as { gmxKey: string; executed: boolean };

    console.log(`  GMX orderKey    : ${orderInfo.gmxKey}`);
    console.log(`  order.executed  : ${orderInfo.executed}`);
    console.log(`  vault.state()   : ${finalState} (Active=2, Empty=0)`);
    console.log(`  gmxPos.exists   : ${gmxPos.exists}`);

    if (finalState === VaultState.Empty) {
      throw new Error(
        "GMX order was CANCELLED (likely InsufficientReserves on testnet). " +
        "Vault returned to Empty via afterOrderCancellation callback. " +
        "Check pool liquidity or increase execFee."
      );
    }

    if (gmxPos.exists) {
      console.log(`  ✓ GMX position: sizeInUsd=${ethers.formatUnits(gmxPos.sizeInUsd, 30)} USD`);
      console.log(`                  collateral=${ethers.formatUnits(gmxPos.collateralAmount, 6)} USDC`);
    }
  });

  // ── Step 5: GMX 콜백 자동 정산 or settleGmxOrder fallback → 볼트 Active 전환 ──
  it("5. GMX callback (or fallback) settles the RYex order → Active", async () => {
    const vaultAddr: string = (this as any).vaultAddr;
    const vault = new ethers.Contract(vaultAddr, POSITION_VAULT_ABI, signer);

    const curState: bigint = await vault.state();
    if (curState === VaultState.Active) {
      console.log("  → Already Active (callback fired before this step)");
      return;
    }

    console.log("  → Waiting for GMX callback or triggering settleGmxOrder fallback…");
    await waitForSettlement(vaultAddr, deployment.gmxAdapter, signer);
    console.log("  ✓ vault settled");
  });

  // ── Step 6: 최종 검증 — vault.gmxPosition() + GMX Reader 교차 검증 ─────
  it("6. verify vault is Active with real GMX position", async () => {
    const vaultAddr: string = (this as any).vaultAddr;
    const vault = new ethers.Contract(vaultAddr, POSITION_VAULT_ABI, signer);

    const finalState: bigint = await vault.state();
    console.log(`  vault.state() = ${finalState} (expected ${VaultState.Active} = Active)`);
    expect(finalState).to.equal(VaultState.Active, "Vault must be Active");

    // 유저가 조회하는 경로: vault.gmxPosition() → adapter → GMX Reader
    const gmxPos = await vault.gmxPosition();
    console.log(`\n  ── vault.gmxPosition() (유저 조회 경로) ─────────`);
    console.log(`  exists          : ${gmxPos.exists}`);
    console.log(`  sizeInUsd       : ${ethers.formatUnits(gmxPos.sizeInUsd, 30)} USD`);
    console.log(`  collateralAmount: ${ethers.formatUnits(gmxPos.collateralAmount, 6)} USDC`);

    // GMX Reader 직접 조회 (교차 검증)
    const readerPos = await readGmxReaderDirect(deployment.gmxAdapter);
    console.log(`\n  ── GMX Reader 직접 조회 (교차 검증) ─────────────`);
    console.log(`  adapter account : ${deployment.gmxAdapter}`);
    console.log(`  positionKey     : ${readerPos.posKey}`);
    console.log(`  exists          : ${readerPos.exists}`);
    console.log(`  sizeInUsd       : ${ethers.formatUnits(readerPos.sizeInUsd, 30)} USD`);
    console.log(`  collateralAmount: ${ethers.formatUnits(readerPos.collateralAmount, 6)} USDC`);
    console.log(`  isLong          : ${readerPos.isLong}`);
    console.log(`  ──────────────────────────────────────────────────`);

    expect(gmxPos.exists).to.be.true;
    expect(gmxPos.sizeInUsd).to.be.gt(0n);
    expect(gmxPos.collateralAmount).to.be.gt(0n);

    // vault 조회 결과와 GMX Reader 직접 조회가 일치해야 함
    expect(readerPos.exists).to.be.true;
    expect(gmxPos.sizeInUsd).to.equal(readerPos.sizeInUsd, "sizeInUsd must match GMX Reader");
    expect(gmxPos.collateralAmount).to.equal(readerPos.collateralAmount, "collateral must match GMX Reader");
  });
});
