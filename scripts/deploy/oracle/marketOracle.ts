/**
 * marketOracle.ts — 마켓별 Ryex price oracle 배포 (GMX 연동 vs mock-only)
 */
import { ethers } from "hardhat";
import { GMX } from "../../../config/gmxArbitrumSepolia";

export interface MarketOracleSpec {
  gmxMarket: string;
  /** mock-only 마켓 초기 가격 (8 dec) */
  mockPrice8?: bigint;
}

const GMX_INDEX: Record<string, { indexToken: string; tokenDecimals: number }> = {
  [GMX.MARKET_ETH.toLowerCase()]: { indexToken: GMX.TOKEN_WETH, tokenDecimals: 18 },
  [GMX.MARKET_BTC.toLowerCase()]: { indexToken: GMX.TOKEN_BTC, tokenDecimals: 8 },
};

export function resolveGmxIndex(gmxMarket: string): { indexToken: string; tokenDecimals: number } | null {
  if (!gmxMarket || gmxMarket === ethers.ZeroAddress) return null;
  return GMX_INDEX[gmxMarket.toLowerCase()] ?? null;
}

/** GMX 마켓이면 GmxPriceOracle, 아니면 MockPriceOracle */
export async function deployMarketOracle(spec: MarketOracleSpec): Promise<string> {
  const gmx = resolveGmxIndex(spec.gmxMarket);
  if (gmx) {
    const F = await ethers.getContractFactory("GmxPriceOracle");
    const oracle = await F.deploy(gmx.indexToken, GMX.CHAINLINK_PRICE_FEED_PROVIDER, gmx.tokenDecimals);
    await oracle.waitForDeployment();
    return oracle.getAddress();
  }
  if (spec.mockPrice8 === undefined || spec.mockPrice8 === 0n) {
    throw new Error("mock-only market requires mockPrice8");
  }
  const F = await ethers.getContractFactory("MockPriceOracle");
  const oracle = await F.deploy(spec.mockPrice8);
  await oracle.waitForDeployment();
  return oracle.getAddress();
}
