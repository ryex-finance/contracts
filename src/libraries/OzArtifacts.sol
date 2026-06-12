// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9.0;

// Hardhat typechain/artifact 생성용 import 전용 stub (배포·런타임 미사용).
// OZ v5에 presets/ 없어 compile 제외 — foundry.toml skip, hardhat.config.ts filter.
import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";

contract OzArtifacts {}
