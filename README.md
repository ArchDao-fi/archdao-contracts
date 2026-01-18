# ArchDAO Smart Contracts

**Futarchy-based governance protocol built on Uniswap V4**

[![Solidity](https://img.shields.io/badge/Solidity-^0.8.26-363636?logo=solidity)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C?logo=foundry)](https://getfoundry.sh/)
[![Tests](https://img.shields.io/badge/Tests-338%20passing-brightgreen)](./test)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

---

## Overview

ArchDAO implements **futarchy governance** — a system where proposals pass or fail based on prediction market prices rather than token-weighted voting. The protocol enables organizations to leverage market-based decision making by creating conditional token markets for each governance proposal.

> **"Vote on Values, Bet on Beliefs"** — Robin Hanson

### Core Principle

A proposal passes if:

```
TWAP(pToken/pQuote) > TWAP(fToken/fQuote) × (1 + threshold)
```

Where:
- `TWAP(pToken/pQuote)` = Time-weighted average price of the pass conditional market
- `TWAP(fToken/fQuote)` = Time-weighted average price of the fail conditional market
- `threshold` = Pass threshold (configurable per organization)

---

## Architecture

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

---

## Contracts

| Contract | Description |
|----------|-------------|
| **OrganizationManager** | Central singleton managing all organization state, configs, and roles |
| **Treasury** | Per-org contract holding assets, managing LP positions, executing proposals |
| **ProposalManager** | Handles complete proposal lifecycle: staking, activation, resolution |
| **GovernanceToken** | ERC-20 with role-based minting for ICO organizations |
| **ConditionalTokenFactory** | Deploys conditional token sets (pToken, fToken, pQuote, fQuote) |
| **ConditionalToken** | ERC-20 conditional tokens redeemable based on proposal outcome |
| **DecisionMarketManager** | Manages Uniswap V4 pool initialization and liquidity |
| **LaggingTWAPHook** | V4 hook implementing rate-limited TWAP observations |
| **RaiseFactory** | Factory for deploying ICO raise contracts |
| **Raise** | Handles ICO contributions, finalization, and token distribution |

---

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/) (stable)

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Installation

```bash
git clone https://github.com/archdao/archdao-contracts.git
cd archdao-contracts
forge install
```

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/unit/ProposalManager.t.sol

# Run with gas reporting
forge test --gas-report
```

---

## Test Coverage

| Contract | Tests |
|----------|-------|
| OrganizationManager | 67 |
| ProposalManager | 55 |
| Treasury | 43 |
| DecisionMarketManager | 25 |
| ConditionalToken | 21 |
| GovernanceToken | 20 |
| LaggingTWAPHook | 20 |
| ConditionalTokenFactory | 16 |
| Raise | 52 |
| RaiseFactory | 13 |
| **Total** | **338** |

---

## Project Structure

```
archdao-contracts/
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
│   │   ├── Raise.sol
│   │   └── RaiseFactory.sol
│   ├── interfaces/
│   │   └── *.sol
│   └── types/
│       ├── OrganizationTypes.sol
│       ├── ProposalTypes.sol
│       └── RaiseTypes.sol
├── test/
│   ├── unit/
│   │   └── *.t.sol
│   └── utils/
├── script/
│   ├── base/
│   │   └── BaseScript.sol
│   └── testing/
├── SPECIFICATION.md
└── foundry.toml
```

---

## Key Concepts

### Organization Types

- **ICO Organizations**: New projects launching through ArchDAO's fundraising mechanism
- **External Organizations**: Existing projects with tokens adopting futarchy governance

### Conditional Token System

For each proposal, four conditional tokens are created:

| Token | Collateral | Redeemable When |
|-------|------------|-----------------|
| pToken | baseToken | Proposal passes |
| fToken | baseToken | Proposal fails |
| pQuote | quoteToken | Proposal passes |
| fQuote | quoteToken | Proposal fails |

### Lagging TWAP

To prevent price manipulation, the protocol uses rate-limited observations:
- Observations can only move by `observationMaxRateBpsPerSecond` per second
- Recording delay before TWAP tracking starts (default 24 hours)
- Serial execution ensures liquidity concentration

---

## Documentation

- [SPECIFICATION.md](./SPECIFICATION.md) - Complete protocol specification
- [.github/copilot-instructions.md](./.github/copilot-instructions.md) - Development guidelines

---

## Security

This codebase has not yet been audited. Use at your own risk.

---

## License

MIT License - see [LICENSE](./LICENSE) for details.

---

## Acknowledgments

Built with:
- [Uniswap V4](https://github.com/uniswap/v4-core)
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Foundry](https://github.com/foundry-rs/foundry)
