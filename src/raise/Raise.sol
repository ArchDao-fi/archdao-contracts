// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Local interfaces
import {IRaise} from "../interfaces/IRaise.sol";
import {IOrganizationManager} from "../interfaces/IOrganizationManager.sol";
import {IGovernanceToken} from "../interfaces/IGovernanceToken.sol";

// Local types
import {RaiseConfig, RaiseStatus} from "../types/RaiseTypes.sol";
import {OrganizationConfig, OrganizationStatus} from "../types/OrganizationTypes.sol";

// ============================================================================
// Raise
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.10
// Ticket: T-036
//
// Handles ICO contributions and token distribution.
// - Contributors deposit quote tokens during the raise period
// - Protocol admin finalizes with an accepted amount
// - Contributors claim tokens proportionally
// - Excess contributions are refundable
// ============================================================================

contract Raise is IRaise {
    using SafeERC20 for IERC20;

    // ============ State Variables ============

    /// @notice Organization ID this raise is for
    uint256 public override organizationId;

    /// @notice OrganizationManager contract
    IOrganizationManager public manager;

    /// @notice Current raise status
    RaiseStatus public override status;

    /// @notice Minimum raise target
    uint256 public override softCap;

    /// @notice Maximum raise limit
    uint256 public override hardCap;

    /// @notice Amount accepted by admin (set during finalization)
    uint256 public override acceptedAmount;

    /// @notice Total contributed so far
    uint256 public override totalContributed;

    /// @notice Raise start timestamp
    uint256 public override startDate;

    /// @notice Raise end timestamp
    uint256 public override endDate;

    /// @notice Quote token for contributions
    IERC20 internal _quoteToken;

    /// @notice Agreed organization config for this raise
    OrganizationConfig internal _agreedConfig;

    /// @notice Contribution amounts by address
    mapping(address => uint256) public override contributions;

    /// @notice List of contributor addresses
    address[] internal _contributors;

    /// @notice Whether contributor has claimed tokens
    mapping(address => bool) public override hasClaimed;

    /// @notice Whether contributor has been refunded
    mapping(address => bool) public hasRefunded;

    /// @notice Whether the contract has been initialized
    bool public initialized;

    /// @notice Governance token deployed for this raise
    IGovernanceToken public governanceToken;

    /// @notice Total tokens allocated for distribution
    uint256 public totalTokensForDistribution;

    // ============ Modifiers ============

    modifier onlyProtocolAdmin() {
        if (!manager.protocolAdmins(msg.sender)) revert NotAuthorized();
        _;
    }

    // ============ Initialization ============

    /// @inheritdoc IRaise
    function initialize(
        uint256 orgId,
        address _manager,
        RaiseConfig calldata config
    ) external override {
        if (initialized) revert AlreadyInitialized();
        if (_manager == address(0)) revert ZeroAddress();
        if (config.quoteToken == address(0)) revert ZeroAddress();
        if (config.softCap == 0) revert InvalidConfig();
        if (config.hardCap < config.softCap) revert InvalidConfig();
        if (config.startDate >= config.endDate) revert InvalidConfig();

        initialized = true;
        organizationId = orgId;
        manager = IOrganizationManager(_manager);
        softCap = config.softCap;
        hardCap = config.hardCap;
        startDate = config.startDate;
        endDate = config.endDate;
        _quoteToken = IERC20(config.quoteToken);
        _agreedConfig = config.agreedConfig;
        status = RaiseStatus.Pending;
    }

    // ============ Contribution ============

    /// @inheritdoc IRaise
    function contribute(uint256 amount) external override {
        if (status != RaiseStatus.Active) revert RaiseNotActive();
        if (block.timestamp < startDate) revert RaiseNotStarted();
        if (block.timestamp > endDate) revert RaiseEnded();
        if (amount == 0) revert ZeroContribution();

        uint256 remaining = hardCap - totalContributed;
        if (amount > remaining) revert ExceedsHardCap(amount, remaining);

        // Track new contributors
        if (contributions[msg.sender] == 0) {
            _contributors.push(msg.sender);
        }

        contributions[msg.sender] += amount;
        totalContributed += amount;

        _quoteToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Contributed(msg.sender, amount);
    }

    // ============ Finalization ============

    /// @inheritdoc IRaise
    function finalize(
        uint256 _acceptedAmount
    ) external override onlyProtocolAdmin {
        if (status != RaiseStatus.Active && status != RaiseStatus.Pending) {
            revert RaiseNotActive();
        }
        if (block.timestamp <= endDate) revert RaiseNotEnded();
        if (_acceptedAmount < softCap)
            revert BelowSoftCap(_acceptedAmount, softCap);
        if (_acceptedAmount > totalContributed) {
            revert AcceptedExceedsContributed(
                _acceptedAmount,
                totalContributed
            );
        }

        acceptedAmount = _acceptedAmount;
        status = RaiseStatus.Completed;

        // Get governance token from OrganizationManager
        address tokenAddr = manager.governanceTokens(organizationId);
        if (tokenAddr == address(0)) revert ZeroAddress();
        governanceToken = IGovernanceToken(tokenAddr);

        // Calculate tokens for distribution
        // Per spec: Tokens are minted by OrganizationManager when it deploys the token
        // The Raise contract receives tokens to distribute to contributors
        totalTokensForDistribution = governanceToken.balanceOf(address(this));

        // Transfer accepted amount to treasury
        address treasury = manager.treasuries(organizationId);
        if (treasury != address(0)) {
            _quoteToken.safeTransfer(treasury, _acceptedAmount);
        }

        emit RaiseFinalized(_acceptedAmount, totalTokensForDistribution);
    }

    /// @inheritdoc IRaise
    function fail() external override onlyProtocolAdmin {
        if (status != RaiseStatus.Active && status != RaiseStatus.Pending) {
            revert RaiseNotActive();
        }

        status = RaiseStatus.Failed;

        emit RaiseFailed();
    }

    // ============ Claims & Refunds ============

    /// @inheritdoc IRaise
    function claimTokens() external override {
        if (status != RaiseStatus.Completed) revert NotRefundable();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();
        if (contributions[msg.sender] == 0) revert NoContribution();

        uint256 claimable = getClaimableAmount(msg.sender);
        if (claimable == 0) revert NoContribution();

        hasClaimed[msg.sender] = true;

        // Transfer tokens to contributor
        IERC20(address(governanceToken)).safeTransfer(msg.sender, claimable);

        emit TokensClaimed(msg.sender, claimable);
    }

    /// @inheritdoc IRaise
    function refund() external override {
        uint256 refundable = getRefundableAmount(msg.sender);
        if (refundable == 0) revert NothingToRefund();
        if (hasRefunded[msg.sender]) revert NothingToRefund();

        hasRefunded[msg.sender] = true;

        // If raise failed, refund full contribution
        // If raise completed but contribution > accepted proportion, refund excess
        _quoteToken.safeTransfer(msg.sender, refundable);

        emit Refunded(msg.sender, refundable);
    }

    // ============ Admin Functions ============

    /// @notice Start the raise (transition from Pending to Active)
    /// @dev Only callable by OrganizationManager
    function start() external {
        if (msg.sender != address(manager)) revert NotAuthorized();
        if (status != RaiseStatus.Pending) revert RaiseNotActive();

        status = RaiseStatus.Active;
    }

    /// @notice Set the governance token address
    /// @dev Only callable by OrganizationManager
    function setGovernanceToken(address token) external {
        if (msg.sender != address(manager)) revert NotAuthorized();
        if (token == address(0)) revert ZeroAddress();

        governanceToken = IGovernanceToken(token);
    }

    // ============ View Functions ============

    /// @inheritdoc IRaise
    function quoteToken() external view override returns (address token) {
        return address(_quoteToken);
    }

    /// @inheritdoc IRaise
    function agreedConfig()
        external
        view
        override
        returns (OrganizationConfig memory config)
    {
        return _agreedConfig;
    }

    /// @inheritdoc IRaise
    function contributors(
        uint256 index
    ) external view override returns (address contributor) {
        return _contributors[index];
    }

    /// @inheritdoc IRaise
    function getContributorCount()
        external
        view
        override
        returns (uint256 count)
    {
        return _contributors.length;
    }

    /// @inheritdoc IRaise
    function getClaimableAmount(
        address contributor
    ) public view override returns (uint256 amount) {
        if (status != RaiseStatus.Completed) return 0;
        if (hasClaimed[contributor]) return 0;
        if (contributions[contributor] == 0) return 0;
        if (totalTokensForDistribution == 0) return 0;
        if (acceptedAmount == 0) return 0;

        // Calculate effective contribution (capped at accepted proportion)
        uint256 userContribution = contributions[contributor];
        uint256 effectiveContribution;

        if (totalContributed <= acceptedAmount) {
            // All contributions accepted
            effectiveContribution = userContribution;
        } else {
            // Pro-rata calculation
            effectiveContribution =
                (userContribution * acceptedAmount) /
                totalContributed;
        }

        // Calculate token share
        return
            (effectiveContribution * totalTokensForDistribution) /
            acceptedAmount;
    }

    /// @inheritdoc IRaise
    function getRefundableAmount(
        address contributor
    ) public view override returns (uint256 amount) {
        if (hasRefunded[contributor]) return 0;
        if (contributions[contributor] == 0) return 0;

        // Full refund if raise failed
        if (status == RaiseStatus.Failed) {
            return contributions[contributor];
        }

        // Partial refund if raise completed but oversubscribed
        if (
            status == RaiseStatus.Completed && totalContributed > acceptedAmount
        ) {
            uint256 userContribution = contributions[contributor];
            uint256 acceptedPortion = (userContribution * acceptedAmount) /
                totalContributed;
            return userContribution - acceptedPortion;
        }

        return 0;
    }
}
