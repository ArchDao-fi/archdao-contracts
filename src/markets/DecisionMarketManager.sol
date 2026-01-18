// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Permit2
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// Uniswap V4 Core
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// Uniswap V4 Periphery
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

// Uniswap V4 Core Test Utils (for liquidity calculations)
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

// Local interfaces
import {IDecisionMarketManager} from "../interfaces/IDecisionMarketManager.sol";
import {ILaggingTWAPHook} from "../interfaces/ILaggingTWAPHook.sol";

// Local types
import {ConditionalTokenSet} from "../types/ProposalTypes.sol";

// ============================================================================
// DecisionMarketManager
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.6
// Ticket: T-023
//
// Singleton manager for Uniswap V4 decision market pools.
// Creates and manages full-range liquidity positions for proposal markets.
//
// Each proposal has TWO pools:
// - Pass pool: pToken/pQuote (conditional tokens for pass outcome)
// - Fail pool: fToken/fQuote (conditional tokens for fail outcome)
//
// Key features:
// - Full-range liquidity for all positions
// - Integration with LaggingTWAPHook for rate-limited TWAP
// - LP position management via PositionManager
// ============================================================================

contract DecisionMarketManager is IDecisionMarketManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Default pool fee (0.3% = 3000)
    uint24 public constant DEFAULT_POOL_FEE = 3000;

    /// @notice Default tick spacing for 0.3% fee tier
    int24 public constant DEFAULT_TICK_SPACING = 60;

    // ============ Immutables ============

    /// @notice Permit2 for token approvals
    IAllowanceTransfer public immutable permit2;

    /// @notice Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice Uniswap V4 PositionManager
    IPositionManager public immutable positionManager;

    /// @notice LaggingTWAPHook for rate-limited observations
    ILaggingTWAPHook public immutable twapHook;

    // ============ State Variables ============

    /// @notice ProposalManager address (only caller for market ops)
    address public proposalManager;

    /// @notice Pass pool key for each proposal
    mapping(uint256 proposalId => PoolKey) internal _passPoolKeys;

    /// @notice Fail pool key for each proposal
    mapping(uint256 proposalId => PoolKey) internal _failPoolKeys;

    /// @notice Pass position token ID for each proposal
    mapping(uint256 proposalId => uint256) internal _passPositionIds;

    /// @notice Fail position token ID for each proposal
    mapping(uint256 proposalId => uint256) internal _failPositionIds;

    /// @notice Track if markets have been initialized for a proposal
    mapping(uint256 proposalId => bool) public marketsInitialized;

    // ============ Modifiers ============

    modifier onlyProposalManager() {
        if (msg.sender != proposalManager) revert NotProposalManager();
        _;
    }

    // ============ Constructor ============

    /// @notice Deploy the DecisionMarketManager
    /// @param _permit2 Permit2 contract for token approvals
    /// @param _poolManager Uniswap V4 PoolManager
    /// @param _positionManager Uniswap V4 PositionManager
    /// @param _twapHook LaggingTWAPHook address
    constructor(
        IAllowanceTransfer _permit2,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        ILaggingTWAPHook _twapHook
    ) {
        if (address(_permit2) == address(0)) revert ZeroAddress();
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        if (address(_positionManager) == address(0)) revert ZeroAddress();
        if (address(_twapHook) == address(0)) revert ZeroAddress();

        permit2 = _permit2;
        poolManager = _poolManager;
        positionManager = _positionManager;
        twapHook = _twapHook;
    }

    // ============ Configuration ============

    /// @notice Set the ProposalManager address (one-time setup)
    /// @param _proposalManager ProposalManager contract address
    function setProposalManager(address _proposalManager) external {
        if (_proposalManager == address(0)) revert ZeroAddress();
        if (proposalManager != address(0)) revert MarketsAlreadyInitialized(0);
        proposalManager = _proposalManager;
    }

    // ============ Market Initialization ============

    /// @inheritdoc IDecisionMarketManager
    function initializeMarkets(
        uint256 proposalId,
        ConditionalTokenSet calldata tokens,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint160 sqrtPriceX96,
        uint256 observationMaxRateBpsPerSecond,
        uint256 twapRecordingStartTime
    )
        external
        override
        onlyProposalManager
        returns (PoolKey[2] memory poolKeys)
    {
        if (marketsInitialized[proposalId])
            revert MarketsAlreadyInitialized(proposalId);

        // Initialize pass pool (pToken/pQuote)
        poolKeys[0] = _initializePool(
            tokens.pToken,
            tokens.pQuote,
            sqrtPriceX96
        );

        // Initialize fail pool (fToken/fQuote)
        poolKeys[1] = _initializePool(
            tokens.fToken,
            tokens.fQuote,
            sqrtPriceX96
        );

        // Store pool keys separately (avoid array copy issue)
        _passPoolKeys[proposalId] = poolKeys[0];
        _failPoolKeys[proposalId] = poolKeys[1];

        // Add full-range liquidity to both pools
        _passPositionIds[proposalId] = _addFullRangeLiquidity(
            poolKeys[0],
            tokens.pToken,
            tokens.pQuote,
            baseAmount,
            quoteAmount
        );

        _failPositionIds[proposalId] = _addFullRangeLiquidity(
            poolKeys[1],
            tokens.fToken,
            tokens.fQuote,
            baseAmount,
            quoteAmount
        );

        // Configure TWAP recording for both pools
        PoolId passPoolId = poolKeys[0].toId();
        PoolId failPoolId = poolKeys[1].toId();

        twapHook.startRecording(
            passPoolId,
            twapRecordingStartTime,
            observationMaxRateBpsPerSecond
        );
        twapHook.startRecording(
            failPoolId,
            twapRecordingStartTime,
            observationMaxRateBpsPerSecond
        );

        marketsInitialized[proposalId] = true;

        emit MarketsInitialized(proposalId, poolKeys[0], poolKeys[1]);

        return poolKeys;
    }

    // ============ Liquidity Management ============

    /// @inheritdoc IDecisionMarketManager
    function removeLiquidity(
        uint256 proposalId
    )
        external
        override
        onlyProposalManager
        returns (
            uint256 pTokenAmount,
            uint256 pQuoteAmount,
            uint256 fTokenAmount,
            uint256 fQuoteAmount
        )
    {
        if (!marketsInitialized[proposalId])
            revert MarketsNotInitialized(proposalId);

        // Remove liquidity from pass pool
        (pTokenAmount, pQuoteAmount) = _removeLiquidityFromPosition(
            _passPositionIds[proposalId],
            _passPoolKeys[proposalId]
        );

        // Remove liquidity from fail pool
        (fTokenAmount, fQuoteAmount) = _removeLiquidityFromPosition(
            _failPositionIds[proposalId],
            _failPoolKeys[proposalId]
        );

        // Stop TWAP recording
        twapHook.stopRecording(_passPoolKeys[proposalId].toId());
        twapHook.stopRecording(_failPoolKeys[proposalId].toId());

        emit LiquidityRemoved(
            proposalId,
            pTokenAmount,
            pQuoteAmount,
            fTokenAmount,
            fQuoteAmount
        );
    }

    // ============ Fee Collection ============

    /// @inheritdoc IDecisionMarketManager
    function collectFees(
        uint256 proposalId
    )
        external
        override
        onlyProposalManager
        returns (
            uint256 pTokenFees,
            uint256 pQuoteFees,
            uint256 fTokenFees,
            uint256 fQuoteFees
        )
    {
        if (!marketsInitialized[proposalId])
            revert MarketsNotInitialized(proposalId);

        // Collect fees from pass pool
        (pTokenFees, pQuoteFees) = _collectFeesFromPosition(
            _passPositionIds[proposalId],
            _passPoolKeys[proposalId]
        );

        // Collect fees from fail pool
        (fTokenFees, fQuoteFees) = _collectFeesFromPosition(
            _failPositionIds[proposalId],
            _failPoolKeys[proposalId]
        );

        uint256 totalFees = pTokenFees + pQuoteFees + fTokenFees + fQuoteFees;
        emit FeesCollected(proposalId, totalFees);
    }

    // ============ View Functions ============

    /// @inheritdoc IDecisionMarketManager
    function getPoolKeys(
        uint256 proposalId
    ) external view override returns (PoolKey[2] memory poolKeys) {
        poolKeys[0] = _passPoolKeys[proposalId];
        poolKeys[1] = _failPoolKeys[proposalId];
        return poolKeys;
    }

    /// @inheritdoc IDecisionMarketManager
    function getSpotPrices(
        uint256 proposalId
    ) external view override returns (uint256 passPrice, uint256 failPrice) {
        if (!marketsInitialized[proposalId])
            revert MarketsNotInitialized(proposalId);

        passPrice = _getSpotPrice(_passPoolKeys[proposalId]);
        failPrice = _getSpotPrice(_failPoolKeys[proposalId]);
    }

    /// @inheritdoc IDecisionMarketManager
    function getTWAPs(
        uint256 proposalId
    ) external view override returns (uint256 passTwap, uint256 failTwap) {
        if (!marketsInitialized[proposalId])
            revert MarketsNotInitialized(proposalId);

        passTwap = twapHook.getTWAP(_passPoolKeys[proposalId].toId());
        failTwap = twapHook.getTWAP(_failPoolKeys[proposalId].toId());
    }

    /// @inheritdoc IDecisionMarketManager
    function getPositionIds(
        uint256 proposalId
    ) external view override returns (uint256[2] memory positionIds) {
        positionIds[0] = _passPositionIds[proposalId];
        positionIds[1] = _failPositionIds[proposalId];
        return positionIds;
    }

    // ============ Internal Functions ============

    /// @notice Initialize a single pool
    /// @param token0Addr Address of token0
    /// @param token1Addr Address of token1
    /// @param sqrtPriceX96 Initial sqrt price
    /// @return key The created PoolKey
    function _initializePool(
        address token0Addr,
        address token1Addr,
        uint160 sqrtPriceX96
    ) internal returns (PoolKey memory key) {
        // Sort tokens to get correct currency order
        (Currency currency0, Currency currency1) = _sortCurrencies(
            token0Addr,
            token1Addr
        );

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DEFAULT_POOL_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(twapHook))
        });

        // Initialize the pool
        poolManager.initialize(key, sqrtPriceX96);
    }

    /// @notice Add full-range liquidity to a pool
    /// @param key Pool key
    /// @param token0Addr Token0 address
    /// @param token1Addr Token1 address
    /// @param amount0 Amount of token0
    /// @param amount1 Amount of token1
    /// @return tokenId Position NFT token ID
    function _addFullRangeLiquidity(
        PoolKey memory key,
        address token0Addr,
        address token1Addr,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 tokenId) {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        // Calculate liquidity in scoped block to reduce stack depth
        uint128 liquidity;
        {
            (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                amount0,
                amount1
            );
        }

        // Determine sorted order and transfer/approve tokens
        (address sorted0, address sorted1) = _sortAddresses(
            token0Addr,
            token1Addr
        );
        uint256 sortedAmount0;
        uint256 sortedAmount1;
        {
            (sortedAmount0, sortedAmount1) = token0Addr == sorted0
                ? (amount0, amount1)
                : (amount1, amount0);

            // Transfer tokens from caller to this contract
            IERC20(sorted0).safeTransferFrom(
                msg.sender,
                address(this),
                sortedAmount0
            );
            IERC20(sorted1).safeTransferFrom(
                msg.sender,
                address(this),
                sortedAmount1
            );

            // Approve Permit2 to pull tokens from this contract
            IERC20(sorted0).forceApprove(address(permit2), sortedAmount0);
            IERC20(sorted1).forceApprove(address(permit2), sortedAmount1);

            // Set Permit2 allowance for PositionManager
            permit2.approve(
                sorted0,
                address(positionManager),
                uint160(sortedAmount0),
                type(uint48).max
            );
            permit2.approve(
                sorted1,
                address(positionManager),
                uint160(sortedAmount1),
                type(uint48).max
            );
        }

        // Execute mint position
        tokenId = positionManager.nextTokenId();
        _executeMintPosition(
            key,
            tickLower,
            tickUpper,
            liquidity,
            sortedAmount0,
            sortedAmount1
        );
    }

    /// @notice Execute mint position via PositionManager
    function _executeMintPosition(
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

    /// @notice Remove all liquidity from a position
    /// @param tokenId Position token ID
    /// @param key Pool key
    /// @return amount0 Amount of token0 recovered
    /// @return amount1 Amount of token1 recovered
    function _removeLiquidityFromPosition(
        uint256 tokenId,
        PoolKey memory key
    ) internal returns (uint256 amount0, uint256 amount1) {
        // Get position liquidity
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        if (liquidity == 0) {
            return (0, 0);
        }

        // Get pool key for the position
        (PoolKey memory posKey, ) = positionManager.getPoolAndPositionInfo(
            tokenId
        );

        // Track balances before
        uint256 balance0Before = IERC20(Currency.unwrap(posKey.currency0))
            .balanceOf(address(this));
        uint256 balance1Before = IERC20(Currency.unwrap(posKey.currency1))
            .balanceOf(address(this));

        // Encode decrease liquidity + take pair
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, 0, 0, bytes(""));
        params[1] = abi.encode(
            posKey.currency0,
            posKey.currency1,
            address(this)
        );

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp
        );

        // Calculate amounts recovered
        amount0 =
            IERC20(Currency.unwrap(posKey.currency0)).balanceOf(address(this)) -
            balance0Before;
        amount1 =
            IERC20(Currency.unwrap(posKey.currency1)).balanceOf(address(this)) -
            balance1Before;

        // Transfer tokens to caller (ProposalManager)
        if (amount0 > 0) {
            IERC20(Currency.unwrap(posKey.currency0)).safeTransfer(
                msg.sender,
                amount0
            );
        }
        if (amount1 > 0) {
            IERC20(Currency.unwrap(posKey.currency1)).safeTransfer(
                msg.sender,
                amount1
            );
        }
    }

    /// @notice Collect fees from a position
    /// @param tokenId Position token ID
    /// @param key Pool key
    /// @return fees0 Fees in token0
    /// @return fees1 Fees in token1
    function _collectFeesFromPosition(
        uint256 tokenId,
        PoolKey memory key
    ) internal returns (uint256 fees0, uint256 fees1) {
        (PoolKey memory posKey, ) = positionManager.getPoolAndPositionInfo(
            tokenId
        );

        // Track balances before
        uint256 balance0Before = IERC20(Currency.unwrap(posKey.currency0))
            .balanceOf(address(this));
        uint256 balance1Before = IERC20(Currency.unwrap(posKey.currency1))
            .balanceOf(address(this));

        // Collect fees by decreasing 0 liquidity
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, bytes(""));
        params[1] = abi.encode(
            posKey.currency0,
            posKey.currency1,
            address(this)
        );

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp
        );

        // Calculate fees collected
        fees0 =
            IERC20(Currency.unwrap(posKey.currency0)).balanceOf(address(this)) -
            balance0Before;
        fees1 =
            IERC20(Currency.unwrap(posKey.currency1)).balanceOf(address(this)) -
            balance1Before;

        // Transfer fees to caller
        if (fees0 > 0) {
            IERC20(Currency.unwrap(posKey.currency0)).safeTransfer(
                msg.sender,
                fees0
            );
        }
        if (fees1 > 0) {
            IERC20(Currency.unwrap(posKey.currency1)).safeTransfer(
                msg.sender,
                fees1
            );
        }
    }

    /// @notice Get spot price from a pool
    /// @param key Pool key
    /// @return price Price as token1/token0 ratio with 1e18 precision
    function _getSpotPrice(
        PoolKey memory key
    ) internal view returns (uint256 price) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());

        // Convert sqrtPriceX96 to price with 1e18 precision
        // price = (sqrtPriceX96 / 2^96)^2 * 1e18
        // = sqrtPriceX96^2 * 1e18 / 2^192
        uint256 sqrtPriceSquared = uint256(sqrtPriceX96) *
            uint256(sqrtPriceX96);
        price = (sqrtPriceSquared * 1e18) >> 192;
    }

    /// @notice Sort two token addresses into currency order
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @return currency0 Lower address as Currency
    /// @return currency1 Higher address as Currency
    function _sortCurrencies(
        address tokenA,
        address tokenB
    ) internal pure returns (Currency currency0, Currency currency1) {
        if (tokenA < tokenB) {
            currency0 = Currency.wrap(tokenA);
            currency1 = Currency.wrap(tokenB);
        } else {
            currency0 = Currency.wrap(tokenB);
            currency1 = Currency.wrap(tokenA);
        }
    }

    /// @notice Sort two addresses
    /// @param a First address
    /// @param b Second address
    /// @return lower Lower address
    /// @return higher Higher address
    function _sortAddresses(
        address a,
        address b
    ) internal pure returns (address lower, address higher) {
        return a < b ? (a, b) : (b, a);
    }
}
