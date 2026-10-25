// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract CraftingV1 is ERC1155Upgradeable, OwnableUpgradeable {
    uint256 public constant WOOD = 1;
    uint256 public constant ORE = 2;
    uint256 public constant SWORD = 3;
    uint256 public totalCrafted;

    error ZeroAmount();
    error InvalidResource(uint256 id);
    error ZeroRecipient();

    event Crafted(address indexed player, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) public initializer {
        __ERC1155_init("");
        __Ownable_init(owner_);
    }

    function issue(address to, uint256 id, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroRecipient();
        if (id != WOOD && id != ORE) revert InvalidResource(id);
        if (amount == 0) revert ZeroAmount();
        _mint(to, id, amount, "");
    }

    function craft(uint256 n) external {
        if (n == 0) revert ZeroAmount();
        address player = _msgSender();
        _burn(player, WOOD, 3 * n);
        _burn(player, ORE, 2 * n);
        totalCrafted += n;
        emit Crafted(player, n);
        _mint(player, SWORD, n, "");
    }
}
