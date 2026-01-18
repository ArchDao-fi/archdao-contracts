// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V4 Core
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// Local interfaces
import {IProposalManager} from "../interfaces/IProposalManager.sol";
import {IOrganizationManager} from "../interfaces/IOrganizationManager.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {IConditionalTokenFactory} from "../interfaces/IConditionalTokenFactory.sol";
import {IConditionalToken} from "../interfaces/IConditionalToken.sol";
import {IDecisionMarketManager} from "../interfaces/IDecisionMarketManager.sol";

// Local types
import {Proposal, ProposalAction, ConditionalTokenSet, ProposalStatus, ProposalOutcome, ActionType, ExecutionCondition} from "../types/ProposalTypes.sol";
import {OrganizationConfig, OrgRole} from "../types/OrganizationTypes.sol";

// ============================================================================
// ProposalManager
// ============================================================================
// Source of Truth: SPECIFICATION.md §4.3
// Ticket: T-029
//
// Per-organization manager handling complete proposal lifecycle:
// - Creation and staking
// - Activation (deploy conditional tokens, initialize markets)
// - Resolution (TWAP comparison, outcome determination)
// - Execution (execute passed proposal actions)
// - Split/merge/redeem conditional token operations
//
// Key invariants:
// - Only ONE non-terminal proposal at a time (serial execution)
// - Stakes are refunded upon activation (pure signaling)
// - Pass threshold can be negative for team proposals
// ============================================================================

