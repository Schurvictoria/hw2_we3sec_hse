// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {CraftingV1} from "../src/CraftingV1.sol";
import {CraftingV2} from "../src/CraftingV2.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract GameReceiver is ERC1155Holder {
    CraftingV2 public game;
    uint256 public rejectId;
    bool public checkCraft;
    bool public checkSalvage;

    constructor(address proxy) {
        game = CraftingV2(proxy);
    }

    function configure(uint256 rejectId_, bool craft_, bool salvage_) external {
        rejectId = rejectId_;
        checkCraft = craft_;
        checkSalvage = salvage_;
    }

    function craft(uint256 n) external {
        game.craft(n);
    }

    function salvage(uint256 n) external {
        game.salvage(n);
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        require(id != rejectId, "item rejected");
        if (checkCraft && id == 3) {
            require(game.balanceOf(address(this), 1) == 0, "wood not spent");
            require(game.balanceOf(address(this), 2) == 0, "ore not spent");
            require(game.totalCrafted() == 2, "craft counter not updated");
        }
        if (checkSalvage && id == 2) {
            require(game.balanceOf(address(this), 3) == 0, "swords not spent");
            require(game.totalSalvaged() == 2, "salvage counter not updated");
        }
        return this.onERC1155Received.selector;
    }
}

