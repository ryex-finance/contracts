import type {
  HardhatUserConfig,
  HardhatNetworkAccountUserConfig,
  HardhatNetworkHDAccountsUserConfig,
  HttpNetworkHDAccountsConfig,
} from "hardhat/types";
import { subtask } from "hardhat/config";
import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from "hardhat/builtin-tasks/task-names";
import * as dotenv from "dotenv";

import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-foundry";

subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(async (_, _hre, runSuper) => {
  const paths: string[] = await runSuper();
  return paths.filter((p) => !p.endsWith("PeripheryArtifacts.sol"));
});

dotenv.config();

const PRIVATE_KEY = process.env.PRIVATE_KEY;
const MNEMONIC = process.env.MNEMONIC;
const ARB_SEPOLIA_RPC = process.env.ARB_SEPOLIA_RPC ?? "https://sepolia-rollup.arbitrum.io/rpc";

const HD_PATH = "m/44'/60'/0'/0";

function sepoliaAccounts(): string[] | HttpNetworkHDAccountsConfig {
  if (PRIVATE_KEY) return [PRIVATE_KEY];
  if (MNEMONIC) {
    return { mnemonic: MNEMONIC, initialIndex: 0, count: 10, path: HD_PATH, passphrase: "" };
  }
  return [];
}

function hardhatAccounts(): HardhatNetworkHDAccountsUserConfig | HardhatNetworkAccountUserConfig[] {
  if (PRIVATE_KEY) {
    return [{ privateKey: PRIVATE_KEY, balance: "10000000000000000000000" }];
  }
  if (MNEMONIC) return { mnemonic: MNEMONIC, count: 10 };
  return { mnemonic: "test test test test test test test test test test test junk", count: 10 };
}

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 1 },
      viaIR: true,
      metadata: { bytecodeHash: "none" },
    },
  },
  networks: {
    arbitrumSepolia: {
      url: ARB_SEPOLIA_RPC,
      accounts: sepoliaAccounts(),
      chainId: 421614,
    },
    hardhat: {
      accounts: hardhatAccounts(),
    },
  },
  mocha: {
    timeout: 600_000,
  },
  paths: {
    tests: "./test/ryex",
  },
};

export default config;
