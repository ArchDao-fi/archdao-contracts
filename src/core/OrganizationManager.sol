// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V4 Core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// V4 Periphery
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

// Permit2
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// Local interfaces
import {IOrganizationManager} from "../interfaces/IOrganizationManager.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {IProposalManager} from "../interfaces/IProposalManager.sol";

// Local contracts
import {Treasury} from "./Treasury.sol";
import {ProposalManager} from "./ProposalManager.sol";
import {GovernanceToken} from "../tokens/GovernanceToken.sol";
import {ConditionalTokenFactory} from "../tokens/ConditionalTokenFactory.sol";
import {DecisionMarketManager} from "../markets/DecisionMarketManager.sol";

// Local types
import {OrganizationState, OrganizationConfig, OrganizationType, OrganizationStatus, OrgRole} from "../types/OrganizationTypes.sol";
import {RaiseConfig} from "../types/RaiseTypes.sol";

// ============================================================================
// OrganizationManager
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.1
// Ticket: T-032
//
// Central singleton managing all organization state:
// - Organization creation (ICO and External types)
// - Role management (owner, team members, protocol admins)
// - Configuration updates (via governance)
// - Protocol-level settings (fees, pause state)
//
// Key invariants:
// - Only protocol admins can approve/reject organizations
// - Config updates require governance (passed proposal)
// - Owner can manage team, transfer ownership
// ============================================================================

