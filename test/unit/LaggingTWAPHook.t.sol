// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

// V4 Core
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

// Local
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {LaggingTWAPHook} from "../../src/markets/LaggingTWAPHook.sol";
import {ILaggingTWAPHook} from "../../src/interfaces/ILaggingTWAPHook.sol";
import {TWAPObservation} from "../../src/types/TWAPTypes.sol";

// ============================================================================
// LaggingTWAPHook Unit Tests
// ============================================================================
// Ticket: T-022
// Tests for SPECIFICATION.md §4.7
// Uses local V4 deployment (same pattern as Counter.t.sol)
// ============================================================================

contract LaggingTWAPHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    LaggingTWAPHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    address decisionMarketManager = makeAddr("decisionMarketManager");

    // Default TWAP config (~72%/day movement)
    uint256 constant DEFAULT_MAX_RATE_BPS = 8; // bps per second

    // ============ Setup ============

    function setUp() public {
        // Deploy V4 artifacts
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        // Deploy the hook with correct flags (only afterSwap)
        address flags = address(
            uint160(Hooks.AFTER_SWAP_FLAG) ^ (0x5555 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo(
            "LaggingTWAPHook.sol:LaggingTWAPHook",
            constructorArgs,
            flags
        );
        hook = LaggingTWAPHook(flags);

        // Set decision market manager
        hook.setDecisionMarketManager(decisionMarketManager);

        // Create the pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Add full-range liquidity
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts
            .getAmountsForLiquidity(
                Constants.SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidityAmount
            );

        (tokenId, ) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    // ============ Hook Permissions Tests ============

    function test_GetHookPermissions_OnlyAfterSwap() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        assertFalse(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertFalse(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

    // ============ DecisionMarketManager Setup Tests ============

    function test_SetDecisionMarketManager_Success() public {
        // Deploy fresh hook
        address flags2 = address(
            uint160(Hooks.AFTER_SWAP_FLAG) ^ (0x6666 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo(
            "LaggingTWAPHook.sol:LaggingTWAPHook",
            constructorArgs,
            flags2
        );
        LaggingTWAPHook freshHook = LaggingTWAPHook(flags2);

        address newManager = makeAddr("newManager");
        freshHook.setDecisionMarketManager(newManager);

        assertEq(freshHook.decisionMarketManager(), newManager);
    }

    function testRevert_SetDecisionMarketManager_AlreadySet() public {
        // Already set in setUp
        vm.expectRevert(ILaggingTWAPHook.RecordingAlreadyStarted.selector);
        hook.setDecisionMarketManager(makeAddr("another"));
    }

    function testRevert_SetDecisionMarketManager_ZeroAddress() public {
        // Deploy fresh hook
        address flags2 = address(
            uint160(Hooks.AFTER_SWAP_FLAG) ^ (0x7777 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo(
            "LaggingTWAPHook.sol:LaggingTWAPHook",
            constructorArgs,
            flags2
        );
        LaggingTWAPHook freshHook = LaggingTWAPHook(flags2);

        vm.expectRevert(ILaggingTWAPHook.ZeroAddress.selector);
        freshHook.setDecisionMarketManager(address(0));
    }

    // ============ Recording Control Tests ============

    function test_StartRecording_Success() public {
        uint256 startTime = block.timestamp + 1 hours; // Recording starts after delay

        vm.prank(decisionMarketManager);
        hook.startRecording(poolId, startTime, DEFAULT_MAX_RATE_BPS);

        assertTrue(hook.isRecording(poolId));
        assertEq(hook.recordingStartTime(poolId), startTime);
        assertEq(
            hook.observationMaxRateBpsPerSecond(poolId),
            DEFAULT_MAX_RATE_BPS
        );
    }

    function testRevert_StartRecording_NotManager() public {
        vm.expectRevert(ILaggingTWAPHook.NotDecisionMarketManager.selector);
        hook.startRecording(poolId, block.timestamp, DEFAULT_MAX_RATE_BPS);
    }

    function testRevert_StartRecording_AlreadyStarted() public {
        vm.startPrank(decisionMarketManager);
        hook.startRecording(poolId, block.timestamp, DEFAULT_MAX_RATE_BPS);

        vm.expectRevert(ILaggingTWAPHook.RecordingAlreadyStarted.selector);
        hook.startRecording(poolId, block.timestamp, DEFAULT_MAX_RATE_BPS);
        vm.stopPrank();
    }

    function test_StopRecording_Success() public {
        vm.startPrank(decisionMarketManager);
        hook.startRecording(poolId, block.timestamp, DEFAULT_MAX_RATE_BPS);
        hook.stopRecording(poolId);
        vm.stopPrank();

        assertFalse(hook.isRecording(poolId));
    }

    function testRevert_StopRecording_NotStarted() public {
        vm.prank(decisionMarketManager);
        vm.expectRevert(ILaggingTWAPHook.RecordingNotStarted.selector);
        hook.stopRecording(poolId);
    }

    function testRevert_StopRecording_NotManager() public {
        vm.prank(decisionMarketManager);
        hook.startRecording(poolId, block.timestamp, DEFAULT_MAX_RATE_BPS);

        vm.expectRevert(ILaggingTWAPHook.NotDecisionMarketManager.selector);
        hook.stopRecording(poolId);
    }

    // ============ TWAP Recording Tests ============

    function test_AfterSwap_NoUpdateBeforeRecordingStarts() public {
        // Start recording in the future
        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(decisionMarketManager);
        hook.startRecording(poolId, startTime, DEFAULT_MAX_RATE_BPS);

        // Perform swap before recording starts
        _performSwap(1e18, true);

        // Observation should not be updated
        TWAPObservation memory obs = hook.getObservation(poolId);
        assertEq(obs.observedPrice, 0);
    }

    function test_AfterSwap_UpdatesObservation() public {
        // Start recording immediately
        vm.prank(decisionMarketManager);
        hook.startRecording(poolId, block.timestamp, DEFAULT_MAX_RATE_BPS);

        // Wait a bit
        vm.warp(block.timestamp + 1);

        // Perform swap
        _performSwap(1e18, true);

        // Observation should be updated
        uint256 observedPrice = hook.getObservedPrice(poolId);
        assertTrue(observedPrice > 0, "Observed price should be non-zero");
    }

    function test_AfterSwap_NoUpdateWhenNotRecording() public {
        // Don't start recording

        // Perform swap
        _performSwap(1e18, true);

        // Observation should remain zero
        assertEq(hook.getObservedPrice(poolId), 0);
    }

    function test_TWAP_AccumulatesOverTime() public {
        // Start recording
        vm.prank(decisionMarketManager);
        hook.startRecording(poolId, block.timestamp, DEFAULT_MAX_RATE_BPS);

        // Initial swap to set price
        vm.warp(block.timestamp + 1);
        _performSwap(1e18, true);

        uint256 initialPrice = hook.getObservedPrice(poolId);
        assertTrue(initialPrice > 0);

        // Wait and do another swap
        vm.warp(block.timestamp + 100);
        _performSwap(0.5e18, false);

        // TWAP should now be calculated
        uint256 twap = hook.getTWAP(poolId);
        assertTrue(twap > 0, "TWAP should be non-zero");
    }

    function test_TWAP_ReturnsZeroBeforeRecording() public {
        // Don't start recording
        uint256 twap = hook.getTWAP(poolId);
        assertEq(twap, 0);
    }

    // ============ Rate Limiting Tests ============

    function test_RateLimiting_CapsLargePriceIncrease() public {
        // Start recording with very restrictive rate (1 bps/sec = 0.01%/sec)
        vm.prank(decisionMarketManager);
        hook.startRecording(poolId, block.timestamp, 1);

        // Wait 1 second and swap
        vm.warp(block.timestamp + 1);
        _performSwap(0.1e18, true);

        uint256 price1 = hook.getObservedPrice(poolId);

        // Wait only 1 second - max delta should be price1 * 1 * 1 / 10000 = price1/10000
        vm.warp(block.timestamp + 1);

        // Large swap that would normally move price significantly
        _performSwap(10e18, true);

        uint256 price2 = hook.getObservedPrice(poolId);

        // Price change should be limited
        // Max change is price1 * 1 bps * 1 second = price1 / 10000
        uint256 maxDelta = price1 / 10000;

        // The new price should not exceed old price + maxDelta
        // Note: Could be equal if rate-limited or slightly different due to calculations
        assertTrue(
            price2 <= price1 + maxDelta + 1,
            "Price increase should be rate-limited"
        );
    }

    function test_RateLimiting_AllowsGradualMovement() public {
        // Start recording with moderate rate
        vm.prank(decisionMarketManager);
        hook.startRecording(poolId, block.timestamp, DEFAULT_MAX_RATE_BPS);

        // Initial swap
        vm.warp(block.timestamp + 1);
        _performSwap(1e18, true);

        uint256 price1 = hook.getObservedPrice(poolId);

        // Wait longer - allows more movement
        vm.warp(block.timestamp + 1000); // 1000 seconds

        _performSwap(5e18, true);

        uint256 price2 = hook.getObservedPrice(poolId);

        // Price should have moved (either rate-limited or natural)
        assertTrue(price2 != price1, "Price should have changed");
    }

    // ============ Multiple Pools Tests ============

    function test_MultiplePoolsIndependent() public {
        // Create second pool with same hook
        (Currency c0, Currency c1) = deployCurrencyPair();
        PoolKey memory poolKey2 = PoolKey(c0, c1, 500, 10, IHooks(hook));
        PoolId poolId2 = poolKey2.toId();
        poolManager.initialize(poolKey2, Constants.SQRT_PRICE_1_1);

        // Add liquidity to pool2
        int24 tickLower2 = TickMath.minUsableTick(poolKey2.tickSpacing);
        int24 tickUpper2 = TickMath.maxUsableTick(poolKey2.tickSpacing);

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts
            .getAmountsForLiquidity(
                Constants.SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(tickLower2),
                TickMath.getSqrtPriceAtTick(tickUpper2),
                100e18
            );

        positionManager.mint(
            poolKey2,
            tickLower2,
            tickUpper2,
            100e18,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // Start recording on pool1 only
        vm.prank(decisionMarketManager);
        hook.startRecording(poolId, block.timestamp, DEFAULT_MAX_RATE_BPS);

        // Pool1 should be recording, pool2 should not
        assertTrue(hook.isRecording(poolId));
        assertFalse(hook.isRecording(poolId2));
    }

    // ============ Constants Tests ============

    function test_BpsDenominator() public view {
        assertEq(hook.BPS_DENOMINATOR(), 10_000);
    }

    function test_PricePrecision() public view {
        assertEq(hook.PRICE_PRECISION(), 1e18);
    }

    // ============ Helper Functions ============

    function _performSwap(uint256 amountIn, bool zeroForOne) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }
}
