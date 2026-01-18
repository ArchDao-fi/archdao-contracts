// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

// V4 Core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// V4 Periphery
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

// Permit2
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// Test utils
import {BaseTest} from "../utils/BaseTest.sol";
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";

// Local contracts
import {DecisionMarketManager} from "../../src/markets/DecisionMarketManager.sol";
import {LaggingTWAPHook} from "../../src/markets/LaggingTWAPHook.sol";
import {ConditionalToken} from "../../src/tokens/ConditionalToken.sol";
import {IDecisionMarketManager} from "../../src/interfaces/IDecisionMarketManager.sol";
import {ILaggingTWAPHook} from "../../src/interfaces/ILaggingTWAPHook.sol";
import {ConditionalTokenSet} from "../../src/types/ProposalTypes.sol";

// ============================================================================
// DecisionMarketManager Unit Tests
// ============================================================================
// Ticket: T-024
// Tests for SPECIFICATION.md §4.6
// ============================================================================

contract DecisionMarketManagerTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    DecisionMarketManager public dmm;
    LaggingTWAPHook public twapHook;

    // Conditional tokens for a proposal
    ConditionalToken public pToken;
    ConditionalToken public fToken;
    ConditionalToken public pQuote;
    ConditionalToken public fQuote;

    address public proposalManager = makeAddr("proposalManager");
    address public alice = makeAddr("alice");

    uint256 constant PROPOSAL_ID = 1;
    uint256 constant BASE_AMOUNT = 1000e18;
    uint256 constant QUOTE_AMOUNT = 1000e18; // Same decimals for simplicity
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    // ============ Setup ============

    function setUp() public {
        // Deploy V4 infrastructure (from BaseTest)
        deployArtifactsAndLabel();

        // Deploy TWAP hook with correct flags
        address hookAddress = address(
            uint160(Hooks.AFTER_SWAP_FLAG) ^ (0x4445 << 144)
        );

        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo(
            "LaggingTWAPHook.sol:LaggingTWAPHook",
            constructorArgs,
            hookAddress
        );
        twapHook = LaggingTWAPHook(hookAddress);

        // Deploy DecisionMarketManager
        dmm = new DecisionMarketManager(
            permit2,
            poolManager,
            positionManager,
            ILaggingTWAPHook(address(twapHook))
        );

        // Configure hook to accept DMM
        twapHook.setDecisionMarketManager(address(dmm));

        // Set proposal manager
        dmm.setProposalManager(proposalManager);

        // Deploy conditional tokens (minter = proposalManager for testing)
        pToken = new ConditionalToken(
            "pToken-TEST-1",
            "pTEST-1",
            18,
            proposalManager
        );
        fToken = new ConditionalToken(
            "fToken-TEST-1",
            "fTEST-1",
            18,
            proposalManager
        );
        pQuote = new ConditionalToken(
            "pQuote-USDC-1",
            "pUSDC-1",
            18,
            proposalManager
        );
        fQuote = new ConditionalToken(
            "fQuote-USDC-1",
            "fUSDC-1",
            18,
            proposalManager
        );

        // Mint conditional tokens to proposalManager for liquidity
        vm.startPrank(proposalManager);
        pToken.mint(proposalManager, BASE_AMOUNT);
        fToken.mint(proposalManager, BASE_AMOUNT);
        pQuote.mint(proposalManager, QUOTE_AMOUNT);
        fQuote.mint(proposalManager, QUOTE_AMOUNT);

        // Approve DMM to spend tokens
        pToken.approve(address(dmm), type(uint256).max);
        fToken.approve(address(dmm), type(uint256).max);
        pQuote.approve(address(dmm), type(uint256).max);
        fQuote.approve(address(dmm), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsPermit2() public view {
        assertEq(address(dmm.permit2()), address(permit2));
    }

    function test_Constructor_SetsPoolManager() public view {
        assertEq(address(dmm.poolManager()), address(poolManager));
    }

    function test_Constructor_SetsPositionManager() public view {
        assertEq(address(dmm.positionManager()), address(positionManager));
    }

    function test_Constructor_SetsTwapHook() public view {
        assertEq(address(dmm.twapHook()), address(twapHook));
    }

    function testRevert_Constructor_ZeroPermit2() public {
        vm.expectRevert(IDecisionMarketManager.ZeroAddress.selector);
        new DecisionMarketManager(
            IAllowanceTransfer(address(0)),
            poolManager,
            positionManager,
            ILaggingTWAPHook(address(twapHook))
        );
    }

    function testRevert_Constructor_ZeroPoolManager() public {
        vm.expectRevert(IDecisionMarketManager.ZeroAddress.selector);
        new DecisionMarketManager(
            permit2,
            IPoolManager(address(0)),
            positionManager,
            ILaggingTWAPHook(address(twapHook))
        );
    }

    function testRevert_Constructor_ZeroPositionManager() public {
        vm.expectRevert(IDecisionMarketManager.ZeroAddress.selector);
        new DecisionMarketManager(
            permit2,
            poolManager,
            IPositionManager(address(0)),
            ILaggingTWAPHook(address(twapHook))
        );
    }

    function testRevert_Constructor_ZeroTwapHook() public {
        vm.expectRevert(IDecisionMarketManager.ZeroAddress.selector);
        new DecisionMarketManager(
            permit2,
            poolManager,
            positionManager,
            ILaggingTWAPHook(address(0))
        );
    }

    // ============ setProposalManager Tests ============

    function test_SetProposalManager_Success() public {
        DecisionMarketManager newDmm = new DecisionMarketManager(
            permit2,
            poolManager,
            positionManager,
            ILaggingTWAPHook(address(twapHook))
        );

        newDmm.setProposalManager(alice);
        assertEq(newDmm.proposalManager(), alice);
    }

    function testRevert_SetProposalManager_ZeroAddress() public {
        DecisionMarketManager newDmm = new DecisionMarketManager(
            permit2,
            poolManager,
            positionManager,
            ILaggingTWAPHook(address(twapHook))
        );

        vm.expectRevert(IDecisionMarketManager.ZeroAddress.selector);
        newDmm.setProposalManager(address(0));
    }

    function testRevert_SetProposalManager_AlreadySet() public {
        // proposalManager already set in setUp
        vm.expectRevert(
            abi.encodeWithSelector(
                IDecisionMarketManager.MarketsAlreadyInitialized.selector,
                0
            )
        );
        dmm.setProposalManager(alice);
    }

    // ============ initializeMarkets Tests ============

    function test_InitializeMarkets_Success() public {
        ConditionalTokenSet memory tokens = ConditionalTokenSet({
            pToken: address(pToken),
            fToken: address(fToken),
            pQuote: address(pQuote),
            fQuote: address(fQuote)
        });

        uint256 twapStartTime = block.timestamp + 1 days;
        uint256 maxRateBps = 8; // ~72%/day

        vm.prank(proposalManager);
        PoolKey[2] memory poolKeys = dmm.initializeMarkets(
            PROPOSAL_ID,
            tokens,
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            SQRT_PRICE_1_1,
            maxRateBps,
            twapStartTime
        );

        // Verify markets are initialized
        assertTrue(dmm.marketsInitialized(PROPOSAL_ID));

        // Verify pool keys are set
        PoolKey[2] memory storedKeys = dmm.getPoolKeys(PROPOSAL_ID);
        assertEq(
            Currency.unwrap(storedKeys[0].currency0),
            Currency.unwrap(poolKeys[0].currency0)
        );
        assertEq(
            Currency.unwrap(storedKeys[1].currency0),
            Currency.unwrap(poolKeys[1].currency0)
        );

        // Verify position IDs are set
        uint256[2] memory positionIds = dmm.getPositionIds(PROPOSAL_ID);
        assertTrue(positionIds[0] > 0);
        assertTrue(positionIds[1] > 0);
    }

    function test_InitializeMarkets_EmitsEvent() public {
        ConditionalTokenSet memory tokens = ConditionalTokenSet({
            pToken: address(pToken),
            fToken: address(fToken),
            pQuote: address(pQuote),
            fQuote: address(fQuote)
        });

        vm.prank(proposalManager);
        vm.expectEmit(true, false, false, false);
        emit IDecisionMarketManager.MarketsInitialized(
            PROPOSAL_ID,
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            }),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            })
        );

        dmm.initializeMarkets(
            PROPOSAL_ID,
            tokens,
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            SQRT_PRICE_1_1,
            8,
            block.timestamp + 1 days
        );
    }

    function testRevert_InitializeMarkets_NotProposalManager() public {
        ConditionalTokenSet memory tokens = ConditionalTokenSet({
            pToken: address(pToken),
            fToken: address(fToken),
            pQuote: address(pQuote),
            fQuote: address(fQuote)
        });

        vm.prank(alice);
        vm.expectRevert(IDecisionMarketManager.NotProposalManager.selector);
        dmm.initializeMarkets(
            PROPOSAL_ID,
            tokens,
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            SQRT_PRICE_1_1,
            8,
            block.timestamp + 1 days
        );
    }

    function testRevert_InitializeMarkets_AlreadyInitialized() public {
        ConditionalTokenSet memory tokens = ConditionalTokenSet({
            pToken: address(pToken),
            fToken: address(fToken),
            pQuote: address(pQuote),
            fQuote: address(fQuote)
        });

        // First init succeeds
        vm.prank(proposalManager);
        dmm.initializeMarkets(
            PROPOSAL_ID,
            tokens,
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            SQRT_PRICE_1_1,
            8,
            block.timestamp + 1 days
        );

        // Mint more tokens for second attempt
        vm.startPrank(proposalManager);
        pToken.mint(proposalManager, BASE_AMOUNT);
        fToken.mint(proposalManager, BASE_AMOUNT);
        pQuote.mint(proposalManager, QUOTE_AMOUNT);
        fQuote.mint(proposalManager, QUOTE_AMOUNT);

        // Second init fails
        vm.expectRevert(
            abi.encodeWithSelector(
                IDecisionMarketManager.MarketsAlreadyInitialized.selector,
                PROPOSAL_ID
            )
        );
        dmm.initializeMarkets(
            PROPOSAL_ID,
            tokens,
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            SQRT_PRICE_1_1,
            8,
            block.timestamp + 1 days
        );
        vm.stopPrank();
    }

    // ============ removeLiquidity Tests ============

    function test_RemoveLiquidity_Success() public {
        // Setup: initialize markets first
        _initializeMarketsForProposal(PROPOSAL_ID);

        vm.prank(proposalManager);
        (
            uint256 pTokenAmount,
            uint256 pQuoteAmount,
            uint256 fTokenAmount,
            uint256 fQuoteAmount
        ) = dmm.removeLiquidity(PROPOSAL_ID);

        // Should recover some tokens (may not be exact due to rounding)
        assertTrue(pTokenAmount > 0 || pQuoteAmount > 0);
        assertTrue(fTokenAmount > 0 || fQuoteAmount > 0);
    }

    function testRevert_RemoveLiquidity_NotProposalManager() public {
        _initializeMarketsForProposal(PROPOSAL_ID);

        vm.prank(alice);
        vm.expectRevert(IDecisionMarketManager.NotProposalManager.selector);
        dmm.removeLiquidity(PROPOSAL_ID);
    }

    function testRevert_RemoveLiquidity_NotInitialized() public {
        vm.prank(proposalManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDecisionMarketManager.MarketsNotInitialized.selector,
                PROPOSAL_ID
            )
        );
        dmm.removeLiquidity(PROPOSAL_ID);
    }

    // ============ View Function Tests ============

    function test_GetPoolKeys_ReturnsCorrectKeys() public {
        _initializeMarketsForProposal(PROPOSAL_ID);

        PoolKey[2] memory keys = dmm.getPoolKeys(PROPOSAL_ID);

        // Pass pool should have pToken and pQuote
        assertTrue(
            Currency.unwrap(keys[0].currency0) == address(pToken) ||
                Currency.unwrap(keys[0].currency1) == address(pToken)
        );

        // Fail pool should have fToken and fQuote
        assertTrue(
            Currency.unwrap(keys[1].currency0) == address(fToken) ||
                Currency.unwrap(keys[1].currency1) == address(fToken)
        );
    }

    function test_GetPositionIds_ReturnsNonZero() public {
        _initializeMarketsForProposal(PROPOSAL_ID);

        uint256[2] memory ids = dmm.getPositionIds(PROPOSAL_ID);

        assertTrue(ids[0] > 0);
        assertTrue(ids[1] > 0);
        assertTrue(ids[0] != ids[1]); // Different positions
    }

    function test_GetSpotPrices_ReturnsNonZero() public {
        _initializeMarketsForProposal(PROPOSAL_ID);

        (uint256 passPrice, uint256 failPrice) = dmm.getSpotPrices(PROPOSAL_ID);

        // At 1:1 sqrt price, prices should be non-zero
        assertTrue(passPrice > 0);
        assertTrue(failPrice > 0);
    }

    function testRevert_GetSpotPrices_NotInitialized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IDecisionMarketManager.MarketsNotInitialized.selector,
                PROPOSAL_ID
            )
        );
        dmm.getSpotPrices(PROPOSAL_ID);
    }

    function test_GetTWAPs_ReturnsZeroBeforeRecording() public {
        _initializeMarketsForProposal(PROPOSAL_ID);

        // TWAP recording hasn't started yet (starts at block.timestamp + 1 days)
        (uint256 passTwap, uint256 failTwap) = dmm.getTWAPs(PROPOSAL_ID);

        // Should be zero before any swaps occur
        assertEq(passTwap, 0);
        assertEq(failTwap, 0);
    }

    // ============ Constants Tests ============

    function test_DefaultPoolFee() public view {
        assertEq(dmm.DEFAULT_POOL_FEE(), 3000); // 0.3%
    }

    function test_DefaultTickSpacing() public view {
        assertEq(dmm.DEFAULT_TICK_SPACING(), 60);
    }

    // ============ Helper Functions ============

    function _initializeMarketsForProposal(uint256 proposalId) internal {
        ConditionalTokenSet memory tokens = ConditionalTokenSet({
            pToken: address(pToken),
            fToken: address(fToken),
            pQuote: address(pQuote),
            fQuote: address(fQuote)
        });

        vm.prank(proposalManager);
        dmm.initializeMarkets(
            proposalId,
            tokens,
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            SQRT_PRICE_1_1,
            8,
            block.timestamp + 1 days
        );
    }
}
