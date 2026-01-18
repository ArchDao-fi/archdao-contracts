// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RaiseConfig} from "../types/RaiseTypes.sol";

// ============================================================================
// IRaiseFactory
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.9
// Deploys ICO raise contracts
// ============================================================================

interface IRaiseFactory {
    // ============ Errors ============

    /// @notice Caller is not the OrganizationManager
    error NotOrganizationManager();

    /// @notice Raise already exists for this organization
    error RaiseAlreadyExists(uint256 orgId);

    /// @notice Invalid raise configuration
    error InvalidRaiseConfig();

    // ============ Events ============

    event RaiseCreated(uint256 indexed orgId, address indexed raiseAddress);

    // ============ Factory Functions ============

    /// @notice Create a new raise contract for an organization
    /// @dev Only callable by OrganizationManager
    /// @param orgId Organization ID
    /// @param config Raise configuration
    /// @return raiseAddress Deployed raise contract address
    function createRaise(
        uint256 orgId,
        RaiseConfig calldata config
    ) external returns (address raiseAddress);

    // ============ View Functions ============

    /// @notice Get the raise contract for an organization
    /// @param orgId Organization ID
    /// @return raiseAddress Raise contract address (address(0) if none)
    function getRaise(
        uint256 orgId
    ) external view returns (address raiseAddress);

    /// @notice Get the OrganizationManager address
    /// @return manager OrganizationManager contract address
    function manager() external view returns (address manager);
}
