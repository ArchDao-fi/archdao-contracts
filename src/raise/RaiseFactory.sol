// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Local interfaces
import {IRaiseFactory} from "../interfaces/IRaiseFactory.sol";
import {IOrganizationManager} from "../interfaces/IOrganizationManager.sol";

// Local types
import {RaiseConfig} from "../types/RaiseTypes.sol";

// Local contracts
import {Raise} from "./Raise.sol";

// ============================================================================
// RaiseFactory
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.9
// Ticket: T-037
//
// Factory for deploying ICO raise contracts.
// Only OrganizationManager can create raises to ensure proper setup.
// ============================================================================

contract RaiseFactory is IRaiseFactory {
    // ============ State Variables ============

    /// @notice OrganizationManager contract
    IOrganizationManager internal immutable _manager;

    /// @notice Mapping of organization ID to raise contract address
    mapping(uint256 => address) internal _raises;

    // ============ Constructor ============

    /// @notice Deploy the RaiseFactory
    /// @param managerAddr OrganizationManager contract address
    constructor(address managerAddr) {
        if (managerAddr == address(0)) revert InvalidRaiseConfig();
        _manager = IOrganizationManager(managerAddr);
    }

    // ============ Factory Functions ============

    /// @inheritdoc IRaiseFactory
    function createRaise(
        uint256 orgId,
        RaiseConfig calldata config
    ) external override returns (address raiseAddress) {
        if (msg.sender != address(_manager)) revert NotOrganizationManager();
        if (_raises[orgId] != address(0)) revert RaiseAlreadyExists(orgId);

        // Validate config
        if (config.softCap == 0) revert InvalidRaiseConfig();
        if (config.hardCap < config.softCap) revert InvalidRaiseConfig();
        if (config.startDate >= config.endDate) revert InvalidRaiseConfig();
        if (config.quoteToken == address(0)) revert InvalidRaiseConfig();

        // Deploy new Raise contract
        Raise raise = new Raise();

        // Initialize the raise
        raise.initialize(orgId, address(_manager), config);

        // Store the raise address
        _raises[orgId] = address(raise);
        raiseAddress = address(raise);

        emit RaiseCreated(orgId, raiseAddress);
    }

    // ============ View Functions ============

    /// @inheritdoc IRaiseFactory
    function getRaise(
        uint256 orgId
    ) external view override returns (address raiseAddress) {
        return _raises[orgId];
    }

    /// @inheritdoc IRaiseFactory
    function manager() external view override returns (address) {
        return address(_manager);
    }
}
