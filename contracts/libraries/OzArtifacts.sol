// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9.0;

// Hardhat typechain/artifact 생성용 import 전용 stub (Foundry compile 제외).
// 실제 배포용 구현: contracts/mocks/ERC20PresetMinterPauser.sol
import {ERC20PresetMinterPauser} from "../mocks/ERC20PresetMinterPauser.sol";

contract OzArtifacts is ERC20PresetMinterPauser {
    constructor() ERC20PresetMinterPauser("OzArtifacts", "OZA") {}
}
