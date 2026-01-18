// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OpenZeppelin / Uniswap Hooks Base
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

// Uniswap V4 Core
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Local interfaces
import {ILaggingTWAPHook} from "../interfaces/ILaggingTWAPHook.sol";

// Local types
import {TWAPObservation} from "../types/TWAPTypes.sol";

// ============================================================================
// LaggingTWAPHook
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.7 and §3.3
// Ticket: T-021
//
// Uniswap V4 hook that implements rate-limited TWAP observations.
// Key features:
// - Rate limiting: Observations can only move by maxDelta per update
// - Recording delay: TWAP recording starts after twapRecordingDelay
// - Manipulation resistance: Limits maximum price movement per second
//
// TWAP Calculation:
// The TWAP is computed as (cumulativePrice / recordingDuration)
// where cumulativePrice accumulates (observedPrice × elapsedTime) over time.
//
// Rate Limiting Formula (from §3.3):
// maxDelta = lastObservedPrice × observationMaxRateBpsPerSecond × elapsedSeconds / 10000
//
// if (currentPrice > lastObservedPrice):
//     newObservation = min(currentPrice, lastObservedPrice + maxDelta)
// else:
//     newObservation = max(currentPrice, lastObservedPrice - maxDelta)
// ============================================================================

contract LaggingTWAPHook is BaseHook, ILaggingTWAPHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ============ Constants ============

    /// @notice Basis points denominator (10000 = 100%)
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Price precision for calculations (1e18)
    uint256 public constant PRICE_PRECISION = 1e18;

    // ============ State Variables ============

    /// @notice Address authorized to configure recording (DecisionMarketManager)
    address public decisionMarketManager;

    /// @notice TWAP observations per pool
    mapping(PoolId => TWAPObservation) public observations;

    /// @notice When recording starts for each pool
    mapping(PoolId => uint256) public override recordingStartTime;

    /// @notice Max rate of price change per second in bps for each pool
    mapping(PoolId => uint256) public override observationMaxRateBpsPerSecond;

    /// @notice Whether recording is active for each pool
    mapping(PoolId => bool) public override isRecording;

    // ============ Modifiers ============

    modifier onlyDecisionMarketManager() {
        if (msg.sender != decisionMarketManager)
            revert NotDecisionMarketManager();
        _;
    }

    // ============ Constructor ============

    /// @notice Deploy the TWAP hook
    /// @param _poolManager Uniswap V4 PoolManager address
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // ============ Configuration ============

    /// @notice Set the DecisionMarketManager address (one-time setup)
    /// @param _decisionMarketManager DecisionMarketManager contract address
    function setDecisionMarketManager(address _decisionMarketManager) external {
        // Can only be set once
        if (decisionMarketManager != address(0))
            revert RecordingAlreadyStarted();
        if (_decisionMarketManager == address(0)) revert ZeroAddress();
        decisionMarketManager = _decisionMarketManager;
    }

    /// @inheritdoc ILaggingTWAPHook
    function startRecording(
        PoolId poolId,
        uint256 startTime,
        uint256 maxRateBpsPerSecond
    ) external override onlyDecisionMarketManager {
        if (isRecording[poolId]) revert RecordingAlreadyStarted();

        recordingStartTime[poolId] = startTime;
        observationMaxRateBpsPerSecond[poolId] = maxRateBpsPerSecond;
        isRecording[poolId] = true;

        // Initialize observation with current price (will be updated on first swap)
        // We set timestamp to startTime so TWAP starts from 0
        observations[poolId] = TWAPObservation({
            timestamp: startTime,
            observedPrice: 0, // Will be set on first swap after startTime
            cumulativePrice: 0
        });

        emit RecordingStarted(poolId, startTime, maxRateBpsPerSecond);
    }

    /// @inheritdoc ILaggingTWAPHook
    function stopRecording(
        PoolId poolId
    ) external override onlyDecisionMarketManager {
        if (!isRecording[poolId]) revert RecordingNotStarted();

        isRecording[poolId] = false;
        emit RecordingStopped(poolId);
    }

    // ============ V4 Hook Callbacks ============

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true, // We use afterSwap to record observations
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @notice Called after every swap - updates TWAP observation
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        // Only update if recording is active and start time has passed
        if (
            isRecording[poolId] && block.timestamp >= recordingStartTime[poolId]
        ) {
            uint256 currentPrice = _getCurrentPrice(key);
            _updateObservation(poolId, currentPrice);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // ============ View Functions ============

    /// @inheritdoc ILaggingTWAPHook
    function getObservedPrice(
        PoolId poolId
    ) external view override returns (uint256) {
        return observations[poolId].observedPrice;
    }

    /// @inheritdoc ILaggingTWAPHook
    function getTWAP(PoolId poolId) external view override returns (uint256) {
        TWAPObservation memory obs = observations[poolId];
        uint256 startTime = recordingStartTime[poolId];

        // If no recording has started or no time has passed, return 0
        if (obs.timestamp <= startTime || block.timestamp <= startTime) {
            return 0;
        }

        // Calculate cumulative up to now (including time since last update)
        uint256 elapsed = block.timestamp - obs.timestamp;
        uint256 currentCumulative = obs.cumulativePrice +
            (obs.observedPrice * elapsed);

        // TWAP = totalCumulative / totalDuration
        uint256 totalDuration = block.timestamp - startTime;
        if (totalDuration == 0) return 0;

        return currentCumulative / totalDuration;
    }

    /// @inheritdoc ILaggingTWAPHook
    function getObservation(
        PoolId poolId
    ) external view override returns (TWAPObservation memory) {
        return observations[poolId];
    }

    // ============ Internal Functions ============

    /// @notice Get current spot price from pool
    /// @param key Pool key
    /// @return price Current price scaled to PRICE_PRECISION
    function _getCurrentPrice(
        PoolKey calldata key
    ) internal view returns (uint256) {
        // Get sqrtPriceX96 from pool
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());

        // Convert sqrtPriceX96 to price
        // price = (sqrtPriceX96 / 2^96)^2 = sqrtPriceX96^2 / 2^192
        // Scaled by PRICE_PRECISION for accuracy
        uint256 price = (uint256(sqrtPriceX96) *
            uint256(sqrtPriceX96) *
            PRICE_PRECISION) >> 192;

        return price;
    }

    /// @notice Update the TWAP observation with rate limiting
    /// @param poolId Pool identifier
    /// @param currentPrice Current spot price
    function _updateObservation(PoolId poolId, uint256 currentPrice) internal {
        TWAPObservation storage obs = observations[poolId];

        uint256 elapsed = block.timestamp - obs.timestamp;
        if (elapsed == 0) return; // No time has passed

        uint256 lastPrice = obs.observedPrice;
        uint256 newObservedPrice;

        // First observation after recording starts
        if (lastPrice == 0) {
            newObservedPrice = currentPrice;
        } else {
            // Calculate rate-limited observation
            uint256 maxDelta = _calculateMaxDelta(
                lastPrice,
                elapsed,
                observationMaxRateBpsPerSecond[poolId]
            );

            if (currentPrice > lastPrice) {
                // Price went up - cap the increase
                uint256 maxPrice = lastPrice + maxDelta;
                newObservedPrice = currentPrice < maxPrice
                    ? currentPrice
                    : maxPrice;
            } else {
                // Price went down - cap the decrease
                uint256 minPrice = lastPrice > maxDelta
                    ? lastPrice - maxDelta
                    : 0;
                newObservedPrice = currentPrice > minPrice
                    ? currentPrice
                    : minPrice;
            }
        }

        // Update cumulative price (using old observed price for elapsed duration)
        if (lastPrice > 0) {
            obs.cumulativePrice += lastPrice * elapsed;
        }

        // Update observation
        obs.timestamp = block.timestamp;
        obs.observedPrice = newObservedPrice;

        emit ObservationUpdated(poolId, newObservedPrice, block.timestamp);
    }

    /// @notice Calculate maximum allowed price delta
    /// @param lastObs Last observed price
    /// @param elapsed Seconds since last observation
    /// @param maxRate Maximum rate in bps per second
    /// @return maxDelta Maximum allowed price change
    function _calculateMaxDelta(
        uint256 lastObs,
        uint256 elapsed,
        uint256 maxRate
    ) internal pure returns (uint256) {
        // maxDelta = lastObs * maxRate * elapsed / BPS_DENOMINATOR
        return (lastObs * maxRate * elapsed) / BPS_DENOMINATOR;
    }
}
