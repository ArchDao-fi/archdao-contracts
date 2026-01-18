// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

// ============================================================================
// IConditionalToken
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.5
// ERC-20 conditional token with RBAC-controlled minting.
// Factory tracks proposal/collateral metadata - token just needs mint/burn.
// ============================================================================

interface IConditionalToken is IERC20, IAccessControl {
    // ============ Minting/Burning ============

    /// @notice Mint conditional tokens
    /// @dev Only callable by addresses with MINTER_ROLE
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burn conditional tokens
    /// @dev Only callable by addresses with MINTER_ROLE
    /// @param from Address to burn from
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external;

    // ============ View Functions ============

    /// @notice Get the MINTER_ROLE bytes32 constant
    function MINTER_ROLE() external view returns (bytes32);

    /// @notice Get token decimals
    function decimals() external view returns (uint8);
}
