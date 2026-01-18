// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Proposal, ProposalAction, ConditionalTokenSet, ProposalStatus, ProposalOutcome} from "../types/ProposalTypes.sol";

// ============================================================================
// IProposalManager
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.3
// Manages the complete proposal lifecycle
// ============================================================================

interface IProposalManager {
    // ============ Errors ============

    /// @notice Address is zero when it shouldn't be
    error ZeroAddress();

    /// @notice Already initialized
    error AlreadyInitialized();

    /// @notice Not initialized
    error NotInitialized();

    /// @notice An active proposal already exists
    error ProposalExists();

    /// @notice Proposal not found
    error ProposalNotFound(uint256 proposalId);

    /// @notice Invalid proposal status for operation
    error InvalidProposalStatus(
        ProposalStatus current,
        ProposalStatus required
    );

    /// @notice Staking threshold not met
    error StakingThresholdNotMet(uint256 current, uint256 required);

    /// @notice Staking period not ended
    error StakingPeriodNotEnded();

    /// @notice Trading period not ended
    error TradingNotEnded();

    /// @notice Action already executed
    error ActionAlreadyExecuted(uint256 actionIndex);

    /// @notice Execution condition not met
    error ExecutionConditionNotMet();

    /// @notice Insufficient stake to unstake
    error InsufficientStake();

    /// @notice Not proposer
    error NotProposer();

    /// @notice Not authorized (not team or owner)
    error NotAuthorized();

    /// @notice Cancellation delay not passed
    error CancellationDelayNotPassed();

    /// @notice No actions provided
    error NoActions();

    /// @notice Proposal did not pass
    error ProposalDidNotPass();

    /// @notice Invalid action index
    error InvalidActionIndex(uint256 index);

    /// @notice Markets not initialized for proposal
    error MarketsNotInitialized();

    /// @notice Cannot redeem - wrong status
    error CannotRedeem();

    /// @notice Nothing to redeem
    error NothingToRedeem();

