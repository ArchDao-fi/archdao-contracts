// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Permit2
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// Uniswap V4 Core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// Uniswap V4 Periphery
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

// Uniswap V4 Core Test Utils (for liquidity calculations)
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

// Local interfaces
import {ITreasury} from "../interfaces/ITreasury.sol";

// ============================================================================
// Treasury
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.2
// Ticket: T-026
//
// Per-organization treasury that:
// - Holds assets (base token + quote token)
// - Manages spot LP position in V4
// - Withdraws/adds liquidity for proposals
// - Executes passed proposal actions
// - Collects and distributes fees
// ============================================================================

contract Treasury is ITreasury {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ============ Immutables ============

    /// @notice Permit2 for token approvals
    IAllowanceTransfer public immutable permit2;

    /// @notice Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice Uniswap V4 PositionManager
    IPositionManager public immutable positionManager;

    // ============ State Variables ============

    /// @notice Organization ID
    uint256 public orgId;

    /// @notice OrganizationManager address
    address public manager;

    /// @notice ProposalManager address
    address public proposalManager;

    /// @notice Base token (governance token)
    address public baseToken;

    /// @notice Quote token (e.g., USDC)
    address public quoteToken;

    /// @notice Spot LP position token ID
    uint256 public spotPositionTokenId;

    /// @notice Pool key for spot position
    PoolKey public spotPoolKey;

    /// @notice Whether treasury is initialized
    bool public initialized;

    // ============ Modifiers ============

    modifier onlyManager() {
        if (msg.sender != manager) revert NotOrganizationManager();
        _;
    }

    modifier onlyProposalManager() {
        if (msg.sender != proposalManager) revert NotProposalManager();
        _;
    }

    modifier whenInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    // ============ Constructor ============

    /// @notice Deploy the Treasury
    /// @param _permit2 Permit2 contract
    /// @param _poolManager V4 PoolManager
    /// @param _positionManager V4 PositionManager
    constructor(
        IAllowanceTransfer _permit2,
        IPoolManager _poolManager,
        IPositionManager _positionManager
    ) {
        if (address(_permit2) == address(0)) revert ZeroAddress();
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        if (address(_positionManager) == address(0)) revert ZeroAddress();

        permit2 = _permit2;
        poolManager = _poolManager;
        positionManager = _positionManager;
    }

    // ============ Initialization ============

    /// @inheritdoc ITreasury
    function initialize(
        uint256 _orgId,
        address _manager,
        address _baseToken,
        address _quoteToken,
        address /* _positionManager */ // Ignored - using immutable from constructor
    ) external override {
        if (initialized) revert AlreadyInitialized();
        if (_manager == address(0)) revert ZeroAddress();
        if (_baseToken == address(0)) revert ZeroAddress();
        if (_quoteToken == address(0)) revert ZeroAddress();

        orgId = _orgId;
        manager = _manager;
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        initialized = true;
    }

    /// @notice Set the ProposalManager address (called by OrganizationManager)
    /// @param _proposalManager ProposalManager contract address
    function setProposalManager(address _proposalManager) external onlyManager {
        if (_proposalManager == address(0)) revert ZeroAddress();
        proposalManager = _proposalManager;
    }

    // ============ Deposits ============

    /// @inheritdoc ITreasury
    function deposit(
        address token,
        uint256 amount
    ) external override whenInitialized {
        if (token != baseToken && token != quoteToken) revert InvalidToken();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(token, msg.sender, amount);
    }

    // ============ LP Management ============

    /// @inheritdoc ITreasury
    function createSpotPosition(
        uint256 baseAmount,
        uint256 quoteAmount,
        PoolKey calldata poolKey
    ) external override onlyManager whenInitialized {
        if (spotPositionTokenId != 0) revert SpotPositionExists();

        // Store pool key
        spotPoolKey = poolKey;

        // Calculate full-range ticks
        int24 tickSpacing = poolKey.tickSpacing;
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);

        // Determine token order and amounts
        (address sorted0, address sorted1) = _sortAddresses(
            baseToken,
            quoteToken
        );
        (uint256 amount0, uint256 amount1) = baseToken == sorted0
            ? (baseAmount, quoteAmount)
            : (quoteAmount, baseAmount);

        // Calculate liquidity
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        // Approve tokens through Permit2
        IERC20(sorted0).forceApprove(address(permit2), amount0);
        IERC20(sorted1).forceApprove(address(permit2), amount1);
        permit2.approve(
            sorted0,
            address(positionManager),
            uint160(amount0),
            type(uint48).max
        );
        permit2.approve(
            sorted1,
            address(positionManager),
            uint160(amount1),
            type(uint48).max
        );

        // Mint position
        spotPositionTokenId = positionManager.nextTokenId();
        _mintPosition(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0,
            amount1
        );

        emit SpotPositionCreated(spotPositionTokenId, baseAmount, quoteAmount);
    }

    /// @inheritdoc ITreasury
    function withdrawLiquidityForProposal(
        uint256 allocationBps
    )
        external
        override
        onlyProposalManager
        whenInitialized
        returns (uint256 baseAmount, uint256 quoteAmount)
    {
        if (spotPositionTokenId == 0) revert NoSpotPosition();

        // Get current liquidity
        uint128 totalLiquidity = positionManager.getPositionLiquidity(
            spotPositionTokenId
        );
        uint128 withdrawLiquidity = uint128(
            (uint256(totalLiquidity) * allocationBps) / BPS_DENOMINATOR
        );

        if (withdrawLiquidity == 0) {
            return (0, 0);
        }

        // Track balances before
        uint256 balance0Before = IERC20(Currency.unwrap(spotPoolKey.currency0))
            .balanceOf(address(this));
        uint256 balance1Before = IERC20(Currency.unwrap(spotPoolKey.currency1))
            .balanceOf(address(this));

        // Decrease liquidity
        _decreaseLiquidity(spotPositionTokenId, withdrawLiquidity);

        // Calculate amounts received
        uint256 amount0 = IERC20(Currency.unwrap(spotPoolKey.currency0))
            .balanceOf(address(this)) - balance0Before;
        uint256 amount1 = IERC20(Currency.unwrap(spotPoolKey.currency1))
            .balanceOf(address(this)) - balance1Before;

        // Map back to base/quote
        address sorted0 = Currency.unwrap(spotPoolKey.currency0);
        if (sorted0 == baseToken) {
            baseAmount = amount0;
            quoteAmount = amount1;
        } else {
            baseAmount = amount1;
            quoteAmount = amount0;
        }

        emit LiquidityWithdrawn(baseAmount, quoteAmount);
    }

    /// @inheritdoc ITreasury
    function addLiquidityAfterResolution(
        uint256 baseAmount,
        uint256 quoteAmount
    ) external override onlyProposalManager whenInitialized {
        if (spotPositionTokenId == 0) revert NoSpotPosition();

        // Determine sorted amounts
        (address sorted0, ) = _sortAddresses(baseToken, quoteToken);
        (uint256 amount0, uint256 amount1) = baseToken == sorted0
            ? (baseAmount, quoteAmount)
            : (quoteAmount, baseAmount);

        // Approve tokens through Permit2
        IERC20(Currency.unwrap(spotPoolKey.currency0)).forceApprove(
            address(permit2),
            amount0
        );
        IERC20(Currency.unwrap(spotPoolKey.currency1)).forceApprove(
            address(permit2),
            amount1
        );
        permit2.approve(
            Currency.unwrap(spotPoolKey.currency0),
            address(positionManager),
            uint160(amount0),
            type(uint48).max
        );
        permit2.approve(
            Currency.unwrap(spotPoolKey.currency1),
            address(positionManager),
            uint160(amount1),
            type(uint48).max
        );

        // Increase liquidity
        _increaseLiquidity(spotPositionTokenId, amount0, amount1);

        emit LiquidityAdded(baseAmount, quoteAmount);
    }

    // ============ Proposal Execution ============

    /// @inheritdoc ITreasury
    function execute(
        address target,
        bytes calldata data,
        uint256 value
    )
        external
        override
        onlyProposalManager
        whenInitialized
        returns (bytes memory result)
    {
        (bool success, bytes memory returnData) = target.call{value: value}(
            data
        );
        if (!success) revert ExecutionFailed(returnData);

        emit ProposalExecuted(target, data, value, returnData);
        return returnData;
    }

    // ============ Fee Collection ============

    /// @inheritdoc ITreasury
    function collectFeesFromSpotPool()
        external
        override
        whenInitialized
        returns (uint256 baseAmount, uint256 quoteAmount)
    {
        if (spotPositionTokenId == 0) revert NoSpotPosition();

        // Track balances before
        uint256 balance0Before = IERC20(Currency.unwrap(spotPoolKey.currency0))
            .balanceOf(address(this));
        uint256 balance1Before = IERC20(Currency.unwrap(spotPoolKey.currency1))
            .balanceOf(address(this));

        // Collect fees (decrease by 0 liquidity)
        _collectFees(spotPositionTokenId);

        // Calculate fees collected
        uint256 amount0 = IERC20(Currency.unwrap(spotPoolKey.currency0))
            .balanceOf(address(this)) - balance0Before;
        uint256 amount1 = IERC20(Currency.unwrap(spotPoolKey.currency1))
            .balanceOf(address(this)) - balance1Before;

        // Map back to base/quote
        address sorted0 = Currency.unwrap(spotPoolKey.currency0);
        if (sorted0 == baseToken) {
            baseAmount = amount0;
            quoteAmount = amount1;
        } else {
            baseAmount = amount1;
            quoteAmount = amount0;
        }

        // TODO: Distribute fees according to treasuryFeeShareBps from OrganizationManager
        // For now, all fees stay in treasury

        emit FeesCollected(
            baseAmount,
            quoteAmount,
            0,
            baseAmount + quoteAmount
        );
    }

    // ============ View Functions ============

    /// @inheritdoc ITreasury
    function getSpotPositionLiquidity()
        external
        view
        override
        returns (uint128 liquidity)
    {
        if (spotPositionTokenId == 0) return 0;
        return positionManager.getPositionLiquidity(spotPositionTokenId);
    }

    /// @inheritdoc ITreasury
    function getSpotPositionAmounts()
        external
        view
        override
        returns (uint256 baseAmount, uint256 quoteAmount)
    {
        if (spotPositionTokenId == 0) return (0, 0);

        uint128 liquidity = positionManager.getPositionLiquidity(
            spotPositionTokenId
        );
        if (liquidity == 0) return (0, 0);

        int24 tickSpacing = spotPoolKey.tickSpacing;
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(spotPoolKey.toId());

        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidity
            );

        // Map back to base/quote
        address sorted0 = Currency.unwrap(spotPoolKey.currency0);
        if (sorted0 == baseToken) {
            baseAmount = amount0;
            quoteAmount = amount1;
        } else {
            baseAmount = amount1;
            quoteAmount = amount0;
        }
    }

    /// @inheritdoc ITreasury
    function getBalance(
        address token
    ) external view override returns (uint256 balance) {
        return IERC20(token).balanceOf(address(this));
    }

    // ============ Internal Functions ============

    /// @notice Sort addresses for token ordering
    function _sortAddresses(
        address a,
        address b
    ) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    /// @notice Mint a new LP position
    function _mintPosition(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            address(this),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp
        );
    }

    /// @notice Decrease liquidity from position
    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            tokenId,
            liquidity,
            0, // min amount0
            0, // min amount1
            bytes("")
        );
        params[1] = abi.encode(
            spotPoolKey.currency0,
            spotPoolKey.currency1,
            address(this)
        );

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp
        );
    }

    /// @notice Increase liquidity in position
    function _increaseLiquidity(
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    ) internal {
        // Calculate liquidity to add
        int24 tickSpacing = spotPoolKey.tickSpacing;
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(spotPoolKey.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, amount0, amount1, bytes(""));
        params[1] = abi.encode(spotPoolKey.currency0, spotPoolKey.currency1);

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp
        );
    }

    /// @notice Collect fees from position
    function _collectFees(uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            tokenId,
            0, // zero liquidity = collect fees only
            0, // min amount0
            0, // min amount1
            bytes("")
        );
        params[1] = abi.encode(
            spotPoolKey.currency0,
            spotPoolKey.currency1,
            address(this)
        );

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp
        );
    }

    /// @notice Allow receiving ETH for proposal executions
    receive() external payable {}
}
