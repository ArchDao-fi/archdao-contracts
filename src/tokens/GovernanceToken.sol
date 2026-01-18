// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OpenZeppelin
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

// Local interfaces
import {IGovernanceToken} from "../interfaces/IGovernanceToken.sol";

// ============================================================================
// GovernanceToken
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.8
// Ticket: T-015
//
// Standard ERC-20 with RBAC-controlled minting for ICO organizations.
// Uses OpenZeppelin AccessControl for role management.
// Token Supply: 1B tokens max (per Q3 answer)
// ============================================================================

contract GovernanceToken is ERC20, AccessControl, IGovernanceToken {
    // ============ Constants ============

    /// @notice Role that can mint tokens
    bytes32 public constant override MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Maximum token supply (1 billion tokens with 18 decimals)
    uint256 public constant override MAX_SUPPLY = 1_000_000_000e18;

    // ============ Constructor ============

    /// @notice Deploy a new governance token
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param minter_ Address that receives MINTER_ROLE (immutable)
    constructor(
        string memory name_,
        string memory symbol_,
        address minter_
    ) ERC20(name_, symbol_) {
        _grantRole(MINTER_ROLE, minter_);
    }

    // ============ External Functions ============

    /// @inheritdoc IGovernanceToken
    function mint(
        address to,
        uint256 amount
    ) external override onlyRole(MINTER_ROLE) {
        if (totalSupply() + amount > MAX_SUPPLY) {
            revert ExceedsMaxSupply(totalSupply() + amount, MAX_SUPPLY);
        }
        _mint(to, amount);
    }

    /// @inheritdoc IGovernanceToken
    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }

    // ============ View Functions ============

    /// @notice ERC165 interface support
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