contract OrganizationManager is IOrganizationManager {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // ============ Constants ============

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum fee share (50%)
    uint256 public constant MAX_FEE_SHARE_BPS = 5000;

    /// @notice Maximum pool fee (10%)
    uint24 public constant MAX_POOL_FEE_BPS = 100_000;

    /// @notice Default pool fee (0.3%)
    uint24 public constant DEFAULT_POOL_FEE = 3000;

    /// @notice Default tick spacing
    int24 public constant DEFAULT_TICK_SPACING = 60;

    // ============ Immutables ============

    /// @notice Permit2 contract
    IAllowanceTransfer public immutable permit2;

    /// @notice Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice Uniswap V4 PositionManager
    IPositionManager public immutable positionManager;

    /// @notice ConditionalTokenFactory
    ConditionalTokenFactory public immutable tokenFactory;

    /// @notice DecisionMarketManager
    DecisionMarketManager public immutable marketManager;

    // ============ State Variables ============

    /// @notice Total organizations created
    uint256 public orgCount;

    /// @notice Protocol fee recipient
    address public protocolFeeRecipient;

    /// @notice Treasury fee share in basis points
    uint256 public treasuryFeeShareBps;

    /// @notice Default pool fee for new pools
    uint24 public defaultPoolFeeBps;

    /// @notice Protocol paused state
    bool public paused;

    /// @notice Protocol admins
    mapping(address => bool) public protocolAdmins;

    /// @notice Organization state by ID
    mapping(uint256 orgId => OrganizationState) internal _organizations;

    /// @notice Organization config by ID
    mapping(uint256 orgId => OrganizationConfig) internal _configs;

    /// @notice Treasury addresses by org ID
    mapping(uint256 orgId => address) public treasuries;

    /// @notice ProposalManager addresses by org ID
    mapping(uint256 orgId => address) public proposalManagers;

    /// @notice Governance token addresses by org ID
    mapping(uint256 orgId => address) public governanceTokens;

    /// @notice Raise contract addresses by org ID
    mapping(uint256 orgId => address) public raises;

    /// @notice Role data by org ID and user
    mapping(uint256 orgId => mapping(address => OrgRole)) internal _roles;

    /// @notice Team member list by org ID
    mapping(uint256 orgId => address[]) internal _teamMembers;

    // ============ Modifiers ============

    modifier onlyProtocolAdmin() {
        if (!protocolAdmins[msg.sender]) revert NotProtocolAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert ProtocolNotPaused();
        _;
    }

    modifier orgExists(uint256 orgId) {
        if (orgId == 0 || orgId > orgCount) revert OrgNotFound(orgId);
        _;
    }

    modifier onlyOwner(uint256 orgId) {
        if (!_roles[orgId][msg.sender].isOwner) revert NotOrgOwner();
        _;
    }

    modifier onlyGovernance(uint256 orgId) {
        if (msg.sender != proposalManagers[orgId]) revert OnlyGovernance();
        _;
    }

    // ============ Constructor ============

    constructor(
        IAllowanceTransfer _permit2,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        ConditionalTokenFactory _tokenFactory,
        DecisionMarketManager _marketManager,
        address _initialAdmin
    ) {
        if (address(_permit2) == address(0)) revert ZeroAddress();
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        if (address(_positionManager) == address(0)) revert ZeroAddress();
        if (address(_tokenFactory) == address(0)) revert ZeroAddress();
        if (address(_marketManager) == address(0)) revert ZeroAddress();
        if (_initialAdmin == address(0)) revert ZeroAddress();

        permit2 = _permit2;
        poolManager = _poolManager;
        positionManager = _positionManager;
        tokenFactory = _tokenFactory;
        marketManager = _marketManager;

        protocolAdmins[_initialAdmin] = true;
        protocolFeeRecipient = _initialAdmin;
        defaultPoolFeeBps = DEFAULT_POOL_FEE;

        emit ProtocolAdminGranted(_initialAdmin);
    }

    // ============ Organization Creation ============

    /// @inheritdoc IOrganizationManager
    function createICOOrganization(
        string calldata metadataURI,
        address quoteToken,
        string calldata tokenName,
        string calldata tokenSymbol,
        OrganizationConfig calldata config,
        RaiseConfig calldata raiseConfig
    ) external override whenNotPaused returns (uint256 orgId) {
        if (quoteToken == address(0)) revert ZeroAddress();
        _validateConfig(config);
        _validateRaiseConfig(raiseConfig);

        orgId = ++orgCount;

        // Store organization state
        _organizations[orgId] = OrganizationState({
            orgType: OrganizationType.ICO,
            status: OrganizationStatus.Pending,
            metadataURI: metadataURI,
            baseToken: address(0), // Will be set when raise finalizes
            quoteToken: quoteToken,
            owner: msg.sender,
            createdAt: block.timestamp
        });

        // Store config
        _configs[orgId] = config;

        // Set owner role
        _roles[orgId][msg.sender] = OrgRole({
            isOwner: true,
            isTeamMember: false,
            customStakeThreshold: 0
        });

        // Note: Treasury, ProposalManager, GovernanceToken, and Raise are deployed
        // when the organization is approved and the raise starts

        emit OrganizationCreated(orgId, OrganizationType.ICO, msg.sender);
    }

    /// @inheritdoc IOrganizationManager
    function createExternalOrganization(
        string calldata metadataURI,
        address baseToken,
        address quoteToken,
        uint256 baseTokenAmount,
        uint256 quoteTokenAmount,
        OrganizationConfig calldata config
    ) external override whenNotPaused returns (uint256 orgId) {
        if (baseToken == address(0)) revert ZeroAddress();
        if (quoteToken == address(0)) revert ZeroAddress();
        if (baseTokenAmount == 0) revert InvalidConfig();
        if (quoteTokenAmount == 0) revert InvalidConfig();
        _validateConfig(config);

        orgId = ++orgCount;

        // Store organization state
        _organizations[orgId] = OrganizationState({
            orgType: OrganizationType.External,
            status: OrganizationStatus.Pending,
            metadataURI: metadataURI,
            baseToken: baseToken,
            quoteToken: quoteToken,
            owner: msg.sender,
            createdAt: block.timestamp
        });

        // Store config
        _configs[orgId] = config;

        // Set owner role
        _roles[orgId][msg.sender] = OrgRole({
            isOwner: true,
            isTeamMember: false,
            customStakeThreshold: 0
        });

        // Deploy Treasury
        Treasury treasury = new Treasury(permit2, poolManager, positionManager);
        treasuries[orgId] = address(treasury);

        // Initialize Treasury
        treasury.initialize(
            orgId,
            address(this),
            baseToken,
            quoteToken,
            address(positionManager)
        );

        // Deploy ProposalManager
        ProposalManager pm = new ProposalManager();
        proposalManagers[orgId] = address(pm);

        // Initialize ProposalManager
        pm.initialize(
            orgId,
            address(this),
            address(treasury),
            address(tokenFactory),
            address(marketManager)
        );

        // Set proposal manager on treasury
        treasury.setProposalManager(address(pm));

        // Transfer tokens from creator to treasury
        IERC20(baseToken).safeTransferFrom(
            msg.sender,
            address(treasury),
            baseTokenAmount
        );
        IERC20(quoteToken).safeTransferFrom(
            msg.sender,
            address(treasury),
            quoteTokenAmount
        );

        // Store governance token (existing token for external orgs)
        governanceTokens[orgId] = baseToken;

        emit OrganizationCreated(orgId, OrganizationType.External, msg.sender);
    }

    // ============ Organization Management ============

    /// @inheritdoc IOrganizationManager
    function updateConfig(
        uint256 orgId,
        OrganizationConfig calldata newConfig
    ) external override orgExists(orgId) onlyGovernance(orgId) {
        _validateConfig(newConfig);
        _configs[orgId] = newConfig;
        emit ConfigUpdated(orgId);
    }

    /// @inheritdoc IOrganizationManager
    function updateMetadata(
        uint256 orgId,
        string calldata uri
    ) external override orgExists(orgId) onlyGovernance(orgId) {
        _organizations[orgId].metadataURI = uri;
        emit MetadataUpdated(orgId, uri);
    }

    /// @inheritdoc IOrganizationManager
    function updateStatus(
        uint256 orgId,
        OrganizationStatus status
    ) external override orgExists(orgId) onlyProtocolAdmin {
        OrganizationStatus currentStatus = _organizations[orgId].status;

        // Validate status transitions
        if (currentStatus == OrganizationStatus.Pending) {
            // Can go to Approved or Rejected
            if (
                status != OrganizationStatus.Approved &&
                status != OrganizationStatus.Rejected
            ) {
                revert InvalidOrgStatus(currentStatus, status);
            }
        } else if (currentStatus == OrganizationStatus.Approved) {
            // ICO can go to Raise, External can go to Active
            OrganizationType orgType = _organizations[orgId].orgType;
            if (
                orgType == OrganizationType.ICO &&
                status != OrganizationStatus.Raise
            ) {
                revert InvalidOrgStatus(currentStatus, status);
            }
            if (
                orgType == OrganizationType.External &&
                status != OrganizationStatus.Active
            ) {
                revert InvalidOrgStatus(currentStatus, status);
            }
        } else if (currentStatus == OrganizationStatus.Raise) {
            // Can go to Active or Failed
            if (
                status != OrganizationStatus.Active &&
                status != OrganizationStatus.Failed
            ) {
                revert InvalidOrgStatus(currentStatus, status);
            }
        } else {
            // Other statuses are terminal
            revert InvalidOrgStatus(currentStatus, status);
        }

        _organizations[orgId].status = status;
        emit OrganizationStatusUpdated(orgId, status);
    }

    // ============ Role Management ============

    /// @inheritdoc IOrganizationManager
    function addTeamMember(
        uint256 orgId,
        address member
    ) external override orgExists(orgId) onlyOwner(orgId) whenNotPaused {
        if (member == address(0)) revert ZeroAddress();
        if (_roles[orgId][member].isTeamMember) revert MemberAlreadyExists();
        if (_roles[orgId][member].isOwner) revert MemberAlreadyExists();

        _roles[orgId][member].isTeamMember = true;
        _teamMembers[orgId].push(member);

        emit TeamMemberAdded(orgId, member);
    }

    /// @inheritdoc IOrganizationManager
    function removeTeamMember(
        uint256 orgId,
        address member
    ) external override orgExists(orgId) onlyOwner(orgId) whenNotPaused {
        if (!_roles[orgId][member].isTeamMember) revert MemberNotFound();

        _roles[orgId][member].isTeamMember = false;

        // Remove from team members array
        address[] storage members = _teamMembers[orgId];
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == member) {
                members[i] = members[members.length - 1];
                members.pop();
                break;
            }
        }

        emit TeamMemberRemoved(orgId, member);
    }

    /// @inheritdoc IOrganizationManager
    function transferOwnership(
        uint256 orgId,
        address newOwner
    ) external override orgExists(orgId) onlyOwner(orgId) whenNotPaused {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner == msg.sender) revert CannotTransferToSelf();

        address previousOwner = msg.sender;

        // Remove owner role from current owner
        _roles[orgId][previousOwner].isOwner = false;

        // Set owner role on new owner
        _roles[orgId][newOwner].isOwner = true;

        // Update organization state
        _organizations[orgId].owner = newOwner;

        emit OwnershipTransferred(orgId, previousOwner, newOwner);
    }

    // ============ Protocol Admin Functions ============

    /// @inheritdoc IOrganizationManager
    function grantProtocolAdmin(
        address account
    ) external override onlyProtocolAdmin {
        if (account == address(0)) revert ZeroAddress();
        protocolAdmins[account] = true;
        emit ProtocolAdminGranted(account);
    }

    /// @inheritdoc IOrganizationManager
    function revokeProtocolAdmin(
        address account
    ) external override onlyProtocolAdmin {
        if (account == msg.sender) revert InvalidConfig(); // Can't revoke self
        protocolAdmins[account] = false;
        emit ProtocolAdminRevoked(account);
    }

    /// @inheritdoc IOrganizationManager
    function setFeeRecipient(
        address recipient
    ) external override onlyProtocolAdmin {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    /// @inheritdoc IOrganizationManager
    function setTreasuryFeeShare(
        uint256 newShareBps
    ) external override onlyProtocolAdmin {
        if (newShareBps > MAX_FEE_SHARE_BPS) revert FeeExceedsMax();
        treasuryFeeShareBps = newShareBps;
        emit TreasuryFeeShareUpdated(newShareBps);
    }

    /// @inheritdoc IOrganizationManager
    function setDefaultPoolFee(
        uint24 newFeeBps
    ) external override onlyProtocolAdmin {
        if (newFeeBps > MAX_POOL_FEE_BPS) revert FeeExceedsMax();
        defaultPoolFeeBps = newFeeBps;
        emit DefaultPoolFeeUpdated(newFeeBps);
    }

    /// @inheritdoc IOrganizationManager
    function pause() external override onlyProtocolAdmin whenNotPaused {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IOrganizationManager
    function unpause() external override onlyProtocolAdmin whenPaused {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ============ View Functions ============

    /// @inheritdoc IOrganizationManager
    function getOrganization(
        uint256 orgId
    )
        external
        view
        override
        returns (
            OrganizationState memory state,
            OrganizationConfig memory config
        )
    {
        state = _organizations[orgId];
        config = _configs[orgId];
    }

    /// @inheritdoc IOrganizationManager
    function getEffectiveStakeThreshold(
        uint256 orgId,
        address user
    ) external view override orgExists(orgId) returns (uint256 threshold) {
        OrgRole memory role = _roles[orgId][user];
        OrganizationConfig memory config = _configs[orgId];

        // Check for custom threshold first
        if (role.customStakeThreshold > 0) {
            return role.customStakeThreshold;
        }

        // Calculate based on role
        address baseToken = _organizations[orgId].baseToken;
        if (baseToken == address(0)) {
            return config.defaultStakingThreshold;
        }

        uint256 totalSupply = IERC20(baseToken).totalSupply();

        if (role.isOwner) {
            return
                (totalSupply * config.ownerStakingThresholdBps) /
                BPS_DENOMINATOR;
        } else if (role.isTeamMember) {
            return
                (totalSupply * config.teamStakingThresholdBps) /
                BPS_DENOMINATOR;
        } else {
            return config.defaultStakingThreshold;
        }
    }

    /// @inheritdoc IOrganizationManager
    function isTeamMember(
        uint256 orgId,
        address user
    ) external view override returns (bool) {
        return _roles[orgId][user].isTeamMember;
    }

    /// @inheritdoc IOrganizationManager
    function isOwner(
        uint256 orgId,
        address user
    ) external view override returns (bool) {
        return _roles[orgId][user].isOwner;
    }

    // ============ Internal Functions ============

    /// @notice Validate organization configuration
    function _validateConfig(OrganizationConfig calldata config) internal pure {
        if (config.stakingDuration == 0) revert InvalidConfig();
        if (config.tradingDuration == 0) revert InvalidConfig();
        if (config.lpAllocationPerProposalBps == 0) revert InvalidConfig();
        if (config.lpAllocationPerProposalBps > BPS_DENOMINATOR)
            revert InvalidConfig();
    }

    /// @notice Validate raise configuration
    function _validateRaiseConfig(RaiseConfig calldata config) internal view {
        if (config.softCap == 0) revert InvalidRaiseConfig();
        if (config.hardCap < config.softCap) revert InvalidRaiseConfig();
        if (config.startDate < block.timestamp) revert InvalidRaiseConfig();
        if (config.endDate <= config.startDate) revert InvalidRaiseConfig();
    }

    /// @notice Get team members for an organization
    function getTeamMembers(
        uint256 orgId
    ) external view returns (address[] memory) {
        return _teamMembers[orgId];
    }

    /// @notice Get role data for a user in an organization
    function getRole(
        uint256 orgId,
        address user
    ) external view returns (OrgRole memory) {
        return _roles[orgId][user];
    }
}
