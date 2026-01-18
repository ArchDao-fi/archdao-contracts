// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

// ============================================================================
// IGovernanceToken
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.8
// Standard ERC-20 with RBAC-controlled minting for ICO organizations.
// Note: 1B token supply cap (per Q3 answer)
// ============================================================================

interface IGovernanceToken is IERC20Metadata, IAccessControl {
    // ============ Errors ============

    /// @notice Minting would exceed max supply
    error ExceedsMaxSupply(uint256 requested, uint256 maxSupply);

    // ============ Minting/Burning ============

    /// @notice Mint governance tokens
    /// @dev Only callable by addresses with MINTER_ROLE
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burn governance tokens from caller's balance
    /// @param amount Amount to burn
    function burn(uint256 amount) external;

    // ============ View Functions ============

    /// @notice Get the MINTER_ROLE bytes32 constant
    function MINTER_ROLE() external view returns (bytes32);

    /// @notice Maximum token supply (1B tokens)
    function MAX_SUPPLY() external view returns (uint256);
}