    // ============ Events ============

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        bool isTeamSponsored
    );
    event Staked(
        uint256 indexed proposalId,
        address indexed staker,
        uint256 amount
    );
    event Unstaked(
        uint256 indexed proposalId,
        address indexed staker,
        uint256 amount
    );
    event StakesRefunded(uint256 indexed proposalId, uint256 totalRefunded);
    event ProposalActivated(
        uint256 indexed proposalId,
        uint256 baseTokenReserve,
        uint256 quoteTokenReserve
    );
    event ProposalCancelled(
        uint256 indexed proposalId,
        address indexed cancelledBy
    );
    event ProposalResolved(
        uint256 indexed proposalId,
        ProposalOutcome outcome,
        uint256 passTwap,
        uint256 failTwap
    );
    event ActionExecuted(
        uint256 indexed proposalId,
        uint256 indexed actionIndex
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalFailed(uint256 indexed proposalId);
    event TokensSplit(
        uint256 indexed proposalId,
        address indexed user,
        bool isBaseToken,
        uint256 amount
    );
    event TokensMerged(
        uint256 indexed proposalId,
        address indexed user,
        bool isBaseToken,
        uint256 amount
    );
    event TokensRedeemed(
        uint256 indexed proposalId,
        address indexed user,
        uint256 baseAmount,
        uint256 quoteAmount
    );

    // ============ Initialization ============

    /// @notice Initialize the proposal manager
    /// @param orgId Organization ID this manager belongs to
    /// @param manager OrganizationManager contract address
    /// @param treasury Treasury contract address
    /// @param tokenFactory ConditionalTokenFactory contract address
    /// @param marketManager DecisionMarketManager contract address
    function initialize(
        uint256 orgId,
        address manager,
        address treasury,
        address tokenFactory,
        address marketManager
    ) external;

    // ============ Proposal Lifecycle ============

    /// @notice Create a new proposal
    /// @dev Requires no existing non-terminal proposal and caller is owner or team member
    /// @param actions Array of proposal actions to execute if passed
    /// @return proposalId The newly created proposal ID
    function createProposal(
        ProposalAction[] calldata actions
    ) external returns (uint256 proposalId);

    /// @notice Stake tokens on a proposal
    /// @param proposalId Proposal to stake on
    /// @param amount Amount of base tokens to stake
    function stake(uint256 proposalId, uint256 amount) external;

    /// @notice Unstake tokens from a proposal
    /// @param proposalId Proposal to unstake from
    /// @param amount Amount to unstake
    function unstake(uint256 proposalId, uint256 amount) external;

    /// @notice Activate a proposal after staking threshold is met
    /// @dev Refunds all stakes, withdraws LP, deploys conditional tokens, initializes markets
    /// @param proposalId Proposal to activate
    function activateProposal(uint256 proposalId) external;

    /// @notice Cancel a proposal during staking period
    /// @dev Refunds all stakes, can be called by owner, team member, or protocol admin
    /// @param proposalId Proposal to cancel
    function cancelProposal(uint256 proposalId) external;

    /// @notice Resolve a proposal after trading period ends
    /// @dev Fetches final TWAPs, determines outcome, collects fees, removes LP
    /// @param proposalId Proposal to resolve
    function resolve(uint256 proposalId) external;

    /// @notice Execute a single action from a passed proposal
    /// @dev Actions must be executed in order (sequential: 0, 1, 2...)
    /// @param proposalId Proposal containing the action
    /// @param actionIndex Index of the action to execute
    function executeAction(uint256 proposalId, uint256 actionIndex) external;

    // ============ Conditional Token Operations ============

    /// @notice Split collateral into conditional tokens
    /// @param proposalId Proposal to split for
    /// @param isBaseToken True for base token, false for quote token
    /// @param amount Amount of collateral to split
    function split(
        uint256 proposalId,
        bool isBaseToken,
        uint256 amount
    ) external;

    /// @notice Merge conditional tokens back into collateral
    /// @param proposalId Proposal to merge for
    /// @param isBaseToken True for base token, false for quote token
    /// @param amount Amount of each conditional to merge
    function merge(
        uint256 proposalId,
        bool isBaseToken,
        uint256 amount
    ) external;

    /// @notice Redeem winning conditional tokens after resolution
    /// @param proposalId Proposal to redeem from
    function redeem(uint256 proposalId) external;

    // ============ View Functions ============

    /// @notice Get full proposal data
    /// @param proposalId Proposal ID
    /// @return proposal The proposal struct
    function getProposal(
        uint256 proposalId
    ) external view returns (Proposal memory proposal);

    /// @notice Get a staker's stake amount on a proposal
    /// @param proposalId Proposal ID
    /// @param staker Staker address
    /// @return amount Staked amount
    function getStake(
        uint256 proposalId,
        address staker
    ) external view returns (uint256 amount);

    /// @notice Check if proposal can be activated
    /// @param proposalId Proposal ID
    /// @return canActivate True if activation conditions are met
    function canActivate(
        uint256 proposalId
    ) external view returns (bool canActivate);

    /// @notice Check if proposal can be resolved
    /// @param proposalId Proposal ID
    /// @return canResolve True if resolution conditions are met
    function canResolve(
        uint256 proposalId
    ) external view returns (bool canResolve);

    /// @notice Check if proposal can be cancelled
    /// @param proposalId Proposal ID
    /// @return canCancel True if cancellation conditions are met
    function canCancel(
        uint256 proposalId
    ) external view returns (bool canCancel);

    /// @notice Get organization ID
    /// @return id Organization ID
    function orgId() external view returns (uint256 id);

    /// @notice Get proposal count
    /// @return count Total proposals created
    function proposalCount() external view returns (uint256 count);

    /// @notice Get active proposal ID (0 if none)
    /// @return id Active proposal ID
    function activeProposalId() external view returns (uint256 id);

    /// @notice Check if initialized
    /// @return isInit True if initialized
    function initialized() external view returns (bool isInit);
}
