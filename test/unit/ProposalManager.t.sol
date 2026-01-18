// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

// V4 Core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

// V4 Periphery
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

// Permit2
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// Solmate
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// Test utils
import {BaseTest} from "../utils/BaseTest.sol";
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";

// Local contracts
import {ProposalManager} from "../../src/core/ProposalManager.sol";
import {Treasury} from "../../src/core/Treasury.sol";
import {ConditionalTokenFactory} from "../../src/tokens/ConditionalTokenFactory.sol";
import {DecisionMarketManager} from "../../src/markets/DecisionMarketManager.sol";
import {LaggingTWAPHook} from "../../src/markets/LaggingTWAPHook.sol";
import {IProposalManager} from "../../src/interfaces/IProposalManager.sol";
import {IOrganizationManager} from "../../src/interfaces/IOrganizationManager.sol";

// Types
import {OrganizationState, OrganizationConfig, OrganizationType, OrganizationStatus} from "../../src/types/OrganizationTypes.sol";
import {Proposal, ProposalAction, ProposalStatus, ProposalOutcome, ActionType, ExecutionCondition} from "../../src/types/ProposalTypes.sol";

// ============================================================================
// ProposalManager Unit Tests
// ============================================================================
// Ticket: T-030
// Tests for SPECIFICATION.md §4.3
// ============================================================================

/// @notice Mock OrganizationManager for testing ProposalManager
contract MockOrganizationManager {
    OrganizationState public state;
    OrganizationConfig public config;
    address public treasuryAddr;

    mapping(address => bool) public _protocolAdmins;
    mapping(address => bool) public _owners;
    mapping(address => bool) public _teamMembers;

    constructor() {
        // Set default config
        config = OrganizationConfig({
            minTwapSpreadBps: 300,
            teamPassThresholdBps: -300,
            nonTeamPassThresholdBps: 300,
            defaultStakingThreshold: 100e18,
            teamStakingThresholdBps: 300,
            ownerStakingThresholdBps: 500,
            stakingDuration: 48 hours,
            tradingDuration: 4 days,
            twapRecordingDelay: 24 hours,
            minCancellationDelay: 24 hours,
            observationMaxRateBpsPerSecond: 8,
            lpAllocationPerProposalBps: 5000
        });

        state = OrganizationState({
            orgType: OrganizationType.External,
            status: OrganizationStatus.Active,
            metadataURI: "ipfs://test",
            baseToken: address(0),
            quoteToken: address(0),
            owner: address(0),
            createdAt: block.timestamp
        });
    }

    function getOrganization(
        uint256
    )
        external
        view
        returns (OrganizationState memory, OrganizationConfig memory)
    {
        return (state, config);
    }

    function isOwner(uint256, address user) external view returns (bool) {
        return _owners[user];
    }

    function isTeamMember(uint256, address user) external view returns (bool) {
        return _teamMembers[user];
    }

    function protocolAdmins(address account) external view returns (bool) {
        return _protocolAdmins[account];
    }

    function treasuries(uint256) external view returns (address) {
        return treasuryAddr;
    }

    // Test helpers
    function setOwner(address user, bool isOwnerVal) external {
        _owners[user] = isOwnerVal;
    }

    function setTeamMember(address user, bool isTeam) external {
        _teamMembers[user] = isTeam;
    }

    function setProtocolAdmin(address account, bool isAdmin) external {
        _protocolAdmins[account] = isAdmin;
    }

    function setTreasury(address treasury) external {
        treasuryAddr = treasury;
    }

    function setBaseToken(address token) external {
        state.baseToken = token;
    }

    function setQuoteToken(address token) external {
        state.quoteToken = token;
    }

    function setStakingDuration(uint256 duration) external {
        config.stakingDuration = duration;
    }

    function setTradingDuration(uint256 duration) external {
        config.tradingDuration = duration;
    }

    function setTwapRecordingDelay(uint256 delay) external {
        config.twapRecordingDelay = delay;
    }

    function setMinCancellationDelay(uint256 delay) external {
        config.minCancellationDelay = delay;
    }

    function setDefaultStakingThreshold(uint256 threshold) external {
        config.defaultStakingThreshold = threshold;
    }

    function setLpAllocationPerProposalBps(uint256 bps) external {
        config.lpAllocationPerProposalBps = bps;
    }
}

