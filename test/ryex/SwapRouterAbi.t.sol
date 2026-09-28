// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISwapRouter02} from "../../contracts/interfaces/ISwapRouter02.sol";

/// @dev 배포본은 v3-periphery SwapRouter (deadline 있음). SwapRouter02 ABI로 호출하면 셀렉터가 달라 revert.
contract SwapRouterAbiTest is Test {
    function test_exactInputSingle_selectorMatchesPeripheryV1() public pure {
        bytes4 got = ISwapRouter02.exactInputSingle.selector;
        bytes4 v1 = bytes4(
            keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))")
        );
        bytes4 router02 = bytes4(
            keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))")
        );
        assertEq(got, v1, "must match Uniswap v3-periphery SwapRouter");
        assertTrue(got != router02, "must not use SwapRouter02 (no deadline) selector");
    }
}
