// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ConditionalTokenSet} from "../types/ProposalTypes.sol";

// ============================================================================
// IConditionalTokenFactory
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.4
// Deploys conditional token sets for proposals
// ============================================================================

interface IConditionalTokenFactory {
    // ============ Errors ============

    /// @notice Address is zero when it shouldn't be
    error ZeroAddress();

    /// @notice Conditional set already deployed for this proposal
    error ConditionalSetExists(uint256 proposalId);

    /// @notice Conditional set not found for this proposal
    error ConditionalSetNotFound(uint256 proposalId);

    // ============ Events ============

    event ConditionalSetDeployed(
        uint256 indexed proposalId,
        address pToken,
        address fToken,
        address pQuote,
        address fQuote
    );

    // ============ Factory Functions ============

    /// @notice Deploy a complete set of conditional tokens for a proposal
    /// @dev Only callable by ProposalManager
    /// @param proposalId The proposal ID these tokens are for
    /// @param baseToken Base collateral token address
    /// @param quoteToken Quote collateral token address
    /// @param minter Address authorized to mint/burn (ProposalManager)
    /// @return tokens The deployed conditional token set
    function deployConditionalSet(
        uint256 proposalId,
        address baseToken,
        address quoteToken,
        address minter
    ) external returns (ConditionalTokenSet memory tokens);

    // ============ View Functions ============

    /// @notice Get conditional tokens for a proposal
    /// @param proposalId Proposal ID
    /// @return tokens The conditional token set
    function getConditionalTokens(
        uint256 proposalId
    ) external view returns (ConditionalTokenSet memory tokens);

    /// @notice Get proposal ID for a conditional token address
    /// @param token Conditional token address
    /// @return proposalId The proposal ID (0 if not found)
    function getProposalForToken(
        address token
    ) external view returns (uint256 proposalId);
}
