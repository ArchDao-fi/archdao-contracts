// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ConditionalTokenSet} from "../types/ProposalTypes.sol";

// ============================================================================
// IDecisionMarketManager
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.6
// Manages Uniswap V4 decision market pools
// ============================================================================

interface IDecisionMarketManager {
    // ============ Errors ============

    /// @notice Address is zero when it shouldn't be
    error ZeroAddress();

    /// @notice Caller is not the ProposalManager
    error NotProposalManager();

    /// @notice Markets already initialized for this proposal
    error MarketsAlreadyInitialized(uint256 proposalId);

    /// @notice Markets not initialized for this proposal
    error MarketsNotInitialized(uint256 proposalId);

    // ============ Events ============

    event MarketsInitialized(
        uint256 indexed proposalId,
        PoolKey passPool,
        PoolKey failPool
    );
    event LiquidityRemoved(
        uint256 indexed proposalId,
        uint256 pTokenAmount,
        uint256 pQuoteAmount,
        uint256 fTokenAmount,
        uint256 fQuoteAmount
    );
    event FeesCollected(uint256 indexed proposalId, uint256 totalFees);

    // ============ Market Initialization ============

    /// @notice Initialize decision markets for a proposal
    /// @dev Creates both pass and fail pools with full-range liquidity
    /// @param proposalId Proposal ID
    /// @param tokens Conditional token set
    /// @param baseAmount Amount of each base conditional (pToken, fToken)
    /// @param quoteAmount Amount of each quote conditional (pQuote, fQuote)
    /// @param sqrtPriceX96 Initial sqrt price (derived from spot pool per Q2)
    /// @param observationMaxRateBpsPerSecond TWAP rate limit
    /// @param twapRecordingStartTime When TWAP recording should begin
    /// @return poolKeys Array of [passPoolKey, failPoolKey]
    function initializeMarkets(
        uint256 proposalId,
        ConditionalTokenSet calldata tokens,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint160 sqrtPriceX96,
        uint256 observationMaxRateBpsPerSecond,
        uint256 twapRecordingStartTime
    ) external returns (PoolKey[2] memory poolKeys);

    // ============ Liquidity Management ============

    /// @notice Remove all liquidity from decision markets
    /// @dev Called during proposal resolution
    /// @param proposalId Proposal ID
    /// @return pTokenAmount Amount of pToken recovered
    /// @return pQuoteAmount Amount of pQuote recovered
    /// @return fTokenAmount Amount of fToken recovered
    /// @return fQuoteAmount Amount of fQuote recovered
    function removeLiquidity(
        uint256 proposalId
    )
        external
        returns (
            uint256 pTokenAmount,
            uint256 pQuoteAmount,
            uint256 fTokenAmount,
            uint256 fQuoteAmount
        );

    // ============ Fee Collection ============

    /// @notice Collect trading fees from decision markets
    /// @param proposalId Proposal ID
    /// @return pTokenFees pToken fees collected
    /// @return pQuoteFees pQuote fees collected
    /// @return fTokenFees fToken fees collected
    /// @return fQuoteFees fQuote fees collected
    function collectFees(
        uint256 proposalId
    )
        external
        returns (
            uint256 pTokenFees,
            uint256 pQuoteFees,
            uint256 fTokenFees,
            uint256 fQuoteFees
        );

    // ============ View Functions ============

    /// @notice Get pool keys for a proposal
    /// @param proposalId Proposal ID
    /// @return poolKeys Array of [passPoolKey, failPoolKey]
    function getPoolKeys(
        uint256 proposalId
    ) external view returns (PoolKey[2] memory poolKeys);

    /// @notice Get current spot prices from decision markets
    /// @param proposalId Proposal ID
    /// @return passPrice Current price in pass market
    /// @return failPrice Current price in fail market
    function getSpotPrices(
        uint256 proposalId
    ) external view returns (uint256 passPrice, uint256 failPrice);

    /// @notice Get TWAPs from decision markets
    /// @param proposalId Proposal ID
    /// @return passTwap TWAP from pass market
    /// @return failTwap TWAP from fail market
    function getTWAPs(
        uint256 proposalId
    ) external view returns (uint256 passTwap, uint256 failTwap);

    /// @notice Get position token IDs for a proposal
    /// @param proposalId Proposal ID
    /// @return positionIds Array of [passPositionId, failPositionId]
    function getPositionIds(
        uint256 proposalId
    ) external view returns (uint256[2] memory positionIds);
}
