# OpenOracle Gas Golfing

This repository is an experimental gas-golfing workspace for OpenOracle.

The point is to see how far the oracle game can be compressed while preserving the important mechanics: expected-state dispute calls, storage-mode and calldata/preimage modes, internal balance accounting, virtual sentinels, capital-efficient self-disputes, and settlement callbacks.

This is not production-ready code. It is a research prototype for measuring tradeoffs, finding the practical gas floor, and stress-testing design ideas before deciding what, if anything, belongs in a production OpenOracle release.

## Where We Are Today

The latest contract-size-limited prototype, `src/OpenOracleGasGolfing_ContractSizeLimit2.sol`, keeps the storage-mode public state readable, stays under the EIP-170 bytecode limit, and preserves both storage-backed and calldata/preimage-backed oracle flows.

Recent production-style measurements show the optimizations are material. The current state of the art for the contract-size-limited prototype's calldata/preimage path is roughly:

| Path | Current |
| --- | ---: |
| Create report | 56k |
| Initial report | 55k |
| Dispute | 64k |
| Settle | 50k |

The current direction is to keep the core oracle semantics intact while making each hot path pay only for state it actually needs.

## Current Focus

- Reduce report creation, initial report, dispute, and settlement gas.
- Compare storage-backed oracle state against calldata/preimage-backed state.
- Avoid unnecessary token transfers by using internal balances where possible.
- Preserve caller-side expected-state protection instead of blindly acting on live state.
- Explore composability around settlement callbacks and internal credits.

## Non-Goals

- This repo is not a deployment target.
- This repo is not an audited production implementation.
- This repo does not attempt to support non-standard ERC20s such as fee-on-transfer, rebasing, or tax tokens.
- Historical snapshots in `src/` are only development artifacts unless explicitly kept for comparison.

## Main Files

- `src/OpenOracleGasGolfing_ContractSizeLimit.sol` - first contract-size-limited gas-golfing prototype.
- `src/OpenOracleGasGolfing_ContractSizeLimit2.sol` - current state-of-the-art contract-size-limited prototype.
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
