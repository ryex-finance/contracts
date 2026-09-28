/**
 * createRethUsdcPool.ts — 새 rToken 기준 rETH/USDC UniV3 풀 생성
 *
 *   # 풀만 생성·초기화 (유동성 없음) — 재배포 직후 기본
 *   SKIP_LIQUIDITY=1 npx hardhat run scripts/setup/createRethUsdcPool.ts --network arbitrumSepolia
 *
 *   # 유동성까지 (추후)
 *   npx hardhat run scripts/setup/createRethUsdcPool.ts --network arbitrumSepolia
 *
 * - fee: deployments swapFee (기본 3000)
 * - SKIP_LIQUIDITY=1 이면 mint / RYield setPool 스킵
 * - 결과는 deployments/pools.<network>.json
 */
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import ERC20Abi from "../../abi/ERC20.json";
import { UNIV3 } from "../../config/gmxArbitrumSepolia";

const MARKET = "rETH";
const SKIP_LIQUIDITY =
  process.env.SKIP_LIQUIDITY === "1" || process.env.SKIP_LIQUIDITY === "true";

function sortTokens(a: string, b: string): [string, string] {
  return a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
}

/** token1/token0 raw 가격비 → sqrtPriceX96 */
function calcSqrtPriceX96(priceToken1PerToken0: number): bigint {
  const sqrtP = Math.sqrt(priceToken1PerToken0);
  return BigInt(Math.round(sqrtP * 2 ** 40)) * 2n ** 56n;
}