contract CraftingTest is Test {
    address owner = makeAddr("game owner");
    address adminOwner = makeAddr("proxy admin owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address operator = makeAddr("operator");
    address proxy;
    CraftingV1 game;

    event Crafted(address indexed player, uint256 amount);
    event Salvaged(address indexed player, uint256 amount);

    function setUp() public {
        proxy = Upgrades.deployTransparentProxy(
            "CraftingV1.sol", adminOwner, abi.encodeCall(CraftingV1.initialize, (owner))
        );
        game = CraftingV1(proxy);
    }

    function fund(address player, uint256 wood, uint256 ore) internal {
        vm.startPrank(owner);
        if (wood > 0) game.issue(player, 1, wood);
        if (ore > 0) game.issue(player, 2, ore);
        vm.stopPrank();
    }

    function upgrade() internal returns (CraftingV2) {
        Upgrades.upgradeProxy(proxy, "CraftingV2.sol", "", adminOwner);
        return CraftingV2(proxy);
    }

    function assertBalances(address player, uint256 wood, uint256 ore, uint256 swords) internal view {
        assertEq(game.balanceOf(player, 1), wood);
        assertEq(game.balanceOf(player, 2), ore);
        assertEq(game.balanceOf(player, 3), swords);
    }

    function testCraftAndEvent() public {
        fund(alice, 9, 6);
        vm.expectEmit(true, false, false, true, proxy);
        emit Crafted(alice, 2);
        vm.prank(alice);
        game.craft(2);
        assertBalances(alice, 3, 2, 2);
        assertEq(game.totalCrafted(), 2);
    }

    function testIssueRestrictions() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        game.issue(alice, 1, 1);
        vm.startPrank(owner);
        vm.expectRevert(CraftingV1.ZeroRecipient.selector);
        game.issue(address(0), 1, 1);
        vm.expectRevert(CraftingV1.ZeroAmount.selector);
        game.issue(alice, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(CraftingV1.InvalidResource.selector, 3));
        game.issue(alice, 3, 1);
        vm.expectRevert(abi.encodeWithSelector(CraftingV1.InvalidResource.selector, 99));
        game.issue(alice, 99, 1);
        vm.stopPrank();
    }

    function testZeroAmounts() public {
        vm.expectRevert(CraftingV1.ZeroAmount.selector);
        vm.prank(alice);
        game.craft(0);
        CraftingV2 v2 = upgrade();
        vm.expectRevert(CraftingV1.ZeroAmount.selector);
        vm.prank(alice);
        v2.salvage(0);
    }

    function testInsufficientWood() public {
        fund(alice, 2, 2);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 2, 3, 1));
        vm.prank(alice);
        game.craft(1);
        assertBalances(alice, 2, 2, 0);
        assertEq(game.totalCrafted(), 0);
    }

    function testInsufficientOreRollsBackWoodBurn() public {
        fund(alice, 3, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 1, 2, 2));
        vm.prank(alice);
        game.craft(1);
        assertBalances(alice, 3, 1, 0);
        assertEq(game.totalCrafted(), 0);
    }

    function testUpgradePreservesStateAndNewHolderSalvages() public {
        fund(alice, 9, 6);
        vm.startPrank(alice);
        game.craft(2);
        game.setApprovalForAll(operator, true);
        vm.stopPrank();
        address oldImplementation = Upgrades.getImplementationAddress(proxy);
        address admin = Upgrades.getAdminAddress(proxy);
        assertEq(ProxyAdmin(admin).owner(), adminOwner);
        assertTrue(owner != adminOwner);
        CraftingV2 v2 = upgrade();
        assertEq(address(v2), proxy);
        assertTrue(Upgrades.getImplementationAddress(proxy) != oldImplementation);
        assertEq(Upgrades.getAdminAddress(proxy), admin);
        assertEq(v2.owner(), owner);
        assertBalances(alice, 3, 2, 2);
        assertTrue(v2.isApprovedForAll(alice, operator));
        assertEq(v2.totalCrafted(), 2);
        assertEq(v2.totalSalvaged(), 0);
        vm.prank(operator);
        v2.safeTransferFrom(alice, bob, 3, 1, "");
        assertEq(v2.totalCrafted(), 2);
        assertEq(v2.totalSalvaged(), 0);
        vm.expectEmit(true, false, false, true, proxy);
        emit Salvaged(bob, 1);
        vm.prank(bob);
        v2.salvage(1);
        assertBalances(bob, 0, 1, 0);
        assertBalances(alice, 3, 2, 1);
        assertEq(v2.totalCrafted(), 2);
        assertEq(v2.totalSalvaged(), 1);
        vm.prank(alice);
        v2.craft(1);
        assertEq(v2.totalCrafted(), 3);
        fund(bob, 3, 2);
        assertBalances(bob, 3, 3, 0);
    }

    function testOnlyAdminOwnerCanUpgrade() public {
        address implementation = address(new CraftingV2());
        ProxyAdmin admin = ProxyAdmin(Upgrades.getAdminAddress(proxy));
        address beforeImplementation = Upgrades.getImplementationAddress(proxy);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, "");
        assertEq(Upgrades.getImplementationAddress(proxy), beforeImplementation);
        upgrade();
    }

    function testInitializersLocked() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        game.initialize(alice);
        CraftingV1 implementationV1 = CraftingV1(Upgrades.getImplementationAddress(proxy));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementationV1.initialize(alice);
        CraftingV2 v2 = upgrade();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initialize(alice);
        CraftingV2 implementationV2 = CraftingV2(Upgrades.getImplementationAddress(proxy));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementationV2.initialize(alice);
        assertEq(v2.owner(), owner);
    }

    function testRejectSwordRollsBackEverything() public {
        GameReceiver receiver = new GameReceiver(proxy);
        fund(address(receiver), 6, 4);
        receiver.configure(3, false, false);
        vm.expectRevert(bytes("item rejected"));
        receiver.craft(2);
        assertBalances(address(receiver), 6, 4, 0);
        assertEq(game.totalCrafted(), 0);
    }

    function testRejectOreRollsBackSalvage() public {
        CraftingV2 v2 = upgrade();
        GameReceiver receiver = new GameReceiver(proxy);
        fund(address(receiver), 6, 4);
        receiver.craft(2);
        receiver.configure(2, false, false);
        vm.expectRevert(bytes("item rejected"));
        receiver.salvage(2);
        assertBalances(address(receiver), 0, 0, 2);
        assertEq(v2.totalCrafted(), 2);
        assertEq(v2.totalSalvaged(), 0);
    }

    function testReceiverSeesUpdatedBalancesAndCounters() public {
        upgrade();
        GameReceiver receiver = new GameReceiver(proxy);
        fund(address(receiver), 6, 4);
        receiver.configure(0, true, false);
        receiver.craft(2);
        receiver.configure(0, false, true);
        receiver.salvage(2);
        assertBalances(address(receiver), 0, 2, 0);
    }

    function testSalvageWithoutSwordsReverts() public {
        CraftingV2 v2 = upgrade();
        fund(alice, 3, 2);
        assertBalances(alice, 3, 2, 0);
        uint256 craftedBefore = v2.totalCrafted();
        uint256 salvagedBefore = v2.totalSalvaged();

        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 0, 1, 3));
        vm.prank(alice);
        v2.salvage(1);

        assertBalances(alice, 3, 2, 0);
        assertEq(v2.totalCrafted(), craftedBefore);
        assertEq(v2.totalSalvaged(), salvagedBefore);
    }

    function testCannotUseOtherPlayersItemsEvenWithApproval() public {
        fund(alice, 3, 2);
        vm.prank(alice);
        game.setApprovalForAll(operator, true);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, operator, 0, 3, 1));
        vm.prank(operator);
        game.craft(1);
        vm.prank(alice);
        game.craft(1);
        CraftingV2 v2 = upgrade();
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, operator, 0, 1, 3));
        vm.prank(operator);
        v2.salvage(1);
        assertBalances(alice, 0, 0, 1);
        assertEq(v2.totalSalvaged(), 0);
    }

    function testBatchTransferAndApprovalRevocation() public {
        CraftingV2 v2 = upgrade();
        fund(alice, 6, 4);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        amounts[0] = 3;
        amounts[1] = 2;
        vm.prank(alice);
        game.setApprovalForAll(operator, true);
        vm.prank(operator);
        game.safeBatchTransferFrom(alice, bob, ids, amounts, "");
        assertBalances(alice, 3, 2, 0);
        assertBalances(bob, 3, 2, 0);
        vm.prank(alice);
        game.setApprovalForAll(operator, false);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, operator, alice));
        vm.prank(operator);
        game.safeTransferFrom(alice, bob, 1, 1, "");
        assertEq(v2.totalCrafted(), 0);
        assertEq(v2.totalSalvaged(), 0);
    }
}

