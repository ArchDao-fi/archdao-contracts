// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// ============================================================================
// ITreasury
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.2
// Manages organization assets and LP positions
// ============================================================================

interface ITreasury {
    // ============ Errors ============

    /// @notice Address is zero when it shouldn't be
    error ZeroAddress();

    /// @notice Treasury already initialized
    error AlreadyInitialized();

    /// @notice Treasury not initialized
    error NotInitialized();

    /// @notice Caller is not the OrganizationManager
    error NotOrganizationManager();

    /// @notice Caller is not the ProposalManager
    error NotProposalManager();

    /// @notice Spot position already exists
    error SpotPositionExists();

    /// @notice Spot position does not exist
    error NoSpotPosition();

    /// @notice Insufficient balance for operation
    error InsufficientBalance(
        address token,
        uint256 required,
        uint256 available
    );

    /// @notice Execution failed
    error ExecutionFailed(bytes reason);

    /// @notice Invalid token
    error InvalidToken();

    // ============ Events ============

    event Deposited(
        address indexed token,
        address indexed from,
        uint256 amount
    );
    event SpotPositionCreated(
        uint256 indexed tokenId,
        uint256 baseAmount,
        uint256 quoteAmount
    );
    event LiquidityWithdrawn(uint256 baseAmount, uint256 quoteAmount);
    event LiquidityAdded(uint256 baseAmount, uint256 quoteAmount);
    event ProposalExecuted(
        address indexed target,
        bytes data,
        uint256 value,
        bytes result
    );
    event FeesCollected(
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 protocolShare,
        uint256 treasuryShare
    );

    // ============ Initialization ============

    /// @notice Initialize the treasury
    /// @param orgId Organization ID this treasury belongs to
    /// @param manager OrganizationManager contract address
    /// @param baseToken Base token address
    /// @param quoteToken Quote token address
    /// @param positionManager V4 PositionManager address
    function initialize(
        uint256 orgId,
        address manager,
        address baseToken,
        address quoteToken,
        address positionManager
    ) external;

    // ============ Deposits ============

    /// @notice Deposit tokens into the treasury
    /// @param token Token address to deposit
    /// @param amount Amount to deposit
    function deposit(address token, uint256 amount) external;

    // ============ LP Management ============

    /// @notice Create the initial spot LP position
    /// @param baseAmount Amount of base token for LP
    /// @param quoteAmount Amount of quote token for LP
    /// @param poolKey V4 pool key
    function createSpotPosition(
        uint256 baseAmount,
        uint256 quoteAmount,
        PoolKey calldata poolKey
    ) external;

    /// @notice Withdraw liquidity for a proposal
    /// @param allocationBps Percentage of LP to withdraw in basis points
    /// @return baseAmount Amount of base token withdrawn
    /// @return quoteAmount Amount of quote token withdrawn
    function withdrawLiquidityForProposal(
        uint256 allocationBps
    ) external returns (uint256 baseAmount, uint256 quoteAmount);

    /// @notice Add liquidity back after proposal resolution
    /// @param baseAmount Amount of base token to add
    /// @param quoteAmount Amount of quote token to add
    function addLiquidityAfterResolution(
        uint256 baseAmount,
        uint256 quoteAmount
    ) external;

    // ============ Proposal Execution ============

    /// @notice Execute an arbitrary call (for passed proposals)
    /// @param target Target contract address
    /// @param data Call data
    /// @param value ETH value to send
    /// @return result Return data from the call
    function execute(
        address target,
        bytes calldata data,
        uint256 value
    ) external returns (bytes memory result);

    // ============ Fee Collection ============

    /// @notice Collect fees from the spot pool
    /// @return baseAmount Base token fees collected
    /// @return quoteAmount Quote token fees collected
    function collectFeesFromSpotPool()
        external
        returns (uint256 baseAmount, uint256 quoteAmount);

    // ============ View Functions ============

    /// @notice Get the spot position's liquidity
    /// @return liquidity Current liquidity amount
    function getSpotPositionLiquidity()
        external
        view
        returns (uint128 liquidity);

    /// @notice Get the spot position's token amounts
    /// @return baseAmount Amount of base token in position
    /// @return quoteAmount Amount of quote token in position
    function getSpotPositionAmounts()
        external
        view
        returns (uint256 baseAmount, uint256 quoteAmount);

    /// @notice Get balance of a token held by treasury
    /// @param token Token address
    /// @return balance Token balance
    function getBalance(address token) external view returns (uint256 balance);

    /// @notice Get the organization ID
    /// @return id Organization ID
    function orgId() external view returns (uint256 id);

    /// @notice Get base token address
    /// @return token Base token address
    function baseToken() external view returns (address token);

    /// @notice Get quote token address
    /// @return token Quote token address
    function quoteToken() external view returns (address token);

    /// @notice Get spot position token ID
    /// @return tokenId V4 position NFT token ID
    function spotPositionTokenId() external view returns (uint256 tokenId);

    /// @notice Check if treasury is initialized
    /// @return isInit True if initialized
    function initialized() external view returns (bool isInit);
}