contract ProposalManagerTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    ProposalManager public proposalManager;
    Treasury public treasury;
    ConditionalTokenFactory public tokenFactory;
    DecisionMarketManager public marketManager;
    LaggingTWAPHook public twapHook;
    MockOrganizationManager public mockManager;

    MockERC20 public baseToken;
    MockERC20 public quoteToken;

    Currency currency0;
    Currency currency1;

    PoolKey spotPoolKey;
    PoolId spotPoolId;

    address public owner = makeAddr("owner");
    address public teamMember = makeAddr("teamMember");
    address public alice = makeAddr("alice");
    address public protocolAdmin = makeAddr("protocolAdmin");

    uint256 constant ORG_ID = 1;
    uint256 constant BASE_AMOUNT = 10_000e18;
    uint256 constant QUOTE_AMOUNT = 10_000e18;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    // Stake amounts - based on 1.2M total supply
    // Owner threshold: 5% (500 bps) of 1.2M = 60K
    // Team threshold: 3% (300 bps) of 1.2M = 36K
    uint256 constant OWNER_STAKE_THRESHOLD = 60_000e18;
    uint256 constant TEAM_STAKE_THRESHOLD = 36_000e18;

    // ============ Setup ============

    function setUp() public {
        // Deploy V4 infrastructure
        deployArtifactsAndLabel();

        // Deploy tokens and mint
        baseToken = new MockERC20("Base Token", "BASE", 18);
        quoteToken = new MockERC20("Quote Token", "QUOTE", 18);

        baseToken.mint(owner, 1_000_000e18);
        quoteToken.mint(owner, 1_000_000e18);
        baseToken.mint(teamMember, 100_000e18);
        quoteToken.mint(teamMember, 100_000e18);
        baseToken.mint(alice, 100_000e18);
        quoteToken.mint(alice, 100_000e18);

        // Sort tokens for V4
        if (address(baseToken) > address(quoteToken)) {
            (baseToken, quoteToken) = (quoteToken, baseToken);
        }

        currency0 = Currency.wrap(address(baseToken));
        currency1 = Currency.wrap(address(quoteToken));

        // Deploy TWAP hook with proper flags (needs to be at specific address)
        address hookFlags = address(
            uint160(Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "LaggingTWAPHook.sol:LaggingTWAPHook",
            abi.encode(poolManager),
            hookFlags
        );
        twapHook = LaggingTWAPHook(hookFlags);

        // Deploy mock manager
        mockManager = new MockOrganizationManager();
        mockManager.setOwner(owner, true);
        mockManager.setTeamMember(teamMember, true);
        mockManager.setProtocolAdmin(protocolAdmin, true);
        mockManager.setBaseToken(address(baseToken));
        mockManager.setQuoteToken(address(quoteToken));

        // Deploy token factory
        tokenFactory = new ConditionalTokenFactory();

        // Deploy Treasury
        treasury = new Treasury(permit2, poolManager, positionManager);
        treasury.initialize(
            ORG_ID,
            address(mockManager),
            address(baseToken),
            address(quoteToken),
            address(positionManager)
        );
        mockManager.setTreasury(address(treasury));

        // Deploy DecisionMarketManager
        marketManager = new DecisionMarketManager(
            permit2,
            poolManager,
            positionManager,
            twapHook
        );
        twapHook.setDecisionMarketManager(address(marketManager));

        // Deploy ProposalManager
        proposalManager = new ProposalManager();

        // Initialize ProposalManager
        proposalManager.initialize(
            ORG_ID,
            address(mockManager),
            address(treasury),
            address(tokenFactory),
            address(marketManager)
        );

        // Set proposal manager on treasury
        vm.prank(address(mockManager));
        treasury.setProposalManager(address(proposalManager));

        // Set proposal manager on market manager
        marketManager.setProposalManager(address(proposalManager));

        // Create spot pool for Treasury LP (no hook needed)
        spotPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        spotPoolId = spotPoolKey.toId();
        poolManager.initialize(spotPoolKey, SQRT_PRICE_1_1);

        // Fund treasury and create spot position
        vm.startPrank(owner);
        baseToken.transfer(address(treasury), BASE_AMOUNT);
        quoteToken.transfer(address(treasury), QUOTE_AMOUNT);
        vm.stopPrank();

        vm.prank(address(mockManager));
        treasury.createSpotPosition(BASE_AMOUNT, QUOTE_AMOUNT, spotPoolKey);

        // Setup approvals for staking
        vm.prank(owner);
        baseToken.approve(address(proposalManager), type(uint256).max);
        vm.prank(teamMember);
        baseToken.approve(address(proposalManager), type(uint256).max);
        vm.prank(alice);
        baseToken.approve(address(proposalManager), type(uint256).max);
    }

    // ============ Helper Functions ============

    function _createDefaultAction()
        internal
        pure
        returns (ProposalAction memory)
    {
        return
            ProposalAction({
                actionType: ActionType.Custom,
                target: address(0x1234),
                data: "",
                value: 0,
                condition: ExecutionCondition.Immediate,
                conditionData: "",
                executed: false
            });
    }

    function _createProposalAsOwner() internal returns (uint256 proposalId) {
        ProposalAction[] memory actions = new ProposalAction[](1);
        actions[0] = _createDefaultAction();

        vm.prank(owner);
        proposalId = proposalManager.createProposal(actions);
    }

    function _createProposalAsTeamMember()
        internal
        returns (uint256 proposalId)
    {
        ProposalAction[] memory actions = new ProposalAction[](1);
        actions[0] = _createDefaultAction();

        vm.prank(teamMember);
        proposalId = proposalManager.createProposal(actions);
    }

    // ============ Constructor Tests ============

    // Note: ProposalManager has no constructor arguments, so no constructor tests needed

    // ============ Initialize Tests ============

    function test_Initialize_SetsOrgId() public view {
        assertEq(proposalManager.orgId(), ORG_ID);
    }

    function test_Initialize_SetsInitialized() public view {
        assertTrue(proposalManager.initialized());
    }

    function test_Initialize_SetsManager() public view {
        assertEq(address(proposalManager.manager()), address(mockManager));
    }

    function test_Initialize_SetsTreasury() public view {
        assertEq(address(proposalManager.treasury()), address(treasury));
    }

    function test_Initialize_SetsTokenFactory() public view {
        assertEq(
            address(proposalManager.tokenFactory()),
            address(tokenFactory)
        );
    }

    function test_Initialize_SetsMarketManager() public view {
        assertEq(
            address(proposalManager.marketManager()),
            address(marketManager)
        );
    }

    function testRevert_Initialize_AlreadyInitialized() public {
        vm.expectRevert(IProposalManager.AlreadyInitialized.selector);
        proposalManager.initialize(
            ORG_ID,
            address(mockManager),
            address(treasury),
            address(tokenFactory),
            address(marketManager)
        );
    }

    function testRevert_Initialize_ZeroManager() public {
        ProposalManager newPM = new ProposalManager();
        vm.expectRevert(IProposalManager.ZeroAddress.selector);
        newPM.initialize(
            ORG_ID,
            address(0),
            address(treasury),
            address(tokenFactory),
            address(marketManager)
        );
    }

    function testRevert_Initialize_ZeroTreasury() public {
        ProposalManager newPM = new ProposalManager();
        vm.expectRevert(IProposalManager.ZeroAddress.selector);
        newPM.initialize(
            ORG_ID,
            address(mockManager),
            address(0),
            address(tokenFactory),
            address(marketManager)
        );
    }

    function testRevert_Initialize_ZeroTokenFactory() public {
        ProposalManager newPM = new ProposalManager();
        vm.expectRevert(IProposalManager.ZeroAddress.selector);
        newPM.initialize(
            ORG_ID,
            address(mockManager),
            address(treasury),
            address(0),
            address(marketManager)
        );
    }

    function testRevert_Initialize_ZeroMarketManager() public {
        ProposalManager newPM = new ProposalManager();
        vm.expectRevert(IProposalManager.ZeroAddress.selector);
        newPM.initialize(
            ORG_ID,
            address(mockManager),
            address(treasury),
            address(tokenFactory),
            address(0)
        );
    }

    // ============ CreateProposal Tests ============

    function test_CreateProposal_Success() public {
        uint256 proposalId = _createProposalAsOwner();

        assertEq(proposalId, 1);
        assertEq(proposalManager.proposalCount(), 1);
        assertEq(proposalManager.activeProposalId(), 1);
    }

    function test_CreateProposal_ByTeamMember() public {
        uint256 proposalId = _createProposalAsTeamMember();

        assertEq(proposalId, 1);

        Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.proposer, teamMember);
        assertTrue(proposal.isTeamSponsored);
    }

    function test_CreateProposal_ByOwner() public {
        uint256 proposalId = _createProposalAsOwner();

        Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.proposer, owner);
        // Owner creates proposal but isTeamSponsored = false because owner != team member
        assertFalse(proposal.isTeamSponsored);
    }

    function test_CreateProposal_StatusIsStaking() public {
        uint256 proposalId = _createProposalAsOwner();

        Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertTrue(proposal.status == ProposalStatus.Staking);
    }

    function test_CreateProposal_SetsStakingEndsAt() public {
        mockManager.setStakingDuration(48 hours);

        uint256 proposalId = _createProposalAsOwner();

        Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.stakingEndsAt, block.timestamp + 48 hours);
    }

    function test_CreateProposal_EmitsEvent() public {
        ProposalAction[] memory actions = new ProposalAction[](1);
        actions[0] = _createDefaultAction();

        // Owner proposal has isTeamSponsored = false
        vm.expectEmit(true, true, false, true);
        emit IProposalManager.ProposalCreated(1, owner, false);

        vm.prank(owner);
        proposalManager.createProposal(actions);
    }

    function testRevert_CreateProposal_NotAuthorized() public {
        ProposalAction[] memory actions = new ProposalAction[](1);
        actions[0] = _createDefaultAction();

        vm.expectRevert(IProposalManager.NotAuthorized.selector);
        vm.prank(alice);
        proposalManager.createProposal(actions);
    }

    function testRevert_CreateProposal_NoActions() public {
        ProposalAction[] memory actions = new ProposalAction[](0);

        vm.expectRevert(IProposalManager.NoActions.selector);
        vm.prank(owner);
        proposalManager.createProposal(actions);
    }

    function testRevert_CreateProposal_ProposalExists() public {
        _createProposalAsOwner();

        ProposalAction[] memory actions = new ProposalAction[](1);
        actions[0] = _createDefaultAction();

        vm.expectRevert(IProposalManager.ProposalExists.selector);
        vm.prank(owner);
        proposalManager.createProposal(actions);
    }

    // ============ Stake Tests ============

    function test_Stake_Success() public {
        uint256 proposalId = _createProposalAsOwner();
        uint256 stakeAmount = 100e18;

        uint256 balanceBefore = baseToken.balanceOf(owner);

        vm.prank(owner);
        proposalManager.stake(proposalId, stakeAmount);

        assertEq(proposalManager.getStake(proposalId, owner), stakeAmount);
        assertEq(baseToken.balanceOf(owner), balanceBefore - stakeAmount);
    }

    function test_Stake_MultipleTimes() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.startPrank(owner);
        proposalManager.stake(proposalId, 50e18);
        proposalManager.stake(proposalId, 50e18);
        vm.stopPrank();

        assertEq(proposalManager.getStake(proposalId, owner), 100e18);
    }

    function test_Stake_MultipleStakers() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, 50e18);

        vm.prank(teamMember);
        proposalManager.stake(proposalId, 50e18);

        Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.totalStaked, 100e18);
    }

    function test_Stake_EmitsEvent() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.expectEmit(true, true, false, true);
        emit IProposalManager.Staked(proposalId, owner, 100e18);

        vm.prank(owner);
        proposalManager.stake(proposalId, 100e18);
    }

    function testRevert_Stake_ProposalNotFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IProposalManager.ProposalNotFound.selector,
                999
            )
        );
        vm.prank(owner);
        proposalManager.stake(999, 100e18);
    }

    function testRevert_Stake_InvalidStatus() public {
        uint256 proposalId = _createProposalAsOwner();

        // Stake threshold and wait
        vm.prank(owner);
        proposalManager.stake(proposalId, OWNER_STAKE_THRESHOLD);
        vm.warp(block.timestamp + 48 hours + 1);

        // Activate
        proposalManager.activateProposal(proposalId);

        // Try to stake when Active
        vm.expectRevert(
            abi.encodeWithSelector(
                IProposalManager.InvalidProposalStatus.selector,
                ProposalStatus.Active,
                ProposalStatus.Staking
            )
        );
        vm.prank(owner);
        proposalManager.stake(proposalId, 100e18);
    }

    // ============ Unstake Tests ============

    function test_Unstake_Success() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, 100e18);

        uint256 balanceBefore = baseToken.balanceOf(owner);

        vm.prank(owner);
        proposalManager.unstake(proposalId, 50e18);

        assertEq(proposalManager.getStake(proposalId, owner), 50e18);
        assertEq(baseToken.balanceOf(owner), balanceBefore + 50e18);
    }

    function test_Unstake_EmitsEvent() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, 100e18);

        vm.expectEmit(true, true, false, true);
        emit IProposalManager.Unstaked(proposalId, owner, 50e18);

        vm.prank(owner);
        proposalManager.unstake(proposalId, 50e18);
    }

    function testRevert_Unstake_InsufficientStake() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, 50e18);

        vm.expectRevert(IProposalManager.InsufficientStake.selector);
        vm.prank(owner);
        proposalManager.unstake(proposalId, 100e18);
    }

    // ============ ActivateProposal Tests ============

    function test_ActivateProposal_Success() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, OWNER_STAKE_THRESHOLD);

        vm.warp(block.timestamp + 48 hours + 1);

        proposalManager.activateProposal(proposalId);

        Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertTrue(proposal.status == ProposalStatus.Active);
    }

    function test_ActivateProposal_RefundsStakes() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, OWNER_STAKE_THRESHOLD);

        uint256 balanceBefore = baseToken.balanceOf(owner);

        vm.warp(block.timestamp + 48 hours + 1);
        proposalManager.activateProposal(proposalId);

        // Stakes should be refunded
        assertEq(
            baseToken.balanceOf(owner),
            balanceBefore + OWNER_STAKE_THRESHOLD
        );
        assertEq(proposalManager.getStake(proposalId, owner), 0);
    }

    function test_ActivateProposal_SetsTradingTimes() public {
        mockManager.setTradingDuration(4 days);
        mockManager.setTwapRecordingDelay(24 hours);

        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, OWNER_STAKE_THRESHOLD);

        vm.warp(block.timestamp + 48 hours + 1);
        proposalManager.activateProposal(proposalId);

        Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.tradingStartsAt, block.timestamp);
        assertEq(proposal.tradingEndsAt, block.timestamp + 4 days);
        assertEq(proposal.twapRecordingStartsAt, block.timestamp + 24 hours);
    }

    function test_ActivateProposal_EmitsEvent() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, OWNER_STAKE_THRESHOLD);

        vm.warp(block.timestamp + 48 hours + 1);

        vm.expectEmit(true, false, false, false);
        emit IProposalManager.ProposalActivated(proposalId, 0, 0);

        proposalManager.activateProposal(proposalId);
    }

    function testRevert_ActivateProposal_StakingPeriodNotEnded() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, OWNER_STAKE_THRESHOLD);

        // Don't warp time

        vm.expectRevert(IProposalManager.StakingPeriodNotEnded.selector);
        proposalManager.activateProposal(proposalId);
    }

    function testRevert_ActivateProposal_ThresholdNotMet() public {
        uint256 proposalId = _createProposalAsOwner();

        uint256 insufficientStake = 10e18; // Less than OWNER_STAKE_THRESHOLD
        vm.prank(owner);
        proposalManager.stake(proposalId, insufficientStake);

        vm.warp(block.timestamp + 48 hours + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IProposalManager.StakingThresholdNotMet.selector,
                insufficientStake,
                OWNER_STAKE_THRESHOLD
            )
        );
        proposalManager.activateProposal(proposalId);
    }

    // ============ CancelProposal Tests ============

    function test_CancelProposal_ByOwner() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(owner);
        proposalManager.cancelProposal(proposalId);

        Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertTrue(proposal.status == ProposalStatus.Cancelled);
        assertEq(proposalManager.activeProposalId(), 0);
    }

    function test_CancelProposal_ByTeamMember() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(teamMember);
        proposalManager.cancelProposal(proposalId);

        Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertTrue(proposal.status == ProposalStatus.Cancelled);
    }

    function test_CancelProposal_ByProtocolAdmin() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(protocolAdmin);
        proposalManager.cancelProposal(proposalId);

        Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertTrue(proposal.status == ProposalStatus.Cancelled);
    }

    function test_CancelProposal_RefundsStakes() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, 100e18);

        uint256 balanceBefore = baseToken.balanceOf(owner);

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(owner);
        proposalManager.cancelProposal(proposalId);

        assertEq(baseToken.balanceOf(owner), balanceBefore + 100e18);
    }

    function test_CancelProposal_EmitsEvent() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.warp(block.timestamp + 24 hours + 1);

        vm.expectEmit(true, true, false, true);
        emit IProposalManager.ProposalCancelled(proposalId, owner);

        vm.prank(owner);
        proposalManager.cancelProposal(proposalId);
    }

    function testRevert_CancelProposal_NotAuthorized() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.warp(block.timestamp + 24 hours + 1);

        vm.expectRevert(IProposalManager.NotAuthorized.selector);
        vm.prank(alice);
        proposalManager.cancelProposal(proposalId);
    }

    function testRevert_CancelProposal_DelayNotPassed() public {
        uint256 proposalId = _createProposalAsOwner();

        // Don't warp past cancellation delay

        vm.expectRevert(IProposalManager.CancellationDelayNotPassed.selector);
        vm.prank(owner);
        proposalManager.cancelProposal(proposalId);
    }

    // ============ View Function Tests ============

    function test_GetProposal_ReturnsCorrectData() public {
        uint256 proposalId = _createProposalAsOwner();

        Proposal memory proposal = proposalManager.getProposal(proposalId);

        assertEq(proposal.id, proposalId);
        assertEq(proposal.proposer, owner);
        assertFalse(proposal.isTeamSponsored); // Owner != team member
        assertTrue(proposal.status == ProposalStatus.Staking);
    }

    function test_GetStake_ReturnsZeroForNonStaker() public {
        uint256 proposalId = _createProposalAsOwner();

        assertEq(proposalManager.getStake(proposalId, alice), 0);
    }

    function test_CanActivate_ReturnsTrueWhenReady() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, OWNER_STAKE_THRESHOLD);

        vm.warp(block.timestamp + 48 hours + 1);

        assertTrue(proposalManager.canActivate(proposalId));
    }

    function test_CanActivate_ReturnsFalseWhenNotReady() public {
        uint256 proposalId = _createProposalAsOwner();

        // Not enough stake
        vm.prank(owner);
        proposalManager.stake(proposalId, 10e18);

        vm.warp(block.timestamp + 48 hours + 1);

        assertFalse(proposalManager.canActivate(proposalId));
    }

    function test_CanActivate_ReturnsFalseWhenTimeTooEarly() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.prank(owner);
        proposalManager.stake(proposalId, OWNER_STAKE_THRESHOLD);

        // Don't warp time
        assertFalse(proposalManager.canActivate(proposalId));
    }

    function test_CanCancel_ReturnsTrueWhenReady() public {
        uint256 proposalId = _createProposalAsOwner();

        vm.warp(block.timestamp + 24 hours + 1);

        assertTrue(proposalManager.canCancel(proposalId));
    }

    function test_CanCancel_ReturnsFalseWhenTooEarly() public {
        uint256 proposalId = _createProposalAsOwner();

        // Don't warp time
        assertFalse(proposalManager.canCancel(proposalId));
    }

    function test_CanResolve_ReturnsFalseWhenStaking() public {
        uint256 proposalId = _createProposalAsOwner();

        assertFalse(proposalManager.canResolve(proposalId));
    }

    function test_ProposalCount_ReturnsCorrectCount() public {
        assertEq(proposalManager.proposalCount(), 0);

        _createProposalAsOwner();
        assertEq(proposalManager.proposalCount(), 1);
    }

    function test_ActiveProposalId_ReturnsZeroWhenNone() public view {
        assertEq(proposalManager.activeProposalId(), 0);
    }

    function test_ActiveProposalId_ReturnsCorrectId() public {
        uint256 proposalId = _createProposalAsOwner();

        assertEq(proposalManager.activeProposalId(), proposalId);
    }

    // ============ Not Initialized Tests ============

    function testRevert_CreateProposal_NotInitialized() public {
        ProposalManager newPM = new ProposalManager();

        ProposalAction[] memory actions = new ProposalAction[](1);
        actions[0] = _createDefaultAction();

        vm.expectRevert(IProposalManager.NotInitialized.selector);
        vm.prank(owner);
        newPM.createProposal(actions);
    }

    function testRevert_Stake_NotInitialized() public {
        ProposalManager newPM = new ProposalManager();

        vm.expectRevert(IProposalManager.NotInitialized.selector);
        vm.prank(owner);
        newPM.stake(1, 100e18);
    }
}
