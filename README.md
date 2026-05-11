# OpenOracle Gas Golfing

This repository is an experimental gas-golfing workspace for OpenOracle.

The point is to see how far the oracle game can be compressed while preserving the important mechanics: expected-state dispute calls, storage-mode and calldata/preimage modes, internal balance accounting, virtual sentinels, capital-efficient self-disputes, and settlement callbacks.

This is not production-ready code. It is a research prototype for measuring tradeoffs, finding the practical gas floor, and stress-testing design ideas before deciding what, if anything, belongs in a production OpenOracle release.

## Where We Are Today

The latest contract-size-limited prototype, `src/OpenOracleGasGolfing_ContractSizeLimit2.sol`, keeps the storage-mode public state readable, stays under the EIP-170 bytecode limit, and preserves both storage-backed and calldata/preimage-backed oracle flows.

Recent production-style measurements show the optimizations are material. The current gas benchmarks for the contract-size-limited prototype's calldata/preimage path are roughly:

| Path | Current |
| --- | ---: |
| Create report | 56k |
| Initial report | 55k |
| Dispute | 64k |
| Settle | 50k |

The follow-on `src/OpenOracleSlim.sol` collapses create + initial report into a single `report()` entry point and drops the storage-mode path entirely. Measured end-to-end on Base, with the reporter and disputer funding their token legs from pre-deposited internal balances (via `deposit` / `tryInternalBalance{1,2}`), and with no protocol fees:

| Path | Slim |
| --- | ---: |
| `report` (create + initial report) | 69k |
| `dispute` | 60k |
| `settle` | 48k |
| **Lifecycle total** | **178k** |

Versus the size-limited prototype's create + initial + dispute + settle (~225k), the slim variant trims ~21% off a full lifecycle by removing the create/initial split and the storage-backed accounting that goes with it.

The current direction is to keep the core oracle semantics intact while making each hot path pay only for state it actually needs.

## Changes Relative to the Production Oracle

`OpenOracleSlim.sol` is not a drop-in for the production `OpenOracle.sol`. The intent is to keep the same trust model and dispute mechanics while shedding storage and surface area that the slim path doesn't need. Notable differences:

- **Single `report()` entry point.** The slim contract merges `createReportInstance` + `submitInitialReport` into one call. There is no two-step "create the instance, then file the initial report" flow.
- **Calldata/preimage state only.** Production keeps `ReportMeta` / `ReportStatus` / `extraReportData` mappings in storage and mutates them on every action. Slim keeps only a `bytes32 stateHash` per report and requires callers to pass the full `OracleGame` + `PreimageHelper` preimage to `dispute()` and `settle()`. Storage is written only when explicitly requested via flags.
- **Flag-driven persistence.** At settle: `FLAG_STORE_PRICE` writes `finalPrice[reportId]` and `FLAG_STORE_ALL` writes the entire settled `OracleGame`. During disputes: `FLAG_TRACK_DISPUTES` writes per-dispute history. Off by default — callers pay for storage only when they want composability.
- **Flags replace booleans.** Production has separate `bool timeType` / `bool trackDisputes` params. Slim packs `timeType`, `trackDisputes`, `storeAll`, `storePrice` into a single `uint8 flags`.
- **Internal-balance APIs.** Slim exposes `deposit`, `approveInternal`, `withdraw`, `withdrawTo`, `dust`, and per-call `tryInternalBalance{1,2}` flags so internal balances can fund report / dispute legs directly without external token transfers.
- **Forced 1-unit sentinel on `tokenHolder` slots.** Every credited `(user, token)` slot is seeded with a virtual 1 unit on first touch (via `_dust` / `dust()` / the report and dispute paths), and `withdraw` leaves the sentinel behind. The sentinel is an accounting marker only — it's excluded from withdrawable / spendable balances — but it converts subsequent writes from cold to warm SSTOREs, which saves gas. Production has no equivalent; every credit can pay the cold-slot cost.
- **Native ETH support.** Slim treats `address(0)` as an ETH sentinel: ETH can sit on either side of a report, funded via `msg.value` and credited back internally on settle/dispute. Production requires callers to wrap into WETH externally.
- **No `ReentrancyGuard`.** Production wraps state-mutating entry points in `nonReentrant`.

## Current Focus

- Reduce report creation, initial report, dispute, and settlement gas.
- Avoid unnecessary token transfers by using internal balances where possible.

## Non-Goals

- This repo is not a deployment target.
- This repo is not an audited production implementation.
- This repo does not attempt to support non-standard ERC20s such as fee-on-transfer, rebasing, or tax tokens.
- Historical snapshots in `src/` are only development artifacts unless explicitly kept for comparison.

## Main Files

- `src/OpenOracleGasGolfing_ContractSizeLimit.sol` - first contract-size-limited gas-golfing prototype.
- `src/OpenOracleGasGolfing_ContractSizeLimit2.sol` - current contract-size-limited prototype.
- `src/OpenOracleSlim.sol` - current state-of-the-art calldata-only prototype.
- `src/OpenOracleErrors.sol` - shared custom errors.
- `test/openOracleGasGolfingConractSizeLimit/` - behavioral tests for the first contract-size-limited implementation.
- `test/openOracleGasGolfingConractSizeLimit2/` - behavioral tests for the current contract-size-limited implementation.

## Testing

```bash
forge test
```

For focused gas-golfing behavior tests:

```bash
forge test --match-path 'test/openOracleGasGolfingConractSizeLimit2/*.sol'
```

## Upstream Project

OpenOracle docs: https://docs.openoracle.org
