import type { BaseContract } from "ethers";
import { ethers } from "hardhat";

const DATA_STORE_ABI = [
  "function getAddress(bytes32) view returns (address)",
  "function getUint(bytes32) view returns (uint256)",
  "function containsBytes32(bytes32,bytes32) view returns (bool)",
] as const;

/** GMX DataStore — BaseContract.getAddress()와 충돌하지 않도록 getFunction으로 호출. */
export async function dataStoreGetAddress(ds: BaseContract, key: string): Promise<string> {
  return ds.getFunction("getAddress").staticCall(key);
}

export async function getGmxDataStore(address: string) {
  return ethers.getContractAt([...DATA_STORE_ABI], address);
}
