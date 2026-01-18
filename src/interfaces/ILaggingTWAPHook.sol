// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {TWAPObservation} from "../types/TWAPTypes.sol";

// ============================================================================
// ILaggingTWAPHook
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.7
// Uniswap V4 hook for rate-limited TWAP observations
// ============================================================================

interface ILaggingTWAPHook {
    // ============ Errors ============

    /// @notice Address is zero when it shouldn't be
    error ZeroAddress();

    /// @notice Caller is not the DecisionMarketManager
    error NotDecisionMarketManager();

    /// @notice Recording has not started for this pool
    error RecordingNotStarted();

    /// @notice Recording already started for this pool
    error RecordingAlreadyStarted();

    // ============ Events ============

    event RecordingStarted(
        PoolId indexed poolId,
        uint256 startTime,
        uint256 maxRateBpsPerSecond
    );
    event RecordingStopped(PoolId indexed poolId);
    event ObservationUpdated(
        PoolId indexed poolId,
        uint256 observedPrice,
        uint256 timestamp
    );

    // ============ Configuration ============

    /// @notice Start TWAP recording for a pool
    /// @dev Only callable by DecisionMarketManager
    /// @param poolId Pool identifier
    /// @param startTime When recording should begin (allows for delay)
    /// @param maxRateBpsPerSecond Maximum rate of price change in bps per second
    function startRecording(
        PoolId poolId,
        uint256 startTime,
        uint256 maxRateBpsPerSecond
    ) external;

    /// @notice Stop TWAP recording for a pool
    /// @dev Only callable by DecisionMarketManager
    /// @param poolId Pool identifier
    function stopRecording(PoolId poolId) external;

    // ============ View Functions ============

    /// @notice Get the current observed (lagging) price
    /// @param poolId Pool identifier
    /// @return observedPrice Current rate-limited observed price
    function getObservedPrice(
        PoolId poolId
    ) external view returns (uint256 observedPrice);

    /// @notice Get the TWAP (time-weighted average price)
    /// @param poolId Pool identifier
    /// @return twap Time-weighted average price since recording started
    function getTWAP(PoolId poolId) external view returns (uint256 twap);

    /// @notice Get the full observation data
    /// @param poolId Pool identifier
    /// @return observation The TWAPObservation struct
    function getObservation(
        PoolId poolId
    ) external view returns (TWAPObservation memory observation);

    /// @notice Get the recording start time for a pool
    /// @param poolId Pool identifier
    /// @return startTime When recording starts (or started)
    function recordingStartTime(
        PoolId poolId
    ) external view returns (uint256 startTime);

    /// @notice Get the max rate for a pool
    /// @param poolId Pool identifier
    /// @return maxRate Maximum rate in bps per second
    function observationMaxRateBpsPerSecond(
        PoolId poolId
    ) external view returns (uint256 maxRate);

    /// @notice Check if a pool is currently recording
    /// @param poolId Pool identifier
    /// @return recording True if recording is active
    function isRecording(PoolId poolId) external view returns (bool recording);
}
