// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Raise} from "../../src/raise/Raise.sol";
import {IRaise} from "../../src/interfaces/IRaise.sol";
import {GovernanceToken} from "../../src/tokens/GovernanceToken.sol";
import {RaiseConfig, RaiseStatus} from "../../src/types/RaiseTypes.sol";
import {OrganizationConfig} from "../../src/types/OrganizationTypes.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// ============================================================================
// Mock OrganizationManager for Raise Tests
// ============================================================================

contract MockOrgManagerForRaise {
    mapping(address => bool) public protocolAdmins;
    mapping(uint256 => address) public treasuries;
    mapping(uint256 => address) public governanceTokens;

    function setProtocolAdmin(address admin, bool isAdmin) external {
        protocolAdmins[admin] = isAdmin;
    }

    function setTreasury(uint256 orgId, address treasury) external {
        treasuries[orgId] = treasury;
    }

    function setGovernanceToken(uint256 orgId, address token) external {
        governanceTokens[orgId] = token;
    }
}

// ============================================================================
// Raise Unit Tests
// ============================================================================
// Ticket: T-038
// Tests for SPECIFICATION.md §4.10
// ============================================================================

contract RaiseTest is Test {
    Raise public raise;
    MockOrgManagerForRaise public mockManager;
    MockERC20 public quoteToken;
    GovernanceToken public govToken;

    address public protocolAdmin = makeAddr("protocolAdmin");
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 constant ORG_ID = 1;
    uint256 constant SOFT_CAP = 100_000e18;
    uint256 constant HARD_CAP = 500_000e18;
    uint256 constant START_DATE = 1000;
    uint256 constant END_DATE = 2000;

    OrganizationConfig defaultConfig;
    RaiseConfig raiseConfig;

    // ============ Setup ============

    function setUp() public {
        // Deploy mock manager
        mockManager = new MockOrgManagerForRaise();
        mockManager.setProtocolAdmin(protocolAdmin, true);
        mockManager.setTreasury(ORG_ID, treasury);

        // Deploy quote token
        quoteToken = new MockERC20("Quote Token", "QUOTE", 18);

        // Deploy governance token with raise as minter
        govToken = new GovernanceToken("Gov Token", "GOV", address(this));

        mockManager.setGovernanceToken(ORG_ID, address(govToken));

        // Create default config
        defaultConfig = OrganizationConfig({
            minTwapSpreadBps: 300,
            teamPassThresholdBps: -300,
            nonTeamPassThresholdBps: 300,
            defaultStakingThreshold: 1000e18,
            teamStakingThresholdBps: 300,
            ownerStakingThresholdBps: 500,
            stakingDuration: 48 hours,
            tradingDuration: 4 days,
            twapRecordingDelay: 24 hours,
            minCancellationDelay: 24 hours,
            observationMaxRateBpsPerSecond: 8,
            lpAllocationPerProposalBps: 5000
        });

        // Create raise config
        raiseConfig = RaiseConfig({
            softCap: SOFT_CAP,
            hardCap: HARD_CAP,
            startDate: START_DATE,
            endDate: END_DATE,
            quoteToken: address(quoteToken),
            agreedConfig: defaultConfig
        });

        // Deploy and initialize raise
        raise = new Raise();
        raise.initialize(ORG_ID, address(mockManager), raiseConfig);

        // Mint tokens to users
        quoteToken.mint(alice, 1_000_000e18);
        quoteToken.mint(bob, 1_000_000e18);
        quoteToken.mint(charlie, 1_000_000e18);

        // Approve raise contract
        vm.prank(alice);
        quoteToken.approve(address(raise), type(uint256).max);
        vm.prank(bob);
        quoteToken.approve(address(raise), type(uint256).max);
        vm.prank(charlie);
        quoteToken.approve(address(raise), type(uint256).max);
    }

    // ============ Helper Functions ============

    function _startRaise() internal {
        vm.prank(address(mockManager));
        raise.start();
        vm.warp(START_DATE + 1);
    }

    function _contribute(address user, uint256 amount) internal {
        vm.prank(user);
        raise.contribute(amount);
    }

    function _setupForFinalization(uint256 totalAmount) internal {
        _startRaise();
        _contribute(alice, totalAmount);
        vm.warp(END_DATE + 1);

        // Mint governance tokens to raise for distribution
        govToken.mint(address(raise), 1_000_000e18);
    }

    // ============ Initialization Tests ============

    function test_Initialize_SetsState() public view {
        assertEq(raise.organizationId(), ORG_ID);
        assertEq(address(raise.manager()), address(mockManager));
        assertEq(raise.softCap(), SOFT_CAP);
        assertEq(raise.hardCap(), HARD_CAP);
        assertEq(raise.startDate(), START_DATE);
        assertEq(raise.endDate(), END_DATE);
        assertEq(raise.quoteToken(), address(quoteToken));
        assertEq(uint256(raise.status()), uint256(RaiseStatus.Pending));
    }

    function test_Initialize_StoresAgreedConfig() public view {
        OrganizationConfig memory config = raise.agreedConfig();
        assertEq(config.minTwapSpreadBps, defaultConfig.minTwapSpreadBps);
        assertEq(config.stakingDuration, defaultConfig.stakingDuration);
    }

    function testRevert_Initialize_AlreadyInitialized() public {
        vm.expectRevert(IRaise.AlreadyInitialized.selector);
        raise.initialize(ORG_ID, address(mockManager), raiseConfig);
    }

    function testRevert_Initialize_ZeroManager() public {
        Raise newRaise = new Raise();
        vm.expectRevert(IRaise.ZeroAddress.selector);
        newRaise.initialize(ORG_ID, address(0), raiseConfig);
    }

    function testRevert_Initialize_ZeroQuoteToken() public {
        Raise newRaise = new Raise();
        RaiseConfig memory badConfig = raiseConfig;
        badConfig.quoteToken = address(0);
        vm.expectRevert(IRaise.ZeroAddress.selector);
        newRaise.initialize(ORG_ID, address(mockManager), badConfig);
    }

    function testRevert_Initialize_ZeroSoftCap() public {
        Raise newRaise = new Raise();
        RaiseConfig memory badConfig = raiseConfig;
        badConfig.softCap = 0;
        vm.expectRevert(IRaise.InvalidConfig.selector);
        newRaise.initialize(ORG_ID, address(mockManager), badConfig);
    }

    function testRevert_Initialize_HardCapBelowSoftCap() public {
        Raise newRaise = new Raise();
        RaiseConfig memory badConfig = raiseConfig;
        badConfig.hardCap = badConfig.softCap - 1;
        vm.expectRevert(IRaise.InvalidConfig.selector);
        newRaise.initialize(ORG_ID, address(mockManager), badConfig);
    }

    function testRevert_Initialize_StartDateAfterEndDate() public {
        Raise newRaise = new Raise();
        RaiseConfig memory badConfig = raiseConfig;
        badConfig.startDate = END_DATE;
        badConfig.endDate = START_DATE;
        vm.expectRevert(IRaise.InvalidConfig.selector);
        newRaise.initialize(ORG_ID, address(mockManager), badConfig);
    }

    // ============ Start Tests ============

    function test_Start_Success() public {
        vm.prank(address(mockManager));
        raise.start();
        assertEq(uint256(raise.status()), uint256(RaiseStatus.Active));
    }

    function testRevert_Start_NotManager() public {
        vm.prank(alice);
        vm.expectRevert(IRaise.NotAuthorized.selector);
        raise.start();
    }

    function testRevert_Start_NotPending() public {
        vm.prank(address(mockManager));
        raise.start();

        vm.prank(address(mockManager));
        vm.expectRevert(IRaise.RaiseNotActive.selector);
        raise.start();
    }

    // ============ Contribute Tests ============

    function test_Contribute_Success() public {
        _startRaise();

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IRaise.Contributed(alice, 50_000e18);
        raise.contribute(50_000e18);

        assertEq(raise.contributions(alice), 50_000e18);
        assertEq(raise.totalContributed(), 50_000e18);
        assertEq(raise.getContributorCount(), 1);
    }

    function test_Contribute_MultipleContributors() public {
        _startRaise();

        _contribute(alice, 50_000e18);
        _contribute(bob, 30_000e18);
        _contribute(charlie, 20_000e18);

        assertEq(raise.contributions(alice), 50_000e18);
        assertEq(raise.contributions(bob), 30_000e18);
        assertEq(raise.contributions(charlie), 20_000e18);
        assertEq(raise.totalContributed(), 100_000e18);
        assertEq(raise.getContributorCount(), 3);
    }

    function test_Contribute_SameUserMultipleTimes() public {
        _startRaise();

        _contribute(alice, 30_000e18);
        _contribute(alice, 20_000e18);

        assertEq(raise.contributions(alice), 50_000e18);
        assertEq(raise.totalContributed(), 50_000e18);
        assertEq(raise.getContributorCount(), 1);
    }

    function test_Contribute_UpToHardCap() public {
        _startRaise();

        _contribute(alice, HARD_CAP);

        assertEq(raise.totalContributed(), HARD_CAP);
    }

    function testRevert_Contribute_NotActive() public {
        vm.prank(alice);
        vm.expectRevert(IRaise.RaiseNotActive.selector);
        raise.contribute(50_000e18);
    }

    function testRevert_Contribute_BeforeStartDate() public {
        vm.prank(address(mockManager));
        raise.start();

        vm.warp(START_DATE - 1);
        vm.prank(alice);
        vm.expectRevert(IRaise.RaiseNotStarted.selector);
        raise.contribute(50_000e18);
    }

    function testRevert_Contribute_AfterEndDate() public {
        _startRaise();
        vm.warp(END_DATE + 1);

        vm.prank(alice);
        vm.expectRevert(IRaise.RaiseEnded.selector);
        raise.contribute(50_000e18);
    }

    function testRevert_Contribute_ZeroAmount() public {
        _startRaise();

        vm.prank(alice);
        vm.expectRevert(IRaise.ZeroContribution.selector);
        raise.contribute(0);
    }

    function testRevert_Contribute_ExceedsHardCap() public {
        _startRaise();

        _contribute(alice, HARD_CAP);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IRaise.ExceedsHardCap.selector, 1e18, 0)
        );
        raise.contribute(1e18);
    }

    // ============ Finalize Tests ============

    function test_Finalize_Success() public {
        _setupForFinalization(SOFT_CAP);

        vm.prank(protocolAdmin);
        vm.expectEmit(false, false, false, true);
        emit IRaise.RaiseFinalized(SOFT_CAP, 1_000_000e18);
        raise.finalize(SOFT_CAP);

        assertEq(uint256(raise.status()), uint256(RaiseStatus.Completed));
        assertEq(raise.acceptedAmount(), SOFT_CAP);
        assertEq(raise.totalTokensForDistribution(), 1_000_000e18);
    }

    function test_Finalize_TransfersToTreasury() public {
        _setupForFinalization(SOFT_CAP);

        uint256 treasuryBalanceBefore = quoteToken.balanceOf(treasury);

        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        assertEq(
            quoteToken.balanceOf(treasury),
            treasuryBalanceBefore + SOFT_CAP
        );
    }

    function test_Finalize_AcceptedLessThanTotal() public {
        _startRaise();
        _contribute(alice, 200_000e18);
        vm.warp(END_DATE + 1);
        govToken.mint(address(raise), 1_000_000e18);

        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        assertEq(raise.acceptedAmount(), SOFT_CAP);
        assertEq(raise.totalContributed(), 200_000e18);
    }

    function testRevert_Finalize_NotProtocolAdmin() public {
        _setupForFinalization(SOFT_CAP);

        vm.prank(alice);
        vm.expectRevert(IRaise.NotAuthorized.selector);
        raise.finalize(SOFT_CAP);
    }

    function testRevert_Finalize_NotEnded() public {
        _startRaise();
        _contribute(alice, SOFT_CAP);

        vm.prank(protocolAdmin);
        vm.expectRevert(IRaise.RaiseNotEnded.selector);
        raise.finalize(SOFT_CAP);
    }

    function testRevert_Finalize_BelowSoftCap() public {
        _setupForFinalization(SOFT_CAP);

        vm.prank(protocolAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRaise.BelowSoftCap.selector,
                SOFT_CAP - 1,
                SOFT_CAP
            )
        );
        raise.finalize(SOFT_CAP - 1);
    }

    function testRevert_Finalize_ExceedsContributed() public {
        _setupForFinalization(SOFT_CAP);

        vm.prank(protocolAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRaise.AcceptedExceedsContributed.selector,
                SOFT_CAP + 1,
                SOFT_CAP
            )
        );
        raise.finalize(SOFT_CAP + 1);
    }

    // ============ Fail Tests ============

    function test_Fail_Success() public {
        _startRaise();

        vm.prank(protocolAdmin);
        vm.expectEmit(false, false, false, false);
        emit IRaise.RaiseFailed();
        raise.fail();

        assertEq(uint256(raise.status()), uint256(RaiseStatus.Failed));
    }

    function testRevert_Fail_NotProtocolAdmin() public {
        _startRaise();

        vm.prank(alice);
        vm.expectRevert(IRaise.NotAuthorized.selector);
        raise.fail();
    }

    function testRevert_Fail_AlreadyCompleted() public {
        _setupForFinalization(SOFT_CAP);
        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        vm.prank(protocolAdmin);
        vm.expectRevert(IRaise.RaiseNotActive.selector);
        raise.fail();
    }

    // ============ ClaimTokens Tests ============

    function test_ClaimTokens_Success() public {
        _setupForFinalization(SOFT_CAP);
        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IRaise.TokensClaimed(alice, 1_000_000e18);
        raise.claimTokens();

        assertEq(govToken.balanceOf(alice), 1_000_000e18);
        assertTrue(raise.hasClaimed(alice));
    }

    function test_ClaimTokens_MultipleContributors() public {
        _startRaise();
        _contribute(alice, 50_000e18);
        _contribute(bob, 50_000e18);
        vm.warp(END_DATE + 1);
        govToken.mint(address(raise), 1_000_000e18);

        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        vm.prank(alice);
        raise.claimTokens();
        vm.prank(bob);
        raise.claimTokens();

        assertEq(govToken.balanceOf(alice), 500_000e18);
        assertEq(govToken.balanceOf(bob), 500_000e18);
    }

    function test_ClaimTokens_Oversubscribed() public {
        _startRaise();
        _contribute(alice, 200_000e18); // 200k contributed
        vm.warp(END_DATE + 1);
        govToken.mint(address(raise), 1_000_000e18);

        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP); // Only accept 100k

        // Alice should get 50% of tokens (100k/200k)
        uint256 expectedTokens = (100_000e18 * 1_000_000e18) / 100_000e18;

        vm.prank(alice);
        raise.claimTokens();

        assertEq(govToken.balanceOf(alice), expectedTokens);
    }

    function testRevert_ClaimTokens_NotCompleted() public {
        _startRaise();
        _contribute(alice, SOFT_CAP);
        vm.warp(END_DATE + 1);

        vm.prank(alice);
        vm.expectRevert(IRaise.NotRefundable.selector);
        raise.claimTokens();
    }

    function testRevert_ClaimTokens_AlreadyClaimed() public {
        _setupForFinalization(SOFT_CAP);
        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        vm.prank(alice);
        raise.claimTokens();

        vm.prank(alice);
        vm.expectRevert(IRaise.AlreadyClaimed.selector);
        raise.claimTokens();
    }

    function testRevert_ClaimTokens_NoContribution() public {
        _setupForFinalization(SOFT_CAP);
        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        vm.prank(bob); // Bob didn't contribute
        vm.expectRevert(IRaise.NoContribution.selector);
        raise.claimTokens();
    }

    // ============ Refund Tests ============

    function test_Refund_FailedRaise() public {
        _startRaise();
        _contribute(alice, 50_000e18);

        vm.prank(protocolAdmin);
        raise.fail();

        uint256 aliceBalanceBefore = quoteToken.balanceOf(alice);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IRaise.Refunded(alice, 50_000e18);
        raise.refund();

        assertEq(quoteToken.balanceOf(alice), aliceBalanceBefore + 50_000e18);
        assertTrue(raise.hasRefunded(alice));
    }

    function test_Refund_Oversubscribed() public {
        _startRaise();
        _contribute(alice, 200_000e18); // 200k contributed
        vm.warp(END_DATE + 1);
        govToken.mint(address(raise), 1_000_000e18);

        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP); // Only accept 100k

        // Alice should get 100k refund (200k - 100k)
        uint256 aliceBalanceBefore = quoteToken.balanceOf(alice);

        vm.prank(alice);
        raise.refund();

        assertEq(quoteToken.balanceOf(alice), aliceBalanceBefore + 100_000e18);
    }

    function test_Refund_MultipleOversubscribed() public {
        _startRaise();
        _contribute(alice, 150_000e18);
        _contribute(bob, 150_000e18);
        vm.warp(END_DATE + 1);
        govToken.mint(address(raise), 1_000_000e18);

        // Total: 300k, accept 100k
        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        // Each should get 2/3 refund
        uint256 aliceExpectedRefund = 150_000e18 -
            ((150_000e18 * SOFT_CAP) / 300_000e18);
        uint256 bobExpectedRefund = 150_000e18 -
            ((150_000e18 * SOFT_CAP) / 300_000e18);

        uint256 aliceBalanceBefore = quoteToken.balanceOf(alice);
        uint256 bobBalanceBefore = quoteToken.balanceOf(bob);

        vm.prank(alice);
        raise.refund();
        vm.prank(bob);
        raise.refund();

        assertEq(
            quoteToken.balanceOf(alice),
            aliceBalanceBefore + aliceExpectedRefund
        );
        assertEq(
            quoteToken.balanceOf(bob),
            bobBalanceBefore + bobExpectedRefund
        );
    }

    function testRevert_Refund_NothingToRefund() public {
        _setupForFinalization(SOFT_CAP);
        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        // Alice contributed exactly the accepted amount, no refund due
        vm.prank(alice);
        vm.expectRevert(IRaise.NothingToRefund.selector);
        raise.refund();
    }

    function testRevert_Refund_AlreadyRefunded() public {
        _startRaise();
        _contribute(alice, 50_000e18);

        vm.prank(protocolAdmin);
        raise.fail();

        vm.prank(alice);
        raise.refund();

        vm.prank(alice);
        vm.expectRevert(IRaise.NothingToRefund.selector);
        raise.refund();
    }

    function testRevert_Refund_NoContribution() public {
        _startRaise();
        _contribute(alice, 50_000e18);

        vm.prank(protocolAdmin);
        raise.fail();

        vm.prank(bob); // Bob didn't contribute
        vm.expectRevert(IRaise.NothingToRefund.selector);
        raise.refund();
    }

    // ============ View Function Tests ============

    function test_GetClaimableAmount_BeforeFinalization() public {
        _startRaise();
        _contribute(alice, SOFT_CAP);

        assertEq(raise.getClaimableAmount(alice), 0);
    }

    function test_GetClaimableAmount_AfterFinalization() public {
        _setupForFinalization(SOFT_CAP);
        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        assertEq(raise.getClaimableAmount(alice), 1_000_000e18);
    }

    function test_GetClaimableAmount_AfterClaimed() public {
        _setupForFinalization(SOFT_CAP);
        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        vm.prank(alice);
        raise.claimTokens();

        assertEq(raise.getClaimableAmount(alice), 0);
    }

    function test_GetRefundableAmount_FailedRaise() public {
        _startRaise();
        _contribute(alice, 50_000e18);

        vm.prank(protocolAdmin);
        raise.fail();

        assertEq(raise.getRefundableAmount(alice), 50_000e18);
    }

    function test_GetRefundableAmount_Oversubscribed() public {
        _startRaise();
        _contribute(alice, 200_000e18);
        vm.warp(END_DATE + 1);
        govToken.mint(address(raise), 1_000_000e18);

        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        assertEq(raise.getRefundableAmount(alice), 100_000e18);
    }

    function test_GetRefundableAmount_ExactMatch() public {
        _setupForFinalization(SOFT_CAP);
        vm.prank(protocolAdmin);
        raise.finalize(SOFT_CAP);

        assertEq(raise.getRefundableAmount(alice), 0);
    }

    function test_Contributors_Array() public {
        _startRaise();
        _contribute(alice, 10_000e18);
        _contribute(bob, 10_000e18);
        _contribute(charlie, 10_000e18);

        assertEq(raise.contributors(0), alice);
        assertEq(raise.contributors(1), bob);
        assertEq(raise.contributors(2), charlie);
    }

    // ============ SetGovernanceToken Tests ============

    function test_SetGovernanceToken_Success() public {
        GovernanceToken newToken = new GovernanceToken(
            "New",
            "NEW",
            address(this)
        );

        vm.prank(address(mockManager));
        raise.setGovernanceToken(address(newToken));

        assertEq(address(raise.governanceToken()), address(newToken));
    }

    function testRevert_SetGovernanceToken_NotManager() public {
        vm.prank(alice);
        vm.expectRevert(IRaise.NotAuthorized.selector);
        raise.setGovernanceToken(address(govToken));
    }

    function testRevert_SetGovernanceToken_ZeroAddress() public {
        vm.prank(address(mockManager));
        vm.expectRevert(IRaise.ZeroAddress.selector);
        raise.setGovernanceToken(address(0));
    }
}
