// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrganizationState, OrganizationConfig, OrganizationType, OrganizationStatus} from "../types/OrganizationTypes.sol";
import {RaiseConfig} from "../types/RaiseTypes.sol";

// ============================================================================
// IOrganizationManager
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.1
// Central singleton managing all organization state
// ============================================================================

interface IOrganizationManager {
    // ============ Errors ============

    /// @notice Address is zero when it shouldn't be
    error ZeroAddress();

    /// @notice Organization not found
    error OrgNotFound(uint256 orgId);

    /// @notice Organization not active
    error OrgNotActive(uint256 orgId);

    /// @notice Not a protocol admin
    error NotProtocolAdmin();

    /// @notice Not the organization owner
    error NotOrgOwner();

    /// @notice Not a team member
    error NotTeamMember();

    /// @notice Invalid configuration parameter
    error InvalidConfig();

    /// @notice Protocol is paused
    error ProtocolPaused();

    /// @notice Protocol is not paused
    error ProtocolNotPaused();

    /// @notice Invalid organization status for operation
    error InvalidOrgStatus(
        OrganizationStatus current,
        OrganizationStatus required
    );

    /// @notice Only governance (proposal execution) can call
    error OnlyGovernance();

    /// @notice Member already exists
    error MemberAlreadyExists();

    /// @notice Member does not exist
    error MemberNotFound();

    /// @notice Cannot transfer to self
    error CannotTransferToSelf();

    /// @notice Fee exceeds maximum
    error FeeExceedsMax();

    /// @notice Invalid raise configuration
    error InvalidRaiseConfig();

    // ============ Events ============

    event OrganizationCreated(
        uint256 indexed orgId,
        OrganizationType orgType,
        address indexed owner
    );
    event OrganizationStatusUpdated(
        uint256 indexed orgId,
        OrganizationStatus status
    );
    event ConfigUpdated(uint256 indexed orgId);
    event MetadataUpdated(uint256 indexed orgId, string uri);
    event TeamMemberAdded(uint256 indexed orgId, address indexed member);
    event TeamMemberRemoved(uint256 indexed orgId, address indexed member);
    event OwnershipTransferred(
        uint256 indexed orgId,
        address indexed previousOwner,
        address indexed newOwner
    );
    event ProtocolAdminGranted(address indexed account);
    event ProtocolAdminRevoked(address indexed account);
    event FeeRecipientUpdated(address indexed recipient);
    event TreasuryFeeShareUpdated(uint256 newShareBps);
    event DefaultPoolFeeUpdated(uint24 newFeeBps);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    // ============ Organization Creation ============

    /// @notice Create a new ICO organization with a raise
    /// @param metadataURI URI pointing to organization metadata
    /// @param quoteToken Address of the quote token for the raise
    /// @param tokenName Name for the new governance token
    /// @param tokenSymbol Symbol for the new governance token
    /// @param config Organization configuration
    /// @param raiseConfig Configuration for the ICO raise
    /// @return orgId The newly created organization ID
    function createICOOrganization(
        string calldata metadataURI,
        address quoteToken,
        string calldata tokenName,
        string calldata tokenSymbol,
        OrganizationConfig calldata config,
        RaiseConfig calldata raiseConfig
    ) external returns (uint256 orgId);

    /// @notice Create a new external organization with existing token
    /// @param metadataURI URI pointing to organization metadata
    /// @param baseToken Address of the existing governance token
    /// @param quoteToken Address of the quote token
    /// @param baseTokenAmount Amount of base token to deposit
    /// @param quoteTokenAmount Amount of quote token to deposit
    /// @param config Organization configuration
    /// @return orgId The newly created organization ID
    function createExternalOrganization(
        string calldata metadataURI,
        address baseToken,
        address quoteToken,
        uint256 baseTokenAmount,
        uint256 quoteTokenAmount,
        OrganizationConfig calldata config
    ) external returns (uint256 orgId);

    // ============ Organization Management ============

    /// @notice Update organization configuration (governance only)
    /// @param orgId Organization ID
    /// @param newConfig New configuration
    function updateConfig(
        uint256 orgId,
        OrganizationConfig calldata newConfig
    ) external;

    /// @notice Update organization metadata URI (governance only)
    /// @param orgId Organization ID
    /// @param uri New metadata URI
    function updateMetadata(uint256 orgId, string calldata uri) external;

