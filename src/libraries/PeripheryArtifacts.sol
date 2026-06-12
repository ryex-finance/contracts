// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9.0;
pragma abicoder v2;

// Hardhat typechain/artifact 생성용 import 전용 stub (배포·런타임 미사용).
// Uniswap V3 pragma 충돌로 compile 제외 — foundry.toml skip, hardhat.config.ts filter.
import {NonfungiblePositionManager} from "@uniswap/v3-periphery/NonfungiblePositionManager.sol";
import {NonfungibleTokenPositionDescriptor} from "@uniswap/v3-periphery/NonfungibleTokenPositionDescriptor.sol";
import {SwapRouter} from "@uniswap/v3-periphery/SwapRouter.sol";
import {Quoter} from "@uniswap/v3-periphery/lens/Quoter.sol";
import {QuoterV2} from "@uniswap/v3-periphery/lens/QuoterV2.sol";
import {TickLens} from "@uniswap/v3-periphery/lens/TickLens.sol";
import {NFTDescriptor} from "@uniswap/v3-periphery/libraries/NFTDescriptor.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";

contract PeripheryArtifacts {}
