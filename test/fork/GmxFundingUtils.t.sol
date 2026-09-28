// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGmxDataStore} from "../../contracts/interfaces/IGmxDataStore.sol";
import {GmxFundingUtils} from "../../contracts/libraries/GmxFundingUtils.sol";

/// @dev Arbitrum Sepolia fork — GmxFundingUtils 토큰 키가 Reader와 일치하는지 검증.
contract GmxFundingUtilsForkTest is Test {
    address constant DATA_STORE = 0xCF4c2C4c53157BcC01A596e3788fFF69cBBCD201;
    address constant GMX_MARKET = 0xb6fC4C9eB02C35A134044526C62bb15014Ac0Bcc;
    address constant WETH = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
    address constant USDC = 0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773;

    function setUp() public {
        vm.createSelectFork("https://sepolia-rollup.arbitrum.io/rpc");
    }

    function test_marketTokens_matchGmxEthMarket() public view {
        IGmxDataStore ds = IGmxDataStore(DATA_STORE);
        assertEq(GmxFundingUtils.marketLongToken(ds, GMX_MARKET), WETH);
        assertEq(GmxFundingUtils.marketShortToken(ds, GMX_MARKET), USDC);
    }
}