contract ProposalManager is IProposalManager {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Price precision for TWAP calculations
    uint256 public constant PRICE_PRECISION = 1e18;

    // ============ State Variables ============

    /// @notice Organization ID
    uint256 public orgId;

    /// @notice OrganizationManager contract
    IOrganizationManager public manager;

    /// @notice Treasury contract
    ITreasury public treasury;

    /// @notice ConditionalTokenFactory contract
    IConditionalTokenFactory public tokenFactory;

    /// @notice DecisionMarketManager contract
    IDecisionMarketManager public marketManager;

    /// @notice Total proposals created
    uint256 public proposalCount;

    /// @notice Current active proposal (0 if none)
    uint256 public activeProposalId;

    /// @notice Proposal storage
    mapping(uint256 proposalId => Proposal) internal _proposals;

    /// @notice Staker balances per proposal
    mapping(uint256 proposalId => mapping(address staker => uint256 amount))
        public stakes;

    /// @notice List of stakers per proposal (for refunds)
    mapping(uint256 proposalId => address[]) internal _stakers;

    /// @notice Whether treasury is initialized
    bool public initialized;

    // ============ Modifiers ============

    modifier whenInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    modifier proposalExists(uint256 proposalId) {
        if (proposalId == 0 || proposalId > proposalCount) {
            revert ProposalNotFound(proposalId);
        }
        _;
    }

    modifier inStatus(uint256 proposalId, ProposalStatus required) {
        if (_proposals[proposalId].status != required) {
            revert InvalidProposalStatus(
                _proposals[proposalId].status,
                required
            );
        }
        _;
    }

    // ============ Constructor ============

    constructor() {}

    // ============ Initialization ============

    /// @inheritdoc IProposalManager
    function initialize(
        uint256 _orgId,
        address _manager,
        address _treasury,
        address _tokenFactory,
        address _marketManager
    ) external override {
        if (initialized) revert AlreadyInitialized();
        if (_manager == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_tokenFactory == address(0)) revert ZeroAddress();
        if (_marketManager == address(0)) revert ZeroAddress();

        orgId = _orgId;
        manager = IOrganizationManager(_manager);
        treasury = ITreasury(_treasury);
        tokenFactory = IConditionalTokenFactory(_tokenFactory);
        marketManager = IDecisionMarketManager(_marketManager);
        initialized = true;
    }

    // ============ Proposal Lifecycle ============

    /// @inheritdoc IProposalManager
    function createProposal(
        ProposalAction[] calldata actions
    ) external override whenInitialized returns (uint256 proposalId) {
        // Check no active proposal
        if (activeProposalId != 0) {
            ProposalStatus currentStatus = _proposals[activeProposalId].status;
            if (
                currentStatus != ProposalStatus.Executed &&
                currentStatus != ProposalStatus.Cancelled &&
                currentStatus != ProposalStatus.Failed
            ) {
                revert ProposalExists();
            }
        }

        // Check caller authorization
        if (!_isTeamOrOwner(msg.sender)) revert NotAuthorized();

        // Require at least one action
        if (actions.length == 0) revert NoActions();

        // Get config
        (, OrganizationConfig memory config) = manager.getOrganization(orgId);

        // Create proposal
        proposalCount++;
        proposalId = proposalCount;
        activeProposalId = proposalId;

        Proposal storage proposal = _proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.isTeamSponsored = _isTeamMember(msg.sender);
        proposal.status = ProposalStatus.Staking;
        proposal.outcome = ProposalOutcome.None;
        proposal.stakingEndsAt = block.timestamp + config.stakingDuration;

        // Copy actions
        for (uint256 i = 0; i < actions.length; i++) {
            proposal.actions.push(actions[i]);
        }

        emit ProposalCreated(proposalId, msg.sender, proposal.isTeamSponsored);
    }

    /// @inheritdoc IProposalManager
    function stake(
        uint256 proposalId,
        uint256 amount
    )
        external
        override
        whenInitialized
        proposalExists(proposalId)
        inStatus(proposalId, ProposalStatus.Staking)
    {
        Proposal storage proposal = _proposals[proposalId];

        // Transfer tokens from staker
        IERC20(treasury.baseToken()).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Track stake
        if (stakes[proposalId][msg.sender] == 0) {
            _stakers[proposalId].push(msg.sender);
        }
        stakes[proposalId][msg.sender] += amount;
        proposal.totalStaked += amount;

        emit Staked(proposalId, msg.sender, amount);
    }

    /// @inheritdoc IProposalManager
    function unstake(
        uint256 proposalId,
        uint256 amount
    )
        external
        override
        whenInitialized
        proposalExists(proposalId)
        inStatus(proposalId, ProposalStatus.Staking)
    {
        if (stakes[proposalId][msg.sender] < amount) revert InsufficientStake();

        Proposal storage proposal = _proposals[proposalId];

        // Update stake tracking
        stakes[proposalId][msg.sender] -= amount;
        proposal.totalStaked -= amount;

        // Return tokens
        IERC20(treasury.baseToken()).safeTransfer(msg.sender, amount);

        emit Unstaked(proposalId, msg.sender, amount);
    }

    /// @inheritdoc IProposalManager
    function activateProposal(
        uint256 proposalId
    )
        external
        override
        whenInitialized
        proposalExists(proposalId)
        inStatus(proposalId, ProposalStatus.Staking)
    {
        Proposal storage proposal = _proposals[proposalId];
        (, OrganizationConfig memory config) = manager.getOrganization(orgId);

        // Check staking duration passed
        if (block.timestamp < proposal.stakingEndsAt)
            revert StakingPeriodNotEnded();

        // Check staking threshold met
        uint256 requiredStake = _getRequiredStake(proposal.proposer, config);
        if (proposal.totalStaked < requiredStake) {
            revert StakingThresholdNotMet(proposal.totalStaked, requiredStake);
        }

        // 1. Refund all stakes
        _refundAllStakes(proposalId);

        // 2. Withdraw LP from treasury
        (uint256 baseAmount, uint256 quoteAmount) = treasury
            .withdrawLiquidityForProposal(config.lpAllocationPerProposalBps);
        proposal.baseTokenReserve = baseAmount;
        proposal.quoteTokenReserve = quoteAmount;

        // 3. Deploy conditional tokens
        ConditionalTokenSet memory tokens = tokenFactory.deployConditionalSet(
            proposalId,
            treasury.baseToken(),
            treasury.quoteToken(),
            address(this) // ProposalManager is minter
        );
        proposal.tokens = tokens;

        // 4. Mint conditional tokens (split the withdrawn liquidity)
        _mintConditionalTokens(tokens, baseAmount, quoteAmount);

        // 5. Approve and initialize decision markets
        _approveTokensForMarkets(tokens, baseAmount, quoteAmount);

        // Calculate TWAP recording start time
        uint256 twapRecordingStartTime = block.timestamp +
            config.twapRecordingDelay;

        // Get initial price from treasury spot pool (simplified: use 1:1)
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price

        PoolKey[2] memory poolKeys = marketManager.initializeMarkets(
            proposalId,
            tokens,
            baseAmount,
            quoteAmount,
            sqrtPriceX96,
            config.observationMaxRateBpsPerSecond,
            twapRecordingStartTime
        );

        proposal.passPoolKey = poolKeys[0];
        proposal.failPoolKey = poolKeys[1];

        // 6. Set timing
        proposal.tradingStartsAt = block.timestamp;
        proposal.tradingEndsAt = block.timestamp + config.tradingDuration;
        proposal.twapRecordingStartsAt = twapRecordingStartTime;

        // 7. Transition to Active
        proposal.status = ProposalStatus.Active;

        emit ProposalActivated(proposalId, baseAmount, quoteAmount);
    }

    /// @inheritdoc IProposalManager
    function cancelProposal(
        uint256 proposalId
    )
        external
        override
        whenInitialized
        proposalExists(proposalId)
        inStatus(proposalId, ProposalStatus.Staking)
    {
        Proposal storage proposal = _proposals[proposalId];
        (, OrganizationConfig memory config) = manager.getOrganization(orgId);

        // Check cancellation delay
        uint256 cancellationAllowedAt = proposal.stakingEndsAt -
            config.stakingDuration +
            config.minCancellationDelay;
        if (block.timestamp < cancellationAllowedAt)
            revert CancellationDelayNotPassed();

        // Check authorization (owner, team, or protocol admin)
        bool isAuthorized = _isTeamOrOwner(msg.sender) ||
            manager.protocolAdmins(msg.sender);
        if (!isAuthorized) revert NotAuthorized();

        // Refund all stakes
        _refundAllStakes(proposalId);

        // Transition to Cancelled
        proposal.status = ProposalStatus.Cancelled;
        activeProposalId = 0;

        emit ProposalCancelled(proposalId, msg.sender);
    }

    /// @inheritdoc IProposalManager
    function resolve(
        uint256 proposalId
    )
        external
        override
        whenInitialized
        proposalExists(proposalId)
        inStatus(proposalId, ProposalStatus.Active)
    {
        Proposal storage proposal = _proposals[proposalId];

        // Check trading period ended
        if (block.timestamp < proposal.tradingEndsAt) revert TradingNotEnded();

        // 1. Fetch final TWAPs
        (uint256 passTwap, uint256 failTwap) = marketManager.getTWAPs(
            proposalId
        );
        proposal.passTwap = passTwap;
        proposal.failTwap = failTwap;

        // 2. Determine outcome based on threshold
        (, OrganizationConfig memory config) = manager.getOrganization(orgId);
        int256 threshold = proposal.isTeamSponsored
            ? config.teamPassThresholdBps
            : config.nonTeamPassThresholdBps;

        bool passed = _checkPassCondition(passTwap, failTwap, threshold);

        // 3. Collect fees from decision markets
        marketManager.collectFees(proposalId);

        // 4. Remove LP from decision markets
        (
            uint256 pTokenAmount,
            uint256 pQuoteAmount,
            uint256 fTokenAmount,
            uint256 fQuoteAmount
        ) = marketManager.removeLiquidity(proposalId);

        // Burn the conditional tokens we got back (they were minted by us)
        _burnConditionalTokens(
            proposal.tokens,
            pTokenAmount,
            pQuoteAmount,
            fTokenAmount,
            fQuoteAmount
        );

        // 5. Add collateral back to treasury LP
        uint256 baseToReturn = passed
            ? proposal.baseTokenReserve
            : proposal.baseTokenReserve;
        uint256 quoteToReturn = passed
            ? proposal.quoteTokenReserve
            : proposal.quoteTokenReserve;

        // Transfer collateral to treasury
        IERC20(treasury.baseToken()).safeTransfer(
            address(treasury),
            baseToReturn
        );
        IERC20(treasury.quoteToken()).safeTransfer(
            address(treasury),
            quoteToReturn
        );
        treasury.addLiquidityAfterResolution(baseToReturn, quoteToReturn);

        // 6. Set resolution data
        proposal.outcome = passed ? ProposalOutcome.Pass : ProposalOutcome.Fail;
        proposal.resolvedAt = block.timestamp;
        proposal.status = ProposalStatus.Resolved;

        if (passed) {
            emit ProposalResolved(
                proposalId,
                ProposalOutcome.Pass,
                passTwap,
                failTwap
            );
        } else {
            proposal.status = ProposalStatus.Failed;
            activeProposalId = 0;
            emit ProposalFailed(proposalId);
        }
    }

    /// @inheritdoc IProposalManager
    function executeAction(
        uint256 proposalId,
        uint256 actionIndex
    )
        external
        override
        whenInitialized
        proposalExists(proposalId)
        inStatus(proposalId, ProposalStatus.Resolved)
    {
        Proposal storage proposal = _proposals[proposalId];

        // Check proposal passed
        if (proposal.outcome != ProposalOutcome.Pass)
            revert ProposalDidNotPass();

        // Validate action index
        if (actionIndex >= proposal.actions.length)
            revert InvalidActionIndex(actionIndex);

        ProposalAction storage action = proposal.actions[actionIndex];

        // Check not already executed
        if (action.executed) revert ActionAlreadyExecuted(actionIndex);

        // Check execution condition
        if (!_checkExecutionCondition(action))
            revert ExecutionConditionNotMet();

        // Execute via treasury
        treasury.execute(action.target, action.data, action.value);

        // Mark executed
        action.executed = true;

        emit ActionExecuted(proposalId, actionIndex);

        // Check if all actions executed
        bool allExecuted = true;
        for (uint256 i = 0; i < proposal.actions.length; i++) {
            if (!proposal.actions[i].executed) {
                allExecuted = false;
                break;
            }
        }

        if (allExecuted) {
            proposal.status = ProposalStatus.Executed;
            activeProposalId = 0;
            emit ProposalExecuted(proposalId);
        }
    }

    // ============ Conditional Token Operations ============

    /// @inheritdoc IProposalManager
    function split(
        uint256 proposalId,
        bool isBaseToken,
        uint256 amount
    ) external override whenInitialized proposalExists(proposalId) {
        Proposal storage proposal = _proposals[proposalId];

        // Can only split during Active status
        if (proposal.status != ProposalStatus.Active) {
            revert InvalidProposalStatus(
                proposal.status,
                ProposalStatus.Active
            );
        }

        ConditionalTokenSet memory tokens = proposal.tokens;

        if (isBaseToken) {
            // Lock base token collateral
            IERC20(treasury.baseToken()).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );

            // Mint pToken and fToken
            IConditionalToken(tokens.pToken).mint(msg.sender, amount);
            IConditionalToken(tokens.fToken).mint(msg.sender, amount);
        } else {
            // Lock quote token collateral
            IERC20(treasury.quoteToken()).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );

            // Mint pQuote and fQuote
            IConditionalToken(tokens.pQuote).mint(msg.sender, amount);
            IConditionalToken(tokens.fQuote).mint(msg.sender, amount);
        }

        emit TokensSplit(proposalId, msg.sender, isBaseToken, amount);
    }

    /// @inheritdoc IProposalManager
    function merge(
        uint256 proposalId,
        bool isBaseToken,
        uint256 amount
    ) external override whenInitialized proposalExists(proposalId) {
        Proposal storage proposal = _proposals[proposalId];

        // Can only merge during Active status
        if (proposal.status != ProposalStatus.Active) {
            revert InvalidProposalStatus(
                proposal.status,
                ProposalStatus.Active
            );
        }

        ConditionalTokenSet memory tokens = proposal.tokens;

        if (isBaseToken) {
            // Burn pToken and fToken
            IConditionalToken(tokens.pToken).burn(msg.sender, amount);
            IConditionalToken(tokens.fToken).burn(msg.sender, amount);

            // Release base token collateral
            IERC20(treasury.baseToken()).safeTransfer(msg.sender, amount);
        } else {
            // Burn pQuote and fQuote
            IConditionalToken(tokens.pQuote).burn(msg.sender, amount);
            IConditionalToken(tokens.fQuote).burn(msg.sender, amount);

            // Release quote token collateral
            IERC20(treasury.quoteToken()).safeTransfer(msg.sender, amount);
        }

        emit TokensMerged(proposalId, msg.sender, isBaseToken, amount);
    }

    /// @inheritdoc IProposalManager
    function redeem(
        uint256 proposalId
    ) external override whenInitialized proposalExists(proposalId) {
        Proposal storage proposal = _proposals[proposalId];

        // Can only redeem after resolution
        if (
            proposal.status != ProposalStatus.Resolved &&
            proposal.status != ProposalStatus.Executed &&
            proposal.status != ProposalStatus.Failed
        ) {
            revert CannotRedeem();
        }

        ConditionalTokenSet memory tokens = proposal.tokens;
        bool passed = proposal.outcome == ProposalOutcome.Pass;

        uint256 baseAmount;
        uint256 quoteAmount;

        if (passed) {
            // Redeem pToken for base, pQuote for quote
            uint256 pTokenBalance = IERC20(tokens.pToken).balanceOf(msg.sender);
            uint256 pQuoteBalance = IERC20(tokens.pQuote).balanceOf(msg.sender);

            if (pTokenBalance > 0) {
                IConditionalToken(tokens.pToken).burn(
                    msg.sender,
                    pTokenBalance
                );
                baseAmount = pTokenBalance;
            }
            if (pQuoteBalance > 0) {
                IConditionalToken(tokens.pQuote).burn(
                    msg.sender,
                    pQuoteBalance
                );
                quoteAmount = pQuoteBalance;
            }
        } else {
            // Redeem fToken for base, fQuote for quote
            uint256 fTokenBalance = IERC20(tokens.fToken).balanceOf(msg.sender);
            uint256 fQuoteBalance = IERC20(tokens.fQuote).balanceOf(msg.sender);

            if (fTokenBalance > 0) {
                IConditionalToken(tokens.fToken).burn(
                    msg.sender,
                    fTokenBalance
                );
                baseAmount = fTokenBalance;
            }
            if (fQuoteBalance > 0) {
                IConditionalToken(tokens.fQuote).burn(
                    msg.sender,
                    fQuoteBalance
                );
                quoteAmount = fQuoteBalance;
            }
        }

        if (baseAmount == 0 && quoteAmount == 0) revert NothingToRedeem();

        // Transfer collateral
        if (baseAmount > 0) {
            IERC20(treasury.baseToken()).safeTransfer(msg.sender, baseAmount);
        }
        if (quoteAmount > 0) {
            IERC20(treasury.quoteToken()).safeTransfer(msg.sender, quoteAmount);
        }

        emit TokensRedeemed(proposalId, msg.sender, baseAmount, quoteAmount);
    }

    // ============ View Functions ============

    /// @inheritdoc IProposalManager
    function getProposal(
        uint256 proposalId
    ) external view override returns (Proposal memory) {
        return _proposals[proposalId];
    }

    /// @inheritdoc IProposalManager
    function getStake(
        uint256 proposalId,
        address staker
    ) external view override returns (uint256) {
        return stakes[proposalId][staker];
    }

    /// @inheritdoc IProposalManager
    function canActivate(
        uint256 proposalId
    ) external view override returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;

        Proposal storage proposal = _proposals[proposalId];
        if (proposal.status != ProposalStatus.Staking) return false;
        if (block.timestamp < proposal.stakingEndsAt) return false;

        (, OrganizationConfig memory config) = manager.getOrganization(orgId);
        uint256 requiredStake = _getRequiredStake(proposal.proposer, config);

        return proposal.totalStaked >= requiredStake;
    }

    /// @inheritdoc IProposalManager
    function canResolve(
        uint256 proposalId
    ) external view override returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;

        Proposal storage proposal = _proposals[proposalId];
        if (proposal.status != ProposalStatus.Active) return false;

        return block.timestamp >= proposal.tradingEndsAt;
    }

    /// @inheritdoc IProposalManager
    function canCancel(
        uint256 proposalId
    ) external view override returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;

        Proposal storage proposal = _proposals[proposalId];
        if (proposal.status != ProposalStatus.Staking) return false;

        (, OrganizationConfig memory config) = manager.getOrganization(orgId);
        uint256 cancellationAllowedAt = proposal.stakingEndsAt -
            config.stakingDuration +
            config.minCancellationDelay;

        return block.timestamp >= cancellationAllowedAt;
    }

    // ============ Internal Functions ============

    /// @notice Check if address is team member or owner
    function _isTeamOrOwner(address account) internal view returns (bool) {
        return
            manager.isOwner(orgId, account) ||
            manager.isTeamMember(orgId, account);
    }

    /// @notice Check if address is team member (not owner)
    function _isTeamMember(address account) internal view returns (bool) {
        return
            manager.isTeamMember(orgId, account) &&
            !manager.isOwner(orgId, account);
    }

    /// @notice Get required stake for proposer
    function _getRequiredStake(
        address proposer,
        OrganizationConfig memory config
    ) internal view returns (uint256) {
        // For simplicity, use defaultStakingThreshold
        // In full implementation, would check owner vs team vs custom thresholds
        if (manager.isOwner(orgId, proposer)) {
            // Owner uses ownerStakingThresholdBps of total supply
            uint256 totalSupply = IERC20(treasury.baseToken()).totalSupply();
            return
                (totalSupply * config.ownerStakingThresholdBps) /
                BPS_DENOMINATOR;
        } else if (manager.isTeamMember(orgId, proposer)) {
            // Team uses teamStakingThresholdBps of total supply
            uint256 totalSupply = IERC20(treasury.baseToken()).totalSupply();
            return
                (totalSupply * config.teamStakingThresholdBps) /
                BPS_DENOMINATOR;
        } else {
            // Default threshold (should not reach here due to authorization check)
            return config.defaultStakingThreshold;
        }
    }

    /// @notice Refund all stakes for a proposal
    function _refundAllStakes(uint256 proposalId) internal {
        address[] storage stakers = _stakers[proposalId];
        uint256 totalRefunded = 0;

        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            uint256 stakeAmount = stakes[proposalId][staker];
            if (stakeAmount > 0) {
                stakes[proposalId][staker] = 0;
                IERC20(treasury.baseToken()).safeTransfer(staker, stakeAmount);
                totalRefunded += stakeAmount;
            }
        }

        _proposals[proposalId].totalStaked = 0;
        emit StakesRefunded(proposalId, totalRefunded);
    }

    /// @notice Mint conditional tokens for market initialization
    function _mintConditionalTokens(
        ConditionalTokenSet memory tokens,
        uint256 baseAmount,
        uint256 quoteAmount
    ) internal {
        // Mint pass and fail tokens for base
        IConditionalToken(tokens.pToken).mint(address(this), baseAmount);
        IConditionalToken(tokens.fToken).mint(address(this), baseAmount);

        // Mint pass and fail tokens for quote
        IConditionalToken(tokens.pQuote).mint(address(this), quoteAmount);
        IConditionalToken(tokens.fQuote).mint(address(this), quoteAmount);
    }

    /// @notice Burn conditional tokens after resolution
    function _burnConditionalTokens(
        ConditionalTokenSet memory tokens,
        uint256 pTokenAmount,
        uint256 pQuoteAmount,
        uint256 fTokenAmount,
        uint256 fQuoteAmount
    ) internal {
        if (pTokenAmount > 0)
            IConditionalToken(tokens.pToken).burn(address(this), pTokenAmount);
        if (fTokenAmount > 0)
            IConditionalToken(tokens.fToken).burn(address(this), fTokenAmount);
        if (pQuoteAmount > 0)
            IConditionalToken(tokens.pQuote).burn(address(this), pQuoteAmount);
        if (fQuoteAmount > 0)
            IConditionalToken(tokens.fQuote).burn(address(this), fQuoteAmount);
    }

    /// @notice Approve tokens for market manager
    function _approveTokensForMarkets(
        ConditionalTokenSet memory tokens,
        uint256 baseAmount,
        uint256 quoteAmount
    ) internal {
        IERC20(tokens.pToken).forceApprove(address(marketManager), baseAmount);
        IERC20(tokens.fToken).forceApprove(address(marketManager), baseAmount);
        IERC20(tokens.pQuote).forceApprove(address(marketManager), quoteAmount);
        IERC20(tokens.fQuote).forceApprove(address(marketManager), quoteAmount);
    }

    /// @notice Check if pass condition is met
    function _checkPassCondition(
        uint256 passTwap,
        uint256 failTwap,
        int256 thresholdBps
    ) internal pure returns (bool) {
        // Pass if: passTwap > failTwap × (1 + threshold/10000)
        // For negative threshold (team): easier to pass
        // For positive threshold (non-team): harder to pass

        if (thresholdBps >= 0) {
            uint256 threshold = uint256(thresholdBps);
            uint256 adjustedFailTwap = (failTwap *
                (BPS_DENOMINATOR + threshold)) / BPS_DENOMINATOR;
            return passTwap > adjustedFailTwap;
        } else {
            uint256 threshold = uint256(-thresholdBps);
            // Negative threshold means we subtract, making it easier to pass
            uint256 adjustedFailTwap = (failTwap *
                (BPS_DENOMINATOR - threshold)) / BPS_DENOMINATOR;
            return passTwap > adjustedFailTwap;
        }
    }

    /// @notice Check if execution condition is met
    function _checkExecutionCondition(
        ProposalAction storage action
    ) internal view returns (bool) {
        if (action.condition == ExecutionCondition.Immediate) {
            return true;
        } else if (action.condition == ExecutionCondition.TimeLocked) {
            uint256 unlockTime = abi.decode(action.conditionData, (uint256));
            return block.timestamp >= unlockTime;
        }
        // Other conditions (MarketCapThreshold, PriceThreshold, CustomOracle)
        // would need oracle integration - returning true for MVP
        return true;
    }
}
