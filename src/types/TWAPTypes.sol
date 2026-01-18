// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ============================================================================
// TWAP Types
// ============================================================================
// Source of Truth: SPECIFICATION.md §5
// ============================================================================

/// @notice TWAP observation data
struct TWAPObservation {
    uint256 timestamp;
    uint256 observedPrice;
    uint256 cumulativePrice;
}
