// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrganizationConfig} from "./OrganizationTypes.sol";

// ============================================================================
// Raise Types
// ============================================================================
// Source of Truth: SPECIFICATION.md §5
// ============================================================================

/// @notice Raise lifecycle status
enum RaiseStatus {
    Pending, // Not yet started
    Active, // Accepting contributions
    Finalizing, // End date passed, awaiting admin finalization
    Completed, // Successfully finalized
    Failed // Did not meet soft cap
}

/// @notice Raise configuration
struct RaiseConfig {
    uint256 softCap;
    uint256 hardCap;
    uint256 startDate;
    uint256 endDate;
    address quoteToken;
    OrganizationConfig agreedConfig;
}