async function main() {
  const profile = process.env.DEPLOY_PROFILE ?? `${network.name}-gmx`;
  const depFile = path.join(process.cwd(), "deployments", `${profile}.json`);
  const uniFile = path.join(process.cwd(), "deployments", `univ3.${network.name}.json`);
  const dep = JSON.parse(await readFile(depFile, "utf8"));
  const uni = JSON.parse(await readFile(uniFile, "utf8"));

  const market = dep.markets?.[MARKET];
  if (!market?.rToken || !market?.oracle) throw new Error(`markets.${MARKET} incomplete`);
  if (!dep.usdc) throw new Error("usdc missing");

  const fee: number = Number(dep.swapFee ?? 3000);
  const npmAddr: string = uni.nonfungiblePositionManager ?? UNIV3.NPM;
  const factoryAddr: string = uni.factory ?? UNIV3.FACTORY;
  const rTokenAddr: string = market.rToken;
  const usdcAddr: string = dep.usdc;
  const oracleAddr: string = market.oracle;

  const [signer] = await ethers.getSigners();
  const signerAddr = await signer.getAddress();

  const rToken = new ethers.Contract(rTokenAddr, ERC20Abi, signer);
  const usdc = new ethers.Contract(usdcAddr, ERC20Abi, signer);
  const oracle = await ethers.getContractAt(["function getPrice() view returns (uint256)"], oracleAddr, signer);
  const npm = await ethers.getContractAt("INonfungiblePositionManager", npmAddr, signer);
  const factory = await ethers.getContractAt("IUniswapV3Factory", factoryAddr, signer);

  if (!dep.vaultFactory) throw new Error("deployments.vaultFactory missing");
  const vaultFactory = await ethers.getContractAt("VaultFactory", dep.vaultFactory, signer);

  const price8: bigint = await oracle.getPrice();
  if (price8 === 0n) throw new Error("oracle price is 0");

  const [token0, token1] = sortTokens(rTokenAddr, usdcAddr);
  const usdcIsToken0 = token0.toLowerCase() === usdcAddr.toLowerCase();

  const priceToken1PerToken0 = usdcIsToken0
    ? Number(10n ** 20n) / Number(price8)
    : Number(price8) / Number(10n ** 20n);
  const sqrtPriceX96 = calcSqrtPriceX96(priceToken1PerToken0);

  console.log(`Network   : ${network.name}`);
  console.log(`Signer    : ${signerAddr}`);
  console.log(`rToken    : ${rTokenAddr}`);
  console.log(`oracle $  : ${ethers.formatUnits(price8, 8)}`);
  console.log(`token0/1  : ${usdcIsToken0 ? "USDC/rETH" : "rETH/USDC"}`);
  console.log(`fee       : ${fee}`);
  console.log(`SKIP_LP   : ${SKIP_LIQUIDITY}`);
  console.log(`sqrtPrice : ${sqrtPriceX96}`);

  let pool: string = await factory.getPool(token0, token1, fee);
  if (pool === ethers.ZeroAddress) {
    console.log("createAndInitializePoolIfNecessary…");
    await (await npm.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96)).wait();
    pool = await factory.getPool(token0, token1, fee);
    if (pool === ethers.ZeroAddress) throw new Error("pool create failed");
  } else {
    console.log(`pool already exists: ${pool}`);
  }
  console.log(`Pool      : ${pool}`);

  /** TWAP(buybackTwapWindow=300s)용 observation 슬롯 확보.
   *  UniV3 기본 cardinality=1이면 observe(300)가 OLD로 revert → buybackPreview/게이트 전부 깨짐.
   *  increaseObservationCardinalityNext는 슬롯만 예약하고, 실제 cardinality는 이후 스왑/mint가
   *  쓰면서 채워짐. 테스트넷 300s 윈도우면 50~100 권장 — 재배포 없이 풀에 직접 호출 가능. */
  const OBSERVATION_CARDINALITY_NEXT = Number(process.env.OBS_CARDINALITY ?? "100");
  const poolView = new ethers.Contract(
    pool,
    [
      "function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)",
      "function increaseObservationCardinalityNext(uint16)",
    ],
    signer,
  );
  const [, , , , cardinalityNext] = await poolView.slot0();
  if (Number(cardinalityNext) < OBSERVATION_CARDINALITY_NEXT) {
    await (await poolView.increaseObservationCardinalityNext(OBSERVATION_CARDINALITY_NEXT)).wait();
    console.log(
      `increaseObservationCardinalityNext ✓ (${cardinalityNext} → ${OBSERVATION_CARDINALITY_NEXT})`,
    );
  } else {
    console.log(`observationCardinalityNext already ${cardinalityNext} (≥ ${OBSERVATION_CARDINALITY_NEXT}), skip`);
  }

  /** VaultFactory에 pool 등록 — 청산 buyback(pendingBuyback 대기버킷 저가매수) 가격조회·라우팅용.
   *  유동성 유무와 무관하게 항상 등록(유동성은 나중에 채워도 buyback은 자연히 활성화). */
  const marketId: string = market.marketId;
  if (!marketId) throw new Error(`markets.${MARKET}.marketId missing`);
  const [, , , , currentPool] = await vaultFactory.markets(marketId);
  if ((currentPool as string).toLowerCase() !== pool.toLowerCase()) {
    await (await vaultFactory.setMarketPool(marketId, pool)).wait();
    console.log(`VaultFactory.setMarketPool ✓ (${pool})`);
  } else {
    console.log("VaultFactory.setMarketPool — already set, skip");
  }

  /** buyback 파라미터 기본값 — 미설정(전부 0)이면 최초 1회만 세팅.
   *  twapWindow=0(테스트넷: UniV3 observation 미충진 시 observe(OLD)로 buybackPreview가 revert하던 문제
   *  회피). cardinality가 충분히 찬 뒤 owner가 setBuybackParams(300, …)로 TWAP 윅 필터 재활성 가능.
   *  bountyBps=20(0.2%), bufferBps=100(1%) — 스팟 목표가=오라클가×99%, sqrtPriceLimitX96 하드 스톱. */
  const [twapWindow, bountyBps, bufferBps] = await Promise.all([
    vaultFactory.buybackTwapWindow(),
    vaultFactory.buybackBountyBps(),
    vaultFactory.buybackBufferBps(),
  ]);
  if (twapWindow === 0n && bountyBps === 0n && bufferBps === 0n) {
    await (await vaultFactory.setBuybackParams(0, 20, 100)).wait();
    console.log("VaultFactory.setBuybackParams ✓ (twap=0, bounty=0.2%, buffer=1%)");
  } else {
    console.log(
      `VaultFactory buyback params already set — twap=${twapWindow}s bounty=${bountyBps}bps buffer=${bufferBps}bps, skip`,
    );
  }

  /** LP 인센티브(borrow fee → 이 풀) — LpZap 배포·등록. UniswapV3Staker의 "라운드"(incentive
   *  startTime~endTime, 이미 시작한 라운드엔 리워드 추가 적립 불가) 제약이 없는 자체
   *  accRewardPerLiquidity 연속 누적기 컨트랙트(docs 참고). borrowFeeToLpBps는 VaultFactory 생성자
   *  기본값(100%)을 그대로 쓴다. 필요 시 owner가 이후 setBorrowFeeToLpBps로 조정.
   *  이미 lpZap이 설정돼 있으면 재배포하지 않고 그대로 재사용(주소는 deployments/pools.<network>.json에 기록). */
  const currentLpZap: string = await vaultFactory.lpZap();
  let lpZapAddr = currentLpZap;
  if (currentLpZap === ethers.ZeroAddress) {
    console.log("LpZap 배포 중…");
    const lpZapFactory = await ethers.getContractFactory("LpZap", signer);
    const lpZap = await lpZapFactory.deploy(dep.vaultFactory, npmAddr, usdcAddr);
    await lpZap.waitForDeployment();
    lpZapAddr = await lpZap.getAddress();
    await (await vaultFactory.setLpZap(lpZapAddr)).wait();
    console.log(`LpZap 배포 + VaultFactory.setLpZap ✓ (${lpZapAddr})`);
  } else {
    console.log(`VaultFactory.lpZap — already set, skip (${currentLpZap})`);
  }

  if (!SKIP_LIQUIDITY) {
    const rethBal: bigint = await rToken.balanceOf(signerAddr);
    const usdcBal: bigint = await usdc.balanceOf(signerAddr);
    if (rethBal === 0n) throw new Error("rETH balance is 0");
    const usdcNeeded: bigint = (rethBal * price8) / 10n ** 20n;
    if (usdcBal < usdcNeeded) {
      throw new Error(
        `insufficient USDC: have ${ethers.formatUnits(usdcBal, 6)}, need ${ethers.formatUnits(usdcNeeded, 6)}`,
      );
    }

    const tickSpacing = Number(await factory.feeAmountTickSpacing(fee));
    const tickLower = Math.ceil(-887272 / tickSpacing) * tickSpacing;
    const tickUpper = Math.floor(887272 / tickSpacing) * tickSpacing;

    await (await rToken.approve(npmAddr, rethBal)).wait();
    await (await usdc.approve(npmAddr, usdcNeeded)).wait();

    const amount0Desired = usdcIsToken0 ? usdcNeeded : rethBal;
    const amount1Desired = usdcIsToken0 ? rethBal : usdcNeeded;

    console.log("mint full-range liquidity…");
    const tx = await npm.mint({
      token0,
      token1,
      fee,
      tickLower,
      tickUpper,
      amount0Desired,
      amount1Desired,
      amount0Min: 0n,
      amount1Min: 0n,
      recipient: signerAddr,
      deadline: Math.floor(Date.now() / 1000) + 1800,
    });
    const rc = await tx.wait();
    console.log(`mint tx   : ${rc?.hash}`);

    const ryield = dep.ryieldVaults?.[MARKET];
    if (ryield) {
      const vault = await ethers.getContractAt("RYieldVault", ryield, signer);
      const owner = await vault.owner();
      if (owner.toLowerCase() === signerAddr.toLowerCase()) {
        await (await vault.setPool(pool)).wait();
        console.log(`RYieldVault.setPool ✓ (${ryield})`);
      } else {
        console.warn(`skip setPool — vault owner ${owner} ≠ signer`);
      }
    }
  } else {
    console.log("skip liquidity mint + RYield setPool (SKIP_LIQUIDITY=1)");
  }

  const poolsFile = path.join(process.cwd(), "deployments", `pools.${network.name}.json`);
  const priceHuman = Number(ethers.formatUnits(price8, 8));
  const poolsOut = {
    network: network.name,
    signer: signerAddr,
    fee,
    skipLiquidity: SKIP_LIQUIDITY,
    rToken: rTokenAddr,
    lpZap: lpZapAddr,
    prices: { [`${MARKET}/USDC`]: priceHuman },
    pools: { [`${MARKET}/USDC`]: pool },
  };
  await writeFile(poolsFile, `${JSON.stringify(poolsOut, null, 2)}\n`);
  console.log(`\n✓ saved pools.${MARKET}/USDC → ${poolsFile}`);

  // 메인 deployments/<profile>.json에도 lpZap·pool을 반영 — 프론트/키퍼가 단일 파일(예:
  // deployments/arbitrumSepolia-gmx.json)만 보고도 lpZap 주소를 찾을 수 있도록 pools.<network>.json과
  // 이중 기록한다(과거엔 여기 기록이 빠져서 프론트가 lpZap 주소를 못 찾는 문제가 있었음).
  dep.lpZap = lpZapAddr;
  dep.markets[MARKET].pool = pool;
  dep.updatedAt = new Date().toISOString();
  await writeFile(depFile, `${JSON.stringify(dep, null, 2)}\n`);
  console.log(`✓ synced lpZap/pool → ${depFile}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
