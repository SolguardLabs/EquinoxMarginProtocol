// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EquinoxERC20} from "../token/EquinoxERC20.sol";

contract MockERC20 is EquinoxERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) EquinoxERC20(name_, symbol_, decimals_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
