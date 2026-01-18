// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// ============================================================================
// Proposal Types
// ============================================================================
// Source of Truth: SPECIFICATION.md §5
// ============================================================================

/// @notice Proposal lifecycle status
enum ProposalStatus {
    Staking, // Gathering stake support
    Active, // Trading period
    Resolved, // Outcome determined, awaiting execution
    Executed, // All actions executed (pass) or finalized (fail)
    Cancelled, // Cancelled during staking
    Failed // Resolved but did not pass
}

/// @notice Proposal resolution outcome
enum ProposalOutcome {
    None, // Not yet resolved
    Pass, // Passed, actions can execute
    Fail // Failed, no actions execute
}

/// @notice Type of proposal action
enum ActionType {
    TreasurySpend, // Transfer tokens from treasury
    MintTokens, // Mint governance tokens
    BurnTokens, // Burn governance tokens from treasury
    AdjustLP, // Modify treasury LP position
    UpdateMetadata, // Update org metadata URI
    UpdateConfig, // Update org config
    Custom // Arbitrary contract call
}

/// @notice Condition for action execution
enum ExecutionCondition {
    Immediate, // Execute right after resolution
    TimeLocked, // Execute after delay
    MarketCapThreshold, // Execute when mcap >= X
    PriceThreshold, // Execute when price >= X
    CustomOracle // Execute when oracle condition met
}

/// @notice Conditional token set for a proposal
struct ConditionalTokenSet {
    address pToken;
    address fToken;
    address pQuote;
    address fQuote;
}

/// @notice Single action within a proposal
struct ProposalAction {
    ActionType actionType;
    address target;
    bytes data;
    uint256 value;
    ExecutionCondition condition;
    bytes conditionData;
    bool executed;
}

/// @notice Full proposal data
struct Proposal {
    uint256 id;
    address proposer;
    bool isTeamSponsored;
    ProposalStatus status;
    ProposalOutcome outcome;
    // Staking
    uint256 totalStaked;
    uint256 stakingEndsAt;
    // Trading
    uint256 tradingStartsAt;
    uint256 tradingEndsAt;
    uint256 twapRecordingStartsAt;
    // Reserves (snapshot at activation)
    uint256 baseTokenReserve;
    uint256 quoteTokenReserve;
    // Conditional tokens
    ConditionalTokenSet tokens;
    // Markets
    PoolKey passPoolKey;
    PoolKey failPoolKey;
    // Resolution
    uint256 passTwap;
    uint256 failTwap;
    uint256 resolvedAt;
    // Actions
    ProposalAction[] actions;
}
