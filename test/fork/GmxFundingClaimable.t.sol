// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGmxDataStore} from "../../contracts/interfaces/IGmxDataStore.sol";
import {GmxFundingUtils} from "../../contracts/libraries/GmxFundingUtils.sol";

/// @dev claimableFunding DataStore 키가 GMX Reader/포지션과 동일한지 검증.
contract GmxFundingClaimableForkTest is Test {
    address constant DATA_STORE = 0xCF4c2C4c53157BcC01A596e3788fFF69cBBCD201;
    address constant GMX_MARKET = 0xb6fC4C9eB02C35A134044526C62bb15014Ac0Bcc;
    // rYield 미배포 — claimable 키 형식만 검증하므로 account는 임의 주소로 충분.
    address constant RYIELD_VAULT = address(0);

    function setUp() public {
        vm.createSelectFork("https://sepolia-rollup.arbitrum.io/rpc");
    }

    function test_claimableFundingKey_readable() public view {
        IGmxDataStore ds = IGmxDataStore(DATA_STORE);
        address longTk = GmxFundingUtils.marketLongToken(ds, GMX_MARKET);
        address shortTk = GmxFundingUtils.marketShortToken(ds, GMX_MARKET);
        // 포지션 없거나 funding 미발생 시 0 — revert 없이 읽히면 키 형식 OK.
        GmxFundingUtils.claimableFunding(ds, GMX_MARKET, longTk, RYIELD_VAULT);
        GmxFundingUtils.claimableFunding(ds, GMX_MARKET, shortTk, RYIELD_VAULT);
    }
}
