// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

// V4 Core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// V4 Periphery
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

// Permit2
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// Solmate
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// Test utils
import {BaseTest} from "../utils/BaseTest.sol";
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";

// Local contracts
import {Treasury} from "../../src/core/Treasury.sol";
import {ITreasury} from "../../src/interfaces/ITreasury.sol";

// ============================================================================
// Treasury Unit Tests
// ============================================================================
// Ticket: T-027
// Tests for SPECIFICATION.md §4.2
// ============================================================================

contract TreasuryTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    Treasury public treasury;

    MockERC20 public baseToken;
    MockERC20 public quoteToken;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    PoolId poolId;

    address public manager = makeAddr("manager");
    address public proposalManagerAddr = makeAddr("proposalManager");
    address public alice = makeAddr("alice");

    uint256 constant ORG_ID = 1;
    uint256 constant BASE_AMOUNT = 1000e18;
    uint256 constant QUOTE_AMOUNT = 1000e18;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    // ============ Setup ============

    function setUp() public {
        // Deploy V4 infrastructure
        deployArtifactsAndLabel();

        // Deploy Treasury
        treasury = new Treasury(permit2, poolManager, positionManager);

        // Deploy tokens and mint
        baseToken = new MockERC20("Base Token", "BASE", 18);
        quoteToken = new MockERC20("Quote Token", "QUOTE", 18);

        baseToken.mint(manager, 1_000_000e18);
        quoteToken.mint(manager, 1_000_000e18);
        baseToken.mint(alice, 100_000e18);
        quoteToken.mint(alice, 100_000e18);

        // Sort tokens for V4
        if (address(baseToken) > address(quoteToken)) {
            (baseToken, quoteToken) = (quoteToken, baseToken);
        }

        currency0 = Currency.wrap(address(baseToken));
        currency1 = Currency.wrap(address(quoteToken));

        // Create pool key
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        // Initialize pool in V4
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Initialize treasury
        treasury.initialize(
            ORG_ID,
            manager,
            address(baseToken),
            address(quoteToken),
            address(positionManager)
        );

        // Set proposal manager
        vm.prank(manager);
        treasury.setProposalManager(proposalManagerAddr);

        // Approve tokens to treasury from manager
        vm.startPrank(manager);
        baseToken.approve(address(treasury), type(uint256).max);
        quoteToken.approve(address(treasury), type(uint256).max);
        vm.stopPrank();

        // Approve tokens to treasury from alice
        vm.startPrank(alice);
        baseToken.approve(address(treasury), type(uint256).max);
        quoteToken.approve(address(treasury), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsPermit2() public view {
        assertEq(address(treasury.permit2()), address(permit2));
    }

    function test_Constructor_SetsPoolManager() public view {
        assertEq(address(treasury.poolManager()), address(poolManager));
    }

    function test_Constructor_SetsPositionManager() public view {
        assertEq(address(treasury.positionManager()), address(positionManager));
    }

    function testRevert_Constructor_ZeroPermit2() public {
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        new Treasury(
            IAllowanceTransfer(address(0)),
            poolManager,
            positionManager
        );
    }

    function testRevert_Constructor_ZeroPoolManager() public {
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        new Treasury(permit2, IPoolManager(address(0)), positionManager);
    }

    function testRevert_Constructor_ZeroPositionManager() public {
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        new Treasury(permit2, poolManager, IPositionManager(address(0)));
    }

    // ============ Initialize Tests ============

    function test_Initialize_SetsOrgId() public view {
        assertEq(treasury.orgId(), ORG_ID);
    }

    function test_Initialize_SetsManager() public view {
        assertEq(treasury.manager(), manager);
    }

    function test_Initialize_SetsBaseToken() public view {
        assertEq(treasury.baseToken(), address(baseToken));
    }

    function test_Initialize_SetsQuoteToken() public view {
        assertEq(treasury.quoteToken(), address(quoteToken));
    }

    function test_Initialize_SetsInitialized() public view {
        assertTrue(treasury.initialized());
    }

    function testRevert_Initialize_AlreadyInitialized() public {
        vm.expectRevert(ITreasury.AlreadyInitialized.selector);
        treasury.initialize(
            2,
            manager,
            address(baseToken),
            address(quoteToken),
            address(positionManager)
        );
    }

    function testRevert_Initialize_ZeroManager() public {
        Treasury newTreasury = new Treasury(
            permit2,
            poolManager,
            positionManager
        );
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        newTreasury.initialize(
            ORG_ID,
            address(0),
            address(baseToken),
            address(quoteToken),
            address(positionManager)
        );
    }

    function testRevert_Initialize_ZeroBaseToken() public {
        Treasury newTreasury = new Treasury(
            permit2,
            poolManager,
            positionManager
        );
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        newTreasury.initialize(
            ORG_ID,
            manager,
            address(0),
            address(quoteToken),
            address(positionManager)
        );
    }

    function testRevert_Initialize_ZeroQuoteToken() public {
        Treasury newTreasury = new Treasury(
            permit2,
            poolManager,
            positionManager
        );
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        newTreasury.initialize(
            ORG_ID,
            manager,
            address(baseToken),
            address(0),
            address(positionManager)
        );
    }

    // ============ setProposalManager Tests ============

    function test_SetProposalManager_Success() public {
        Treasury newTreasury = new Treasury(
            permit2,
            poolManager,
            positionManager
        );
        newTreasury.initialize(
            ORG_ID,
            manager,
            address(baseToken),
            address(quoteToken),
            address(positionManager)
        );

        vm.prank(manager);
        newTreasury.setProposalManager(alice);
        assertEq(newTreasury.proposalManager(), alice);
    }

    function testRevert_SetProposalManager_NotManager() public {
        vm.expectRevert(ITreasury.NotOrganizationManager.selector);
        vm.prank(alice);
        treasury.setProposalManager(alice);
    }

    function testRevert_SetProposalManager_ZeroAddress() public {
        Treasury newTreasury = new Treasury(
            permit2,
            poolManager,
            positionManager
        );
        newTreasury.initialize(
            ORG_ID,
            manager,
            address(baseToken),
            address(quoteToken),
            address(positionManager)
        );

        vm.expectRevert(ITreasury.ZeroAddress.selector);
        vm.prank(manager);
        newTreasury.setProposalManager(address(0));
    }

    // ============ Deposit Tests ============

    function test_Deposit_BaseToken() public {
        uint256 amount = 100e18;

        vm.prank(alice);
        treasury.deposit(address(baseToken), amount);

        assertEq(treasury.getBalance(address(baseToken)), amount);
    }

    function test_Deposit_QuoteToken() public {
        uint256 amount = 100e18;

        vm.prank(alice);
        treasury.deposit(address(quoteToken), amount);

        assertEq(treasury.getBalance(address(quoteToken)), amount);
    }

    function test_Deposit_EmitsEvent() public {
        uint256 amount = 100e18;

        vm.expectEmit(true, true, false, true);
        emit ITreasury.Deposited(address(baseToken), alice, amount);

        vm.prank(alice);
        treasury.deposit(address(baseToken), amount);
    }

    function testRevert_Deposit_InvalidToken() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(alice, 1000e18);

        vm.startPrank(alice);
        randomToken.approve(address(treasury), type(uint256).max);

        vm.expectRevert(ITreasury.InvalidToken.selector);
        treasury.deposit(address(randomToken), 100e18);
        vm.stopPrank();
    }

    function testRevert_Deposit_NotInitialized() public {
        Treasury newTreasury = new Treasury(
            permit2,
            poolManager,
            positionManager
        );

        vm.expectRevert(ITreasury.NotInitialized.selector);
        newTreasury.deposit(address(baseToken), 100e18);
    }

    // ============ createSpotPosition Tests ============

    function test_CreateSpotPosition_Success() public {
        // Deposit tokens first
        vm.startPrank(manager);
        treasury.deposit(address(baseToken), BASE_AMOUNT);
        treasury.deposit(address(quoteToken), QUOTE_AMOUNT);

        // Create position
        treasury.createSpotPosition(BASE_AMOUNT, QUOTE_AMOUNT, poolKey);
        vm.stopPrank();

        // Verify position was created
        assertGt(treasury.spotPositionTokenId(), 0);
        assertGt(treasury.getSpotPositionLiquidity(), 0);
    }

    function test_CreateSpotPosition_EmitsEvent() public {
        // Deposit tokens first
        vm.startPrank(manager);
        treasury.deposit(address(baseToken), BASE_AMOUNT);
        treasury.deposit(address(quoteToken), QUOTE_AMOUNT);

        uint256 expectedTokenId = positionManager.nextTokenId();

        vm.expectEmit(true, false, false, false);
        emit ITreasury.SpotPositionCreated(
            expectedTokenId,
            BASE_AMOUNT,
            QUOTE_AMOUNT
        );

        treasury.createSpotPosition(BASE_AMOUNT, QUOTE_AMOUNT, poolKey);
        vm.stopPrank();
    }

    function testRevert_CreateSpotPosition_NotManager() public {
        vm.expectRevert(ITreasury.NotOrganizationManager.selector);
        vm.prank(alice);
        treasury.createSpotPosition(BASE_AMOUNT, QUOTE_AMOUNT, poolKey);
    }

    function testRevert_CreateSpotPosition_AlreadyExists() public {
        // Create first position
        vm.startPrank(manager);
        treasury.deposit(address(baseToken), BASE_AMOUNT * 2);
        treasury.deposit(address(quoteToken), QUOTE_AMOUNT * 2);
        treasury.createSpotPosition(BASE_AMOUNT, QUOTE_AMOUNT, poolKey);

        // Try to create another
        vm.expectRevert(ITreasury.SpotPositionExists.selector);
        treasury.createSpotPosition(BASE_AMOUNT, QUOTE_AMOUNT, poolKey);
        vm.stopPrank();
    }

    // ============ withdrawLiquidityForProposal Tests ============

    function test_WithdrawLiquidityForProposal_Success() public {
        // Create position
        vm.startPrank(manager);
        treasury.deposit(address(baseToken), BASE_AMOUNT);
        treasury.deposit(address(quoteToken), QUOTE_AMOUNT);
        treasury.createSpotPosition(BASE_AMOUNT, QUOTE_AMOUNT, poolKey);
        vm.stopPrank();

        uint128 liquidityBefore = treasury.getSpotPositionLiquidity();

        // Withdraw 50%
        vm.prank(proposalManagerAddr);
        (uint256 baseWithdrawn, uint256 quoteWithdrawn) = treasury
            .withdrawLiquidityForProposal(5000);

        uint128 liquidityAfter = treasury.getSpotPositionLiquidity();

        // Verify liquidity decreased
        assertLt(liquidityAfter, liquidityBefore);
        assertGt(baseWithdrawn, 0);
        assertGt(quoteWithdrawn, 0);
    }

    function test_WithdrawLiquidityForProposal_EmitsEvent() public {
        // Create position
        vm.startPrank(manager);
        treasury.deposit(address(baseToken), BASE_AMOUNT);
        treasury.deposit(address(quoteToken), QUOTE_AMOUNT);
        treasury.createSpotPosition(BASE_AMOUNT, QUOTE_AMOUNT, poolKey);
        vm.stopPrank();

        vm.expectEmit(false, false, false, false);
        emit ITreasury.LiquidityWithdrawn(0, 0); // amounts vary

        vm.prank(proposalManagerAddr);
        treasury.withdrawLiquidityForProposal(5000);
    }

    function testRevert_WithdrawLiquidityForProposal_NotProposalManager()
        public
    {
        vm.expectRevert(ITreasury.NotProposalManager.selector);
        vm.prank(alice);
        treasury.withdrawLiquidityForProposal(5000);
    }

    function testRevert_WithdrawLiquidityForProposal_NoPosition() public {
        vm.expectRevert(ITreasury.NoSpotPosition.selector);
        vm.prank(proposalManagerAddr);
        treasury.withdrawLiquidityForProposal(5000);
    }

    // ============ addLiquidityAfterResolution Tests ============

    function test_AddLiquidityAfterResolution_Success() public {
        // Create and withdraw
        vm.startPrank(manager);
        treasury.deposit(address(baseToken), BASE_AMOUNT);
        treasury.deposit(address(quoteToken), QUOTE_AMOUNT);
        treasury.createSpotPosition(BASE_AMOUNT, QUOTE_AMOUNT, poolKey);
        vm.stopPrank();

        vm.prank(proposalManagerAddr);
        (uint256 baseWithdrawn, uint256 quoteWithdrawn) = treasury
            .withdrawLiquidityForProposal(5000);

        uint128 liquidityAfterWithdraw = treasury.getSpotPositionLiquidity();

        // Add liquidity back
        vm.prank(proposalManagerAddr);
        treasury.addLiquidityAfterResolution(baseWithdrawn, quoteWithdrawn);

        uint128 liquidityAfterAdd = treasury.getSpotPositionLiquidity();

        // Verify liquidity increased
        assertGt(liquidityAfterAdd, liquidityAfterWithdraw);
    }

    function testRevert_AddLiquidityAfterResolution_NotProposalManager()
        public
    {
        vm.expectRevert(ITreasury.NotProposalManager.selector);
        vm.prank(alice);
        treasury.addLiquidityAfterResolution(100e18, 100e18);
    }

    function testRevert_AddLiquidityAfterResolution_NoPosition() public {
        vm.expectRevert(ITreasury.NoSpotPosition.selector);
        vm.prank(proposalManagerAddr);
        treasury.addLiquidityAfterResolution(100e18, 100e18);
    }

    // ============ execute Tests ============

    function test_Execute_Success() public {
        // Fund treasury with ETH
        vm.deal(address(treasury), 1 ether);

        // Execute a simple transfer
        vm.prank(proposalManagerAddr);
        treasury.execute(alice, "", 0.5 ether);

        assertEq(alice.balance, 0.5 ether);
    }

    function test_Execute_CallContract() public {
        // Execute a token mint (calling baseToken.mint)
        bytes memory data = abi.encodeWithSelector(
            MockERC20.mint.selector,
            alice,
            1000e18
        );

        vm.prank(proposalManagerAddr);
        treasury.execute(address(baseToken), data, 0);

        // Alice should have received tokens
        assertGt(baseToken.balanceOf(alice), 100_000e18); // More than initial
    }

    function test_Execute_EmitsEvent() public {
        vm.deal(address(treasury), 1 ether);

        vm.expectEmit(true, false, false, false);
        emit ITreasury.ProposalExecuted(alice, "", 0.1 ether, "");

        vm.prank(proposalManagerAddr);
        treasury.execute(alice, "", 0.1 ether);
    }

    function testRevert_Execute_NotProposalManager() public {
        vm.expectRevert(ITreasury.NotProposalManager.selector);
        vm.prank(alice);
        treasury.execute(alice, "", 0);
    }

    function testRevert_Execute_CallFails() public {
        // Try to call a non-existent function
        bytes memory badData = abi.encodeWithSelector(
            bytes4(keccak256("nonExistentFunction()"))
        );

        vm.prank(proposalManagerAddr);
        vm.expectRevert(); // Will revert with ExecutionFailed
        treasury.execute(address(baseToken), badData, 0);
    }

    // ============ View Function Tests ============

    function test_GetBalance_ReturnsCorrectAmount() public {
        uint256 amount = 500e18;

        vm.prank(alice);
        treasury.deposit(address(baseToken), amount);

        assertEq(treasury.getBalance(address(baseToken)), amount);
    }

    function test_GetSpotPositionLiquidity_ReturnsZeroWithoutPosition()
        public
        view
    {
        assertEq(treasury.getSpotPositionLiquidity(), 0);
    }

    function test_GetSpotPositionAmounts_ReturnsZeroWithoutPosition()
        public
        view
    {
        (uint256 baseAmount, uint256 quoteAmount) = treasury
            .getSpotPositionAmounts();
        assertEq(baseAmount, 0);
        assertEq(quoteAmount, 0);
    }

    function test_GetSpotPositionAmounts_ReturnsCorrectAmounts() public {
        // Create position
        vm.startPrank(manager);
        treasury.deposit(address(baseToken), BASE_AMOUNT);
        treasury.deposit(address(quoteToken), QUOTE_AMOUNT);
        treasury.createSpotPosition(BASE_AMOUNT, QUOTE_AMOUNT, poolKey);
        vm.stopPrank();

        (uint256 baseAmount, uint256 quoteAmount) = treasury
            .getSpotPositionAmounts();

        // Amounts should be close to initial (might not be exact due to rounding)
        assertGt(baseAmount, (BASE_AMOUNT * 99) / 100);
        assertGt(quoteAmount, (QUOTE_AMOUNT * 99) / 100);
    }
}
