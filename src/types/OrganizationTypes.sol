// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ============================================================================
// Organization Types
// ============================================================================
// Source of Truth: SPECIFICATION.md §5
// ============================================================================

/// @notice Type of organization
enum OrganizationType {
    ICO, // New project with raise
    External // Existing token
}

/// @notice Organization lifecycle status
enum OrganizationStatus {
    Pending, // Awaiting admin approval
    Approved, // Approved, awaiting raise (ICO) or activation (External)
    Raise, // ICO in progress
    Active, // Fully operational
    Rejected, // Admin rejected
    Failed // Raise failed to meet soft cap
}

/// @notice Organization state data
struct OrganizationState {
    OrganizationType orgType;
    OrganizationStatus status;
    string metadataURI;
    address baseToken;
    address quoteToken;
    address owner;
    uint256 createdAt;
}

/// @notice Organization configuration parameters
struct OrganizationConfig {
    // Pass threshold settings
    uint256 minTwapSpreadBps; // Minimum spread for pass (e.g., 300 = 3%)
    int256 teamPassThresholdBps; // Team proposal threshold (e.g., -300 = -3%)
    int256 nonTeamPassThresholdBps; // Non-team threshold (e.g., 300 = 3%)
    // Staking settings
    uint256 defaultStakingThreshold; // Absolute token amount for non-team
    uint256 teamStakingThresholdBps; // Team threshold as bps of supply (e.g., 300 = 3%)
    uint256 ownerStakingThresholdBps; // Owner threshold as bps (e.g., 500 = 5%)
    // Timing settings
    uint256 stakingDuration; // Default 48 hours
    uint256 tradingDuration; // Default 4 days
    uint256 twapRecordingDelay; // Default 24 hours
    uint256 minCancellationDelay; // Default 24 hours
    // TWAP settings
    uint256 observationMaxRateBpsPerSecond; // Rate limit for observations
    // LP settings
    uint256 lpAllocationPerProposalBps; // % of treasury LP per proposal
}

/// @notice Organization role data
struct OrgRole {
    bool isOwner;
    bool isTeamMember;
    uint256 customStakeThreshold; // 0 = use default for role
}
