// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A mintable ERC-20 standing in for IMD and for the tokens cases are about.
contract MockERC20 is ERC20 {
    string internal sym;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        sym = symbol_;
    }

    function symbol() public view override returns (string memory) {
        return sym;
    }

    function setSymbol(string memory s) external {
        sym = s;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A token whose symbol() reverts.
contract RevertingSymbolToken {
    function symbol() external pure returns (string memory) {
        revert("no symbol");
    }
}

/// @dev A token whose symbol() returns a bytes32, as MKR does.
contract Bytes32SymbolToken {
    function symbol() external pure returns (bytes32) {
        return "MKR";
    }
}

/// @dev A token whose symbol() burns all the gas it is given.
contract GasBurningSymbolToken {
    function symbol() external pure returns (string memory) {
        while (true) {}
        return "";
    }
}

/// @dev A token whose symbol() returns a huge string.
contract BombSymbolToken {
    function symbol() external pure returns (string memory) {
        return new string(100_000);
    }
}
