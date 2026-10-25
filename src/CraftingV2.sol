// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CraftingV1} from "./CraftingV1.sol";

/// @custom:oz-upgrades-from CraftingV1
contract CraftingV2 is CraftingV1 {
    uint256 public totalSalvaged;

    event Salvaged(address indexed player, uint256 amount);

    function salvage(uint256 n) external {
        if (n == 0) revert ZeroAmount();
        address player = _msgSender();
        _burn(player, SWORD, n);
        totalSalvaged += n;
        emit Salvaged(player, n);
        _mint(player, ORE, n, "");
    }
}