contract CraftingFuzzTest is Test {
    address owner = makeAddr("owner");
    address alice = makeAddr("new player");
    address bob = makeAddr("existing player");
    CraftingV2 v2;

    function setUp() public {
        address adminOwner = makeAddr("admin owner");
        address proxy = Upgrades.deployTransparentProxy(
            "CraftingV1.sol", adminOwner, abi.encodeCall(CraftingV1.initialize, (owner))
        );
        Upgrades.upgradeProxy(proxy, "CraftingV2.sol", "", adminOwner);
        v2 = CraftingV2(proxy);
    }

    function fund(address player, uint256 wood, uint256 ore) internal {
        vm.startPrank(owner);
        v2.issue(player, 1, wood);
        v2.issue(player, 2, ore);
        vm.stopPrank();
    }

    function assertBalances(address player, uint256 wood, uint256 ore, uint256 swords) internal view {
        assertEq(v2.balanceOf(player, 1), wood);
        assertEq(v2.balanceOf(player, 2), ore);
        assertEq(v2.balanceOf(player, 3), swords);
    }

    function testFuzzCraftAndSalvage(uint256 rawN) public {
        uint256 n = bound(rawN, 1, 1000);
        fund(bob, 3, 2);
        vm.startPrank(bob);
        v2.craft(1);
        v2.salvage(1);
        vm.stopPrank();
        uint256 craftedBefore = v2.totalCrafted();
        uint256 salvagedBefore = v2.totalSalvaged();
        assertBalances(alice, 0, 0, 0);
        fund(alice, 3 * n, 2 * n);
        vm.startPrank(alice);
        v2.craft(n);
        v2.salvage(n);
        vm.stopPrank();
        assertBalances(alice, 0, n, 0);
        assertEq(v2.totalCrafted(), craftedBefore + n);
        assertEq(v2.totalSalvaged(), salvagedBefore + n);
    }
}
