# ArchDAO Smart Contracts - Copilot Instructions

> **Implementation Guide for Futarchy Governance Protocol**  
> Solidity ^0.8.26 | Foundry | Uniswap V4

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Code Style & Syntax Rules](#2-code-style--syntax-rules)
3. [Architecture Reference](#3-architecture-reference)
4. [Contract Implementation Order](#4-contract-implementation-order)
5. [Testing Standards](#5-testing-standards)
6. [Uniswap V4 Integration Patterns](#6-uniswap-v4-integration-patterns)
7. [Security Checklist](#7-security-checklist)
8. [File Structure](#8-file-structure)
9. [Commands Reference](#9-commands-reference)

---

## 1. Project Overview

ArchDAO implements **futarchy governance** — proposals pass/fail based on prediction market prices rather than token-weighted voting. The protocol uses Uniswap V4 for decision markets with a custom TWAP hook.

### Source of Truth

All implementation details are defined in [SPECIFICATION.md](../SPECIFICATION.md). This includes:

- Complete contract specifications with function signatures
- Data structures (enums, structs)
- Lifecycle flows with sequence diagrams
- Access control matrix
- Configuration parameters
- Error codes

**ALWAYS reference SPECIFICATION.md before implementing any contract.**

### Core Principle

```
TWAP(pToken/pQuote) > TWAP(fToken/fQuote) × (1 + threshold) → Proposal Passes
```

---

## 2. Code Style & Syntax Rules

### 2.1 File Header

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
```

### 2.2 Import Order

Imports MUST follow this order, with blank lines between groups:

```solidity
// 1. OpenZeppelin base contracts (if using OZ hooks base)
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

// 2. Uniswap V4 Core
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

// 3. Uniswap V4 Periphery
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

// 4. Permit2
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

// 5. OpenZeppelin Contracts
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// 6. Solmate (for tests/mocks)
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// 7. Local interfaces
import {IOrganizationManager} from "../interfaces/IOrganizationManager.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";

// 8. Local contracts
import {Treasury} from "./Treasury.sol";
import {ProposalManager} from "./ProposalManager.sol";
```

### 2.3 Contract Structure Order

```solidity
contract MyContract {
    // ============ Using Statements ============
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    // ============ Type Declarations ============
    // (structs, enums defined locally if not in separate file)

    // ============ Constants ============
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ============ Immutables ============
    IPoolManager public immutable poolManager;

    // ============ State Variables ============
    uint256 public orgCount;
    mapping(uint256 => Organization) public organizations;

    // ============ Events ============
    event OrganizationCreated(uint256 indexed orgId, address indexed owner);

    // ============ Errors ============
    error OrgNotFound(uint256 orgId);
    error NotProtocolAdmin();

    // ============ Modifiers ============
    modifier onlyProtocolAdmin() {
        if (!protocolAdmins[msg.sender]) revert NotProtocolAdmin();
        _;
    }

    // ============ Constructor ============
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ============ External Functions ============
    // (public state-changing functions)

    // ============ External View Functions ============
    // (public view/pure functions)

    // ============ Internal Functions ============
    // (internal helpers, prefixed with underscore)

    // ============ Private Functions ============
    // (private helpers, prefixed with underscore)
}
```

### 2.4 Naming Conventions

| Type                      | Convention                         | Example                              |
| ------------------------- | ---------------------------------- | ------------------------------------ |
| Contract                  | PascalCase                         | `OrganizationManager`                |
| Interface                 | I + PascalCase                     | `IOrganizationManager`               |
| Library                   | PascalCase + Lib                   | `ProposalLib`, `TWAPMath`            |
| Function                  | camelCase                          | `createProposal`                     |
| Internal/Private Function | \_camelCase                        | `_validateConfig`                    |
| Hook Callback (internal)  | \_hookName                         | `_beforeSwap`, `_afterSwap`          |
| Variable                  | camelCase                          | `totalStaked`                        |
| Constant                  | SCREAMING_SNAKE_CASE               | `MAX_FEE_BPS`                        |
| Immutable                 | camelCase                          | `poolManager`                        |
| Mapping                   | descriptive plural or "To" pattern | `organizations`, `tokenToProposal`   |
| Event                     | PastTense or Action                | `ProposalCreated`, `Staked`          |
| Error                     | DescriptiveError                   | `OrgNotFound`, `InsufficientBalance` |
| Struct                    | PascalCase                         | `OrganizationState`                  |
| Enum                      | PascalCase                         | `ProposalStatus`                     |
| Enum Value                | PascalCase                         | `Staking`, `Active`, `Resolved`      |

### 2.5 Function Signature Style

```solidity
// Short signatures - single line
function getOrganization(uint256 orgId) external view returns (Organization memory);

// Medium signatures - parameters on one line, returns separate
function createProposal(ProposalAction[] calldata actions)
    external
    returns (uint256 proposalId);

// Long signatures - one parameter per line
function initializeMarkets(
    uint256 proposalId,
    ConditionalTokenSet calldata tokens,
    uint256 baseAmount,
    uint256 quoteAmount,
    uint160 sqrtPriceX96,
    uint256 observationMaxRateBpsPerSecond,
    uint256 twapRecordingStartTime
) external returns (PoolKey[2] memory poolKeys);
```

### 2.6 Hook Function Pattern (from v4-template)

```solidity
// Hook permissions - explicit true/false for every flag
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: false,
        beforeAddLiquidity: false,
        afterAddLiquidity: false,
        beforeRemoveLiquidity: false,
        afterRemoveLiquidity: false,
        beforeSwap: false,
        afterSwap: true,  // LaggingTWAPHook uses this
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
    });
}

// Internal hook implementation - prefix with underscore
function _afterSwap(
    address,
    PoolKey calldata key,
    SwapParams calldata,
    BalanceDelta,
    bytes calldata
) internal override returns (bytes4, int128) {
    // Implementation
    return (BaseHook.afterSwap.selector, 0);
}
```

### 2.7 State Variable Mapping Pattern

```solidity
// NOTE: State variables should typically be unique to a pool
// A single hook contract should be able to service multiple pools
mapping(PoolId => uint256) public observedPrices;
mapping(PoolId => TWAPObservation) public observations;
```

### 2.8 Error Handling

```solidity
// Use custom errors instead of require strings
error InsufficientBalance(address token, uint256 required, uint256 available);
error InvalidProposalStatus(ProposalStatus current, ProposalStatus required);

// In functions:
if (balance < required) {
    revert InsufficientBalance(token, required, balance);
}

// For simple checks, single-condition pattern:
if (!protocolAdmins[msg.sender]) revert NotProtocolAdmin();
```

### 2.9 Comments Style

```solidity
/// @notice Brief description of the function
/// @dev Implementation details if complex
/// @param orgId The organization identifier
/// @return proposalId The newly created proposal ID
function createProposal(uint256 orgId) external returns (uint256 proposalId);

// NOTE: Single-line notes for important callouts
// -----------------------------------------------
// Section dividers for grouping related functions
// -----------------------------------------------
```

### 2.10 Numeric Literals

```solidity
// Use underscores for readability
uint256 public constant MAX_SUPPLY = 1_000_000_000e18;
uint256 liquidityAmount = 100e18;
uint256 amountIn = 1e18;

// BPS (basis points) - always use 10_000 denominator
uint256 public constant BPS_DENOMINATOR = 10_000;
uint256 feeBps = 300; // 3%
```

---

## 3. Architecture Reference

### 3.1 Contract Hierarchy

```
┌─────────────────────────────────────────────────────────────────┐
│                      SINGLETONS (Deploy Once)                    │
├─────────────────────────────────────────────────────────────────┤
│  OrganizationManager    - Central registry, configs, roles       │
│  ConditionalTokenFactory - Deploys conditional token sets        │
│  DecisionMarketManager  - Manages V4 pool init and LP            │
│  LaggingTWAPHook        - V4 hook for rate-limited TWAP          │
│  RaiseFactory           - Deploys ICO raise contracts            │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    PER-ORGANIZATION (Deploy per org)             │
├─────────────────────────────────────────────────────────────────┤
│  Treasury               - Holds assets, manages LP, executes     │
│  ProposalManager        - Proposal lifecycle, staking, redeem    │
│  GovernanceToken        - ERC-20 with controlled minting (ICO)   │
│  Raise                  - ICO contributions and distribution     │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    PER-PROPOSAL (Deploy per proposal)            │
├─────────────────────────────────────────────────────────────────┤
│  ConditionalToken (×4)  - pToken, fToken, pQuote, fQuote         │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Key Relationships

```
OrganizationManager ─┬─► Treasury (1:1 per org)
                     ├─► ProposalManager (1:1 per org)
                     ├─► GovernanceToken (1:1 per org, ICO only)
                     └─► Raise (1:1 per org, ICO only)

ProposalManager ─────┬─► ConditionalTokenFactory (creates tokens)
                     ├─► DecisionMarketManager (creates pools)
                     └─► Treasury (withdraws/adds liquidity)

DecisionMarketManager ──► LaggingTWAPHook (attached to pools)
                     ──► Uniswap V4 PoolManager
                     ──► Uniswap V4 PositionManager
```

### 3.3 Data Flow Diagram

See SPECIFICATION.md Section 6 for complete sequence diagrams covering:

- Proposal Lifecycle
- Split/Merge/Redeem Flow
- External Organization Onboarding
- ICO Raise Flow

---

## 4. Contract Implementation Order

Implement contracts in dependency order:

### Phase 1: Data Structures & Interfaces

```
src/
├── types/
│   └── DataTypes.sol          # All enums and structs
├── interfaces/
│   ├── IOrganizationManager.sol
│   ├── ITreasury.sol
│   ├── IProposalManager.sol
│   ├── IConditionalTokenFactory.sol
│   ├── IConditionalToken.sol
│   ├── IDecisionMarketManager.sol
│   ├── ILaggingTWAPHook.sol
│   ├── IRaiseFactory.sol
│   └── IRaise.sol
└── libraries/
    ├── ProposalLib.sol
    ├── TWAPMath.sol
    └── PoolKeyLib.sol
```

### Phase 2: Token Contracts

```
src/tokens/
├── GovernanceToken.sol        # Simple ERC-20 with mint auth
├── ConditionalToken.sol       # ERC-20 for pToken/fToken/pQuote/fQuote
└── ConditionalTokenFactory.sol # Deploys conditional sets
```

### Phase 3: Hook & Market Manager

```
src/markets/
├── LaggingTWAPHook.sol        # V4 hook - rate-limited TWAP
└── DecisionMarketManager.sol  # Pool init, LP management
```

### Phase 4: Core Contracts

```
src/core/
├── Treasury.sol               # Asset management, LP, execution
├── ProposalManager.sol        # Proposal lifecycle
└── OrganizationManager.sol    # Central registry (depends on Treasury, PM)
```

### Phase 5: Raise System

```
src/raise/
├── Raise.sol                  # ICO contributions
└── RaiseFactory.sol           # Deploys raises
```

---

## 5. Testing Standards

### 5.1 Test File Structure

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./utils/BaseTest.sol";

// V4 imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

// Local imports
import {LaggingTWAPHook} from "../src/markets/LaggingTWAPHook.sol";

contract LaggingTWAPHookTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    LaggingTWAPHook hook;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy hook with correct flags
        // ... (see Counter.t.sol pattern)
    }

    function test_AfterSwap_UpdatesObservation() public {
        // Arrange
        // Act
        // Assert
    }

    function testFuzz_TWAPRateLimit(uint256 priceChange) public {
        // Fuzz testing
    }

    function testRevert_WhenNotRecording() public {
        // Revert testing
    }
}
```

### 5.2 Test Naming Convention

```solidity
// Format: test_FunctionName_Condition or test_Description
function test_CreateProposal_WhenOwner() public {}
function test_CreateProposal_WhenTeamMember() public {}
function testRevert_CreateProposal_WhenNotTeamOrOwner() public {}
function testFuzz_Stake_Amount(uint256 amount) public {}
```

### 5.3 Hook Deployment Pattern (from v4-template)

```solidity
// Deploy hook to address with correct flags
address flags = address(
    uint160(
        Hooks.AFTER_SWAP_FLAG  // Only afterSwap for TWAP hook
    ) ^ (0x4444 << 144)  // Namespace to avoid collisions
);

bytes memory constructorArgs = abi.encode(poolManager);
deployCodeTo("LaggingTWAPHook.sol:LaggingTWAPHook", constructorArgs, flags);
hook = LaggingTWAPHook(flags);
```

### 5.4 Test Utilities

Use existing utilities from `test/utils/`:

- `BaseTest.sol` - Deploys V4 artifacts, labels addresses
- `Deployers.sol` - Token deployment, permit2, pool manager setup
- `EasyPosm.sol` - Simplified position manager interactions

---

## 6. Uniswap V4 Integration Patterns

### 6.1 Pool Initialization

```solidity
PoolKey memory poolKey = PoolKey({
    currency0: currency0,
    currency1: currency1,
    fee: 3000,           // 0.30%
    tickSpacing: 60,
    hooks: IHooks(hookAddress)
});

poolManager.initialize(poolKey, SQRT_PRICE_1_1);
```

### 6.2 Full-Range Liquidity (for Decision Markets)

```solidity
int24 tickLower = TickMath.minUsableTick(tickSpacing);
int24 tickUpper = TickMath.maxUsableTick(tickSpacing);

uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
    sqrtPriceX96,
    TickMath.getSqrtPriceAtTick(tickLower),
    TickMath.getSqrtPriceAtTick(tickUpper),
    amount0,
    amount1
);
```

### 6.3 Position Manager Actions

```solidity
// Mint position
bytes memory actions = abi.encodePacked(
    uint8(Actions.MINT_POSITION),
    uint8(Actions.SETTLE_PAIR)
);

// Decrease liquidity
bytes memory actions = abi.encodePacked(
    uint8(Actions.DECREASE_LIQUIDITY),
    uint8(Actions.TAKE_PAIR)
);

positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
```

### 6.4 Hook Data Flow

```solidity
// In hook callbacks, use PoolId for state mapping
function _afterSwap(
    address,
    PoolKey calldata key,
    SwapParams calldata,
    BalanceDelta,
    bytes calldata
) internal override returns (bytes4, int128) {
    PoolId poolId = key.toId();

    // Update pool-specific state
    observations[poolId] = newObservation;

    return (BaseHook.afterSwap.selector, 0);
}
```

---

## 7. Security Checklist

### 7.1 Access Control

- [ ] `onlyProtocolAdmin` for pause, fee settings, org approval
- [ ] `onlyOwner(orgId)` for team management
- [ ] `onlyTeamOrOwner(orgId)` for proposal creation
- [ ] `onlyGovernance(orgId)` for config/metadata updates (via passed proposals)
- [ ] `whenNotPaused` on all state-changing external functions

### 7.2 TWAP Manipulation Resistance

- [ ] Rate limiting: `observationMaxRateBpsPerSecond` enforced
- [ ] Recording delay: TWAP recording starts after `twapRecordingDelay`
- [ ] Serial execution: Only one active proposal at a time

### 7.3 Reentrancy

- [ ] Use checks-effects-interactions pattern
- [ ] Consider `nonReentrant` modifier for token transfers
- [ ] Treasury executions via passed proposals only

### 7.4 Integer Safety

- [ ] Use SafeCast for downcasting
- [ ] Validate BPS values < 10_000
- [ ] Check for overflow in TWAP calculations

### 7.5 Token Safety

- [ ] Validate token addresses (non-zero)
- [ ] Handle ERC-20 return values
- [ ] Consider fee-on-transfer tokens impact

---

## 8. File Structure

```
archdao-contracts/
├── .github/
│   ├── copilot-instructions.md   # This file
│   └── workflows/
│       └── test.yml
├── src/
│   ├── core/
│   │   ├── OrganizationManager.sol
│   │   ├── Treasury.sol
│   │   └── ProposalManager.sol
│   ├── tokens/
│   │   ├── GovernanceToken.sol
│   │   ├── ConditionalToken.sol
│   │   └── ConditionalTokenFactory.sol
│   ├── markets/
│   │   ├── DecisionMarketManager.sol
│   │   └── LaggingTWAPHook.sol
│   ├── raise/
│   │   ├── RaiseFactory.sol
│   │   └── Raise.sol
│   ├── interfaces/
│   │   └── *.sol
│   ├── libraries/
│   │   ├── ProposalLib.sol
│   │   ├── TWAPMath.sol
│   │   └── PoolKeyLib.sol
│   └── types/
│       └── DataTypes.sol
├── test/
│   ├── unit/
│   ├── integration/
│   ├── invariant/
│   └── utils/
│       ├── BaseTest.sol
│       ├── Deployers.sol
│       └── libraries/
│           └── EasyPosm.sol
├── script/
│   ├── Deploy.s.sol
│   └── base/
│       ├── BaseScript.sol
│       └── LiquidityHelpers.sol
├── SPECIFICATION.md
├── foundry.toml
└── remappings.txt
```

---

## 9. Commands Reference

### Allowed Commands

```bash
# Install dependencies
forge install

# Run all tests
forge test

# Run specific test file
forge test --match-path test/unit/Treasury.t.sol

# Run specific test function
forge test --match-test test_CreateProposal

# Run with verbosity
forge test -vvv

# Run with gas reporting
forge test --gas-report

# Build only (no tests)
forge build
```

### DO NOT RUN

```bash
# DO NOT run deployment scripts without explicit user instruction
forge script ...

# DO NOT run any blockchain interaction commands
cast ...
```

---

## Quick Reference Card

| Aspect             | Convention                                          |
| ------------------ | --------------------------------------------------- |
| Solidity Version   | `^0.8.26`                                           |
| License            | MIT                                                 |
| EVM Version        | Cancun                                              |
| Fee Denominator    | 10_000 (BPS)                                        |
| V4 Hook Base       | `@openzeppelin/uniswap-hooks/src/base/BaseHook.sol` |
| Test Base          | `test/utils/BaseTest.sol`                           |
| Errors             | Custom errors with parameters                       |
| Events             | Indexed for IDs and addresses                       |
| Modifiers          | Access control, pause state                         |
| Internal Functions | Prefix with `_`                                     |

---

## Reminders

1. **ALWAYS check SPECIFICATION.md** for exact function signatures and data structures
2. **One proposal active at a time** - serial execution model
3. **TWAP uses lagging observations** - rate-limited to prevent manipulation
4. **Full-range LP** for all decision market pools
5. **Pass threshold can be negative** for team proposals (easier to pass)
6. **Stakes are refunded** immediately upon activation - pure signaling mechanism