    /// @notice Update organization status (protocol admin only)
    /// @param orgId Organization ID
    /// @param status New status
    function updateStatus(uint256 orgId, OrganizationStatus status) external;

    // ============ Role Management ============

    /// @notice Add a team member to an organization (owner only)
    /// @param orgId Organization ID
    /// @param member Address to add as team member
    function addTeamMember(uint256 orgId, address member) external;

    /// @notice Remove a team member from an organization (owner only)
    /// @param orgId Organization ID
    /// @param member Address to remove
    function removeTeamMember(uint256 orgId, address member) external;

    /// @notice Transfer organization ownership (owner only)
    /// @param orgId Organization ID
    /// @param newOwner Address of new owner
    function transferOwnership(uint256 orgId, address newOwner) external;

    // ============ Protocol Admin ============

    /// @notice Grant protocol admin role
    /// @param account Address to grant admin role
    function grantProtocolAdmin(address account) external;

    /// @notice Revoke protocol admin role
    /// @param account Address to revoke admin role
    function revokeProtocolAdmin(address account) external;

    /// @notice Set the protocol fee recipient
    /// @param recipient Address to receive protocol fees
    function setFeeRecipient(address recipient) external;

    /// @notice Set the treasury fee share (bps)
    /// @param newShareBps New share in basis points
    function setTreasuryFeeShare(uint256 newShareBps) external;

    /// @notice Set the default pool fee for new pools
    /// @param newFeeBps New fee in basis points (e.g., 3000 = 0.3%)
    function setDefaultPoolFee(uint24 newFeeBps) external;

    /// @notice Pause the protocol
    function pause() external;

    /// @notice Unpause the protocol
    function unpause() external;

    // ============ View Functions ============

    /// @notice Get organization state and config
    /// @param orgId Organization ID
    /// @return state Organization state
    /// @return config Organization config
    function getOrganization(
        uint256 orgId
    )
        external
        view
        returns (
            OrganizationState memory state,
            OrganizationConfig memory config
        );

    /// @notice Get effective stake threshold for a user
    /// @param orgId Organization ID
    /// @param user User address
    /// @return threshold Effective stake threshold
    function getEffectiveStakeThreshold(
        uint256 orgId,
        address user
    ) external view returns (uint256 threshold);

    /// @notice Check if address is a team member
    /// @param orgId Organization ID
    /// @param user User address
    /// @return isTeam True if user is team member
    function isTeamMember(
        uint256 orgId,
        address user
    ) external view returns (bool isTeam);

    /// @notice Check if address is the owner
    /// @param orgId Organization ID
    /// @param user User address
    /// @return isOwnerResult True if user is owner
    function isOwner(
        uint256 orgId,
        address user
    ) external view returns (bool isOwnerResult);

    /// @notice Get organization count
    /// @return count Total number of organizations
    function orgCount() external view returns (uint256 count);

    /// @notice Check if protocol is paused
    /// @return isPaused True if paused
    function paused() external view returns (bool isPaused);

    /// @notice Check if address is protocol admin
    /// @param account Address to check
    /// @return isAdmin True if admin
    function protocolAdmins(
        address account
    ) external view returns (bool isAdmin);

    /// @notice Get treasury address for an organization
    /// @param orgId Organization ID
    /// @return treasury Treasury contract address
    function treasuries(uint256 orgId) external view returns (address treasury);

    /// @notice Get proposal manager address for an organization
    /// @param orgId Organization ID
    /// @return proposalManager ProposalManager contract address
    function proposalManagers(
        uint256 orgId
    ) external view returns (address proposalManager);

    /// @notice Get governance token address for an organization
    /// @param orgId Organization ID
    /// @return token Governance token address
    function governanceTokens(
        uint256 orgId
    ) external view returns (address token);

    /// @notice Get raise contract address for an organization
    /// @param orgId Organization ID
    /// @return raise Raise contract address
    function raises(uint256 orgId) external view returns (address raise);

    /// @notice Get protocol fee recipient
    /// @return recipient Fee recipient address
    function protocolFeeRecipient() external view returns (address recipient);

    /// @notice Get treasury fee share
    /// @return shareBps Share in basis points
    function treasuryFeeShareBps() external view returns (uint256 shareBps);

    /// @notice Get default pool fee
    /// @return feeBps Fee in basis points
    function defaultPoolFeeBps() external view returns (uint24 feeBps);
}
