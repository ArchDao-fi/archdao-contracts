// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

// Mocks
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ConditionalTokenFactory} from "../../src/tokens/ConditionalTokenFactory.sol";
import {ConditionalToken} from "../../src/tokens/ConditionalToken.sol";
import {IConditionalTokenFactory} from "../../src/interfaces/IConditionalTokenFactory.sol";
import {ConditionalTokenSet} from "../../src/types/ProposalTypes.sol";

// ============================================================================
// ConditionalTokenFactory Unit Tests
// ============================================================================
// Ticket: T-020
// Tests for SPECIFICATION.md §4.4
// ============================================================================

contract ConditionalTokenFactoryTest is Test {
    ConditionalTokenFactory public factory;

    MockERC20 public baseToken;
    MockERC20 public quoteToken;

    address public minter = makeAddr("minter");
    address public alice = makeAddr("alice");

    uint256 constant PROPOSAL_ID_1 = 1;
    uint256 constant PROPOSAL_ID_2 = 2;

    // ============ Setup ============

    function setUp() public {
        factory = new ConditionalTokenFactory();

        // Deploy mock tokens
        baseToken = new MockERC20("ArchDAO Token", "ARCH", 18);
        quoteToken = new MockERC20("USD Coin", "USDC", 6);
    }

    // ============ deployConditionalSet Tests ============

    function test_DeployConditionalSet_Success() public {
        ConditionalTokenSet memory tokens = factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            minter
        );

        // Verify all addresses are non-zero
        assertTrue(tokens.pToken != address(0));
        assertTrue(tokens.fToken != address(0));
        assertTrue(tokens.pQuote != address(0));
        assertTrue(tokens.fQuote != address(0));

        // Verify all addresses are different
        assertTrue(tokens.pToken != tokens.fToken);
        assertTrue(tokens.pToken != tokens.pQuote);
        assertTrue(tokens.pToken != tokens.fQuote);
        assertTrue(tokens.fToken != tokens.pQuote);
        assertTrue(tokens.fToken != tokens.fQuote);
        assertTrue(tokens.pQuote != tokens.fQuote);
    }

    function test_DeployConditionalSet_TokenProperties() public {
        ConditionalTokenSet memory tokens = factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            minter
        );

        bytes32 MINTER_ROLE = ConditionalToken(tokens.pToken).MINTER_ROLE();

        // Check pToken properties
        ConditionalToken pToken = ConditionalToken(tokens.pToken);
        assertTrue(pToken.hasRole(MINTER_ROLE, minter));
        assertEq(pToken.decimals(), 18); // Same as baseToken

        // Check fToken properties
        ConditionalToken fToken = ConditionalToken(tokens.fToken);
        assertTrue(fToken.hasRole(MINTER_ROLE, minter));
        assertEq(fToken.decimals(), 18);

        // Check pQuote properties
        ConditionalToken pQuote = ConditionalToken(tokens.pQuote);
        assertTrue(pQuote.hasRole(MINTER_ROLE, minter));
        assertEq(pQuote.decimals(), 6); // Same as quoteToken (USDC)

        // Check fQuote properties
        ConditionalToken fQuote = ConditionalToken(tokens.fQuote);
        assertTrue(fQuote.hasRole(MINTER_ROLE, minter));
        assertEq(fQuote.decimals(), 6);

        // Verify factory tracks proposal mapping
        assertEq(factory.getProposalForToken(tokens.pToken), PROPOSAL_ID_1);
        assertEq(factory.getProposalForToken(tokens.fToken), PROPOSAL_ID_1);
        assertEq(factory.getProposalForToken(tokens.pQuote), PROPOSAL_ID_1);
        assertEq(factory.getProposalForToken(tokens.fQuote), PROPOSAL_ID_1);
    }

    function test_DeployConditionalSet_TokenNaming() public {
        ConditionalTokenSet memory tokens = factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            minter
        );

        // Check names
        assertEq(ConditionalToken(tokens.pToken).name(), "pToken-ARCH-1");
        assertEq(ConditionalToken(tokens.fToken).name(), "fToken-ARCH-1");
        assertEq(ConditionalToken(tokens.pQuote).name(), "pQuote-USDC-1");
        assertEq(ConditionalToken(tokens.fQuote).name(), "fQuote-USDC-1");

        // Check symbols
        assertEq(ConditionalToken(tokens.pToken).symbol(), "pARCH-1");
        assertEq(ConditionalToken(tokens.fToken).symbol(), "fARCH-1");
        assertEq(ConditionalToken(tokens.pQuote).symbol(), "pUSDC-1");
        assertEq(ConditionalToken(tokens.fQuote).symbol(), "fUSDC-1");
    }

    function test_DeployConditionalSet_EmitsEvent() public {
        // Record logs to verify event was emitted
        vm.recordLogs();

        factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            minter
        );

        // Check that at least one log was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            // Check for ConditionalSetDeployed event signature
            if (
                logs[i].topics[0] ==
                keccak256(
                    "ConditionalSetDeployed(uint256,address,address,address,address)"
                )
            ) {
                // Verify the indexed proposalId
                assertEq(uint256(logs[i].topics[1]), PROPOSAL_ID_1);
                eventFound = true;
                break;
            }
        }

        assertTrue(eventFound, "ConditionalSetDeployed event not found");
    }

    function test_DeployConditionalSet_StoresMapping() public {
        ConditionalTokenSet memory tokens = factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            minter
        );

        // Verify tokenToProposal mapping
        assertEq(factory.getProposalForToken(tokens.pToken), PROPOSAL_ID_1);
        assertEq(factory.getProposalForToken(tokens.fToken), PROPOSAL_ID_1);
        assertEq(factory.getProposalForToken(tokens.pQuote), PROPOSAL_ID_1);
        assertEq(factory.getProposalForToken(tokens.fQuote), PROPOSAL_ID_1);
    }

    function test_DeployConditionalSet_MultipleProposals() public {
        ConditionalTokenSet memory tokens1 = factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            minter
        );

        ConditionalTokenSet memory tokens2 = factory.deployConditionalSet(
            PROPOSAL_ID_2,
            address(baseToken),
            address(quoteToken),
            minter
        );

        // Verify different tokens for different proposals
        assertTrue(tokens1.pToken != tokens2.pToken);
        assertTrue(tokens1.fToken != tokens2.fToken);
        assertTrue(tokens1.pQuote != tokens2.pQuote);
        assertTrue(tokens1.fQuote != tokens2.fQuote);

        // Verify correct proposal IDs
        assertEq(factory.getProposalForToken(tokens1.pToken), PROPOSAL_ID_1);
        assertEq(factory.getProposalForToken(tokens2.pToken), PROPOSAL_ID_2);
    }

    function testRevert_DeployConditionalSet_ZeroBaseToken() public {
        vm.expectRevert(IConditionalTokenFactory.ZeroAddress.selector);
        factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(0),
            address(quoteToken),
            minter
        );
    }

    function testRevert_DeployConditionalSet_ZeroQuoteToken() public {
        vm.expectRevert(IConditionalTokenFactory.ZeroAddress.selector);
        factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(0),
            minter
        );
    }

    function testRevert_DeployConditionalSet_ZeroMinter() public {
        vm.expectRevert(IConditionalTokenFactory.ZeroAddress.selector);
        factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            address(0)
        );
    }

    function testRevert_DeployConditionalSet_AlreadyExists() public {
        // First deployment succeeds
        factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            minter
        );

        // Second deployment for same proposal fails
        vm.expectRevert(
            abi.encodeWithSelector(
                IConditionalTokenFactory.ConditionalSetExists.selector,
                PROPOSAL_ID_1
            )
        );
        factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            minter
        );
    }

    // ============ getConditionalTokens Tests ============

    function test_GetConditionalTokens_Success() public {
        ConditionalTokenSet memory deployed = factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            minter
        );

        ConditionalTokenSet memory retrieved = factory.getConditionalTokens(
            PROPOSAL_ID_1
        );

        assertEq(retrieved.pToken, deployed.pToken);
        assertEq(retrieved.fToken, deployed.fToken);
        assertEq(retrieved.pQuote, deployed.pQuote);
        assertEq(retrieved.fQuote, deployed.fQuote);
    }

    function testRevert_GetConditionalTokens_NotFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IConditionalTokenFactory.ConditionalSetNotFound.selector,
                PROPOSAL_ID_1
            )
        );
        factory.getConditionalTokens(PROPOSAL_ID_1);
    }

    // ============ getProposalForToken Tests ============

    function test_GetProposalForToken_UnknownToken() public view {
        // Unknown tokens return 0 (no revert)
        assertEq(factory.getProposalForToken(address(0xdead)), 0);
    }

    // ============ Fuzz Tests ============

    function testFuzz_DeployConditionalSet_ProposalId(
        uint256 proposalId
    ) public {
        ConditionalTokenSet memory tokens = factory.deployConditionalSet(
            proposalId,
            address(baseToken),
            address(quoteToken),
            minter
        );

        // Factory tracks the proposal mapping (token doesn't store it anymore)
        assertEq(factory.getProposalForToken(tokens.pToken), proposalId);
        assertEq(factory.getProposalForToken(tokens.fToken), proposalId);
        assertEq(factory.getProposalForToken(tokens.pQuote), proposalId);
        assertEq(factory.getProposalForToken(tokens.fQuote), proposalId);
    }

    function testFuzz_MultipleProposals(uint8 count) public {
        count = uint8(bound(count, 1, 50)); // Limit to prevent gas issues

        for (uint256 i = 1; i <= count; i++) {
            ConditionalTokenSet memory tokens = factory.deployConditionalSet(
                i,
                address(baseToken),
                address(quoteToken),
                minter
            );

            assertEq(factory.getProposalForToken(tokens.pToken), i);
        }
    }

    // ============ Integration Tests ============

    function test_MintedTokensAreUsable() public {
        ConditionalTokenSet memory tokens = factory.deployConditionalSet(
            PROPOSAL_ID_1,
            address(baseToken),
            address(quoteToken),
            minter
        );

        ConditionalToken pToken = ConditionalToken(tokens.pToken);

        // Minter can mint tokens
        vm.prank(minter);
        pToken.mint(alice, 1000e18);

        assertEq(pToken.balanceOf(alice), 1000e18);

        // Alice can transfer
        vm.prank(alice);
        pToken.transfer(minter, 500e18);

        assertEq(pToken.balanceOf(alice), 500e18);
        assertEq(pToken.balanceOf(minter), 500e18);
    }
}
