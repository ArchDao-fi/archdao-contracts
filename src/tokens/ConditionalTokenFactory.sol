// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OpenZeppelin
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Local interfaces
import {IConditionalTokenFactory} from "../interfaces/IConditionalTokenFactory.sol";

// Local contracts
import {ConditionalToken} from "./ConditionalToken.sol";

// Local types
import {ConditionalTokenSet} from "../types/ProposalTypes.sol";

// ============================================================================
// ConditionalTokenFactory
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.4
// Ticket: T-019
//
// Singleton factory that deploys conditional token sets for proposals.
// Creates four tokens per proposal:
// - pToken: Pass conditional backed by baseToken
// - fToken: Fail conditional backed by baseToken
// - pQuote: Pass conditional backed by quoteToken
// - fQuote: Fail conditional backed by quoteToken
//
// Token naming convention:
// - pToken: "pToken-{baseSymbol}-{proposalId}"
// - fToken: "fToken-{baseSymbol}-{proposalId}"
// - pQuote: "pQuote-{quoteSymbol}-{proposalId}"
// - fQuote: "fQuote-{quoteSymbol}-{proposalId}"
// ============================================================================

contract ConditionalTokenFactory is IConditionalTokenFactory {
    // ============ State Variables ============

    /// @notice Mapping from proposal ID to its conditional token set
    mapping(uint256 proposalId => ConditionalTokenSet) public proposalTokens;

    /// @notice Mapping from token address to its proposal ID
    mapping(address token => uint256 proposalId) public tokenToProposal;

    // ============ External Functions ============

    /// @inheritdoc IConditionalTokenFactory
    function deployConditionalSet(
        uint256 proposalId,
        address baseToken,
        address quoteToken,
        address minter
    ) external override returns (ConditionalTokenSet memory tokens) {
        // Validate inputs
        if (baseToken == address(0)) revert ZeroAddress();
        if (quoteToken == address(0)) revert ZeroAddress();
        if (minter == address(0)) revert ZeroAddress();

        // Check if set already exists for this proposal
        if (proposalTokens[proposalId].pToken != address(0)) {
            revert ConditionalSetExists(proposalId);
        }

        // Deploy base token pair (pToken, fToken)
        (address pToken, address fToken) = _deployTokenPair(
            baseToken,
            proposalId,
            minter,
            true // isBaseToken
        );

        // Deploy quote token pair (pQuote, fQuote)
        (address pQuote, address fQuote) = _deployTokenPair(
            quoteToken,
            proposalId,
            minter,
            false // isBaseToken
        );

        // Store the token set
        tokens = ConditionalTokenSet({
            pToken: pToken,
            fToken: fToken,
            pQuote: pQuote,
            fQuote: fQuote
        });
        proposalTokens[proposalId] = tokens;

        // Map tokens back to proposal
        tokenToProposal[pToken] = proposalId;
        tokenToProposal[fToken] = proposalId;
        tokenToProposal[pQuote] = proposalId;
        tokenToProposal[fQuote] = proposalId;

        emit ConditionalSetDeployed(proposalId, pToken, fToken, pQuote, fQuote);

        return tokens;
    }

    // ============ View Functions ============

    /// @inheritdoc IConditionalTokenFactory
    function getConditionalTokens(
        uint256 proposalId
    ) external view override returns (ConditionalTokenSet memory tokens) {
        tokens = proposalTokens[proposalId];
        if (tokens.pToken == address(0)) {
            revert ConditionalSetNotFound(proposalId);
        }
        return tokens;
    }

    /// @inheritdoc IConditionalTokenFactory
    function getProposalForToken(
        address token
    ) external view override returns (uint256) {
        return tokenToProposal[token];
    }

    // ============ Internal Functions ============

    /// @notice Deploy a pair of pass/fail conditional tokens
    /// @param collateralToken The collateral token to derive decimals and symbol from
    /// @param proposalId The proposal ID for naming
    /// @param minter The minter address
    /// @param isBaseToken True if deploying for base token, false for quote
    /// @return passToken The pass conditional token address
    /// @return failToken The fail conditional token address
    function _deployTokenPair(
        address collateralToken,
        uint256 proposalId,
        address minter,
        bool isBaseToken
    ) internal returns (address passToken, address failToken) {
        string memory symbol = IERC20Metadata(collateralToken).symbol();
        uint8 decimals_ = IERC20Metadata(collateralToken).decimals();
        string memory idStr = _toString(proposalId);

        string memory passPrefix = isBaseToken ? "pToken-" : "pQuote-";
        string memory failPrefix = isBaseToken ? "fToken-" : "fQuote-";
        string memory passSymbolPrefix = "p";
        string memory failSymbolPrefix = "f";

        passToken = address(
            new ConditionalToken(
                string.concat(passPrefix, symbol, "-", idStr),
                string.concat(passSymbolPrefix, symbol, "-", idStr),
                decimals_,
                minter
            )
        );

        failToken = address(
            new ConditionalToken(
                string.concat(failPrefix, symbol, "-", idStr),
                string.concat(failSymbolPrefix, symbol, "-", idStr),
                decimals_,
                minter
            )
        );
    }

    /// @notice Convert uint256 to string
    /// @param value The value to convert
    /// @return str The string representation
    function _toString(
        uint256 value
    ) internal pure returns (string memory str) {
        if (value == 0) {
            return "0";
        }

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}
