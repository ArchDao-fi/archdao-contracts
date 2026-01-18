// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ConditionalToken} from "../../src/tokens/ConditionalToken.sol";
import {IConditionalToken} from "../../src/interfaces/IConditionalToken.sol";

// ============================================================================
// ConditionalToken Unit Tests
// ============================================================================
// Ticket: T-018
// Tests for SPECIFICATION.md §4.5
// Uses OpenZeppelin AccessControl for RBAC
// ============================================================================

contract ConditionalTokenTest is Test {
    ConditionalToken public pToken;
    ConditionalToken public fToken;

    address public minter = makeAddr("minter");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public MINTER_ROLE;

    uint8 constant DECIMALS_18 = 18;

    // ============ Setup ============

    function setUp() public {
        // Deploy pass token with 18 decimals
        pToken = new ConditionalToken(
            "pToken-ARCH-42",
            "pARCH-42",
            DECIMALS_18,
            minter
        );

        // Deploy fail token with 18 decimals
        fToken = new ConditionalToken(
            "fToken-ARCH-42",
            "fARCH-42",
            DECIMALS_18,
            minter
        );

        MINTER_ROLE = pToken.MINTER_ROLE();
    }

    // ============ Constructor Tests ============


    function test_Constructor_GrantsMinterRole() public view {
        assertTrue(pToken.hasRole(MINTER_ROLE, minter));
        assertTrue(fToken.hasRole(MINTER_ROLE, minter));
    }

    function test_Constructor_SetsNameAndSymbol() public view {
        assertEq(pToken.name(), "pToken-ARCH-42");
        assertEq(pToken.symbol(), "pARCH-42");
        assertEq(fToken.name(), "fToken-ARCH-42");
        assertEq(fToken.symbol(), "fARCH-42");
    }

    function test_Constructor_SetsDecimals_18() public view {
        assertEq(pToken.decimals(), 18);
        assertEq(fToken.decimals(), 18);
    }

    function test_Constructor_SetsDecimals_6() public {
        ConditionalToken pQuote = new ConditionalToken(
            "pQuote-USDC-42",
            "pUSDC-42",
            6,
            minter
        );

        assertEq(pQuote.decimals(), 6);
    }

    function test_Constructor_SetsDecimals_8() public {
        ConditionalToken pBtc = new ConditionalToken(
            "pToken-WBTC-42",
            "pWBTC-42",
            8,
            minter
        );

        assertEq(pBtc.decimals(), 8);
    }

    // ============ Mint Tests ============

    function test_Mint_Success() public {
        vm.prank(minter);
        pToken.mint(alice, 1000e18);

        assertEq(pToken.balanceOf(alice), 1000e18);
        assertEq(pToken.totalSupply(), 1000e18);
    }

    function test_Mint_MultipleMints() public {
        vm.startPrank(minter);
        pToken.mint(alice, 1000e18);
        pToken.mint(bob, 2000e18);
        pToken.mint(alice, 500e18);
        vm.stopPrank();

        assertEq(pToken.balanceOf(alice), 1500e18);
        assertEq(pToken.balanceOf(bob), 2000e18);
        assertEq(pToken.totalSupply(), 3500e18);
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
        pToken.mint(alice, 1000e18);
    }

    // ============ Burn Tests ============

    function test_Burn_Success() public {
        // Setup: mint tokens
        vm.prank(minter);
        pToken.mint(alice, 1000e18);

        // Admin burns alice's tokens (ProposalManager controlled)
        vm.prank(minter);
        pToken.burn(alice, 500e18);

        assertEq(pToken.balanceOf(alice), 500e18);
        assertEq(pToken.totalSupply(), 500e18);
    }

    function test_Burn_AllTokens() public {
        vm.prank(minter);
        pToken.mint(alice, 1000e18);

        vm.prank(minter);
        pToken.burn(alice, 1000e18);

        assertEq(pToken.balanceOf(alice), 0);
        assertEq(pToken.totalSupply(), 0);
    }

    function testRevert_Burn_NotMinter() public {
        vm.prank(minter);
        pToken.mint(alice, 1000e18);

        // Alice cannot burn her own tokens directly
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                MINTER_ROLE
            )
        );
        pToken.burn(alice, 500e18);
    }

    function testRevert_Burn_InsufficientBalance() public {
        vm.prank(minter);
        pToken.mint(alice, 1000e18);

        vm.prank(minter);
        vm.expectRevert(); // ERC20 insufficient balance error
        pToken.burn(alice, 1001e18);
    }

    // ============ Role Management Tests ============




    // ============ ERC20 Standard Tests ============

    function test_Transfer_Success() public {
        vm.prank(minter);
        pToken.mint(alice, 1000e18);

        vm.prank(alice);
        pToken.transfer(bob, 400e18);

        assertEq(pToken.balanceOf(alice), 600e18);
        assertEq(pToken.balanceOf(bob), 400e18);
    }

    function test_Approve_Success() public {
        vm.prank(alice);
        pToken.approve(bob, 1000e18);

        assertEq(pToken.allowance(alice, bob), 1000e18);
    }

    function test_TransferFrom_Success() public {
        vm.prank(minter);
        pToken.mint(alice, 1000e18);

        vm.prank(alice);
        pToken.approve(bob, 500e18);

        vm.prank(bob);
        pToken.transferFrom(alice, bob, 500e18);

        assertEq(pToken.balanceOf(alice), 500e18);
        assertEq(pToken.balanceOf(bob), 500e18);
    }

    // ============ Pass vs Fail Token Behavior ============

    function test_PassAndFailTokensIndependent() public {
        // Mint pass tokens
        vm.startPrank(minter);
        pToken.mint(alice, 1000e18);
        fToken.mint(alice, 1000e18);
        vm.stopPrank();

        // Both have independent supplies
        assertEq(pToken.totalSupply(), 1000e18);
        assertEq(fToken.totalSupply(), 1000e18);

        // Burn some pass tokens
        vm.prank(minter);
        pToken.burn(alice, 300e18);

        // Pass supply changed, fail unchanged
        assertEq(pToken.totalSupply(), 700e18);
        assertEq(fToken.totalSupply(), 1000e18);
    }

    // ============ Fuzz Tests ============

    function testFuzz_Mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 1, type(uint128).max);

        vm.prank(minter);
        pToken.mint(to, amount);

        assertEq(pToken.balanceOf(to), amount);
        assertEq(pToken.totalSupply(), amount);
    }

    function testFuzz_Burn(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        burnAmount = bound(burnAmount, 1, mintAmount);

        vm.prank(minter);
        pToken.mint(alice, mintAmount);

        vm.prank(minter);
        pToken.burn(alice, burnAmount);

        assertEq(pToken.balanceOf(alice), mintAmount - burnAmount);
        assertEq(pToken.totalSupply(), mintAmount - burnAmount);
    }

    function testFuzz_Transfer(uint256 amount, uint256 transferAmount) public {
        amount = bound(amount, 1, type(uint128).max);
        transferAmount = bound(transferAmount, 1, amount);

        vm.prank(minter);
        pToken.mint(alice, amount);

        vm.prank(alice);
        pToken.transfer(bob, transferAmount);

        assertEq(pToken.balanceOf(alice), amount - transferAmount);
        assertEq(pToken.balanceOf(bob), transferAmount);
    }

    function testFuzz_Decimals(uint8 decimals_) public {
        decimals_ = uint8(bound(decimals_, 0, 24));

        ConditionalToken customToken = new ConditionalToken(
            "pToken-CUST",
            "pCUST",
            decimals_,
            minter
        );

        assertEq(customToken.decimals(), decimals_);
    }

    // ============ Constants Tests ============

    function test_MinterRole_IsCorrect() public view {
        assertEq(MINTER_ROLE, keccak256("MINTER_ROLE"));
    }
}
