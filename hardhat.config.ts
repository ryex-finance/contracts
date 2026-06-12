import type { HardhatUserConfig } from "hardhat/config";
import { subtask } from "hardhat/config";
import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from "hardhat/builtin-tasks/task-names";
import * as dotenv from "dotenv";

import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-foundry";

// src/libraries/OzArtifacts.sol · PeripheryArtifacts.sol — typechain 생성용 import stub.
// OZ v5 presets / Uniswap V3 pragma 충돌로 Hardhat compile에서 제외 (foundry.toml skip 동일).
subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(async (_, _hre, runSuper) => {
  const paths: string[] = await runSuper();
  return paths.filter(
    (p) => !p.endsWith("OzArtifacts.sol") && !p.endsWith("PeripheryArtifacts.sol"),
  );
});

dotenv.config();

const PRIVATE_KEY = process.env.PRIVATE_KEY;
const MNEMONIC = process.env.MNEMONIC;
const ARB_SEPOLIA_RPC = process.env.ARB_SEPOLIA_RPC ?? "https://sepolia-rollup.arbitrum.io/rpc";

function networkAccounts() {
  if (PRIVATE_KEY) return [PRIVATE_KEY];
  if (MNEMONIC) return { mnemonic: MNEMONIC, count: 10 };
  return [];
}

const config: HardhatUserConfig = {
  solidity: {
    // Match the fixed `pragma solidity 0.8.24;` declared by every migrated source file.
    version: "0.8.24",
    settings: {
      optimizer: {
        // Parity with Foundry (optimizer_runs = 200) for consistent bytecode/gas.
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    arbitrumSepolia: {
      url: ARB_SEPOLIA_RPC,
      accounts: networkAccounts(),
      chainId: 421614,
    },
  },
  paths: {
    // Foundry 전용: test/*.sol — Hardhat은 TS 테스트만 이 디렉터리에서 읽습니다.
    tests: "./test/ryex",
  },
};

export default config;
