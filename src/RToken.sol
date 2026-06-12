// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IRToken} from "./interfaces/IRToken.sol";

/// @title RToken — 자산 표시 부채 토큰 (docs/11). 자산별 인스턴스(rBTC, rETH, …).
/// @notice Vault만 mint/burn(D1). mint 수령자는 Vault가 전달하는 owner EOA(D2).
///         이름/심볼은 마켓 등록 시 VaultFactory가 주입(Wave 1 멀티에셋).
contract RToken is ERC20, IRToken {
    IVaultFactory public immutable factory;

    event RBTCMinted(address indexed vault, address indexed to, uint256 amount);
    event RBTCBurned(address indexed vault, address indexed from, uint256 amount);

    error NotVault();

    constructor(IVaultFactory factory_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        factory = factory_;
    }

    modifier onlyVault() {
        if (!factory.isVault(msg.sender)) revert NotVault(); // D1
        _;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
        emit RBTCMinted(msg.sender, to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
        emit RBTCBurned(msg.sender, from, amount);
    }

    // 명시적 오버라이드 해소 (IERC20 vs ERC20)
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
