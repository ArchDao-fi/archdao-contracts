// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OpenZeppelin
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

// Local interfaces
import {IConditionalToken} from "../interfaces/IConditionalToken.sol";

// ============================================================================
// ConditionalToken
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.5
// Ticket: T-017
//
// Simple ERC-20 with RBAC-controlled minting for conditional markets.
// Uses OpenZeppelin AccessControl for role management.
// ============================================================================

contract ConditionalToken is ERC20, AccessControl, IConditionalToken {
    // ============ Constants ============

    /// @notice Role that can mint and burn tokens
    bytes32 public constant override MINTER_ROLE = keccak256("MINTER_ROLE");

    // ============ Immutables ============

    /// @notice Decimals (passed in at deployment, should match collateral)
    uint8 private immutable _decimals;

    // ============ Constructor ============

    /// @notice Deploy a new conditional token
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param decimals_ Token decimals (should match collateral)
    /// @param minter_ Address that receives MINTER_ROLE (immutable)
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address minter_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        _grantRole(MINTER_ROLE, minter_);
    }

    // ============ External Functions ============

    /// @inheritdoc IConditionalToken
    function mint(
        address to,
        uint256 amount
    ) external override onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc IConditionalToken
    function burn(
        address from,
        uint256 amount
    ) external override onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }

    // ============ View Functions ============

    /// @notice Returns the number of decimals
    function decimals()
        public
        view
        override(ERC20, IConditionalToken)
        returns (uint8)
    {
        return _decimals;
    }

    /// @notice ERC165 interface support
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
