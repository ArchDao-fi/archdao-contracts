// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {GovernanceToken} from "../../src/tokens/GovernanceToken.sol";
import {IGovernanceToken} from "../../src/interfaces/IGovernanceToken.sol";

// ============================================================================
// GovernanceToken Unit Tests
// ============================================================================
// Ticket: T-016
// Tests for SPECIFICATION.md §4.8
// Uses OpenZeppelin AccessControl for RBAC
// ============================================================================

contract GovernanceTokenTest is Test {
    GovernanceToken public token;

    address public minter = makeAddr("minter");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public MINTER_ROLE;

    string constant NAME = "ArchDAO Token";
    string constant SYMBOL = "ARCH";

    // ============ Setup ============

    function setUp() public {
        token = new GovernanceToken(NAME, SYMBOL, minter);
        MINTER_ROLE = token.MINTER_ROLE();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsNameAndSymbol() public view {
        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
    }


    function test_Constructor_GrantsMinterRole() public view {
        assertTrue(token.hasRole(MINTER_ROLE, minter));
    }

    function test_Constructor_SetsDecimals() public view {
        assertEq(token.decimals(), 18);
    }

    function test_Constructor_InitialSupplyIsZero() public view {
        assertEq(token.totalSupply(), 0);
    }

    // ============ Mint Tests ============

    function test_Mint_Success() public {
        vm.prank(minter);
        token.mint(alice, 1000e18);

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.totalSupply(), 1000e18);
    }

    function test_Mint_MultipleMints() public {
        vm.startPrank(minter);
        token.mint(alice, 1000e18);
        token.mint(bob, 2000e18);
        token.mint(alice, 500e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 1500e18);
        assertEq(token.balanceOf(bob), 2000e18);
        assertEq(token.totalSupply(), 3500e18);
    }

    function testRevert_Mint_NotMinter() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                MINTER_ROLE
            )
        );
        token.mint(alice, 1000e18);
    }

    function testRevert_Mint_ExceedsMaxSupply() public {
        uint256 maxSupply = token.MAX_SUPPLY();

        vm.startPrank(minter);

        // Mint up to max supply
        token.mint(alice, maxSupply);
        assertEq(token.totalSupply(), maxSupply);

        // Try to mint 1 more wei
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceToken.ExceedsMaxSupply.selector,
                maxSupply + 1,
                maxSupply
            )
        );
        token.mint(bob, 1);

        vm.stopPrank();
    }

    function test_Mint_ExactlyMaxSupply() public {
        uint256 maxSupply = token.MAX_SUPPLY();

        vm.prank(minter);
        token.mint(alice, maxSupply);

        assertEq(token.totalSupply(), maxSupply);
        assertEq(token.balanceOf(alice), maxSupply);
    }

    // ============ Burn Tests ============

    function test_Burn_Success() public {
        // Setup: mint tokens
        vm.prank(minter);
        token.mint(alice, 1000e18);

        // Alice burns half
        vm.prank(alice);
        token.burn(500e18);

        assertEq(token.balanceOf(alice), 500e18);
        assertEq(token.totalSupply(), 500e18);
    }

    function test_Burn_AllTokens() public {
        vm.prank(minter);
        token.mint(alice, 1000e18);

        vm.prank(alice);
        token.burn(1000e18);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function testRevert_Burn_InsufficientBalance() public {
        vm.prank(minter);
        token.mint(alice, 1000e18);

        vm.prank(alice);
        vm.expectRevert(); // ERC20 insufficient balance error
        token.burn(1001e18);
    }

    // ============ Role Management Tests ============





    // ============ ERC20 Standard Tests ============

    function test_Transfer_Success() public {
        vm.prank(minter);
        token.mint(alice, 1000e18);

        vm.prank(alice);
        token.transfer(bob, 400e18);

        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.balanceOf(bob), 400e18);
    }

    function test_Approve_Success() public {
        vm.prank(alice);
        token.approve(bob, 1000e18);

        assertEq(token.allowance(alice, bob), 1000e18);
    }

    function test_TransferFrom_Success() public {
        vm.prank(minter);
        token.mint(alice, 1000e18);

        vm.prank(alice);
        token.approve(bob, 500e18);

        vm.prank(bob);
        token.transferFrom(alice, bob, 500e18);

        assertEq(token.balanceOf(alice), 500e18);
        assertEq(token.balanceOf(bob), 500e18);
    }

    // ============ Fuzz Tests ============

    function testFuzz_Mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        uint256 maxSupply = token.MAX_SUPPLY();
        amount = bound(amount, 1, maxSupply);

        vm.prank(minter);
        token.mint(to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testFuzz_Burn(uint256 mintAmount, uint256 burnAmount) public {
        uint256 maxSupply = token.MAX_SUPPLY();
        mintAmount = bound(mintAmount, 1, maxSupply);
        burnAmount = bound(burnAmount, 1, mintAmount);

        vm.prank(minter);
        token.mint(alice, mintAmount);

        vm.prank(alice);
        token.burn(burnAmount);

        assertEq(token.balanceOf(alice), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function testFuzz_Transfer(uint256 amount, uint256 transferAmount) public {
        uint256 maxSupply = token.MAX_SUPPLY();
        amount = bound(amount, 1, maxSupply);
        transferAmount = bound(transferAmount, 1, amount);

        vm.prank(minter);
        token.mint(alice, amount);

        vm.prank(alice);
        token.transfer(bob, transferAmount);

        assertEq(token.balanceOf(alice), amount - transferAmount);
        assertEq(token.balanceOf(bob), transferAmount);
    }

    // ============ Constants Tests ============

    function test_MaxSupply_IsOneBillion() public view {
        assertEq(token.MAX_SUPPLY(), 1_000_000_000e18);
    }

    function test_MinterRole_IsCorrect() public view {
        assertEq(MINTER_ROLE, keccak256("MINTER_ROLE"));
    }
}
