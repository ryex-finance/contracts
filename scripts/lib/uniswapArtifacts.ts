import UniswapV3FactoryArtifact from "@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";
import SwapRouterArtifact from "@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json";
import NonfungiblePositionManagerArtifact from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
import NonfungibleTokenPositionDescriptorArtifact from "@uniswap/v3-periphery/artifacts/contracts/NonfungibleTokenPositionDescriptor.sol/NonfungibleTokenPositionDescriptor.json";
import NFTDescriptorArtifact from "@uniswap/v3-periphery/artifacts/contracts/libraries/NFTDescriptor.sol/NFTDescriptor.json";
import QuoterArtifact from "@uniswap/v3-periphery/artifacts/contracts/lens/Quoter.sol/Quoter.json";
import QuoterV2Artifact from "@uniswap/v3-periphery/artifacts/contracts/lens/QuoterV2.sol/QuoterV2.json";
import TickLensArtifact from "@uniswap/v3-periphery/artifacts/contracts/lens/TickLens.sol/TickLens.json";
import type { ArtifactJson } from "./artifact";

// NOTE: UniswapV3Staker는 더 이상 쓰지 않는다 — "라운드"(incentive startTime~endTime, 이미 시작한
// 라운드엔 리워드 추가 적립 불가) 제약 때문에 자체 LpZap(accRewardPerLiquidity 연속 누적기)으로 교체함.
// LpZap은 우리 컨트랙트(contracts/LpZap.sol)이므로 hardhat이 직접 컴파일 — 여기 아티팩트 목록에 없음.
export const UNISWAP_DEPLOY_ARTIFACTS = {
  UniswapV3Factory: UniswapV3FactoryArtifact as ArtifactJson,
  SwapRouter: SwapRouterArtifact as ArtifactJson,
  NonfungiblePositionManager: NonfungiblePositionManagerArtifact as ArtifactJson,
  NonfungibleTokenPositionDescriptor: NonfungibleTokenPositionDescriptorArtifact as ArtifactJson,
  NFTDescriptor: NFTDescriptorArtifact as ArtifactJson,
  Quoter: QuoterArtifact as ArtifactJson,
  QuoterV2: QuoterV2Artifact as ArtifactJson,
  TickLens: TickLensArtifact as ArtifactJson,
} as const;
