// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RaiseConfig, RaiseStatus} from "../types/RaiseTypes.sol";
import {OrganizationConfig} from "../types/OrganizationTypes.sol";

// ============================================================================
// IRaise
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.10
// Handles ICO contributions and token distribution
// Note: acceptedAmount caps raise, pro-rata refunds (per Q3 answer)
// ============================================================================

interface IRaise {
    // ============ Errors ============

    /// @notice Raise has already been initialized
    error AlreadyInitialized();

    /// @notice Raise is not in active status
    error RaiseNotActive();

    /// @notice Raise has ended (past end date)
    error RaiseEnded();

    /// @notice Raise has not started yet
    error RaiseNotStarted();

    /// @notice Contribution would exceed hard cap
    error ExceedsHardCap(uint256 amount, uint256 remaining);

    /// @notice Contribution amount is zero
    error ZeroContribution();

    /// @notice Caller is not authorized (not protocol admin)
    error NotAuthorized();

    /// @notice Raise has not ended yet
    error RaiseNotEnded();

    /// @notice Accepted amount is below soft cap
    error BelowSoftCap(uint256 acceptedAmount, uint256 softCap);

    /// @notice Accepted amount exceeds total contributed
    error AcceptedExceedsContributed(
        uint256 acceptedAmount,
        uint256 totalContributed
    );

    /// @notice User has already claimed their tokens
    error AlreadyClaimed();

    /// @notice User has no contribution to claim
    error NoContribution();

    /// @notice There is nothing to refund
    error NothingToRefund();

    /// @notice Raise is not in a refundable state
    error NotRefundable();

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Invalid configuration
    error InvalidConfig();

    // ============ Events ============

    event Contributed(address indexed contributor, uint256 amount);
    event RaiseFinalized(uint256 acceptedAmount, uint256 tokensDistributed);
    event TokensClaimed(address indexed contributor, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);
    event RaiseFailed();

    // ============ Initialization ============

    /// @notice Initialize the raise contract
    /// @param orgId Organization ID this raise is for
    /// @param manager OrganizationManager contract address
    /// @param config Raise configuration
    function initialize(
        uint256 orgId,
        address manager,
        RaiseConfig calldata config
    ) external;

    // ============ Contribution ============

    /// @notice Contribute quote tokens to the raise
    /// @dev Requires raise is Active, within date range, doesn't exceed hardCap
    /// @param amount Amount of quote tokens to contribute
    function contribute(uint256 amount) external;

    // ============ Finalization ============

    /// @notice Finalize the raise (protocol admin only)
    /// @dev Sets acceptedAmount (discretionary cap), mints tokens, creates LP
    /// @param acceptedAmount Amount to accept (can be less than total contributed)
    function finalize(uint256 acceptedAmount) external;

    /// @notice Mark the raise as failed (protocol admin only)
    /// @dev Used when soft cap is not met
    function fail() external;

    // ============ Claims & Refunds ============

    /// @notice Claim governance tokens after successful raise
    /// @dev Returns proportional share based on contribution
    function claimTokens() external;

    /// @notice Get refund if raise failed or contribution exceeds accepted amount
    /// @dev Returns excess or full contribution depending on raise status
    function refund() external;

    // ============ View Functions ============

    /// @notice Get organization ID
    /// @return id Organization ID
    function organizationId() external view returns (uint256 id);

    /// @notice Get current raise status
    /// @return status Current RaiseStatus
    function status() external view returns (RaiseStatus status);

    /// @notice Get soft cap
    /// @return cap Soft cap amount
    function softCap() external view returns (uint256 cap);

    /// @notice Get hard cap
    /// @return cap Hard cap amount
    function hardCap() external view returns (uint256 cap);

    /// @notice Get accepted amount (set during finalization)
    /// @return amount Accepted contribution amount
    function acceptedAmount() external view returns (uint256 amount);

    /// @notice Get total contributed amount
    /// @return total Total contributions received
    function totalContributed() external view returns (uint256 total);

    /// @notice Get raise start date
    /// @return date Start timestamp
    function startDate() external view returns (uint256 date);

    /// @notice Get raise end date
    /// @return date End timestamp
    function endDate() external view returns (uint256 date);

    /// @notice Get quote token address
    /// @return token Quote token address
    function quoteToken() external view returns (address token);

    /// @notice Get agreed organization config
    /// @return config Organization config agreed during raise
    function agreedConfig()
        external
        view
        returns (OrganizationConfig memory config);

    /// @notice Get contribution amount for an address
    /// @param contributor Contributor address
    /// @return amount Contribution amount
    function contributions(
        address contributor
    ) external view returns (uint256 amount);

    /// @notice Get contributor at index
    /// @param index Array index
    /// @return contributor Contributor address
    function contributors(
        uint256 index
    ) external view returns (address contributor);

    /// @notice Get total number of contributors
    /// @return count Contributor count
    function getContributorCount() external view returns (uint256 count);

    /// @notice Check if an address has claimed
    /// @param contributor Contributor address
    /// @return claimed True if already claimed
    function hasClaimed(
        address contributor
    ) external view returns (bool claimed);

    /// @notice Calculate claimable tokens for a contributor
    /// @param contributor Contributor address
    /// @return amount Claimable token amount
    function getClaimableAmount(
        address contributor
    ) external view returns (uint256 amount);

    /// @notice Calculate refundable amount for a contributor
    /// @param contributor Contributor address
    /// @return amount Refundable amount
    function getRefundableAmount(
        address contributor
    ) external view returns (uint256 amount);
}
