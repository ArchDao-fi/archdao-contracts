// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

// V4 Core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
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

// Local contracts
import {OrganizationManager} from "../../src/core/OrganizationManager.sol";
import {ConditionalTokenFactory} from "../../src/tokens/ConditionalTokenFactory.sol";
import {DecisionMarketManager} from "../../src/markets/DecisionMarketManager.sol";
import {LaggingTWAPHook} from "../../src/markets/LaggingTWAPHook.sol";
import {IOrganizationManager} from "../../src/interfaces/IOrganizationManager.sol";

// Types
import {OrganizationState, OrganizationConfig, OrganizationType, OrganizationStatus, OrgRole} from "../../src/types/OrganizationTypes.sol";
import {RaiseConfig} from "../../src/types/RaiseTypes.sol";

// ============================================================================
// OrganizationManager Unit Tests
// ============================================================================
// Ticket: T-033
// Tests for SPECIFICATION.md §4.1
// ============================================================================

contract OrganizationManagerTest is BaseTest {
    using CurrencyLibrary for Currency;

    OrganizationManager public orgManager;
    ConditionalTokenFactory public tokenFactory;
    DecisionMarketManager public marketManager;
    LaggingTWAPHook public twapHook;

    MockERC20 public baseToken;
    MockERC20 public quoteToken;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 constant BASE_AMOUNT = 10_000e18;
    uint256 constant QUOTE_AMOUNT = 10_000e18;

    // ============ Setup ============

    function setUp() public {
        // Deploy V4 infrastructure
        deployArtifactsAndLabel();

        // Deploy tokens
        baseToken = new MockERC20("Base Token", "BASE", 18);
        quoteToken = new MockERC20("Quote Token", "QUOTE", 18);

        // Sort tokens for V4
        if (address(baseToken) > address(quoteToken)) {
            (baseToken, quoteToken) = (quoteToken, baseToken);
        }

        // Mint tokens to users
        baseToken.mint(alice, 1_000_000e18);
        quoteToken.mint(alice, 1_000_000e18);
        baseToken.mint(bob, 100_000e18);
        quoteToken.mint(bob, 100_000e18);

        // Deploy TWAP hook
        address hookFlags = address(
            uint160(Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "LaggingTWAPHook.sol:LaggingTWAPHook",
            abi.encode(poolManager),
            hookFlags
        );
        twapHook = LaggingTWAPHook(hookFlags);

        // Deploy token factory
        tokenFactory = new ConditionalTokenFactory();

        // Deploy market manager
        marketManager = new DecisionMarketManager(
            permit2,
            poolManager,
            positionManager,
            twapHook
        );
        twapHook.setDecisionMarketManager(address(marketManager));

        // Deploy OrganizationManager
        orgManager = new OrganizationManager(
            permit2,
            poolManager,
            positionManager,
            tokenFactory,
            marketManager,
            admin
        );

        // Approve tokens for users
        vm.prank(alice);
        baseToken.approve(address(orgManager), type(uint256).max);
        vm.prank(alice);
        quoteToken.approve(address(orgManager), type(uint256).max);
    }

    // ============ Helper Functions ============

    function _createDefaultConfig()
        internal
        pure
        returns (OrganizationConfig memory)
    {
        return
            OrganizationConfig({
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
    }

    function _createDefaultRaiseConfig()
        internal
        view
        returns (RaiseConfig memory)
    {
        return
            RaiseConfig({
                softCap: 1000e18,
                hardCap: 10_000e18,
                startDate: block.timestamp + 1 days,
                endDate: block.timestamp + 30 days,
                quoteToken: address(quoteToken),
                agreedConfig: _createDefaultConfig()
            });
    }

    function _createExternalOrg() internal returns (uint256 orgId) {
        vm.prank(alice);
        orgId = orgManager.createExternalOrganization(
            "ipfs://metadata",
            address(baseToken),
            address(quoteToken),
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            _createDefaultConfig()
        );
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsPermit2() public view {
        assertEq(address(orgManager.permit2()), address(permit2));
    }

    function test_Constructor_SetsPoolManager() public view {
        assertEq(address(orgManager.poolManager()), address(poolManager));
    }

    function test_Constructor_SetsPositionManager() public view {
        assertEq(
            address(orgManager.positionManager()),
            address(positionManager)
        );
    }

    function test_Constructor_SetsTokenFactory() public view {
        assertEq(address(orgManager.tokenFactory()), address(tokenFactory));
    }

    function test_Constructor_SetsMarketManager() public view {
        assertEq(address(orgManager.marketManager()), address(marketManager));
    }

    function test_Constructor_SetsInitialAdmin() public view {
        assertTrue(orgManager.protocolAdmins(admin));
    }

    function test_Constructor_SetsFeeRecipient() public view {
        assertEq(orgManager.protocolFeeRecipient(), admin);
    }

    function test_Constructor_SetsDefaultPoolFee() public view {
        assertEq(orgManager.defaultPoolFeeBps(), 3000);
    }

    function testRevert_Constructor_ZeroPermit2() public {
        vm.expectRevert(IOrganizationManager.ZeroAddress.selector);
        new OrganizationManager(
            IAllowanceTransfer(address(0)),
            poolManager,
            positionManager,
            tokenFactory,
            marketManager,
            admin
        );
    }

    function testRevert_Constructor_ZeroPoolManager() public {
        vm.expectRevert(IOrganizationManager.ZeroAddress.selector);
        new OrganizationManager(
            permit2,
            IPoolManager(address(0)),
            positionManager,
            tokenFactory,
            marketManager,
            admin
        );
    }

    function testRevert_Constructor_ZeroPositionManager() public {
        vm.expectRevert(IOrganizationManager.ZeroAddress.selector);
        new OrganizationManager(
            permit2,
            poolManager,
            IPositionManager(address(0)),
            tokenFactory,
            marketManager,
            admin
        );
    }

    function testRevert_Constructor_ZeroTokenFactory() public {
        vm.expectRevert(IOrganizationManager.ZeroAddress.selector);
        new OrganizationManager(
            permit2,
            poolManager,
            positionManager,
            ConditionalTokenFactory(address(0)),
            marketManager,
            admin
        );
    }

    function testRevert_Constructor_ZeroMarketManager() public {
        vm.expectRevert(IOrganizationManager.ZeroAddress.selector);
        new OrganizationManager(
            permit2,
            poolManager,
            positionManager,
            tokenFactory,
            DecisionMarketManager(address(0)),
            admin
        );
    }

    function testRevert_Constructor_ZeroAdmin() public {
        vm.expectRevert(IOrganizationManager.ZeroAddress.selector);
        new OrganizationManager(
            permit2,
            poolManager,
            positionManager,
            tokenFactory,
            marketManager,
            address(0)
        );
    }

    // ============ CreateExternalOrganization Tests ============

    function test_CreateExternalOrganization_Success() public {
        uint256 orgId = _createExternalOrg();

        assertEq(orgId, 1);
        assertEq(orgManager.orgCount(), 1);
    }

    function test_CreateExternalOrganization_SetsState() public {
        uint256 orgId = _createExternalOrg();

        (OrganizationState memory state, ) = orgManager.getOrganization(orgId);

        assertTrue(state.orgType == OrganizationType.External);
        assertTrue(state.status == OrganizationStatus.Pending);
        assertEq(state.baseToken, address(baseToken));
        assertEq(state.quoteToken, address(quoteToken));
        assertEq(state.owner, alice);
    }

    function test_CreateExternalOrganization_SetsOwnerRole() public {
        uint256 orgId = _createExternalOrg();

        assertTrue(orgManager.isOwner(orgId, alice));
        assertFalse(orgManager.isTeamMember(orgId, alice));
    }

    function test_CreateExternalOrganization_DeploysTreasury() public {
        uint256 orgId = _createExternalOrg();

        address treasury = orgManager.treasuries(orgId);
        assertTrue(treasury != address(0));
    }

    function test_CreateExternalOrganization_DeploysProposalManager() public {
        uint256 orgId = _createExternalOrg();

        address pm = orgManager.proposalManagers(orgId);
        assertTrue(pm != address(0));
    }

    function test_CreateExternalOrganization_TransfersTokens() public {
        uint256 aliceBaseBefore = baseToken.balanceOf(alice);
        uint256 aliceQuoteBefore = quoteToken.balanceOf(alice);

        uint256 orgId = _createExternalOrg();

        address treasury = orgManager.treasuries(orgId);

        assertEq(baseToken.balanceOf(alice), aliceBaseBefore - BASE_AMOUNT);
        assertEq(quoteToken.balanceOf(alice), aliceQuoteBefore - QUOTE_AMOUNT);
        assertEq(baseToken.balanceOf(treasury), BASE_AMOUNT);
        assertEq(quoteToken.balanceOf(treasury), QUOTE_AMOUNT);
    }

    function test_CreateExternalOrganization_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IOrganizationManager.OrganizationCreated(
            1,
            OrganizationType.External,
            alice
        );

        vm.prank(alice);
        orgManager.createExternalOrganization(
            "ipfs://metadata",
            address(baseToken),
            address(quoteToken),
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            _createDefaultConfig()
        );
    }

    function testRevert_CreateExternalOrganization_ZeroBaseToken() public {
        vm.expectRevert(IOrganizationManager.ZeroAddress.selector);
        vm.prank(alice);
        orgManager.createExternalOrganization(
            "ipfs://metadata",
            address(0),
            address(quoteToken),
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            _createDefaultConfig()
        );
    }

    function testRevert_CreateExternalOrganization_ZeroQuoteToken() public {
        vm.expectRevert(IOrganizationManager.ZeroAddress.selector);
        vm.prank(alice);
        orgManager.createExternalOrganization(
            "ipfs://metadata",
            address(baseToken),
            address(0),
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            _createDefaultConfig()
        );
    }

    function testRevert_CreateExternalOrganization_ZeroBaseAmount() public {
        vm.expectRevert(IOrganizationManager.InvalidConfig.selector);
        vm.prank(alice);
        orgManager.createExternalOrganization(
            "ipfs://metadata",
            address(baseToken),
            address(quoteToken),
            0,
            QUOTE_AMOUNT,
            _createDefaultConfig()
        );
    }

    function testRevert_CreateExternalOrganization_WhenPaused() public {
        vm.prank(admin);
        orgManager.pause();

        vm.expectRevert(IOrganizationManager.ProtocolPaused.selector);
        vm.prank(alice);
        orgManager.createExternalOrganization(
            "ipfs://metadata",
            address(baseToken),
            address(quoteToken),
            BASE_AMOUNT,
            QUOTE_AMOUNT,
            _createDefaultConfig()
        );
    }

    // ============ CreateICOOrganization Tests ============

    function test_CreateICOOrganization_Success() public {
        vm.prank(alice);
        uint256 orgId = orgManager.createICOOrganization(
            "ipfs://metadata",
            address(quoteToken),
            "Test Token",
            "TEST",
            _createDefaultConfig(),
            _createDefaultRaiseConfig()
        );

        assertEq(orgId, 1);
        assertEq(orgManager.orgCount(), 1);
    }

    function test_CreateICOOrganization_SetsState() public {
        vm.prank(alice);
        uint256 orgId = orgManager.createICOOrganization(
            "ipfs://metadata",
            address(quoteToken),
            "Test Token",
            "TEST",
            _createDefaultConfig(),
            _createDefaultRaiseConfig()
        );

        (OrganizationState memory state, ) = orgManager.getOrganization(orgId);

        assertTrue(state.orgType == OrganizationType.ICO);
        assertTrue(state.status == OrganizationStatus.Pending);
        assertEq(state.baseToken, address(0)); // Not set until raise finalizes
        assertEq(state.quoteToken, address(quoteToken));
        assertEq(state.owner, alice);
    }

    function testRevert_CreateICOOrganization_ZeroQuoteToken() public {
        vm.expectRevert(IOrganizationManager.ZeroAddress.selector);
        vm.prank(alice);
        orgManager.createICOOrganization(
            "ipfs://metadata",
            address(0),
            "Test Token",
            "TEST",
            _createDefaultConfig(),
            _createDefaultRaiseConfig()
        );
    }

    function testRevert_CreateICOOrganization_InvalidRaiseConfig() public {
        RaiseConfig memory badConfig = _createDefaultRaiseConfig();
        badConfig.softCap = 0;

        vm.expectRevert(IOrganizationManager.InvalidRaiseConfig.selector);
        vm.prank(alice);
        orgManager.createICOOrganization(
            "ipfs://metadata",
            address(quoteToken),
            "Test Token",
            "TEST",
            _createDefaultConfig(),
            badConfig
        );
    }

    // ============ UpdateStatus Tests ============

    function test_UpdateStatus_ApproveExternal() public {
        uint256 orgId = _createExternalOrg();

        vm.prank(admin);
        orgManager.updateStatus(orgId, OrganizationStatus.Approved);

        (OrganizationState memory state, ) = orgManager.getOrganization(orgId);
        assertTrue(state.status == OrganizationStatus.Approved);
    }

    function test_UpdateStatus_ActivateExternal() public {
        uint256 orgId = _createExternalOrg();

        vm.prank(admin);
        orgManager.updateStatus(orgId, OrganizationStatus.Approved);

        vm.prank(admin);
        orgManager.updateStatus(orgId, OrganizationStatus.Active);

        (OrganizationState memory state, ) = orgManager.getOrganization(orgId);
        assertTrue(state.status == OrganizationStatus.Active);
    }

    function test_UpdateStatus_RejectPending() public {
        uint256 orgId = _createExternalOrg();

        vm.prank(admin);
        orgManager.updateStatus(orgId, OrganizationStatus.Rejected);

        (OrganizationState memory state, ) = orgManager.getOrganization(orgId);
        assertTrue(state.status == OrganizationStatus.Rejected);
    }

    function test_UpdateStatus_EmitsEvent() public {
        uint256 orgId = _createExternalOrg();

        vm.expectEmit(true, false, false, true);
        emit IOrganizationManager.OrganizationStatusUpdated(
            orgId,
            OrganizationStatus.Approved
        );

        vm.prank(admin);
        orgManager.updateStatus(orgId, OrganizationStatus.Approved);
    }

    function testRevert_UpdateStatus_NotAdmin() public {
        uint256 orgId = _createExternalOrg();

        vm.expectRevert(IOrganizationManager.NotProtocolAdmin.selector);
        vm.prank(alice);
        orgManager.updateStatus(orgId, OrganizationStatus.Approved);
    }

    function testRevert_UpdateStatus_InvalidTransition() public {
        uint256 orgId = _createExternalOrg();

        vm.expectRevert(
            abi.encodeWithSelector(
                IOrganizationManager.InvalidOrgStatus.selector,
                OrganizationStatus.Pending,
                OrganizationStatus.Active
            )
        );
        vm.prank(admin);
        orgManager.updateStatus(orgId, OrganizationStatus.Active);
    }

    // ============ Role Management Tests ============

    function test_AddTeamMember_Success() public {
        uint256 orgId = _createExternalOrg();

        vm.prank(alice);
        orgManager.addTeamMember(orgId, bob);

        assertTrue(orgManager.isTeamMember(orgId, bob));
    }

    function test_AddTeamMember_EmitsEvent() public {
        uint256 orgId = _createExternalOrg();

        vm.expectEmit(true, true, false, true);
        emit IOrganizationManager.TeamMemberAdded(orgId, bob);

        vm.prank(alice);
        orgManager.addTeamMember(orgId, bob);
    }

    function testRevert_AddTeamMember_NotOwner() public {
        uint256 orgId = _createExternalOrg();

        vm.expectRevert(IOrganizationManager.NotOrgOwner.selector);
        vm.prank(bob);
        orgManager.addTeamMember(orgId, carol);
    }

    function testRevert_AddTeamMember_AlreadyExists() public {
        uint256 orgId = _createExternalOrg();

        vm.prank(alice);
        orgManager.addTeamMember(orgId, bob);

        vm.expectRevert(IOrganizationManager.MemberAlreadyExists.selector);
        vm.prank(alice);
        orgManager.addTeamMember(orgId, bob);
    }

    function test_RemoveTeamMember_Success() public {
        uint256 orgId = _createExternalOrg();

        vm.prank(alice);
        orgManager.addTeamMember(orgId, bob);

        vm.prank(alice);
        orgManager.removeTeamMember(orgId, bob);

        assertFalse(orgManager.isTeamMember(orgId, bob));
    }

    function test_RemoveTeamMember_EmitsEvent() public {
        uint256 orgId = _createExternalOrg();

        vm.prank(alice);
        orgManager.addTeamMember(orgId, bob);

        vm.expectEmit(true, true, false, true);
        emit IOrganizationManager.TeamMemberRemoved(orgId, bob);

        vm.prank(alice);
        orgManager.removeTeamMember(orgId, bob);
    }

    function testRevert_RemoveTeamMember_NotFound() public {
        uint256 orgId = _createExternalOrg();

        vm.expectRevert(IOrganizationManager.MemberNotFound.selector);
        vm.prank(alice);
        orgManager.removeTeamMember(orgId, bob);
    }

    function test_TransferOwnership_Success() public {
        uint256 orgId = _createExternalOrg();

        vm.prank(alice);
        orgManager.transferOwnership(orgId, bob);

        assertTrue(orgManager.isOwner(orgId, bob));
        assertFalse(orgManager.isOwner(orgId, alice));
    }

    function test_TransferOwnership_EmitsEvent() public {
        uint256 orgId = _createExternalOrg();

        vm.expectEmit(true, true, true, true);
        emit IOrganizationManager.OwnershipTransferred(orgId, alice, bob);

        vm.prank(alice);
        orgManager.transferOwnership(orgId, bob);
    }

    function testRevert_TransferOwnership_ToSelf() public {
        uint256 orgId = _createExternalOrg();

        vm.expectRevert(IOrganizationManager.CannotTransferToSelf.selector);
        vm.prank(alice);
        orgManager.transferOwnership(orgId, alice);
    }

    function testRevert_TransferOwnership_ToZero() public {
        uint256 orgId = _createExternalOrg();

        vm.expectRevert(IOrganizationManager.ZeroAddress.selector);
        vm.prank(alice);
        orgManager.transferOwnership(orgId, address(0));
    }

    // ============ Protocol Admin Tests ============

    function test_GrantProtocolAdmin_Success() public {
        vm.prank(admin);
        orgManager.grantProtocolAdmin(bob);

        assertTrue(orgManager.protocolAdmins(bob));
    }

    function test_GrantProtocolAdmin_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IOrganizationManager.ProtocolAdminGranted(bob);

        vm.prank(admin);
        orgManager.grantProtocolAdmin(bob);
    }

    function testRevert_GrantProtocolAdmin_NotAdmin() public {
        vm.expectRevert(IOrganizationManager.NotProtocolAdmin.selector);
        vm.prank(alice);
        orgManager.grantProtocolAdmin(bob);
    }

    function test_RevokeProtocolAdmin_Success() public {
        vm.prank(admin);
        orgManager.grantProtocolAdmin(bob);

        vm.prank(admin);
        orgManager.revokeProtocolAdmin(bob);

        assertFalse(orgManager.protocolAdmins(bob));
    }

    function testRevert_RevokeProtocolAdmin_Self() public {
        vm.expectRevert(IOrganizationManager.InvalidConfig.selector);
        vm.prank(admin);
        orgManager.revokeProtocolAdmin(admin);
    }

    function test_SetFeeRecipient_Success() public {
        vm.prank(admin);
        orgManager.setFeeRecipient(bob);

        assertEq(orgManager.protocolFeeRecipient(), bob);
    }

    function test_SetFeeRecipient_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IOrganizationManager.FeeRecipientUpdated(bob);

        vm.prank(admin);
        orgManager.setFeeRecipient(bob);
    }

    function test_SetTreasuryFeeShare_Success() public {
        vm.prank(admin);
        orgManager.setTreasuryFeeShare(1000);

        assertEq(orgManager.treasuryFeeShareBps(), 1000);
    }

    function testRevert_SetTreasuryFeeShare_ExceedsMax() public {
        vm.expectRevert(IOrganizationManager.FeeExceedsMax.selector);
        vm.prank(admin);
        orgManager.setTreasuryFeeShare(6000); // > 50%
    }

    function test_SetDefaultPoolFee_Success() public {
        vm.prank(admin);
        orgManager.setDefaultPoolFee(5000);

        assertEq(orgManager.defaultPoolFeeBps(), 5000);
    }

    // ============ Pause Tests ============

    function test_Pause_Success() public {
        vm.prank(admin);
        orgManager.pause();

        assertTrue(orgManager.paused());
    }

    function test_Pause_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IOrganizationManager.Paused(admin);

        vm.prank(admin);
        orgManager.pause();
    }

    function testRevert_Pause_AlreadyPaused() public {
        vm.prank(admin);
        orgManager.pause();

        vm.expectRevert(IOrganizationManager.ProtocolPaused.selector);
        vm.prank(admin);
        orgManager.pause();
    }

    function test_Unpause_Success() public {
        vm.prank(admin);
        orgManager.pause();

        vm.prank(admin);
        orgManager.unpause();

        assertFalse(orgManager.paused());
    }

    function testRevert_Unpause_NotPaused() public {
        vm.expectRevert(IOrganizationManager.ProtocolNotPaused.selector);
        vm.prank(admin);
        orgManager.unpause();
    }

    // ============ View Function Tests ============

    function test_GetOrganization_ReturnsCorrectData() public {
        uint256 orgId = _createExternalOrg();

        (
            OrganizationState memory state,
            OrganizationConfig memory config
        ) = orgManager.getOrganization(orgId);

        assertEq(state.baseToken, address(baseToken));
        assertEq(state.quoteToken, address(quoteToken));
        assertEq(config.stakingDuration, 48 hours);
    }

    function test_GetEffectiveStakeThreshold_Owner() public {
        uint256 orgId = _createExternalOrg();

        // Owner threshold: 5% (500 bps) of total supply
        // Total supply: 1_100_000e18 (alice has 1M - BASE_AMOUNT, bob has 100K)
        // Actually baseToken total supply = initial mints = 1.1M
        uint256 totalSupply = baseToken.totalSupply();
        uint256 expectedThreshold = (totalSupply * 500) / 10_000;

        uint256 threshold = orgManager.getEffectiveStakeThreshold(orgId, alice);
        assertEq(threshold, expectedThreshold);
    }

    function test_GetEffectiveStakeThreshold_TeamMember() public {
        uint256 orgId = _createExternalOrg();

        vm.prank(alice);
        orgManager.addTeamMember(orgId, bob);

        // Team threshold: 3% (300 bps) of total supply
        uint256 totalSupply = baseToken.totalSupply();
        uint256 expectedThreshold = (totalSupply * 300) / 10_000;

        uint256 threshold = orgManager.getEffectiveStakeThreshold(orgId, bob);
        assertEq(threshold, expectedThreshold);
    }

    function test_GetEffectiveStakeThreshold_NonMember() public {
        uint256 orgId = _createExternalOrg();

        // Non-member gets default threshold
        uint256 threshold = orgManager.getEffectiveStakeThreshold(orgId, carol);
        assertEq(threshold, 100e18);
    }

    function test_GetTeamMembers_ReturnsCorrectList() public {
        uint256 orgId = _createExternalOrg();

        vm.startPrank(alice);
        orgManager.addTeamMember(orgId, bob);
        orgManager.addTeamMember(orgId, carol);
        vm.stopPrank();

        address[] memory members = orgManager.getTeamMembers(orgId);
        assertEq(members.length, 2);
        assertEq(members[0], bob);
        assertEq(members[1], carol);
    }

    function test_OrgCount_ReturnsCorrect() public {
        assertEq(orgManager.orgCount(), 0);

        _createExternalOrg();
        assertEq(orgManager.orgCount(), 1);

        _createExternalOrg();
        assertEq(orgManager.orgCount(), 2);
    }
}
