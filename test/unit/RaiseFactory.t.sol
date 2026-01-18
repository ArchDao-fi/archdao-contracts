// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RaiseFactory} from "../../src/raise/RaiseFactory.sol";
import {Raise} from "../../src/raise/Raise.sol";
import {IRaiseFactory} from "../../src/interfaces/IRaiseFactory.sol";
import {IRaise} from "../../src/interfaces/IRaise.sol";
import {RaiseConfig, RaiseStatus} from "../../src/types/RaiseTypes.sol";
import {OrganizationConfig} from "../../src/types/OrganizationTypes.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// ============================================================================
// Mock OrganizationManager for RaiseFactory Tests
// ============================================================================

contract MockOrgManagerForRaiseFactory {
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
// RaiseFactory Unit Tests
// ============================================================================
// Ticket: T-039
// Tests for SPECIFICATION.md §4.9
// ============================================================================

contract RaiseFactoryTest is Test {
    RaiseFactory public factory;
    MockOrgManagerForRaiseFactory public mockManager;
    MockERC20 public quoteToken;

    address public alice = makeAddr("alice");

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
        mockManager = new MockOrgManagerForRaiseFactory();

        // Deploy quote token
        quoteToken = new MockERC20("Quote Token", "QUOTE", 18);

        // Deploy factory
        factory = new RaiseFactory(address(mockManager));

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
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsManager() public view {
        assertEq(address(factory.manager()), address(mockManager));
    }

    function testRevert_Constructor_ZeroManager() public {
        vm.expectRevert(IRaiseFactory.InvalidRaiseConfig.selector);
        new RaiseFactory(address(0));
    }

    // ============ CreateRaise Tests ============

    function test_CreateRaise_Success() public {
        vm.prank(address(mockManager));
        vm.expectEmit(true, false, false, false);
        emit IRaiseFactory.RaiseCreated(ORG_ID, address(0)); // Address unknown before deployment
        address raiseAddr = factory.createRaise(ORG_ID, raiseConfig);

        assertTrue(raiseAddr != address(0));
        assertEq(factory.getRaise(ORG_ID), raiseAddr);
    }

    function test_CreateRaise_InitializesCorrectly() public {
        vm.prank(address(mockManager));
        address raiseAddr = factory.createRaise(ORG_ID, raiseConfig);

        Raise raise = Raise(raiseAddr);
        assertEq(raise.organizationId(), ORG_ID);
        assertEq(address(raise.manager()), address(mockManager));
        assertEq(raise.softCap(), SOFT_CAP);
        assertEq(raise.hardCap(), HARD_CAP);
        assertEq(raise.startDate(), START_DATE);
        assertEq(raise.endDate(), END_DATE);
        assertEq(raise.quoteToken(), address(quoteToken));
        assertEq(uint256(raise.status()), uint256(RaiseStatus.Pending));
    }

    function test_CreateRaise_MultipleOrganizations() public {
        vm.startPrank(address(mockManager));

        address raise1 = factory.createRaise(1, raiseConfig);
        address raise2 = factory.createRaise(2, raiseConfig);
        address raise3 = factory.createRaise(3, raiseConfig);

        vm.stopPrank();

        assertTrue(raise1 != raise2);
        assertTrue(raise2 != raise3);
        assertEq(factory.getRaise(1), raise1);
        assertEq(factory.getRaise(2), raise2);
        assertEq(factory.getRaise(3), raise3);
    }

    function testRevert_CreateRaise_NotOrganizationManager() public {
        vm.prank(alice);
        vm.expectRevert(IRaiseFactory.NotOrganizationManager.selector);
        factory.createRaise(ORG_ID, raiseConfig);
    }

    function testRevert_CreateRaise_RaiseAlreadyExists() public {
        vm.startPrank(address(mockManager));
        factory.createRaise(ORG_ID, raiseConfig);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRaiseFactory.RaiseAlreadyExists.selector,
                ORG_ID
            )
        );
        factory.createRaise(ORG_ID, raiseConfig);
        vm.stopPrank();
    }

    function testRevert_CreateRaise_ZeroSoftCap() public {
        RaiseConfig memory badConfig = raiseConfig;
        badConfig.softCap = 0;

        vm.prank(address(mockManager));
        vm.expectRevert(IRaiseFactory.InvalidRaiseConfig.selector);
        factory.createRaise(ORG_ID, badConfig);
    }

    function testRevert_CreateRaise_HardCapBelowSoftCap() public {
        RaiseConfig memory badConfig = raiseConfig;
        badConfig.hardCap = SOFT_CAP - 1;

        vm.prank(address(mockManager));
        vm.expectRevert(IRaiseFactory.InvalidRaiseConfig.selector);
        factory.createRaise(ORG_ID, badConfig);
    }

    function testRevert_CreateRaise_StartDateAfterEndDate() public {
        RaiseConfig memory badConfig = raiseConfig;
        badConfig.startDate = END_DATE;
        badConfig.endDate = START_DATE;

        vm.prank(address(mockManager));
        vm.expectRevert(IRaiseFactory.InvalidRaiseConfig.selector);
        factory.createRaise(ORG_ID, badConfig);
    }

    function testRevert_CreateRaise_ZeroQuoteToken() public {
        RaiseConfig memory badConfig = raiseConfig;
        badConfig.quoteToken = address(0);

        vm.prank(address(mockManager));
        vm.expectRevert(IRaiseFactory.InvalidRaiseConfig.selector);
        factory.createRaise(ORG_ID, badConfig);
    }

    // ============ GetRaise Tests ============

    function test_GetRaise_ReturnsZeroForNonexistent() public view {
        assertEq(factory.getRaise(999), address(0));
    }

    function test_GetRaise_ReturnsCorrectAddress() public {
        vm.prank(address(mockManager));
        address raiseAddr = factory.createRaise(ORG_ID, raiseConfig);

        assertEq(factory.getRaise(ORG_ID), raiseAddr);
    }
}
