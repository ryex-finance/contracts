// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IRyexTreasury — 프로토콜 수익 수납·인출 (fees, 청산 penalty treasury 몫)
interface IRyexTreasury {
    event Swept(address indexed token, address indexed to, uint256 amount);

    function sweep(IERC20 token, address to, uint256 amount) external;
}
